// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev Mock P256 precompile that returns success (valid = 1). Etched at 0x100 so the WebAuthn
///      branch's crypto values are arbitrary — the ECDSA branch still uses real ecrecover.
contract MockP256OwnerAuthSuccess {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @dev The isValidOwnerAuth view lives in AirAccountExtension and is reached through the account's
///      fallback → delegatecall. Casting the account address to this interface therefore also proves
///      the fallback routing serves the view (exactly what a DVT's eth_call hits). Issue #159.
interface IOwnerAuth {
    function isValidOwnerAuth(bytes32 userOpHash, bytes calldata ownerAuth) external view returns (bytes4);
}

/// @title isValidOwnerAuth — owner-authorization single-source-of-truth view (issue #159)
/// @notice Verifies routing (fallback → Extension), the 1-byte type tag, the EIP-191 ECDSA prefix
///         convention, the WebAuthn owner-key branch, the dedicated magic value, and fail-closed
///         behavior on malformed / unknown-tag input.
contract IsValidOwnerAuthTest is Test {
    using MessageHashUtils for bytes32;

    AAStarAirAccountV7 account;
    IOwnerAuth authView;

    Vm.Wallet ownerWallet;
    Vm.Wallet strangerWallet;

    address constant ENTRY_POINT = address(0xEE);
    bytes4  constant MAGIC       = 0xa0cf00cf; // isValidOwnerAuth(bytes32,bytes)
    bytes4  constant FAIL        = 0xffffffff;
    bytes4  constant ERC1271     = 0x1626ba7e;

    uint8 constant TAG_ECDSA    = 0x01;
    uint8 constant TAG_WEBAUTHN = 0x02;

    function setUp() public {
        ownerWallet    = vm.createWallet("ownerAuthOwner");
        strangerWallet = vm.createWallet("ownerAuthStranger");

        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
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
        account.initialize(ENTRY_POINT, ownerWallet.addr, cfg, address(0), bytes32(0), bytes32(0));
        authView = IOwnerAuth(address(account));

        // Owner passkey (non-zero so the WebAuthn key-missing gate doesn't short-circuit).
        vm.prank(ownerWallet.addr);
        account.setP256Key(bytes32(uint256(1)), bytes32(uint256(2)));

        // Mock P256 precompile (returns valid) so the WebAuthn branch exercises structure, not crypto.
        MockP256OwnerAuthSuccess p256Mock = new MockP256OwnerAuthSuccess();
        vm.etch(address(0x100), address(p256Mock).code);
    }

    // ─── ECDSA branch (tag 0x01) ──────────────────────────────────────

    function _ecdsaOwnerAuth(Vm.Wallet memory w, bytes32 userOpHash) internal pure returns (bytes memory) {
        // EIP-191 personal_sign — MUST match the UserOp owner path (_validateECDSA), not raw ERC-1271.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, userOpHash.toEthSignedMessageHash());
        return abi.encodePacked(TAG_ECDSA, r, s, v);
    }

    function test_ecdsa_validOwnerSig_returnsMagic() public view {
        bytes32 userOpHash = keccak256("op-1");
        bytes4 out = authView.isValidOwnerAuth(userOpHash, _ecdsaOwnerAuth(ownerWallet, userOpHash));
        assertEq(out, MAGIC, "valid owner ECDSA must return magic");
    }

    function test_ecdsa_wrongSigner_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-2");
        bytes4 out = authView.isValidOwnerAuth(userOpHash, _ecdsaOwnerAuth(strangerWallet, userOpHash));
        assertEq(out, FAIL, "non-owner ECDSA must fail");
    }

    /// @dev Guards the prefix convention: a raw sign over userOpHash (no EIP-191) must NOT validate,
    ///      because the view applies toEthSignedMessageHash. If this ever passes, the DVT/SDK could
    ///      silently rely on raw-sign and drift from the on-chain UserOp path.
    function test_ecdsa_rawSignInsteadOfPersonalSign_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-3");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, userOpHash); // raw, no prefix
        bytes memory ownerAuth = abi.encodePacked(TAG_ECDSA, r, s, v);
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "raw-sign must fail");
    }

    function test_ecdsa_wrongLength_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-4");
        bytes memory ownerAuth = abi.encodePacked(TAG_ECDSA, new bytes(64)); // 64, not 65
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "wrong ECDSA length must fail, not revert");
    }

    /// @dev Codex Medium (PR #160): the on-chain UserOp path (_validateECDSA) normalizes v=0/1 -> 27/28
    ///      and accepts. The view MUST do the same, else an owner sig with v=0/1 passes validateUserOp
    ///      but the DVT's eth_call rejects it — a divergence between the two paths meant to be equivalent.
    function test_ecdsa_vZeroOne_normalizedAndAccepted() public view {
        bytes32 userOpHash = keccak256("op-v01");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, userOpHash.toEthSignedMessageHash());
        uint8 vRaw = v - 27; // 0 or 1 — the non-normalized recovery id
        bytes memory ownerAuth = abi.encodePacked(TAG_ECDSA, r, s, vRaw);
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), MAGIC, "v=0/1 owner sig must be accepted (matches _validateECDSA)");
    }

    /// @dev High-S signatures are malleable; both _validateECDSA and this view must reject them.
    function test_ecdsa_highS_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-highs");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerWallet.privateKey, userOpHash.toEthSignedMessageHash());
        // Flip s to its high-S complement: s' = n - s, v' = v ^ 1 (still a valid sig, but non-canonical).
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory ownerAuth = abi.encodePacked(TAG_ECDSA, r, highS, vFlip);
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "high-S must be rejected (EIP-2)");
    }

    // ─── WebAuthn branch (tag 0x02) ───────────────────────────────────

    /// @dev Minimal structurally-valid WebAuthn assertion. Challenge is NOT in the blob — the contract
    ///      binds it via base64url(userOpHash). P256 precompile is mocked, so crypto values are arbitrary.
    function _waBlob() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01; // UP flag
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory suffix = bytes('"}');
        return abi.encode(authenticatorData, prefix, suffix, bytes32(uint256(0xAA)), bytes32(uint256(0x01)));
    }

    function test_webauthn_validAssertion_returnsMagic() public view {
        bytes32 userOpHash = keccak256("op-wa-1");
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, _waBlob());
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), MAGIC, "valid owner WebAuthn must return magic");
    }

    function test_webauthn_badPrefix_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-wa-2");
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x01;
        // webauthn.create instead of webauthn.get — must be rejected even though P256 mock returns valid.
        bytes memory prefix = bytes('{"type":"webauthn.create","challenge":"');
        bytes memory blob = abi.encode(authenticatorData, prefix, bytes('"}'), bytes32(uint256(0xAA)), bytes32(uint256(0x01)));
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, blob);
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "wrong clientData type must fail");
    }

    function test_webauthn_upFlagUnset_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-wa-3");
        bytes memory authenticatorData = new bytes(37); // flags byte left 0x00 → UP unset
        bytes memory prefix = bytes('{"type":"webauthn.get","challenge":"');
        bytes memory blob = abi.encode(authenticatorData, prefix, bytes('"}'), bytes32(uint256(0xAA)), bytes32(uint256(0x01)));
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, blob);
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "UP flag unset must fail");
    }

    function test_webauthn_tooShort_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-wa-4");
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, new bytes(100)); // < 352 → fail-closed
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "short WebAuthn blob must fail, not revert");
    }

    /// @dev An account with no owner passkey must never authorize the WebAuthn branch.
    function test_webauthn_noPasskeySet_returnsFailure() public {
        uint8[] memory noAlgs = new uint8[](0);
        AAStarAirAccountBase.InitConfig memory cfg = AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
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
        AAStarAirAccountV7 noKeyAcct = new AAStarAirAccountV7(address(0));
        noKeyAcct.initialize(ENTRY_POINT, ownerWallet.addr, cfg, address(0), bytes32(0), bytes32(0));

        bytes32 userOpHash = keccak256("op-wa-5");
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, _waBlob());
        assertEq(
            IOwnerAuth(address(noKeyAcct)).isValidOwnerAuth(userOpHash, ownerAuth),
            FAIL,
            "no owner passkey must fail"
        );
    }

    // ─── Tag discrimination / fail-closed ─────────────────────────────

    function test_unknownTag_returnsFailure() public view {
        bytes32 userOpHash = keccak256("op-5");
        bytes memory ownerAuth = abi.encodePacked(uint8(0x03), _waBlob());
        assertEq(authView.isValidOwnerAuth(userOpHash, ownerAuth), FAIL, "unknown tag must fail");
    }

    function test_emptyOwnerAuth_returnsFailure() public view {
        assertEq(authView.isValidOwnerAuth(keccak256("op-6"), ""), FAIL, "empty ownerAuth must fail");
    }

    // ─── Fail-closed fuzz (Codex High was a false positive — lock it in) ──

    /// @dev No tag-0x02 WebAuthn payload may EVER revert — it must always return magic or 0xffffffff,
    ///      so a DVT's eth_call cannot be griefed into a revert. Codex flagged a suspected abi.decode
    ///      revert (adversarial offsets/lengths); 10k fuzz runs show the ABI bounds pre-check holds.
    function testFuzz_webauthn_neverReverts(bytes calldata rawBlob) public view {
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, rawBlob);
        bytes4 out = authView.isValidOwnerAuth(keccak256("fuzz-wa"), ownerAuth);
        assertTrue(out == FAIL || out == MAGIC, "WebAuthn branch must be fail-closed, never revert");
    }

    /// @dev Directly hammer the three ABI offset words that drive abi.decode bounds.
    function testFuzz_webauthn_adversarialOffsets(uint256 o0, uint256 o1, uint256 o2, uint16 extra) public view {
        uint256 dataLen = 352 + (uint256(extra) % 256);
        bytes memory blob = new bytes(dataLen);
        o0 %= (dataLen + 64); o1 %= (dataLen + 64); o2 %= (dataLen + 64);
        assembly {
            let base := add(blob, 32)
            mstore(base, o0)
            mstore(add(base, 32), o1)
            mstore(add(base, 64), o2)
        }
        bytes memory ownerAuth = abi.encodePacked(TAG_WEBAUTHN, blob);
        bytes4 out = authView.isValidOwnerAuth(keccak256("fuzz-off"), ownerAuth);
        assertTrue(out == FAIL || out == MAGIC, "adversarial offsets must not revert");
    }

    function testFuzz_ecdsa_neverReverts(bytes calldata rawSig) public view {
        bytes memory ownerAuth = abi.encodePacked(TAG_ECDSA, rawSig);
        bytes4 out = authView.isValidOwnerAuth(keccak256("fuzz-ec"), ownerAuth);
        assertTrue(out == FAIL || out == MAGIC, "ECDSA branch must be fail-closed, never revert");
    }

    // ─── Magic value semantics ────────────────────────────────────────

    function test_magicValue_isOwnSelectorNotErc1271() public pure {
        assertEq(MAGIC, IOwnerAuth.isValidOwnerAuth.selector, "magic must be the function selector");
        assertTrue(MAGIC != ERC1271, "magic must NOT collide with ERC-1271 isValidSignature");
    }
}
