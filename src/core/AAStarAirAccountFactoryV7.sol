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

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    error GuardianDidNotAccept(address guardian);

    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _communityGuardian Default community Safe multisig guardian address
    /// @param defaultTokens Token addresses to pre-configure for all new accounts (empty = no defaults)
    /// @param defaultConfigs Spending limits aligned with defaultTokens
    constructor(
        address _entryPoint,
        address _communityGuardian,
        address[] memory defaultTokens,
        AAStarGlobalGuard.TokenConfig[] memory defaultConfigs
    ) {
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
        bytes32 cloneSalt = _getSalt(owner, salt);
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
    /// @dev With the clone pattern, the address depends only on implementation + salt (not config).
    ///      The config parameter is retained for interface compatibility.
    function getAddress(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory /* config */
    ) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt));
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
        require(dailyLimit > 0, "Daily limit required"); // F72: guard must be configured

        // Verify both guardians signed the domain-separated acceptance message (F56 — M5.3)
        // chainId + address(this) prevent replay across chains and factories with same owner+salt
        bytes32 acceptHash = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, address(this), owner, salt))
            .toEthSignedMessageHash();
        (address recovered1,,) = acceptHash.tryRecover(guardian1Sig);
        if (recovered1 != guardian1) revert GuardianDidNotAccept(guardian1);
        (address recovered2,,) = acceptHash.tryRecover(guardian2Sig);
        if (recovered2 != guardian2) revert GuardianDidNotAccept(guardian2);

        bytes32 cloneSalt = _getSalt(owner, salt);
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
        return Clones.predictDeterministicAddress(implementation, _getSalt(owner, salt));
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

    function _getSalt(address owner, uint256 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, salt));
    }
}
