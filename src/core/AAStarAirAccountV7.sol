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

    /// @notice Contract version — updated on each release
    string public constant VERSION = "0.15.0";

    constructor(address _entryPoint, address _owner, InitConfig memory _config)
        AAStarAirAccountBase(_entryPoint, _owner, _config) {}

    // ─── ERC-7579 Minimum Compatibility Shim ─────────────────────────

    // Module type IDs (ERC-7579 §2)
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR  = 2;

    /// @notice ERC-7579 account identity string.
    ///         Format: "vendor.name.version" — enables tooling to identify this account type.
    function accountId() external pure returns (string memory) {
        return "airaccount.v7@0.15.0";
    }

    /// @notice ERC-7579: declare which module types this account supports.
    ///         M6 declares validator(1) and executor(2) support.
    ///         Hook(3) and Fallback(4) are planned for M7.
    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR || moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @notice ERC-7579: check whether a module is installed.
    ///         For validators (type 1): returns true if module == validator router address.
    ///         For executors (type 2): not yet installed, returns false.
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata /* additionalContext */
    ) external view returns (bool) {
        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            return module == address(validator);
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

    /// @notice Returns the contract version string
    function version() external pure returns (string memory) {
        return VERSION;
    }

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        validationData = _validateSignature(userOpHash, userOp.signature);
        if (missingAccountFunds > 0) {
            _payPrefund(missingAccountFunds);
        }
    }
}
