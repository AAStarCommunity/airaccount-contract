// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock EntryPoint for M2 tests
contract MockEntryPointM2 {
    mapping(address => uint256) public balances;

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function withdrawTo(address payable to, uint256 amount) external {
        balances[msg.sender] -= amount;
        (bool s,) = to.call{value: amount}("");
        require(s);
    }

    receive() external payable {}
}

/// @dev Mock algorithm that always succeeds
contract MockSuccessAlgorithm is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) {
        return 0;
    }
}

contract AAStarAirAccountV7_M2Test is Test {
    MockEntryPointM2 entryPointMock;
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockSuccessAlgorithm mockAlg;

    Vm.Wallet ownerWallet;
    address entryPointAddr;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        entryPointMock = new MockEntryPointM2();
        entryPointAddr = address(entryPointMock);

        account = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr, _emptyConfig());
        router = new AAStarValidator();
        mockAlg = new MockSuccessAlgorithm();

        // Fund account
        vm.deal(address(account), 10 ether);
    }

    function _emptyConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        uint8[] memory noAlgs = new uint8[](0);
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs
        });
    }

    // ─── Validator Configuration ──────────────────────────────────────

    function test_setValidator() public {
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));
        assertEq(address(account.validator()), address(router));
    }

    function test_setValidator_onlyOwner() public {
        vm.expectRevert();
        account.setValidator(address(router));
    }

    // ─── ECDSA Backwards Compatibility (65-byte sig, no algId) ────────

    function test_ecdsaBackwardsCompat() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Sign with owner wallet (65-byte ECDSA, no algId prefix)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            ownerWallet.privateKey,
            _ethSignedMessageHash(userOpHash)
        );
        userOp.signature = abi.encodePacked(r, s, v);

        // Validate via EntryPoint
        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "ECDSA backwards compat should pass");
    }

    // ─── Explicit ECDSA with algId=0x02 prefix ───────────────────────

    function test_ecdsaWithAlgIdPrefix() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            ownerWallet.privateKey,
            _ethSignedMessageHash(userOpHash)
        );
        // Prefix with algId=0x02
        userOp.signature = abi.encodePacked(uint8(0x02), r, s, v);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "ECDSA with algId prefix should pass");
    }

    // ─── Invalid ECDSA ───────────────────────────────────────────────

    function test_invalidEcdsaSig() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Sign with wrong key
        Vm.Wallet memory wrongWallet = vm.createWallet("wrong");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            wrongWallet.privateKey,
            _ethSignedMessageHash(userOpHash)
        );
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong signer should fail");
    }

    // ─── Unknown algId without validator → fail ──────────────────────

    function test_unknownAlgId_noValidator() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        userOp.signature = abi.encodePacked(uint8(0xff), bytes("randomdata"));

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Unknown algId without validator should fail");
    }

    // ─── Empty signature → fail ──────────────────────────────────────

    function test_emptySignature() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        userOp.signature = "";

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Empty sig should fail");
    }

    // ─── Triple signature with malformed data → fail ─────────────────

    function test_tripleSignature_malformed() public {
        // Set validator so BLS path is attempted
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // algId=0x01 + garbage data (too short for triple sig)
        userOp.signature = abi.encodePacked(uint8(0x01), bytes("tooshort"));

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Malformed triple sig should fail");
    }

    // ─── Triple signature with wrong aaSignature signer → fail ───────

    function test_tripleSignature_wrongAASigner() public {
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));

        // Register mock BLS algorithm
        router.registerAlgorithm(0x01, address(mockAlg));

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Build properly structured triple sig but with wrong signer
        Vm.Wallet memory wrongWallet = vm.createWallet("wrong2");
        bytes memory tripSig = _buildTripleSig(userOpHash, wrongWallet, ownerWallet);

        userOp.signature = abi.encodePacked(uint8(0x01), tripSig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong AA signer should fail");
    }

    // ─── Triple signature with wrong messagePoint signer → fail ──────

    function test_tripleSignature_wrongMPSigner() public {
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));

        router.registerAlgorithm(0x01, address(mockAlg));

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        Vm.Wallet memory wrongWallet = vm.createWallet("wrong3");
        bytes memory tripSig = _buildTripleSig(userOpHash, ownerWallet, wrongWallet);

        userOp.signature = abi.encodePacked(uint8(0x01), tripSig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong MP signer should fail");
    }

    // ─── Triple signature with valid ECDSA + mock BLS → pass ─────────

    function test_tripleSignature_validWithMockBLS() public {
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));

        router.registerAlgorithm(0x01, address(mockAlg));

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory tripSig = _buildTripleSig(userOpHash, ownerWallet, ownerWallet);

        userOp.signature = abi.encodePacked(uint8(0x01), tripSig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Valid triple sig with mock BLS should pass");
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _buildUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _ethSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /// @dev Build a triple signature with given wallets for AA sig and MP sig.
    ///      Uses 1 fake nodeId, fake BLS sig and messagePoint (256 bytes each).
    function _buildTripleSig(
        bytes32 userOpHash,
        Vm.Wallet memory aaSigner,
        Vm.Wallet memory mpSigner
    ) internal pure returns (bytes memory) {
        // 1 nodeId
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");

        // Fake BLS signature (256 bytes) and message point (256 bytes)
        bytes memory blsSig = new bytes(256);
        bytes memory messagePoint = new bytes(256);
        messagePoint[0] = 0x42; // Non-zero so keccak256 is distinct

        // AA signature (ECDSA over userOpHash)
        (uint8 v1, bytes32 r1, bytes32 s1) = _signHash(aaSigner, userOpHash);

        // MessagePoint signature (ECDSA over keccak256(messagePoint))
        bytes32 mpHash = keccak256(messagePoint);
        (uint8 v2, bytes32 r2, bytes32 s2) = _signHash(mpSigner, mpHash);

        return abi.encodePacked(
            bytes32(nodeIdsLength),  // 32
            fakeNodeId,              // 32
            blsSig,                  // 256
            messagePoint,            // 256
            abi.encodePacked(r1, s1, v1), // 65
            abi.encodePacked(r2, s2, v2)  // 65
        );
    }

    function _signHash(Vm.Wallet memory w, bytes32 hash) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (v, r, s) = vm.sign(w.privateKey, ethHash);
    }
}
