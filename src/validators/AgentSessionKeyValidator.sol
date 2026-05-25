// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC7579Validator} from "../interfaces/IERC7579Module.sol";

/// @title AgentSessionKeyValidator — ERC-7579 Validator for AI agent session keys (M7.14)
/// @notice Extends session key pattern with agent-specific constraints:
///   - velocityLimit: max N calls per time window (prevents runaway agents)
///   - callTargetAllowlist: agent can only call pre-approved contracts (prompt injection defense)
///   - selectorAllowlist: per-target selector restrictions (M7.18)
///
/// @dev Spend control is intentionally NOT a per-session concern. Session keys are Tier-1
///      (ALG_SESSION_KEY) and inherit the account's T1/T2/T3 tier model + global daily limit:
///      any amount above tier1Limit already requires higher-tier multi-factor sigs a session
///      key cannot produce, and cumulative spend is bounded by the guard's daily limit + the
///      session expiry. A separate per-session spendCap would duplicate that logic without
///      adding protection, so it is omitted.
///
/// @dev Maps to ERC-7715 wallet_grantPermissions and ERC-7710 Delegation standards.
///      Install as Validator module (type 1) via account.installModule(1, agentValidator, guardianSig).
contract AgentSessionKeyValidator is IERC7579Validator {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Structs ─────────────────────────────────────────────────────

    struct AgentSessionConfig {
        uint48  expiry;              // Unix timestamp — session expires after this
        uint16  velocityLimit;       // Max calls per velocityWindow (0 = unlimited)
        uint32  velocityWindow;      // Window in seconds for velocity limiting
        bool    revoked;             // Owner can revoke at any time
        address[] callTargets;       // Allowlisted contracts (empty = all allowed)
        bytes4[]  selectorAllowlist; // Allowed selectors (empty = all selectors allowed for any target)
    }

    struct AgentSessionState {
        uint256 callCount;     // Total calls in current window
        uint256 windowStart;   // When current velocity window started
    }

    // ─── Storage ─────────────────────────────────────────────────────

    /// @dev account → sessionKey → config
    mapping(address => mapping(address => AgentSessionConfig)) public agentSessions;

    /// @dev account → sessionKey → runtime state
    mapping(address => mapping(address => AgentSessionState)) public sessionStates;

    /// @dev account → initialized
    mapping(address => bool) internal _initialized;

    /// @dev sessionKey → parentAccount — maps a session key to the account that granted it.
    ///      Note: if a session key is reused across multiple accounts, the last grantAgentSession wins.
    mapping(address sessionKey => address parentAccount) public sessionKeyOwner;

    /// @dev account → subKey → parentKey — tracks who delegated to the sub-agent for a given account
    mapping(address account => mapping(address subKey => address parentKey)) public delegatedBy;

    /// @dev Expected signature length: 1-byte algId prefix (0x08) + 65-byte ECDSA (r,s,v)
    uint256 internal constant SESSION_SIG_LENGTH = 66;

    /// @dev AlgId prefix required in UserOp signatures routed to this validator
    uint8 internal constant ALG_SESSION_KEY = 0x08;

    /// @dev Maximum number of callTargets entries per session (gas-bomb prevention)
    uint256 internal constant MAX_CALL_TARGETS = 20;

    /// @dev Maximum number of selectorAllowlist entries per session (gas-bomb prevention)
    uint256 internal constant MAX_SELECTORS = 30;

    // ─── Events ──────────────────────────────────────────────────────

    event AgentSessionGranted(address indexed account, address indexed sessionKey, uint48 expiry);
    event AgentSessionRevoked(address indexed account, address indexed sessionKey);
    /// @dev Emitted when a session key sub-delegates to a new sub-agent
    event AgentSessionDelegated(
        address indexed parentAccount,
        address indexed parentKey,
        address indexed subKey,
        uint48 expiry
    );

    // ─── Errors ──────────────────────────────────────────────────────

    error SessionExpired();
    error SessionRevoked();
    error SessionNotFound();
    error VelocityLimitExceeded(uint16 limit, uint256 count);
    error CallTargetForbidden(address target);
    error SelectorForbidden(address target, bytes4 selector);
    error InvalidExpiry();
    /// @dev Caller has no valid (non-revoked, non-expired) session on any account
    error CallerNotSessionKey();
    /// @dev Sub-session scope exceeds the parent session scope
    error ScopeEscalationDenied();
    /// @dev Parent session is expired or revoked
    error ParentSessionExpired();
    /// @dev callTargets list exceeds maximum allowed length
    error MaxTargetsExceeded();
    /// @dev selectorAllowlist exceeds maximum allowed length
    error MaxSelectorsExceeded();
    /// @dev velocityWindow must be > 0 when velocityLimit > 0
    error InvalidVelocityWindow();

    // ─── IERC7579Module ─────────────────────────────────────────────

    function onInstall(bytes calldata /* data */) external override {
        _initialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata /* data */) external override {
        _initialized[msg.sender] = false;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _initialized[smartAccount];
    }

    // ─── Session Key Management ───────────────────────────────────────

    /// @notice Grant an agent session key with constraints.
    /// @dev Called by the account owner (or via EntryPoint UserOp signed by owner).
    ///      The account calls this directly — msg.sender = account.
    /// @param sessionKey The agent's EOA signing address
    /// @param cfg Session configuration (expiry, velocity, allowlists)
    function grantAgentSession(address sessionKey, AgentSessionConfig calldata cfg) external {
        if (cfg.expiry <= block.timestamp) revert InvalidExpiry();
        // velocityWindow=0 with velocityLimit>0 would silently disable rate limiting (window check: block.timestamp > 0+0 always true → counter reset every call)
        if (cfg.velocityLimit > 0 && cfg.velocityWindow == 0) revert InvalidVelocityWindow();
        if (cfg.callTargets.length > MAX_CALL_TARGETS) revert MaxTargetsExceeded();
        if (cfg.selectorAllowlist.length > MAX_SELECTORS) revert MaxSelectorsExceeded();
        agentSessions[msg.sender][sessionKey] = cfg;
        // Track which account owns this session key (last grant wins for cross-account reuse)
        sessionKeyOwner[sessionKey] = msg.sender;
        emit AgentSessionGranted(msg.sender, sessionKey, cfg.expiry);
    }

    /// @notice A session key holder can sub-delegate with equal or narrower scope.
    ///         Parent session must be valid (not expired, not revoked).
    ///         Sub-delegation CANNOT escalate scope (verified on-chain).
    /// @param account    The smart account under which the parent session was granted.
    ///                   Caller must pass this explicitly to prevent cross-account routing confusion
    ///                   when the same key is granted sessions on multiple accounts.
    /// @param subKey     The sub-agent's EOA address
    /// @param subCfg     Config for the sub-session — must be <= parent scope
    function delegateSession(address account, address subKey, AgentSessionConfig calldata subCfg) external {
        address parentKey = msg.sender;

        // Verify that caller is a known session key on the specified account.
        // Using an explicit `account` param prevents sessionKeyOwner cross-account overwrite:
        // if the same key has sessions on multiple accounts, each account is addressed separately.
        AgentSessionConfig storage parentCfg = agentSessions[account][parentKey];
        if (parentCfg.expiry == 0) revert CallerNotSessionKey();

        // Verify parent session is still valid
        if (parentCfg.revoked || block.timestamp > parentCfg.expiry) revert ParentSessionExpired();

        // Enforce scope: expiry cannot extend beyond parent
        if (subCfg.expiry > parentCfg.expiry) revert ScopeEscalationDenied();

        // Enforce scope: velocity rate (limit/window) cannot increase.
        // Comparing only velocityLimit ignores the window — a sub with 9 calls/1s exceeds
        // a parent with 10 calls/60s even though 9 < 10. Cross-multiply to compare rates:
        //   sub.limit / sub.window <= parent.limit / parent.window
        //   ↔ sub.limit * parent.window <= parent.limit * sub.window
        if (subCfg.velocityLimit == 0) {
            // sub requests unlimited velocity — only valid if parent is also unlimited
            if (parentCfg.velocityLimit != 0) revert ScopeEscalationDenied();
        } else {
            if (parentCfg.velocityLimit > 0) {
                uint256 subRate    = uint256(subCfg.velocityLimit)    * uint256(parentCfg.velocityWindow);
                uint256 parentRate = uint256(parentCfg.velocityLimit) * uint256(subCfg.velocityWindow);
                if (subRate > parentRate) revert ScopeEscalationDenied();
            }
        }

        // Enforce scope: callTargets cannot expand beyond parent's allowlist.
        // Empty callTargets = "all targets allowed" (widest scope), same as velocityLimit=0.
        // sub=empty (all targets) is only valid if parent is also empty (all targets).
        // sub=non-empty (restricted) is always a subset of any parent scope.
        if (subCfg.callTargets.length > MAX_CALL_TARGETS) revert MaxTargetsExceeded();
        if (subCfg.callTargets.length == 0) {
            // sub requests all targets — only valid if parent also allows all
            if (parentCfg.callTargets.length != 0) revert ScopeEscalationDenied();
        } else if (parentCfg.callTargets.length > 0) {
            // both have restricted lists — every sub target must appear in parent's list
            if (!_isSubsetAddresses(subCfg.callTargets, parentCfg.callTargets)) revert ScopeEscalationDenied();
        }

        // Enforce scope: selectorAllowlist cannot expand beyond parent's allowlist.
        // Empty selectorAllowlist = "all selectors allowed" (widest scope), same as callTargets=empty.
        // sub=empty (all selectors) is only valid if parent is also empty (all selectors).
        // sub=non-empty (restricted) is always a subset of any parent scope.
        if (subCfg.selectorAllowlist.length > MAX_SELECTORS) revert MaxSelectorsExceeded();
        if (subCfg.selectorAllowlist.length == 0) {
            // sub requests all selectors — only valid if parent also allows all
            if (parentCfg.selectorAllowlist.length != 0) revert ScopeEscalationDenied();
        } else if (parentCfg.selectorAllowlist.length > 0) {
            // both have restricted lists — every sub selector must appear in parent's list
            if (!_isSubsetSelectors(subCfg.selectorAllowlist, parentCfg.selectorAllowlist)) revert ScopeEscalationDenied();
        }

        // Store sub-session under the explicitly supplied account
        agentSessions[account][subKey] = subCfg;
        // Track delegation chain
        delegatedBy[account][subKey] = parentKey;
        // Update sessionKeyOwner to the explicit account.
        // NOTE: still last-write-wins if the same subKey is granted on multiple accounts.
        // Callers that need per-account delegation must use the account-scoped agentSessions directly.
        sessionKeyOwner[subKey] = account;

        emit AgentSessionDelegated(account, parentKey, subKey, subCfg.expiry);
    }

    /// @notice Revoke an agent session key immediately.
    function revokeAgentSession(address sessionKey) external {
        agentSessions[msg.sender][sessionKey].revoked = true;
        emit AgentSessionRevoked(msg.sender, sessionKey);
    }

    // ─── IERC7579Validator ─────────────────────────────────────────

    /// @notice Validate agent UserOperation against session constraints.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256 validationData) {
        if (!_initialized[userOp.sender]) return 1;

        // Require ALG_SESSION_KEY (0x08) prefix so the account stores the correct algId in
        // transient storage via _storeValidatedAlgId(sig[0]) after nonce-key routing.
        // Without this, sig[0] would be an arbitrary byte of r, bypassing session scope enforcement.
        if (userOp.signature.length < SESSION_SIG_LENGTH) return 1;
        if (uint8(userOp.signature[0]) != ALG_SESSION_KEY) return 1;
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        address recovered = ethHash.recover(userOp.signature[1:SESSION_SIG_LENGTH]);

        AgentSessionConfig storage cfg = agentSessions[userOp.sender][recovered];
        if (cfg.expiry == 0) return 1; // session not found
        if (cfg.revoked) return 1;
        if (block.timestamp > cfg.expiry) return 1;

        // Enforce velocity limit
        if (cfg.velocityLimit > 0) {
            AgentSessionState storage state = sessionStates[userOp.sender][recovered];
            if (block.timestamp > state.windowStart + cfg.velocityWindow) {
                // New window — reset counter
                state.windowStart = block.timestamp;
                state.callCount = 0;
            }
            if (state.callCount >= cfg.velocityLimit) {
                revert VelocityLimitExceeded(cfg.velocityLimit, state.callCount);
            }
            state.callCount++;
        }

        // Return success with expiry timestamp packed (ERC-4337 validUntil)
        // High 48 bits = validUntil, low 48 bits = validAfter (0)
        validationData = uint256(cfg.expiry) << 160;
    }

    /// @notice Enforce call target and selector restrictions.
    /// @dev Called by the account BEFORE executing a call (similar to scope enforcement in SessionKeyValidator).
    ///      The account should call this in its _enforceGuard equivalent when algId routes through this validator.
    function enforceSessionScope(
        address account,
        address sessionKey,
        address callTarget,
        bytes4 selector
    ) external view {
        AgentSessionConfig storage cfg = agentSessions[account][sessionKey];
        if (cfg.expiry == 0) revert SessionNotFound();
        if (cfg.revoked) revert SessionRevoked();
        if (block.timestamp > cfg.expiry) revert SessionExpired();

        // Check call target allowlist
        if (cfg.callTargets.length > 0 && !_containsAddress(cfg.callTargets, callTarget)) {
            revert CallTargetForbidden(callTarget);
        }

        // Check selector allowlist
        if (cfg.selectorAllowlist.length > 0 && !_containsSelector(cfg.selectorAllowlist, selector)) {
            revert SelectorForbidden(callTarget, selector);
        }
    }

    function isValidSignatureWithSender(
        address /* sender */,
        bytes32 /* hash */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return 0xffffffff; // Not used for ERC-1271
    }

    // ─── Private helpers ─────────────────────────────────────────────

    /// @dev Returns true if `value` is present in `arr`.
    function _containsAddress(address[] storage arr, address value) private view returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    /// @dev Returns true if `value` is present in `arr`.
    function _containsSelector(bytes4[] storage arr, bytes4 value) private view returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    /// @dev Returns true if every element of `sub` is present in `parent`.
    function _isSubsetAddresses(address[] calldata sub, address[] storage parent) private view returns (bool) {
        for (uint256 i = 0; i < sub.length; i++) {
            if (!_containsAddress(parent, sub[i])) return false;
        }
        return true;
    }

    /// @dev Returns true if every element of `sub` is present in `parent`.
    function _isSubsetSelectors(bytes4[] calldata sub, bytes4[] storage parent) private view returns (bool) {
        for (uint256 i = 0; i < sub.length; i++) {
            if (!_containsSelector(parent, sub[i])) return false;
        }
        return true;
    }
}
