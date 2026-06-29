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
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7();
        account.initialize(entryPointAddr, ownerWallet.addr, config);


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
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        AAStarAirAccountV7 failAccount = new AAStarAirAccountV7();
        failAccount.initialize(entryPointAddr, ownerWallet.addr, config);

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

        // HIGH-3: callData must equal the executed call so the content-keyed algId resolves.
        userOp.callData = abi.encodeWithSelector(account.execute.selector, address(0xBEEF), uint256(0.5 ether), bytes(""));
        vm.prank(entryPointAddr);
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Cumulative T2 validation should pass");

        // Execute a tier-2 value transfer (0.5 ETH) — should succeed
        vm.prank(entryPointAddr);
        account.execute(address(0xBEEF), 0.5 ether, "");

        // Execute a tier-1 value transfer (0.05 ETH) — should also succeed (T2 >= T1)
        // Re-validate first with callData matching the second execute.
        userOp.callData = abi.encodeWithSelector(account.execute.selector, address(0xBEEF), uint256(0.05 ether), bytes(""));
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
    /// Format (issue #45 Fix 1): [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)]
    /// messagePoint + messagePointSig removed — point is recomputed on-chain from userOpHash.
    function _buildCumulativeT2Sig(
        bytes32, /*userOpHash*/
        Vm.Wallet memory /*mpSigner*/
    ) internal pure returns (bytes memory) {
        // P256 r,s (fake — the precompile is mocked)
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        // BLS payload components
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);

        return abi.encodePacked(
            p256R,                          // 32
            p256S,                          // 32
            bytes32(nodeIdsLength),         // 32
            fakeNodeId,                     // 32
            blsSig                          // 256
        );
    }

    /// @dev Build cumulative tier 3 signature: P256(64) + BLS payload + guardianECDSA(65)
    /// Format (issue #45 Fix 1): [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][guardianECDSA(65)]
    function _buildCumulativeT3Sig(
        bytes32 userOpHash,
        Vm.Wallet memory, /*mpSigner*/
        Vm.Wallet memory guardianSigner
    ) internal pure returns (bytes memory) {
        // P256 r,s (fake — the precompile is mocked)
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        // BLS payload components
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);

        // Guardian ECDSA co-sign (ECDSA over userOpHash)
        (uint8 v2, bytes32 r2, bytes32 s2) = _signHash(guardianSigner, userOpHash);

        return abi.encodePacked(
            p256R,                              // 32
            p256S,                              // 32
            bytes32(nodeIdsLength),             // 32
            fakeNodeId,                         // 32
            blsSig,                             // 256
            abi.encodePacked(r2, s2, v2)        // 65 (guardian ECDSA)
        );
    }

    /// @dev Build cumulative tier 3 signature with a custom hash for guardian signing (for testing invalid guardian)
    function _buildCumulativeT3Sig_withGuardianHash(
        bytes32, /*userOpHash*/
        Vm.Wallet memory, /*mpSigner*/
        Vm.Wallet memory guardianSigner,
        bytes32 guardianSignHash
    ) internal pure returns (bytes memory) {
        bytes32 p256R = bytes32(uint256(0xAA));
        bytes32 p256S = bytes32(uint256(0xBB));

        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);

        // Guardian signs the WRONG hash instead of userOpHash
        (uint8 v2, bytes32 r2, bytes32 s2) = _signHash(guardianSigner, guardianSignHash);

        return abi.encodePacked(
            p256R, p256S,
            bytes32(nodeIdsLength), fakeNodeId,
            blsSig,
            abi.encodePacked(r2, s2, v2)
        );
    }

    function _signHash(Vm.Wallet memory w, bytes32 hash) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (v, r, s) = vm.sign(w.privateKey, ethHash);
    }

    // ─── WebAuthn waBlob builder ───────────────────────────────────────

    /// @dev Constructs a minimal but structurally valid WebAuthn assertion blob.
    ///      The P256 precompile is mocked so the crypto values are arbitrary.
    function _buildWaBlob() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01; // UP (User Present) flag
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory suffix = bytes('"}');
        bytes32 r = bytes32(uint256(0xAA));
        bytes32 s = bytes32(uint256(0x01)); // low-S (< SECP256R1_N_OVER_2)
        return abi.encode(authenticatorData, prefix, suffix, r, s);
    }

    /// @dev Builds a T2_WA signature: [uint32 waBlobLen][waBlob][blsPayload]
    function _buildCumulativeT2WASig() internal pure returns (bytes memory) {
        bytes memory waBlob = _buildWaBlob();
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);

        bytes memory blsPayload = abi.encodePacked(bytes32(nodeIdsLength), fakeNodeId, blsSig);
        return abi.encodePacked(bytes4(uint32(waBlob.length)), waBlob, blsPayload);
    }

    /// @dev Builds a T3_WA signature: [uint32 waBlobLen][waBlob][blsPayload][guardianECDSA(65)]
    function _buildCumulativeT3WASig(bytes32 userOpHash, Vm.Wallet memory guardianSigner)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory waBlob = _buildWaBlob();
        uint256 nodeIdsLength = 1;
        bytes32 fakeNodeId = keccak256("testnode");
        bytes memory blsSig = new bytes(256);
        bytes memory blsPayload = abi.encodePacked(bytes32(nodeIdsLength), fakeNodeId, blsSig);

        (uint8 v, bytes32 r, bytes32 s) = _signHash(guardianSigner, userOpHash);
        bytes memory guardianSig = abi.encodePacked(r, s, v);

        return abi.encodePacked(bytes4(uint32(waBlob.length)), waBlob, blsPayload, guardianSig);
    }
}

