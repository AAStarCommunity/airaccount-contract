// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AAStarBLSAlgorithm} from "../src/validators/AAStarBLSAlgorithm.sol";

// issue #45 Fix 1 — golden-vector test for on-chain RFC 9380 hash_to_curve.
// The expected 256-byte G2 points were produced by noble-curves v2.0.1 (the exact
// version the DVT runs):
//   bls12_381.G2.hashToCurve(getBytes(h), { DST: "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_" })
// then encoded EIP-2537-style (x.c0 at 16, x.c1 at 80, y.c0 at 144, y.c1 at 208) — mirroring
// YetAnotherAA-Validator/src/utils/bls.util.ts encodeG2Point().
///
///      REQUIRES EIP-2537 precompiles → run with `--evm-version prague` (revm enables
///      0x05/0x11/0x0d under Prague). Under the repo default `cancun` these precompiles are
///      absent and the test is skipped via the precompile-availability guard.
contract HashToG2GoldenTest is Test {
    AAStarBLSAlgorithm bls;

    function setUp() public {
        bls = new AAStarBLSAlgorithm();
    }

    /// @dev Returns true iff EIP-2537 MAP_FP2_TO_G2 (0x11) is present (Prague). Under cancun the
    ///      staticcall hits an empty account → returns success with 0 bytes of output.
    function _has2537() internal view returns (bool) {
        bytes memory inp = new bytes(128);
        bool ok;
        uint256 rds;
        assembly {
            ok := staticcall(gas(), 0x11, add(inp, 0x20), 128, 0, 0)
            rds := returndatasize()
        }
        return ok && rds == 256;
    }

    function test_hashToG2_golden_vector1() public view {
        if (!_has2537()) return; // skip under cancun
        bytes32 h = 0x1111111111111111111111111111111111111111111111111111111111111111;
        bytes memory expected =
            hex"0000000000000000000000000000000006ee78bc8f2dec556b1fc39b04afe2126b9817c06dc3a62eebea7015bc5e5f83209b3b632351b8b32442ea4df23425cb00000000000000000000000000000000160a054c6de9a3df5ba20bdb88a06e0af04e27fccf362e3469b11ba80243ad6e78fc020c8fc79cc26c489731f7be19590000000000000000000000000000000001e519a10826c01e6492cf454c3b4fe21103add791f18c950f4202ff9e4be43e8b15185d25e6ae64f23e1c861b5e1a8300000000000000000000000000000000134607d8f6cd2b673a9d3283ec12f593d3bcb787d5d6198f3ad472e680eff430e95c708d1d880ac65fa080e74ef5e36b";
        assertEq(bls.hashToG2(h), expected, "hashToG2 != noble G2.hashToCurve (vec1)");
    }

    function test_hashToG2_golden_vector2() public view {
        if (!_has2537()) return; // skip under cancun
        bytes32 h = 0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81;
        bytes memory expected =
            hex"0000000000000000000000000000000008ecb047898685515ad76c4ed47ca143e91e1e8f71f659e5c346ee4b532c8bbf5c3f376252faf0fa8b9f46bf4523c12b0000000000000000000000000000000008531197560a096eeaec90e9c0eb6093bc010b7460745354c3c146589d7961cb15640b0d8c55b436871d5c0e2d9b7c320000000000000000000000000000000007ccd070ad13a66af87038b017ea84cab71c9cc4f19fa2406d58e2b46c430584e049e617270778e386a11ffee28f81880000000000000000000000000000000008633c44f58a9feb8c43e5ad4b30b9b4aa7102c4fb75c97f11ec7e52027cda8d0ee58a1b0293865ba15d18dbbaa2c165";
        assertEq(bls.hashToG2(h), expected, "hashToG2 != noble G2.hashToCurve (vec2)");
    }

    /// @dev Two distinct messages must map to distinct points (sanity).
    function test_hashToG2_distinct() public view {
        if (!_has2537()) return;
        bytes memory a = bls.hashToG2(bytes32(uint256(1)));
        bytes memory b = bls.hashToG2(bytes32(uint256(2)));
        assertTrue(keccak256(a) != keccak256(b), "distinct messages mapped equal");
    }
}
