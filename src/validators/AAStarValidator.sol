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

    /// @dev Pending proposals: algId → Proposal
    mapping(uint8 => Proposal) public proposals;

    /// @dev Contract owner
    address public owner;

    /// @dev Once true, registerAlgorithm is permanently disabled; use proposeAlgorithm + executeProposal instead
    bool public setupComplete;

    /// @dev Timelock duration for algorithm proposals
    uint256 public constant TIMELOCK_DURATION = 7 days;

    // ─── Structs ────────────────────────────────────────────────────

    struct Proposal {
        address algorithm;
        uint256 proposedAt;
    }

    // ─── Events ───────────────────────────────────────────────────────

    event AlgorithmRegistered(uint8 indexed algId, address indexed algorithm);
    event AlgorithmProposed(uint8 indexed algId, address indexed algorithm, uint256 executeAfter);
    event ProposalCancelled(uint8 indexed algId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SetupFinalized();

    // ─── Errors ───────────────────────────────────────────────────────

    error OnlyOwner();
    error AlgorithmAlreadyRegistered();
    error AlgorithmNotRegistered();
    error InvalidAlgorithmAddress();
    error EmptySignature();
    error NoActiveProposal();
    error TimelockNotExpired(uint256 remaining);
    error ProposalAlreadyPending();
    error SetupAlreadyClosed();

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
    /// @dev Disabled once setupComplete is true — use proposeAlgorithm + executeProposal after setup.
    /// @param algId The algorithm identifier (first byte of signature)
    /// @param algorithm The algorithm contract address
    function registerAlgorithm(uint8 algId, address algorithm) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (setupComplete) revert SetupAlreadyClosed();
        if (algorithm == address(0)) revert InvalidAlgorithmAddress();
        if (algorithms[algId] != address(0)) revert AlgorithmAlreadyRegistered();

        algorithms[algId] = algorithm;
        emit AlgorithmRegistered(algId, algorithm);
    }

    /// @notice Lock direct registration permanently. After this call, new algorithms require 7-day timelock.
    /// @dev One-way: cannot be undone. Emits SetupFinalized.
    function finalizeSetup() external {
        if (msg.sender != owner) revert OnlyOwner();
        setupComplete = true;
        emit SetupFinalized();
    }

    // ─── Governance: Timelock Proposals ────────────────────────────────

    /// @notice Propose a new algorithm with 7-day timelock.
    ///         Only-add: cannot propose for an algId that already has an algorithm.
    function proposeAlgorithm(uint8 algId, address algorithm) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (algorithm == address(0)) revert InvalidAlgorithmAddress();
        if (algorithms[algId] != address(0)) revert AlgorithmAlreadyRegistered();
        if (proposals[algId].algorithm != address(0)) revert ProposalAlreadyPending();

        proposals[algId] = Proposal({
            algorithm: algorithm,
            proposedAt: block.timestamp
        });

        emit AlgorithmProposed(algId, algorithm, block.timestamp + TIMELOCK_DURATION);
    }

    /// @notice Execute a proposal after the timelock has expired.
    function executeProposal(uint8 algId) external {
        Proposal memory p = proposals[algId];
        if (p.algorithm == address(0)) revert NoActiveProposal();
        if (algorithms[algId] != address(0)) revert AlgorithmAlreadyRegistered();

        uint256 elapsed = block.timestamp - p.proposedAt;
        if (elapsed < TIMELOCK_DURATION) {
            revert TimelockNotExpired(TIMELOCK_DURATION - elapsed);
        }

        algorithms[algId] = p.algorithm;
        delete proposals[algId];
        emit AlgorithmRegistered(algId, p.algorithm);
    }

    /// @notice Cancel a pending proposal.
    function cancelProposal(uint8 algId) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (proposals[algId].algorithm == address(0)) revert NoActiveProposal();

        delete proposals[algId];
        emit ProposalCancelled(algId);
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
