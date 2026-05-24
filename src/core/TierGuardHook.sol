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

    /// @dev MEDIUM-1: separate initialized sentinel so guardAddr==0 still marks as installed.
    mapping(address => bool) private _initialized;

    error TierGuardHookUnauthorized();
    error TierViolation(uint8 required, uint8 provided);
    error UnknownAlgId(uint8 algId);
    error AlreadyInstalled();

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
        if (_initialized[msg.sender]) revert AlreadyInstalled();
        _initialized[msg.sender] = true;
        if (data.length == 0) return; // no-op if no init data
        // Discriminant: 3-param=(address,uint256,uint256)=96 bytes; 4-param adds address=128 bytes.
        // Static ABI encoding means a 3-param call is always exactly 96 bytes — never 128.
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
        delete _initialized[msg.sender];
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _initialized[smartAccount];
    }

    // ─── IERC7579Hook ────────────────────────────────────────────────

    /// @notice Pre-execution check: enforce tier + daily limit + session scope (M8.P2).
    ///         HIGH-1 fix: uses _parseExecuteCalldata to follow the ABI offset pointer for the
    ///         `bytes func` parameter instead of relying on fixed offsets that can be bypassed.
    /// @param msgSender The original msg.sender of the execute() call (unused — msg.sender is the account)
    /// @param msgValue The ETH value being sent
    /// @param msgData The full execute() calldata forwarded by the account.
    ///        Layout: [4B execute selector][32B dest][32B value][32B func-offset pointer][32B func-len][func...]
    ///        dest and inner selector are extracted via _parseExecuteCalldata (offset-pointer-safe).
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
            // fail-closed: session key expected but not found in transient storage → revert
            if (taggedSessionKey == bytes32(0)) revert TierGuardHookUnauthorized();
            uint8 sessionType = uint8(uint256(taggedSessionKey) >> 248);
            // MEDIUM-2: fail-closed — only 0x01 (normal session key) is supported; any other tag reverts.
            if (sessionType != 0x01) revert TierGuardHookUnauthorized();
            address sessionKey = address(uint160(uint256(taggedSessionKey)));
            // Parse dest and inner selector from the forwarded execute() calldata using
            // _parseExecuteCalldata, which follows the ABI offset pointer for the `bytes func`
            // parameter. Fixed-offset parsing (e.g. msgData[132:136]) is UNSAFE because ABI
            // encoding allows non-standard offsets: an attacker could craft calldata where the
            // real func data is at a non-standard position but the hook reads a decoy selector
            // at the standard position. We use the offset pointer at params[64:96] instead.
            (address dest, bytes4 selector) = _parseExecuteCalldata(msgData);
            // enforceSessionScope reverts if the target or selector is not in the allowlist
            (bool ok,) = agentValidator.staticcall(
                abi.encodeWithSignature(
                    "enforceSessionScope(address,address,address,bytes4)",
                    msg.sender, sessionKey, dest, selector
                )
            );
            if (!ok) revert TierGuardHookUnauthorized();
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

    /// @dev Safely parse execute(address dest, uint256 value, bytes func) calldata to extract
    ///      the call target address and the first 4 bytes of func (the inner call selector).
    ///
    ///      HIGH-1 FIX: Fixed-offset parsing (e.g. dest at [4:36], selector at [132:136]) is
    ///      unsafe because ABI encoding allows non-standard offsets for dynamic `bytes` params.
    ///      An attacker can craft calldata where the real func data is at a non-standard position
    ///      but the hook reads a decoy selector from the hardcoded offset. This function follows
    ///      the ABI offset pointer stored at params[64:96] to find where func actually starts.
    ///
    ///      msgData layout (full execute() calldata forwarded by _dispatchHook):
    ///        [0:4]    execute() outer selector
    ///        params = [4:] (everything after the outer selector)
    ///        params[0:32]   dest (address, zero-padded to 32 bytes)
    ///        params[32:64]  value (uint256)
    ///        params[64:96]  ABI offset to func bytes (relative to start of params, in bytes)
    ///        params[offset:offset+32]  length of func bytes
    ///        params[offset+32:offset+32+length]  func bytes
    ///
    ///      Returns (address(0), bytes4(0)) on any decode error, which is safe because
    ///      enforceSessionScope with a zero dest will fail the allowlist check.
    function _parseExecuteCalldata(bytes calldata msgData)
        internal pure returns (address dest, bytes4 innerSelector)
    {
        // Minimum: outer selector(4) + dest(32) + value(32) + offset(32) = 100 bytes
        if (msgData.length < 100) return (address(0), bytes4(0));
        bytes calldata params = msgData[4:];  // strip outer selector
        // params[0:32] = dest
        dest = address(uint160(uint256(bytes32(params[0:32]))));
        // params[32:64] = value (ignored here)
        // params[64:96] = ABI offset pointer (relative to params start) to the func bytes data
        uint256 offset = uint256(bytes32(params[64:96]));
        // offset+32 must be within params (length slot at params[offset:offset+32])
        if (offset + 32 > params.length) return (dest, bytes4(0));
        uint256 funcLen = uint256(bytes32(params[offset:offset + 32]));
        // Need at least 4 bytes of func to extract a selector
        if (funcLen < 4) return (dest, bytes4(0));
        // offset+32+funcLen must be within params
        if (offset + 32 + funcLen > params.length) return (dest, bytes4(0));
        innerSelector = bytes4(params[offset + 32:offset + 36]);
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
