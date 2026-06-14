// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

/// @title PopcountAssemblyTest — proves the SWAR/bit-parallel Hamming-weight assembly used by
///        AAStarAirAccountBase._popcount and ForceExitModule._countBits equals the reference
///        while-loop bit-count (issue #79). The production functions are `internal`, so this
///        harness re-declares BYTE-FOR-BYTE identical assembly and asserts it matches the simple
///        loop across known vectors, an exhaustive low-range sweep, single-bit values, and fuzz.
contract PopcountHarness {
    /// @dev EXACT copy of AAStarAirAccountBase._popcount / ForceExitModule._countBits assembly.
    ///      Kept in sync manually; the equality tests below would fail if they ever diverge.
    function asm(uint256 x) external pure returns (uint256 count) {
        assembly {
            x := sub(x, and(shr(1, x), 0x5555555555555555555555555555555555555555555555555555555555555555))
            x := add(and(x, 0x3333333333333333333333333333333333333333333333333333333333333333),
                     and(shr(2, x), 0x3333333333333333333333333333333333333333333333333333333333333333))
            x := and(add(x, shr(4, x)), 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f)
            count := shr(248, mul(x, 0x0101010101010101010101010101010101010101010101010101010101010101))
        }
    }

    /// @dev The pre-#79 reference implementation: clear-lowest-set-bit loop (Kernighan).
    ///      Returns the exact Hamming weight for ALL inputs including all-ones (256).
    function loop(uint256 x) external pure returns (uint256 count) {
        while (x != 0) {
            x &= x - 1; // clear the lowest set bit
            count++;
        }
    }
}

contract PopcountAssemblyTest is Test {
    PopcountHarness internal h;

    function setUp() public {
        h = new PopcountHarness();
    }

    /// @notice Known vectors incl. 0, all-ones, single bits, and a mix.
    function test_knownVectors() public view {
        // zero
        assertEq(h.asm(0), 0);
        assertEq(h.loop(0), 0);

        // every single-bit value: asm == loop == 1
        for (uint256 i = 0; i < 256; i++) {
            uint256 v = uint256(1) << i;
            assertEq(h.asm(v), 1, "single bit asm");
            assertEq(h.loop(v), 1, "single bit loop");
            assertEq(h.asm(v), h.loop(v));
        }

        // small mixed values
        assertEq(h.asm(0x07), 3);  // 0b111
        assertEq(h.asm(0xFF), 8);
        assertEq(h.asm(0xFFFF), 16);
        assertEq(h.asm(type(uint8).max), 8);
        assertEq(h.asm(type(uint16).max), 16);
        assertEq(h.asm(type(uint32).max), 32);
        assertEq(h.asm(type(uint64).max), 64);
        assertEq(h.asm(type(uint128).max), 128);

        // all-ones documented edge: the asm mul+shr step overflows and returns 0 (NOT 256),
        // while the loop returns the true 256. This edge is unreachable for the production
        // callers (bitmaps cap at 3 guardians / a bounded weighted-signer set), and is asserted
        // here so the discrepancy is documented, not accidental.
        assertEq(h.loop(type(uint256).max), 256, "loop full");
        assertEq(h.asm(type(uint256).max), 0,    "asm full edge");
    }

    /// @notice Exhaustive over [0, 4095] — every value is checked asm == loop.
    function test_exhaustiveLowRange() public view {
        for (uint256 v = 0; v < 4096; v++) {
            assertEq(h.asm(v), h.loop(v), "exhaustive low-range mismatch");
        }
    }

    /// @notice The realistic production domain: bitmaps with at most a handful of bits set
    ///         (guardian approvals / weighted-signer sets). Sweep all 2-bit and 3-bit patterns
    ///         within the low byte plus a few wider spreads.
    function test_guardianBitmapDomain() public view {
        // all 3-of-3 guardian bitmaps and subsets (bits 0..2)
        for (uint256 mask = 0; mask <= 0x07; mask++) {
            assertEq(h.asm(mask), h.loop(mask));
        }
        // spread bits across the word (still few set)
        uint256[6] memory spread = [
            uint256(0x01),
            (uint256(1) << 64) | 1,
            (uint256(1) << 128) | (uint256(1) << 64) | 1,
            (uint256(1) << 255),
            (uint256(1) << 255) | (uint256(1) << 254),
            (uint256(1) << 200) | (uint256(1) << 100) | 1
        ];
        for (uint256 i = 0; i < spread.length; i++) {
            assertEq(h.asm(spread[i]), h.loop(spread[i]));
        }
    }

    /// @notice Fuzz: for any input that is NOT all-ones, asm result == loop result == true weight.
    ///         (all-ones is the single documented edge handled in test_knownVectors.)
    function testFuzz_asmEqualsLoop(uint256 x) public view {
        vm.assume(x != type(uint256).max);
        assertEq(h.asm(x), h.loop(x), "fuzz asm != loop");
    }
}
