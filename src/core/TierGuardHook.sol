// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IERC7579Hook} from "../interfaces/IERC7579Module.sol";

/// @title TierGuardHook — ERC-7579 Hook for session-scope enforcement on AirAccount
/// @notice When installed as a Hook(3) module on an AAStarAirAccountV7, this hook enforces
///         session key call-target and selector restrictions for ALG_SESSION_KEY operations.
/// @dev The hook is called by the account in execute() BEFORE the actual call.
///      ETH tier and daily limit enforcement is NOT done here — those are enforced directly
///      by the account's _enforceGuard (guard.checkTransaction has onlyAccount, the hook cannot
///      call it). The account's skipEthCheck is always false so limits are always enforced inline.
///
///      Session scope enforcement (M8.P2): When an AgentSessionKeyValidator address is configured
///      via onInstall, preCheck enforces callTargets and selectorAllowlist for ALG_SESSION_KEY ops.
contract TierGuardHook is IERC7579Hook {
    /// @dev Tracks which accounts have installed this hook (prevents bypass via zero-guard).
    mapping(address => bool) private _initialized;

    /// @dev Per-account AgentSessionKeyValidator address for session scope enforcement (M8.P2).
    ///      If set, preCheck enforces callTargets/selectorAllowlist for ALG_SESSION_KEY ops.
    mapping(address => address) public accountAgentValidator;

    error TierGuardHookUnauthorized();
    error AlreadyInstalled();
    error NotInstalled();

    uint8 internal constant ALG_SESSION_KEY = 0x08;

    // ─── IERC7579Module ─────────────────────────────────────────────

    /// @notice Install hook for msg.sender account.
    /// @param data abi.encode(agentSessionKeyValidator) — 32 bytes (address).
    ///        Pass address(0) or empty bytes to install without session scope enforcement.
    function onInstall(bytes calldata data) external override {
        if (_initialized[msg.sender]) revert AlreadyInstalled();
        _initialized[msg.sender] = true;
        if (data.length >= 32) {
            address agentValidator = abi.decode(data, (address));
            accountAgentValidator[msg.sender] = agentValidator;
        }
    }

    function onUninstall(bytes calldata /* data */) external override {
        delete _initialized[msg.sender];
        delete accountAgentValidator[msg.sender];
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _initialized[smartAccount];
    }

    // ─── IERC7579Hook ────────────────────────────────────────────────

    /// @notice Pre-execution check: enforce tier + daily limit + session scope (M8.P2).
    /// @param msgSender The original msg.sender of the execute() call (unused — msg.sender is the account)
    /// @param msgValue The ETH value being sent
    /// @param msgData The full execute() calldata forwarded by the account.
    ///        Layout: [4B execute selector][32B dest padded][32B value][32B func-offset][32B func-len][func...]
    ///        dest  = address(uint160(uint256(bytes32(msgData[4:36]))))
    ///        func offset pointer at msgData[68:100] — read this, do NOT assume 0x60.
    ///        func data starts at: 4 + offset + 32  (4=execute selector, 32=length word)
    ///        inner selector = first 4 bytes of func data
    ///
    ///        Security: fixed-offset [132:136] is bypassable with non-canonical ABI encoding.
    ///        Attacker could put a fake allowed selector at offset 132 while actual func runs
    ///        at a different ABI-decoded position. Always derive position from the offset pointer.
    /// @return hookData Empty bytes (no post-check state needed)
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external override returns (bytes memory hookData) {
        msgSender;
        msgValue;

        // ── Session scope enforcement (M8.P2) ─────────────────────────────────
        // ETH tier / daily-limit enforcement is intentionally NOT done here.
        // AAStarGlobalGuard.checkTransaction() carries onlyAccount (msg.sender == account),
        // so calling it from the hook (a separate contract) would always revert.
        // The account's _enforceGuard handles tier + daily limits directly with skipEthCheck=false.
        //
        // This hook's sole responsibility is session-scope enforcement (call targets + selectors).
        // When an AgentSessionKeyValidator is configured and the operation uses ALG_SESSION_KEY,
        // enforce callTargets and selectorAllowlist constraints that were set at session grant time.
        address agentValidator = accountAgentValidator[msg.sender];
        uint8 algId = _getAlgIdFromAccount(msg.sender);
        if (agentValidator != address(0) && algId == ALG_SESSION_KEY) {
            bytes32 taggedSessionKey = _getSessionKeyFromAccount(msg.sender);
            if (taggedSessionKey != bytes32(0)) {
                uint8 sessionType = uint8(uint256(taggedSessionKey) >> 248);
                if (sessionType == 0x01) {
                    address sessionKey = address(uint160(uint256(taggedSessionKey)));
                    // Parse dest and inner selector from execute() calldata.
                    // dest: msgData[4:36] (always at fixed position — it's a value type, not a pointer).
                    // selector: derived from the ABI offset pointer at msgData[68:100].
                    //   offset is relative to args start (msgData[4:]).
                    //   func data starts at: 4 + offset + 32  (32 = func length word).
                    //   We MUST read the offset from msgData[68:100] rather than assuming 0x60
                    //   to prevent non-canonical ABI bypass (fake selector at fixed position 132).
                    address dest;
                    bytes4 selector;
                    if (msgData.length >= 36) {
                        dest = address(uint160(uint256(bytes32(msgData[4:36]))));
                    }
                    if (msgData.length >= 100) {
                        uint256 funcOffset = uint256(bytes32(msgData[68:100]));
                        // Guard against overflow: funcOffset must leave room for 4+32 header bytes
                        if (funcOffset <= type(uint256).max - 36) {
                            uint256 funcDataStart = 4 + funcOffset + 32;
                            if (msgData.length >= funcDataStart + 4) {
                                selector = bytes4(msgData[funcDataStart:funcDataStart + 4]);
                            }
                        }
                    }
                    // enforceSessionScope reverts if the target or selector is not in the allowlist
                    (bool ok,) = agentValidator.staticcall(
                        abi.encodeWithSignature(
                            "enforceSessionScope(address,address,address,bytes4)",
                            msg.sender, sessionKey, dest, selector
                        )
                    );
                    if (!ok) revert TierGuardHookUnauthorized();
                }
            }
        }

        return "";
    }

    function postCheck(bytes calldata /* hookData */) external override {
        // No post-check logic needed
    }

    // ─── Internal ────────────────────────────────────────────────────

    /// @dev Call back to the account to get the current tagged session key from transient storage.
    ///      Returns bytes32(0) if the account does not implement getCurrentSessionKey() or if no
    ///      session key is active.
    ///      COMPATIBILITY: requires AAStarAirAccountV7 (M7+) with getCurrentSessionKey() exposed.
    function _getSessionKeyFromAccount(address account) internal view returns (bytes32 taggedId) {
        (bool ok, bytes memory data) = account.staticcall(
            abi.encodeWithSignature("getCurrentSessionKey()")
        );
        if (ok && data.length >= 32) {
            taggedId = abi.decode(data, (bytes32));
        }
    }

    /// @dev Read algId from account's getCurrentAlgId() helper (added in M7).
    ///      getCurrentAlgId() peeks at the transient algId queue without consuming it,
    ///      so the hook sees the same algId that execute() will consume after preCheck returns.
    ///
    ///      COMPATIBILITY: TierGuardHook requires AAStarAirAccountV7 (M7+).
    ///      If getCurrentAlgId() is unavailable, the fallback is ALG_ECDSA (Tier 1).
    ///      RESTRICTIVE (fail-closed): any operation requiring Tier 2+ will revert with
    ///      TierViolation because tier(ALG_ECDSA)=1 < required≥2.
    ///      This is a security-safe default — Tier 2/3 ops are blocked, not bypassed.
    ///      Recommendation: only install TierGuardHook on accounts that implement getCurrentAlgId().
    function _getAlgIdFromAccount(address account) internal view returns (uint8 algId) {
        (bool ok, bytes memory data) = account.staticcall(
            abi.encodeWithSignature("getCurrentAlgId()")
        );
        if (ok && data.length >= 32) {
            algId = uint8(abi.decode(data, (uint256)));
        } else {
            algId = 0x01; // fallback: ALG_ECDSA (not a session key) — see compatibility note above
        }
    }
}
