// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

// REAL passkey end-to-end test. Unlike P256Guardian.t.sol (which etches a mock precompile that
// blindly returns 1), this exercises the FULL cryptographic chain a real Apple/Google passkey
// goes through:
//
//   1. A software P-256 authenticator (Node WebCrypto, via FFI) produces a genuine WebAuthn
//      assertion — clientDataJSON, authenticatorData, and a real ES256 signature — over the exact
//      challenge the contract derives. This is byte-for-byte the format navigator.credentials.get()
//      returns; only the key custody differs (software here vs Secure Enclave on a phone).
//   2. address(0x100) is etched with a REAL P-256 verifier (OpenZeppelin P256.verifySolidity),
//      so the contract's staticcall runs actual secp256r1 math — no mock, no auto-pass.
//
// It proves the contract accepts real passkey signatures for registration + full social recovery,
// AND rejects tampered ones (guarding against a false-positive verifier).
//
// Requires: forge test --ffi  (calls node test/webauthn/gen_p256_assertion.mjs)

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

/// @dev RIP-7212-compatible verifier backed by OZ's pure-Solidity secp256r1 implementation.
///      Etched at 0x100 so the contract's precompile staticcall performs genuine verification.
contract RealP256Verifier {
    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length != 160) return abi.encode(uint256(0));
        bool ok = P256.verifySolidity(
            bytes32(input[0:32]),    // hash
            bytes32(input[32:64]),   // r
            bytes32(input[64:96]),   // s
            bytes32(input[96:128]),  // qx
            bytes32(input[128:160])  // qy
        );
        return abi.encode(ok ? uint256(1) : uint256(0));
    }
}

interface IExt {
    function addP256Guardian(bytes32 x, bytes32 y) external;
    function getGuardianP256Key(uint8 index) external view returns (bytes32, bytes32);
    function getRecoveryNonce() external view returns (uint256);
    function proposeRecoveryWithSig(address newOwner, uint8 gIdx, bytes calldata sig) external;
    function approveRecoveryWithSig(uint8 gIdx, bytes calldata sig) external;
    function executeRecovery() external;
}

