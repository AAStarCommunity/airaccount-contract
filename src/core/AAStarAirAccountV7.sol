// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";

/// @title AAStarAirAccountV7 - ERC-4337 account for EntryPoint v0.7
/// @notice Non-upgradable, inherits core logic from AAStarAirAccountBase
contract AAStarAirAccountV7 is IAccount, AAStarAirAccountBase {
    constructor(address _entryPoint, address _owner, InitConfig memory _config)
        AAStarAirAccountBase(_entryPoint, _owner, _config) {}

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        validationData = _validateSignature(userOpHash, userOp.signature);
        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }
}
