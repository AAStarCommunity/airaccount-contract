// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {RailgunParser} from "../src/parsers/RailgunParser.sol";

/// @title RailgunParserTest — Unit tests for M7.11 RailgunParser (V2.1 correct ABI)
///
/// @dev Calldata layout (verified against Railgun-Community/engine V2.1 ABI):
///
///   shield() selector: 0x044a40c3
///     data[4:][128:160] = tokenAddress
///     data[4:][192:224] = amount
///     minimum data[4:] length: 352 bytes → total calldata: 356 bytes
///
///   transact() selector: 0xd8ae136a
///     data[4:][544:576] = tokenAddress
///     data[4:][608:640] = amount
///     minimum data[4:] length: 960 bytes → total calldata: 964 bytes
contract RailgunParserTest is Test {
    RailgunParser public parser;

    /// @dev Railgun V2.1 selectors (verified against deployed contracts)
    bytes4 internal constant RAILGUN_SHIELD   = 0x044a40c3;
    bytes4 internal constant RAILGUN_TRANSACT = 0xd8ae136a;

    address internal constant TOKEN_USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant TOKEN_USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    function setUp() public {
        parser = new RailgunParser();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    /// @dev Build minimal shield() calldata with valid token+amount at correct offsets.
    ///      data[4:] layout: 128B padding | tokenAddress(32) | 32B padding | amount(32) | 160B tail padding
    ///      Total: 4 + 352 = 356 bytes.
    function _buildShieldCalldata(address token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RAILGUN_SHIELD,
            new bytes(128),                           // [4:132]   padding (ABI ptr + len + npk + tokenType)
            bytes32(uint256(uint160(token))),          // [132:164]  tokenAddress  (offset 128 in data[4:])
            new bytes(32),                            // [164:196]  tokenSubID
            bytes32(amount),                          // [196:228]  amount         (offset 192 in data[4:])
            new bytes(160)                            // [228:388]  ShieldCiphertext tail to reach 352-byte min
        );
    }

    /// @dev Build minimal transact() calldata with valid token+amount at correct offsets.
    ///      data[4:] layout: 544B padding | tokenAddress(32) | 32B padding | amount(32) | 320B tail padding
    ///      Total: 4 + 960 = 964 bytes.
    function _buildTransactCalldata(address token, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RAILGUN_TRANSACT,
            new bytes(544),                           // [4:548]   padding (SnarkProof + merkleRoot + offsets + npk + tokenType)
            bytes32(uint256(uint160(token))),          // [548:580]  tokenAddress  (offset 544 in data[4:])
            new bytes(32),                            // [580:612]  tokenSubID
            bytes32(amount),                          // [612:644]  amount         (offset 608 in data[4:])
            new bytes(320)                            // [644:964]  tail to reach 960-byte min
        );
    }

    // ─── Selector dispatch ────────────────────────────────────────────────────────

    function test_unknownSelector_returnsZero() public view {
        bytes memory data = abi.encodePacked(bytes4(0xDEADBEEF), new bytes(1000));
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_tooShort_returnsZero() public view {
        (address tok, uint256 amt) = parser.parseTokenTransfer(new bytes(3));
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_emptyData_returnsZero() public view {
        (address tok, uint256 amt) = parser.parseTokenTransfer(new bytes(0));
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── shield() ────────────────────────────────────────────────────────────────

    function test_shield_validData_parsesCorrectly() public view {
        bytes memory data = _buildShieldCalldata(TOKEN_USDT, 500e18);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, TOKEN_USDT);
        assertEq(amt, 500e18);
    }

    function test_shield_zeroToken_returnsZero() public view {
        bytes memory data = _buildShieldCalldata(address(0), 500e18);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_shield_zeroAmount_returnsZero() public view {
        bytes memory data = _buildShieldCalldata(TOKEN_USDT, 0);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_shield_insufficientData_returnsZero() public view {
        // 355 bytes total = 1 byte short of the 356-byte minimum
        bytes memory data = abi.encodePacked(RAILGUN_SHIELD, new bytes(351));
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    // ─── transact() ──────────────────────────────────────────────────────────────

    function test_transact_validData_parsesCorrectly() public view {
        bytes memory data = _buildTransactCalldata(TOKEN_USDC, 1000e6);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, TOKEN_USDC);
        assertEq(amt, 1000e6);
    }

    function test_transact_zeroToken_returnsZero() public view {
        bytes memory data = _buildTransactCalldata(address(0), 1000e6);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_transact_zeroAmount_returnsZero() public view {
        bytes memory data = _buildTransactCalldata(TOKEN_USDC, 0);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }

    function test_transact_insufficientData_returnsZero() public view {
        // 963 bytes total = 1 byte short of the 964-byte minimum
        bytes memory data = abi.encodePacked(RAILGUN_TRANSACT, new bytes(959));
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0));
        assertEq(amt, 0);
    }
}
