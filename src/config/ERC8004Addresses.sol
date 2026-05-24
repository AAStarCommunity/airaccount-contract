// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title ERC8004Addresses — Official ERC-8004 "Trustless Agents" contract addresses
/// @notice All contracts are deployed at deterministic addresses via CREATE2 (SAFE Singleton Factory).
///         Mainnet and testnet each share a single address across all supported EVM chains.
///
///         Supported mainnet chains (chain IDs): 1, 10, 137, 8453, 42161, 43114, 56, 534352, ...
///         Supported testnet chains (chain IDs): 11155111, 11155420, 84532, 421614, 80002, ...
///
///         Source: https://github.com/erc-8004/erc-8004-contracts (scripts/addresses.ts)
library ERC8004Addresses {
    // ─── Mainnet (Ethereum, OP Mainnet, Base, Arbitrum, Polygon, etc.) ────────

    address internal constant MAINNET_IDENTITY_REGISTRY   = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant MAINNET_REPUTATION_REGISTRY = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address internal constant MAINNET_VALIDATION_REGISTRY = 0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58;

    // ─── Testnet (Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, etc.) ──

    address internal constant TESTNET_IDENTITY_REGISTRY   = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant TESTNET_REPUTATION_REGISTRY = 0x8004B663056A597Dffe9eCcC1965A193B7388713;
    address internal constant TESTNET_VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    // ─── Per-chain lookup ─────────────────────────────────────────────────────

    /// @notice Return identity registry address for the given chain.
    function identityRegistry(uint256 chainId) internal pure returns (address) {
        return _isMainnet(chainId) ? MAINNET_IDENTITY_REGISTRY : TESTNET_IDENTITY_REGISTRY;
    }

    /// @notice Return reputation registry address for the given chain.
    function reputationRegistry(uint256 chainId) internal pure returns (address) {
        return _isMainnet(chainId) ? MAINNET_REPUTATION_REGISTRY : TESTNET_REPUTATION_REGISTRY;
    }

    /// @notice Return validation registry address for the given chain.
    function validationRegistry(uint256 chainId) internal pure returns (address) {
        return _isMainnet(chainId) ? MAINNET_VALIDATION_REGISTRY : TESTNET_VALIDATION_REGISTRY;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _isMainnet(uint256 chainId) private pure returns (bool) {
        return
            chainId == 1       ||  // Ethereum
            chainId == 10      ||  // OP Mainnet
            chainId == 137     ||  // Polygon
            chainId == 8453    ||  // Base
            chainId == 42161   ||  // Arbitrum One
            chainId == 43114   ||  // Avalanche
            chainId == 56      ||  // BSC
            chainId == 534352  ||  // Scroll
            chainId == 100     ||  // Gnosis
            chainId == 42220   ||  // Celo
            chainId == 59144   ||  // Linea
            chainId == 5000    ||  // Mantle
            chainId == 167000  ||  // Taiko
            chainId == 360;        // Shape
    }
}
