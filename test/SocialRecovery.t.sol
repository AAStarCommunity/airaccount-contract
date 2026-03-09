// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";

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
    event RecoveryCancelled();
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    function setUp() public {
        account = new AAStarAirAccountV7(entryPointAddr, ownerAddr);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    /// @dev Add 3 guardians as owner
    function _addThreeGuardians() internal {
        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1);
        account.addGuardian(guardian2);
        account.addGuardian(guardian3);
        vm.stopPrank();
    }

    /// @dev Propose recovery from guardian1
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
    // 3. addGuardian: max 3 guardians, 4th reverts with MaxGuardiansReached
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_maxThreeGuardians() public {
        _addThreeGuardians();
        assertEq(account.guardianCount(), 3);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("MaxGuardiansReached()"));
        account.addGuardian(guardian4);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 4. addGuardian: duplicate guardian reverts with GuardianAlreadySet
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_duplicateReverts() public {
        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1);

        vm.expectRevert(abi.encodeWithSignature("GuardianAlreadySet()"));
        account.addGuardian(guardian1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 5. addGuardian: zero address reverts with InvalidGuardian
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_zeroAddressReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.addGuardian(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 6. addGuardian: owner address reverts with InvalidGuardian
    // ═══════════════════════════════════════════════════════════════════

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

        // Remove guardian at index 0 (guardian1), expect shift
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

        // Remove guardian at index 1 (guardian2)
        vm.prank(ownerAddr);
        account.removeGuardian(1);

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardians(1), guardian3);
    }

    function test_removeGuardian_removesLast() public {
        _addThreeGuardians();

        // Remove guardian at index 2 (guardian3)
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

        // Verify recovery is active
        (address proposedNewOwner,,) = account.activeRecovery();
        assertEq(proposedNewOwner, newOwnerAddr);

        // Remove a guardian — should cancel recovery
        vm.prank(ownerAddr);

        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();

        account.removeGuardian(2);

        // Verify recovery is cancelled
        (address clearedOwner,,) = account.activeRecovery();
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

        (address proposed, uint256 proposedAt, uint256 bitmap) = account.activeRecovery();
        assertEq(proposed, newOwnerAddr);
        assertEq(proposedAt, block.timestamp);
        // guardian1 is index 0, so bit 0 should be set
        assertEq(bitmap, 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 10. proposeRecovery: non-guardian reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_nonGuardianReverts() public {
        _addThreeGuardians();

        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.proposeRecovery(newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 11. proposeRecovery: newOwner=0 reverts with InvalidNewOwner
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_zeroNewOwnerReverts() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        account.proposeRecovery(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 12. proposeRecovery: newOwner=currentOwner reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_currentOwnerReverts() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        account.proposeRecovery(ownerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 13. proposeRecovery: second proposal while active reverts
    // ═══════════════════════════════════════════════════════════════════

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

        (,, uint256 bitmap) = account.activeRecovery();
        // bit 0 (guardian1) + bit 1 (guardian2) = 3
        assertEq(bitmap, 3);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 15. approveRecovery: same guardian can't approve twice
    // ═══════════════════════════════════════════════════════════════════

    function test_approveRecovery_sameGuardianTwiceReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyApproved()"));
        account.approveRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 16. approveRecovery: no active recovery reverts
    // ═══════════════════════════════════════════════════════════════════

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

        // Second approval
        vm.prank(guardian2);
        account.approveRecovery();

        // Warp past timelock (2 days)
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, false, false);
        emit RecoveryExecuted(ownerAddr, newOwnerAddr);

        vm.expectEmit(true, true, false, false);
        emit OwnerChanged(ownerAddr, newOwnerAddr);

        account.executeRecovery();

        assertEq(account.owner(), newOwnerAddr);

        // Active recovery should be cleared
        (address cleared,,) = account.activeRecovery();
        assertEq(cleared, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 18. executeRecovery: reverts before timelock
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_revertsBeforeTimelock() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();

        // Warp to just before timelock expires
        vm.warp(block.timestamp + 2 days - 1);

        vm.expectRevert(abi.encodeWithSignature("RecoveryTimelockNotExpired()"));
        account.executeRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 19. executeRecovery: reverts with only 1 approval
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_revertsWithInsufficientApprovals() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        // Only 1 approval (from proposer), warp past timelock
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSignature("RecoveryNotApproved()"));
        account.executeRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 20. executeRecovery: reverts with no active recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_revertsNoActiveRecovery() public {
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        account.executeRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 21. Full recovery flow: propose -> approve -> warp -> execute
    // ═══════════════════════════════════════════════════════════════════

    function test_fullRecoveryFlow() public {
        // Step 1: Owner adds 3 guardians
        _addThreeGuardians();
        assertEq(account.guardianCount(), 3);

        // Step 2: Guardian1 proposes recovery (auto-approves)
        vm.prank(guardian1);
        account.proposeRecovery(newOwnerAddr);

        (address proposed,,) = account.activeRecovery();
        assertEq(proposed, newOwnerAddr);

        // Step 3: Guardian3 approves (now 2/3 threshold met)
        vm.prank(guardian3);
        account.approveRecovery();

        (,, uint256 bitmap) = account.activeRecovery();
        // bit 0 (guardian1) + bit 2 (guardian3) = 5
        assertEq(bitmap, 5);

        // Step 4: Warp past timelock
        vm.warp(block.timestamp + 2 days);

        // Step 5: Anyone can execute
        vm.prank(randomAddr);
        account.executeRecovery();

        // Step 6: Verify owner changed
        assertEq(account.owner(), newOwnerAddr);

        // Step 7: Old owner can no longer call owner-only functions
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.addGuardian(makeAddr("newGuardian"));

        // Step 8: New owner can call owner-only functions (remove one first to make room)
        vm.startPrank(newOwnerAddr);
        account.removeGuardian(0);
        account.addGuardian(makeAddr("newGuardian"));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 22. cancelRecovery: owner cancels
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_ownerCancels() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(ownerAddr);

        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();

        account.cancelRecovery();

        (address cleared,,) = account.activeRecovery();
        assertEq(cleared, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 23. cancelRecovery: non-owner can't cancel
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_nonOwnerReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 24. cancelRecovery: reverts when no active recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_noActiveRecoveryReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        account.cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 25. executeRecovery: works with all 3 guardians approving
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_allThreeGuardiansApprove() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();

        vm.prank(guardian3);
        account.approveRecovery();

        (,, uint256 bitmap) = account.activeRecovery();
        // All 3 bits set: 0b111 = 7
        assertEq(bitmap, 7);

        vm.warp(block.timestamp + 2 days);
        account.executeRecovery();

        assertEq(account.owner(), newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 26. executeRecovery: exact timelock boundary (at exactly 2 days)
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_exactTimelockBoundary() public {
        _addThreeGuardians();

        uint256 proposalTime = block.timestamp;
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        account.approveRecovery();

        // Warp to exactly 2 days (should succeed since check is <, not <=)
        vm.warp(proposalTime + 2 days);
        account.executeRecovery();

        assertEq(account.owner(), newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 27. Recovery after recovery: can do a second recovery after first
    // ═══════════════════════════════════════════════════════════════════

    function test_secondRecoveryAfterFirst() public {
        _addThreeGuardians();

        // First recovery
        vm.warp(1000);
        _proposeRecoveryFromGuardian1();
        vm.prank(guardian2);
        account.approveRecovery();
        vm.warp(1000 + 2 days);
        account.executeRecovery();
        assertEq(account.owner(), newOwnerAddr);

        // Second recovery: propose a different new owner
        address secondNewOwner = makeAddr("secondNewOwner");
        vm.warp(1000 + 3 days); // Move forward a bit
        vm.prank(guardian1);
        account.proposeRecovery(secondNewOwner);

        vm.prank(guardian3);
        account.approveRecovery();

        vm.warp(1000 + 5 days); // 2 days after second proposal
        account.executeRecovery();

        assertEq(account.owner(), secondNewOwner);
    }
}
