// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";

/// @title AAStarBLSAlgorithm M3 Tests - Cached aggregated keys, G2 operations
contract AAStarBLSAlgorithmM3Test is Test {
    AAStarBLSAlgorithm public bls;
    address public owner = address(this);

    // Sample G1 points in EIP-2537 format (128 bytes each) — using generator-derived keys
    bytes public pk1;
    bytes public pk2;

    bytes32 public nodeId1 = bytes32(uint256(1));
    bytes32 public nodeId2 = bytes32(uint256(2));

    function setUp() public {
        bls = new AAStarBLSAlgorithm();

        // Create deterministic 128-byte public keys for testing
        pk1 = _makeKey(0x11);
        pk2 = _makeKey(0x22);

        bls.registerPublicKey(nodeId1, pk1);
        bls.registerPublicKey(nodeId2, pk2);
    }

    // ─── computeSetHash ──────────────────────────────────────────────

    function test_computeSetHash_deterministic() public view {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = nodeId1;
        ids[1] = nodeId2;

        bytes32 hash1 = bls.computeSetHash(ids);
        bytes32 hash2 = bls.computeSetHash(ids);
        assertEq(hash1, hash2);
    }

    function test_computeSetHash_orderMatters() public view {
        bytes32[] memory ids1 = new bytes32[](2);
        ids1[0] = nodeId1;
        ids1[1] = nodeId2;

        bytes32[] memory ids2 = new bytes32[](2);
        ids2[0] = nodeId2;
        ids2[1] = nodeId1;

        assertNotEq(bls.computeSetHash(ids1), bls.computeSetHash(ids2));
    }

    // ─── cacheAggregatedKey ──────────────────────────────────────────

    function test_cacheAggregatedKey_emptyReverts() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(AAStarBLSAlgorithm.NoNodesProvided.selector);
        bls.cacheAggregatedKey(empty);
    }

    function test_cacheAggregatedKey_unregisteredReverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(999));
        vm.expectRevert(AAStarBLSAlgorithm.NodeNotRegistered.selector);
        bls.cacheAggregatedKey(ids);
    }

    // Note: cacheAggregatedKey with real keys requires G1Add precompile (EIP-2537)
    // which is not available in forge's EVM. Testing format/validation only.

    // ─── aggregateKeys ───────────────────────────────────────────────

    function test_aggregateKeys_emptyReverts() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(AAStarBLSAlgorithm.NoNodesProvided.selector);
        bls.aggregateKeys(empty);
    }

    function test_aggregateKeys_unregisteredReverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(999));
        vm.expectRevert(AAStarBLSAlgorithm.NodeNotRegistered.selector);
        bls.aggregateKeys(ids);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _makeKey(uint8 seed) internal pure returns (bytes memory key) {
        key = new bytes(128);
        // Fill with deterministic but unique data
        for (uint256 i = 0; i < 128; i++) {
            key[i] = bytes1(uint8(seed + uint8(i % 48)));
        }
    }
}
