// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {P256} from "solady/utils/P256.sol";

/// @title WebAuthnLib — shared WebAuthn (FIDO2 `webauthn.get`) P-256 assertion verifier
/// @notice #149: single source of truth for the P-256 / WebAuthn owner+guardian assertion check that
///         was previously carried as private copies in BOTH `AAStarAirAccountBase` and
///         `AirAccountExtension` (the code even noted "Mirrors ...", "Identical verification logic to
///         ...", a hand-sync hazard on a security-critical, non-upgradable path). Extracting it here
///         (a) removes the duplication and (b) frees EIP-170 headroom in the account impl + extension
///         because the WebAuthn bytecode is deployed ONCE (this external library), not twice.
///
///         Behavior is byte-identical to the prior inline implementation: same 352-byte ABI floor,
///         same no-revert ABI pre-validation (ERC-4337 `validateUserOp` must return, not revert), same
///         `webauthn.get` type binding (rejects replayed registration assertions), same UP-flag check,
///         same explicit low-S canonicality gate (EIP-7212 / the RIP-7212 precompile do NOT enforce
///         low-S), same clientDataJSON reconstruction. Only the raw `staticcall(0x100)` is replaced by
///         Solady `P256.verifySignatureAllowMalleability`, which is the same RIP-7212 precompile call
///         on chains that have it (the OP-mainnet target) and additionally falls back to a Solidity
///         verifier on chains that don't (a strict superset — the prior code returned false there).
///
///         Public (not internal) so Solidity deploys it once and links it via delegatecall — that is
///         what yields the bytecode saving. The function is pure w.r.t. the caller's storage (the
///         public key is a parameter), so running under the account's delegatecall context is safe.
///
///         ⚠️ DEPLOYMENT (external library — read before deploying the account stack): because this is
///         a linked library, `AAStarAirAccountV7` and `AirAccountExtension` creation bytecode carry an
///         UNRESOLVED link placeholder (`__$…$__`). You MUST deploy WebAuthnLib FIRST and substitute its
///         address into that placeholder before deploying the impl — sending raw `artifact.bytecode.object`
///         (the pre-#149 deploy pattern) ships a BROKEN account whose WebAuthn verification jumps to a
///         garbage address. The TS deploy scripts do this via `linkBytecode()` +
///         `LIBRARIES["src/utils/WebAuthnLib.sol:WebAuthnLib"]` (fail-closed: any residual placeholder
///         throws). `forge`/`forge script` auto-link. See `scripts/deploy-op-mainnet-alpha.ts`.
library WebAuthnLib {
    /// @dev secp256r1 group order / 2. A signature with s above this is the high-S malleable twin and
    ///      is rejected here (the precompile itself accepts both s and n-s).
    uint256 internal constant SECP256R1_N_OVER_2 =
        0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8;

    /// @notice Verify a WebAuthn `webauthn.get` P-256 assertion over `challenge` against `(pubKeyX, pubKeyY)`.
    /// @param challenge The 32-byte value that was base64url-encoded into `clientDataJSON.challenge` (the userOpHash / op digest).
    /// @param sig       `abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)`.
    /// @param pubKeyX   Owner/guardian passkey P-256 x-coordinate.
    /// @param pubKeyY   Owner/guardian passkey P-256 y-coordinate.
    /// @return          True iff the assertion is a valid, low-S, `webauthn.get` signature over the challenge.
    function verifyP256(bytes32 challenge, bytes memory sig, bytes32 pubKeyX, bytes32 pubKeyY)
        public
        view
        returns (bool)
    {
        if (pubKeyX == bytes32(0) && pubKeyY == bytes32(0)) return false;
        // ABI(bytes,bytes,bytes,bytes32,bytes32) head: 5*32 = 160 bytes; each dynamic bytes
        // needs at least 32 (length word) + 32 (one padded word) = 64 bytes.
        // Absolute minimum = 160 + 3*64 = 352 bytes.
        if (sig.length < 352) return false;

        // Pre-validate ABI structure to prevent abi.decode from reverting on malformed input.
        // A revert inside validateUserOp violates ERC-4337 (bundlers expect return 1/false, not revert).
        // Layout: [off0(32)][off1(32)][off2(32)][r(32)][s(32)] then dynamic data.
        {
            uint256 off0; uint256 off1; uint256 off2;
            uint256 len0; uint256 len1; uint256 len2;
            assembly {
                let base := add(sig, 32) // skip bytes memory length slot
                off0 := mload(base)
                off1 := mload(add(base, 32))
                off2 := mload(add(base, 64))
            }
            uint256 dataLen = sig.length;
            // Each offset must be within [160, dataLen-32] so there is room for a length word.
            // Use (off > dataLen - 32) to avoid checked-arithmetic overflow when off is near MAX_UINT256.
            if (off0 < 160 || off0 > dataLen - 32) return false;
            if (off1 < 160 || off1 > dataLen - 32) return false;
            if (off2 < 160 || off2 > dataLen - 32) return false;
            assembly {
                let base := add(sig, 32)
                len0 := mload(add(base, off0))
                len1 := mload(add(base, off1))
                len2 := mload(add(base, off2))
            }
            // Each array's content (length word + padded data) must not exceed sig.
            if (len0 > dataLen - off0 - 32) return false;
            if (len1 > dataLen - off1 - 32) return false;
            if (len2 > dataLen - off2 - 32) return false;
        }

        (
            bytes memory authenticatorData,
            bytes memory clientDataJSONPrefix,
            bytes memory clientDataJSONSuffix,
            bytes32 r,
            bytes32 s
        ) = abi.decode(sig, (bytes, bytes, bytes, bytes32, bytes32));

        // Minimum authenticatorData: rpIdHash(32) + flags(1) + signCount(4) = 37 bytes.
        if (authenticatorData.length < 37) return false;
        // UP (User Present) flag must be set (bit 0 of flags byte at index 32).
        if (uint8(authenticatorData[32]) & 0x01 == 0) return false;

        // Bind operation type: clientDataJSONPrefix must be the standard assertion preamble.
        // Prevents replay of webauthn.create (registration) assertions through this path.
        if (keccak256(clientDataJSONPrefix) != keccak256(bytes('{"type":"webauthn.get","challenge":"'))) {
            return false;
        }

        bytes memory clientDataJSON = abi.encodePacked(
            clientDataJSONPrefix,
            _base64UrlEncode32(challenge),
            clientDataJSONSuffix
        );

        bytes32 clientDataHash = sha256(clientDataJSON);
        bytes32 payloadHash    = sha256(abi.encodePacked(authenticatorData, clientDataHash));

        // Explicit low-S canonicality gate BEFORE the curve check — kept identical to the prior inline
        // path (the RIP-7212 precompile accepts high-S). `verifySignatureAllowMalleability` is the raw
        // precompile equivalent of the prior `staticcall(0x100)`, so with this gate the behavior is
        // byte-identical to the old code (explicit low-S + raw precompile), plus a Solidity fallback on
        // non-precompile chains where the old code simply returned false.
        if (uint256(s) > SECP256R1_N_OVER_2) return false;
        return P256.verifySignatureAllowMalleability(payloadHash, r, s, pubKeyX, pubKeyY);
    }

    /// @dev Base64url-encode a bytes32 (no padding) — reconstructs `clientDataJSON.challenge`.
    ///      Ported VERBATIM from the prior `AAStarAirAccountBase._base64UrlEncode32` (byte-identical output).
    function _base64UrlEncode32(bytes32 input) internal pure returns (bytes memory result) {
        result = new bytes(43);
        bytes memory data = abi.encodePacked(input);
        bytes memory t = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_");
        uint256 j = 0;
        for (uint256 i = 0; i < 30; i += 3) {
            uint256 b0 = uint8(data[i]);
            uint256 b1 = uint8(data[i + 1]);
            uint256 b2 = uint8(data[i + 2]);
            result[j++] = t[b0 >> 2];
            result[j++] = t[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j++] = t[((b1 & 0x0F) << 2) | (b2 >> 6)];
            result[j++] = t[b2 & 0x3F];
        }
        // Final 2 bytes (indices 30, 31) -> 3 base64url chars (no padding)
        uint256 b30 = uint8(data[30]);
        uint256 b31 = uint8(data[31]);
        result[j++] = t[b30 >> 2];
        result[j++] = t[((b30 & 0x03) << 4) | (b31 >> 4)];
        result[j]   = t[(b31 & 0x0F) << 2];
    }
}
