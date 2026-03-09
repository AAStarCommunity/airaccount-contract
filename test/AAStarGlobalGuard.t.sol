// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/core/AAStarGlobalGuard.sol";

contract AAStarGlobalGuardTest is Test {
    AAStarGlobalGuard guard;
    address owner = address(0xA11CE);
    address nonOwner = address(0xB0B);
    uint256 constant DAILY_LIMIT = 1 ether;
    uint8 constant ALG_ECDSA = 1;
    uint8 constant ALG_WEBAUTHN = 2;
    uint8 constant ALG_BLS = 3;

    function setUp() public {
        guard = new AAStarGlobalGuard(owner, DAILY_LIMIT);
        // Approve a default algorithm for most tests
        vm.prank(owner);
        guard.approveAlgorithm(ALG_ECDSA);
    }

    // ─── 1. Constructor ────────────────────────────────────────────────

    function test_constructor_setsOwnerAndDailyLimit() public view {
        assertEq(guard.owner(), owner);
        assertEq(guard.dailyLimit(), DAILY_LIMIT);
    }

    // ─── 2. setDailyLimit ──────────────────────────────────────────────

    function test_setDailyLimit_ownerCanSet() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit AAStarGlobalGuard.DailyLimitSet(DAILY_LIMIT, 2 ether);
        guard.setDailyLimit(2 ether);
        assertEq(guard.dailyLimit(), 2 ether);
    }

    function test_setDailyLimit_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(AAStarGlobalGuard.OnlyOwner.selector);
        guard.setDailyLimit(2 ether);
    }

    // ─── 3. approveAlgorithm ───────────────────────────────────────────

    function test_approveAlgorithm_ownerCanApprove() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit AAStarGlobalGuard.AlgorithmApproved(ALG_WEBAUTHN);
        guard.approveAlgorithm(ALG_WEBAUTHN);
        assertTrue(guard.approvedAlgorithms(ALG_WEBAUTHN));
    }

    function test_approveAlgorithm_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(AAStarGlobalGuard.OnlyOwner.selector);
        guard.approveAlgorithm(ALG_WEBAUTHN);
    }

    // ─── 4. revokeAlgorithm ────────────────────────────────────────────

    function test_revokeAlgorithm_ownerCanRevoke() public {
        // First approve, then revoke
        vm.startPrank(owner);
        guard.approveAlgorithm(ALG_WEBAUTHN);
        vm.expectEmit(true, false, false, false);
        emit AAStarGlobalGuard.AlgorithmRevoked(ALG_WEBAUTHN);
        guard.revokeAlgorithm(ALG_WEBAUTHN);
        vm.stopPrank();
        assertFalse(guard.approvedAlgorithms(ALG_WEBAUTHN));
    }

    function test_revokeAlgorithm_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(AAStarGlobalGuard.OnlyOwner.selector);
        guard.revokeAlgorithm(ALG_ECDSA);
    }

    // ─── 5. checkTransaction: algorithm whitelist ──────────────────────

    function test_checkTransaction_approvedAlgPasses() public {
        bool ok = guard.checkTransaction(0.1 ether, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_unapprovedAlgReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.AlgorithmNotApproved.selector, ALG_BLS));
        guard.checkTransaction(0.1 ether, ALG_BLS);
    }

    // ─── 6. checkTransaction: within daily limit ───────────────────────

    function test_checkTransaction_withinLimitPasses() public {
        bool ok = guard.checkTransaction(0.5 ether, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_exactLimitPasses() public {
        bool ok = guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertTrue(ok);
    }

    // ─── 7. checkTransaction: exceeding daily limit ────────────────────

    function test_checkTransaction_exceedingLimitReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 1.1 ether, DAILY_LIMIT)
        );
        guard.checkTransaction(1.1 ether, ALG_ECDSA);
    }

    // ─── 8. Multiple transactions accumulate daily spending ────────────

    function test_checkTransaction_accumulatesSpending() public {
        guard.checkTransaction(0.3 ether, ALG_ECDSA);
        guard.checkTransaction(0.3 ether, ALG_ECDSA);
        guard.checkTransaction(0.3 ether, ALG_ECDSA);

        // 0.9 ether spent, only 0.1 ether remaining
        vm.expectRevert(
            abi.encodeWithSelector(AAStarGlobalGuard.DailyLimitExceeded.selector, 0.2 ether, 0.1 ether)
        );
        guard.checkTransaction(0.2 ether, ALG_ECDSA);
    }

    function test_checkTransaction_emitsSpendRecorded() public {
        uint256 today = block.timestamp / 1 days;
        vm.expectEmit(true, false, false, true);
        emit AAStarGlobalGuard.SpendRecorded(today, 0.5 ether, 0.5 ether);
        guard.checkTransaction(0.5 ether, ALG_ECDSA);
    }

    // ─── 9. remainingDailyAllowance ────────────────────────────────────

    function test_remainingDailyAllowance_fullAtStart() public view {
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    function test_remainingDailyAllowance_decreasesAfterSpend() public {
        guard.checkTransaction(0.4 ether, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0.6 ether);
    }

    function test_remainingDailyAllowance_zeroAfterFullSpend() public {
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0);
    }

    // ─── 10. Daily limit resets next day ───────────────────────────────

    function test_dailyLimitResetsNextDay() public {
        // Spend full limit today
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), 0);

        // Warp forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Allowance should be fully reset
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);

        // Should be able to spend again
        bool ok = guard.checkTransaction(0.5 ether, ALG_ECDSA);
        assertTrue(ok);
        assertEq(guard.remainingDailyAllowance(), 0.5 ether);
    }

    // ─── 11. Zero value transactions always pass limit check ───────────

    function test_checkTransaction_zeroValueAlwaysPasses() public {
        // Exhaust the daily limit
        guard.checkTransaction(DAILY_LIMIT, ALG_ECDSA);

        // Zero value should still pass even with no remaining allowance
        bool ok = guard.checkTransaction(0, ALG_ECDSA);
        assertTrue(ok);
    }

    function test_checkTransaction_zeroValueDoesNotAccumulate() public {
        guard.checkTransaction(0, ALG_ECDSA);
        assertEq(guard.remainingDailyAllowance(), DAILY_LIMIT);
    }

    // ─── 12. Zero dailyLimit means unlimited ───────────────────────────

    function test_unlimitedWhenDailyLimitIsZero() public {
        // Deploy a guard with 0 daily limit
        AAStarGlobalGuard unlimitedGuard = new AAStarGlobalGuard(owner, 0);
        vm.prank(owner);
        unlimitedGuard.approveAlgorithm(ALG_ECDSA);

        // Should allow any amount
        bool ok = unlimitedGuard.checkTransaction(1000 ether, ALG_ECDSA);
        assertTrue(ok);

        // remainingDailyAllowance returns type(uint256).max
        assertEq(unlimitedGuard.remainingDailyAllowance(), type(uint256).max);
    }

    function test_setDailyLimitToZeroMakesUnlimited() public {
        vm.prank(owner);
        guard.setDailyLimit(0);

        // Should allow any amount
        bool ok = guard.checkTransaction(1000 ether, ALG_ECDSA);
        assertTrue(ok);
        assertEq(guard.remainingDailyAllowance(), type(uint256).max);
    }
}
