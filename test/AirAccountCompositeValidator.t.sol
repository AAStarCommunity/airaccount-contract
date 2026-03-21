// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AirAccountCompositeValidator} from "../src/validators/AirAccountCompositeValidator.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock account that always returns EIP-1271 magic value from isValidSignature
contract MockAccountReturnsValid {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e; // EIP-1271 magic
    }
}

/// @dev Mock account that always returns failure from isValidSignature
contract MockAccountReturnsInvalid {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff; // failure magic
    }
}

/// @dev Mock account that reverts on isValidSignature
contract MockAccountReverts {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("sig check failed");
    }
}

/// @title AirAccountCompositeValidatorTest — Unit tests for AirAccountCompositeValidator (M7)
contract AirAccountCompositeValidatorTest is Test {
    AirAccountCompositeValidator public validator;

    address public account;
    address public other;

    // algId constants (matches AirAccountCompositeValidator)
    uint8 constant ALG_ECDSA         = 0x02;
    uint8 constant ALG_CUMULATIVE_T2 = 0x04;
    uint8 constant ALG_CUMULATIVE_T3 = 0x05;
    uint8 constant ALG_WEIGHTED      = 0x07;

    function setUp() public {
        validator = new AirAccountCompositeValidator();
        account   = makeAddr("account");
        other     = makeAddr("other");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _makeUserOp(address sender, bytes memory sig) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: sig
        });
    }

    // ─── onInstall / onUninstall / isInitialized ──────────────────────────────

    function test_onInstall_setsInitialized() public {
        assertFalse(validator.isInitialized(account));
        vm.prank(account);
        validator.onInstall("");
        assertTrue(validator.isInitialized(account));
    }

    function test_onUninstall_clearsInitialized() public {
        vm.startPrank(account);
        validator.onInstall("");
        assertTrue(validator.isInitialized(account));

        validator.onUninstall("");
        vm.stopPrank();

        assertFalse(validator.isInitialized(account));
    }

    function test_isInitialized_beforeInstall_false() public view {
        assertFalse(validator.isInitialized(other));
    }

    // ─── validateUserOp ───────────────────────────────────────────────────────

    function test_validateUserOp_notInitialized_reverts() public {
        // sender not initialized to AccountNotInitialized
        bytes memory sig = abi.encodePacked(ALG_CUMULATIVE_T2, hex"deadbeef");
        PackedUserOperation memory userOp = _makeUserOp(account, sig);

        vm.expectRevert(AirAccountCompositeValidator.AccountNotInitialized.selector);
        validator.validateUserOp(userOp, bytes32(0));
    }

    function test_validateUserOp_emptySignature_returns1() public {
        // Install account first
        vm.prank(account);
        validator.onInstall("");

        PackedUserOperation memory userOp = _makeUserOp(account, "");

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 1, "empty sig should return 1 (invalid)");
    }

    function test_validateUserOp_unsupportedAlgId_reverts() public {
        // Install account
        vm.prank(account);
        validator.onInstall("");

        // algId=0x02 (ECDSA) is NOT a composite alg to UnsupportedAlgId
        bytes memory sig = abi.encodePacked(ALG_ECDSA, hex"deadbeef");
        PackedUserOperation memory userOp = _makeUserOp(account, sig);

        vm.expectRevert(abi.encodeWithSelector(
            AirAccountCompositeValidator.UnsupportedAlgId.selector,
            ALG_ECDSA
        ));
        validator.validateUserOp(userOp, bytes32(0));
    }

    function test_validateUserOp_unsupportedAlgId_0x01_reverts() public {
        vm.prank(account);
        validator.onInstall("");

        bytes memory sig = abi.encodePacked(uint8(0x01), hex"deadbeef");
        PackedUserOperation memory userOp = _makeUserOp(account, sig);

        vm.expectRevert(abi.encodeWithSelector(
            AirAccountCompositeValidator.UnsupportedAlgId.selector,
            uint8(0x01)
        ));
        validator.validateUserOp(userOp, bytes32(0));
    }

    function test_validateUserOp_compositeAlgId_delegatesToAccount_returns0() public {
        // Deploy a mock account contract that returns EIP-1271 magic
        MockAccountReturnsValid mockAccount = new MockAccountReturnsValid();
        address mockAddr = address(mockAccount);

        // Install validator for that mock account address (prank as mockAddr)
        vm.prank(mockAddr);
        validator.onInstall("");

        // Build a userOp with algId=T2 signed by "mockAddr"
        bytes memory sig = abi.encodePacked(ALG_CUMULATIVE_T2, hex"aabbccdd");
        PackedUserOperation memory userOp = _makeUserOp(mockAddr, sig);

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 0, "mock returns valid EIP-1271, should return 0");
    }

    function test_validateUserOp_compositeAlgId_t3_delegatesToAccount_returns0() public {
        MockAccountReturnsValid mockAccount = new MockAccountReturnsValid();
        address mockAddr = address(mockAccount);

        vm.prank(mockAddr);
        validator.onInstall("");

        bytes memory sig = abi.encodePacked(ALG_CUMULATIVE_T3, hex"aabbccdd");
        PackedUserOperation memory userOp = _makeUserOp(mockAddr, sig);

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 0, "ALG_T3 + valid sig should return 0");
    }

    function test_validateUserOp_compositeAlgId_weighted_delegatesToAccount_returns0() public {
        MockAccountReturnsValid mockAccount = new MockAccountReturnsValid();
        address mockAddr = address(mockAccount);

        vm.prank(mockAddr);
        validator.onInstall("");

        bytes memory sig = abi.encodePacked(ALG_WEIGHTED, hex"aabbccdd");
        PackedUserOperation memory userOp = _makeUserOp(mockAddr, sig);

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 0, "ALG_WEIGHTED + valid sig to returns 0");
    }

    function test_validateUserOp_accountReturnsInvalid_returns1() public {
        MockAccountReturnsInvalid mockAccount = new MockAccountReturnsInvalid();
        address mockAddr = address(mockAccount);

        vm.prank(mockAddr);
        validator.onInstall("");

        bytes memory sig = abi.encodePacked(ALG_CUMULATIVE_T2, hex"aabbccdd");
        PackedUserOperation memory userOp = _makeUserOp(mockAddr, sig);

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 1, "account returns invalid magic to result should be 1");
    }

    function test_validateUserOp_accountReverts_returns1() public {
        MockAccountReverts mockAccount = new MockAccountReverts();
        address mockAddr = address(mockAccount);

        vm.prank(mockAddr);
        validator.onInstall("");

        bytes memory sig = abi.encodePacked(ALG_CUMULATIVE_T2, hex"aabbccdd");
        PackedUserOperation memory userOp = _makeUserOp(mockAddr, sig);

        uint256 result = validator.validateUserOp(userOp, bytes32(0));
        assertEq(result, 1, "account staticcall fails to result should be 1");
    }

    // ─── isValidSignatureWithSender ───────────────────────────────────────────

    function test_isValidSignatureWithSender_returns_magic_when_valid() public {
        // Deploy mock that returns magic, etch its code onto a test address
        MockAccountReturnsValid mockImpl = new MockAccountReturnsValid();
        address mockAddr = makeAddr("mockAccount");
        vm.etch(mockAddr, address(mockImpl).code);

        // Call isValidSignatureWithSender from mockAddr — msg.sender = mockAddr
        vm.prank(mockAddr);
        bytes4 result = validator.isValidSignatureWithSender(other, bytes32(0), "");
        assertEq(result, bytes4(0x1626ba7e), "should forward magic value");
    }

    function test_isValidSignatureWithSender_returns_failure_when_invalid() public {
        MockAccountReturnsInvalid mockImpl = new MockAccountReturnsInvalid();
        address mockAddr = makeAddr("mockAccount2");
        vm.etch(mockAddr, address(mockImpl).code);

        vm.prank(mockAddr);
        bytes4 result = validator.isValidSignatureWithSender(other, bytes32(0), "");
        assertEq(result, bytes4(0xffffffff), "should return failure magic");
    }

    function test_isValidSignatureWithSender_callerHasNoCode_returnsFailure() public view {
        // If msg.sender has no code, staticcall returns empty to returns 0xffffffff
        // (caller = address(this) which has code, but let's use an EOA)
        // Actually we call directly — msg.sender = address(this) = test contract with code
        bytes4 result = validator.isValidSignatureWithSender(other, bytes32(0), "");
        // test contract doesn't implement isValidSignature to returns 0xffffffff
        assertEq(result, bytes4(0xffffffff));
    }
}
