// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAggregator} from "@account-abstraction/interfaces/IAggregator.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {AAStarBLSAlgorithm} from "../validators/AAStarBLSAlgorithm.sol";

/// @title AAStarBLSAggregator - IAggregator implementation for batch BLS verification
/// @notice Aggregates BLS signatures across multiple UserOps into a single pairing check.
///         Gas savings: N UserOps share one pairing (102,900 gas) instead of N pairings.
/// @dev Uses bilinearity of BLS12-381 pairing:
///      e(G, sum(sig_i)) = product(e(aggPK_i, msgPt_i))
///      For same-node-set batches (common case):
///      e(G, aggSig) * e(-aggPK, aggMsgPt) = 1   (only 2 pairs!)
contract AAStarBLSAggregator is IAggregator {
    // ─── Constants ──────────────────────────────────────────────────

    uint256 private constant G2_POINT_LENGTH = 256;

    /// @dev EIP-2537 precompile addresses
    address private constant G2ADD_PRECOMPILE = address(0x0e);
    address private constant PAIRING_PRECOMPILE = address(0x0f);

    /// @dev G1 generator point in EIP-2537 format (128 bytes)
    bytes private constant GENERATOR_POINT =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    /// @dev BLS12-381 field modulus p (split into two 256-bit limbs)
    uint256 private constant P_HIGH = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f624;
    uint256 private constant P_LOW = 0x1eabfffeb153ffffb9feffffffffaaab;

    uint256 private constant G1_POINT_LENGTH = 128;

    // ─── Storage ────────────────────────────────────────────────────

    /// @notice Reference to the BLS algorithm contract for key lookups
    AAStarBLSAlgorithm public immutable blsAlgorithm;

    // ─── Errors ─────────────────────────────────────────────────────

    error InvalidSignatureFormat();
    error PairingVerificationFailed();
    error EmptyBatch();
    error NodeSetMismatch();
    error AggregatedSignatureInvalid();

    // ─── Constructor ────────────────────────────────────────────────

    constructor(address _blsAlgorithm) {
        blsAlgorithm = AAStarBLSAlgorithm(_blsAlgorithm);
    }

    // ─── IAggregator Implementation ─────────────────────────────────

    /// @inheritdoc IAggregator
    /// @dev Validates per-UserOp non-BLS components (signature format check).
    ///      ECDSA×2 validation is done by the account's validateUserOp.
    ///      Returns empty bytes (no signature modification needed).
    function validateUserOpSignature(
        PackedUserOperation calldata userOp
    ) external pure override returns (bytes memory sigForUserOp) {
        // Just validate that the signature format is correct
        bytes calldata sig = userOp.signature;
        if (sig.length < 1) revert InvalidSignatureFormat();
        if (uint8(sig[0]) != 0x01) revert InvalidSignatureFormat();

        // Parse triple sig format
        bytes calldata sigData = sig[1:];
        if (sigData.length < 32) revert InvalidSignatureFormat();
        uint256 nodeIdsLength = uint256(bytes32(sigData[0:32]));
        uint256 expectedLength = 32 + nodeIdsLength * 32 + 256 + 256 + 65 + 65;
        if (sigData.length != expectedLength) revert InvalidSignatureFormat();

        // Return empty — signature is used as-is in handleAggregatedOps
        return "";
    }

    /// @inheritdoc IAggregator
    /// @dev Aggregates BLS signatures and message points from all UserOps.
    ///      Returns: aggBlsSig(256) | aggMsgPoint(256) | nodeIdsLength(32) | nodeIds(N×32)
    function aggregateSignatures(
        PackedUserOperation[] calldata userOps
    ) external view override returns (bytes memory aggregatedSignature) {
        if (userOps.length == 0) revert EmptyBatch();

        // Extract BLS sig and messagePoint from first UserOp
        (bytes32[] memory nodeIds0, bytes memory aggSig, bytes memory aggMsgPt) =
            _extractBLSData(userOps[0].signature);

        // Aggregate remaining UserOps
        for (uint256 i = 1; i < userOps.length; i++) {
            (bytes32[] memory nodeIdsI, bytes memory blsSig, bytes memory msgPt) =
                _extractBLSData(userOps[i].signature);

            // Verify same node set (for optimized 2-pair pairing)
            if (nodeIdsI.length != nodeIds0.length) revert NodeSetMismatch();
            for (uint256 j = 0; j < nodeIds0.length; j++) {
                if (nodeIdsI[j] != nodeIds0[j]) revert NodeSetMismatch();
            }

            // G2Add: aggregate BLS signatures
            aggSig = _g2Add(aggSig, blsSig);
            // G2Add: aggregate message points
            aggMsgPt = _g2Add(aggMsgPt, msgPt);
        }

        // Pack: aggBlsSig(256) | aggMsgPoint(256) | nodeIdsLength(32) | nodeIds(N×32)
        aggregatedSignature = abi.encodePacked(aggSig, aggMsgPt, uint256(nodeIds0.length));
        for (uint256 i = 0; i < nodeIds0.length; i++) {
            aggregatedSignature = abi.encodePacked(aggregatedSignature, nodeIds0[i]);
        }
    }

    /// @inheritdoc IAggregator
    /// @dev Batch-verifies all UserOps with a single pairing check.
    ///      Reverts if verification fails (EntryPoint expects revert on failure).
    function validateSignatures(
        PackedUserOperation[] calldata userOps,
        bytes calldata signature
    ) external view override {
        if (userOps.length == 0) revert EmptyBatch();

        // Parse aggregated signature
        if (signature.length < 512 + 32) revert InvalidSignatureFormat();

        bytes calldata aggBlsSig = signature[0:256];
        bytes calldata aggMsgPt = signature[256:512];
        uint256 nodeCount = uint256(bytes32(signature[512:544]));

        if (signature.length != 544 + nodeCount * 32) revert InvalidSignatureFormat();

        // Extract nodeIds
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        for (uint256 i = 0; i < nodeCount; i++) {
            nodeIds[i] = bytes32(signature[544 + i * 32:576 + i * 32]);
        }

        // Get aggregated public key from BLS algorithm (uses cache if available)
        bytes memory aggPK = blsAlgorithm.aggregateKeys(nodeIds);

        // Negate aggregated public key
        bytes memory negAggPK = _negateG1Point(aggPK);

        // Pairing check: e(G, aggBlsSig) * e(-aggPK, aggMsgPt) = 1
        bool valid = _verifyPairing(negAggPK, aggBlsSig, aggMsgPt);
        if (!valid) revert AggregatedSignatureInvalid();
    }

    // ─── Internal: BLS Data Extraction ──────────────────────────────

    /// @dev Extract BLS-relevant data from a UserOp's triple signature
    function _extractBLSData(
        bytes calldata signature
    ) internal pure returns (bytes32[] memory nodeIds, bytes memory blsSig, bytes memory msgPt) {
        // Skip algId byte (0x01)
        bytes calldata sigData = signature[1:];

        uint256 nodeIdsLength = uint256(bytes32(sigData[0:32]));
        uint256 nodeIdsDataLength = nodeIdsLength * 32;
        uint256 baseOffset = 32 + nodeIdsDataLength;

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

        // Extract message point (256 bytes)
        msgPt = new bytes(256);
        bytes calldata msgPtSlice = sigData[baseOffset + 256:baseOffset + 512];
        assembly {
            calldatacopy(add(msgPt, 0x20), msgPtSlice.offset, 256)
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

            // staticcall G2Add precompile (0x0e)
            let success := staticcall(gas(), 0x0e, input, 512, add(result, 0x20), 256)
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

    function _verifyPairing(
        bytes memory negatedKey,
        bytes calldata blsSig,
        bytes calldata msgPoint
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
            calldatacopy(dst, blsSig.offset, 256)

            // Pair 2: (negatedKey, msgPoint)
            let nkPtr := add(negatedKey, 0x20)
            dst := add(pairingData, 384)
            mstore(dst, mload(nkPtr))
            mstore(add(dst, 0x20), mload(add(nkPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(nkPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(nkPtr, 0x60)))

            dst := add(pairingData, 512)
            calldatacopy(dst, msgPoint.offset, 256)

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
