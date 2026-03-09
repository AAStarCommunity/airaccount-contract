// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/// @title AAStarValidator - Generic algorithm router for signature validation
/// @notice Routes signature validation to registered algorithm implementations via algId.
///         algId is the first byte of the signature: 0x01=BLS, 0x02=ECDSA, 0x03=P256, etc.
///         Only-add registry: algorithms can be registered but never removed or replaced.
/// @dev Used by AAStarAirAccountBase for external-call validation (non-inlined algorithms)
contract AAStarValidator is IAAStarValidator {
    // ─── Storage ──────────────────────────────────────────────────────

    /// @dev algId → algorithm implementation address
    mapping(uint8 => address) public algorithms;

    /// @dev Contract owner
    address public owner;

    // ─── Events ───────────────────────────────────────────────────────

    event AlgorithmRegistered(uint8 indexed algId, address indexed algorithm);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyOwner();
    error AlgorithmAlreadyRegistered();
    error AlgorithmNotRegistered();
    error InvalidAlgorithmAddress();
    error EmptySignature();

    // ─── Constructor ──────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─── IAAStarValidator Implementation ──────────────────────────────

    /// @inheritdoc IAAStarValidator
    /// @dev Routes to algorithm based on sig[0] (algId). Strips the algId byte before forwarding.
    function validateSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (uint256 validationData) {
        if (signature.length == 0) revert EmptySignature();

        uint8 algId = uint8(signature[0]);
        address alg = algorithms[algId];
        if (alg == address(0)) revert AlgorithmNotRegistered();

        // Forward remaining signature (without algId byte) to algorithm
        return IAAStarAlgorithm(alg).validate(hash, signature[1:]);
    }

    /// @inheritdoc IAAStarValidator
    function getAlgorithm(uint8 algId) external view override returns (address) {
        return algorithms[algId];
    }

    // ─── Algorithm Registry ───────────────────────────────────────────

    /// @notice Register an algorithm implementation. Only-add: cannot update or remove.
    /// @param algId The algorithm identifier (first byte of signature)
    /// @param algorithm The algorithm contract address
    function registerAlgorithm(uint8 algId, address algorithm) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (algorithm == address(0)) revert InvalidAlgorithmAddress();
        if (algorithms[algId] != address(0)) revert AlgorithmAlreadyRegistered();

        algorithms[algId] = algorithm;
        emit AlgorithmRegistered(algId, algorithm);
    }

    // ─── Ownership ────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (newOwner == address(0)) revert InvalidAlgorithmAddress();

        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }
}
