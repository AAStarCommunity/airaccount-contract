// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC7579Validator} from "../interfaces/IERC7579Module.sol";

/// @title AirAccountCompositeValidator — ERC-7579 Validator module
/// @notice Combines ALG_WEIGHTED(0x07), ALG_CUMULATIVE_T2(0x04), ALG_CUMULATIVE_T3(0x05) into one module.
/// @dev Routes internally by algId (first byte of signature). Delegates actual verification to the account's
///      built-in _validateSignature logic via a callback interface.
///
///      This module is designed to be installed on AAStarAirAccountV7 accounts and called via nonce-key routing.
///      When the nonce key selects this validator, validateUserOp is called instead of the account's built-in.
///
///      Architecture: The composite validator itself doesn't replicate all the cryptographic logic from
///      AAStarAirAccountBase. Instead, it accepts the signature if the account's own isValidSignature()
///      confirms validity. This avoids code duplication while providing the ERC-7579 module interface.
contract AirAccountCompositeValidator is IERC7579Validator {
    // algId constants (must match AAStarAirAccountBase)
    uint8 internal constant ALG_CUMULATIVE_T2 = 0x04;
    uint8 internal constant ALG_CUMULATIVE_T3 = 0x05;
    uint8 internal constant ALG_WEIGHTED      = 0x07;

    error UnsupportedAlgId(uint8 algId);
    error AccountNotInitialized();

    mapping(address => bool) internal _initialized;

    // ─── IERC7579Module ─────────────────────────────────────────────

    function onInstall(bytes calldata /* data */) external override {
        _initialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata /* data */) external override {
        _initialized[msg.sender] = false;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return _initialized[smartAccount];
    }

    // ─── IERC7579Validator ─────────────────────────────────────────

    /// @notice Validate a UserOperation by delegating back to the account's full signature validation.
    /// @dev Calls account.validateCompositeSignature(userOpHash, sig) which runs the same
    ///      cryptographic logic as the built-in path (P256+BLS+Guardian for T2/T3, weighted for 0x07).
    ///      The account sets SKIP_ALGID_STORE_SLOT before validation so algId is stored only once
    ///      (by the outer validateUserOp), preventing queue corruption in batched UserOps.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external override returns (uint256 validationData) {
        if (!_initialized[userOp.sender]) revert AccountNotInitialized();

        if (userOp.signature.length == 0) return 1;
        uint8 algId = uint8(userOp.signature[0]);

        // Only handle composite algorithms
        if (algId != ALG_CUMULATIVE_T2 && algId != ALG_CUMULATIVE_T3 && algId != ALG_WEIGHTED) {
            revert UnsupportedAlgId(algId);
        }

        // Delegate to account's full validateCompositeSignature (not isValidSignature — that is
        // owner-ECDSA only and would reject all multi-sig formats).
        (bool ok, bytes memory ret) = userOp.sender.call(
            abi.encodeWithSignature("validateCompositeSignature(bytes32,bytes)", userOpHash, userOp.signature)
        );
        if (ok && ret.length >= 32) {
            return abi.decode(ret, (uint256));
        }
        return 1;
    }

    function isValidSignatureWithSender(
        address /* sender */,
        bytes32 hash,
        bytes calldata data
    ) external view override returns (bytes4 magicValue) {
        // Pass through to ERC-1271 check on the calling account
        (bool ok, bytes memory ret) = msg.sender.staticcall(
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", hash, data)
        );
        if (ok && ret.length >= 32) {
            return abi.decode(ret, (bytes4));
        }
        return 0xffffffff;
    }
}
