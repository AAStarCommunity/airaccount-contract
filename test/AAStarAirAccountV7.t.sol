// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction/interfaces/IStakeManager.sol";

/// @title MockEntryPoint - Minimal mock for EntryPoint deposit/withdraw functionality
contract MockEntryPoint {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) external {
        // In real EntryPoint, msg.sender is the account that owns the deposit
        deposits[msg.sender] -= amount;
        (bool success,) = withdrawAddress.call{value: amount}("");
        require(success, "withdraw failed");
    }

    receive() external payable {}
}

/// @title AAStarAirAccountV7Test - Comprehensive unit tests for AAStarAirAccountV7
contract AAStarAirAccountV7Test is Test {
    AAStarAirAccountV7 public account;
    MockEntryPoint public mockEntryPoint;

    Vm.Wallet public ownerWallet;
    Vm.Wallet public randomWallet;

    address public entryPointAddr;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        randomWallet = vm.createWallet("random");

        mockEntryPoint = new MockEntryPoint();
        entryPointAddr = address(mockEntryPoint);

        account = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr);

        // Fund the account with 10 ETH
        vm.deal(address(account), 10 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _buildUserOp(bytes memory signature) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }

    function _signUserOp(bytes32 userOpHash, uint256 privateKey) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── Signature Validation Tests ─────────────────────────────────────

    /// @notice Valid owner signature should return 0 (success)
    function test_validateUserOp_validSignature() public {
        bytes32 userOpHash = keccak256("test user op hash");
        bytes memory sig = _signUserOp(userOpHash, ownerWallet.privateKey);
        PackedUserOperation memory userOp = _buildUserOp(sig);

        vm.prank(entryPointAddr);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0, "Valid signature should return 0");
    }

    /// @notice Invalid signature (wrong signer) should return 1 (SIG_VALIDATION_FAILED)
    function test_validateUserOp_invalidSignature() public {
        bytes32 userOpHash = keccak256("test user op hash");
        bytes memory sig = _signUserOp(userOpHash, randomWallet.privateKey);
        PackedUserOperation memory userOp = _buildUserOp(sig);

        vm.prank(entryPointAddr);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 1, "Invalid signature should return 1 (SIG_VALIDATION_FAILED)");
    }

    /// @notice Calling validateUserOp from non-EntryPoint should revert
    function test_validateUserOp_onlyEntryPoint() public {
        bytes32 userOpHash = keccak256("test user op hash");
        bytes memory sig = _signUserOp(userOpHash, ownerWallet.privateKey);
        PackedUserOperation memory userOp = _buildUserOp(sig);

        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotEntryPoint.selector);
        account.validateUserOp(userOp, userOpHash, 0);
    }

    /// @notice validateUserOp should pay prefund when missingAccountFunds > 0
    function test_validateUserOp_paysPrefund() public {
        bytes32 userOpHash = keccak256("test user op hash");
        bytes memory sig = _signUserOp(userOpHash, ownerWallet.privateKey);
        PackedUserOperation memory userOp = _buildUserOp(sig);

        uint256 prefund = 0.1 ether;
        uint256 epBalanceBefore = entryPointAddr.balance;

        vm.prank(entryPointAddr);
        account.validateUserOp(userOp, userOpHash, prefund);

        assertEq(entryPointAddr.balance, epBalanceBefore + prefund, "EntryPoint should receive prefund");
    }

    // ─── Execution Tests ────────────────────────────────────────────────

    /// @notice Execute ETH transfer from EntryPoint should succeed
    function test_execute_fromEntryPoint() public {
        address recipient = makeAddr("recipient");
        uint256 sendAmount = 1 ether;

        vm.prank(entryPointAddr);
        account.execute(recipient, sendAmount, "");

        assertEq(recipient.balance, sendAmount, "Recipient should receive ETH");
    }

    /// @notice Execute from owner directly should succeed
    function test_execute_fromOwner() public {
        address recipient = makeAddr("recipient");
        uint256 sendAmount = 1 ether;

        vm.prank(ownerWallet.addr);
        account.execute(recipient, sendAmount, "");

        assertEq(recipient.balance, sendAmount, "Recipient should receive ETH");
    }

    /// @notice Execute from unauthorized address should revert
    function test_execute_fromUnauthorized() public {
        address recipient = makeAddr("recipient");

        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwnerOrEntryPoint.selector);
        account.execute(recipient, 1 ether, "");
    }

    /// @notice Batch execute multiple ETH transfers
    function test_executeBatch_success() public {
        address[] memory dests = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory funcs = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            dests[i] = makeAddr(string(abi.encodePacked("recipient", i)));
            values[i] = 0.5 ether;
            funcs[i] = "";
        }

        vm.prank(entryPointAddr);
        account.executeBatch(dests, values, funcs);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(dests[i].balance, 0.5 ether, "Each recipient should receive 0.5 ETH");
        }
    }

    /// @notice Batch execute with mismatched array lengths should revert
    function test_executeBatch_arrayMismatch() public {
        address[] memory dests = new address[](2);
        uint256[] memory values = new uint256[](3);
        bytes[] memory funcs = new bytes[](2);

        vm.prank(entryPointAddr);
        vm.expectRevert(AAStarAirAccountBase.ArrayLengthMismatch.selector);
        account.executeBatch(dests, values, funcs);
    }

    /// @notice Batch execute with mismatched func array length should also revert
    function test_executeBatch_arrayMismatch_funcs() public {
        address[] memory dests = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory funcs = new bytes[](3);

        vm.prank(entryPointAddr);
        vm.expectRevert(AAStarAirAccountBase.ArrayLengthMismatch.selector);
        account.executeBatch(dests, values, funcs);
    }

    // ─── Deposit Management Tests ───────────────────────────────────────

    /// @notice addDeposit should forward ETH to EntryPoint
    function test_addDeposit() public {
        uint256 depositAmount = 1 ether;

        account.addDeposit{value: depositAmount}();

        uint256 deposit = account.getDeposit();
        assertEq(deposit, depositAmount, "Deposit should match sent amount");
    }

    /// @notice withdrawDepositTo should work when called by owner
    function test_withdrawDepositTo() public {
        // First add a deposit
        account.addDeposit{value: 2 ether}();
        assertEq(account.getDeposit(), 2 ether);

        address payable recipient = payable(makeAddr("withdrawRecipient"));
        uint256 withdrawAmount = 1 ether;

        vm.prank(ownerWallet.addr);
        account.withdrawDepositTo(recipient, withdrawAmount);

        assertEq(account.getDeposit(), 1 ether, "Remaining deposit should be 1 ETH");
        assertEq(recipient.balance, withdrawAmount, "Recipient should receive withdrawn amount");
    }

    /// @notice withdrawDepositTo should revert when called by non-owner
    function test_withdrawDepositTo_notOwner() public {
        account.addDeposit{value: 1 ether}();

        address payable recipient = payable(makeAddr("withdrawRecipient"));

        vm.prank(randomWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.NotOwner.selector);
        account.withdrawDepositTo(recipient, 0.5 ether);
    }

    // ─── Receive ETH Test ───────────────────────────────────────────────

    /// @notice Account should be able to receive ETH directly
    function test_receiveEth() public {
        uint256 balanceBefore = address(account).balance;
        uint256 sendAmount = 1 ether;

        (bool success,) = address(account).call{value: sendAmount}("");

        assertTrue(success, "ETH transfer should succeed");
        assertEq(address(account).balance, balanceBefore + sendAmount, "Account balance should increase");
    }

    // ─── State Tests ────────────────────────────────────────────────────

    /// @notice Verify immutable state is set correctly
    function test_immutableState() public view {
        assertEq(account.entryPoint(), entryPointAddr, "EntryPoint should match");
        assertEq(account.owner(), ownerWallet.addr, "Owner should match");
    }
}
