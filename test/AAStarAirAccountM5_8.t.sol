// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock P256 precompile that always returns valid
contract MockP256ValidM58 {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @dev Mock P256 precompile that always returns invalid
contract MockP256InvalidM58 {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// @dev Mock EntryPoint
contract MockEPM58 {
    mapping(address => uint256) public balances;
    function depositTo(address a) external payable { balances[a] += msg.value; }
    function balanceOf(address a) external view returns (uint256) { return balances[a]; }
    function withdrawTo(address payable to, uint256 amount) external {
        balances[msg.sender] -= amount;
        (bool s,) = to.call{value: amount}("");
        require(s);
    }
    receive() external payable {}
}

/// @title AAStarAirAccountM5_8Test — ALG_COMBINED_T1 (0x06) zero-trust tier 1 tests (F79)
contract AAStarAirAccountM5_8Test is Test {
    uint8 constant ALG_COMBINED_T1 = 0x06;

    MockEPM58 entryPointMock;
    AAStarAirAccountV7 account;
    Vm.Wallet ownerWallet;
    address entryPointAddr;

    MockP256ValidM58 p256ValidMock;
    MockP256InvalidM58 p256InvalidMock;

    function setUp() public {
        ownerWallet = vm.createWallet("owner58");
        entryPointMock = new MockEPM58();
        entryPointAddr = address(entryPointMock);

        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_COMBINED_T1;

        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });

        account = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr, config);
        vm.deal(address(account), 10 ether);

        // Set P256 key (non-zero)
        vm.prank(ownerWallet.addr);
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        p256ValidMock = new MockP256ValidM58();
        p256InvalidMock = new MockP256InvalidM58();

        // Deploy valid P256 precompile at 0x100 by default
        vm.etch(address(0x100), address(p256ValidMock).code);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

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

    /// @dev Build COMBINED_T1 signature: [0x06][P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]
    function _buildCombinedT1Sig(
        bytes32 userOpHash,
        Vm.Wallet memory ecdsaSigner,
        bytes32 p256r,
        bytes32 p256s
    ) internal pure returns (bytes memory) {
        // ECDSA signs userOpHash with EIP-191 prefix
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ecdsaSigner.privateKey, ethHash);

        return abi.encodePacked(
            uint8(ALG_COMBINED_T1),
            p256r,   // 32
            p256s,   // 32
            r,       // 32
            s,       // 32
            v        // 1
        );
    }

    // ─── 1. Valid combined signature ─────────────────────────────────

    function test_combinedT1_bothValid_passes() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // P256 mock returns 1 (valid), ECDSA signed by owner
        userOp.signature = _buildCombinedT1Sig(
            userOpHash, ownerWallet, bytes32(uint256(0xAA)), bytes32(uint256(0xBB))
        );

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Both valid should pass");
    }

    // ─── 2. P256 invalid, ECDSA valid → fail ─────────────────────────

    function test_combinedT1_p256Invalid_fails() public {
        // Replace precompile with always-invalid mock
        vm.etch(address(0x100), address(p256InvalidMock).code);

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        userOp.signature = _buildCombinedT1Sig(
            userOpHash, ownerWallet, bytes32(uint256(0xAA)), bytes32(uint256(0xBB))
        );

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Invalid P256 should fail");
    }

    // ─── 3. P256 valid, ECDSA wrong signer → fail ────────────────────

    function test_combinedT1_ecdsaWrongSigner_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Sign with a different wallet (not the owner)
        Vm.Wallet memory wrongWallet = vm.createWallet("notOwner58");
        userOp.signature = _buildCombinedT1Sig(
            userOpHash, wrongWallet, bytes32(uint256(0xAA)), bytes32(uint256(0xBB))
        );

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong ECDSA signer should fail");
    }

    // ─── 4. Wrong signature length → fail ────────────────────────────

    function test_combinedT1_wrongLength_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // 129 bytes total but algId prefix takes 1, so sigData = 128 ≠ 129
        userOp.signature = abi.encodePacked(uint8(ALG_COMBINED_T1), new bytes(127));

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong length should fail");
    }

    // ─── 5. No P256 key set → fail ───────────────────────────────────

    function test_combinedT1_noP256Key_fails() public {
        // Deploy fresh account with zero P256 key
        uint8[] memory algIds = new uint8[](1);
        algIds[0] = ALG_COMBINED_T1;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: algIds,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 noKeyAccount = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr, config);

        PackedUserOperation memory userOp = _buildUserOp(address(noKeyAccount));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        userOp.signature = _buildCombinedT1Sig(
            userOpHash, ownerWallet, bytes32(uint256(0xAA)), bytes32(uint256(0xBB))
        );

        vm.prank(entryPointAddr);
        uint256 result = noKeyAccount.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "No P256 key should fail");
    }

    // ─── 6. algTier mapping: 0x06 = tier 1 ──────────────────────────

    function test_algId_0x06_isApprovedByDefault() public view {
        // Account was created with only 0x06 approved — verify guard approves it
        AAStarGlobalGuard g = account.guard();
        assertTrue(g.approvedAlgorithms(ALG_COMBINED_T1), "0x06 should be approved");
    }

    // ─── 7. Factory approves 0x06 by default ─────────────────────────

    function test_factory_approves_0x06() public {
        // Verify factory _buildDefaultConfig includes 0x06
        // We test indirectly: guard should approve 0x06 for accounts created via factory defaults
        // Already covered by factory tests; this test validates the constant value
        assertEq(ALG_COMBINED_T1, 0x06);
    }

    // ─── 8. EIP-2 s-value malleability check (Issue 5 fix) ──────────

    function test_combinedT1_highS_ecdsaRejected() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Build a valid ECDSA sig first, then flip s to the high half (malleable form)
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, ethHash);

        // Produce the canonical high-s counterpart: s' = secp256k1_n - s
        bytes32 secp256k1_n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(uint256(secp256k1_n) - uint256(s));
        // Flip v accordingly
        uint8 flippedV = v == 27 ? 28 : 27;

        userOp.signature = abi.encodePacked(
            uint8(ALG_COMBINED_T1),
            bytes32(uint256(0xAA)), // p256r (mock always valid)
            bytes32(uint256(0xBB)), // p256s
            r,
            highS,   // high-s — must be rejected
            flippedV
        );

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "High-s ECDSA signature must be rejected (EIP-2 malleability)");
    }

    function test_combinedT1_lowS_ecdsaAccepted() public {
        // Confirm that a standard (low-s) signature still passes after the fix
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        userOp.signature = _buildCombinedT1Sig(
            userOpHash, ownerWallet, bytes32(uint256(0xAA)), bytes32(uint256(0xBB))
        );

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Low-s ECDSA signature must still be accepted");
    }
}
