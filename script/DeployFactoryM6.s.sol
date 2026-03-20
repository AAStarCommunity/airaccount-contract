// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title DeployFactoryM6 — Deploy AirAccount M6 factory to any EVM chain
/// @notice Supports both --private-key (Sepolia) and --account keystore (OP Mainnet / cast wallet).
///         Token config is loaded from env vars; tokens/limits may be empty for a minimal deploy.
///
/// @dev Usage (Sepolia, private key):
///   forge script script/DeployFactoryM6.s.sol:DeployFactoryM6 \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
///     --broadcast --slow -vv
///
/// @dev Usage (OP Mainnet, cast wallet):
///   forge script script/DeployFactoryM6.s.sol:DeployFactoryM6 \
///     --rpc-url $OPT_MAINNET_RPC \
///     --account optimism-deployer \
///     --broadcast --slow --timeout 300 -vv
///
/// @dev Environment variables (all optional — defaults to minimal deploy):
///   ENTRYPOINT            — EntryPoint address (default: 0x0000...032, ERC-4337 v0.7 canonical)
///   COMMUNITY_GUARDIAN    — Community guardian address (default: address(0))
///   DEPLOYER_ADDRESS      — Deployer address (informational log only, auto-resolved if not set)
contract DeployFactoryM6 is Script {
    // ERC-4337 v0.7 EntryPoint — canonical address on all EVM chains
    address constant EP_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        address entryPoint    = vm.envOr("ENTRYPOINT",         EP_V07);
        address guardian      = vm.envOr("COMMUNITY_GUARDIAN", address(0));
        address deployerAddr  = vm.envOr("DEPLOYER_ADDRESS",   address(0));

        console.log("=== Deploy AirAccount M6 Factory ===");
        console.log("Chain ID     :", block.chainid);
        console.log("EntryPoint   :", entryPoint);
        console.log("Guardian     :", guardian);
        if (deployerAddr != address(0)) {
            console.log("Deployer     :", deployerAddr);
        }

        // No token presets in script — token config requires chain-specific addresses
        // Use deploy-sepolia.sh / deploy-op.sh which pass token arrays via the TypeScript helper,
        // OR call factory.addTokenConfig() after deploy.
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);

        // vm.startBroadcast() with NO args:
        //   - When --private-key is passed → forge uses that key
        //   - When --account <name> is passed → forge uses encrypted keystore (cast wallet)
        vm.startBroadcast();

        AAStarAirAccountFactoryV7 factory = new AAStarAirAccountFactoryV7(
            entryPoint,
            guardian,
            noTokens,
            noConfigs
        );

        address impl = factory.implementation();

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Result ===");
        console.log("Factory         :", address(factory));
        console.log("Implementation  :", impl);
        console.log("Account size    : 20900 B (EIP-170 compliant)");
        console.log("Factory size    :  9527 B");
        console.log("");
        console.log("=== Add to .env ===");
        console.log("AIRACCOUNT_FACTORY=", address(factory));
        console.log("AIRACCOUNT_IMPL=   ", impl);
    }
}
