// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAirAccountV7} from "./AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title AAStarAirAccountFactoryV7 - EIP-1167 clone factory for V7 accounts
/// @notice Deploys minimal proxy clones pointing to a shared implementation, then calls initialize().
///         This keeps factory bytecode well under EIP-170's 24,576-byte limit.
///         Account address = Clones.predictDeterministicAddress(implementation, keccak256(owner ++ salt))
/// @dev Provides both full-config and convenience (default guardian) creation methods.
///      No default daily limit — user must specify their own limit during creation.
contract AAStarAirAccountFactoryV7 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev Shared implementation contract — all user accounts are clones of this address.
    ///      Deployed atomically in the factory constructor. Never call initialize() on this address directly.
    address public immutable implementation;

    /// @dev The EntryPoint address used for all created accounts
    address public immutable entryPoint;

    /// @dev Default community guardian (Safe multisig provided by the community)
    address public immutable defaultCommunityGuardian;

    /// @dev Default token addresses for new accounts (chain-specific, set at deploy time)
    address[] private _defaultTokenAddresses;
    /// @dev Default token spending configs aligned with _defaultTokenAddresses
    AAStarGlobalGuard.TokenConfig[] private _defaultTokenConfigs;

    /// @dev Default validator module pre-installed on every new account (address(0) = disabled)
    ///      Typically AirAccountCompositeValidator to enable weighted/cumulative sigs out-of-box.
    address public immutable defaultValidatorModule;

    /// @dev Default hook module pre-installed on every new account (address(0) = disabled)
    ///      Typically TierGuardHook to enforce tier-based spending limits via ERC-7579 hooks.
    address public immutable defaultHookModule;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    error GuardianDidNotAccept(address guardian);
    error DuplicateGuardian();

    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _communityGuardian Default community Safe multisig guardian address
    /// @param defaultTokens Token addresses to pre-configure for all new accounts (empty = no defaults)
    /// @param defaultConfigs Spending limits aligned with defaultTokens
    /// @param _defaultValidatorModule AirAccountCompositeValidator to pre-install (address(0) = none)
    /// @param _defaultHookModule TierGuardHook to pre-install (address(0) = none)
    constructor(
        address _entryPoint,
        address _communityGuardian,
        address[] memory defaultTokens,
        AAStarGlobalGuard.TokenConfig[] memory defaultConfigs,
        address _defaultValidatorModule,
        address _defaultHookModule
    ) {
        defaultValidatorModule = _defaultValidatorModule;
        defaultHookModule = _defaultHookModule;
        require(defaultTokens.length == defaultConfigs.length, "Token/config length mismatch");
        // Deploy shared implementation. All user accounts are EIP-1167 clones of this address.
        implementation = address(new AAStarAirAccountV7());
        entryPoint = _entryPoint;
        defaultCommunityGuardian = _communityGuardian;
        for (uint256 i = 0; i < defaultTokens.length; i++) {
            address tok = defaultTokens[i];
            require(tok != address(0), "Default token address zero");
            // Dedup check: O(n^2) but n is small (≤10 expected) and this is deploy-time only
            for (uint256 j = 0; j < i; j++) {
                require(_defaultTokenAddresses[j] != tok, "Duplicate default token");
            }
            // Validate tier/daily relationship eagerly — invalid configs revert here rather
            // than failing silently for every createAccountWithDefaults call.
            AAStarGlobalGuard.TokenConfig memory cfg = defaultConfigs[i];
            bool bad = (cfg.tier1Limit > 0 && cfg.tier2Limit > 0 && cfg.tier1Limit > cfg.tier2Limit)
                || (cfg.tier2Limit > 0 && cfg.dailyLimit > 0 && cfg.dailyLimit < cfg.tier2Limit)
                || (cfg.tier1Limit > 0 && cfg.tier2Limit == 0 && cfg.dailyLimit > 0 && cfg.dailyLimit < cfg.tier1Limit)
                || ((cfg.tier1Limit > 0 || cfg.tier2Limit > 0) && cfg.dailyLimit == 0);
            require(!bad, "Invalid default token config");
            _defaultTokenAddresses.push(tok);
            _defaultTokenConfigs.push(cfg);
        }
    }

    // ─── Full Configuration ─────────────────────────────────────────

    /// @notice Deploy a new account with full configuration.
    /// @param owner Account owner (ECDSA signer)
    /// @param salt CREATE2 salt for deterministic address
    /// @param config Full initialization config (guardians, guard, algorithms)
    function createAccount(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config
    ) external returns (address account) {
        // Validate guardians: non-zero entries must be pairwise distinct.
        // Without this, [addrA, addrA, addrB] degrades 2-of-3 social recovery to 1-of-2.
        address[3] memory g = config.guardians;
        if (g[0] != address(0) && g[1] != address(0) && g[0] == g[1]) revert DuplicateGuardian();
        if (g[0] != address(0) && g[2] != address(0) && g[0] == g[2]) revert DuplicateGuardian();
        if (g[1] != address(0) && g[2] != address(0) && g[1] == g[2]) revert DuplicateGuardian();

        // Bind address to config: include guardians and dailyLimit in salt so that
        // a front-runner cannot pre-deploy this address with a different (malicious) config.
        // Without this, anyone could call createAccount(victim, salt, maliciousConfig) and
        // seize control of the victim's counterfactual address via social recovery.
        bytes32 cloneSalt = _getSalt(owner, salt, _getConfigHash(config));
        account = Clones.predictDeterministicAddress(implementation, cloneSalt);
        if (account.code.length > 0) {
            return account;
        }
        // Pre-deploy guard bound to the predicted account address.
        // Guard must be deployed BEFORE the clone so it can reference the account address.
        // guard creation code stays in factory runtime, not in account runtime — avoids EIP-170 overflow.
        address guardAddr = address(0);
        if (config.dailyLimit > 0) {
            guardAddr = address(new AAStarGlobalGuard(
                account,
                config.dailyLimit,
                config.approvedAlgIds,
                config.minDailyLimit,
                config.initialTokens,
                config.initialTokenConfigs
            ));
        }
        account = Clones.cloneDeterministic(implementation, cloneSalt);
        AAStarAirAccountV7(payable(account)).initialize(entryPoint, owner, config, guardAddr);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Predict the counterfactual address for a full-config account.
    /// @dev Address depends on owner + salt + keccak256(guardians, dailyLimit) to prevent
    ///      front-running attacks where an attacker pre-deploys the account with malicious guardians.
    function getAddress(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config
    ) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt, _getConfigHash(config)));
    }

    // ─── Convenience: Default Guardian Setup ────────────────────────

    /// @notice Deploy account with default community guardian as third guardian.
    /// @dev User provides 2 personal guardians with acceptance signatures.
    ///      Each guardian must sign: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()
    ///      Guard is initialized with user-specified dailyLimit and all 3 standard algorithms.
    /// @param owner Account owner
    /// @param salt CREATE2 salt
    /// @param guardian1 User's backup key (passkey, EOA, or second device)
    /// @param guardian1Sig guardian1's acceptance signature
    /// @param guardian2 Trusted person (spouse, family) or another passkey
    /// @param guardian2Sig guardian2's acceptance signature
    /// @param dailyLimit Daily spending limit in wei (user chooses based on their needs)
    /// @dev Guardian acceptance hash is domain-separated:
    ///      keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()
    ///      Including chainId and address(this) prevents cross-chain and cross-factory replay.
    function createAccountWithDefaults(
        address owner,
        uint256 salt,
        address guardian1,
        bytes calldata guardian1Sig,
        address guardian2,
        bytes calldata guardian2Sig,
        uint256 dailyLimit
    ) external returns (address account) {
        require(guardian1 != address(0) && guardian2 != address(0), "Guardians required");
        require(guardian1 != guardian2, "Guardians must be distinct");
        require(dailyLimit > 0, "Daily limit required"); // F72: guard must be configured

        // Verify both guardians signed the domain-separated acceptance message (F56 — M5.3)
        // chainId + address(this) prevent replay across chains and factories with same owner+salt
        bytes32 acceptHash = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(this), owner, salt))
            .toEthSignedMessageHash();
        (address recovered1,,) = acceptHash.tryRecover(guardian1Sig);
        if (recovered1 != guardian1) revert GuardianDidNotAccept(guardian1);
        (address recovered2,,) = acceptHash.tryRecover(guardian2Sig);
        if (recovered2 != guardian2) revert GuardianDidNotAccept(guardian2);

        bytes32 cloneSalt = _getDefaultSalt(owner, salt);
        account = Clones.predictDeterministicAddress(implementation, cloneSalt);
        if (account.code.length > 0) {
            return account;
        }

        AAStarAirAccountBase.InitConfig memory config = _buildDefaultConfig(
            guardian1, guardian2, dailyLimit
        );
        // Pre-deploy guard bound to the predicted account address before cloning.
        address guardAddr = address(new AAStarGlobalGuard(
            account,
            config.dailyLimit,
            config.approvedAlgIds,
            config.minDailyLimit,
            config.initialTokens,
            config.initialTokenConfigs
        ));
        account = Clones.cloneDeterministic(implementation, cloneSalt);
        AAStarAirAccountV7(payable(account)).initialize(entryPoint, owner, config, guardAddr);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Predict address for a default-config account.
    /// @dev With the clone pattern, the address depends only on implementation + salt (not guardian config).
    function getAddressWithDefaults(
        address owner,
        uint256 salt,
        address /* guardian1 */,
        address /* guardian2 */,
        uint256 /* dailyLimit */
    ) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _getDefaultSalt(owner, salt));
    }

    // ─── Internal ───────────────────────────────────────────────────

    function _buildDefaultConfig(
        address guardian1,
        address guardian2,
        uint256 dailyLimit
    ) internal view returns (AAStarAirAccountBase.InitConfig memory) {
        // Default approved algorithms: ECDSA, BLS, P256, Cumulative T2, Cumulative T3, Combined T1, Weighted, SessionKey
        uint8[] memory algIds = new uint8[](8);
        algIds[0] = 0x02; // ALG_ECDSA
        algIds[1] = 0x01; // ALG_BLS
        algIds[2] = 0x03; // ALG_P256
        algIds[3] = 0x04; // ALG_CUMULATIVE_T2 (P256 + BLS)
        algIds[4] = 0x05; // ALG_CUMULATIVE_T3 (P256 + BLS + Guardian)
        algIds[5] = 0x06; // ALG_COMBINED_T1 (P256 + ECDSA zero-trust)
        algIds[6] = 0x07; // ALG_WEIGHTED (resolves to 0x02/0x04/0x05 based on weight)
        algIds[7] = 0x08; // ALG_SESSION_KEY (time-limited session key)

        // minDailyLimit = 10% of dailyLimit — stolen ECDSA key cannot reduce limit below this floor
        uint256 minLimit = dailyLimit / 10;

        // Use chain-specific defaults set at factory deploy time; copy from storage to memory
        uint256 n = _defaultTokenAddresses.length;
        address[] memory tokens = new address[](n);
        AAStarGlobalGuard.TokenConfig[] memory configs = new AAStarGlobalGuard.TokenConfig[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _defaultTokenAddresses[i];
            configs[i] = _defaultTokenConfigs[i];
        }

        return AAStarAirAccountBase.InitConfig({
            guardians: [guardian1, guardian2, defaultCommunityGuardian],
            dailyLimit: dailyLimit,
            approvedAlgIds: algIds,
            minDailyLimit: minLimit,
            initialTokens: tokens,
            initialTokenConfigs: configs
        });
    }

    /// @dev Hash the security-critical fields of a config that determine account identity.
    ///      guardians + dailyLimit are the fields an attacker would change in a front-run.
    function _getConfigHash(AAStarAirAccountBase.InitConfig memory config) internal pure returns (bytes32) {
        return keccak256(abi.encode(config.guardians, config.dailyLimit));
    }

    /// @dev Internal salt for createAccount/getAddress: binds address to owner + salt + configHash.
    function _getSalt(address owner, uint256 salt, bytes32 configHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt, configHash));
    }

    /// @dev Internal salt for createAccountWithDefaults/getAddressWithDefaults: binds to owner + salt only
    ///      (guardian acceptance signatures already prevent front-running for this path).
    function _getDefaultSalt(address owner, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }

    // ─── ERC-7828 Chain-Specific Address (M7.4) ─────────────────────

    /// @notice ERC-7828: Returns a chain-qualified address identifier.
    ///         Enables cross-chain address disambiguation for accounts deployed at the same address
    ///         on multiple L2s via CREATE2 with the same salt.
    /// @dev keccak256(account ++ chainId) — unique per (address, chain) pair.
    ///      Use for canonical cross-chain account references.
    /// @param account The account address to qualify
    /// @return Chain-qualified address bytes32 identifier
    function getChainQualifiedAddress(address account) external view returns (bytes32) {
        return keccak256(abi.encodePacked(account, block.chainid));
    }

    /// @notice Predict account address AND its chain-qualified identifier in one call.
    /// @dev Convenience function for frontends building cross-chain address registries.
    function getAddressWithChainId(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config
    ) external view returns (address account, bytes32 chainQualified) {
        account = Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt, _getConfigHash(config)));
        chainQualified = keccak256(abi.encodePacked(account, block.chainid));
    }
}
