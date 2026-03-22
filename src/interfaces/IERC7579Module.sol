// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @title IERC7579Module — Base interface for all ERC-7579 modules
interface IERC7579Module {
    /// @notice Initialize the module for a specific account
    function onInstall(bytes calldata data) external;
    /// @notice Cleanup when module is uninstalled from an account
    function onUninstall(bytes calldata data) external;
    /// @notice Returns true if the module is initialized for the given account
    function isInitialized(address smartAccount) external view returns (bool);
}

/// @title IERC7579Validator — ERC-7579 validator module interface
interface IERC7579Validator is IERC7579Module {
    /// @notice Validate a UserOperation
    /// @return validationData 0=success, 1=failure, or aggregator address packed
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256 validationData);

    /// @notice ERC-1271 signature validation
    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata data
    ) external view returns (bytes4 magicValue);
}

/// @title IERC7579Hook — ERC-7579 hook module interface
interface IERC7579Hook is IERC7579Module {
    /// @notice Called before execution — can revert to block the call
    function preCheck(
        address msgSender,
        uint256 msgValue,
        bytes calldata msgData
    ) external returns (bytes memory hookData);

    /// @notice Called after execution
    function postCheck(bytes calldata hookData) external;
}
