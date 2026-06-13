// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/core/AAStarGlobalGuard.sol";

contract AAStarGlobalGuardTest is Test {
    AAStarGlobalGuard guard;
    address account = address(0xA11CE); // simulates the AA account contract
    address nonAccount = address(0xB0B);
    uint256 constant DAILY_LIMIT = 1 ether;
    uint8 constant ALG_BLS = 0x01;
    uint8 constant ALG_ECDSA = 0x02;
    uint8 constant ALG_P256 = 0x03;

    function setUp() public {
        guard = new AAStarGlobalGuard(account, DAILY_LIMIT, DAILY_LIMIT / 10, new address[](0), new AAStarGlobalGuard.TokenConfig[](0));
    }

    // ─── 1. Constructor ────────────────────────────────────────────────

    function test_constructor_setsAccountAndDailyLimit() public view {
        assertEq(guard.account(), account);
        assertEq(guard.dailyLimit(), DAILY_LIMIT);
    }

    // v0.17.2-beta.4: the algorithm whitelist + approveAlgorithm moved off the guard onto the
    // account. Those behaviors are covered by test/Beta4AlgIdBundlerFix.t.sol
    // (test_whitelist_populatedOnAccountFromConfig, test_guardApproveAlgorithm_writesAccountNotGuard,
    // test_validateUserOp_rejectsNonWhitelistedAlg). The guard is now pure accounting.

    // ─── decreaseDailyLimit (monotonic) ───────────────────────────

    function test_decreaseDailyLimit_accountCanDecrease() public {
        vm.prank(account);
        vm.expectEmit(false, false, false, true);
        emit AAStarGlobalGuard.DailyLimitDecreased(DAILY_LIMIT, 0.5 ether);
        guard.decreaseDailyLimit(0.5 ether);
        assertEq(guard.dailyLimit(), 0.5 ether);
    }

    function test_decreaseDailyLimit_cannotIncrease() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.CanOnlyDecreaseLimit.selector, DAILY_LIMIT, 2 ether)
        );
        guard.decreaseDailyLimit(2 ether);
    }

    function test_decreaseDailyLimit_cannotSetSameValue() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.CanOnlyDecreaseLimit.selector, DAILY_LIMIT, DAILY_LIMIT)
        );
        guard.decreaseDailyLimit(DAILY_LIMIT);
    }

    function test_decreaseDailyLimit_nonAccountReverts() public {
        vm.prank(nonAccount);
        vm.expectRevert(AAStarGlobalGuard.OnlyAccount.selector);
        guard.decreaseDailyLimit(0.5 ether);
    }

    // ─── 4. checkTransaction: onlyAccount access control ─────────────

    function test_checkTransaction_nonAccountReverts() public {
        vm.prank(nonAccount);
        vm.expectRevert(AAStarGlobalGuard.OnlyAccount.selector);
        guard.recordSpend(0.1 ether);
    }

    // ─── 5. checkTransaction: algorithm whitelist ────────────────────

    function test_checkTransaction_approvedAlgPasses() public {
        vm.prank(account);
        bool ok = guard.recordSpend(0.1 ether);
        assertTrue(ok);
    }

    // (whitelist-revert removed: enforced in validateUserOp now — see Beta4AlgIdBundlerFix.t.sol)

    // ─── checkTransaction: within daily limit ────────────────────

    function test_checkTransaction_withinLimitPasses() public {
        vm.prank(account);
        bool ok = guard.recordSpend(0.5 ether);
        assertTrue(ok);
    }

    function test_checkTransaction_exactLimitPasses() public {
        vm.prank(account);
        bool ok = guard.recordSpend(DAILY_LIMIT);
        assertTrue(ok);
    }

    // ─── 7. checkTransaction: exceeding daily limit ─────────────────

    function test_checkTransaction_exceedingLimitReverts() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 1.1 ether, DAILY_LIMIT)
        );
        guard.recordSpend(1.1 ether);
    }

    // ─── 8. Multiple transactions accumulate daily spending ─────────

    function test_checkTransaction_accumulatesSpending() public {
        vm.startPrank(account);
        guard.recordSpend(0.3 ether);
        guard.recordSpend(0.3 ether);
        guard.recordSpend(0.3 ether);
        vm.stopPrank();

        // 0.9 ether spent, only 0.1 ether remaining
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 0.2 ether, 0.1 ether)
        );
        guard.recordSpend(0.2 ether);
    }

    function test_checkTransaction_emitsSpendRecorded() public {
        uint256 today = block.timestamp / 1 days;
        vm.prank(account);
        vm.expectEmit(true, false, false, true);
        emit AAStarGlobalGuard.SpendRecorded(today, 0.5 ether, 0.5 ether);
        guard.recordSpend(0.5 ether);
    }

    // ─── 9. remainingDailyAllowance ─────────────────────────────────

    function test_remainingDailyAllowance_fullAtStart() public view {
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    function test_remainingDailyAllowance_decreasesAfterSpend() public {
        vm.prank(account);
        guard.recordSpend(0.4 ether);
        assertEq(guard.remainingDailyAllowance(), 0.6 ether);
    }

    function test_remainingDailyAllowance_zeroAfterFullSpend() public {
        vm.prank(account);
        guard.recordSpend(DAILY_LIMIT);
        assertEq(guard.remainingDailyAllowance(), 0);
    }

    // ─── 10. Daily limit resets next day ─────────────────────────────

    function test_dailyLimitResetsNextDay() public {
        vm.prank(account);
        guard.recordSpend(DAILY_LIMIT);
        assertEq(guard.remainingDailyAllowance(), 0);

        vm.warp(block.timestamp + 1 days);

        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);

        vm.prank(account);
        bool ok = guard.recordSpend(0.5 ether);
        assertTrue(ok);
        assertEq(guard.remainingDailyAllowance(), 0.5 ether);
    }

    // ─── 11. Zero value transactions always pass limit check ────────

    function test_checkTransaction_zeroValueAlwaysPasses() public {
        vm.prank(account);
        guard.recordSpend(DAILY_LIMIT);

        vm.prank(account);
        bool ok = guard.recordSpend(0);
        assertTrue(ok);
    }

    function test_checkTransaction_zeroValueDoesNotAccumulate() public {
        vm.prank(account);
        guard.recordSpend(0);
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    // ─── 12. Zero dailyLimit means unlimited ────────────────────────

    function test_unlimitedWhenDailyLimitIsZero() public {
        AAStarGlobalGuard unlimitedGuard = new AAStarGlobalGuard(account, 0, 0, new address[](0), new AAStarGlobalGuard.TokenConfig[](0));

        vm.prank(account);
        bool ok = unlimitedGuard.recordSpend(1000 ether);
        assertTrue(ok);

        assertEq(unlimitedGuard.remainingDailyAllowance(), type(uint256).max);
    }

    // ─── 13. Account immutability ───────────────────────────────────

    function test_accountIsImmutable() public view {
        assertEq(guard.account(), account);
    }

    // ─── 14. Monotonic decrease chain ───────────────────────────────

    function test_decreaseChain() public {
        vm.startPrank(account);
        guard.decreaseDailyLimit(0.8 ether);
        guard.decreaseDailyLimit(0.5 ether);
        guard.decreaseDailyLimit(0.1 ether);
        vm.stopPrank();

        assertEq(guard.dailyLimit(), 0.1 ether);

        // Cannot go back up
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.CanOnlyDecreaseLimit.selector, 0.1 ether, 0.5 ether)
        );
        guard.decreaseDailyLimit(0.5 ether);
    }
}
