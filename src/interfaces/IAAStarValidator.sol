// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IAAStarValidator - Generic algorithm router interface
/// @notice Routes signature validation to algorithm-specific implementations
interface IAAStarValidator {
    /// @dev Validate a signature by routing to the appropriate algorithm
    /// @param userOpHash The hash of the UserOperation
    /// @param signature The signature to validate (sig[0] = algId)
    /// @return validationData 0 for success, 1 for failure
    function validateSignature(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view returns (uint256 validationData);

    /// @dev Check if an algorithm is registered
    /// @param algId The algorithm identifier
    /// @return The address of the algorithm implementation (address(0) if not registered)
    function getAlgorithm(uint8 algId) external view returns (address);
}