contract P256WebAuthnRealSigTest is Test {
    AAStarAirAccountV7 account;

    address constant P256_PRECOMPILE = address(0x100);
    address constant P256_GUARDIAN_SENTINEL = address(0x7026);
    uint8 constant SIG_VERSION = 4;

    // Public keys of the two fixed test passkeys in gen_p256_assertion.mjs (key 0 and key 1).
    bytes32 constant PK0_X = 0xe8e47200eb693978a384a1d2d4baaca209c91a2fefa004e818ae9a734bf7287c;
    bytes32 constant PK0_Y = 0x6e9808d701ac9a2fcad8ede6374ed3dc8187eaade2f0ae3a43a0232441df32d1;
    bytes32 constant PK1_X = 0x62810e5e1c845ca988f1906dc8dbbe9e060ceb8552076fcbc36dc8843950c9e5;
    bytes32 constant PK1_Y = 0x3751a3348045d04907920d750d5d200a1d35a7a8f11f325f7e283eaaf86e616b;

    address entryPointAddr = makeAddr("entryPoint");
    address ownerAddr = makeAddr("owner");
    address newOwnerAddr = makeAddr("newOwner");

    /// @dev External probe so a missing `--ffi` flag can be caught (cheatcodes can't be try/caught inline).
    function ffiProbe() external returns (bytes memory) {
        string[] memory c = new string[](2);
        c[0] = "node";
        c[1] = "--version";
        return vm.ffi(c);
    }

    function setUp() public {
        // This suite needs FFI (forge test --ffi) to call the Node authenticator. If FFI is
        // disabled, skip the whole suite rather than failing the default `forge test` run.
        try this.ffiProbe() returns (bytes memory) {} catch {
            vm.skip(true);
            return;
        }

        // REAL verifier at the precompile address — genuine secp256r1, not a mock.
        vm.etch(P256_PRECOMPILE, address(new RealP256Verifier()).code);

        uint8[] memory noAlgs = new uint8[](0);
        // Deploy with TWO P-256 passkey guardians (slots 0 and 1) → 2-of-2 recovery quorum.
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [PK0_X, PK1_X, bytes32(0)],
            guardianP256Y: [PK0_Y, PK1_Y, bytes32(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        });
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerAddr, config, address(0), bytes32(0), bytes32(0));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Recompute the exact challenge the contract derives for a P-256 guardian op.
    function _challenge(string memory opLabel, bytes memory opData) internal view returns (bytes32) {
        return keccak256(abi.encode(
            SIG_VERSION, block.chainid, address(account), "P256_GUARDIAN", opLabel, opData
        ));
    }

    /// @dev FFI into the Node authenticator; returns the contract sig blob
    ///      abi.encode(authData, prefix, suffix, r, s).
    function _realSig(bytes32 challenge, uint8 keyIdx) internal returns (bytes memory) {
        string[] memory cmd = new string[](5);
        cmd[0] = "node";
        cmd[1] = "test/webauthn/gen_p256_assertion.mjs";
        cmd[2] = vm.toString(challenge);
        cmd[3] = "05"; // flags: UP|UV
        cmd[4] = vm.toString(uint256(keyIdx));
        bytes memory out = vm.ffi(cmd);
        (bytes memory ad, bytes memory pre, bytes memory suf, bytes32 r, bytes32 s,,) =
            abi.decode(out, (bytes, bytes, bytes, bytes32, bytes32, bytes32, bytes32));
        return abi.encode(ad, pre, suf, r, s);
    }

    // ── tests ────────────────────────────────────────────────────────────────

    /// Full passkey-only social recovery: passkey#0 proposes (auto-approves), passkey#1 approves,
    /// timelock elapses, anyone executes. Every signature is a real ES256 assertion verified by
    /// real secp256r1 math.
    function test_fullPasskeyRecovery_realSignatures() public {
        assertEq(account.owner(), ownerAddr);
        uint256 nonce = IExt(address(account)).getRecoveryNonce();

        // 1. passkey#0 proposes recovery to newOwner (auto-approve = bit 0)
        bytes32 proposeChallenge = _challenge("PROPOSE_RECOVERY", abi.encode(nonce, newOwnerAddr));
        bytes memory sig0 = _realSig(proposeChallenge, 0);
        IExt(address(account)).proposeRecoveryWithSig(newOwnerAddr, 0, sig0);

        (address pendingOwner,,,) = account.activeRecovery();
        assertEq(pendingOwner, newOwnerAddr, "proposal not recorded");

        // 2. passkey#1 approves (bit 1) → 2-of-2 reached
        bytes32 approveChallenge = _challenge("APPROVE_RECOVERY", abi.encode(nonce, newOwnerAddr));
        bytes memory sig1 = _realSig(approveChallenge, 1);
        IExt(address(account)).approveRecoveryWithSig(1, sig1);

        // 3. timelock (2 days) then execute
        vm.warp(block.timestamp + 2 days + 1);
        IExt(address(account)).executeRecovery();

        assertEq(account.owner(), newOwnerAddr, "owner not recovered via real passkeys");
    }

    /// Registration of a NEW passkey guardian (bootstrap path) + a real-signature proposal from it.
    /// Re-deploys with a single passkey, registers a second, then has the registered key propose.
    function test_registerPasskeyGuardian_thenRealPropose() public {
        // fresh account with only passkey#0
        uint8[] memory noAlgs = new uint8[](0);
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerAddr, AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            guardianP256X: [PK0_X, bytes32(0), bytes32(0)],
            guardianP256Y: [PK0_Y, bytes32(0), bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }), address(0), bytes32(0), bytes32(0));

        // owner registers passkey#1 as guardian 1 (bootstrap: count 1 < RECOVERY_THRESHOLD)
        vm.prank(ownerAddr);
        IExt(address(account)).addP256Guardian(PK1_X, PK1_Y);
        (bytes32 gx, bytes32 gy) = IExt(address(account)).getGuardianP256Key(1);
        assertEq(gx, PK1_X);
        assertEq(gy, PK1_Y);

        // the freshly-registered passkey#1 proposes recovery with a real signature
        uint256 nonce = IExt(address(account)).getRecoveryNonce();
        bytes32 c = _challenge("PROPOSE_RECOVERY", abi.encode(nonce, newOwnerAddr));
        bytes memory sig = _realSig(c, 1);
        IExt(address(account)).proposeRecoveryWithSig(newOwnerAddr, 1, sig);

        (address pendingOwner,,,) = account.activeRecovery();
        assertEq(pendingOwner, newOwnerAddr);
    }

    /// A real signature bound to the WRONG challenge (wrong newOwner) must be rejected by the
    /// real verifier — proves the precompile is doing genuine work, not auto-passing.
    function test_realVerifier_rejectsWrongChallengeSignature() public {
        uint256 nonce = IExt(address(account)).getRecoveryNonce();
        // sign the challenge for newOwnerAddr ...
        bytes32 c = _challenge("PROPOSE_RECOVERY", abi.encode(nonce, newOwnerAddr));
        bytes memory sig = _realSig(c, 0);
        // ... but submit it proposing a DIFFERENT owner → reconstructed challenge differs → reject
        address attacker = makeAddr("attacker");
        vm.expectRevert();
        IExt(address(account)).proposeRecoveryWithSig(attacker, 0, sig);
    }

    /// A signature from a key that is NOT the registered guardian must be rejected.
    function test_realVerifier_rejectsWrongKey() public {
        uint256 nonce = IExt(address(account)).getRecoveryNonce();
        bytes32 c = _challenge("PROPOSE_RECOVERY", abi.encode(nonce, newOwnerAddr));
        // sign with passkey#1 but claim to be guardian slot 0 (which holds passkey#0's pubkey)
        bytes memory sig = _realSig(c, 1);
        vm.expectRevert();
        IExt(address(account)).proposeRecoveryWithSig(newOwnerAddr, 0, sig);
    }

    // ── #120 final review [HIGH] regression: removal opData binds slot index + P-256 key ──────────

    /// @dev Deploy 3 guardians: slot0 = P-256 key0, slot1 = P-256 key1, slot2 = ECDSA `ecdsaG`.
    ///      (removeGuardianWithMixedSigs requires guardianCount > 2.)
    function _deployTwoP256OneEcdsa(address ecdsaG) internal {
        uint8[] memory noAlgs = new uint8[](0);
        account = new AAStarAirAccountV7(address(0));
        account.initialize(entryPointAddr, ownerAddr, AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), ecdsaG],
            guardianP256X: [PK0_X, PK1_X, bytes32(0)],
            guardianP256Y: [PK0_Y, PK1_Y, bytes32(0)],
            dailyLimit: 0, approvedAlgIds: noAlgs, minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }), address(0), bytes32(0), bytes32(0));
    }

    /// @dev ECDSA guardian signature over the REMOVE_GUARDIAN domain for the given opData.
    function _ecdsaRemovalSig(uint256 pk, bytes memory opData) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(
            SIG_VERSION, block.chainid, address(account), "REMOVE_GUARDIAN", opData
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(h));
        return abi.encodePacked(r, s, v);
    }

    /// Positive control: a removal authorized for slot 1 (its real opData) succeeds. Uses a REAL
    /// P-256 assertion (slot 0) + a real ECDSA sig (slot 2) — no mock.
    function test_removeMixedSigs_realSig_correctSlotSucceeds() public {
        uint256 gEKey = uint256(keccak256("ecdsaGuardian"));
        _deployTwoP256OneEcdsa(vm.addr(gEKey));

        // Authorize removing slot 1 (P-256 key1): opData binds (nonce, index=1, sentinel, PK1).
        bytes memory opData = abi.encode(uint256(0), uint8(1), P256_GUARDIAN_SENTINEL, PK1_X, PK1_Y);
        bytes32 ch = _challenge("REMOVE_GUARDIAN", opData);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _realSig(ch, 0);                 // P-256 guardian slot 0 signs the real assertion
        sigs[1] = _ecdsaRemovalSig(gEKey, opData); // ECDSA guardian slot 2
        uint8[] memory idxs = new uint8[](2); idxs[0] = 0; idxs[1] = 2;

        vm.prank(ownerAddr);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "removeGuardianWithMixedSigs(uint8,uint8[],bytes[])", uint8(1), idxs, sigs));
        assertTrue(ok, "correct-slot removal should succeed");
        assertEq(account.guardianCount(), 2);
    }

    /// THE H1 REGRESSION: signatures authorizing removal of slot 1 must NOT be replayable to remove
    /// slot 0. Before the fix, every P-256 slot's removal opData was identical (nonce, sentinel), so
    /// these sigs would have removed slot 0. Now opData binds index + P-256 key, so the contract
    /// rebuilds a different challenge for slot 0 and the REAL P-256 verifier rejects the assertion.
    function test_removeMixedSigs_realSig_crossSlotRejected() public {
        uint256 gEKey = uint256(keccak256("ecdsaGuardian"));
        _deployTwoP256OneEcdsa(vm.addr(gEKey));

        // Sigs authorize removing slot 1 (key1).
        bytes memory opData1 = abi.encode(uint256(0), uint8(1), P256_GUARDIAN_SENTINEL, PK1_X, PK1_Y);
        bytes32 ch1 = _challenge("REMOVE_GUARDIAN", opData1);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _realSig(ch1, 0);
        sigs[1] = _ecdsaRemovalSig(gEKey, opData1);
        uint8[] memory idxs = new uint8[](2); idxs[0] = 0; idxs[1] = 2;

        // Attacker submits them targeting slot 0. Contract rebuilds opData for slot 0 → different
        // challenge → real secp256r1 verification of sig0 fails → revert. No guardian removed.
        vm.prank(ownerAddr);
        (bool ok,) = address(account).call(abi.encodeWithSignature(
            "removeGuardianWithMixedSigs(uint8,uint8[],bytes[])", uint8(0), idxs, sigs));
        assertFalse(ok, "cross-slot removal must be rejected by the index/key binding");
        assertEq(account.guardianCount(), 3, "no guardian should have been removed");
    }
}
