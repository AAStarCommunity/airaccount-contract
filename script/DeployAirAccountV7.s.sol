// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";

/// @title DeployAirAccountV7 - Foundry deploy script for Sepolia
/// @notice Deploys Factory + creates first account for the deployer
/// @dev Usage: forge script script/DeployAirAccountV7.s.sol \
///      --rpc-url $SEPOLIA_RPC --broadcast --verify -vvvv
contract DeployAirAccountV7 is Script {
    // EntryPoint v0.7 on all EVM chains
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("EntryPoint:", ENTRYPOINT_V07);

        vm.startBroadcast(deployerKey);

        // Deploy Factory
        AAStarAirAccountFactoryV7 factory = new AAStarAirAccountFactoryV7(ENTRYPOINT_V07);
        console.log("Factory deployed at:", address(factory));

        // Create first account for deployer (salt = 0)
        address account = factory.createAccount(deployer, 0);
        console.log("Account deployed at:", account);

        vm.stopBroadcast();

        // Print summary for .env
        console.log("");
        console.log("=== Add to .env ===");
        console.log("FACTORY_ADDRESS=", address(factory));
        console.log("ACCOUNT_ADDRESS=", account);
    }
}
