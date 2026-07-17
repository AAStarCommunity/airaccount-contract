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
        return _buildShieldCalldataN(token, amount, 1);
    }

    /// @dev H4/#194: build shield() calldata with an explicit ShieldRequest[] length `n` (was implicitly 0
    ///      via all-zero padding). Real Railgun calldata carries the array length at [32:64] in data[4:].
    function _buildShieldCalldataN(address token, uint256 amount, uint256 n) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RAILGUN_SHIELD,
            uint256(0x20),                            // [0:32]    array pointer
            n,                                        // [32:64]   array length
            new bytes(64),                            // [64:128]  npk + tokenType
            bytes32(uint256(uint160(token))),          // [128:160] tokenAddress
            new bytes(32),                            // [160:192] tokenSubID
            bytes32(amount),                          // [192:224] amount
            new bytes(128)                            // tail to reach 352-byte min
        );
    }

    /// @dev Build minimal transact() calldata with valid token+amount at correct offsets.
    ///      data[4:] layout: 544B padding | tokenAddress(32) | 32B padding | amount(32) | 320B tail padding
    ///      Total: 4 + 960 = 964 bytes.
    function _buildTransactCalldata(address token, uint256 amount) internal pure returns (bytes memory) {
        return _buildTransactCalldataN(token, amount, 1);
    }

    /// @dev H4/#194: build transact() calldata with an explicit Transaction[] length `n`.
    function _buildTransactCalldataN(address token, uint256 amount, uint256 n) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RAILGUN_TRANSACT,
            uint256(0x20),                            // [0:32]    array pointer
            n,                                        // [32:64]   array length
            new bytes(480),                           // [64:544]  tx fields before tokenAddress
            bytes32(uint256(uint160(token))),          // [544:576] tokenAddress
            new bytes(32),                            // [576:608] tokenSubID
            bytes32(amount),                          // [608:640] amount
            new bytes(320)                            // tail to reach 960-byte min
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

    // H4/#194: the parser only meters the FIRST array element, so a multi-request shield() must NOT
    // return a partial result (else the extra requests move tokens unmetered). Returns (0,0) → the
    // guard fails closed on a registered parser returning nothing.
    function test_shield_multiElement_returnsZero() public view {
        bytes memory data = _buildShieldCalldataN(TOKEN_USDT, 500e18, 2);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0), "multi-element shield must not be partially metered");
        assertEq(amt, 0);
    }

    function test_transact_multiElement_returnsZero() public view {
        bytes memory data = _buildTransactCalldataN(TOKEN_USDT, 500e18, 2);
        (address tok, uint256 amt) = parser.parseTokenTransfer(data);
        assertEq(tok, address(0), "multi-element transact must not be partially metered");
        assertEq(amt, 0);
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
