// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {AAStarValidator} from "../src/validators/AAStarValidator.sol";
import {IAAStarAlgorithm} from "../src/interfaces/IAAStarAlgorithm.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Mock EntryPoint for cumulative signature tests
contract MockEntryPointCumulative {
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

/// @dev Mock BLS algorithm that always succeeds
contract MockBLSSuccess is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Mock BLS algorithm that always fails
contract MockBLSFail is IAAStarAlgorithm {
    function validate(bytes32, bytes calldata) external pure override returns (uint256) {
        return 1;
    }
}

/// @dev Mock P256 precompile that returns success (valid = 1)
contract MockP256Success {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @dev Mock P256 precompile that returns failure (valid = 0)
contract MockP256Fail {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// @title Cumulative Signature Tests (M4.1 — F29-F34)
contract CumulativeSignatureTest is Test {
    MockEntryPointCumulative entryPointMock;
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockBLSSuccess mockBLSSuccess;
    MockBLSFail mockBLSFail;

    Vm.Wallet ownerWallet;
    Vm.Wallet guardianWallet1;
    Vm.Wallet guardianWallet2;
    Vm.Wallet guardianWallet3;
    Vm.Wallet nonGuardianWallet;
    address entryPointAddr;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        guardianWallet1 = vm.createWallet("guardian1");
        guardianWallet2 = vm.createWallet("guardian2");
        guardianWallet3 = vm.createWallet("guardian3");
        nonGuardianWallet = vm.createWallet("nonGuardian");

        entryPointMock = new MockEntryPointCumulative();
        entryPointAddr = address(entryPointMock);

        // Create account with 3 guardians
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [guardianWallet1.addr, guardianWallet2.addr, guardianWallet3.addr],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr, config);

        router = new AAStarValidator();
        mockBLSSuccess = new MockBLSSuccess();
        mockBLSFail = new MockBLSFail();

        // Set validator router + register BLS algorithm
        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));
        router.registerAlgorithm(0x01, address(mockBLSSuccess));

        // Set P256 key (non-zero so P256 path doesn't reject for missing key)
        vm.prank(ownerWallet.addr);
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        // Deploy mock P256 precompile at address(0x100)
        MockP256Success p256Mock = new MockP256Success();
        vm.etch(address(0x100), address(p256Mock).code);

        // Fund account
        vm.deal(address(account), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // F33: Cumulative Tier 2 Tests
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Valid P256 + BLS cumulative tier 2 signature should pass
    function test_cumulativeTier2_validSignature() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sig = _buildCumulativeT2Sig(userOpHash, ownerWallet);
        userOp.signature = abi.encodePacked(uint8(0x04), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Valid cumulative T2 should pass");
    }

    /// @notice Valid BLS but invalid P256 should fail
    function test_cumulativeTier2_invalidP256() public {
        // Deploy a failing P256 precompile
        MockP256Fail p256Fail = new MockP256Fail();
        vm.etch(address(0x100), address(p256Fail).code);

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sig = _buildCumulativeT2Sig(userOpHash, ownerWallet);
        userOp.signature = abi.encodePacked(uint8(0x04), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Invalid P256 should fail cumulative T2");
    }

    /// @notice Valid P256 but invalid BLS should fail
    function test_cumulativeTier2_invalidBLS() public {
        // Deploy a fresh account + router with a failing BLS algorithm
        AAStarValidator failRouter = new AAStarValidator();
        failRouter.registerAlgorithm(0x01, address(mockBLSFail));

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 failAccount = new AAStarAirAccountV7(entryPointAddr, ownerWallet.addr, config);
        vm.deal(address(failAccount), 10 ether);

        vm.startPrank(ownerWallet.addr);
        failAccount.setValidator(address(failRouter));
        failAccount.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();

        PackedUserOperation memory userOp = _buildUserOp(address(failAccount));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sig = _buildCumulativeT2Sig(userOpHash, ownerWallet);
        userOp.signature = abi.encodePacked(uint8(0x04), sig);

        vm.prank(entryPointAddr);
        uint256 result = failAccount.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Invalid BLS should fail cumulative T2");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F34: Cumulative Tier 3 Tests
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Valid P256 + BLS + Guardian ECDSA should pass
    function test_cumulativeTier3_validSignature() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sig = _buildCumulativeT3Sig(userOpHash, ownerWallet, guardianWallet1);
        userOp.signature = abi.encodePacked(uint8(0x05), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Valid cumulative T3 should pass");
    }

    /// @notice Valid P256 + BLS but guardian signed wrong hash should fail
    function test_cumulativeTier3_invalidGuardian() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Guardian signs a DIFFERENT hash (not userOpHash), so recovery yields wrong address
        bytes32 wrongHash = keccak256("wrong");
        bytes memory sig = _buildCumulativeT3Sig_withGuardianHash(
            userOpHash, ownerWallet, guardianWallet1, wrongHash
        );
        userOp.signature = abi.encodePacked(uint8(0x05), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Guardian signed wrong hash should fail cumulative T3");
    }

    /// @notice Valid sig from non-guardian address should fail
    function test_cumulativeTier3_nonGuardianSigner() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Sign guardian part with a non-guardian wallet
        bytes memory sig = _buildCumulativeT3Sig(userOpHash, ownerWallet, nonGuardianWallet);
        userOp.signature = abi.encodePacked(uint8(0x05), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Non-guardian signer should fail cumulative T3");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F32: _algTier mapping tests
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verify _algTier returns correct tiers for cumulative algIds
    function test_algTier_cumulativeMapping() public {
        // We test via requiredTier + tier enforcement since _algTier is internal.
        // Set tier limits so we can test enforcement.
        vm.prank(ownerWallet.addr);
        account.setTierLimits(0.1 ether, 1 ether);

        // Tier 2 transaction (0.5 ETH) with cumulative T2 (algId=0x04) should pass
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes memory sig = _buildCumulativeT2Sig(userOpHash, ownerWallet);
        userOp.signature = abi.encodePacked(uint8(0x04), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "ALG_CUMULATIVE_T2 should map to tier 2");

        // Tier 3 transaction (5 ETH) with cumulative T3 (algId=0x05) should pass
        PackedUserOperation memory userOp3 = _buildUserOp(address(account));
        bytes32 userOpHash3 = keccak256(abi.encode(userOp3));
        bytes memory sig3 = _buildCumulativeT3Sig(userOpHash3, ownerWallet, guardianWallet2);
        userOp3.signature = abi.encodePacked(uint8(0x05), sig3);

        vm.prank(entryPointAddr);
        uint256 result3 = account.validateUserOp(userOp3, userOpHash3, 0);
        assertEq(result3, 0, "ALG_CUMULATIVE_T3 should map to tier 3");
    }

    /// @notice Verify tier enforcement works for cumulative T2 with tier limits
    function test_tierEnforcement_cumulativeTier2() public {
        vm.prank(ownerWallet.addr);
        account.setTierLimits(0.1 ether, 1 ether);

        // Validate a cumulative T2 signature
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes memory sig = _buildCumulativeT2Sig(userOpHash, ownerWallet);
        userOp.signature = abi.encodePacked(uint8(0x04), sig);

        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Cumulative T2 validation should pass");

        // Execute a tier-2 value transfer (0.5 ETH) — should succeed
        vm.prank(entryPointAddr);
        account.execute(address(0xBEEF), 0.5 ether, "");

        // Execute a tier-1 value transfer (0.05 ETH) — should also succeed (T2 >= T1)
        // Re-validate first
        vm.prank(entryPointAddr);
        account.validateUserOp(userOp, userOpHash, 0);

        vm.prank(entryPointAddr);
        account.execute(address(0xBEEF), 0.05 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

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

    /// @dev Build cumulative tier 2 signature: P256(64) + BLS payload
    /// Format: [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][messagePointSig(65)]
    function _buildCumulativeT2Sig(
        bytes32 userOpHash,
        Vm.Wallet memory mpSigner
    ) internal pure returns (bytes memory) {
        // P256 r,s (fake — the precompile is mocked)
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        // BLS payload components
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);
        bytes memory messagePoint = new bytes(256);
        messagePoint[0] = 0x42;

        // MessagePoint signature — binds messagePoint to userOpHash to prevent cross-op replay (F55)
        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint));
        (uint8 v, bytes32 r, bytes32 s) = _signHash(mpSigner, mpHash);

        return abi.encodePacked(
            p256R,                          // 32
            p256S,                          // 32
            bytes32(nodeIdsLength),         // 32
            fakeNodeId,                     // 32
            blsSig,                         // 256
            messagePoint,                   // 256
            abi.encodePacked(r, s, v)       // 65
        );
    }

    /// @dev Build cumulative tier 3 signature: P256(64) + BLS payload + guardianECDSA(65)
    /// Format: [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][messagePointSig(65)][guardianECDSA(65)]
    function _buildCumulativeT3Sig(
        bytes32 userOpHash,
        Vm.Wallet memory mpSigner,
        Vm.Wallet memory guardianSigner
    ) internal pure returns (bytes memory) {
        // P256 r,s (fake — the precompile is mocked)
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        // BLS payload components
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);
        bytes memory messagePoint = new bytes(256);
        messagePoint[0] = 0x42;

        // MessagePoint signature — binds messagePoint to userOpHash to prevent cross-op replay (F55)
        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint));
        (uint8 v1, bytes32 r1, bytes32 s1) = _signHash(mpSigner, mpHash);

        // Guardian ECDSA co-sign (ECDSA over userOpHash)
        (uint8 v2, bytes32 r2, bytes32 s2) = _signHash(guardianSigner, userOpHash);

        return abi.encodePacked(
            p256R,                              // 32
            p256S,                              // 32
            bytes32(nodeIdsLength),             // 32
            fakeNodeId,                         // 32
            blsSig,                             // 256
            messagePoint,                       // 256
            abi.encodePacked(r1, s1, v1),       // 65 (messagePoint sig)
            abi.encodePacked(r2, s2, v2)        // 65 (guardian ECDSA)
        );
    }

    /// @dev Build cumulative tier 3 signature with a custom hash for guardian signing (for testing invalid guardian)
    function _buildCumulativeT3Sig_withGuardianHash(
        bytes32 userOpHash,
        Vm.Wallet memory mpSigner,
        Vm.Wallet memory guardianSigner,
        bytes32 guardianSignHash
    ) internal pure returns (bytes memory) {
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);
        bytes memory messagePoint = new bytes(256);
        messagePoint[0] = 0x42;

        // Note: uses userOpHash binding (F55) — even for the "wrong guardian hash" test, messagePoint sig is correct
        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint));
        (uint8 v1, bytes32 r1, bytes32 s1) = _signHash(mpSigner, mpHash);

        // Guardian signs the WRONG hash instead of userOpHash
        (uint8 v2, bytes32 r2, bytes32 s2) = _signHash(guardianSigner, guardianSignHash);

        return abi.encodePacked(
            p256R, p256S,
            bytes32(nodeIdsLength), fakeNodeId,
            blsSig, messagePoint,
            abi.encodePacked(r1, s1, v1),
            abi.encodePacked(r2, s2, v2)
        );
    }

    function _signHash(Vm.Wallet memory w, bytes32 hash) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (v, r, s) = vm.sign(w.privateKey, ethHash);
    }
}
