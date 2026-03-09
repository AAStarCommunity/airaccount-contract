// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title AAStarBLSAlgorithm - BLS12-381 aggregate signature verification with node management
/// @notice Extracted from YetAnotherAA AAStarValidator with assembly optimizations.
///         ABI-compatible with the NestJS backend (registerPublicKey, isRegistered, etc.)
/// @dev Uses EIP-2537 precompiles: G1Add (0x0b), Pairing (0x0f)
contract AAStarBLSAlgorithm is IAAStarAlgorithm {
    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev nodeId → G1 public key (128 bytes EIP-2537 format)
    mapping(bytes32 => bytes) public registeredKeys;

    /// @dev nodeId → registration status
    mapping(bytes32 => bool) public isRegistered;

    /// @dev All registered node identifiers
    bytes32[] public registeredNodes;

    /// @dev Cached aggregated public keys: keccak256(sorted nodeIds) → aggregated G1 key
    mapping(bytes32 => bytes) public cachedAggKeys;

    /// @dev Contract owner for admin functions
    address public owner;

    // ─── Constants ────────────────────────────────────────────────────

    /// @dev EIP-2537 precompile addresses
    address private constant G1ADD_PRECOMPILE = address(0x0b);
    address private constant PAIRING_PRECOMPILE = address(0x0f);

    uint256 private constant G1_POINT_LENGTH = 128;
    uint256 private constant G2_POINT_LENGTH = 256;
    uint256 private constant PAIRING_INPUT_LENGTH = 768; // 2 × (G1 + G2)

    /// @dev BLS12-381 field modulus p (split into two 256-bit limbs)
    uint256 private constant P_HIGH = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f624;
    uint256 private constant P_LOW = 0x1eabfffeb153ffffb9feffffffffaaab;

    /// @dev G1 generator point in EIP-2537 format (128 bytes)
    bytes private constant GENERATOR_POINT =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    // ─── Events ───────────────────────────────────────────────────────

    event PublicKeyRegistered(bytes32 indexed nodeId, bytes publicKey);
    event PublicKeyUpdated(bytes32 indexed nodeId, bytes oldKey, bytes newKey);
    event PublicKeyRevoked(bytes32 indexed nodeId);
    event AggKeyCached(bytes32 indexed setHash, uint256 nodeCount);
    event AggKeyCacheInvalidated(bytes32 indexed nodeId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyOwner();
    error InvalidNodeId();
    error InvalidKeyLength();
    error NodeAlreadyRegistered();
    error NodeNotRegistered();
    error ArrayLengthMismatch();
    error EmptyArrays();
    error NoNodesProvided();
    error InvalidSignatureLength();
    error InvalidMessageLength();
    error PairingFailed();

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─── IAAStarAlgorithm Implementation ──────────────────────────────

    /// @inheritdoc IAAStarAlgorithm
    /// @dev Expects signature format: [nodeIds...][blsSignature(256)][messagePoint(256)]
    ///      The nodeIds count is derived from (sig.length - 512) / 32
    function validate(bytes32 /*hash*/, bytes calldata signature) external view override returns (uint256) {
        // Parse: variable-length nodeIds + 256-byte BLS sig + 256-byte messagePoint
        uint256 fixedLen = G2_POINT_LENGTH + G2_POINT_LENGTH; // 512
        if (signature.length <= fixedLen) return 1;

        uint256 nodeIdsBytes = signature.length - fixedLen;
        if (nodeIdsBytes == 0 || nodeIdsBytes % 32 != 0) return 1;

        uint256 nodeCount = nodeIdsBytes / 32;
        bytes32[] memory nodeIds = new bytes32[](nodeCount);
        for (uint256 i = 0; i < nodeCount; i++) {
            nodeIds[i] = bytes32(signature[i * 32:(i + 1) * 32]);
        }

        bytes calldata blsSignature = signature[nodeIdsBytes:nodeIdsBytes + G2_POINT_LENGTH];
        bytes calldata messagePoint = signature[nodeIdsBytes + G2_POINT_LENGTH:];

        bool valid = _validateBLSSignature(nodeIds, blsSignature, messagePoint);
        return valid ? 0 : 1;
    }

    // ─── BLS Verification (NestJS-compatible ABI) ─────────────────────

    /// @notice Verify aggregate BLS signature (view, no events)
    function validateAggregateSignature(
        bytes32[] calldata nodeIds,
        bytes calldata signature,
        bytes calldata messagePoint
    ) external view returns (bool) {
        if (nodeIds.length == 0) revert NoNodesProvided();
        if (signature.length != G2_POINT_LENGTH) revert InvalidSignatureLength();
        if (messagePoint.length != G2_POINT_LENGTH) revert InvalidMessageLength();
        return _validateBLSSignature(nodeIds, signature, messagePoint);
    }

    /// @notice Verify aggregate BLS signature (state-changing for event compat)
    function verifyAggregateSignature(
        bytes32[] calldata nodeIds,
        bytes calldata signature,
        bytes calldata messagePoint
    ) external returns (bool) {
        if (nodeIds.length == 0) revert NoNodesProvided();
        if (signature.length != G2_POINT_LENGTH) revert InvalidSignatureLength();
        if (messagePoint.length != G2_POINT_LENGTH) revert InvalidMessageLength();
        return _validateBLSSignature(nodeIds, signature, messagePoint);
    }

    // ─── Core BLS Logic (Assembly Optimized) ──────────────────────────

    function _validateBLSSignature(
        bytes32[] memory nodeIds,
        bytes calldata signature,
        bytes calldata messagePoint
    ) internal view returns (bool) {
        // 1. Load public keys from storage and aggregate
        bytes memory aggregatedKey = _aggregateNodeKeys(nodeIds);

        // 2. Negate aggregated key
        bytes memory negatedKey = _negateG1PointAssembly(aggregatedKey);

        // 3. Build pairing input and verify
        return _verifyPairing(negatedKey, signature, messagePoint, nodeIds.length);
    }

    /// @dev Aggregate public keys of registered nodes using G1Add precompile.
    ///      Checks cache first; falls back to on-chain aggregation if not cached.
    function _aggregateNodeKeys(bytes32[] memory nodeIds) internal view returns (bytes memory result) {
        // Check cache
        bytes32 setHash = computeSetHash(nodeIds);
        bytes memory cached = cachedAggKeys[setHash];
        if (cached.length == G1_POINT_LENGTH) return cached;

        // Cache miss: aggregate from storage
        bytes32 firstNodeId = nodeIds[0];
        if (!isRegistered[firstNodeId]) revert NodeNotRegistered();
        result = registeredKeys[firstNodeId];

        for (uint256 i = 1; i < nodeIds.length; i++) {
            bytes32 nodeId = nodeIds[i];
            if (!isRegistered[nodeId]) revert NodeNotRegistered();
            bytes memory key = registeredKeys[nodeId];
            result = _g1Add(result, key);
        }
    }

    /// @notice Pre-compute and cache an aggregated public key for a node set.
    ///         Call this off-chain before submitting batched UserOps for gas savings.
    /// @param nodeIds The node identifiers (order matters for hash)
    function cacheAggregatedKey(bytes32[] calldata nodeIds) external {
        if (nodeIds.length == 0) revert NoNodesProvided();

        // Aggregate
        bytes memory result = registeredKeys[nodeIds[0]];
        if (!isRegistered[nodeIds[0]]) revert NodeNotRegistered();

        for (uint256 i = 1; i < nodeIds.length; i++) {
            if (!isRegistered[nodeIds[i]]) revert NodeNotRegistered();
            result = _g1Add(result, registeredKeys[nodeIds[i]]);
        }

        bytes32 setHash = computeSetHash(nodeIds);
        cachedAggKeys[setHash] = result;
        emit AggKeyCached(setHash, nodeIds.length);
    }

    /// @notice Compute the cache key for a set of nodeIds
    function computeSetHash(bytes32[] memory nodeIds) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(nodeIds));
    }

    /// @dev G1 point addition via EIP-2537 precompile with assembly
    function _g1Add(bytes memory p1, bytes memory p2) internal view returns (bytes memory result) {
        result = new bytes(G1_POINT_LENGTH);
        assembly {
            // Allocate 256 bytes for input (p1 || p2)
            let input := mload(0x40)
            mstore(0x40, add(input, 256))

            // Copy p1 (128 bytes from p1+32)
            let src := add(p1, 0x20)
            let dst := input
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
            mstore(add(dst, 0x40), mload(add(src, 0x40)))
            mstore(add(dst, 0x60), mload(add(src, 0x60)))

            // Copy p2 (128 bytes from p2+32)
            src := add(p2, 0x20)
            dst := add(input, 128)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
            mstore(add(dst, 0x40), mload(add(src, 0x40)))
            mstore(add(dst, 0x60), mload(add(src, 0x60)))

            // staticcall G1Add precompile
            let success := staticcall(gas(), 0x0b, input, 256, add(result, 0x20), 128)
            if iszero(success) { revert(0, 0) }
        }
    }

    /// @dev Negate G1 point: -P = (x, p - y). Assembly-optimized.
    function _negateG1PointAssembly(bytes memory point) internal pure returns (bytes memory negated) {
        negated = new bytes(G1_POINT_LENGTH);
        assembly {
            let src := add(point, 0x20)
            let dst := add(negated, 0x20)

            // Copy x coordinate unchanged (first 64 bytes = 2 words)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))

            // Check if point is infinity (all zeros)
            let isZero := 1
            for { let i := 0 } lt(i, 4) { i := add(i, 1) } {
                if mload(add(src, mul(i, 0x20))) { isZero := 0 }
            }

            if iszero(isZero) {
                // Extract y coordinate: bytes 80-127 (48 bytes within 64-byte chunk)
                // y_high = 32 bytes at offset 80
                let yPtr := add(src, 80)
                let y_high := mload(yPtr)
                // y_low = 16 bytes at offset 112, shifted right 128
                let y_low := shr(128, mload(add(yPtr, 32)))

                // Compute p - y (two-limb subtraction)
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
                    // Borrow needed
                    neg_y_low := add(sub(p_low, y_low), add(not(0), 1))
                    neg_y_high := sub(sub(p_high, y_high), 1)
                }

                // Store negated y: zero padding at bytes 64-79, then neg_y at bytes 80-127
                mstore(add(dst, 0x40), 0) // Zero padding (bytes 64-95, top 16 bytes)
                mstore(add(dst, 80), neg_y_high) // bytes 80-111
                mstore(add(dst, 112), shl(128, neg_y_low)) // bytes 112-127 (16 bytes)
            }
        }
    }

    /// @dev Build pairing data and verify via precompile. Assembly-optimized.
    function _verifyPairing(
        bytes memory negatedKey,
        bytes calldata signature,
        bytes calldata messagePoint,
        uint256 nodeCount
    ) internal view returns (bool) {
        uint256 requiredGas = _calculateRequiredGas(nodeCount);

        // Load generator point into memory (can't reference bytes constant in assembly)
        bytes memory gen = GENERATOR_POINT;

        bool isValid;
        assembly {
            // Allocate 768 bytes for pairing input
            let pairingData := mload(0x40)
            mstore(0x40, add(pairingData, 768))

            // ── First pairing: (generator, signature) ──
            let genPtr := add(gen, 0x20)
            let dst := pairingData
            mstore(dst, mload(genPtr))
            mstore(add(dst, 0x20), mload(add(genPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(genPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(genPtr, 0x60)))

            // Copy signature (256 bytes from calldata)
            dst := add(pairingData, 128)
            calldatacopy(dst, signature.offset, 256)

            // ── Second pairing: (negatedKey, messagePoint) ──
            let nkPtr := add(negatedKey, 0x20)
            dst := add(pairingData, 384)
            mstore(dst, mload(nkPtr))
            mstore(add(dst, 0x20), mload(add(nkPtr, 0x20)))
            mstore(add(dst, 0x40), mload(add(nkPtr, 0x40)))
            mstore(add(dst, 0x60), mload(add(nkPtr, 0x60)))

            // Copy messagePoint (256 bytes from calldata)
            dst := add(pairingData, 512)
            calldatacopy(dst, messagePoint.offset, 256)

            // ── Call pairing precompile ──
            let resultPtr := mload(0x40)
            mstore(0x40, add(resultPtr, 0x20))

            let success := staticcall(requiredGas, 0x0f, pairingData, 768, resultPtr, 0x20)

            if success {
                isValid := eq(mload(resultPtr), 1)
            }
        }

        return isValid;
    }

    // ─── Gas Calculation ──────────────────────────────────────────────

    function _calculateRequiredGas(uint256 nodeCount) internal pure returns (uint256 requiredGas) {
        if (nodeCount == 0) return 0;

        // EIP-2537 pairing: 32600 * k + 37700, k = 2 pairings
        uint256 pairingCost = 102_900;
        // G1Add: (nodeCount - 1) * 500
        uint256 g1AddCost = nodeCount > 1 ? (nodeCount - 1) * 500 : 0;
        // Storage reads: nodeCount * 2100
        uint256 storageCost = nodeCount * 2100;
        // EVM overhead
        uint256 evmCost = 50_000 + (nodeCount * 1000);

        requiredGas = ((pairingCost + g1AddCost + storageCost + evmCost) * 125) / 100;

        // Clamp to [150k, 2M]
        if (requiredGas < 150_000) requiredGas = 150_000;
        if (requiredGas > 2_000_000) requiredGas = 2_000_000;
    }

    /// @notice Public gas estimate (NestJS-compatible)
    function getGasEstimate(uint256 nodeCount) external pure returns (uint256) {
        return _calculateRequiredGas(nodeCount);
    }

    // ─── Node Management (ABI-compatible with YetAA) ──────────────────

    function registerPublicKey(bytes32 nodeId, bytes calldata publicKey) external {
        if (nodeId == bytes32(0)) revert InvalidNodeId();
        if (publicKey.length != G1_POINT_LENGTH) revert InvalidKeyLength();
        if (isRegistered[nodeId]) revert NodeAlreadyRegistered();

        registeredKeys[nodeId] = publicKey;
        isRegistered[nodeId] = true;
        registeredNodes.push(nodeId);

        emit PublicKeyRegistered(nodeId, publicKey);
    }

    function updatePublicKey(bytes32 nodeId, bytes calldata newPublicKey) external onlyOwner {
        if (!isRegistered[nodeId]) revert NodeNotRegistered();
        if (newPublicKey.length != G1_POINT_LENGTH) revert InvalidKeyLength();

        bytes memory oldKey = registeredKeys[nodeId];
        registeredKeys[nodeId] = newPublicKey;

        emit PublicKeyUpdated(nodeId, oldKey, newPublicKey);
    }

    function revokePublicKey(bytes32 nodeId) external onlyOwner {
        if (!isRegistered[nodeId]) revert NodeNotRegistered();

        delete registeredKeys[nodeId];
        isRegistered[nodeId] = false;

        // Pop-and-swap removal
        uint256 len = registeredNodes.length;
        for (uint256 i = 0; i < len; i++) {
            if (registeredNodes[i] == nodeId) {
                registeredNodes[i] = registeredNodes[len - 1];
                registeredNodes.pop();
                break;
            }
        }

        emit PublicKeyRevoked(nodeId);
    }

    function batchRegisterPublicKeys(bytes32[] calldata nodeIds, bytes[] calldata publicKeys) external onlyOwner {
        if (nodeIds.length != publicKeys.length) revert ArrayLengthMismatch();
        if (nodeIds.length == 0) revert EmptyArrays();

        for (uint256 i = 0; i < nodeIds.length; i++) {
            if (nodeIds[i] == bytes32(0)) revert InvalidNodeId();
            if (publicKeys[i].length != G1_POINT_LENGTH) revert InvalidKeyLength();
            if (isRegistered[nodeIds[i]]) revert NodeAlreadyRegistered();

            registeredKeys[nodeIds[i]] = publicKeys[i];
            isRegistered[nodeIds[i]] = true;
            registeredNodes.push(nodeIds[i]);

            emit PublicKeyRegistered(nodeIds[i], publicKeys[i]);
        }
    }

    function getRegisteredNodeCount() external view returns (uint256) {
        return registeredNodes.length;
    }

    function getRegisteredNodes(
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory nodeIds, bytes[] memory publicKeys) {
        uint256 total = registeredNodes.length;
        if (offset >= total) {
            return (new bytes32[](0), new bytes[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 length = end - offset;

        nodeIds = new bytes32[](length);
        publicKeys = new bytes[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 nid = registeredNodes[offset + i];
            nodeIds[i] = nid;
            publicKeys[i] = registeredKeys[nid];
        }
    }

    /// @notice Public aggregation for external callers (e.g., BLSAggregator)
    function aggregateKeys(bytes32[] calldata nodeIds) external view returns (bytes memory) {
        if (nodeIds.length == 0) revert NoNodesProvided();

        // Check cache first
        bytes32 setHash = computeSetHash(nodeIds);
        bytes memory cached = cachedAggKeys[setHash];
        if (cached.length == G1_POINT_LENGTH) return cached;

        bytes memory result = registeredKeys[nodeIds[0]];
        if (!isRegistered[nodeIds[0]]) revert NodeNotRegistered();

        for (uint256 i = 1; i < nodeIds.length; i++) {
            if (!isRegistered[nodeIds[i]]) revert NodeNotRegistered();
            result = _g1Add(result, registeredKeys[nodeIds[i]]);
        }
        return result;
    }

    /// @dev G2 point addition via EIP-2537 precompile (address 0x0e)
    function g2Add(bytes memory p1, bytes memory p2) external view returns (bytes memory result) {
        return _g2Add(p1, p2);
    }

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

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == owner) revert InvalidNodeId();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }
}
