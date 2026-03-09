// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/// @title IAAStarAlgorithm - Interface for signature algorithm implementations
/// @notice Each algorithm (BLS, PQ, etc.) implements this interface
interface IAAStarAlgorithm {
    /// @dev Validate a signature using this algorithm
    /// @param userOpHash The hash of the UserOperation
    /// @param signature The algorithm-specific signature data (algId prefix already stripped)
    /// @return validationData 0 for success, 1 for failure
    function validate(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view returns (uint256 validationData);
}
