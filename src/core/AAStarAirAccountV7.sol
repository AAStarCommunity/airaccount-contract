// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountBase} from "./AAStarAirAccountBase.sol";

/**
 * @title AAStarAirAccountV7 — ERC-4337 account for EntryPoint v0.7
 * @notice Non-upgradable, inherits core logic from AAStarAirAccountBase.
 *
 * ERC-7579 Minimum Compatibility Shim (M6):
 *   AirAccount is NOT a full ERC-7579 implementation (that is M7 work).
 *   This shim adds the minimum surface so that ERC-7579 ecosystem tools
 *   (paymaster SDKs, session key wizards, ZeroDev tooling) can query
 *   account metadata and installed modules without custom integration.
 *
 *   Supported in M6 (read/query only):
 *     - accountId()           — identity string for tooling
 *     - supportsModule()      — declares validator(1) and executor(2) support
 *     - isModuleInstalled()   — maps to existing validator slot
 *     - supportsInterface()   — ERC-165 for ERC-1271 and ERC-7579 interface IDs
 *     - isValidSignature()    — ERC-1271 on-chain signature validation
 *
 *   NOT supported in M6 (full M7):
 *     - installModule() / uninstallModule() with guardian gate + timelock
 *     - executeFromExecutor()
 *     - Full ModeCode execution dispatch
 */
