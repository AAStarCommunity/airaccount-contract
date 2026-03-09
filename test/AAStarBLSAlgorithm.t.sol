// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";

/// @dev Unit tests for AAStarBLSAlgorithm node management and basic structure.
///      BLS pairing verification requires EIP-2537 precompiles (Sepolia/Prague only),
///      so those are tested in E2E tests. Here we test node management ABI compatibility.
contract AAStarBLSAlgorithmTest is Test {
    AAStarBLSAlgorithm public bls;
    address owner;

    bytes32 constant NODE1 = keccak256("node1");
    bytes32 constant NODE2 = keccak256("node2");
    bytes32 constant NODE3 = keccak256("node3");

    // Fake 128-byte G1 public keys (for management tests only, not valid curve points)
    bytes pubKey1;
    bytes pubKey2;
    bytes pubKey3;

    function setUp() public {
        owner = address(this);
        bls = new AAStarBLSAlgorithm();

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
        vm.expectRevert(AAStarBLSAlgorithm.InvalidNodeId.selector);
        bls.registerPublicKey(bytes32(0), pubKey1);
    }

    function test_registerPublicKey_invalidKeyLength() public {
        vm.expectRevert(AAStarBLSAlgorithm.InvalidKeyLength.selector);
        bls.registerPublicKey(NODE1, new bytes(64)); // Wrong length
    }

    function test_registerPublicKey_duplicate() public {
        bls.registerPublicKey(NODE1, pubKey1);

        vm.expectRevert(AAStarBLSAlgorithm.NodeAlreadyRegistered.selector);
        bls.registerPublicKey(NODE1, pubKey2);
    }

    function test_registerPublicKey_anyone() public {
        // Anyone can register (open access, future: requires PNT stake)
        vm.prank(address(0xdead));
        bls.registerPublicKey(NODE1, pubKey1);
        assertTrue(bls.isRegistered(NODE1));
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
        vm.expectRevert(AAStarBLSAlgorithm.OnlyOwner.selector);
        bls.updatePublicKey(NODE1, pubKey2);
    }

    function test_updatePublicKey_notRegistered() public {
        vm.expectRevert(AAStarBLSAlgorithm.NodeNotRegistered.selector);
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
        vm.expectRevert(AAStarBLSAlgorithm.OnlyOwner.selector);
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
        vm.expectRevert(AAStarBLSAlgorithm.OnlyOwner.selector);
        bls.batchRegisterPublicKeys(ids, keys);
    }

    function test_batchRegisterPublicKeys_lengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = NODE1;
        ids[1] = NODE2;
        bytes[] memory keys = new bytes[](1);
        keys[0] = pubKey1;

        vm.expectRevert(AAStarBLSAlgorithm.ArrayLengthMismatch.selector);
        bls.batchRegisterPublicKeys(ids, keys);
    }

    function test_batchRegisterPublicKeys_empty() public {
        vm.expectRevert(AAStarBLSAlgorithm.EmptyArrays.selector);
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

    // ─── Ownership ────────────────────────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = address(0xBEEF);
        bls.transferOwnership(newOwner);
        assertEq(bls.owner(), newOwner);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(AAStarBLSAlgorithm.OnlyOwner.selector);
        bls.transferOwnership(address(0xBEEF));
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
        vm.expectRevert(AAStarBLSAlgorithm.NoNodesProvided.selector);
        bls.validateAggregateSignature(empty, new bytes(256), new bytes(256));
    }

    function test_validateAggregateSignature_invalidSigLength() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;

        vm.expectRevert(AAStarBLSAlgorithm.InvalidSignatureLength.selector);
        bls.validateAggregateSignature(ids, new bytes(128), new bytes(256));
    }

    function test_validateAggregateSignature_invalidMsgLength() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = NODE1;

        vm.expectRevert(AAStarBLSAlgorithm.InvalidMessageLength.selector);
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
}
