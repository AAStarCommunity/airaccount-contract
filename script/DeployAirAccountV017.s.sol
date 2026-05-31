// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Script, console} from "forge-std/Script.sol";

import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {ForceExitModule} from "../src/core/ForceExitModule.sol";
import {AirAccountDelegate} from "../src/core/AirAccountDelegate.sol";
import {CalldataParserRegistry} from "../src/core/CalldataParserRegistry.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";
import {SessionKeyValidator} from "../src/validators/SessionKeyValidator.sol";
import {AAStarBLSAggregator} from "../src/aggregator/AAStarBLSAggregator.sol";
import {AgentRegistry} from "../src/registries/AgentRegistry.sol";
import {RailgunParser} from "../src/parsers/RailgunParser.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";

/// @title DeployAirAccountV017 — full v0.17.0 deployment (multi-chain)
/// @notice Deploys the complete AirAccount v0.17.0 contract set and wires the validator router.
///         Chain-portable: works on Sepolia (11155111), OP Sepolia (11155420), OP Mainnet (10),
///         and any EVM chain with EntryPoint v0.7 at the canonical address.
///
/// @dev Key source comes from the forge CLI (vm.startBroadcast() with no arg), so the SAME script
///      serves both testnet (env private key) and mainnet (encrypted keystore, password-prompted):
///
///   Testnet (Sepolia) — env key:
///     forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
///       --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
///
///   Testnet (OP Sepolia) — env key:
///     forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
///       --rpc-url $OP_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
///
///   Mainnet (OP Mainnet) — encrypted keystore (cast wallet), prompts for password:
///     cast wallet import op-deployer --interactive      # one-time, stores encrypted keystore
///     forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
///       --rpc-url $OP_MAINNET_RPC_URL --account op-deployer --broadcast -vvvv
///
///   Optional verification: append --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev External dependencies NOT deployed here:
///      - EntryPoint v0.7 (canonical, immutable, same on every chain)
///      - ERC-8004 official Identity/Reputation/Validation registries (referenced via
///        src/config/ERC8004Addresses.sol at their deterministic CREATE2 addresses)
///      - AAStarAirAccountV7 implementation (deployed inside the Factory constructor)
///      - AAStarGlobalGuard (deployed per-account by the Factory on createAccount)
contract DeployAirAccountV017 is Script {
    /// @dev ERC-4337 EntryPoint v0.7 — canonical address, identical on all chains.
    address constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @dev BLS aggregate signature algId in the validator router.
    uint8 constant ALG_BLS = 0x01;

    struct Deployed {
        address blsAlgorithm;
        address validatorRouter;
        address blsAggregator;
        address sessionKeyValidator;
        address forceExitModule;
        address agentRegistry;
        address delegate;
        address parserRegistry;
        address railgunParser;
        address uniswapV3Parser;
        address factory;
        address implementation;
    }

    function run() external {
        // Community guardian (Safe multisig). Read from env; address(0) is allowed but warned —
        // createAccountWithDefaults uses it as the 3rd guardian, so set it for production chains.
        address communityGuardian = vm.envOr("COMMUNITY_GUARDIAN_ADDRESS", address(0));

        console.log("=== Deploy AirAccount v0.17.0 ===");
        console.log("chainid          :", block.chainid);
        console.log("EntryPoint       :", ENTRYPOINT);
        console.log("communityGuardian:", communityGuardian);
        if (communityGuardian == address(0)) {
            console.log("WARN: COMMUNITY_GUARDIAN_ADDRESS unset -> createAccountWithDefaults 3rd guardian will be address(0).");
        }

        Deployed memory d;

        vm.startBroadcast();

        // 1. BLS aggregate-signature algorithm (Tier 2/3 DVT co-sign)
        d.blsAlgorithm = address(new AAStarBLSAlgorithm());

        // 2. Validator router (algId -> algorithm)
        AAStarValidator router = new AAStarValidator();
        router.registerAlgorithm(ALG_BLS, d.blsAlgorithm);
        d.validatorRouter = address(router);

        // 3. BLS aggregator (ERC-4337 IAggregator)
        d.blsAggregator = address(new AAStarBLSAggregator(d.blsAlgorithm));

        // 4. Unified SessionKeyValidator (algId 0x08) — covers BOTH simple DApp/M6.4-style
        //    session keys AND the richer agent-session features (velocity, callTargets[],
        //    selectorAllowlist[]) previously split into AgentSessionKeyValidator (deleted v0.17.2).
        d.sessionKeyValidator = address(new SessionKeyValidator());
        // M-3 fix: register it in the router so base._validateSignature -> router for 0x08 works.
        // Without this register call, ALG_SESSION_KEY validation returns SIG_VALIDATION_FAILED.
        router.registerAlgorithm(0x08, d.sessionKeyValidator);

        // 5. L2 force-exit executor module
        d.forceExitModule = address(new ForceExitModule());

        // 6. EIP-7702 delegate singleton (EOA onboarding path)
        d.delegate = address(new AirAccountDelegate());

        // 7. DeFi calldata parsers + registry (opt-in via account.setParserRegistry).
        d.parserRegistry = address(new CalldataParserRegistry());
        d.railgunParser = address(new RailgunParser());
        d.uniswapV3Parser = address(new UniswapV3Parser());

        // 8. Factory (constructor deploys the AAStarAirAccountV7 implementation).
        //    v0.17.2: no per-account default module install — unified SessionKeyValidator at
        //    router[0x08] replaces the deleted CompositeValidator + TierGuardHook + ASK trio.
        //    MUST be deployed BEFORE AgentRegistry because AgentRegistry takes
        //    factory.implementation() as a constructor argument (H-2 whitelist binding).
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        AAStarAirAccountFactoryV7 factory = new AAStarAirAccountFactoryV7(
            ENTRYPOINT,
            communityGuardian,
            noTokens,
            noConfigs
        );
        d.factory = address(factory);
        d.implementation = factory.implementation();

        // 9. Agent identity/wallet registry (SuperPaymaster setAgentRegistries target).
        //    H-2 (Codex P1 round 2): factory-provenance whitelist instead of extcodehash check.
        //    AgentRegistry constructor takes NO args; the factory address is bound post-deploy
        //    via `bindFactory`, and factory.createAccount* writes `isValidAccount[account] = true`
        //    via `markValid`. SuperPaymaster eligibility derives from this mapping.
        d.agentRegistry = address(new AgentRegistry());
        AgentRegistry(d.agentRegistry).bindFactory(address(factory));
        factory.setAgentRegistry(d.agentRegistry);

        vm.stopBroadcast();

        _report(d);
    }

    function _report(Deployed memory d) internal pure {
        console.log("\n=== v0.17.0 Deployment Summary ===");
        console.log("BLS Algorithm        :", d.blsAlgorithm);
        console.log("Validator Router     :", d.validatorRouter);
        console.log("BLS Aggregator       :", d.blsAggregator);
        console.log("SessionKey Validator :", d.sessionKeyValidator);
        console.log("ForceExit Module     :", d.forceExitModule);
        console.log("Agent Registry       :", d.agentRegistry);
        console.log("AirAccount Delegate  :", d.delegate);
        console.log("Parser Registry      :", d.parserRegistry);
        console.log("Railgun Parser       :", d.railgunParser);
        console.log("UniswapV3 Parser     :", d.uniswapV3Parser);
        console.log("Factory V7           :", d.factory);
        console.log("Implementation (V7)  :", d.implementation);
    }
}
