// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title SocialRecovery Tests
/// @notice Comprehensive tests for the social recovery (F28) features in AAStarAirAccountBase
contract SocialRecoveryTest is Test {
    AAStarAirAccountV7 account;

    address entryPointAddr = makeAddr("entryPoint");
    address ownerAddr = makeAddr("owner");
    address guardian1 = makeAddr("guardian1");
    address guardian2 = makeAddr("guardian2");
    address guardian3 = makeAddr("guardian3");
    address guardian4 = makeAddr("guardian4");
    address newOwnerAddr = makeAddr("newOwner");
    address randomAddr = makeAddr("random");

    // Re-declare events for expectEmit
    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount);
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event RecoveryCancelVoted(address indexed votedBy, uint256 cancelCount);
    event RecoveryCancelled();
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    function setUp() public {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7();
        account.initialize(entryPointAddr, ownerAddr, config);

    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _addThreeGuardians() internal {
        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1);
        account.addGuardian(guardian2);
        account.addGuardian(guardian3);
        vm.stopPrank();
    }

    function _proposeRecoveryFromGuardian1() internal {
        vm.prank(guardian1);
        account.proposeRecovery(newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1. addGuardian: owner adds guardian successfully
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_ownerAddsSuccessfully() public {
        vm.prank(ownerAddr);

        vm.expectEmit(true, true, false, false);
        emit GuardianAdded(0, guardian1);

        account.addGuardian(guardian1);

        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardianCount(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 2. addGuardian: non-owner reverts with NotOwner
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_nonOwnerReverts() public {
        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.addGuardian(guardian1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 3. addGuardian: max 3 guardians, 4th reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_maxThreeGuardians() public {
        _addThreeGuardians();
        assertEq(account.guardianCount(), 3);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("MaxGuardiansReached()"));
        account.addGuardian(guardian4);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 4. addGuardian: duplicate reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_duplicateReverts() public {
        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1);

        vm.expectRevert(abi.encodeWithSignature("GuardianAlreadySet()"));
        account.addGuardian(guardian1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 5–6. addGuardian: zero address / owner address reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_zeroAddressReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.addGuardian(address(0));
    }

    function test_addGuardian_ownerAddressReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.addGuardian(ownerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 7. removeGuardian: removes and shifts correctly
    // ═══════════════════════════════════════════════════════════════════

    function test_removeGuardian_shiftsCorrectly() public {
        _addThreeGuardians();

        vm.prank(ownerAddr);
        vm.expectEmit(true, true, false, false);
        emit GuardianRemoved(0, guardian1);
        account.removeGuardian(0);

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian2);
        assertEq(account.guardians(1), guardian3);
        assertEq(account.guardians(2), address(0));
    }

    function test_removeGuardian_removesMiddle() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        account.removeGuardian(1);

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardians(1), guardian3);
    }

    function test_removeGuardian_removesLast() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        account.removeGuardian(2);

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardians(1), guardian2);
    }

    function test_removeGuardian_invalidIndexReverts() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.removeGuardian(3);
    }

    function test_removeGuardian_nonOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.removeGuardian(0);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 8. removeGuardian: cancels active recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_removeGuardian_cancelsActiveRecovery() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        (address proposedNewOwner,,,) = account.activeRecovery();
        assertEq(proposedNewOwner, newOwnerAddr);

        vm.prank(ownerAddr);
        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();
        account.removeGuardian(2);

        (address clearedOwner,,,) = account.activeRecovery();
        assertEq(clearedOwner, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 9. proposeRecovery: guardian proposes, auto-approves
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_guardianProposesWithAutoApproval() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        vm.expectEmit(true, true, false, false);
        emit RecoveryProposed(newOwnerAddr, guardian1);
        vm.expectEmit(true, true, false, true);
        emit RecoveryApproved(newOwnerAddr, guardian1, 1);
        account.proposeRecovery(newOwnerAddr);

        (address proposed, uint256 proposedAt, uint256 bitmap,) = account.activeRecovery();
        assertEq(proposed, newOwnerAddr);
        assertEq(proposedAt, block.timestamp);
        assertEq(bitmap, 1); // bit 0 set
    }

    // ═══════════════════════════════════════════════════════════════════
    // 10–13. proposeRecovery: revert cases
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_nonGuardianReverts() public {
        _addThreeGuardians();
        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.proposeRecovery(newOwnerAddr);
    }

    function test_proposeRecovery_zeroNewOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        account.proposeRecovery(address(0));
    }

    function test_proposeRecovery_currentOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        account.proposeRecovery(ownerAddr);
    }

    function test_proposeRecovery_alreadyActiveReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        vm.expectRevert(abi.encodeWithSignature("RecoveryAlreadyActive()"));
        account.proposeRecovery(newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 14. approveRecovery: second guardian approves
    // ═══════════════════════════════════════════════════════════════════

    function test_approveRecovery_secondGuardianApproves() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        vm.expectEmit(true, true, false, true);
        emit RecoveryApproved(newOwnerAddr, guardian2, 2);
        account.approveRecovery();

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(bitmap, 3); // bit 0 + bit 1
    }

    // ═══════════════════════════════════════════════════════════════════
    // 15–16. approveRecovery: revert cases
    // ═══════════════════════════════════════════════════════════════════

    function test_approveRecovery_sameGuardianTwiceReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyApproved()"));
        account.approveRecovery();
    }

    function test_approveRecovery_noActiveRecoveryReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        account.approveRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 17. executeRecovery: works after timelock + 2 approvals
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_successAfterTimelockAndThreshold() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();

        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, false, false);
        emit RecoveryExecuted(ownerAddr, newOwnerAddr);
        vm.expectEmit(true, true, false, false);
        emit OwnerChanged(ownerAddr, newOwnerAddr);

        account.executeRecovery();

        assertEq(account.owner(), newOwnerAddr);
        (address cleared,,,) = account.activeRecovery();
        assertEq(cleared, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 18–20. executeRecovery: revert cases
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_revertsBeforeTimelock() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();
        vm.prank(guardian2);
        account.approveRecovery();

        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(abi.encodeWithSignature("RecoveryTimelockNotExpired()"));
        account.executeRecovery();
    }

    function test_executeRecovery_revertsWithInsufficientApprovals() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSignature("RecoveryNotApproved()"));
        account.executeRecovery();
    }

    function test_executeRecovery_revertsNoActiveRecovery() public {
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        account.executeRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 21. Full recovery flow
    // ═══════════════════════════════════════════════════════════════════

    function test_fullRecoveryFlow() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        account.proposeRecovery(newOwnerAddr);

        (address proposed,,,) = account.activeRecovery();
        assertEq(proposed, newOwnerAddr);

        vm.prank(guardian3);
        account.approveRecovery();

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(bitmap, 5); // bit 0 + bit 2

        vm.warp(block.timestamp + 2 days);

        vm.prank(randomAddr);
        account.executeRecovery();

        assertEq(account.owner(), newOwnerAddr);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.addGuardian(makeAddr("newGuardian"));

        vm.startPrank(newOwnerAddr);
        account.removeGuardian(0);
        account.addGuardian(makeAddr("newGuardian"));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 22. cancelRecovery: requires 2-of-3 guardians (same as recovery)
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_singleGuardianNotEnough() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        // One guardian votes to cancel — not enough
        vm.prank(guardian2);
        vm.expectEmit(true, false, false, true);
        emit RecoveryCancelVoted(guardian2, 1);
        account.cancelRecovery();

        // Recovery still active
        (address stillActive,,,) = account.activeRecovery();
        assertEq(stillActive, newOwnerAddr);
    }

    function test_cancelRecovery_twoGuardiansCancels() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        // First guardian votes to cancel
        vm.prank(guardian2);
        account.cancelRecovery();

        // Second guardian votes — reaches 2-of-3 threshold → cancellation happens
        vm.prank(guardian3);
        vm.expectEmit(true, false, false, true);
        emit RecoveryCancelVoted(guardian3, 2);
        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();
        account.cancelRecovery();

        // Recovery is cancelled
        (address cleared,,,) = account.activeRecovery();
        assertEq(cleared, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 23. cancelRecovery: owner CANNOT cancel
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_ownerReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 24. cancelRecovery: non-guardian can't cancel
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_nonGuardianReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 25. cancelRecovery: no active recovery reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_noActiveRecoveryReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 26. cancelRecovery: same guardian can't vote twice
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_sameGuardianTwiceReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.cancelRecovery();

        vm.prank(guardian2);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCancelVoted()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 27. executeRecovery: all 3 guardians approve
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_allThreeGuardiansApprove() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();
        vm.prank(guardian3);
        account.approveRecovery();

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(bitmap, 7); // 0b111

        vm.warp(block.timestamp + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 28. executeRecovery: exact timelock boundary
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_exactTimelockBoundary() public {
        _addThreeGuardians();
        uint256 proposalTime = block.timestamp;
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();

        vm.warp(proposalTime + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 29. Second recovery after first
    // ═══════════════════════════════════════════════════════════════════

    function test_secondRecoveryAfterFirst() public {
        _addThreeGuardians();

        vm.warp(1000);
        _proposeRecoveryFromGuardian1();
        vm.prank(guardian2);
        account.approveRecovery();
        vm.warp(1000 + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), newOwnerAddr);

        address secondNewOwner = makeAddr("secondNewOwner");
        vm.warp(1000 + 3 days);
        vm.prank(guardian1);
        account.proposeRecovery(secondNewOwner);
        vm.prank(guardian3);
        account.approveRecovery();
        vm.warp(1000 + 5 days);
        account.executeRecovery();
        assertEq(account.owner(), secondNewOwner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 30. Stolen key cannot block recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_stolenKey_cannotBlockRecovery() public {
        _addThreeGuardians();

        _proposeRecoveryFromGuardian1();
        vm.prank(guardian2);
        account.approveRecovery();

        // Thief tries to cancel — not a guardian
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.cancelRecovery();

        // Recovery succeeds
        vm.warp(block.timestamp + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 31. Cancel and re-propose
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelAndRepropose() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        // 2 guardians cancel
        vm.prank(guardian1);
        account.cancelRecovery();
        vm.prank(guardian2);
        account.cancelRecovery();

        (address cleared,,,) = account.activeRecovery();
        assertEq(cleared, address(0));

        // Re-propose with different owner
        address anotherOwner = makeAddr("anotherOwner");
        vm.prank(guardian2);
        account.proposeRecovery(anotherOwner);
        vm.prank(guardian3);
        account.approveRecovery();

        vm.warp(block.timestamp + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), anotherOwner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 32. Cancel race: cancel votes don't persist across proposals
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelBitmapClearedOnNewProposal() public {
        _addThreeGuardians();

        // First proposal
        _proposeRecoveryFromGuardian1();

        // One cancel vote (not enough)
        vm.prank(guardian2);
        account.cancelRecovery();

        // Remove guardian to force-cancel via removeGuardian (resets everything)
        vm.prank(ownerAddr);
        account.removeGuardian(2); // cancels recovery, removes guardian3

        // Add back a guardian
        vm.prank(ownerAddr);
        account.addGuardian(guardian3);

        // New proposal — cancel bitmap should be fresh
        vm.prank(guardian1);
        account.proposeRecovery(newOwnerAddr);

        (,,, uint256 cancelBitmap) = account.activeRecovery();
        assertEq(cancelBitmap, 0); // Clean slate
    }
}
