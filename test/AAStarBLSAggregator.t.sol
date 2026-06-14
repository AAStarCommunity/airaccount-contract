// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSAggregator} from "../src/aggregator/AAStarBLSAggregator.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Minimal EntryPoint stand-in: getUserOpHash(op) = keccak256(abi.encode(sender, nonce)).
///      Used so the aggregator can derive each op's userOpHash for the #45 on-chain binding.
///      The off-chain fixture (/tmp/gen_batch.mjs) signs over hashToCurve of THIS exact hash.
contract MockEntryPointAgg {
    function getUserOpHash(PackedUserOperation calldata op) external pure returns (bytes32) {
        return keccak256(abi.encode(op.sender, op.nonce));
    }
}

/// @dev Tests for AAStarBLSAggregator.
///      Format/empty-batch tests run under any EVM. The batch PAIRING + #45-binding tests need
///      EIP-2537 (the aggregator recomputes each op's message point via blsAlgorithm.hashToG2),
///      so they self-skip unless run with `--evm-version prague`.
contract AAStarBLSAggregatorTest is Test {
    AAStarBLSAggregator public aggregator;
    AAStarBLSAlgorithm public blsAlgorithm;
    MockEntryPointAgg public ep;

    // Same 3-node set as the fixtures (sks 0x11..01 / 0x22..02 / 0x33..03).
    bytes32 constant NODE0 = keccak256("replay-node-0");
    bytes32 constant NODE1 = keccak256("replay-node-1");
    bytes32 constant NODE2 = keccak256("replay-node-2");

    bytes PK0 =
        hex"0000000000000000000000000000000000018a69dc077fab6cfcbccb3885ad65db01da0c02491dff25d29ce90d03bc68cb52ad49bead602238cf467eafdb48cd0000000000000000000000000000000002becaee44a5a46c7330c9c7a7212c11542851f5dd029554a40db9b14e004f0c1f1d879d9948a9a7b477f8db2641fc8d";
    bytes PK1 =
        hex"000000000000000000000000000000000bc90707abc9ce61d525419ceda6aacd8a3b4f222bf63e18d7c6ba56b5c8f9642375e1424b2e3d3ab0c7324bcfd2ecea0000000000000000000000000000000016116e6a87fc280d377d071a22b78316eca19ac05435a378e4f9b41e4d1650ce90dd139ea84feb1c13ac8f9db393e7e7";
    bytes PK2 =
        hex"000000000000000000000000000000000e53de59dcec974f6ec859282f92820ae22198ba0c0405c1ac0e0878959f6528340c4ca46d6907a92c997b90dd5b83af0000000000000000000000000000000002f3e512ee7a9a7d45e8679c1e808fb2751b53aeb254f24ba1499719e8a9289c3dd88db9d00c18edf9d0bb306fb5526d";

    // Per-op aggregate BLS signatures over hashToCurve(userOpHash) where userOpHash =
    // keccak256(abi.encode(sender=0x1234, nonce)). From /tmp/gen_batch.mjs.
    bytes AGG_NONCE1 =
        hex"000000000000000000000000000000000be4ca32a22d359dc1d9b1d231b8598d4525c157208a544651ff103a1733f9c5c7b83f12decd21348e289d6fc2b15aa20000000000000000000000000000000012eeb3030999eca8c77d11beb5f8fc95d6fe9ad6e0edc5a409688602ba47736b9738eb7d8fe06d87e277ef816ed43443000000000000000000000000000000001939166c8b22a73c31e1fdab1f86276461a701b53d535b65ca4ca100ffd3cfeffbbd9175b34a3d68ae1e66ac578696200000000000000000000000000000000004c0e2b2e5b3a4a6c3c4bda2bb4af935403943e1978a6732f494b85acaeabe99613d25ca85a53b00296df861ef65fbb9";
    bytes AGG_NONCE2 =
        hex"00000000000000000000000000000000187954e0a351bf11a05f2cfbc8516df92832f1633098a0744290d1e2773df6b799cdbd83c4c982976b27f05155efa6aa000000000000000000000000000000000e459be3eb1c9abba7fa136176b74da02b94624874a75c8f62f52d7bf88d16b944adf61371c82799969e0b2255fba481000000000000000000000000000000000925224052a974a939bbf8f3b3b483a8c633ef3972dc7a6482930d503dee5d44abc512f143d0c071e8d2b5dfe0c87bc2000000000000000000000000000000000e6be428da58f033cace24d44ae1ed4d62c757f4cf7bbf43e68674922faa7336a5f2c7c11dd99f602afd0c88b0ad7162";

    function setUp() public {
        blsAlgorithm = new AAStarBLSAlgorithm();
        ep = new MockEntryPointAgg();
        aggregator = new AAStarBLSAggregator(address(blsAlgorithm), address(ep));
        blsAlgorithm.registerPublicKey(NODE0, PK0);
        blsAlgorithm.registerPublicKey(NODE1, PK1);
        blsAlgorithm.registerPublicKey(NODE2, PK2);
    }

    function _has2537() internal view returns (bool) {
        bytes memory inp = new bytes(128);
        bool ok;
        uint256 rds;
        assembly {
            ok := staticcall(gas(), 0x11, add(inp, 0x20), 128, 0, 0)
            rds := returndatasize()
        }
        return ok && rds == 256;
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_storesRefs() public view {
        assertEq(address(aggregator.blsAlgorithm()), address(blsAlgorithm));
        assertEq(address(aggregator.entryPoint()), address(ep));
    }

    // ─── validateUserOpSignature: format (issue #45: [0x01][len][nodeIds][blsSig(256)][aaSig(65)]) ──

    function _validFormatSig(uint256 n) internal pure returns (bytes memory) {
        bytes memory s = abi.encodePacked(uint8(0x01), uint256(n));
        for (uint256 i = 0; i < n; i++) s = abi.encodePacked(s, bytes32(uint256(0xA0 + i)));
        return abi.encodePacked(s, new bytes(256), new bytes(65));
    }

    function test_validateUserOpSignature_validFormat_returnsEmpty() public view {
        bytes memory r = aggregator.validateUserOpSignature(_makeUserOp(_validFormatSig(1), 0));
        assertEq(r.length, 0);
    }

    function test_validateUserOpSignature_twoNodes_validFormat() public view {
        bytes memory r = aggregator.validateUserOpSignature(_makeUserOp(_validFormatSig(2), 0));
        assertEq(r.length, 0);
    }

    function test_validateUserOpSignature_emptySignature_reverts() public {
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(_makeUserOp(new bytes(0), 0));
    }

    function test_validateUserOpSignature_wrongAlgId_reverts() public {
        bytes memory sig = abi.encodePacked(uint8(0x02), uint256(1), NODE0, new bytes(256), new bytes(65));
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(_makeUserOp(sig, 0));
    }

    function test_validateUserOpSignature_tooShort_reverts() public {
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(_makeUserOp(abi.encodePacked(uint8(0x01)), 0));
    }

    function test_validateUserOpSignature_oldFormatWithMessagePoint_reverts() public {
        // Old layout still carried messagePoint(256)+mpSig(65): now an invalid (too-long) length.
        bytes memory sig = abi.encodePacked(
            uint8(0x01), uint256(1), NODE0, new bytes(256), new bytes(256), new bytes(65), new bytes(65)
        );
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(_makeUserOp(sig, 0));
    }

    function test_validateUserOpSignature_extraBytes_reverts() public {
        bytes memory sig = abi.encodePacked(_validFormatSig(1), uint8(0xFF));
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateUserOpSignature(_makeUserOp(sig, 0));
    }

    // ─── empty batch reverts ────────────────────────────────────────────

    function test_aggregateSignatures_emptyBatch_reverts() public {
        vm.expectRevert(AAStarBLSAggregator.EmptyBatch.selector);
        aggregator.aggregateSignatures(new PackedUserOperation[](0));
    }

    function test_validateSignatures_emptyBatch_reverts() public {
        vm.expectRevert(AAStarBLSAggregator.EmptyBatch.selector);
        aggregator.validateSignatures(new PackedUserOperation[](0), "");
    }

    function test_validateSignatures_malformedOpSignature_reverts() public {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(new bytes(0), 1); // empty op signature → _extractBLSData reverts
        vm.expectRevert(AAStarBLSAggregator.InvalidSignatureFormat.selector);
        aggregator.validateSignatures(ops, "");
    }

    // ─── Batch verification + #45 binding (EIP-2537 → prague only) ───────

    /// @dev Build an op's signature in the new format with a given embedded aggregate BLS sig.
    function _batchOpSig(bytes memory aggSig) internal view returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), uint256(3), NODE0, NODE1, NODE2, aggSig, new bytes(65));
    }

    /// @dev Batch of 2 ops with DIFFERENT userOpHashes (nonces 1 & 2), same node set, each with its
    ///      own valid aggregate → validateSignatures accepts (message points recomputed per-op).
    function test_validateSignatures_validBatch_accepts() public view {
        if (!_has2537()) return;
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _makeUserOp(_batchOpSig(AGG_NONCE1), 1);
        ops[1] = _makeUserOp(_batchOpSig(AGG_NONCE2), 2);
        aggregator.validateSignatures(ops, ""); // no revert == success
    }

    /// @dev #45-SAFE: present nonce-1's aggregate inside an op whose userOpHash is nonce-2's.
    ///      The aggregator recomputes the message point from the op's REAL userOpHash (nonce 2),
    ///      so the nonce-1 signature no longer matches → REJECT. Under the OLD embedded-messagePoint
    ///      design this replay would have verified.
    function test_validateSignatures_replayWrongUserOpHash_rejects() public {
        if (!_has2537()) return;
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(_batchOpSig(AGG_NONCE1), 2); // nonce-1 sig, but op nonce=2
        vm.expectRevert(AAStarBLSAggregator.AggregatedSignatureInvalid.selector);
        aggregator.validateSignatures(ops, "");
    }

    /// @dev Single valid op (nonce 1) verifies on its own.
    function test_validateSignatures_singleValidOp_accepts() public view {
        if (!_has2537()) return;
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _makeUserOp(_batchOpSig(AGG_NONCE1), 1);
        aggregator.validateSignatures(ops, "");
    }

    /// @dev Per-op infinity BLS signature is rejected before aggregation.
    function test_validateSignatures_perOpInfinityBlsSig_rejects() public {
        if (!_has2537()) return;
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _makeUserOp(_batchOpSig(AGG_NONCE1), 1);
        ops[1] = _makeUserOp(_batchOpSig(new bytes(256)), 2); // infinity blsSig
        vm.expectRevert(AAStarBLSAggregator.AggregatedSignatureInvalid.selector);
        aggregator.validateSignatures(ops, "");
    }

    /// @dev Mismatched node set across the batch is rejected.
    function test_validateSignatures_nodeSetMismatch_rejects() public {
        if (!_has2537()) return;
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _makeUserOp(_batchOpSig(AGG_NONCE1), 1);
        // op1 uses a different (2-node) set → NodeSetMismatch
        bytes memory sig1 = abi.encodePacked(uint8(0x01), uint256(2), NODE0, NODE1, AGG_NONCE2, new bytes(65));
        ops[1] = _makeUserOp(sig1, 2);
        vm.expectRevert(AAStarBLSAggregator.NodeSetMismatch.selector);
        aggregator.validateSignatures(ops, "");
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _makeUserOp(bytes memory sig, uint256 nonce) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(0x1234),
            nonce: nonce,
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
