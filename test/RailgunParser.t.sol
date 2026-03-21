// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {RailgunParser} from "../src/parsers/RailgunParser.sol";

/// @title RailgunParserTest — Unit tests for M7.11 RailgunParser
contract RailgunParserTest is Test {
    RailgunParser public parser;

    /// @dev Railgun V3 transact() selector — matches RailgunParser.RAILGUN_TRANSACT
    bytes4 internal constant RAILGUN_TRANSACT = 0x00f714ce;
    /// @dev Railgun shield() selector — matches RailgunParser.RAILGUN_SHIELD
    bytes4 internal constant RAILGUN_SHIELD = 0x960b850d;

    // Sample token addresses
    address internal constant TOKEN_A = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC mainnet
    address internal constant TOKEN_B = address(0xdAC17F958D2ee523a2206206994597C13D831ec7); // USDT mainnet

    function setUp() public {
        parser = new RailgunParser();
    }

    // ─── Helper: build calldata with selector + padding + (token, amount) ──────
    //
    // RailgunParser strips the 4-byte selector, then passes data[4:] to _parseTransact/_parseShield.
    // _tryDecodeTokenAmount reads at offset 64 within data[4:]:
    //   tok = data[4:][64:96]   = data[68:100]
    //   amt = data[4:][96:128]  = data[100:132]
    //
    // So full calldata layout:
    //   [0:4]    = selector
    //   [4:68]   = 64 bytes of padding (anything)
    //   [68:100] = token address (right-padded to 32 bytes)
    //   [100:132]= amount (uint256)
    //
    // Total minimum length: 132 bytes.
    //
    // NOTE: _parseShield also requires data[4:].length >= 224, so data.length >= 228.
    // We pad accordingly for shield tests.

    function _buildTransactCalldata(address token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RAILGUN_TRANSACT,          // [0:4]   selector
            new bytes(64),             // [4:68]  64-byte padding
            bytes32(uint256(uint160(token))), // [68:100] token address padded to 32 bytes
            bytes32(amount)            // [100:132] amount
        );
    }

    /// @dev Build shield calldata — needs data[4:].length >= 224, i.e. data.length >= 228
    function _buildShieldCalldata(address token, uint256 amount) internal pure returns (bytes memory) {
        // data[4:] must be >= 224 bytes and token at offset 64 within data[4:]
        // Layout of data[4:]:
        //   [0:64]   = 64-byte padding
        //   [64:96]  = token address
        //   [96:128] = amount
        //   [128:224]= 96 more bytes of padding to reach minimum 224 bytes
        return abi.encodePacked(
            RAILGUN_SHIELD,            // [0:4]  selector
            new bytes(64),             // [4:68] 64-byte padding
            bytes32(uint256(uint160(token))), // [68:100] token
            bytes32(amount),           // [100:132] amount
            new bytes(96)              // [132:228] padding to reach 228 total (224 after selector)
        );
    }

    // ─── Test 1: unknown selector returns (address(0), 0) ─────────────────────

    function test_parseTokenTransfer_unknownSelector_returnsZero() public view {
        bytes memory data = abi.encodePacked(
            bytes4(0xDEADBEEF),
            new bytes(128)
        );
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── Test 2: data.length < 4 returns (address(0), 0) ──────────────────────

    function test_parseTokenTransfer_tooShort_returnsZero() public view {
        bytes memory data = new bytes(3);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── Test 3: empty bytes returns (address(0), 0) ──────────────────────────

    function test_parseTokenTransfer_emptyData_returnsZero() public view {
        (address tok, uint256 amt) = parser.parseTokenTransfer(new bytes(0));
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── Test 4: transact selector with valid data returns non-zero ───────────

    function test_parseTokenTransfer_transactSelector_withValidData_returnsNonZero() public view {
        bytes memory data = _buildTransactCalldata(TOKEN_A, 1000e6);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, TOKEN_A);
        assertEq(amt, 1000e6);
    }

    // ─── Test 5: shield selector with valid data returns non-zero ─────────────

    function test_parseTokenTransfer_shieldSelector_withValidData_returnsNonZero() public view {
        bytes memory data = _buildShieldCalldata(TOKEN_B, 500e18);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, TOKEN_B);
        assertEq(amt, 500e18);
    }

    // ─── Test 6: transact selector with zero token returns (address(0), 0) ────

    function test_parseTokenTransfer_transactSelector_zeroToken_returnsZero() public view {
        // Build calldata with address(0) as token
        bytes memory data = abi.encodePacked(
            RAILGUN_TRANSACT,
            new bytes(64),
            bytes32(uint256(0)),     // token = address(0)
            bytes32(uint256(1000e6)) // non-zero amount
        );
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── Test 7: transact selector with zero amount returns (address(0), 0) ───

    function test_parseTokenTransfer_transactSelector_zeroAmount_returnsZero() public view {
        // Build calldata with valid token but zero amount
        bytes memory data = abi.encodePacked(
            RAILGUN_TRANSACT,
            new bytes(64),
            bytes32(uint256(uint160(TOKEN_A))), // valid token
            bytes32(uint256(0))                 // amount = 0
        );
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }
}
