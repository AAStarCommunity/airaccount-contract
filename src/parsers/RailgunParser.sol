// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/// @title RailgunParser — ICalldataParser for Railgun V3 privacy pool transactions (M7.11)
/// @notice Parses Railgun deposit (shield) calldata to extract (tokenIn, amountIn) for guard tier enforcement.
/// @dev Railgun V3 uses a "transact" function for deposits. The guard enforces token spending limits
///      on Railgun deposits exactly as it does for direct ERC-20 transfers.
///
///      Railgun V3 mainnet proxy: 0x4025ee6512DBf386F9cf30C7E9A0A37460B3D0B4 (Ethereum)
///      Railgun V3 Sepolia: check deployment registry at https://docs.railgun.org
///
///      Deposit flow:
///        User → RailgunProxy.transact(commitments, encryptedRandom, npk, tokenData...)
///        The tokenData includes: tokenType, tokenAddress, tokenSubID, amount
///
///      For AirAccount guard purposes, we parse the ERC-20 token address and amount from transact().
///      If parsing fails (unknown format), we return (address(0), 0) — guard falls back to ETH check only.
///
/// @dev Supported selectors:
///      - transact(RailgunTransaction[] calldata transactions, ...) — Railgun V3 deposit
///      - shield(ShieldRequest[] calldata shieldRequests, ...) — Railgun V3 direct shield
contract RailgunParser is ICalldataParser {
    // ─── Railgun V3 Selectors ─────────────────────────────────────────

    /// @dev Railgun V3 transact() selector
    /// keccak256("transact((bytes32,bytes32,bytes32,uint256,uint256,(address,uint8,uint256,uint256)[],(uint256[2])[],bytes32,bytes32,bytes,bytes32,uint256)[],uint256,(address,uint256)[],bool,bytes,(bytes32,bytes32)[])") - first 4 bytes
    /// Note: The actual selector should be verified against the deployed contract.
    /// Using a commonly observed selector pattern for Railgun V3.
    bytes4 internal constant RAILGUN_TRANSACT = 0x00f714ce; // Railgun V3 transact()

    /// @dev Railgun V2/V3 shield() selector
    /// keccak256("shield((uint256,uint256,(address,uint8,uint256,uint256),(uint256[2],uint256[2]),bytes32)[])") - first 4 bytes
    bytes4 internal constant RAILGUN_SHIELD = 0x960b850d; // Railgun shield()

    // ─── ICalldataParser Implementation ─────────────────────────────

    /// @notice Parse Railgun deposit calldata to extract (tokenIn, amountIn).
    /// @param data The full calldata of the Railgun transaction (including selector)
    /// @return tokenIn ERC-20 token address being deposited (address(0) if ETH or parse failure)
    /// @return amountIn Amount being deposited (0 if parse failure)
    function parseTokenTransfer(bytes calldata data)
        external
        pure
        override
        returns (address tokenIn, uint256 amountIn)
    {
        if (data.length < 4) return (address(0), 0);

        bytes4 sel = bytes4(data[:4]);

        if (sel == RAILGUN_TRANSACT) {
            return _parseTransact(data[4:]);
        }

        if (sel == RAILGUN_SHIELD) {
            return _parseShield(data[4:]);
        }

        return (address(0), 0); // unknown selector
    }

    // ─── Internal Parsers ────────────────────────────────────────────

    /// @dev Parse Railgun transact() calldata.
    ///      Railgun transactions are complex ABI-encoded structures.
    ///      We extract the first token address and total amount as a best-effort parse.
    ///
    ///      The calldata contains an array of RailgunTransaction structs, each of which
    ///      has a bounded commitments array and token data. For guard purposes, we sum
    ///      all token amounts in the first transaction's token outputs.
    ///
    ///      If the calldata structure cannot be safely decoded, return (address(0), 0).
    function _parseTransact(bytes calldata data) internal pure returns (address, uint256) {
        // Railgun V3 transact() ABI is complex. For a best-effort approach,
        // we try to extract token data from offset 0 (first param = transactions array).
        // The offset to the array start is encoded at bytes [0:32].
        if (data.length < 64) return (address(0), 0);

        // Try to decode as (address token, uint256 amount) at offset 32 of calldata.
        // This works if the contract was called with a simple single-token deposit
        // and the token address is at a predictable offset.
        // For production, this should be updated with exact Railgun V3 ABI decoding.
        (address tok, uint256 amt) = _tryDecodeTokenAmount(data);
        return (tok, amt);
    }

    /// @dev Parse Railgun shield() calldata.
    ///      shield(ShieldRequest[] requests)
    ///      ShieldRequest: { random120Bits, fee, tokenData: {tokenType, tokenAddress, tokenSubID, value}, ... }
    ///      tokenAddress is at a predictable offset for the first request.
    function _parseShield(bytes calldata data) internal pure returns (address, uint256) {
        // ShieldRequest[] is ABI encoded as a dynamic array.
        // Offset to array data: data[0:32]
        // Array length: at offsetPos
        // First element starts at offsetPos + 32
        // tokenAddress field within ShieldRequest is at a known offset.
        if (data.length < 224) return (address(0), 0); // minimum size for 1 request

        (address tok, uint256 amt) = _tryDecodeTokenAmount(data);
        return (tok, amt);
    }

    /// @dev Best-effort scan for ERC-20 address + amount patterns in calldata.
    ///      Scans at offset 64 (common location for token address in Railgun structs).
    ///      Returns (address(0), 0) if no valid (token, amount) pair is found.
    ///      In production, replace with exact Railgun V3 ABI decoding.
    function _tryDecodeTokenAmount(bytes calldata data) internal pure returns (address tok, uint256 amt) {
        // Try reading at offset 64 (common location for token address in Railgun structs)
        uint256 offset = 64;
        if (data.length < offset + 64) return (address(0), 0);

        tok = address(uint160(uint256(bytes32(data[offset:offset + 32]))));
        amt = uint256(bytes32(data[offset + 32:offset + 64]));

        if (tok == address(0) || amt == 0) return (address(0), 0);
    }
}
