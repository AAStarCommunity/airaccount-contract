// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {AAStarAirAccountV7} from "./AAStarAirAccountV7.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title AAStarAirAccountFactoryV7 - CREATE2 factory for V7 accounts
contract AAStarAirAccountFactoryV7 {
    /// @dev The EntryPoint address used for all created accounts
    address public immutable entryPoint;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    constructor(address _entryPoint) {
        entryPoint = _entryPoint;
    }

    /// @dev Deploy a new AAStarAirAccountV7 with CREATE2
    function createAccount(address owner, uint256 salt) external returns (address account) {
        // Check if already deployed
        address predicted = getAddress(owner, salt);
        if (predicted.code.length > 0) {
            return predicted;
        }

        bytes memory bytecode = abi.encodePacked(
            type(AAStarAirAccountV7).creationCode,
            abi.encode(entryPoint, owner)
        );

        account = Create2.deploy(0, _getSalt(owner, salt), bytecode);
        emit AccountCreated(account, owner, salt);
    }

    /// @dev Predict the counterfactual address
    function getAddress(address owner, uint256 salt) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(AAStarAirAccountV7).creationCode,
            abi.encode(entryPoint, owner)
        );

        return Create2.computeAddress(
            _getSalt(owner, salt),
            keccak256(bytecode)
        );
    }

    function _getSalt(address owner, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }
}