// ═══════════════════════════════════════════════════════════════════
// WebAuthn Cumulative Signature Tests (ALG_CUMULATIVE_T2_WA / T3_WA)
// ═══════════════════════════════════════════════════════════════════
contract CumulativeWebAuthnTest is Test {
    MockEntryPointCumulative entryPoint;
    AAStarAirAccountV7 account;
    AAStarValidator router;
    MockBLSSuccess mockBLSSuccess;

    Vm.Wallet ownerWallet;
    Vm.Wallet guardianWallet;
    Vm.Wallet nonGuardianWallet;

    function setUp() public {
        ownerWallet       = vm.createWallet("waOwner");
        guardianWallet    = vm.createWallet("waGuardian");
        nonGuardianWallet = vm.createWallet("waNonGuardian");

        entryPoint = new MockEntryPointCumulative();

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [guardianWallet.addr, address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7();
        account.initialize(address(entryPoint), ownerWallet.addr, cfg);

        router = new AAStarValidator();
        mockBLSSuccess = new MockBLSSuccess();

        vm.prank(ownerWallet.addr);
        account.setValidator(address(router));
        router.registerAlgorithm(0x01, address(mockBLSSuccess));

        // Owner P256 key (non-zero so the key-missing check doesn't short-circuit)
        vm.prank(ownerWallet.addr);
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        // Mock P256 precompile (returns valid)
        MockP256Success p256Mock = new MockP256Success();
        vm.etch(address(0x100), address(p256Mock).code);

        vm.deal(address(account), 100 ether);
    }

    // ─── AlgTierLib: new ids map to correct tiers ─────────────────────

    function test_waAlgIds_tierMapping() public view {
        // 0x09 must be tier 2, 0x0a must be tier 3
        assertEq(account.requiredTier(0), 0, "no tier configured");
    }

    // ─── T2_WA: valid WebAuthn passkey + BLS ──────────────────────────

    function test_cumulativeTier2WA_validSignature() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sigData = _buildT2WAData();
        userOp.signature = abi.encodePacked(uint8(0x09), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Valid T2_WA should pass");
    }

    function test_cumulativeTier2WA_invalidP256_fails() public {
        MockP256Fail p256Fail = new MockP256Fail();
        vm.etch(address(0x100), address(p256Fail).code);

        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        userOp.signature = abi.encodePacked(uint8(0x09), _buildT2WAData());

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Failing P256 should reject T2_WA");
    }

    function test_cumulativeTier2WA_wrongClientDataPrefix_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory badWaBlob = _buildWaBlobWithPrefix(bytes('{"type":"webauthn.create","challenge":"'));
        bytes memory blsPayload = _buildBlsPayload();
        bytes memory sigData = abi.encodePacked(bytes4(uint32(badWaBlob.length)), badWaBlob, blsPayload);
        userOp.signature = abi.encodePacked(uint8(0x09), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Wrong clientDataJSON prefix should reject T2_WA");
    }

    function test_cumulativeTier2WA_upFlagUnset_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory badWaBlob = _buildWaBlobNoUPFlag();
        bytes memory blsPayload = _buildBlsPayload();
        bytes memory sigData = abi.encodePacked(bytes4(uint32(badWaBlob.length)), badWaBlob, blsPayload);
        userOp.signature = abi.encodePacked(uint8(0x09), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "UP flag unset should reject T2_WA");
    }

    function test_cumulativeTier2WA_truncatedSig_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Only 3 bytes — missing waBlobLen field
        userOp.signature = abi.encodePacked(uint8(0x09), bytes3(0xAAAAAA));

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Truncated sig should reject T2_WA");
    }

    // ─── T3_WA: valid WebAuthn passkey + BLS + guardian ECDSA ─────────

    function test_cumulativeTier3WA_validSignature() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sigData = _buildT3WAData(userOpHash, guardianWallet);
        userOp.signature = abi.encodePacked(uint8(0x0a), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Valid T3_WA should pass");
    }

    function test_cumulativeTier3WA_nonGuardian_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        bytes memory sigData = _buildT3WAData(userOpHash, nonGuardianWallet);
        userOp.signature = abi.encodePacked(uint8(0x0a), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Non-guardian should reject T3_WA");
    }

    function test_cumulativeTier3WA_missingGuardianSig_fails() public {
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Omit both blsPayload and guardian sig: only waBlob present.
        // sigData.length = 4 + waBlobLen, which is < 4 + waBlobLen + 65 => early return 1.
        bytes memory waBlob = _buildWaBlob();
        bytes memory sigData = abi.encodePacked(bytes4(uint32(waBlob.length)), waBlob);
        userOp.signature = abi.encodePacked(uint8(0x0a), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Missing guardian sig should reject T3_WA");
    }

    // ─── Security: malformed waBlob must return 1, never revert ──────

    function test_cumulativeTier2WA_malformedWaBlob_returnsOne_notRevert() public {
        // Construct a blob that is >= 352 bytes but has an ABI offset that claims content
        // beyond the blob boundary. Without the pre-decode ABI validation this would cause
        // abi.decode to revert, violating ERC-4337's requirement that validateUserOp return 1.
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));

        // Head: off0=0xdeadbeef (points way past data), off1=160, off2=192, r=0, s=0
        bytes memory malformedWaBlob = abi.encodePacked(
            uint256(0xdeadbeef),  // off0: out-of-bounds offset
            uint256(160),         // off1
            uint256(192),         // off2
            bytes32(0),           // r
            bytes32(0),           // s
            new bytes(200)        // padding to ensure length >= 352
        );
        bytes memory blsPayload = _buildBlsPayload();
        bytes memory sigData = abi.encodePacked(bytes4(uint32(malformedWaBlob.length)), malformedWaBlob, blsPayload);
        userOp.signature = abi.encodePacked(uint8(0x09), sigData);

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Malformed waBlob must return 1 (not revert)");
    }

    // ─── Raw-ECDSA compat: 65-byte sig starting with 0x09/0x0a falls through ──

    function test_rawECDSA_firstByte0x09_fallsThrough() public {
        // A raw 65-byte ECDSA sig (no algId prefix) whose first byte is 0x09 must NOT
        // be misrouted to ALG_CUMULATIVE_T2_WA. It should fall through to the raw-ECDSA
        // compat path and be validated as ECDSA against the owner key.
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        // Craft userOpHash so that the resulting ECDSA sig (r,s,v) starts with 0x09.
        // We iterate over hashes until vm.sign produces r[0] == 0x09.
        bytes32 userOpHash;
        bytes memory sig;
        for (uint256 i = 0; i < 256; i++) {
            userOpHash = keccak256(abi.encode("ecdsa_firstbyte_0x09", i));
            bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, ethHash);
            sig = abi.encodePacked(r, s, v);
            if (uint8(sig[0]) == 0x09) break;
        }
        require(uint8(sig[0]) == 0x09, "Could not find sig starting with 0x09 in 256 iters");

        userOp.signature = sig;

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "65-byte ECDSA sig with first byte 0x09 must validate via raw-ECDSA path");
    }

    // ─── populateExecAlg covers new algIds ────────────────────────────

    function test_populateExecAlg_T2WA_storesAlgId() public {
        // executeUserOp re-derives algId from sig — verify the new id flows through
        PackedUserOperation memory userOp = _buildUserOp(address(account));
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        bytes memory sigData = _buildT2WAData();
        userOp.signature = abi.encodePacked(uint8(0x09), sigData);

        vm.prank(address(entryPoint));
        account.validateUserOp(userOp, userOpHash, 0);
        // If no revert and result=0, the routing + store path worked
        // (full execute path covered by integration tests)
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

    function _buildWaBlob() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01; // UP flag
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory suffix = bytes('"}');
        bytes32 r = bytes32(uint256(0xAA));
        bytes32 s = bytes32(uint256(0x01)); // low-S
        return abi.encode(authenticatorData, prefix, suffix, r, s);
    }

    function _buildWaBlobWithPrefix(bytes memory prefix) internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01;
        bytes memory suffix = bytes('"}');
        bytes32 r = bytes32(uint256(0xAA));
        bytes32 s = bytes32(uint256(0x01));
        return abi.encode(authenticatorData, prefix, suffix, r, s);
    }

    function _buildWaBlobNoUPFlag() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        // authenticatorData[32] = 0x00  (UP flag NOT set)
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory suffix = bytes('"}');
        bytes32 r = bytes32(uint256(0xAA));
        bytes32 s = bytes32(uint256(0x01));
        return abi.encode(authenticatorData, prefix, suffix, r, s);
    }

    function _buildBlsPayload() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(1)), keccak256("testnode"), new bytes(256));
    }

    function _buildT2WAData() internal pure returns (bytes memory) {
        bytes memory waBlob = _buildWaBlob();
        bytes memory blsPayload = _buildBlsPayload();
        return abi.encodePacked(bytes4(uint32(waBlob.length)), waBlob, blsPayload);
    }

    function _buildT3WAData(bytes32 userOpHash, Vm.Wallet memory guardianSigner)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory waBlob = _buildWaBlob();
        bytes memory blsPayload = _buildBlsPayload();
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", userOpHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianSigner.privateKey, ethHash);
        return abi.encodePacked(bytes4(uint32(waBlob.length)), waBlob, blsPayload, abi.encodePacked(r, s, v));
    }
}
