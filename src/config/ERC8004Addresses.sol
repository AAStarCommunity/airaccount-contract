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
    /// @dev Reverts when queried for a chain that has no known official ERC-8004 deployment.
    ///      Prevents silently returning testnet addresses on an unsupported chain.
    error UnsupportedChain(uint256 chainId);

    // ─── Mainnet (Ethereum, OP Mainnet, Base, Arbitrum, Polygon, etc.) ────────

    address internal constant MAINNET_IDENTITY_REGISTRY   = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant MAINNET_REPUTATION_REGISTRY = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
    address internal constant MAINNET_VALIDATION_REGISTRY = 0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58;

    // ─── Testnet (Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, etc.) ──

    address internal constant TESTNET_IDENTITY_REGISTRY   = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant TESTNET_REPUTATION_REGISTRY = 0x8004B663056A597Dffe9eCcC1965A193B7388713;
    address internal constant TESTNET_VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    // ─── Per-chain lookup ─────────────────────────────────────────────────────

    /// @notice Return identity registry address for the given chain. Reverts on unsupported chains.
    function identityRegistry(uint256 chainId) internal pure returns (address) {
        if (_isMainnet(chainId)) return MAINNET_IDENTITY_REGISTRY;
        if (_isTestnet(chainId)) return TESTNET_IDENTITY_REGISTRY;
        revert UnsupportedChain(chainId);
    }

    /// @notice Return reputation registry address for the given chain. Reverts on unsupported chains.
    function reputationRegistry(uint256 chainId) internal pure returns (address) {
        if (_isMainnet(chainId)) return MAINNET_REPUTATION_REGISTRY;
        if (_isTestnet(chainId)) return TESTNET_REPUTATION_REGISTRY;
        revert UnsupportedChain(chainId);
    }

    /// @notice Return validation registry address for the given chain. Reverts on unsupported chains.
    function validationRegistry(uint256 chainId) internal pure returns (address) {
        if (_isMainnet(chainId)) return MAINNET_VALIDATION_REGISTRY;
        if (_isTestnet(chainId)) return TESTNET_VALIDATION_REGISTRY;
        revert UnsupportedChain(chainId);
    }

    /// @notice True when the chain has a known official ERC-8004 deployment (mainnet or testnet).
    function isSupported(uint256 chainId) internal pure returns (bool) {
        return _isMainnet(chainId) || _isTestnet(chainId);
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

    function _isTestnet(uint256 chainId) private pure returns (bool) {
        return
            chainId == 11155111 ||  // Ethereum Sepolia
            chainId == 11155420 ||  // OP Sepolia
            chainId == 84532    ||  // Base Sepolia
            chainId == 421614   ||  // Arbitrum Sepolia
            chainId == 80002;       // Polygon Amoy
    }
}
