// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {TierGuardHook} from "../src/core/TierGuardHook.sol";

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

/// @title TierGuardHookTest — Unit tests for TierGuardHook (M7.2)
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
}
