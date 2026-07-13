// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

// ─── P-256 precompile mocks ───────────────────────────────────────────────────

interface IAirAccountRecovery { function proposeRecovery(address newOwner) external; function approveRecovery() external; function executeRecovery() external; function cancelRecovery() external; }

contract MockP256Valid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

contract MockP256Invalid {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

// ─── Main test contract ───────────────────────────────────────────────────────

/// @title P256Guardian Tests
/// @notice Tests for P-256 (passkey/WebAuthn) guardian support (issue #119)
contract P256GuardianTest is Test {
    using MessageHashUtils for bytes32;

    AAStarAirAccountV7 account;

    address entryPoint  = makeAddr("entryPoint");
    address owner       = makeAddr("owner");
    address newOwner    = makeAddr("newOwner");

    bytes32 constant P256_X0 = bytes32(uint256(0xAAAA0001));
    bytes32 constant P256_Y0 = bytes32(uint256(0xBBBB0001));
    bytes32 constant P256_X1 = bytes32(uint256(0xAAAA0002));
    bytes32 constant P256_Y1 = bytes32(uint256(0xBBBB0002));
    bytes32 constant P256_X2 = bytes32(uint256(0xAAAA0003));
    bytes32 constant P256_Y2 = bytes32(uint256(0xBBBB0003));
    bytes32 constant P256_X3 = bytes32(uint256(0xAAAA0004));
    bytes32 constant P256_Y3 = bytes32(uint256(0xBBBB0004));

    address constant P256_PRECOMPILE = address(0x100);
    address constant P256_SENTINEL   = address(0x7026);
    uint8   constant GUARDIAN_SIG_VER   = 4;
    uint256 constant RECOVERY_THRESHOLD = 2;

    uint256 ecdsaGuardianKey = uint256(keccak256("ecdsaGuardian"));
    address ecdsaGuardian    = vm.addr(ecdsaGuardianKey);

    bytes32 constant VALID_R = bytes32(uint256(0x1234));
    bytes32 constant VALID_S = bytes32(uint256(0x5678)); // well below SECP256R1_N_OVER_2

    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event P256GuardianAdded(uint8 indexed index, bytes32 x, bytes32 y);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy, uint8 guardianIdx);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount, uint8 guardianIdx);
    event RecoveryCancelVoted(address indexed votedBy, uint256 cancelCount, uint8 guardianIdx);
    event RecoveryCancelled();

    // ── Deploy helpers ─────────────────────────────────────────────────────────

    function _deploy(address g0, address g1, address g2) internal {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [g0, g1, g2],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, cfg, address(0), bytes32(0), bytes32(0));
    }

    function _deployWithP256Init(bytes32 x0, bytes32 y0, bytes32 x1, bytes32 y1) internal {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [x0, x1, bytes32(0)],
            guardianP256Y: [y0, y1, bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, cfg, address(0), bytes32(0), bytes32(0));
    }

    function _deployWithThreeP256Init() internal {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [P256_X0, P256_X1, P256_X2],
            guardianP256Y: [P256_Y0, P256_Y1, P256_Y2],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, cfg, address(0), bytes32(0), bytes32(0));
    }

    // #120 final review [Medium] regression: the P-256 sentinel (0x7026) must be rejected as a
    // plain ECDSA guardian at init. Otherwise the slot is marked P-256 with key (0,0) — a guardian
    // that can neither ECDSA-sign nor produce a valid P-256 assertion, permanently breaking recovery
    // on this non-upgradable account.
    function test_init_rejectsSentinelAsEcdsaGuardian() public {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountV7 a = new AAStarAirAccountV7(address(0));
        vm.expectRevert(abi.encodeWithSignature("InvalidGuardian()"));
        a.initialize(entryPoint, owner, AAStarAirAccountBase.InitConfig({
            guardians: [address(0x7026), address(0), address(0)],
            guardianP256X: [bytes32(0), bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        }), address(0), bytes32(0), bytes32(0));
    }

    // Deploy with 1 ECDSA + 1 P-256 guardian (mixed init)
    function _deployMixed(address ecdsa, bytes32 x1, bytes32 y1) internal {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [ecdsa, address(0), address(0)],
            guardianP256X: [bytes32(0), x1, bytes32(0)],
            guardianP256Y: [bytes32(0), y1, bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, cfg, address(0), bytes32(0), bytes32(0));
    }

    function _deployEmpty() internal {
        _deploy(address(0), address(0), address(0));
    }

    // ── Sig helpers ────────────────────────────────────────────────────────────

    /// @dev Build a mock WebAuthn-formatted P-256 sig.
    ///      Format: abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
    ///      authenticatorData: 37 bytes, byte 32 = 0x01 (UP flag), rest zero.
    ///      The precompile is mocked so content beyond the format doesn't matter.
    function _mockP256Sig() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01; // UP (User Present) flag
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory suffix = bytes('","origin":"https://airaccount.test","crossOrigin":false}');
        return abi.encode(authenticatorData, prefix, suffix, VALID_R, VALID_S);
    }

    function _ecdsaOpHash(string memory opLabel, bytes memory opData) internal view returns (bytes32) {
        return keccak256(abi.encode(
            GUARDIAN_SIG_VER, block.chainid, address(account), opLabel, opData
        )).toEthSignedMessageHash();
    }

    function _signEcdsa(uint256 privKey, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, hash);
        return abi.encodePacked(r, s, v);
    }

    // ── addP256Guardian (bootstrap — 0 guardians only) ─────────────────────────

    function test_addP256Guardian_bootstrap_setsSlot() public {
        _deployEmpty();
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit P256GuardianAdded(0, P256_X0, P256_Y0);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256Guardian(bytes32,bytes32)", P256_X0, P256_Y0
        ));
        assertTrue(ok);
        (bool ok2, bytes memory data) = address(account).call(abi.encodeWithSignature(
            "getGuardianP256Key(uint8)", uint8(0)
        ));
        assertTrue(ok2);
        (bytes32 x, bytes32 y) = abi.decode(data, (bytes32, bytes32));
        assertEq(x, P256_X0);
        assertEq(y, P256_Y0);
    }

    function test_addP256Guardian_bootstrap_countIncrements() public {
        _deployEmpty();
        vm.prank(owner);
        address(account).call(abi.encodeWithSignature("addP256Guardian(bytes32,bytes32)", P256_X0, P256_Y0));
        assertEq(account.guardianCount(), 1);
    }

    function test_addP256Guardian_requiresConsensus_atThreshold() public {
        // Owner may add directly until _guardianCount >= RECOVERY_THRESHOLD (=2).
        // count=1 is still below threshold — 1 guardian cannot form the required quorum.
        _deployEmpty();
        vm.startPrank(owner);
        address(account).call(abi.encodeWithSignature("addP256Guardian(bytes32,bytes32)", P256_X0, P256_Y0)); // 0→1
        address(account).call(abi.encodeWithSignature("addP256Guardian(bytes32,bytes32)", P256_X1, P256_Y1)); // 1→2
        // count=2 == RECOVERY_THRESHOLD → third direct add must fail (UseGuardianConsensus)
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256Guardian(bytes32,bytes32)", P256_X2, P256_Y2
        ));
        vm.stopPrank();
        assertFalse(ok);
        assertEq(account.guardianCount(), 2);
    }

    function test_addP256Guardian_zeroKey_reverts() public {
        _deployEmpty();
        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256Guardian(bytes32,bytes32)", bytes32(0), P256_Y0
        ));
        assertFalse(ok);
    }

    function test_addGuardian_sentinelAddress_reverts() public {
        _deployEmpty();
        vm.prank(owner);
        vm.expectRevert();
        account.addGuardian(P256_SENTINEL);
    }

    function test_addGuardian_withExistingGuardian_reverts() public {
        // UseGuardianConsensus is triggered at count >= RECOVERY_THRESHOLD (=2).
        // count=1 allows direct add; need count=2 to enforce consensus.
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1); // count=2
        vm.prank(owner);
        vm.expectRevert(); // UseGuardianConsensus
        account.addGuardian(makeAddr("newG"));
    }

    // ── addP256GuardianWithMixedSigs (post-init, requires consensus) ───────────

    function test_addP256GuardianWithMixedSigs_twoP256Signers() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit P256GuardianAdded(2, P256_X2, P256_Y2);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256GuardianWithMixedSigs(bytes32,bytes32,uint8[],bytes[])",
            P256_X2, P256_Y2, signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.guardianCount(), 3);
    }

    function test_addP256GuardianWithMixedSigs_maxSlotReached_reverts() public {
        _deployWithThreeP256Init();
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256GuardianWithMixedSigs(bytes32,bytes32,uint8[],bytes[])",
            P256_X3, P256_Y3, signerIdxs, sigs
        ));
        assertFalse(ok); // MaxGuardiansReached
    }

    function test_addP256GuardianWithMixedSigs_insufficientSigs_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint8[] memory signerIdxs = new uint8[](1);
        signerIdxs[0] = 0;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256GuardianWithMixedSigs(bytes32,bytes32,uint8[],bytes[])",
            P256_X2, P256_Y2, signerIdxs, sigs
        ));
        assertFalse(ok); // InsufficientGuardianApprovals
    }

    function test_addP256GuardianWithMixedSigs_invalidPrecompile_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Invalid()).code);

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addP256GuardianWithMixedSigs(bytes32,bytes32,uint8[],bytes[])",
            P256_X2, P256_Y2, signerIdxs, sigs
        ));
        assertFalse(ok); // InvalidP256GuardianSignature
    }

    // ── addGuardianWithMixedSigs (ECDSA guardian via consensus) ───────────────

    function test_addGuardianWithMixedSigs_ecdsaConsensus() public {
        uint256 g1Key = uint256(keccak256("g1_consensus"));
        uint256 g2Key = uint256(keccak256("g2_consensus"));
        address g1 = vm.addr(g1Key);
        address g2 = vm.addr(g2Key);
        address g3 = makeAddr("g3_new");
        _deploy(g1, g2, address(0)); // 2 ECDSA guardians

        bytes memory opData = abi.encode(uint256(0), g3); // _guardianAdditionNonce=0
        bytes32 ethHash = keccak256(abi.encode(
            GUARDIAN_SIG_VER, block.chainid, address(account), "ADD_GUARDIAN", opData
        )).toEthSignedMessageHash();

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signEcdsa(g1Key, ethHash);
        sigs[1] = _signEcdsa(g2Key, ethHash);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit GuardianAdded(2, g3);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "addGuardianWithMixedSigs(address,uint8[],bytes[])", g3, signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.guardianCount(), 3);
    }

    // ── Init-time P-256 guardian ───────────────────────────────────────────────

    function test_init_with_two_p256_guardians() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        assertEq(account.guardianCount(), 2);
        (bool ok0, bytes memory d0) = address(account).call(abi.encodeWithSignature("getGuardianP256Key(uint8)", uint8(0)));
        (bool ok1, bytes memory d1) = address(account).call(abi.encodeWithSignature("getGuardianP256Key(uint8)", uint8(1)));
        assertTrue(ok0 && ok1);
        (bytes32 x0,) = abi.decode(d0, (bytes32, bytes32));
        (bytes32 x1,) = abi.decode(d1, (bytes32, bytes32));
        assertEq(x0, P256_X0);
        assertEq(x1, P256_X1);
    }

    function test_init_p256_missingY_reverts() public {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [P256_X0, bytes32(0), bytes32(0)],
            guardianP256Y: [bytes32(0), bytes32(0), bytes32(0)], // y==0 with non-zero x
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        });
        account = new AAStarAirAccountV7(address(0));
        vm.expectRevert();
        account.initialize(entryPoint, owner, cfg, address(0), bytes32(0), bytes32(0));
    }

    // ── proposeRecoveryWithSig ─────────────────────────────────────────────────

    function test_proposeRecoveryWithSig_p256Guardian() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        vm.expectEmit(true, true, false, false);
        emit RecoveryProposed(newOwner, address(this), 0);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        assertTrue(ok);
        (address proposedOwner,,,) = account.activeRecovery();
        assertEq(proposedOwner, newOwner);
    }

    /// #120 R1 [Medium]: a non-standard clientDataJSON type (here webauthn.create instead of
    /// webauthn.get) must be rejected by the type-prefix binding even when the precompile would
    /// otherwise accept the signature — guards against type confusion / arbitrary-JSON prefixes.
    function test_proposeRecoveryWithSig_rejectsNonGetType() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01; // UP flag set
        bytes memory badPrefix = bytes('{"type":"webauthn.create","challenge":"'); // wrong type
        bytes memory suffix = bytes('","origin":"https://airaccount.test","crossOrigin":false}');
        bytes memory badSig = abi.encode(authenticatorData, badPrefix, suffix, VALID_R, VALID_S);

        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), badSig
        ));
        assertFalse(ok, "non-webauthn.get assertion must be rejected");
        (address proposedOwner,,,) = account.activeRecovery();
        assertEq(proposedOwner, address(0), "no proposal should have been created");
    }

    function test_proposeRecoveryWithSig_invalidPrecompile_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Invalid()).code);

        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        assertFalse(ok);
    }

    function test_proposeRecoveryWithSig_ecdsaSlot_reverts() public {
        _deploy(ecdsaGuardian, address(0), address(0));
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        assertFalse(ok); // InvalidGuardian (slot is ECDSA, not P-256)
    }

    function test_proposeRecoveryWithSig_shortAuthData_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        bytes memory shortAuth = new bytes(10); // < 37
        bytes memory sig = abi.encode(shortAuth, bytes("pre"), bytes("suf"), VALID_R, VALID_S);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), sig
        ));
        assertFalse(ok); // InvalidAuthenticatorData
    }

    function test_proposeRecoveryWithSig_missingUPFlag_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        bytes memory authData = new bytes(37); // all zeros — UP flag not set
        bytes memory sig = abi.encode(authData, bytes("pre"), bytes("suf"), VALID_R, VALID_S);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), sig
        ));
        assertFalse(ok); // InvalidAuthenticatorData
    }

    // ── approveRecoveryWithSig ─────────────────────────────────────────────────

    function test_approveRecoveryWithSig_second_guardian_crosses_threshold() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));

        vm.expectEmit(true, true, false, true);
        emit RecoveryApproved(newOwner, address(this), 2, 1);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "approveRecoveryWithSig(uint8,bytes)", uint8(1), _mockP256Sig()
        ));
        assertTrue(ok);

        (,, uint256 bitmap,) = account.activeRecovery();
        assertEq(_popcount(bitmap), 2);
    }

    function test_approveRecoveryWithSig_alreadyApproved_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "approveRecoveryWithSig(uint8,bytes)", uint8(0), _mockP256Sig()
        ));
        assertFalse(ok); // AlreadyApproved
    }

    // ── cancelRecoveryWithSig ──────────────────────────────────────────────────

    function test_cancelRecoveryWithSig_twoVotesCancelRecovery() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        address(account).call(abi.encodeWithSignature(
            "cancelRecoveryWithSig(uint8,bytes)", uint8(0), _mockP256Sig()
        ));
        vm.expectEmit(false, false, false, false);
        emit RecoveryCancelled();
        address(account).call(abi.encodeWithSignature(
            "cancelRecoveryWithSig(uint8,bytes)", uint8(1), _mockP256Sig()
        ));

        (address proposedOwner,,,) = account.activeRecovery();
        assertEq(proposedOwner, address(0));
    }

    function test_cancelRecoveryWithSig_incrementsNonce() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        address(account).call(abi.encodeWithSignature(
            "proposeRecoveryWithSig(address,uint8,bytes)", newOwner, uint8(0), _mockP256Sig()
        ));
        address(account).call(abi.encodeWithSignature(
            "cancelRecoveryWithSig(uint8,bytes)", uint8(0), _mockP256Sig()
        ));
        address(account).call(abi.encodeWithSignature(
            "cancelRecoveryWithSig(uint8,bytes)", uint8(1), _mockP256Sig()
        ));
        assertEq(account.getRecoveryNonce(), 1);
    }

    // ── executeRecovery nonce increment ───────────────────────────────────────

    function test_executeRecovery_incrementsNonce() public {
        uint256 g2Key = uint256(keccak256("g2_exec_nonce_test"));
        address g2addr = vm.addr(g2Key);
        _deploy(ecdsaGuardian, g2addr, address(0));

        vm.prank(ecdsaGuardian);
        IAirAccountRecovery(address(account)).proposeRecovery(newOwner);
        vm.prank(g2addr);
        IAirAccountRecovery(address(account)).approveRecovery();

        vm.warp(block.timestamp + 3 days);
        IAirAccountRecovery(address(account)).executeRecovery();

        assertEq(account.getRecoveryNonce(), 1);
    }

    // ── removeGuardianWithMixedSigs ────────────────────────────────────────────

    function test_removeGuardianWithMixedSigs_ecdsa_only() public {
        uint256 g1Key = uint256(keccak256("g1"));
        uint256 g2Key = uint256(keccak256("g2"));
        address g1 = vm.addr(g1Key);
        address g2 = vm.addr(g2Key);
        address g3 = makeAddr("g3");
        _deploy(g1, g2, g3);

        // #120 final review [HIGH]: opData binds (nonce, index, guardianAddr, p256X, p256Y).
        // Removing g3 at slot 2 (ECDSA → key (0,0)).
        bytes memory opData = abi.encode(uint256(0), uint8(2), g3, bytes32(0), bytes32(0));
        bytes32 ethHash = keccak256(abi.encode(
            GUARDIAN_SIG_VER, block.chainid, address(account), "REMOVE_GUARDIAN", opData
        )).toEthSignedMessageHash();

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signEcdsa(g1Key, ethHash);
        sigs[1] = _signEcdsa(g2Key, ethHash);

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "removeGuardianWithMixedSigs(uint8,uint8[],bytes[])", uint8(2), signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.guardianCount(), 2);
    }

    function test_removeGuardianWithMixedSigs_p256_slot_shifts_key() public {
        _deployWithThreeP256Init();
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 1; signerIdxs[1] = 2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "removeGuardianWithMixedSigs(uint8,uint8[],bytes[])", uint8(0), signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.guardianCount(), 2);

        (bool ok2, bytes memory d) = address(account).call(abi.encodeWithSignature(
            "getGuardianP256Key(uint8)", uint8(0)
        ));
        assertTrue(ok2);
        (bytes32 x,) = abi.decode(d, (bytes32, bytes32));
        assertEq(x, P256_X1); // slot 0 now holds what was slot 1
    }

    // Tests that the legacy (ECDSA-sig) removeGuardian path also shifts P-256 key slots correctly.
    // Regression for Round 4 HIGH: Base::removeGuardian previously shifted addresses but not keys.
    function test_removeGuardian_legacy_shiftsP256Key() public {
        // Deploy: slot 0 = ECDSA (ecdsaGuardian), slot 1 = P-256 (X0/Y0), slot 2 = ECDSA (guardian2)
        uint256 g2Key = uint256(keccak256(abi.encodePacked("guardian2")));
        address g2 = vm.addr(g2Key);
        uint256 g3Key = uint256(keccak256(abi.encodePacked("guardian3")));
        address g3 = vm.addr(g3Key);

        uint8[] memory noAlgs = new uint8[](0);
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, AAStarAirAccountBase.InitConfig({
            guardians: [g2, address(0), g3],
            guardianP256X: [bytes32(0), P256_X0, bytes32(0)],
            guardianP256Y: [bytes32(0), P256_Y0, bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        }), address(0), bytes32(0), bytes32(0));
        // layout: g2=idx0(ECDSA), P256=idx1(X0/Y0), g3=idx2(ECDSA)

        // Build ECDSA removal sigs for removing idx 0 (g2 address). #120 final review [HIGH]:
        // opData binds (nonce, index, guardianAddr, p256X, p256Y); ECDSA slot → key (0,0).
        bytes32 h = keccak256(abi.encode(
            uint8(4), block.chainid, address(account), "REMOVE_GUARDIAN",
            abi.encode(uint256(0), uint8(0), g2, bytes32(0), bytes32(0))
        ));
        bytes32 ethH = MessageHashUtils.toEthSignedMessageHash(h);
        bytes[] memory sigs = new bytes[](2);
        { (uint8 v, bytes32 r, bytes32 s) = vm.sign(g3Key, ethH); sigs[0] = abi.encodePacked(r, s, v); }
        // P-256 guardian can't sign ECDSA removal — use g3 twice? No, need 2 distinct ECDSA signers.
        // Redeploy with 3 ECDSA guardians so legacy removeGuardian works
        uint256 g1Key = uint256(keccak256(abi.encodePacked("g1_legacy")));
        address g1a = vm.addr(g1Key);
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPoint, owner, AAStarAirAccountBase.InitConfig({
            guardians: [g1a, address(0), g3],
            guardianP256X: [bytes32(0), P256_X0, bytes32(0)],
            guardianP256Y: [bytes32(0), P256_Y0, bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0),
            tier1Limit: 0,
            tier2Limit: 0
        }), address(0), bytes32(0), bytes32(0));
        // layout: g1a=idx0(ECDSA), P256=idx1(X0/Y0), g3=idx2(ECDSA)
        h = keccak256(abi.encode(
            uint8(4), block.chainid, address(account), "REMOVE_GUARDIAN",
            abi.encode(uint256(0), uint8(0), g1a, bytes32(0), bytes32(0))
        ));
        ethH = MessageHashUtils.toEthSignedMessageHash(h);
        { (uint8 v, bytes32 r, bytes32 s) = vm.sign(g1Key, ethH); sigs[0] = abi.encodePacked(r, s, v); }
        { (uint8 v, bytes32 r, bytes32 s) = vm.sign(g3Key, ethH); sigs[1] = abi.encodePacked(r, s, v); }

        vm.prank(owner);
        account.removeGuardian(0, sigs); // remove g1a (idx 0), P-256 shifts to idx 0

        assertEq(account.guardianCount(), 2);
        // P-256 key must have shifted from slot 1 to slot 0
        (bool ok, bytes memory d) = address(account).call(abi.encodeWithSignature(
            "getGuardianP256Key(uint8)", uint8(0)
        ));
        assertTrue(ok);
        (bytes32 x, bytes32 y) = abi.decode(d, (bytes32, bytes32));
        assertEq(x, P256_X0);
        assertEq(y, P256_Y0);
    }

    // ── modifyTierLimitsWithMixedGuardians ────────────────────────────────────

    function test_modifyTierLimitsWithMixedGuardians_twoP256Guardians() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint256 deadline = block.timestamp + 1 hours;
        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])",
            uint256(1 ether), uint256(10 ether), deadline, signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.tier1Limit(), 1 ether);
        assertEq(account.tier2Limit(), 10 ether);
    }

    function test_modifyTierLimitsWithMixedGuardians_mixedTypes() public {
        _deployMixed(ecdsaGuardian, P256_X0, P256_Y0); // slot 0=ECDSA, slot 1=P-256
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory opData = abi.encode(uint256(0), uint256(1 ether), uint256(10 ether), deadline);
        bytes32 ecdsaHash = keccak256(abi.encode(
            GUARDIAN_SIG_VER, block.chainid, address(account), "MODIFY_TIER_LIMITS", opData
        )).toEthSignedMessageHash();

        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signEcdsa(ecdsaGuardianKey, ecdsaHash);
        sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])",
            uint256(1 ether), uint256(10 ether), deadline, signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.tier1Limit(), 1 ether);
    }

    function test_modifyTierLimitsWithMixedGuardians_expiredDeadline_reverts() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint256 deadline = block.timestamp - 1;
        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])",
            uint256(1 ether), uint256(10 ether), deadline, signerIdxs, sigs
        ));
        assertFalse(ok);
    }

    /// @notice issue-140 Low: modifyTierLimitsWithMixedGuardians succeeds when called via
    ///         self-call (msg.sender == account), covering the gasless UserOp path.
    function test_modifyTierLimitsWithMixedGuardians_selfCall_succeeds() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        uint256 deadline = block.timestamp + 1 hours;
        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(address(account));
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])",
            uint256(1 ether), uint256(10 ether), deadline, signerIdxs, sigs
        ));
        assertTrue(ok);
        assertEq(account.tier1Limit(), 1 ether);
        assertEq(account.tier2Limit(), 10 ether);
    }

    // ── getGuardianP256Key view ────────────────────────────────────────────────

    function test_getGuardianP256Key_ecdsaSlot_returnsZero() public {
        _deploy(ecdsaGuardian, address(0), address(0));
        (bool ok, bytes memory d) = address(account).call(abi.encodeWithSignature(
            "getGuardianP256Key(uint8)", uint8(0)
        ));
        assertTrue(ok);
        (bytes32 x, bytes32 y) = abi.decode(d, (bytes32, bytes32));
        assertEq(x, bytes32(0));
        assertEq(y, bytes32(0));
    }

    // ── tierLimitNonce() — issue #131 ────────────────────────────────────────

    function test_tierLimitNonce_initiallyZero() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        (bool ok, bytes memory d) = address(account).call(
            abi.encodeWithSignature("tierLimitNonce()")
        );
        assertTrue(ok, "tierLimitNonce() call failed");
        assertEq(abi.decode(d, (uint256)), 0, "fresh account nonce should be 0");
    }

    function test_tierLimitNonce_incrementsAfterMixedModify() public {
        _deployWithP256Init(P256_X0, P256_Y0, P256_X1, P256_Y1);
        vm.etch(P256_PRECOMPILE, address(new MockP256Valid()).code);

        // nonce before: 0
        (, bytes memory d0) = address(account).call(abi.encodeWithSignature("tierLimitNonce()"));
        assertEq(abi.decode(d0, (uint256)), 0);

        uint256 deadline = block.timestamp + 1 hours;
        uint8[] memory signerIdxs = new uint8[](2);
        signerIdxs[0] = 0; signerIdxs[1] = 1;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _mockP256Sig(); sigs[1] = _mockP256Sig();

        vm.prank(owner);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])",
            uint256(1 ether), uint256(10 ether), deadline, signerIdxs, sigs
        ));
        assertTrue(ok, "modifyTierLimitsWithMixedGuardians failed");

        // nonce after: 1
        (, bytes memory d1) = address(account).call(abi.encodeWithSignature("tierLimitNonce()"));
        assertEq(abi.decode(d1, (uint256)), 1, "nonce should be 1 after first modify");
    }

    // ── Utility ───────────────────────────────────────────────────────────────

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) { c += x & 1; x >>= 1; }
    }
}
