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
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;
        guard = new AAStarGlobalGuard(account, DAILY_LIMIT, algIds, DAILY_LIMIT / 10);
    }

    // ─── 1. Constructor ────────────────────────────────────────────────

    function test_constructor_setsAccountAndDailyLimit() public view {
        assertEq(guard.account(), account);
        assertEq(guard.dailyLimit(), DAILY_LIMIT);
    }

    function test_constructor_setsApprovedAlgorithms() public view {
        assertTrue(guard.approvedAlgorithms(ALG_ECDSA));
        assertFalse(guard.approvedAlgorithms(ALG_BLS));
    }

    function test_constructor_multipleAlgorithms() public {
        uint8[] memory algIds = new uint8[](3);
        algIds[0] = ALG_ECDSA;
        algIds[1] = ALG_BLS;
        algIds[2] = ALG_P256;
        AAStarGlobalGuard g = new AAStarGlobalGuard(account, DAILY_LIMIT, algIds, DAILY_LIMIT / 10);
        assertTrue(g.approvedAlgorithms(ALG_ECDSA));
        assertTrue(g.approvedAlgorithms(ALG_BLS));
        assertTrue(g.approvedAlgorithms(ALG_P256));
    }

    // ─── 2. approveAlgorithm (add-only) ──────────────────────────────

    function test_approveAlgorithm_accountCanApprove() public {
        vm.prank(account);
        vm.expectEmit(true, false, false, false);
        emit AAStarGlobalGuard.AlgorithmApproved(ALG_BLS);
        guard.approveAlgorithm(ALG_BLS);
        assertTrue(guard.approvedAlgorithms(ALG_BLS));
    }

    function test_approveAlgorithm_nonAccountReverts() public {
        vm.prank(nonAccount);
        vm.expectRevert(AAStarGlobalGuard.OnlyAccount.selector);
        guard.approveAlgorithm(ALG_BLS);
    }

    // ─── 3. decreaseDailyLimit (monotonic) ───────────────────────────

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
        guard.checkTransaction(0.1 ether, ALG_ECDSA);
    }

    // ─── 5. checkTransaction: algorithm whitelist ────────────────────

    function test_checkTransaction_approvedAlgPasses() public {
        vm.prank(account);
        bool ok = guard.checkTransaction(0.1 ether, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_unapprovedAlgReverts() public {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.AlgorithmNotApproved.selector, ALG_BLS));
        guard.checkTransaction(0.1 ether, ALG_BLS);
    }

    // ─── 6. checkTransaction: within daily limit ────────────────────

    function test_checkTransaction_withinLimitPasses() public {
        vm.prank(account);
        bool ok = guard.checkTransaction(0.5 ether, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_exactLimitPasses() public {
        vm.prank(account);
        bool ok = guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertTrue(ok);
    }

    // ─── 7. checkTransaction: exceeding daily limit ─────────────────

    function test_checkTransaction_exceedingLimitReverts() public {
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 1.1 ether, DAILY_LIMIT)
        );
        guard.checkTransaction(1.1 ether, ALG_ECDSA);
    }

    // ─── 8. Multiple transactions accumulate daily spending ─────────

    function test_checkTransaction_accumulatesSpending() public {
        vm.startPrank(account);
        guard.checkTransaction(0.3 ether, ALG_ECDSA);
        guard.checkTransaction(0.3 ether, ALG_ECDSA);
        guard.checkTransaction(0.3 ether, ALG_ECDSA);
        vm.stopPrank();

        // 0.9 ether spent, only 0.1 ether remaining
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 0.2 ether, 0.1 ether)
        );
        guard.checkTransaction(0.2 ether, ALG_ECDSA);
    }

    function test_checkTransaction_emitsSpendRecorded() public {
        uint256 today = block.timestamp / 1 days;
        vm.prank(account);
        vm.expectEmit(true, false, false, true);
        emit AAStarGlobalGuard.SpendRecorded(today, 0.5 ether, 0.5 ether);
        guard.checkTransaction(0.5 ether, ALG_ECDSA);
    }

    // ─── 9. remainingDailyAllowance ─────────────────────────────────

    function test_remainingDailyAllowance_fullAtStart() public view {
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    function test_remainingDailyAllowance_decreasesAfterSpend() public {
        vm.prank(account);
        guard.checkTransaction(0.4 ether, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0.6 ether);
    }

    function test_remainingDailyAllowance_zeroAfterFullSpend() public {
        vm.prank(account);
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0);
    }

    // ─── 10. Daily limit resets next day ─────────────────────────────

    function test_dailyLimitResetsNextDay() public {
        vm.prank(account);
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0);

        vm.warp(block.timestamp + 1 days);

        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);

        vm.prank(account);
        bool ok = guard.checkTransaction(0.5 ether, ALG_ECDSA);
        assertTrue(ok);
        assertEq(guard.remainingDailyAllowance(), 0.5 ether);
    }

    // ─── 11. Zero value transactions always pass limit check ────────

    function test_checkTransaction_zeroValueAlwaysPasses() public {
        vm.prank(account);
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);

        vm.prank(account);
        bool ok = guard.checkTransaction(0, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_zeroValueDoesNotAccumulate() public {
        vm.prank(account);
        guard.checkTransaction(0, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    // ─── 12. Zero dailyLimit means unlimited ────────────────────────

    function test_unlimitedWhenDailyLimitIsZero() public {
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_ECDSA;
        AAStarGlobalGuard unlimitedGuard = new AAStarGlobalGuard(account, 0, algIds, 0);

        vm.prank(account);
        bool ok = unlimitedGuard.checkTransaction(1000 ether, ALG_ECDSA);
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
