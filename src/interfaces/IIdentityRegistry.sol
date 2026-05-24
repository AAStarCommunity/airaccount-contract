// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IIdentityRegistry — ERC-8004 Agent Identity Registry interface
/// @notice Minimal interface for minting and querying agent identity NFTs.
///         Each NFT represents an on-chain agent identity owned by a human AirAccount.
interface IIdentityRegistry {
    /// @notice Emitted when an agent identity NFT is minted.
    event AgentIdentityRegistered(uint256 indexed agentId, address indexed owner, string agentURI);

    /// @notice Mint a new agent identity NFT to the caller.
    /// @param agentURI Metadata URI describing the agent (name, description, capabilities)
    /// @return agentId The newly minted NFT token ID (on-chain agent identity)
    function register(string calldata agentURI) external returns (uint256 agentId);

    /// @notice Returns the human AirAccount that owns this agent identity NFT.
    function ownerOf(uint256 agentId) external view returns (address);

    /// @notice Returns the metadata URI for an agent identity.
    function tokenURI(uint256 agentId) external view returns (string memory);
}
