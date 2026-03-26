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
///   - spendCap: per-session cumulative token spend limit
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
        address spendToken;          // ERC-20 token for spend cap (address(0) = ETH)
        uint256 spendCap;            // Max cumulative spend this session (0 = unlimited)
        bool    revoked;             // Owner can revoke at any time
        address[] callTargets;       // Allowlisted contracts (empty = all allowed)
        bytes4[]  selectorAllowlist; // Allowed selectors (empty = all selectors allowed for any target)
    }

    struct AgentSessionState {
        uint256 callCount;     // Total calls in current window
        uint256 windowStart;   // When current velocity window started
        uint256 totalSpent;    // Cumulative spend this session
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

    /// @dev Maximum number of callTargets entries per session (gas-bomb prevention)
    uint256 internal constant MAX_CALL_TARGETS = 20;

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
    error SpendCapExceeded(uint256 cap, uint256 spent);
    error CallTargetForbidden(address target);
    error SelectorForbidden(address target, bytes4 selector);
    error InvalidExpiry();
    error OnlyAccountOwner();
    /// @dev Caller has no valid (non-revoked, non-expired) session on any account
    error CallerNotSessionKey();
    /// @dev Sub-session scope exceeds the parent session scope
    error ScopeEscalationDenied();
    /// @dev Parent session is expired or revoked
    error ParentSessionExpired();
    /// @dev callTargets list exceeds maximum allowed length
    error MaxTargetsExceeded();

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
    /// @param cfg Session configuration (expiry, velocity, spend cap, allowlists)
    function grantAgentSession(address sessionKey, AgentSessionConfig calldata cfg) external {
        if (cfg.expiry <= block.timestamp) revert InvalidExpiry();
        if (cfg.callTargets.length > MAX_CALL_TARGETS) revert MaxTargetsExceeded();
        agentSessions[msg.sender][sessionKey] = cfg;
        // Track which account owns this session key (last grant wins for cross-account reuse)
        sessionKeyOwner[sessionKey] = msg.sender;
        emit AgentSessionGranted(msg.sender, sessionKey, cfg.expiry);
    }

    /// @notice A session key holder can sub-delegate with equal or narrower scope.
    ///         Parent session must be valid (not expired, not revoked).
    ///         Sub-delegation CANNOT escalate scope (verified on-chain).
    /// @param subKey  The sub-agent's EOA address
    /// @param subCfg  Config for the sub-session — must be <= parent scope
    function delegateSession(address subKey, AgentSessionConfig calldata subCfg) external {
        address parentKey = msg.sender;
        address parentAccount = sessionKeyOwner[parentKey];

        // Verify that caller is a known session key
        AgentSessionConfig storage parentCfg = agentSessions[parentAccount][parentKey];
        if (parentCfg.expiry == 0) revert CallerNotSessionKey();

        // Verify parent session is still valid
        if (parentCfg.revoked || block.timestamp > parentCfg.expiry) revert ParentSessionExpired();

        // Enforce scope: expiry cannot extend beyond parent
        if (subCfg.expiry > parentCfg.expiry) revert ScopeEscalationDenied();

        // Enforce scope: spendCap cannot increase
        // sub cap=0 (unlimited) is only allowed if parent cap is also 0 (unlimited)
        if (subCfg.spendCap == 0) {
            // sub requests unlimited spend — only valid if parent also has unlimited
            if (parentCfg.spendCap != 0) revert ScopeEscalationDenied();
        } else {
            // sub has a finite cap — parent must also have a finite cap and sub cap <= parent cap
            if (parentCfg.spendCap > 0 && subCfg.spendCap > parentCfg.spendCap) revert ScopeEscalationDenied();
        }

        // Enforce scope: velocityLimit cannot increase
        // sub velocityLimit=0 (unlimited) is only valid if parent velocityLimit is also 0 (unlimited)
        if (subCfg.velocityLimit == 0) {
            // sub requests unlimited velocity — only valid if parent is also unlimited
            if (parentCfg.velocityLimit != 0) revert ScopeEscalationDenied();
        } else {
            // sub has a finite limit — only escalates if parent has a limit and sub exceeds it
            if (parentCfg.velocityLimit > 0 && subCfg.velocityLimit > parentCfg.velocityLimit) {
                revert ScopeEscalationDenied();
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
            for (uint256 i = 0; i < subCfg.callTargets.length; i++) {
                bool found = false;
                for (uint256 j = 0; j < parentCfg.callTargets.length; j++) {
                    if (subCfg.callTargets[i] == parentCfg.callTargets[j]) {
                        found = true;
                        break;
                    }
                }
                if (!found) revert ScopeEscalationDenied();
            }
        }

        // Enforce scope: selectorAllowlist cannot expand beyond parent's allowlist.
        // Empty selectorAllowlist = "all selectors allowed" (widest scope), same as callTargets=empty.
        // sub=empty (all selectors) is only valid if parent is also empty (all selectors).
        // sub=non-empty (restricted) is always a subset of any parent scope.
        if (subCfg.selectorAllowlist.length == 0) {
            // sub requests all selectors — only valid if parent also allows all
            if (parentCfg.selectorAllowlist.length != 0) revert ScopeEscalationDenied();
        } else if (parentCfg.selectorAllowlist.length > 0) {
            // both have restricted lists — every sub selector must appear in parent's list
            for (uint256 i = 0; i < subCfg.selectorAllowlist.length; i++) {
                bool found = false;
                for (uint256 j = 0; j < parentCfg.selectorAllowlist.length; j++) {
                    if (subCfg.selectorAllowlist[i] == parentCfg.selectorAllowlist[j]) {
                        found = true;
                        break;
                    }
                }
                if (!found) revert ScopeEscalationDenied();
            }
        }

        // Store sub-session under the same parent account
        agentSessions[parentAccount][subKey] = subCfg;
        // Track delegation chain
        delegatedBy[parentAccount][subKey] = parentKey;
        // Track the sub-agent's owner for potential further delegation
        sessionKeyOwner[subKey] = parentAccount;

        emit AgentSessionDelegated(parentAccount, parentKey, subKey, subCfg.expiry);
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

        // Recover signing key from signature
        if (userOp.signature.length < 65) return 1;
        bytes32 ethHash = userOpHash.toEthSignedMessageHash();
        address recovered = ethHash.recover(userOp.signature[0:65]);

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

        // Check call target allowlist
        if (cfg.callTargets.length > 0) {
            bool targetAllowed = false;
            for (uint256 i = 0; i < cfg.callTargets.length; i++) {
                if (cfg.callTargets[i] == callTarget) {
                    targetAllowed = true;
                    break;
                }
            }
            if (!targetAllowed) revert CallTargetForbidden(callTarget);
        }

        // Check selector allowlist
        if (cfg.selectorAllowlist.length > 0) {
            bool selectorAllowed = false;
            for (uint256 i = 0; i < cfg.selectorAllowlist.length; i++) {
                if (cfg.selectorAllowlist[i] == selector) {
                    selectorAllowed = true;
                    break;
                }
            }
            if (!selectorAllowed) revert SelectorForbidden(callTarget, selector);
        }
    }

    /// @notice Update cumulative spend tracking.
    /// @dev Called by account after each spend to track against spendCap.
    ///      Only the account itself may call this — prevents griefing via artificial cap exhaustion.
    function recordSpend(address account, address sessionKey, uint256 amount) external {
        if (msg.sender != account) revert OnlyAccountOwner();
        AgentSessionConfig storage cfg = agentSessions[account][sessionKey];
        if (cfg.spendCap == 0) return; // no cap — skip tracking

        AgentSessionState storage state = sessionStates[account][sessionKey];
        state.totalSpent += amount;
        if (state.totalSpent > cfg.spendCap) {
            revert SpendCapExceeded(cfg.spendCap, state.totalSpent);
        }
    }

    function isValidSignatureWithSender(
        address /* sender */,
        bytes32 /* hash */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return 0xffffffff; // Not used for ERC-1271
    }
}
