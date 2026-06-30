// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

contract MockEntryPointPA {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    receive() external payable {}
}

/// @dev Stands in for AAStarBLSAlgorithm at the account's ALG_BLS slot: implements validate()
///      (always succeeds) AND exposes the protocol-level `aggregator()` value the account reads.
contract MockBLSWithAggregator is IAAStarAlgorithm {
    address public aggregator;
    function setAggregator(address a) external { aggregator = a; }
    function validate(bytes32, bytes calldata) external pure override returns (uint256) { return 0; }
}

/// @dev issue #45 Part B: the account reads the SINGLE protocol-level aggregator via
///      blsAlgorithm.aggregator(). When non-zero the 0x01 BLS tier defers to the EntryPoint batch
///      aggregator (returns its address); when zero it does inline single-op verification. There is
///      NO account-side setter — the end-user owner cannot change which aggregator is used.
contract ProtocolAggregatorTest is Test {
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockBLSWithAggregator mockBls;
    MockEntryPointPA epMock;
    address entryPointAddr;
    Vm.Wallet ownerWallet;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        epMock = new MockEntryPointPA();
        entryPointAddr = address(epMock);

        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerWallet.addr, _emptyConfig(), address(0), bytes32(0), bytes32(0));

        router = new AAStarValidator();
        mockBls = new MockBLSWithAggregator();
        router.registerAlgorithm(0x01, address(mockBls)); // ALG_BLS

        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));
        vm.deal(address(account), 10 ether);
    }

    function _emptyConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: new uint8[](0),
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
    }

    function _userOp() internal view returns (PackedUserOperation memory op) {
        op = PackedUserOperation({
            sender: address(account), nonce: 0, initCode: "", callData: "",
            accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0),
            paymasterAndData: "", signature: ""
        });
    }

    // New triple-sig format: [0x01][len(32)][nodeId(32)][blsSig(256)][aaSig(65)]
    function _tripleSig(bytes32 userOpHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerWallet.privateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash)));
        return abi.encodePacked(
            uint8(0x01), uint256(1), keccak256("node"), new bytes(256), abi.encodePacked(r, s, v)
        );
    }

    // aggregator() == 0 → inline single-op path (mock validate returns 0 → success).
    function test_aggregatorZero_inlineSingleOpPath() public {
        assertEq(mockBls.aggregator(), address(0));
        PackedUserOperation memory op = _userOp();
        bytes32 h = keccak256(abi.encode(op));
        op.signature = _tripleSig(h);
        vm.prank(entryPointAddr);
        assertEq(account.validateUserOp(op, h, 0), 0, "inline BLS path should pass");
    }

    // aggregator() != 0 → 0x01 BLS tier returns the protocol aggregator address (batch deferral).
    function test_aggregatorSet_returnsAggregatorAddress() public {
        address agg = address(0xA66);
        mockBls.setAggregator(agg);
        PackedUserOperation memory op = _userOp();
        bytes32 h = keccak256(abi.encode(op));
        op.signature = _tripleSig(h);
        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(op, h, 0);
        assertEq(result, uint256(uint160(agg)), "should defer to protocol aggregator");
    }

    // Wrong owner signature still fails before the aggregator branch.
    function test_aggregatorSet_butWrongOwnerSig_fails() public {
        mockBls.setAggregator(address(0xA66));
        Vm.Wallet memory wrong = vm.createWallet("wrong");
        PackedUserOperation memory op = _userOp();
        bytes32 h = keccak256(abi.encode(op));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(wrong.privateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h)));
        op.signature = abi.encodePacked(uint8(0x01), uint256(1), keccak256("node"), new bytes(256), abi.encodePacked(r, s, v));
        vm.prank(entryPointAddr);
        assertEq(account.validateUserOp(op, h, 0), 1, "wrong owner sig must fail");
    }

    // There is NO account-side aggregator setter (old per-account API is gone).
    function test_noAccountSideSetter() public {
        (bool ok1,) = address(account).call(
            abi.encodeWithSignature("setAggregatorWithGuardians(address,uint256,bytes[])", address(0xA66), block.timestamp, new bytes[](0))
        );
        assertFalse(ok1, "setAggregatorWithGuardians must not exist on the account");
        (bool ok2,) = address(account).call(abi.encodeWithSignature("setAggregator(address)", address(0xA66)));
        assertFalse(ok2, "setAggregator must not exist on the account");
        (bool ok3,) = address(account).call(abi.encodeWithSignature("blsAggregator()"));
        assertFalse(ok3, "blsAggregator() getter must be gone");
    }
}
