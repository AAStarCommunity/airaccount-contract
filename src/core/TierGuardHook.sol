// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IERC7579Hook} from "../interfaces/IERC7579Module.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";

/// @title TierGuardHook — ERC-7579 Hook module wrapping AirAccount's tier/guard enforcement
/// @notice When installed as a Hook(3) module on an AAStarAirAccountV7, this hook reads the
///         account's guard contract and algId from transient storage, then enforces spending limits.
/// @dev The hook is called by the account in execute() BEFORE the actual call.
///      For accounts using this hook, guard enforcement moves from inline _enforceGuard to this module.
///
///      Architecture note: This hook is complementary to the account's built-in guard.
///      If both are active, both will enforce. The account should disable its own inline guard
///      enforcement when this hook is active (not yet implemented — M7.2+).
///
///      algId reading: The account stores algId in transient storage (ALG_ID_SLOT_BASE queue)
///      before calling preCheck. The hook calls back to the account's _consumeValidatedAlgId()
///      via a standardized interface. For simplicity in this implementation, algId defaults to
///      ALG_ECDSA if the callback is unavailable.
///
///      Session scope enforcement (M8.P2): When an AgentSessionKeyValidator address is configured
///      via the extended onInstall format, preCheck additionally enforces callTargets and
///      selectorAllowlist for ALG_SESSION_KEY operations by calling enforceSessionScope().
contract TierGuardHook is IERC7579Hook {
    /// @dev Per-account guard address mapping (set at install time)
    mapping(address => address) public accountGuard;

    /// @dev Per-account tier1/tier2 limits (set at install time)
    mapping(address => uint256) public accountTier1;
    mapping(address => uint256) public accountTier2;

    /// @dev Per-account AgentSessionKeyValidator address for session scope enforcement (M8.P2).
    ///      If set, preCheck enforces callTargets/selectorAllowlist for ALG_SESSION_KEY ops.
    mapping(address => address) public accountAgentValidator;

    error TierGuardHookUnauthorized();
    error TierViolation(uint8 required, uint8 provided);
    error UnknownAlgId(uint8 algId);

    // ALG constants (mirrors AAStarAirAccountBase)
    uint8 internal constant ALG_ECDSA          = 0x02;
    uint8 internal constant ALG_P256           = 0x03;
    uint8 internal constant ALG_CUMULATIVE_T2  = 0x04;
    uint8 internal constant ALG_CUMULATIVE_T3  = 0x05;
    uint8 internal constant ALG_WEIGHTED       = 0x07;
    uint8 internal constant ALG_BLS            = 0x01;
    uint8 internal constant ALG_COMBINED_T1    = 0x06;
    uint8 internal constant ALG_SESSION_KEY    = 0x08;

    // ─── IERC7579Module ─────────────────────────────────────────────

    /// @notice Install hook for msg.sender account.
    /// @param data abi.encode(guardAddress, tier1Limit, tier2Limit) — 3-param (96 bytes, backward compatible)
    ///        OR abi.encode(guardAddress, tier1Limit, tier2Limit, agentSessionKeyValidator) — 4-param (128 bytes).
    ///        The 4-param format enables session scope enforcement via AgentSessionKeyValidator (M8.P2).
    function onInstall(bytes calldata data) external override {
        if (data.length == 0) return; // no-op if no init data
        if (data.length >= 128) {
            // Extended 4-param format: includes agentSessionKeyValidator address
            (address guardAddr, uint256 t1, uint256 t2, address agentValidator) =
                abi.decode(data, (address, uint256, uint256, address));
            accountGuard[msg.sender] = guardAddr;
            accountTier1[msg.sender] = t1;
            accountTier2[msg.sender] = t2;
            accountAgentValidator[msg.sender] = agentValidator;
        } else {
            // Original 3-param format (backward compatible)
            (address guardAddr, uint256 t1, uint256 t2) = abi.decode(data, (address, uint256, uint256));
            accountGuard[msg.sender] = guardAddr;
            accountTier1[msg.sender] = t1;
            accountTier2[msg.sender] = t2;
        }
    }

    function onUninstall(bytes calldata /* data */) external override {
        delete accountGuard[msg.sender];
        delete accountTier1[msg.sender];
        delete accountTier2[msg.sender];
        delete accountAgentValidator[msg.sender];
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return accountGuard[smartAccount] != address(0);
    }

    // ─── IERC7579Hook ────────────────────────────────────────────────

    /// @notice Pre-execution check: enforce tier + daily limit + session scope (M8.P2).
    /// @param msgSender The original msg.sender of the execute() call (unused — msg.sender is the account)
    /// @param msgValue The ETH value being sent
    /// @param msgData The full execute() calldata forwarded by the account.
    ///        Layout: [4B execute selector][32B dest padded][32B value][32B func-offset][32B func-len][func...]
    ///        dest  = address(uint160(uint256(bytes32(msgData[4:36]))))
    ///        inner selector = bytes4(msgData[132:136]) when func.length >= 4
    /// @return hookData Empty bytes (no post-check state needed)
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external override returns (bytes memory hookData) {
        // Suppress unused variable warning
        msgSender;

        address guardAddr = accountGuard[msg.sender];
        if (guardAddr == address(0)) return ""; // no guard configured

        // Get algId from account's transient storage via callback
        uint8 algId = _getAlgIdFromAccount(msg.sender);
        uint8 tier = _algTier(algId);

        // ETH tier check
        uint256 t1 = accountTier1[msg.sender];
        uint256 t2 = accountTier2[msg.sender];
        if (t1 > 0 || t2 > 0) {
            uint256 alreadySpent;
            try AAStarGlobalGuard(guardAddr).todaySpent() returns (uint256 spent) {
                alreadySpent = spent;
            } catch {}
            uint8 required = _requiredTier(alreadySpent + msgValue, t1, t2);
            if (required > 0 && tier < required) {
                revert TierViolation(required, tier);
            }
        }

        // Daily limit check
        try AAStarGlobalGuard(guardAddr).checkTransaction(msgValue, algId) {} catch {
            revert TierGuardHookUnauthorized();
        }

        // ── Session scope enforcement (M8.P2) ─────────────────────────────────
        // When an AgentSessionKeyValidator is configured and the operation uses ALG_SESSION_KEY,
        // enforce callTargets and selectorAllowlist constraints that were set at session grant time.
        // This closes the gap where AgentSessionKeyValidator only validated during validateUserOp
        // but did not enforce scope during execute().
        address agentValidator = accountAgentValidator[msg.sender];
        if (agentValidator != address(0) && algId == ALG_SESSION_KEY) {
            bytes32 taggedSessionKey = _getSessionKeyFromAccount(msg.sender);
            if (taggedSessionKey != bytes32(0)) {
                uint8 sessionType = uint8(uint256(taggedSessionKey) >> 248);
                if (sessionType == 0x01) {
                    address sessionKey = address(uint160(uint256(taggedSessionKey)));
                    // Parse dest and inner selector from the forwarded execute() calldata.
                    // msgData = full execute() calldata (including the 4-byte selector):
                    //   [0:4]    execute() selector (bytes4)
                    //   [4:36]   dest (address padded to 32 bytes)
                    //   [36:68]  value (uint256)
                    //   [68:100] ABI offset for func bytes (= 0x60 relative to arg start = 96)
                    //   [100:132] func data length
                    //   [132:]   func bytes (inner calldata)
                    // Inner call selector = first 4 bytes of func: msgData[132:136]
                    address dest;
                    bytes4 selector;
                    if (msgData.length >= 36) {
                        dest = address(uint160(uint256(bytes32(msgData[4:36]))));
                    }
                    if (msgData.length >= 136) {
                        selector = bytes4(msgData[132:136]);
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
            algId = ALG_ECDSA; // fallback: Tier 1 limits — see compatibility note above
        }
    }

    /// @dev Peek at the session key from the account's transient queue via getCurrentSessionKey().
    ///      Returns bytes32(0) if the account does not implement getCurrentSessionKey() or queue is empty.
    ///      Top byte: 0x01 = ECDSA session (lower 20 bytes = session key address).
    function _getSessionKeyFromAccount(address account) internal view returns (bytes32 taggedId) {
        (bool ok, bytes memory data) = account.staticcall(
            abi.encodeWithSignature("getCurrentSessionKey()")
        );
        if (ok && data.length >= 32) {
            taggedId = abi.decode(data, (bytes32));
        }
    }

    function _algTier(uint8 algId) internal pure returns (uint8) {
        if (algId == ALG_CUMULATIVE_T3 || algId == ALG_BLS) return 3;
        if (algId == ALG_CUMULATIVE_T2 || algId == ALG_WEIGHTED) return 2; // weighted multisig = at least Tier 2
        if (algId == ALG_ECDSA || algId == ALG_P256 || algId == ALG_COMBINED_T1 || algId == ALG_SESSION_KEY) return 1;
        revert UnknownAlgId(algId);
    }

    function _requiredTier(uint256 amount, uint256 t1, uint256 t2) internal pure returns (uint8) {
        if (t1 == 0 && t2 == 0) return 0;
        if (amount <= t1) return 1;
        if (amount <= t2) return 2;
        return 3;
    }
}
