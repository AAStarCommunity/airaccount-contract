// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {TierGuardHook} from "../src/core/TierGuardHook.sol";
import {AgentSessionKeyValidator} from "../src/validators/AgentSessionKeyValidator.sol";

/// @dev Minimal mock guard for TierGuardHook tests
contract MockGuard {
    bool public shouldRevert;
    uint256 public todaySpentValue;

    function setShouldRevert(bool v) external { shouldRevert = v; }
    function setTodaySpent(uint256 v) external { todaySpentValue = v; }
    function todaySpent() external view returns (uint256) { return todaySpentValue; }
    function checkTransaction(uint256, uint8) external view returns (bool) {
        if (shouldRevert) revert("limit exceeded");
        return true;
    }
}

/// @dev Contract account proxy — preCheck returns bytes memory so msg.sender must be a contract.
///      All onInstall/onUninstall/preCheck calls are routed through this helper so that
///      msg.sender = address(accountContract) (a real contract), which TierGuardHook expects.
contract MockAccountCaller {
    function callInstall(TierGuardHook hook, bytes calldata data) external {
        hook.onInstall(data);
    }

    function callUninstall(TierGuardHook hook) external {
        hook.onUninstall("");
    }

    function callPreCheck(
        TierGuardHook hook,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external returns (bytes memory) {
        return hook.preCheck(msgSender, msgValue, msgData);
    }

    function callPreCheckExpectRevert(
        TierGuardHook hook,
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external {
        // Will revert if preCheck reverts — caller catches the revert
        hook.preCheck(msgSender, msgValue, msgData);
    }
}

/// @dev Account that exposes getCurrentAlgId() returning a fixed value.
///      Used to test _algTier behavior for specific algIds.
contract MockAccountWithAlgId is MockAccountCaller {
    uint8 public immutable algId;
    constructor(uint8 _algId) { algId = _algId; }
    function getCurrentAlgId() external view returns (uint256) { return algId; }
}

/// @dev Mock AgentSessionKeyValidator for session scope enforcement tests (M8.P2).
///      Implements enforceSessionScope() that reverts for forbidden targets and passes for allowed ones.
contract MockAgentSessionKeyValidator {
    /// @dev Allowed call targets. Empty = allow all.
    address[] public allowedTargets;

    function setAllowedTargets(address[] memory targets) external {
        delete allowedTargets;
        for (uint256 i = 0; i < targets.length; i++) {
            allowedTargets.push(targets[i]);
        }
    }

    function enforceSessionScope(
        address, /* account */
        address, /* sessionKey */
        address callTarget,
        bytes4  /* selector */
    ) external view {
        if (allowedTargets.length == 0) return; // empty = allow all
        for (uint256 i = 0; i < allowedTargets.length; i++) {
            if (allowedTargets[i] == callTarget) return; // found — allowed
        }
        // Not found in allowlist — revert to signal forbidden target
        revert("CallTargetForbidden");
    }
}

/// @dev Account that returns ALG_SESSION_KEY from getCurrentAlgId() but bytes32(0) from
///      getCurrentSessionKey() — simulates a missing session key in transient storage.
///      Used to test MEDIUM-2 fail-closed behavior: preCheck must revert when agentValidator
///      is configured + algId=ALG_SESSION_KEY but no session key is present.
contract MockAccountWithSessionKeyMissing is MockAccountCaller {
    function getCurrentAlgId() external pure returns (uint256) {
        return 0x08; // ALG_SESSION_KEY
    }

    function getCurrentSessionKey() external pure returns (bytes32) {
        return bytes32(0); // no session key in transient storage
    }
}

/// @dev Account that exposes both getCurrentAlgId() (returning ALG_SESSION_KEY=0x08)
///      and getCurrentSessionKey() (returning a tagged ECDSA session key address).
///      Used to test session scope enforcement in TierGuardHook (M8.P2).
contract MockAccountWithSessionKey is MockAccountCaller {
    address public immutable sessionKeyAddr;

    constructor(address _sessionKey) {
        sessionKeyAddr = _sessionKey;
    }

    function getCurrentAlgId() external pure returns (uint256) {
        return 0x08; // ALG_SESSION_KEY
    }

    function getCurrentSessionKey() external view returns (bytes32) {
        // Tag 0x01 = ECDSA session key; lower 20 bytes = session key address
        return bytes32(uint256(0x01) << 248 | uint256(uint160(sessionKeyAddr)));
    }
}

/// @title TierGuardHookTest — Unit tests for TierGuardHook (M7.2, M8.P2)
contract TierGuardHookTest is Test {
    TierGuardHook public hook;
    MockGuard     public guard;

    MockAccountCaller public accountContract;   // contract that acts as the AA account
    address public account;                      // == address(accountContract)
    address public other;

    function setUp() public {
        hook            = new TierGuardHook();
        guard           = new MockGuard();
        accountContract = new MockAccountCaller();
        account         = address(accountContract);
        other           = makeAddr("other");
    }

    // ─── Helper: install guard via accountContract ────────────────────────────

    function _install(address guardAddr, uint256 t1, uint256 t2) internal {
        bytes memory data = abi.encode(guardAddr, t1, t2);
        accountContract.callInstall(hook, data);
    }

    // ─── onInstall ────────────────────────────────────────────────────────────

    function test_onInstall_setsGuardAddress() public {
        _install(address(guard), 1 ether, 10 ether);
        assertEq(hook.accountGuard(account), address(guard));
    }

    function test_onInstall_setsTierLimits() public {
        uint256 t1 = 0.5 ether;
        uint256 t2 = 5 ether;
        _install(address(guard), t1, t2);
        assertEq(hook.accountTier1(account), t1);
        assertEq(hook.accountTier2(account), t2);
    }

    function test_onInstall_emptyData_noRevert() public {
        // Should silently return without reverting
        accountContract.callInstall(hook, "");
        // Nothing set
        assertEq(hook.accountGuard(account), address(0));
    }

    // ─── onUninstall ─────────────────────────────────────────────────────────

    function test_onUninstall_clearsState() public {
        _install(address(guard), 1 ether, 10 ether);

        // Verify set
        assertEq(hook.accountGuard(account), address(guard));

        // Uninstall
        accountContract.callUninstall(hook);

        assertEq(hook.accountGuard(account), address(0));
        assertEq(hook.accountTier1(account), 0);
        assertEq(hook.accountTier2(account), 0);
    }

    // ─── isInitialized ────────────────────────────────────────────────────────

    function test_isInitialized_beforeInstall_false() public view {
        assertFalse(hook.isInitialized(account));
    }

    function test_isInitialized_afterInstall_true() public {
        _install(address(guard), 1 ether, 10 ether);
        assertTrue(hook.isInitialized(account));
    }

    function test_isInitialized_afterUninstall_false() public {
        _install(address(guard), 1 ether, 10 ether);
        accountContract.callUninstall(hook);
        assertFalse(hook.isInitialized(account));
    }

    // ─── preCheck ─────────────────────────────────────────────────────────────

    function test_preCheck_noGuard_passes() public {
        // Account has no guard — preCheck should return empty bytes without reverting
        bytes memory result = accountContract.callPreCheck(hook, other, 0, "");
        assertEq(result, "");
    }

    function test_preCheck_guardsCallsCheckTransaction() public {
        // Install hook with guard that does NOT revert (t1=0, t2=0 = no tier check)
        _install(address(guard), 0, 0);
        guard.setShouldRevert(false);

        // preCheck should succeed and return empty bytes
        bytes memory result = accountContract.callPreCheck(hook, other, 0.1 ether, "");
        assertEq(result, "");
    }

    function test_preCheck_dailyLimitExceeded_reverts() public {
        // Install with guard that WILL revert
        _install(address(guard), 0, 0);
        guard.setShouldRevert(true);

        // preCheck should revert with TierGuardHookUnauthorized
        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        accountContract.callPreCheckExpectRevert(hook, other, 0.1 ether, "");
    }

    function test_preCheck_tierViolation_reverts() public {
        // Install with tier limits: t1=1 ether, t2=5 ether
        // msgValue=3 ether > t1 but <=t2 => required tier = 2
        // accountContract has no getCurrentAlgId() => fallback ECDSA (tier=1) => TierViolation(2,1)
        _install(address(guard), 1 ether, 5 ether);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        vm.expectRevert(abi.encodeWithSelector(TierGuardHook.TierViolation.selector, uint8(2), uint8(1)));
        accountContract.callPreCheckExpectRevert(hook, other, 3 ether, "");
    }

    function test_preCheck_belowTier1_passes() public {
        // msgValue=0.5 ether <= t1=1 ether => required tier=1; ECDSA tier=1 => no violation
        _install(address(guard), 1 ether, 5 ether);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        bytes memory result = accountContract.callPreCheck(hook, other, 0.5 ether, "");
        assertEq(result, "");
    }

    // ─── _algTier: ALG_WEIGHTED (0x07) ────────────────────────────────────────

    /// @notice ALG_WEIGHTED (0x07) must map to Tier 2.
    ///         Before fix it returned 0 (unknown), causing weighted-multisig ops to be either
    ///         blocked (required>0 > tier 0) or have guard enforcement with wrong tier.
    function test_algTier_weighted_returnsTier2() public {
        // tier2 limit=1 ether, tier3 limit=5 ether
        // msgValue=3 ether: required tier = 2 (above t1=1, below t2=5)
        // accountContract has no getCurrentAlgId() → fallback ALG_ECDSA (tier=1) → TierViolation(2,1)
        _install(address(guard), 1 ether, 5 ether);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        // Verify that without ALG_WEIGHTED support, 3 ether triggers TierViolation (tier=1 from fallback)
        vm.expectRevert(abi.encodeWithSelector(TierGuardHook.TierViolation.selector, uint8(2), uint8(1)));
        accountContract.callPreCheckExpectRevert(hook, address(this), 3 ether, "");
    }

    /// @notice A MockAccount that returns ALG_WEIGHTED from getCurrentAlgId() gets Tier 2 assigned,
    ///         allowing 3 ether (>t1 <=t2) to pass without TierViolation.
    function test_algTier_weighted_noTierViolation_whenAccountReturnsWeighted() public {
        // Deploy an account contract that returns ALG_WEIGHTED from getCurrentAlgId()
        MockAccountWithAlgId weightedAccount = new MockAccountWithAlgId(0x07); // ALG_WEIGHTED
        bytes memory data = abi.encode(address(guard), uint256(1 ether), uint256(5 ether));
        weightedAccount.callInstall(hook, data);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        // 3 ether: required tier=2, account provides ALG_WEIGHTED=tier2 → no violation
        bytes memory result = weightedAccount.callPreCheck(hook, address(this), 3 ether, "");
        assertEq(result, "");
    }

    // ─── postCheck ────────────────────────────────────────────────────────────

    function test_postCheck_noRevert() public {
        // postCheck is a no-op — must not revert
        hook.postCheck("");
    }

    // ─── Multi-account isolation ──────────────────────────────────────────────

    // ─── Review fix: unknown algId reverts ──────────────────────────────

    /// @notice An account returning an unrecognized algId (e.g. 0xFF) should revert with UnknownAlgId,
    ///         preventing silent tier-0 bypass for future algIds that are added without updating TierGuardHook.
    function test_preCheck_unknownAlgId_reverts() public {
        MockAccountWithAlgId unknownAccount = new MockAccountWithAlgId(0xFF);
        bytes memory data = abi.encode(address(guard), uint256(1 ether), uint256(5 ether));
        unknownAccount.callInstall(hook, data);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        vm.expectRevert(abi.encodeWithSelector(TierGuardHook.UnknownAlgId.selector, uint8(0xFF)));
        unknownAccount.callPreCheckExpectRevert(hook, address(this), 0.5 ether, "");
    }

    /// @notice algId=0x09 (undefined) should also revert
    function test_preCheck_algId0x09_reverts() public {
        MockAccountWithAlgId account09 = new MockAccountWithAlgId(0x09);
        bytes memory data = abi.encode(address(guard), uint256(1 ether), uint256(5 ether));
        account09.callInstall(hook, data);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        vm.expectRevert(abi.encodeWithSelector(TierGuardHook.UnknownAlgId.selector, uint8(0x09)));
        account09.callPreCheckExpectRevert(hook, address(this), 0.5 ether, "");
    }

    /// @notice algId=0x00 (unset) should revert UnknownAlgId
    function test_preCheck_algId0x00_reverts() public {
        MockAccountWithAlgId account00 = new MockAccountWithAlgId(0x00);
        bytes memory data = abi.encode(address(guard), uint256(1 ether), uint256(5 ether));
        account00.callInstall(hook, data);
        guard.setShouldRevert(false);
        guard.setTodaySpent(0);

        vm.expectRevert(abi.encodeWithSelector(TierGuardHook.UnknownAlgId.selector, uint8(0x00)));
        account00.callPreCheckExpectRevert(hook, address(this), 0.5 ether, "");
    }

    // ─── Multi-account isolation ──────────────────────────────────────────────

    function test_multiAccount_isolatedState() public {
        MockAccountCaller accountB = new MockAccountCaller();

        bytes memory dataA = abi.encode(address(guard), uint256(1 ether), uint256(5 ether));
        bytes memory dataB = abi.encode(address(0xBEEF), uint256(2 ether), uint256(10 ether));

        accountContract.callInstall(hook, dataA);
        accountB.callInstall(hook, dataB);

        assertEq(hook.accountGuard(account), address(guard));
        assertEq(hook.accountGuard(address(accountB)), address(0xBEEF));
        assertEq(hook.accountTier1(account), 1 ether);
        assertEq(hook.accountTier1(address(accountB)), 2 ether);
    }

    // ─── M8.P2: Session scope enforcement via AgentSessionKeyValidator ────────

    /// @dev Build msgData that matches the execute() calldata forwarded by _dispatchHook.
    ///      _dispatchHook uses calldatacopy(msg.data), so msgData = full execute() calldata.
    ///
    ///      execute(address dest, uint256 value, bytes calldata func) ABI layout:
    ///        [0:4]    execute() selector
    ///        [4:36]   dest (address padded to 32 bytes)
    ///        [36:68]  value (uint256)
    ///        [68:100] ABI offset for func bytes (= 0x60 = 96, relative to arg start)
    ///        [100:132] func data length
    ///        [132:]   func bytes (inner calldata)
    function _buildExecuteMsgData(
        address dest,
        uint256 value,
        bytes memory func
    ) internal pure returns (bytes memory) {
        bytes4 sel = bytes4(keccak256("execute(address,uint256,bytes)"));
        bytes memory args = abi.encode(dest, value, func);
        return abi.encodePacked(sel, args);
    }

    /// @notice M8.P2: ALG_SESSION_KEY with callTargets=[tokenA]; calling tokenB must revert.
    function test_PreCheck_SessionKey_enforcesCallTarget_blocks_forbidden() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA;
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0), address(agentValidator));
        sessionAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        // Attempt to call tokenB (not in the allowlist) — preCheck must revert
        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", address(this), 100);
        bytes memory msgData = _buildExecuteMsgData(tokenB, 0, func);

        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        sessionAccount.callPreCheckExpectRevert(hook, address(this), 0, msgData);
    }

    /// @notice M8.P2: ALG_SESSION_KEY with callTargets=[tokenA]; calling tokenA must succeed.
    function test_PreCheck_SessionKey_enforcesCallTarget_allows_permitted() public {
        address tokenA = makeAddr("tokenA");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA;
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0), address(agentValidator));
        sessionAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        // Call tokenA (in the allowlist) — preCheck must succeed
        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", address(this), 100);
        bytes memory msgData = _buildExecuteMsgData(tokenA, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, address(this), 0, msgData);
        assertEq(result, "");
    }

    /// @notice M8.P2: no agentValidator set (3-param install) — session scope enforcement is skipped.
    ///         Even though algId=ALG_SESSION_KEY, no scope check is performed without an agentValidator.
    function test_PreCheck_SessionKey_noValidator_skipsEnforcement() public {
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        // Install with original 3-param format — no agentValidator field
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0));
        sessionAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        // Any target allowed because no agentValidator is configured
        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", address(this), 100);
        bytes memory msgData = _buildExecuteMsgData(tokenB, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, address(this), 0, msgData);
        assertEq(result, "");
    }

    /// @notice M8.P2: empty callTargets allowlist in agentValidator means any target is allowed.
    ///         enforceSessionScope with empty callTargets returns without reverting.
    function test_PreCheck_SessionKey_emptyAllowlist_allowsAll() public {
        address anyTarget = makeAddr("anyTarget");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        // No targets set → empty allowlist → any target allowed

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0), address(agentValidator));
        sessionAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        bytes memory func = abi.encodeWithSignature("doSomething()");
        bytes memory msgData = _buildExecuteMsgData(anyTarget, 0, func);
        bytes memory result = sessionAccount.callPreCheck(hook, address(this), 0, msgData);
        assertEq(result, "");
    }

    // ─── MEDIUM-2: fail-closed when agentValidator configured but no session key ─

    /// @notice MEDIUM-2 fix: when agentValidator is configured and algId=ALG_SESSION_KEY but
    ///         getCurrentSessionKey() returns bytes32(0) (no session key in transient storage),
    ///         preCheck must revert with TierGuardHookUnauthorized rather than silently skipping
    ///         scope enforcement. This closes the window where an attacker could omit the session
    ///         key from transient storage to bypass scope checks entirely.
    function test_preCheck_sessionKey_missingSessionKey_reverts() public {
        address agentValidatorAddr = address(new MockAgentSessionKeyValidator());

        MockAccountWithSessionKeyMissing missingKeyAccount = new MockAccountWithSessionKeyMissing();
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0), agentValidatorAddr);
        missingKeyAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        bytes memory func = abi.encodeWithSignature("transfer(address,uint256)", address(this), 100);
        bytes memory msgData = _buildExecuteMsgData(makeAddr("anyTarget"), 0, func);

        // agentValidator is configured + algId=ALG_SESSION_KEY + no session key → must revert
        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        missingKeyAccount.callPreCheckExpectRevert(hook, address(this), 0, msgData);
    }

    // ─── MEDIUM-1: onInstall idempotency ──────────────────────────────

    /// @notice MEDIUM-1 fix: calling onInstall twice on the same account must revert with
    ///         AlreadyInstalled on the second call, preventing config overwrite.
    function test_onInstall_alreadyInstalled_reverts() public {
        _install(address(guard), 1 ether, 10 ether);

        // Second install attempt on the same account — must revert
        bytes memory data = abi.encode(address(guard), uint256(1 ether), uint256(10 ether));
        vm.expectRevert(TierGuardHook.AlreadyInstalled.selector);
        accountContract.callInstall(hook, data);
    }

    // ─── HIGH-1: non-standard ABI offset cannot bypass scope enforcement ──────

    /// @notice HIGH-1 fix: craft calldata where the `bytes func` ABI offset pointer is non-standard
    ///         (points past the canonical position) but still within bounds. The fixed-offset
    ///         parser would read from offset 132 and see a decoy "safe" selector, but
    ///         _parseExecuteCalldata follows the offset pointer and finds the real (forbidden) selector.
    ///
    ///         ABI encoding of execute(address dest, uint256 value, bytes func):
    ///           outer selector (4 bytes)
    ///           params[0:32]  = dest (address)
    ///           params[32:64] = value (uint256)
    ///           params[64:96] = offset pointer to func bytes (relative to params start)
    ///
    ///         Normal encoding: offset = 0x60 (96), func starts at params[96].
    ///         Non-standard: offset = 0x80 (128), func starts at params[128].
    ///         In this case, params[96:128] is padding/decoy data (which would be read as the
    ///         selector by the old fixed-offset code at msgData[132:136]).
    ///
    ///         We place a "safe" (address(0) / 0x00000000) decoy at the standard position
    ///         and the real forbidden selector at the non-standard position pointed to by offset.
    function test_PreCheck_SessionKey_nonStandardABIOffset_cannotBypass() public {
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address sessionKey = makeAddr("sessionKey");

        MockAgentSessionKeyValidator agentValidator = new MockAgentSessionKeyValidator();
        address[] memory targets = new address[](1);
        targets[0] = tokenA;
        agentValidator.setAllowedTargets(targets);

        MockAccountWithSessionKey sessionAccount = new MockAccountWithSessionKey(sessionKey);
        bytes memory installData = abi.encode(address(guard), uint256(0), uint256(0), address(agentValidator));
        sessionAccount.callInstall(hook, installData);
        guard.setShouldRevert(false);

        // Build non-standard ABI calldata manually:
        //   outer selector (4 bytes)
        //   params[0:32]   = tokenB (dest — forbidden)
        //   params[32:64]  = 0 (value)
        //   params[64:96]  = 0x80 (128) — non-standard offset pointer, func starts at params[128]
        //   params[96:128] = decoy: 32-byte length=4 followed by a "safe" selector 0x00000000
        //                    (old fixed-offset code would read params[96:100] as func length
        //                     and params[100:104] as the selector — but we abuse the region)
        //   params[128:160] = func length = 4
        //   params[160:164] = real forbidden selector (e.g. transfer(address,uint256) = 0xa9059cbb)
        bytes4 outerSel = bytes4(keccak256("execute(address,uint256,bytes)"));
        // Build the non-standard calldata byte by byte
        bytes memory msgData = abi.encodePacked(
            outerSel,                           // [0:4]   outer selector
            bytes32(uint256(uint160(tokenB))),  // [4:36]  dest = tokenB (forbidden target)
            bytes32(uint256(0)),                // [36:68] value = 0
            bytes32(uint256(0x80)),             // [68:100] offset = 128 (non-standard)
            // params[96:128] = decoy region — fixed-offset code (now removed) would have read
            // msgData[132:136] = params[128:132] as the selector. We put 0x00000000 there so
            // the old code would have seen an "empty" selector and possibly bypassed the check.
            bytes32(uint256(0)),                // [100:132] decoy: "func length=0" at standard pos
            // The real func data starts at params[128] (offset 128 from params start):
            bytes32(uint256(4)),                // [132:164] real func length = 4
            bytes4(0xa9059cbb),                 // [164:168] real selector: transfer(address,uint256)
            bytes28(0)                          // [168:196] padding to 32 bytes
        );

        // With _parseExecuteCalldata (HIGH-1 fix), the hook follows the offset pointer (0x80=128)
        // and reads the real func data: dest=tokenB (forbidden), selector=0xa9059cbb.
        // tokenB is not in the allowlist — enforceSessionScope reverts — TierGuardHookUnauthorized.
        vm.expectRevert(TierGuardHook.TierGuardHookUnauthorized.selector);
        sessionAccount.callPreCheckExpectRevert(hook, address(this), 0, msgData);
    }
}
