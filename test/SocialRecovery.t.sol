// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title SocialRecovery Tests
/// @notice Comprehensive tests for the social recovery (F28) features in AAStarAirAccountBase
interface IAirAccountRecovery { function proposeRecovery(address newOwner) external; function approveRecovery() external; function executeRecovery() external; function cancelRecovery() external; }

contract SocialRecoveryTest is Test {
    AAStarAirAccountV7 account;

    address entryPointAddr = makeAddr("entryPoint");
    address ownerAddr = makeAddr("owner");
    // Private keys match makeAddr derivation: vm.addr(uint256(keccak256(abi.encodePacked(name))))
    uint256 guardian1Key = uint256(keccak256(abi.encodePacked("guardian1")));
    uint256 guardian2Key = uint256(keccak256(abi.encodePacked("guardian2")));
    uint256 guardian3Key = uint256(keccak256(abi.encodePacked("guardian3")));
    address guardian1 = makeAddr("guardian1");
    address guardian2 = makeAddr("guardian2");
    address guardian3 = makeAddr("guardian3");
    address guardian4 = makeAddr("guardian4");
    address newOwnerAddr = makeAddr("newOwner");
    address randomAddr = makeAddr("random");

    // Re-declare events for expectEmit
    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy, uint8 guardianIdx);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount, uint8 guardianIdx);
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event RecoveryCancelVoted(address indexed votedBy, uint256 cancelCount, uint8 guardianIdx);
    event RecoveryCancelled();
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    function setUp() public {
        uint8[] memory noAlgs = new uint8[](0);
        // Init with all 3 guardians — post-init guardian additions require guardian consensus.
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [guardian1, guardian2, guardian3],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerAddr, config, address(0), bytes32(0), bytes32(0));
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    // No-op: setUp now initializes 3 guardians directly via InitConfig.
    function _addThreeGuardians() internal {}

    // Creates a fresh account with no guardians — use in tests that exercise bootstrap addGuardian.
    function _resetToEmptyAccount() internal {
        uint8[] memory noAlgs = new uint8[](0);
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerAddr, AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }), address(0), bytes32(0), bytes32(0));
    }

    // Signs an ADD_GUARDIAN op for addGuardianWithMixedSigs.
    function _signAddition(uint256 privKey, address guardianAddr, uint256 nonce) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "ADD_GUARDIAN",
            abi.encode(nonce, guardianAddr)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, MessageHashUtils.toEthSignedMessageHash(h));
        return abi.encodePacked(r, s, v);
    }

    // GUARDIAN_SIG_VERSION (issue #84) — mirror of the internal constant in AAStarAirAccountBase.
    uint8 internal constant GUARDIAN_SIG_VERSION = 4;

    // #120 final review [HIGH]: removal opData now binds (nonce, index, guardianAddr, p256X, p256Y).
    // These helpers remove ECDSA guardians, so the P-256 key is (0,0). The slot `index` is passed
    // explicitly (matching the removeGuardian(index, ...) call) so the helper makes NO external call
    // to the account — an account view call here would consume the test's vm.prank(owner).
    function _signRemoval(uint256 privKey, address guardianAddr, uint256 nonce, uint8 index) internal view returns (bytes memory) {
        bytes32 removalHash = keccak256(abi.encode(
            GUARDIAN_SIG_VERSION, block.chainid, address(account), "REMOVE_GUARDIAN",
            abi.encode(nonce, index, guardianAddr, bytes32(0), bytes32(0))
        ));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(removalHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // Returns 2 guardian sigs for removing the guardian at `index` (address `guardianAddr`), nonce = 0.
    function _twoGuardianSigs(address guardianAddr, uint8 index) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signRemoval(guardian1Key, guardianAddr, 0, index);
        sigs[1] = _signRemoval(guardian2Key, guardianAddr, 0, index);
    }

    // Variant for nonce != 0 (e.g. second removal in the same test).
    function _twoGuardianSigsNonce(address guardianAddr, uint256 nonce, uint8 index) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signRemoval(guardian1Key, guardianAddr, nonce, index);
        sigs[1] = _signRemoval(guardian2Key, guardianAddr, nonce, index);
    }

    function _proposeRecoveryFromGuardian1() internal {
        vm.prank(guardian1);
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1. addGuardian: owner adds guardian successfully
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_ownerAddsSuccessfully() public {
        _resetToEmptyAccount(); // bootstrap: no guardians yet
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
        // setUp already provides 3 guardians; direct addGuardian reverts UseGuardianConsensus (count>0).
        // MaxGuardiansReached is reached via addGuardianWithMixedSigs with full slots.
        assertEq(account.guardianCount(), 3);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("UseGuardianConsensus()"));
        account.addGuardian(guardian4);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 4. addGuardian: duplicate reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_duplicateReverts() public {
        _resetToEmptyAccount(); // bootstrap: 0 guardians
        vm.startPrank(ownerAddr);
        account.addGuardian(guardian1); // count 0→1 (below RECOVERY_THRESHOLD, direct add still allowed)

        // count=1 < RECOVERY_THRESHOLD so consensus not yet required; duplicate is caught before threshold.
        vm.expectRevert(abi.encodeWithSignature("GuardianAlreadySet()"));
        account.addGuardian(guardian1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 5–6. addGuardian: zero address / owner address reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_addGuardian_zeroAddressReverts() public {
        _resetToEmptyAccount(); // bootstrap path: InvalidGuardian check runs before consensus check
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.addGuardian(address(0));
    }

    function test_addGuardian_ownerAddressReverts() public {
        _resetToEmptyAccount(); // bootstrap path
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
        account.removeGuardian(0, _twoGuardianSigs(guardian1, 0));

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian2);
        assertEq(account.guardians(1), guardian3);
        assertEq(account.guardians(2), address(0));
    }

    function test_removeGuardian_removesMiddle() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        account.removeGuardian(1, _twoGuardianSigs(guardian2, 1));

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardians(1), guardian3);
    }

    function test_removeGuardian_removesLast() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        account.removeGuardian(2, _twoGuardianSigs(guardian3, 2));

        assertEq(account.guardianCount(), 2);
        assertEq(account.guardians(0), guardian1);
        assertEq(account.guardians(1), guardian2);
    }

    function test_removeGuardian_invalidIndexReverts() public {
        _addThreeGuardians();
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        account.removeGuardian(3, new bytes[](0)); // fails InvalidGuardian before sig check
    }

    function test_removeGuardian_nonOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.removeGuardian(0, new bytes[](0)); // fails onlyOwner before sig check
    }

    function test_removeGuardian_minGuardianRequired_reverts() public {
        // Drop to 2 guardians by removing guardian3 first.
        vm.prank(ownerAddr);
        account.removeGuardian(2, _twoGuardianSigs(guardian3, 2));

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("MinGuardianRequired()"));
        account.removeGuardian(0, new bytes[](0));
    }

    function test_removeGuardian_insufficientSigs_reverts() public {
        _addThreeGuardians();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signRemoval(guardian1Key, guardian1, 0, 0);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("InsufficientGuardianApprovals()"));
        account.removeGuardian(0, sigs);
    }

    function test_removeGuardian_duplicateSig_reverts() public {
        _addThreeGuardians();
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRemoval(guardian1Key, guardian1, 0, 0);
        sigs[1] = _signRemoval(guardian1Key, guardian1, 0, 0); // same guardian twice

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("DuplicateGuardianSig()"));
        account.removeGuardian(0, sigs);
    }

    function test_removeGuardian_nonGuardianSig_reverts() public {
        _addThreeGuardians();
        uint256 randomKey = uint256(keccak256(abi.encodePacked("random")));
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signRemoval(guardian1Key, guardian1, 0, 0);
        sigs[1] = _signRemoval(randomKey, guardian1, 0, 0); // not a guardian

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        account.removeGuardian(0, sigs);
    }

    function test_removeGuardian_noncePreventsReplay() public {
        bytes[] memory removeSigs = _twoGuardianSigs(guardian3, 2);
        vm.prank(ownerAddr);
        account.removeGuardian(2, removeSigs); // removalNonce 0 → 1

        // Restore guardian3 via guardian consensus (addGuardianWithMixedSigs).
        // After removal: guardian1=idx0, guardian2=idx1 (additionNonce still 0).
        uint8[] memory addIdxs = new uint8[](2);
        addIdxs[0] = 0; addIdxs[1] = 1;
        bytes[] memory addSigs = new bytes[](2);
        addSigs[0] = _signAddition(guardian1Key, guardian3, 0);
        addSigs[1] = _signAddition(guardian2Key, guardian3, 0);
        vm.prank(ownerAddr);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addGuardianWithMixedSigs(address,uint8[],bytes[])", guardian3, addIdxs, addSigs
        ));
        assertTrue(ok);

        // Old removal sigs (removalNonce=0) no longer valid — recovered addresses are garbage.
        vm.prank(ownerAddr);
        vm.expectRevert(); // NotGuardian
        account.removeGuardian(2, removeSigs);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 8. removeGuardian: blocked during active recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_removeGuardian_revertsIfRecoveryActive() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        (address proposedNewOwner,,,) = account.activeRecovery();
        assertEq(proposedNewOwner, newOwnerAddr);

        // Owner cannot remove a guardian while recovery is in progress —
        // prevents using pre-collected guardian sigs to cancel recovery.
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("RecoveryAlreadyActive()"));
        account.removeGuardian(2, _twoGuardianSigs(guardian3, 2));

        // Recovery is still active
        (address stillActive,,,) = account.activeRecovery();
        assertEq(stillActive, newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 9. proposeRecovery: guardian proposes, auto-approves
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeRecovery_guardianProposesWithAutoApproval() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        vm.expectEmit(true, true, false, false);
        emit RecoveryProposed(newOwnerAddr, guardian1, 0);
        vm.expectEmit(true, true, false, true);
        emit RecoveryApproved(newOwnerAddr, guardian1, 1, 0);
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);

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
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);
    }

    function test_proposeRecovery_zeroNewOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        IAirAccountRecovery(address(account)).proposeRecovery(address(0));
    }

    function test_proposeRecovery_currentOwnerReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("InvalidNewOwner()"));
        IAirAccountRecovery(address(account)).proposeRecovery(ownerAddr);
    }

    function test_proposeRecovery_alreadyActiveReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        vm.expectRevert(abi.encodeWithSignature("RecoveryAlreadyActive()"));
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 14. approveRecovery: second guardian approves
    // ═══════════════════════════════════════════════════════════════════

    function test_approveRecovery_secondGuardianApproves() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        vm.expectEmit(true, true, false, true);
        emit RecoveryApproved(newOwnerAddr, guardian2, 2, 1);
        IAirAccountRecovery(address(account)).approveRecovery();

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
        IAirAccountRecovery(address(account)).approveRecovery();
    }

    function test_approveRecovery_noActiveRecoveryReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        IAirAccountRecovery(address(account)).approveRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 17. executeRecovery: works after timelock + 2 approvals
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_successAfterTimelockAndThreshold() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).approveRecovery();

        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, false, false);
        emit RecoveryExecuted(ownerAddr, newOwnerAddr);
        vm.expectEmit(true, true, false, false);
        emit OwnerChanged(ownerAddr, newOwnerAddr);

        IAirAccountRecovery(address(account)).executeRecovery();

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
        IAirAccountRecovery(address(account)).approveRecovery();

        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(abi.encodeWithSignature("RecoveryTimelockNotExpired()"));
        IAirAccountRecovery(address(account)).executeRecovery();
    }

    function test_executeRecovery_revertsWithInsufficientApprovals() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSignature("RecoveryNotApproved()"));
        IAirAccountRecovery(address(account)).executeRecovery();
    }

    function test_executeRecovery_revertsNoActiveRecovery() public {
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        IAirAccountRecovery(address(account)).executeRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 21. Full recovery flow
    // ═══════════════════════════════════════════════════════════════════

    function test_fullRecoveryFlow() public {
        _addThreeGuardians();

        vm.prank(guardian1);
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);

        (address proposed,,,) = account.activeRecovery();
        assertEq(proposed, newOwnerAddr);

        vm.prank(guardian3);
        IAirAccountRecovery(address(account)).approveRecovery();

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(bitmap, 5); // bit 0 + bit 2

        vm.warp(block.timestamp + 2 days);

        vm.prank(randomAddr);
        IAirAccountRecovery(address(account)).executeRecovery();

        assertEq(account.owner(), newOwnerAddr);

        // Old owner can no longer call addGuardian (fails NotOwner before UseGuardianConsensus).
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
        account.addGuardian(makeAddr("newGuardian"));

        // New owner removes guardian1 (count: 3→2); then adds a new guardian via consensus.
        // After removal: guardian2=idx0, guardian3=idx1 (additionNonce=0).
        bytes[] memory removeSigs = _twoGuardianSigs(guardian1, 0);
        vm.prank(newOwnerAddr);
        account.removeGuardian(0, removeSigs);

        address newG = makeAddr("newGuardian");
        uint8[] memory addIdxs = new uint8[](2);
        addIdxs[0] = 0; addIdxs[1] = 1;
        bytes[] memory addSigs = new bytes[](2);
        addSigs[0] = _signAddition(guardian2Key, newG, 0);
        addSigs[1] = _signAddition(guardian3Key, newG, 0);
        vm.prank(newOwnerAddr);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addGuardianWithMixedSigs(address,uint8[],bytes[])", newG, addIdxs, addSigs
        ));
        assertTrue(ok);
        assertEq(account.guardianCount(), 3);
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
        emit RecoveryCancelVoted(guardian2, 1, 1);
        IAirAccountRecovery(address(account)).cancelRecovery();

        // Recovery still active
        (address stillActive,,,) = account.activeRecovery();
        assertEq(stillActive, newOwnerAddr);
    }

    function test_cancelRecovery_twoGuardiansCancels() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        // First guardian votes to cancel
        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).cancelRecovery();

        // Second guardian votes — reaches 2-of-3 threshold → cancellation happens
        vm.prank(guardian3);
        vm.expectEmit(true, false, false, true);
        emit RecoveryCancelVoted(guardian3, 2, 2);
        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();
        IAirAccountRecovery(address(account)).cancelRecovery();

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
        IAirAccountRecovery(address(account)).cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 24. cancelRecovery: non-guardian can't cancel
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_nonGuardianReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(randomAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        IAirAccountRecovery(address(account)).cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 25. cancelRecovery: no active recovery reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_noActiveRecoveryReverts() public {
        _addThreeGuardians();
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSignature("NoActiveRecovery()"));
        IAirAccountRecovery(address(account)).cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 26. cancelRecovery: same guardian can't vote twice
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelRecovery_sameGuardianTwiceReverts() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).cancelRecovery();

        vm.prank(guardian2);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCancelVoted()"));
        IAirAccountRecovery(address(account)).cancelRecovery();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 27. executeRecovery: all 3 guardians approve
    // ═══════════════════════════════════════════════════════════════════

    function test_executeRecovery_allThreeGuardiansApprove() public {
        _addThreeGuardians();
        _proposeRecoveryFromGuardian1();

        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).approveRecovery();
        vm.prank(guardian3);
        IAirAccountRecovery(address(account)).approveRecovery();

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(bitmap, 7); // 0b111

        vm.warp(block.timestamp + 2 days);
        IAirAccountRecovery(address(account)).executeRecovery();
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
        IAirAccountRecovery(address(account)).approveRecovery();

        vm.warp(proposalTime + 2 days);
        IAirAccountRecovery(address(account)).executeRecovery();
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
        IAirAccountRecovery(address(account)).approveRecovery();
        vm.warp(1000 + 2 days);
        IAirAccountRecovery(address(account)).executeRecovery();
        assertEq(account.owner(), newOwnerAddr);

        address secondNewOwner = makeAddr("secondNewOwner");
        vm.warp(1000 + 3 days);
        vm.prank(guardian1);
        IAirAccountRecovery(address(account)).proposeRecovery(secondNewOwner);
        vm.prank(guardian3);
        IAirAccountRecovery(address(account)).approveRecovery();
        vm.warp(1000 + 5 days);
        IAirAccountRecovery(address(account)).executeRecovery();
        assertEq(account.owner(), secondNewOwner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 30. Stolen key cannot block recovery
    // ═══════════════════════════════════════════════════════════════════

    function test_stolenKey_cannotBlockRecovery() public {
        _addThreeGuardians();

        _proposeRecoveryFromGuardian1();
        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).approveRecovery();

        // Thief tries to cancel — not a guardian
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        IAirAccountRecovery(address(account)).cancelRecovery();

        // Recovery succeeds
        vm.warp(block.timestamp + 2 days);
        IAirAccountRecovery(address(account)).executeRecovery();
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
        IAirAccountRecovery(address(account)).cancelRecovery();
        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).cancelRecovery();

        (address cleared,,,) = account.activeRecovery();
        assertEq(cleared, address(0));

        // Re-propose with different owner
        address anotherOwner = makeAddr("anotherOwner");
        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).proposeRecovery(anotherOwner);
        vm.prank(guardian3);
        IAirAccountRecovery(address(account)).approveRecovery();

        vm.warp(block.timestamp + 2 days);
        IAirAccountRecovery(address(account)).executeRecovery();
        assertEq(account.owner(), anotherOwner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 32. Cancel race: cancel votes don't persist across proposals
    // ═══════════════════════════════════════════════════════════════════

    function test_cancelBitmapClearedOnNewProposal() public {
        _addThreeGuardians();

        // First proposal
        _proposeRecoveryFromGuardian1();

        // guardian2 votes to cancel
        vm.prank(guardian2);
        IAirAccountRecovery(address(account)).cancelRecovery();

        // guardian1 (proposer) also votes to cancel — 2 votes → cancels recovery, clears activeRecovery
        vm.prank(guardian1);
        IAirAccountRecovery(address(account)).cancelRecovery();

        (address cleared,,,) = account.activeRecovery();
        assertEq(cleared, address(0));

        // New proposal — cancel bitmap should be fresh
        vm.prank(guardian1);
        IAirAccountRecovery(address(account)).proposeRecovery(newOwnerAddr);

        (,,, uint256 cancelBitmap) = account.activeRecovery();
        assertEq(cancelBitmap, 0); // Clean slate
    }
}
