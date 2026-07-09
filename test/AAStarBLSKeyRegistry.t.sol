// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSKeyRegistry} from "../src/validators/AAStarBLSKeyRegistry.sol";

/// @dev Unit tests for AAStarBLSKeyRegistry node management and basic structure.
///      BLS pairing verification requires EIP-2537 precompiles (Sepolia/Prague only),
///      so those are tested in E2E tests. Here we test node management ABI compatibility.
contract AAStarBLSKeyRegistryTest is Test {
    AAStarBLSKeyRegistry public bls;
    address owner;

    bytes32 constant NODE1 = keccak256("node1");
    bytes32 constant NODE2 = keccak256("node2");
    bytes32 constant NODE3 = keccak256("node3");

    // Fake 128-byte G1 public keys (for management tests only, not valid curve points)
    bytes pubKey1;
    bytes pubKey2;
    bytes pubKey3;

    /// @dev BLS12-381 G1 generator in EIP-2537 format (128 bytes). A real on-curve point,
    ///      needed for tests that exercise the G1ADD precompile (rejects off-curve inputs).
    bytes constant G1_GENERATOR =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    function setUp() public {
        owner = address(this);
        bls = new AAStarBLSKeyRegistry();

        pubKey1 = _fakeG1Point(1);
        pubKey2 = _fakeG1Point(2);
        pubKey3 = _fakeG1Point(3);
    }

    function _fakeG1Point(uint8 seed) internal pure returns (bytes memory) {
        bytes memory pk = new bytes(128);
        pk[16] = bytes1(seed); // Put seed in the x-coord area
        return pk;
    }

    // ─── Registration ─────────────────────────────────────────────────

    function test_registerPublicKey() public {
        bls.registerPublicKey(NODE1, pubKey1);

        assertTrue(bls.isRegistered(NODE1));
        assertEq(bls.getRegisteredNodeCount(), 1);
    }

    function test_registerPublicKey_invalidNodeId() public {
        vm.expectRevert(AAStarBLSKeyRegistry.InvalidNodeId.selector);
        bls.registerPublicKey(bytes32(0), pubKey1);
    }

    function test_registerPublicKey_invalidKeyLength() public {
        vm.expectRevert(AAStarBLSKeyRegistry.InvalidKeyLength.selector);
        bls.registerPublicKey(NODE1, new bytes(64)); // Wrong length
    }

    function test_registerPublicKey_duplicate() public {
        bls.registerPublicKey(NODE1, pubKey1);

        vm.expectRevert(AAStarBLSKeyRegistry.NodeAlreadyRegistered.selector);
        bls.registerPublicKey(NODE1, pubKey2);
    }

    function test_registerPublicKey_onlyOwner() public {
        // Non-owner cannot register (security fix: was permissionless)
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.registerPublicKey(NODE1, pubKey1);
    }

    // ─── Update ───────────────────────────────────────────────────────

    function test_updatePublicKey() public {
        bls.registerPublicKey(NODE1, pubKey1);
        bls.updatePublicKey(NODE1, pubKey2);

        // Key updated (node still registered)
        assertTrue(bls.isRegistered(NODE1));
    }

    function test_updatePublicKey_onlyOwner() public {
        bls.registerPublicKey(NODE1, pubKey1);

        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.updatePublicKey(NODE1, pubKey2);
    }

    function test_updatePublicKey_notRegistered() public {
        vm.expectRevert(AAStarBLSKeyRegistry.NodeNotRegistered.selector);
        bls.updatePublicKey(NODE1, pubKey2);
    }

    // ─── Revoke ───────────────────────────────────────────────────────

    function test_revokePublicKey() public {
        bls.registerPublicKey(NODE1, pubKey1);
        bls.revokePublicKey(NODE1);

        assertFalse(bls.isRegistered(NODE1));
        assertEq(bls.getRegisteredNodeCount(), 0);
    }

    function test_revokePublicKey_onlyOwner() public {
        bls.registerPublicKey(NODE1, pubKey1);

        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.revokePublicKey(NODE1);
    }

    function test_revokePublicKey_middleOfArray() public {
        bls.registerPublicKey(NODE1, pubKey1);
        bls.registerPublicKey(NODE2, pubKey2);
        bls.registerPublicKey(NODE3, pubKey3);

        bls.revokePublicKey(NODE2);

        assertEq(bls.getRegisteredNodeCount(), 2);
        assertTrue(bls.isRegistered(NODE1));
        assertFalse(bls.isRegistered(NODE2));
        assertTrue(bls.isRegistered(NODE3));
    }

    // ─── Batch Registration ───────────────────────────────────────────

    function test_batchRegisterPublicKeys() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = NODE1;
        ids[1] = NODE2;

        bytes[] memory keys = new bytes[](2);
        keys[0] = pubKey1;
        keys[1] = pubKey2;

        bls.batchRegisterPublicKeys(ids, keys);

        assertEq(bls.getRegisteredNodeCount(), 2);
        assertTrue(bls.isRegistered(NODE1));
        assertTrue(bls.isRegistered(NODE2));
    }

    function test_batchRegisterPublicKeys_onlyOwner() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;
        bytes[] memory keys = new bytes[](1);
        keys[0] = pubKey1;

        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.batchRegisterPublicKeys(ids, keys);
    }

    function test_batchRegisterPublicKeys_lengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = NODE1;
        ids[1] = NODE2;
        bytes[] memory keys = new bytes[](1);
        keys[0] = pubKey1;

        vm.expectRevert(AAStarBLSKeyRegistry.ArrayLengthMismatch.selector);
        bls.batchRegisterPublicKeys(ids, keys);
    }

    function test_batchRegisterPublicKeys_empty() public {
        vm.expectRevert(AAStarBLSKeyRegistry.EmptyArrays.selector);
        bls.batchRegisterPublicKeys(new bytes32[](0), new bytes[](0));
    }

    // ─── Enumeration ──────────────────────────────────────────────────

    function test_getRegisteredNodes_paginated() public {
        bls.registerPublicKey(NODE1, pubKey1);
        bls.registerPublicKey(NODE2, pubKey2);
        bls.registerPublicKey(NODE3, pubKey3);

        (bytes32[] memory ids, bytes[] memory keys) = bls.getRegisteredNodes(0, 2);
        assertEq(ids.length, 2);
        assertEq(keys.length, 2);
        assertEq(ids[0], NODE1);
        assertEq(ids[1], NODE2);

        (ids, keys) = bls.getRegisteredNodes(2, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], NODE3);
    }

    function test_getRegisteredNodes_offsetOutOfBounds() public {
        bls.registerPublicKey(NODE1, pubKey1);
        (bytes32[] memory ids,) = bls.getRegisteredNodes(5, 10);
        assertEq(ids.length, 0);
    }

    // ─── Ownership (two-step, Ownable2Step) ───────────────────────────

    function test_transferOwnership_twoStep() public {
        address newOwner = address(0xBEEF);
        // Step 1: current owner records pending owner — ownership does NOT change yet.
        bls.transferOwnership(newOwner);
        assertEq(bls.owner(), address(this), "owner must not change until accepted");
        assertEq(bls.pendingOwner(), newOwner);

        // Step 2: only the pending owner can accept.
        vm.prank(newOwner);
        bls.acceptOwnership();
        assertEq(bls.owner(), newOwner);
        assertEq(bls.pendingOwner(), address(0));
    }

    function test_acceptOwnership_onlyPendingOwner() public {
        bls.transferOwnership(address(0xBEEF));
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.NotPendingOwner.selector);
        bls.acceptOwnership();
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.transferOwnership(address(0xBEEF));
    }

    // ─── Protocol aggregator (issue #45 Part B) ───────────────────────

    function test_setAggregator_onlyOwner_succeeds() public {
        assertEq(bls.aggregator(), address(0), "default: no aggregator");
        bls.setAggregator(address(0xA66));
        assertEq(bls.aggregator(), address(0xA66));
        // can be cleared (disable batch protocol-wide)
        bls.setAggregator(address(0));
        assertEq(bls.aggregator(), address(0));
    }

    function test_setAggregator_nonOwner_reverts() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.setAggregator(address(0xA66));
    }

    function test_setAggregator_onlyNewSafeOwnerAfterHandover() public {
        // After EOA→Safe handover, only the Safe (new owner) can set the aggregator.
        address safe = address(0x5AFE);
        bls.transferOwnership(safe);
        vm.prank(safe);
        bls.acceptOwnership();

        // Old owner (this) can no longer set it.
        vm.expectRevert(AAStarBLSKeyRegistry.OnlyOwner.selector);
        bls.setAggregator(address(0xA66));

        // The Safe can.
        vm.prank(safe);
        bls.setAggregator(address(0xA66));
        assertEq(bls.aggregator(), address(0xA66));
    }

    // ─── Gas Estimate ─────────────────────────────────────────────────

    function test_getGasEstimate() public view {
        uint256 gas1 = bls.getGasEstimate(1);
        uint256 gas3 = bls.getGasEstimate(3);

        assertGe(gas1, 150_000);
        assertGt(gas3, gas1);
        assertLe(bls.getGasEstimate(100), 2_000_000);
    }

    // ─── Validate AggregateSignature Input Checks ─────────────────────

    function test_validateAggregateSignature_emptyNodes() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(AAStarBLSKeyRegistry.NoNodesProvided.selector);
        bls.validateAggregateSignature(empty, new bytes(256), new bytes(256));
    }

    function test_validateAggregateSignature_invalidSigLength() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;

        vm.expectRevert(AAStarBLSKeyRegistry.InvalidSignatureLength.selector);
        bls.validateAggregateSignature(ids, new bytes(128), new bytes(256));
    }

    function test_validateAggregateSignature_invalidMsgLength() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;

        vm.expectRevert(AAStarBLSKeyRegistry.InvalidMessageLength.selector);
        bls.validateAggregateSignature(ids, new bytes(256), new bytes(128));
    }

    // ─── IAAStarAlgorithm.validate Input Checks ──────────────────────

    function test_validate_tooShort() public view {
        // Signature too short (< 512 bytes)
        uint256 result = bls.validate(bytes32(0), new bytes(100));
        assertEq(result, 1);
    }

    function test_validate_invalidNodeIdsPortion() public view {
        // Exactly 512 bytes = no nodeIds → fail
        uint256 result = bls.validate(bytes32(0), new bytes(512));
        assertEq(result, 1);
    }

    // ─── aggregateKeys ────────────────────────────────────────────────

    function test_aggregateKeys_emptyNodeIds_reverts() public {
        vm.expectRevert(AAStarBLSKeyRegistry.NoNodesProvided.selector);
        bls.aggregateKeys(new bytes32[](0));
    }

    function test_aggregateKeys_unregisteredNode_reverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1; // not registered
        vm.expectRevert(AAStarBLSKeyRegistry.NodeNotRegistered.selector);
        bls.aggregateKeys(ids);
    }

    function test_aggregateKeys_singleNode_returnsKey() public {
        bls.registerPublicKey(NODE1, pubKey1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;
        // Single node: loop body never executes, no EIP-2537 precompile needed
        bytes memory result = bls.aggregateKeys(ids);
        assertEq(result, pubKey1);
    }

    function test_aggregateKeys_twoNodes_returnsG1Point() public {
        // Two nodes calls _g1Add (EIP-2537 G1Add precompile 0x0b). The real precompile
        // rejects points that are not on the BLS12-381 G1 curve, so we must register valid
        // on-curve points here (the fake _fakeG1Point blobs are off-curve and would revert
        // under --evm-version prague). G1ADD(G, G) = 2G is a valid doubling. (#104)
        bls.registerPublicKey(NODE1, G1_GENERATOR);
        bls.registerPublicKey(NODE2, G1_GENERATOR);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = NODE1;
        ids[1] = NODE2;
        bytes memory result = bls.aggregateKeys(ids);
        assertEq(result.length, 128); // G1 point = 128 bytes
    }
}
