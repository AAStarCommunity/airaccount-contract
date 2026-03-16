// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAirAccountV7} from "./AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title AAStarAirAccountFactoryV7 - CREATE2 factory for V7 accounts
/// @notice Deploys account + guard + guardians atomically. No unprotected window.
/// @dev Provides both full-config and convenience (default guardian) creation methods.
///      No default daily limit — user must specify their own limit during creation.
contract AAStarAirAccountFactoryV7 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

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
        entryPoint = _entryPoint;
        defaultCommunityGuardian = _communityGuardian;
        for (uint256 i = 0; i < defaultTokens.length; i++) {
            _defaultTokenAddresses.push(defaultTokens[i]);
            _defaultTokenConfigs.push(defaultConfigs[i]);
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
        address predicted = getAddress(owner, salt, config);
        if (predicted.code.length > 0) {
            return predicted;
        }

        bytes memory bytecode = abi.encodePacked(
            type(AAStarAirAccountV7).creationCode,
            abi.encode(entryPoint, owner, config)
        );

        account = Create2.deploy(0, _getSalt(owner, salt), bytecode);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Predict the counterfactual address for a full-config account.
    function getAddress(
        address owner,
        uint256 salt,
        AAStarAirAccountBase.InitConfig memory config
    ) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(AAStarAirAccountV7).creationCode,
            abi.encode(entryPoint, owner, config)
        );

        return Create2.computeAddress(
            _getSalt(owner, salt),
            keccak256(bytecode)
        );
    }

    // ─── Convenience: Default Guardian Setup ────────────────────────

    /// @notice Deploy account with default community guardian as third guardian.
    /// @dev User provides 2 personal guardians with acceptance signatures.
    ///      Each guardian must sign: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt))
    ///      Guard is initialized with user-specified dailyLimit and all 3 standard algorithms.
    /// @param owner Account owner
    /// @param salt CREATE2 salt
    /// @param guardian1 User's backup key (passkey, EOA, or second device)
    /// @param guardian1Sig guardian1's acceptance signature
    /// @param guardian2 Trusted person (spouse, family) or another passkey
    /// @param guardian2Sig guardian2's acceptance signature
    /// @param dailyLimit Daily spending limit in wei (user chooses based on their needs)
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

        // Verify both guardians signed the acceptance message (F56 — M5.3)
        bytes32 acceptHash = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt))
            .toEthSignedMessageHash();
        (address recovered1,,) = acceptHash.tryRecover(guardian1Sig);
        if (recovered1 != guardian1) revert GuardianDidNotAccept(guardian1);
        (address recovered2,,) = acceptHash.tryRecover(guardian2Sig);
        if (recovered2 != guardian2) revert GuardianDidNotAccept(guardian2);

        AAStarAirAccountBase.InitConfig memory config = _buildDefaultConfig(
            guardian1, guardian2, dailyLimit
        );
        address predicted = getAddress(owner, salt, config);
        if (predicted.code.length > 0) {
            return predicted;
        }

        bytes memory bytecode = abi.encodePacked(
            type(AAStarAirAccountV7).creationCode,
            abi.encode(entryPoint, owner, config)
        );

        account = Create2.deploy(0, _getSalt(owner, salt), bytecode);
        emit AccountCreated(account, owner, salt);
    }

    /// @notice Predict address for a default-config account.
    function getAddressWithDefaults(
        address owner,
        uint256 salt,
        address guardian1,
        address guardian2,
        uint256 dailyLimit
    ) public view returns (address) {
        AAStarAirAccountBase.InitConfig memory config = _buildDefaultConfig(
            guardian1, guardian2, dailyLimit
        );
        return getAddress(owner, salt, config);
    }

    // ─── Internal ───────────────────────────────────────────────────

    function _buildDefaultConfig(
        address guardian1,
        address guardian2,
        uint256 dailyLimit
    ) internal view returns (AAStarAirAccountBase.InitConfig memory) {
        // Default approved algorithms: ECDSA, BLS, P256, Cumulative T2, Cumulative T3, Combined T1
        uint8[] memory algIds = new uint8[](6);
        algIds[0] = 0x02; // ALG_ECDSA
        algIds[1] = 0x01; // ALG_BLS
        algIds[2] = 0x03; // ALG_P256
        algIds[3] = 0x04; // ALG_CUMULATIVE_T2 (P256 + BLS)
        algIds[4] = 0x05; // ALG_CUMULATIVE_T3 (P256 + BLS + Guardian)
        algIds[5] = 0x06; // ALG_COMBINED_T1 (P256 + ECDSA zero-trust)

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
