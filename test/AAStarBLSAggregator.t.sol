// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSAggregator} from "../src/aggregator/AAStarBLSAggregator.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Unit tests for AAStarBLSAggregator.
///      BLS precompiles (EIP-2537) are NOT available in forge's EVM, so we test
///      signature format validation, empty batch reverts, and constructor storage.
///      Full BLS pairing tests belong in E2E (Prague/Sepolia).
contract AAStarBLSAggregatorTest is Test {
    AAStarBLSAggregator public aggregator;
    AAStarBLSAlgorithm public blsAlgorithm;

    bytes32 constant NODE1 = keccak256("node1");

    function setUp() public {
        blsAlgorithm = new AAStarBLSAlgorithm();
        aggregator = new AAStarBLSAggregator(address(blsAlgorithm));
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_storesBlsAlgorithm() public view {
        assertEq(address(aggregator.blsAlgorithm()), address(blsAlgorithm));
    }

    // ─── validateUserOpSignature: valid format ──────────────────────────

    function test_validateUserOpSignature_validFormat_returnsEmpty() public view {
        // Build a well-formed triple signature:
        // 0x01 | nodeIdsLength(32) | nodeIds(1×32) | blsSig(256) | messagePoint(256) | aaSignature(65) | mpSignature(65)
        uint256 nodeCount = 1;
        bytes memory sig = abi.encodePacked(
            uint8(0x01),
            uint256(nodeCount),             // nodeIdsLength = 1
            NODE1,                          // 1 nodeId (32 bytes)
            new bytes(256),                 // blsSig placeholder
            new bytes(256),                 // messagePoint placeholder
            new bytes(65),                  // aaSignature placeholder
            new bytes(65)                   // mpSignature placeholder
        );

        PackedUserOperation memory userOp = _makeUserOp(sig);
        bytes memory result = aggregator.validateUserOpSignature(userOp);
        assertEq(result.length, 0, "Should return empty bytes for valid format");
    }

    function test_validateUserOpSignature_twoNodes_validFormat() public view {
        // Two node IDs in the signature
        bytes32 node2 = keccak256("node2");
        uint256 nodeCount = 2;
        bytes memory sig = abi.encodePacked(
            uint8(0x01),
            uint256(nodeCount),
            NODE1,
            node2,
            new bytes(256),
            new bytes(256),
            new bytes(65),
            new bytes(65)
        );

        PackedUserOperation memory userOp = _makeUserOp(sig);
        bytes memory result = aggregator.validateUserOpSignature(userOp);
        assertEq(result.length, 0);
    }

    // ─── validateUserOpSignature: invalid format reverts ────────────────

    function test_validateUserOpSignature_emptySignature_reverts() public {
        PackedUserOperation memory userOp = _makeUserOp(new bytes(0));
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(userOp);
    }

    function test_validateUserOpSignature_wrongAlgId_reverts() public {
        // algId = 0x02 instead of 0x01
        bytes memory sig = abi.encodePacked(
            uint8(0x02),
            uint256(1),
            NODE1,
            new bytes(256),
            new bytes(256),
            new bytes(65),
            new bytes(65)
        );

        PackedUserOperation memory userOp = _makeUserOp(sig);
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(userOp);
    }

    function test_validateUserOpSignature_tooShort_noNodeIdsLength_reverts() public {
        // Only algId byte, no nodeIdsLength
        bytes memory sig = abi.encodePacked(uint8(0x01));

        PackedUserOperation memory userOp = _makeUserOp(sig);
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(userOp);
    }

    function test_validateUserOpSignature_truncatedBody_reverts() public {
        // algId + nodeIdsLength=1 + nodeId + blsSig, but missing messagePoint and ECDSA sigs
        bytes memory sig = abi.encodePacked(
            uint8(0x01),
            uint256(1),
            NODE1,
            new bytes(256) // only blsSig, missing rest
        );

        PackedUserOperation memory userOp = _makeUserOp(sig);
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(userOp);
    }

    function test_validateUserOpSignature_extraBytes_reverts() public {
        // Valid format + 1 extra byte
        bytes memory sig = abi.encodePacked(
            uint8(0x01),
            uint256(1),
            NODE1,
            new bytes(256),
            new bytes(256),
            new bytes(65),
            new bytes(65),
            uint8(0xFF) // extra byte
        );

        PackedUserOperation memory userOp = _makeUserOp(sig);
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(userOp);
    }

    // ─── aggregateSignatures: empty batch reverts ───────────────────────

    function test_aggregateSignatures_emptyBatch_reverts() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](0);
        vm.expectRevert(AAStarBLSAggregator.EmptyBatch.selector);
        aggregator.aggregateSignatures(ops);
    }

    // ─── validateSignatures: empty batch reverts ────────────────────────

    function test_validateSignatures_emptyBatch_reverts() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](0);
        vm.expectRevert(AAStarBLSAggregator.EmptyBatch.selector);
        aggregator.validateSignatures(ops, new bytes(544));
    }

    // ─── validateSignatures: caller-supplied aggregate is IGNORED (v0.17.2-beta.1 round 5 HIGH-3) ──

    /// @dev Round 5 HIGH-3: the `signature` parameter is no longer trusted/parsed. validateSignatures
    ///      recomputes the aggregate from `userOps[i].signature`. These three legacy tests previously
    ///      verified malformed-`signature` rejection; with the new binding, the revert now originates
    ///      from `_extractBLSData(userOps[0].signature)` because userOps[0].signature is empty/malformed.
    ///      We accept any revert (without specific selector) — the assertion is "still rejects bad input",
    ///      just at the userOps-side path rather than the aggregate-side path.

    function test_validateSignatures_tooShortSignature_reverts() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(new bytes(0));

        vm.expectRevert(); // userOps[0].signature too short → _extractBLSData reverts
        aggregator.validateSignatures(ops, new bytes(100));
    }

    function test_validateSignatures_signatureLengthMismatch_reverts() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(new bytes(0));

        bytes memory aggSig = abi.encodePacked(
            new bytes(256),     // aggBlsSig — IGNORED in beta.1
            new bytes(256),     // aggMsgPoint — IGNORED
            uint256(1)          // nodeCount — IGNORED
        );

        vm.expectRevert(); // revert from _extractBLSData(empty userOps[0].signature)
        aggregator.validateSignatures(ops, aggSig);
    }

    function test_validateSignatures_zeroNodeCount_formatValid_butNodeLookupNeeded() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(new bytes(0));

        bytes memory aggSig = abi.encodePacked(
            new bytes(256),
            new bytes(256),
            uint256(0)
        );

        vm.expectRevert(); // empty userOps[0].signature → _extractBLSData reverts, NOT from supplied aggSig
        aggregator.validateSignatures(ops, aggSig);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    /// @dev Build a minimal PackedUserOperation with given signature
    function _makeUserOp(bytes memory sig) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(0x1234),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }
}
