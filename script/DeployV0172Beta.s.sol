// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {ForceExitModule} from "../src/core/ForceExitModule.sol";
import {AirAccountDelegate} from "../src/core/AirAccountDelegate.sol";
import {CalldataParserRegistry} from "../src/core/CalldataParserRegistry.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {AAStarBLSKeyRegistry} from "../src/validators/AAStarBLSKeyRegistry.sol";
import {SessionKeyValidator} from "../src/validators/SessionKeyValidator.sol";
import {AAStarBLSAggregator} from "../src/aggregator/AAStarBLSAggregator.sol";
import {AgentRegistry} from "../src/registries/AgentRegistry.sol";
import {RailgunParser} from "../src/parsers/RailgunParser.sol";
import {UniswapV3Parser} from "../src/parsers/UniswapV3Parser.sol";

/// @title DeployV0172Beta — full v0.17.2-beta.1 deployment script (multi-chain)
/// @notice Deploys the 11 singletons of v0.17.2-beta.1 and performs the 4 post-deploy
///         wiring transactions in a single `forge script ... --broadcast` invocation.
///
/// @dev Reads the following env vars (see `docs/contracts-inventory-v0.17.2-beta.1.md` §5):
///        - DEPLOYER_KEY               — uint256 private key for the broadcaster.
///                                       Optional: if set, used via vm.startBroadcast(uint256).
///                                       Otherwise the script falls back to vm.startBroadcast()
///                                       (no-arg), so `--private-key` / `--account` from the
///                                       forge CLI continue to work for keystore / env-based flows.
///        - ENTRY_POINT_07             — address, defaults to the canonical
///                                       0x0000000071727De22E5E9d8BAf0edAc6f37da032.
///        - P256_VERIFIER              — address, defaults to 0x...100 (precompile).
///                                       Sanity-logged only; never passed to a constructor.
///        - COMMUNITY_GUARDIAN_ADDRESS — address, defaults to address(0) (with a WARN line).
///                                       Used as the 3rd default guardian inside
///                                       `factory.createAccountWithDefaults` / `createAgentAccount`.
///
/// @dev Usage:
///   forge script script/DeployV0172Beta.s.sol:DeployV0172Beta \
///       --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
///       --broadcast -vvvv --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// @dev NOT deployed here (intentionally):
///      - EntryPoint v0.7 (canonical, already deployed on every chain).
///      - EIP-7212 P256 precompile (chain-native at 0x100; not a contract).
///      - ERC-8004 Identity/Reputation/Validation registries (already deployed at
///        deterministic CREATE2 addresses; referenced via src/config/ERC8004Addresses.sol).
///      - `AAStarAirAccountV7` implementation — auto-deployed inside the factory constructor.
///      - `AirAccountExtension` — auto-deployed inside the V7 implementation constructor.
///      - `AAStarGlobalGuard` — deployed per account by the factory on `createAccount*`.
contract DeployV0172Beta is Script {
    /// @dev ERC-4337 EntryPoint v0.7 — canonical address, identical on all chains.
    address constant DEFAULT_ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @dev EIP-7212 P256 precompile — sanity-logged only.
    address constant DEFAULT_P256_VERIFIER = address(0x100);

    /// @dev Algorithm IDs (mirror of AAStarAirAccountBase constants).
    uint8 constant ALG_BLS         = 0x01;
    uint8 constant ALG_SESSION_KEY = 0x08;

    // ─── Deployment record (in-memory; emitted via console2.log) ──────

    struct Deployed {
        address blsAlgorithm;        // #1
        address validatorRouter;     // #2
        address blsAggregator;       // #3
        address sessionKeyValidator; // #4
        address forceExitModule;     // #5
        address delegate;            // #6
        address parserRegistry;      // #7
        address railgunParser;       // #8
        address uniswapV3Parser;     // #9
        address factory;             // #10
        address implementation;      // (auto, inside factory ctor)
        address agentExtension;      // (auto, inside V7 impl ctor)
        address agentRegistry;       // #11
    }

    Deployed internal _d;

    // ─── Entrypoint ──────────────────────────────────────────────────

    function run() external {
        // Resolved once, used for both deployAll() and wireAll() banner.
        address entryPoint        = vm.envOr("ENTRY_POINT_07",             DEFAULT_ENTRYPOINT);
        address p256Verifier      = vm.envOr("P256_VERIFIER",              DEFAULT_P256_VERIFIER);
        address communityGuardian = vm.envOr("COMMUNITY_GUARDIAN_ADDRESS", address(0));

        console2.log("=== Deploy AirAccount v0.17.2-beta.1 ===");
        console2.log("chainid          :", block.chainid);
        console2.log("EntryPoint       :", entryPoint);
        console2.log("P256 verifier    :", p256Verifier);
        console2.log("communityGuardian:", communityGuardian);
        if (communityGuardian == address(0)) {
            console2.log("WARN: COMMUNITY_GUARDIAN_ADDRESS unset -> 3rd default guardian will be address(0).");
        }
        if (p256Verifier.code.length == 0) {
            // Precompiles have no code; this is informational only.
            console2.log("INFO: P256_VERIFIER has no code (expected for the EIP-7212 precompile).");
        }

        // Resolve broadcaster: optional uint256 DEPLOYER_KEY env var, otherwise fall back to the
        // forge CLI signer (--private-key / --account). The two-branch start lets the same script
        // serve both env-key and keystore flows without forking control flow downstream.
        uint256 deployerKey = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        deployAll(entryPoint, communityGuardian);
        wireAll();

        vm.stopBroadcast();

        _report();
    }

    // ─── Deploy: one contract per step, in DAG order ─────────────────

    /// @notice Deploys all 11 singletons in dependency order. No state setters are called here
    ///         (all wiring is in `wireAll`). Designed to be callable from other scripts/tests
    ///         that need to deploy without broadcasting (just call from inside a vm.broadcast).
    function deployAll(address entryPoint, address communityGuardian) public {
        // 1. BLS aggregate-signature algorithm (Tier 2/3 DVT co-sign).
        _d.blsAlgorithm = address(new AAStarBLSKeyRegistry());
        console2.log("Deployed AAStarBLSKeyRegistry:", _d.blsAlgorithm);

        // 2. Validator router (algId -> algorithm).
        _d.validatorRouter = address(new AAStarValidator());
        console2.log("Deployed AAStarValidator:", _d.validatorRouter);

        // 3. BLS aggregator (ERC-4337 IAggregator).
        _d.blsAggregator = address(new AAStarBLSAggregator(_d.blsAlgorithm, entryPoint));
        console2.log("Deployed AAStarBLSAggregator:", _d.blsAggregator);

        // 4. Unified SessionKeyValidator (algId 0x08) — covers both DApp/M6.4 simple sessions
        //    AND the richer agent-grade controls (velocity, callTargets[], selectorAllowlist[]).
        _d.sessionKeyValidator = address(new SessionKeyValidator());
        console2.log("Deployed SessionKeyValidator:", _d.sessionKeyValidator);

        // 5. L2 force-exit executor module.
        _d.forceExitModule = address(new ForceExitModule());
        console2.log("Deployed ForceExitModule:", _d.forceExitModule);

        // 6. EIP-7702 delegate singleton (EOA onboarding path).
        _d.delegate = address(new AirAccountDelegate());
        console2.log("Deployed AirAccountDelegate:", _d.delegate);

        // 7. DeFi calldata parser registry — still useful as a stub. Even though parsers are
        //    disabled in beta.1, deploying the registry lets per-account opt-in calls fail
        //    gracefully ("no parser registered for this dest") rather than reverting on a
        //    missing-contract staticcall.
        _d.parserRegistry = address(new CalldataParserRegistry());
        console2.log("Deployed CalldataParserRegistry:", _d.parserRegistry);

        // v0.17.2-beta.1 round 5 HIGH-4 / HIGH-5 (Codex): the two parsers below are NOT
        // deployed in this beta because their decoding logic is unsound (fail-open paths +
        // tuple-offset misdecode + multi-item undercount). Until they're rewritten with a
        // proper ABI decoder and fail-closed semantics, no account should opt into them.
        // Tracked in docs/known-issues.md KI-14. To re-enable for beta.2+:
        //   _d.railgunParser    = address(new RailgunParser());
        //   _d.uniswapV3Parser  = address(new UniswapV3Parser());
        // and reinstate the console2.log lines.
        _d.railgunParser   = address(0);
        _d.uniswapV3Parser = address(0);
        console2.log("Skipped RailgunParser:    DISABLED in beta.1 -- KI-14");
        console2.log("Skipped UniswapV3Parser:  DISABLED in beta.1 -- KI-14");

        // 10. AirAccount implementation + factory.
        //     #82 EIP-3860 fix: the implementation is deployed FIRST and injected into the factory
        //     (the factory no longer auto-deploys it inline — that embedded ~14 KB of creation code
        //     into the factory initcode and brushed the 49,152-byte cap). The implementation ctor
        //     still deploys the singleton AirAccountExtension itself.
        //     v0.17.2: the constructor signature no longer takes defaultValidator/defaultHook
        //     module addresses — the unified SessionKeyValidator at router[0x08] replaces them.
        //     We pass empty default-token arrays for chain portability; per-chain stablecoin
        //     limits, if wanted, require a chain-specific Factory redeploy (out of scope here).
        address[] memory noTokens = new address[](0);
        AAStarGlobalGuard.TokenConfig[] memory noConfigs = new AAStarGlobalGuard.TokenConfig[](0);
        address impl = address(new AAStarAirAccountV7());
        AAStarAirAccountFactoryV7 factory = new AAStarAirAccountFactoryV7(
            impl,
            entryPoint,
            communityGuardian,
            noTokens,
            noConfigs
        );
        _d.factory = address(factory);
        _d.implementation = factory.implementation();

        // Surface the auto-deployed implementation + its agent extension for the report. We must
        // re-call factory.implementation() via the implementation's getter to fetch the extension,
        // but that's a single immutable read — cheap and informative for the deploy banner.
        _d.agentExtension = _readImplExtension(_d.implementation);

        console2.log("Deployed AAStarAirAccountFactoryV7:", _d.factory);
        console2.log("Deployed AAStarAirAccountV7 (impl):", _d.implementation);
        console2.log("Deployed AirAccountExtension:", _d.agentExtension);

        // 11. Agent identity/wallet registry. Constructor takes no args (v0.17.2 H-2 round 2).
        //     Must be deployed AFTER the factory so wireAll() can bind them in the correct order.
        _d.agentRegistry = address(new AgentRegistry());
        console2.log("Deployed AgentRegistry:", _d.agentRegistry);
    }

    // ─── Wire: post-deploy state mutations ───────────────────────────

    /// @notice Performs all post-deploy wiring transactions in the correct order:
    ///         1) router.registerAlgorithm(0x01, blsAlgorithm)
    ///         2) router.registerAlgorithm(0x08, sessionKeyValidator)
    ///         3) agentRegistry.bindFactory(factory)
    ///         4) factory.setAgentRegistry(agentRegistry)
    ///
    /// @dev Notes intentionally NOT wired here (these are operator-decision steps):
    ///      - router.finalizeSetup() — leave unlocked during beta so additional algorithms
    ///        can be added without 7-day timelock. Operator runs once before GA.
    ///      - Tier boundary / TokenConfig values — these are per-account in `AAStarGlobalGuard`,
    ///        not per-router. The factory passes empty defaults; account creators supply their own.
    ///      - SuperPaymaster `setAgentRegistries(agentRegistry, ...)` — handed off to the SP team.
    function wireAll() public {
        // 1) Register BLS at algId 0x01 in the router.
        AAStarValidator(_d.validatorRouter).registerAlgorithm(ALG_BLS, _d.blsAlgorithm);
        console2.log("Wired router.registerAlgorithm(0x01, blsAlgorithm)");

        // 2) Register SessionKeyValidator at algId 0x08 in the router. Without this call,
        //    base._validateSignature -> validator.validateSignature(0x08, ...) returns
        //    SIG_VALIDATION_FAILED — i.e., session keys are silently dead on a fresh deploy.
        //    This is the v0.17.x deploy-script bug fix called out by the ADR.
        AAStarValidator(_d.validatorRouter).registerAlgorithm(ALG_SESSION_KEY, _d.sessionKeyValidator);
        console2.log("Wired router.registerAlgorithm(0x08, sessionKeyValidator)");

        // 3) Bind factory to AgentRegistry. This must happen BEFORE
        //    factory.setAgentRegistry(agentRegistry) so the registry already accepts
        //    factory.markValid() callbacks when the factory points at it. Caller must be
        //    the registry's deployer == this broadcaster.
        AgentRegistry(_d.agentRegistry).bindFactory(_d.factory);
        console2.log("Wired agentRegistry.bindFactory(factory)");

        // 4) Point the factory at the registry. Caller must be the factory's factoryAdmin ==
        //    this broadcaster. After this, every createAccount* writes isValidAccount[account]=true
        //    in the registry, which is the sole population path for SuperPaymaster eligibility.
        AAStarAirAccountFactoryV7(_d.factory).setAgentRegistry(_d.agentRegistry);
        console2.log("Wired factory.setAgentRegistry(agentRegistry)");
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    /// @dev Reads `agentExtension()` off the implementation. Uses a low-level staticcall so the
    ///      script does not need to import the full `AAStarAirAccountV7` (which would also pull
    ///      in the EntryPoint interface and friends). Returns address(0) on failure.
    function _readImplExtension(address impl) internal view returns (address ext) {
        (bool ok, bytes memory ret) = impl.staticcall(abi.encodeWithSignature("agentExtension()"));
        if (ok && ret.length >= 32) {
            ext = abi.decode(ret, (address));
        }
    }

    function _report() internal view {
        console2.log("");
        console2.log("=== v0.17.2-beta.1 Deployment Summary ===");
        console2.log("BLS Algorithm        :", _d.blsAlgorithm);
        console2.log("Validator Router     :", _d.validatorRouter);
        console2.log("BLS Aggregator       :", _d.blsAggregator);
        console2.log("SessionKey Validator :", _d.sessionKeyValidator);
        console2.log("ForceExit Module     :", _d.forceExitModule);
        console2.log("AirAccount Delegate  :", _d.delegate);
        console2.log("Parser Registry      :", _d.parserRegistry);
        console2.log("Railgun Parser       :", _d.railgunParser);
        console2.log("UniswapV3 Parser     :", _d.uniswapV3Parser);
        console2.log("Factory V7           :", _d.factory);
        console2.log("Implementation (V7)  :", _d.implementation);
        console2.log("Agent Extension      :", _d.agentExtension);
        console2.log("Agent Registry       :", _d.agentRegistry);
    }
}
