// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IERC8004IdentityRegistry — ERC-8004 "Trustless Agents" Identity Registry
/// @notice Interface matching the official ERC-8004 IdentityRegistryUpgradeable deployed on all chains.
///         Agents register as ERC-721 NFTs; owning the NFT = owning that agent identity.
///         Each identity can bind one `agentWallet` via EIP-712-signed `setAgentWallet()`.
///
/// @dev Official deployments (same address across chains via CREATE2):
///      - Mainnet / OP Mainnet / Base / Arbitrum / ...: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
///      - Sepolia / OP Sepolia / Base Sepolia / ...:     0x8004A818BFB912233c491871b3d84c89A494BD9e
///
///      Source: https://github.com/erc-8004/erc-8004-contracts
///      Spec:   https://eips.ethereum.org/EIPS/eip-8004
interface IERC8004IdentityRegistry is IERC721 {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    // ─── Registration ─────────────────────────────────────────────────────────

    /// @notice Register an agent with no URI (agentWallet defaults to msg.sender).
    function register() external returns (uint256 agentId);

    /// @notice Register an agent with a metadata URI (agentWallet defaults to msg.sender).
    function register(string calldata agentURI) external returns (uint256 agentId);

    /// @notice Register an agent with URI and additional metadata entries.
    function register(string calldata agentURI, MetadataEntry[] calldata metadata)
        external
        returns (uint256 agentId);

    // ─── URI & Metadata ───────────────────────────────────────────────────────

    function setAgentURI(uint256 agentId, string calldata newURI) external;

    function getMetadata(uint256 agentId, string memory metadataKey)
        external
        view
        returns (bytes memory);

    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue)
        external;

    // ─── Agent Wallet binding (EIP-712) ───────────────────────────────────────

    /// @notice Link a wallet address to this agent identity.
    /// @param agentId  The agent NFT token ID.
    /// @param newWallet Address of the execution wallet (EOA or smart contract).
    /// @param deadline  Unix timestamp; must be <= block.timestamp + 5 minutes.
    /// @param signature EIP-712 `AgentWalletSet(uint256,address,address,uint256)` sig from newWallet.
    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /// @notice Returns the wallet currently bound to this agent identity.
    function getAgentWallet(uint256 agentId) external view returns (address);

    /// @notice Clear the wallet binding for this agent identity.
    function unsetAgentWallet(uint256 agentId) external;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);

    function getVersion() external pure returns (string memory);
}
