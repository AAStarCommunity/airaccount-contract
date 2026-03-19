// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title CalldataParserRegistry — Singleton registry mapping DeFi protocols to their parsers
/// @notice Maps destination contract addresses to their corresponding ICalldataParser implementations.
///         Accounts that enable parser support store a reference to this registry.
///         Accounts without a registry reference fall back to native ERC20 transfer parsing.
///
/// @dev Design:
///      - One registry serves all AirAccount instances (gas-efficient, no per-account storage)
///      - Governance: owner manages the registry (should be ProtocolGuard / Safe multisig in prod)
///      - Only-add: parsers can be registered but not removed (monotonic, same principle as guard)
///      - Multiple dest contracts can share one parser (e.g., Uniswap router variants)
///
///      Usage by account:
///        ICalldataParserRegistry(parserRegistry).getParser(dest) → ICalldataParser
contract CalldataParserRegistry {
    // ─── Storage ──────────────────────────────────────────────────────

    /// @notice Registry owner (should be protocol-controlled Safe multisig in production)
    address public owner;

    /// @notice dest contract address → parser contract address (address(0) = no parser)
    mapping(address => address) public parserFor;

    // ─── Events ──────────────────────────────────────────────────────

    event ParserRegistered(address indexed dest, address indexed parser);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Errors ──────────────────────────────────────────────────────

    error OnlyOwner();
    error InvalidAddress();
    error ParserAlreadyRegistered();

    // ─── Constructor ─────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─── Registry Management ─────────────────────────────────────────

    /// @notice Register a parser for a destination contract.
    ///         Only-add: once registered, a parser cannot be replaced (monotonic).
    /// @param dest   The DeFi protocol contract address (e.g., Uniswap V3 SwapRouter)
    /// @param parser The parser contract implementing ICalldataParser
    function registerParser(address dest, address parser) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (dest == address(0) || parser == address(0)) revert InvalidAddress();
        if (parserFor[dest] != address(0)) revert ParserAlreadyRegistered();

        parserFor[dest] = parser;
        emit ParserRegistered(dest, parser);
    }

    /// @notice Look up the parser for a destination contract.
    ///         Returns address(0) if no parser is registered for this dest.
    function getParser(address dest) external view returns (address) {
        return parserFor[dest];
    }

    // ─── Ownership ────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (newOwner == address(0)) revert InvalidAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }
}
