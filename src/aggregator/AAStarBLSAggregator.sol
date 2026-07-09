// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAggregator} from "@account-abstraction/interfaces/IAggregator.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {AAStarBLSKeyRegistry} from "../validators/AAStarBLSKeyRegistry.sol";

/// @title AAStarBLSAggregator - IAggregator implementation for batch BLS verification
/// @notice Aggregates BLS signatures across multiple UserOps into a single pairing check.
///         Gas savings: N UserOps share one pairing (102,900 gas) instead of N pairings.
/// @dev Uses bilinearity of BLS12-381 pairing:
///      e(G, sum(sig_i)) = product(e(aggPK_i, msgPt_i))
///      For same-node-set batches (common case):
///      e(G, aggSig) * e(-aggPK, aggMsgPt) = 1   (only 2 pairs!)
///
///      issue #45 Fix 1 (batch path): each op's message point is RECOMPUTED on-chain from its own
///      userOpHash (blsAlgorithm.hashToG2(entryPoint.getUserOpHash(op_i))) and THOSE are aggregated
///      into aggMsgPt — NOT the caller-supplied messagePoint embedded in the op signature. This
///      binds every op's BLS contribution to its exact userOpHash, closing the batch replay hole
///      (a valid aggregate for {hashA,hashB} can no longer be presented for a different batch).
///      Same node-set across the batch is still required (NodeSetMismatch).
contract AAStarBLSAggregator is IAggregator {
    // ─── Constants ──────────────────────────────────────────────────

    uint256 private constant G2_POINT_LENGTH = 256;

    /// @dev EIP-2537 precompile addresses (final Pectra/Prague addressing). G2ADD is 0x0d
    ///      (0x0e is G2MSM — the prior 0x0e here was a latent bug that reverts on real points;
    ///      fixed under issue #45 now that the batch path is exercised on-chain).
    address private constant G2ADD_PRECOMPILE = address(0x0d);
    address private constant PAIRING_PRECOMPILE = address(0x0f);

    /// @dev G1 generator point in EIP-2537 format (128 bytes)
    bytes private constant GENERATOR_POINT =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    /// @dev BLS12-381 field modulus p (split into two 256-bit limbs)
    uint256 private constant P_HIGH = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f624;
    uint256 private constant P_LOW = 0x1eabfffeb153ffffb9feffffffffaaab;

    uint256 private constant G1_POINT_LENGTH = 128;

    // ─── Storage ────────────────────────────────────────────────────

    /// @notice Reference to the BLS algorithm contract for key lookups + on-chain hash_to_curve.
    AAStarBLSKeyRegistry public immutable blsAlgorithm;

    /// @notice The ERC-4337 EntryPoint, used to derive each op's userOpHash for the #45 binding.
    IEntryPoint public immutable entryPoint;

    // ─── Errors ─────────────────────────────────────────────────────

    error InvalidSignatureFormat();
    error PairingVerificationFailed();
    error EmptyBatch();
    error NodeSetMismatch();
    error AggregatedSignatureInvalid();

    // ─── Constructor ────────────────────────────────────────────────

    constructor(address _blsAlgorithm, address _entryPoint) {
        blsAlgorithm = AAStarBLSKeyRegistry(_blsAlgorithm);
        entryPoint = IEntryPoint(_entryPoint);
    }

    /// @dev issue #45: recompute op_i's BLS message point on-chain from its userOpHash,
    ///      identical to the single-op path (AAStarBLSKeyRegistry.validate). NOT the embedded point.
    function _messagePointForOp(PackedUserOperation calldata op) internal view returns (bytes memory) {
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        return blsAlgorithm.hashToG2(userOpHash);
    }

    // ─── IAggregator Implementation ─────────────────────────────────

    /// @inheritdoc IAggregator
    /// @dev Validates per-UserOp non-BLS components (signature format check).
    ///      ECDSA×2 validation is done by the account's validateUserOp.
    ///      Returns empty bytes (no signature modification needed).
    function validateUserOpSignature(
        PackedUserOperation calldata userOp
    ) external pure override returns (bytes memory sigForUserOp) {
        // Validate the triple-sig format (issue #45: messagePoint + messagePointSig removed).
        bytes calldata sig = userOp.signature;
        if (sig.length < 1) revert InvalidSignatureFormat();
        if (uint8(sig[0]) != 0x01) revert InvalidSignatureFormat();

        // New format: [nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][aaSignature(65)]
        bytes calldata sigData = sig[1:];
        if (sigData.length < 32) revert InvalidSignatureFormat();
        uint256 nodeIdsLength = uint256(bytes32(sigData[0:32]));
        uint256 expectedLength = 32 + nodeIdsLength * 32 + 256 + 65;
        if (sigData.length != expectedLength) revert InvalidSignatureFormat();

        // Return empty — signature is used as-is in handleAggregatedOps
        return "";
    }

    /// @inheritdoc IAggregator
    /// @dev Aggregates BLS signatures from all UserOps; the aggregate MESSAGE POINT is recomputed
    ///      from each op's userOpHash (issue #45), NOT taken from the op signature.
    ///      Returns: aggBlsSig(256) | aggMsgPoint(256) | nodeIdsLength(32) | nodeIds(N×32).
    ///      (validateSignatures ignores the returned blob and recomputes independently; the
    ///      aggMsgPoint is included for parity/diagnostics only.)
    function aggregateSignatures(
        PackedUserOperation[] calldata userOps
    ) external view override returns (bytes memory aggregatedSignature) {
        if (userOps.length == 0) revert EmptyBatch();

        // Extract BLS sig from the first op; recompute its message point from userOpHash.
        (bytes32[] memory nodeIds0, bytes memory aggSig) = _extractBLSData(userOps[0].signature);
        bytes memory aggMsgPt = _messagePointForOp(userOps[0]);

        // Aggregate remaining UserOps
        for (uint256 i = 1; i < userOps.length; i++) {
            (bytes32[] memory nodeIdsI, bytes memory blsSig) = _extractBLSData(userOps[i].signature);

            // Verify same node set (for optimized 2-pair pairing)
            if (nodeIdsI.length != nodeIds0.length) revert NodeSetMismatch();
            for (uint256 j = 0; j < nodeIds0.length; j++) {
                if (nodeIdsI[j] != nodeIds0[j]) revert NodeSetMismatch();
            }

            // G2Add: aggregate BLS signatures + recomputed (userOpHash-bound) message points.
            aggSig = _g2Add(aggSig, blsSig);
            aggMsgPt = _g2Add(aggMsgPt, _messagePointForOp(userOps[i]));
        }

        // Pack: aggBlsSig(256) | aggMsgPoint(256) | nodeIdsLength(32) | nodeIds(N×32)
        aggregatedSignature = abi.encodePacked(aggSig, aggMsgPt, uint256(nodeIds0.length));
        for (uint256 i = 0; i < nodeIds0.length; i++) {
            aggregatedSignature = abi.encodePacked(aggregatedSignature, nodeIds0[i]);
        }
    }

    /// @inheritdoc IAggregator
    /// @dev v0.17.2-beta.1 round 5 HIGH-3 (Codex): the caller-supplied `signature` is
    ///      now IGNORED. Without this binding, a malicious bundler could submit a valid
    ///      aggregate for unrelated data while batching UserOps whose embedded BLS payloads
    ///      were never included — turning batch verification into a reusable proof
    ///      unrelated to the actual batch. We now recompute the aggregate from
    ///      `userOps[i].signature` and pair against THAT — what the EntryPoint actually
    ///      executes is what we verify.
    function validateSignatures(
        PackedUserOperation[] calldata userOps,
        bytes calldata /*signature*/
    ) external view override {
        if (userOps.length == 0) revert EmptyBatch();

        // Recompute the aggregate from the actual UserOps in the batch.
        // issue #45: the BLS signature is taken from each op, but the MESSAGE POINT is recomputed
        // from that op's userOpHash (hashToG2) — NOT the embedded point. So a valid aggregate for
        // one set of userOpHashes cannot be replayed under a batch with different userOpHashes.
        (bytes32[] memory nodeIds, bytes memory aggSig) = _extractBLSData(userOps[0].signature);
        bytes memory aggMsgPt = _messagePointForOp(userOps[0]);

        // v0.17.2-beta.1 round 6 follow-up (Codex): PER-USEROP infinity reject.
        //
        // Round 5 HIGH-2 fix only checked infinity on the FINAL recomputed aggregate. Round 6
        // verification caught the residual: a malicious bundler can submit `userOps[i]` whose
        // embedded BLS sig is infinity — G2Add(valid, infinity) = valid (identity element),
        // so the final aggregate stays non-infinity and passes the post-aggregate check, BUT
        // that UserOp's BLS factor is effectively never verified. Each per-UserOp component
        // must therefore be rejected at infinity before G2Add. (The recomputed message point is
        // never infinity — hash_to_curve does not return it — but assert it for symmetry.)
        if (_isG2Infinity(aggSig)) revert AggregatedSignatureInvalid();
        if (_isG2Infinity(aggMsgPt)) revert AggregatedSignatureInvalid();

        for (uint256 i = 1; i < userOps.length; i++) {
            (bytes32[] memory nodeIdsI, bytes memory blsSig) = _extractBLSData(userOps[i].signature);
            bytes memory msgPt = _messagePointForOp(userOps[i]);

            // All UserOps in a batch must share the same node set (already enforced by
            // aggregateSignatures; re-enforced here so validateSignatures is independent).
            if (nodeIdsI.length != nodeIds.length) revert NodeSetMismatch();
            for (uint256 j = 0; j < nodeIds.length; j++) {
                if (nodeIdsI[j] != nodeIds[j]) revert NodeSetMismatch();
            }

            // Round 6 per-UserOp infinity reject (see comment above).
            if (_isG2Infinity(blsSig)) revert AggregatedSignatureInvalid();
            if (_isG2Infinity(msgPt)) revert AggregatedSignatureInvalid();

            aggSig = _g2Add(aggSig, blsSig);
            aggMsgPt = _g2Add(aggMsgPt, msgPt);
        }

        // Defensive post-aggregate check (belt + suspenders against pathological sums-to-infinity
        // among non-infinity per-UserOp components).
        if (_isG2Infinity(aggSig)) revert AggregatedSignatureInvalid();
        if (_isG2Infinity(aggMsgPt)) revert AggregatedSignatureInvalid();

        // Get aggregated public key from BLS algorithm (cache removed in beta.1, always on-demand).
        bytes memory aggPK = blsAlgorithm.aggregateKeys(nodeIds);

        // Negate aggregated public key
        bytes memory negAggPK = _negateG1Point(aggPK);

        // Pairing check: e(G, aggSig) * e(-aggPK, aggMsgPt) = 1
        bool valid = _verifyPairing(negAggPK, aggSig, aggMsgPt);
        if (!valid) revert AggregatedSignatureInvalid();
    }

    /// @dev v0.17.2-beta.1 round 5 HIGH-2: G2 infinity (all-zero 256-byte encoding) check.
    function _isG2Infinity(bytes memory point) internal pure returns (bool) {
        if (point.length != 256) return false;
        for (uint256 i = 0; i < 256; i++) {
            if (point[i] != 0) return false;
        }
        return true;
    }

    // ─── Internal: BLS Data Extraction ──────────────────────────────

    /// @dev Extract nodeIds + BLS signature from a UserOp's triple signature.
    ///      issue #45: the messagePoint is NO LONGER read here — it is recomputed from the op's
    ///      userOpHash in _messagePointForOp. New format: [0x01][len(32)][nodeIds][blsSig(256)][aaSig(65)].
    function _extractBLSData(
        bytes calldata signature
    ) internal pure returns (bytes32[] memory nodeIds, bytes memory blsSig) {
        if (signature.length < 1 || uint8(signature[0]) != 0x01) revert InvalidSignatureFormat();
        // Skip algId byte (0x01)
        bytes calldata sigData = signature[1:];

        if (sigData.length < 32) revert InvalidSignatureFormat();
        uint256 nodeIdsLength = uint256(bytes32(sigData[0:32]));
        uint256 nodeIdsDataLength = nodeIdsLength * 32;
        uint256 baseOffset = 32 + nodeIdsDataLength;
        // Strict length: [len][nodeIds][blsSig(256)][aaSig(65)].
        if (sigData.length != baseOffset + 256 + 65) revert InvalidSignatureFormat();

        // Extract nodeIds
        nodeIds = new bytes32[](nodeIdsLength);
        for (uint256 i = 0; i < nodeIdsLength; i++) {
            nodeIds[i] = bytes32(sigData[32 + i * 32:64 + i * 32]);
        }

        // Extract BLS signature (256 bytes)
        blsSig = new bytes(256);
        bytes calldata blsSigSlice = sigData[baseOffset:baseOffset + 256];
        assembly {
            calldatacopy(add(blsSig, 0x20), blsSigSlice.offset, 256)
        }
    }

    // ─── Internal: G2 Point Addition ────────────────────────────────

    function _g2Add(bytes memory p1, bytes memory p2) internal view returns (bytes memory result) {
        result = new bytes(G2_POINT_LENGTH);
        assembly {
            let input := mload(0x40)
            mstore(0x40, add(input, 512))

            // Copy p1 (256 bytes)
            let src := add(p1, 0x20)
            let dst := input
            for { let i := 0 } lt(i, 8) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 0x20)), mload(add(src, mul(i, 0x20))))
            }

            // Copy p2 (256 bytes)
            src := add(p2, 0x20)
            dst := add(input, 256)
            for { let i := 0 } lt(i, 8) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 0x20)), mload(add(src, mul(i, 0x20))))
            }

            // staticcall G2Add precompile (0x0d — final EIP-2537 addressing; 0x0e is G2MSM)
            let success := staticcall(gas(), 0x0d, input, 512, add(result, 0x20), 256)
            if iszero(success) { revert(0, 0) }
        }
    }

    // ─── Internal: G1 Point Negation ────────────────────────────────

    function _negateG1Point(bytes memory point) internal pure returns (bytes memory negated) {
        negated = new bytes(G1_POINT_LENGTH);
        assembly {
            let src := add(point, 0x20)
            let dst := add(negated, 0x20)

            // Copy x unchanged
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))

            // Check if zero
            let isZero := 1
            for { let i := 0 } lt(i, 4) { i := add(i, 1) } {
                if mload(add(src, mul(i, 0x20))) { isZero := 0 }
            }

            if iszero(isZero) {
                let yPtr := add(src, 80)
                let y_high := mload(yPtr)
                let y_low := shr(128, mload(add(yPtr, 32)))

                let p_high := P_HIGH
                let p_low := P_LOW

                let neg_y_low
                let neg_y_high
                switch lt(p_low, y_low)
                case 0 {
                    neg_y_low := sub(p_low, y_low)
                    neg_y_high := sub(p_high, y_high)
                }
                default {
                    neg_y_low := add(sub(p_low, y_low), add(not(0), 1))
                    neg_y_high := sub(sub(p_high, y_high), 1)
                }

                mstore(add(dst, 0x40), 0)
                mstore(add(dst, 80), neg_y_high)
                mstore(add(dst, 112), shl(128, neg_y_low))
            }
        }
    }

    // ─── Internal: Pairing Verification ─────────────────────────────

    /// @dev v0.17.2-beta.1 round 5 HIGH-3: blsSig + msgPoint now arrive as `bytes memory`
    ///      because they're the result of in-memory `_g2Add` re-aggregation (not the
    ///      caller-supplied calldata slice the prior trust-the-caller design used).
    function _verifyPairing(
        bytes memory negatedKey,
        bytes memory blsSig,
        bytes memory msgPoint
    ) internal view returns (bool isValid) {
        bytes memory gen = GENERATOR_POINT;

        assembly {
            let pairingData := mload(0x40)
            mstore(0x40, add(pairingData, 768))

            // Pair 1: (generator, blsSig)
            let genPtr := add(gen, 0x20)
            let dst := pairingData
            mstore(dst, mload(genPtr))
            mstore(add(dst, 0x20), mload(add(genPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(genPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(genPtr, 0x60)))

            dst := add(pairingData, 128)
            // memory-to-memory copy (Cancun MCOPY) — blsSig is now `bytes memory` after
            // the round-5 HIGH-3 re-aggregation; skip length prefix.
            mcopy(dst, add(blsSig, 0x20), 256)

            // Pair 2: (negatedKey, msgPoint)
            let nkPtr := add(negatedKey, 0x20)
            dst := add(pairingData, 384)
            mstore(dst, mload(nkPtr))
            mstore(add(dst, 0x20), mload(add(nkPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(nkPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(nkPtr, 0x60)))

            dst := add(pairingData, 512)
            mcopy(dst, add(msgPoint, 0x20), 256)

            // Call pairing precompile
            let resultPtr := mload(0x40)
            mstore(0x40, add(resultPtr, 0x20))

            let success := staticcall(gas(), 0x0f, pairingData, 768, resultPtr, 0x20)
            if success {
                isValid := eq(mload(resultPtr), 1)
            }
        }
    }
}