contract AAStarAirAccountV7 is IAccount, AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev Implementation constructor. Does NOT disable initializers so that direct `new` in tests works.
    ///      The factory deploys one shared implementation and uses Clones for user accounts.
    constructor() {}

    /// @notice Initialize this account without a guard (called directly in tests or for no-guard accounts).
    ///         The `initializer` modifier from OZ Initializable prevents re-initialization.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians and algorithm list (dailyLimit ignored — no guard deployed)
    function initialize(address _entryPoint, address _owner, InitConfig calldata _config) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.minDailyLimit, address(0));
    }

    /// @notice Initialize this account with a pre-deployed guard.
    ///         Guard must be deployed by the caller (factory or test) before calling this.
    ///         Keeping guard deployment outside the account removes ~4,595B of creation code
    ///         from the account's runtime, keeping it under EIP-170's 24,576-byte limit.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians (dailyLimit/algIds used to deploy _guardAddr)
    /// @param _guardAddr Pre-deployed AAStarGlobalGuard address bound to this account's address
    function initialize(address _entryPoint, address _owner, InitConfig calldata _config, address _guardAddr) external initializer {
        _initAccount(_entryPoint, _owner, _config.guardians, _config.minDailyLimit, _guardAddr);
    }

    // ─── ERC-7579 Minimum Compatibility Shim ─────────────────────────

    // Module type IDs (ERC-7579 §2)
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;
    uint256 internal constant MODULE_TYPE_HOOK     = 3;
    uint256 internal constant MODULE_TYPE_FALLBACK = 4;

    /// @notice ERC-7579 account identity string.
    ///         Format: "vendor.name.version" — enables tooling to identify this account type.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.16.0";
    }

    /// @notice ERC-7579: declare which module types this account supports.
    ///         M7 declares validator(1), executor(2), and hook(3) support.
    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR
            || moduleTypeId == MODULE_TYPE_EXECUTOR
            || moduleTypeId == MODULE_TYPE_HOOK;
    }

    /// @notice ERC-7579: check whether a module is installed.
    ///         For validators (type 1): returns true if module == validator router address OR in registry.
    ///         For executors (type 2): checks installed executor registry.
    ///         For hooks (type 3): checks installed hook registry.
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata /* additionalContext */
    ) external view returns (bool) {
        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            return module == address(validator) || _installedValidators[module];
        }
        if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            return _installedExecutors[module];
        }
        if (moduleTypeId == MODULE_TYPE_HOOK) {
            return _installedHooks[module];
        }
        return false;
    }

    /// @notice ERC-1271: on-chain signature validation (used by ERC-7579 tooling and DeFi protocols).
    ///         Validates that the signature was produced by this account's owner.
    ///         The caller is responsible for passing the correct hash (may be pre-EIP-191).
    /// @return magicValue 0x1626ba7e if valid, 0xffffffff otherwise
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        // Standard ERC-1271: recover directly from hash, no additional prefix
        address signer = ECDSA.recover(hash, sig);
        if (signer == owner) return 0x1626ba7e;
        return 0xffffffff;
    }

    /// @notice ERC-165: interface detection.
    ///         Signals support for ERC-1271 (isValidSignature) and ERC-7579 minimum surface.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 ||  // ERC-165 itself
            interfaceId == 0x1626ba7e ||  // ERC-1271 isValidSignature
            interfaceId == type(IAccount).interfaceId; // ERC-4337 IAccount
    }

    // ─── Core ─────────────────────────────────────────────────────────

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        // ERC-7579 nonce key routing: high 192 bits of nonce = validator module address (M7.2).
        // If non-zero, route to installed validator module instead of built-in signature routing.
        uint192 validatorId = uint192(userOp.nonce >> 64);
        if (validatorId != 0) {
            address validatorModule = address(uint160(validatorId));
            if (!_installedValidators[validatorModule]) {
                validationData = 1; // SIG_VALIDATION_FAILED — module not installed
            } else {
                // selector = keccak256("validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)")
                (bool ok, bytes memory ret) = validatorModule.call(
                    abi.encodeWithSelector(0x97003203, userOp, userOpHash)
                );
                validationData = (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 1;
            }
        } else {
            validationData = _validateSignature(userOpHash, userOp.signature);
        }
        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }

    // ─── ERC-7579 Module Management (M7.2) ────────────────────────────

    /// @notice ERC-7579: Install a module.
    /// @param moduleTypeId 1=Validator, 2=Executor, 3=Hook
    /// @param module Module contract address (must be deployed)
    /// @param initData Guardian acceptance signature(s) + optional module init data.
    ///   Number of guardian sigs prepended: 0 if threshold<=40, 1 if threshold<=70, 2 if threshold=100.
    ///   Guardian sig hash: keccak256("INSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external onlyOwnerOrEntryPoint {
        if (module == address(0) || module.code.length == 0) revert ModuleInvalid();
        if (moduleTypeId == 0 || moduleTypeId > 3) revert InvalidModuleType();

        // Determine required guardian signatures based on threshold
        uint8 threshold = _installModuleThreshold == 0 ? 70 : _installModuleThreshold;
        uint8 sigsRequired = threshold >= 100 ? 2 : (threshold >= 70 ? 1 : 0);

        if (sigsRequired > 0) {
            bytes32 installHash = keccak256(
                abi.encodePacked("INSTALL_MODULE", block.chainid, address(this), moduleTypeId, module)
            ).toEthSignedMessageHash();

            uint256 approvedBitmap = 0;
            for (uint8 i = 0; i < sigsRequired; i++) {
                if (initData.length < uint256(i + 1) * 65) revert InstallModuleUnauthorized();
                bytes memory sig = abi.encodePacked(initData[uint256(i) * 65:uint256(i + 1) * 65]);
                address recovered = installHash.recover(sig);
                uint8 gi = _guardianIndex(recovered); // reverts NotGuardian if not a guardian
                uint256 bit = uint256(1) << gi;
                if (approvedBitmap & bit != 0) revert InstallModuleUnauthorized(); // no double-voting
                approvedBitmap |= bit;
            }
        }

        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            if (_installedValidators[module]) revert ModuleAlreadyInstalled();
            _installedValidators[module] = true;
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            if (_installedExecutors[module]) revert ModuleAlreadyInstalled();
            _installedExecutors[module] = true;
        } else {
            // MODULE_TYPE_HOOK
            if (_installedHooks[module]) revert ModuleAlreadyInstalled();
            _installedHooks[module] = true;
        }

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @notice ERC-7579: Uninstall a module.
    /// @dev Always requires 2 guardian signatures regardless of installModuleThreshold.
    ///      Guardian sig hash: keccak256("UNINSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external {
        if (moduleTypeId == 0 || moduleTypeId > 3) revert InvalidModuleType();

        // Uninstall always requires 2 guardian signatures (stronger than install)
        if (_guardianCount < 2) revert InstallModuleUnauthorized();
        bytes32 uninstallHash = keccak256(
            abi.encodePacked("UNINSTALL_MODULE", block.chainid, address(this), moduleTypeId, module)
        ).toEthSignedMessageHash();

        uint256 approvedBitmap = 0;
        for (uint8 i = 0; i < 2; i++) {
            if (deInitData.length < uint256(i + 1) * 65) revert InstallModuleUnauthorized();
            bytes memory sig = abi.encodePacked(deInitData[uint256(i) * 65:uint256(i + 1) * 65]);
            address recovered = uninstallHash.recover(sig);
            uint8 gi = _guardianIndex(recovered); // reverts NotGuardian if not a guardian
            uint256 bit = uint256(1) << gi;
            if (approvedBitmap & bit != 0) revert InstallModuleUnauthorized(); // no double-voting
            approvedBitmap |= bit;
        }

        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            if (!_installedValidators[module]) revert ModuleNotInstalled();
            _installedValidators[module] = false;
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            if (!_installedExecutors[module]) revert ModuleNotInstalled();
            _installedExecutors[module] = false;
        } else {
            if (!_installedHooks[module]) revert ModuleNotInstalled();
            _installedHooks[module] = false;
        }

        emit ModuleUninstalled(moduleTypeId, module);
    }

    /// @dev Execution struct for batch mode in executeFromExecutor
    struct Execution {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice ERC-7579: Execute calls on behalf of this account, called by an installed executor module.
    /// @param mode ModeCode (bytes32): byte[0]=callType (0x00=single, 0x01=batch), byte[1]=execType (ignored)
    /// @param executionCalldata For single: abi.encodePacked(target, value, calldata). For batch: abi.encode(Execution[])
    /// @return returnData Array of return data from each call
    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external nonReentrant returns (bytes[] memory returnData) {
        if (!_installedExecutors[msg.sender]) revert ModuleNotInstalled();

        uint8 callType = uint8(bytes1(mode));

        if (callType == 0x00) {
            // Single call: target(20) ++ value(32) ++ calldata
            if (executionCalldata.length < 52) revert ArrayLengthMismatch();
            address target = address(bytes20(executionCalldata[0:20]));
            uint256 value = uint256(bytes32(executionCalldata[20:52]));
            bytes calldata data = executionCalldata[52:];

            // Enforce daily limit (no tier re-check: executor install was guardian-gated)
            if (address(guard) != address(0)) {
                guard.checkTransaction(value, ALG_ECDSA); // use ALG_ECDSA as executor-level tier
            }

            returnData = new bytes[](1);
            (bool success, bytes memory result) = target.call{value: value}(data);
            if (!success) {
                assembly { revert(add(result, 32), mload(result)) }
            }
            returnData[0] = result;
        } else if (callType == 0x01) {
            // Batch call: abi.encode(Execution[])
            Execution[] memory execs = abi.decode(executionCalldata, (Execution[]));
            returnData = new bytes[](execs.length);
            for (uint256 i = 0; i < execs.length; i++) {
                if (address(guard) != address(0)) {
                    guard.checkTransaction(execs[i].value, ALG_ECDSA);
                }
                (bool success, bytes memory result) = execs[i].target.call{value: execs[i].value}(execs[i].data);
                if (!success) {
                    assembly { revert(add(result, 32), mload(result)) }
                }
                returnData[i] = result;
            }
        } else {
            revert InvalidModuleType(); // unsupported callType
        }
    }
}
