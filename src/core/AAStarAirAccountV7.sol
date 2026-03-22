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

    /// @notice ERC-7579 account identity string.
    ///         Format: "vendor.name.version" — enables tooling to identify this account type.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.16.0";
    }

    /// @notice ERC-7579: declare which module types this account supports.
    ///         M7 declares validator(1), executor(2), and hook(3) support.
    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        unchecked { return moduleTypeId - 1 < 3; } // 1,2,3=valid; 0 wraps to MAX→false
    }

    /// @notice ERC-7579: check whether a module is installed.
    ///         Checks the unified module registry for types 1-3.
    ///         Note: the built-in ECDSA validator is registered at initialize time.
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata /* additionalContext */
    ) external view returns (bool) {
        if (moduleTypeId == 0 || moduleTypeId > 3) return false;
        return _installedModules[moduleTypeId][module];
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

    /// @notice H-5: Composite signature callback for AirAccountCompositeValidator module.
    ///         Validates weighted/cumulative signatures using the account's built-in routing.
    ///         Called by the installed CompositeValidator module via nonce-key routing.
    ///         Also stores the algId in the transient queue (H-6) for guard tier enforcement.
    function validateCompositeSignature(bytes32 hash, bytes calldata sig) external returns (uint256) {
        if (!_installedModules[MODULE_TYPE_VALIDATOR][msg.sender]) revert ModuleNotInstalled();
        return _validateSignature(hash, sig);
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
        address validatorModule = address(uint160(userOp.nonce >> 64));
        if (validatorModule != address(0)) {
            if (!_installedModules[MODULE_TYPE_VALIDATOR][validatorModule]) {
                validationData = 1; // SIG_VALIDATION_FAILED — module not installed
            } else {
                // selector = keccak256("validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)")
                (bool ok, bytes memory ret) = validatorModule.call(
                    abi.encodeWithSelector(0x97003203, userOp, userOpHash)
                );
                validationData = (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 1;
                // H-6: store sig[0] as algId so guard receives the correct tier.
                // CompositeValidator may push a more-specific algId first via validateCompositeSignature;
                // execute() reads that entry (pos 0) first, leaving this one unconsumed.
                // Only write algId on success (validationData==0) to avoid polluting the transient queue
                // with garbage bytes from failed validations in batched UserOp bundles.
                if (validationData == 0 && userOp.signature.length > 0) _storeValidatedAlgId(uint8(userOp.signature[0]));
            }
        } else {
            validationData = _validateSignature(userOpHash, userOp.signature);
        }
        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }

    // ─── ERC-7579 Module Management (M7.2) ────────────────────────────

    /// @dev Best-effort onUninstall(bytes) call with empty data.
    ///      Uses scratch memory (0x00) and ignores call result.
    function _callLifecycle(bytes4 sel, address module) private {
        assembly {
            mstore(0, sel)
            mstore(4, 0x20)
            mstore(0x24, 0)
            pop(call(gas(), module, 0, 0, 0x44, 0, 0))
        }
    }

    /// @dev Verify `count` sequential 65-byte ECDSA sigs from distinct guardians.
    ///      Reverts InstallModuleUnauthorized on any failure (too few bytes, non-guardian, double-vote).
    function _checkGuardianSigs(bytes32 hash, bytes calldata sigs, uint8 count) private {
        uint256 bitmap;
        for (uint8 i; i < count; ++i) {
            uint256 end = uint256(i + 1) * 65;
            if (sigs.length < end) revert InstallModuleUnauthorized();
            address recovered = hash.recover(sigs[end - 65 : end]);
            uint256 bit = uint256(1) << _guardianIndex(recovered);
            if (bitmap & bit != 0) revert InstallModuleUnauthorized();
            bitmap |= bit;
        }
    }

    /// @notice ERC-7579: Install a module.
    /// @param moduleTypeId 1=Validator, 2=Executor, 3=Hook
    /// @param module Module contract address (must be deployed)
    /// @param initData Layout: guardian sig(s) prepended, then module init data.
    ///   Guardian sig count: 0 if threshold<=40, 1 if threshold<=70, 2 if threshold=100.
    ///   Sig hash: keccak256("INSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    ///   Bytes after the sig(s) are passed as initData to onInstall(bytes).
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external onlyOwnerOrEntryPoint {
        if (module == address(0) || module.code.length == 0) revert ModuleInvalid();
        if (moduleTypeId == 0 || moduleTypeId > 3) revert InvalidModuleType();

        uint8 threshold = _installModuleThreshold == 0 ? 70 : _installModuleThreshold;
        uint8 sigsRequired = threshold >= 100 ? 2 : (threshold >= 70 ? 1 : 0);

        if (sigsRequired > 0) {
            _checkGuardianSigs(
                keccak256(abi.encodePacked("INSTALL_MODULE", block.chainid, address(this), moduleTypeId, module))
                    .toEthSignedMessageHash(),
                initData, sigsRequired
            );
        }

        if (_installedModules[moduleTypeId][module]) revert ModuleAlreadyInstalled();
        _installedModules[moduleTypeId][module] = true;
        // Only one active hook is tracked. Installing a second Hook module overwrites _activeHook,
        // silently deactivating the previous hook's preCheck dispatch. Callers must uninstall the
        // existing hook before installing a new one to avoid silent deactivation.
        if (moduleTypeId == MODULE_TYPE_HOOK) _activeHook = module;

        // Pass bytes after the guardian sigs as actual module initData.
        // Best-effort: ignore onInstall revert (backward-compatible with modules that don't need initData).
        bytes calldata moduleInitData = initData[uint256(sigsRequired) * 65:];
        (bool _ok,) = module.call(abi.encodeWithSelector(0x6d61fe70, moduleInitData));
        _ok; // best-effort

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @notice ERC-7579: Uninstall a module.
    /// @dev Always requires 2 guardian sigs regardless of installModuleThreshold.
    ///      Sig hash: keccak256("UNINSTALL_MODULE" || chainId || account || moduleTypeId || module).toEthSignedMessageHash()
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    ) external onlyOwnerOrEntryPoint {
        if (moduleTypeId == 0 || moduleTypeId > 3) revert InvalidModuleType();

        _checkGuardianSigs(
            keccak256(abi.encodePacked("UNINSTALL_MODULE", block.chainid, address(this), moduleTypeId, module))
                .toEthSignedMessageHash(),
            deInitData, 2
        );

        if (!_installedModules[moduleTypeId][module]) revert ModuleNotInstalled();
        _installedModules[moduleTypeId][module] = false;
        if (moduleTypeId == MODULE_TYPE_HOOK && _activeHook == module) _activeHook = address(0);
        _callLifecycle(0x8a91b0e3, module); // M-10: best-effort onUninstall(bytes)
        emit ModuleUninstalled(moduleTypeId, module);
    }

    /// @notice ERC-7579: Execute a single call on behalf of this account, called by an installed executor module.
    ///         Executor modules are installed via guardians (installModule requires guardian sig), providing
    ///         authentication. The guard is still enforced here for ETH value AND ERC20 token limits.
    /// @param mode    ModeCode (bytes32): byte[0] must be 0x00 (single call). Batch mode not supported in M7.
    /// @param executionCalldata abi.encodePacked(target(20), value(32), calldata)
    /// @return returnData Single-element array with the call's return bytes
    function executeFromExecutor(
        bytes32 mode,
        bytes calldata executionCalldata
    ) external nonReentrant returns (bytes[] memory returnData) {
        if (!_installedModules[MODULE_TYPE_EXECUTOR][msg.sender]) revert ModuleNotInstalled();
        // ERC-7579 ModeCode: only single-call (byte[0]=0x00) with no extra flags (bytes[1-31] must be zero).
        // Reject batch mode (0x01) and any unknown execution type flags — strict compliance, no ambiguity.
        if (mode != bytes32(0)) revert InvalidModuleType();
        if (executionCalldata.length < 52) revert ArrayLengthMismatch();

        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value  = uint256(bytes32(executionCalldata[20:52]));
        bytes calldata data = executionCalldata[52:];

        // Enforce ETH + token daily limits at ALG_ECDSA tier.
        // Executor install required guardian approval, but guard still applies per-op limits.
        if (address(guard) != address(0)) {
            guard.checkTransaction(value, ALG_ECDSA);
            if (data.length >= 4) _checkTokenGuard(target, data, ALG_ECDSA);
        }

        returnData = new bytes[](1);
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) { assembly { revert(add(result, 32), mload(result)) } }
        returnData[0] = result;
    }
}
