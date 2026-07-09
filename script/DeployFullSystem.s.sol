// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {AAStarBLSKeyRegistry} from "../src/validators/AAStarBLSKeyRegistry.sol";

/// @title DeployFullSystem - Deploy all M2+ contracts to Sepolia
/// @dev Usage: forge script script/DeployFullSystem.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
contract DeployFullSystem is Script {
    // EntryPoint v0.7 (canonical address)
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Default community guardian (Safe multisig — replace with actual address)
    address constant COMMUNITY_GUARDIAN = address(0); // TODO: set before production deploy

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("EntryPoint:", ENTRYPOINT);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BLS Algorithm
        AAStarBLSKeyRegistry blsAlg = new AAStarBLSKeyRegistry();
        console.log("AAStarBLSKeyRegistry:", address(blsAlg));

        // 2. Deploy Validator Router
        AAStarValidator validatorRouter = new AAStarValidator();
        console.log("AAStarValidator (router):", address(validatorRouter));

        // 3. Register BLS algorithm (algId=0x01) in router
        validatorRouter.registerAlgorithm(0x01, address(blsAlg));
        console.log("Registered BLS algorithm (algId=0x01)");

        // 4. Deploy implementation + Factory (no default token config in script — use deploy-m5.ts
        //    for chain-specific tokens). #82 EIP-3860 fix: impl deployed first, injected into factory.
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        address impl = address(new AAStarAirAccountV7());
        AAStarAirAccountFactoryV7 factory = new AAStarAirAccountFactoryV7(
            impl,
            ENTRYPOINT,
            COMMUNITY_GUARDIAN,
            noTokens,
            noConfigs
        );
        console.log("AAStarAirAccountFactoryV7:", address(factory));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("BLS Algorithm    :", address(blsAlg));
        console.log("Validator Router :", address(validatorRouter));
        console.log("Factory V7       :", address(factory));
        console.log("EntryPoint       :", ENTRYPOINT);
    }
}
