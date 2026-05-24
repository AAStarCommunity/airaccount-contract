// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title IdentityRegistry — Agent identity NFT registry
/// @notice Each NFT represents an on-chain agent identity bound to a human AirAccount.
///         The NFT owner is the human AirAccount that registered the agent.
///         Token IDs start at 1; ID 0 is reserved as "unregistered".
///
///         STANDARD NOTE: "ERC-8004" is an internal AAstar draft standard for agent identity
///         and is NOT an official EIP. External integrators should depend on `IIdentityRegistry`
///         rather than this implementation directly.
///
///         RECOVERY NOTE: If the human AirAccount undergoes social recovery to a new address,
///         the agentId NFT becomes stranded (non-transferable). A future `migrate(agentId, newOwner)`
///         function — callable only via the social recovery flow — will handle re-assignment.
///
/// @dev Non-transferable by design: once an agent identity is minted to a human
///      AirAccount, it should not be tradeable. Transfer functions are disabled.
///      If the human wants to re-assign, they must burn and re-register.
contract IdentityRegistry is ERC721, IIdentityRegistry {
    uint256 private _nextTokenId;
    mapping(uint256 => string) private _agentURIs;

    error TransferNotAllowed();
    error TokenDoesNotExist(uint256 agentId);

    constructor() ERC721("AirAccount Agent Identity", "AAID") {
        _nextTokenId = 1;
    }

    /// @inheritdoc IIdentityRegistry
    /// @param agentURI Metadata URI for agent identity.
    ///        Recommended format: `ipfs://<CID>` (content-addressed) or `did:web:<domain>` (DID).
    ///        Suggested metadata schema: { "name": string, "description": string,
    ///          "agentKey": address (hex), "capabilities": string[] }
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _nextTokenId++;
        _mint(msg.sender, agentId);
        _agentURIs[agentId] = agentURI;
        emit AgentIdentityRegistered(agentId, msg.sender, agentURI);
    }

    /// @inheritdoc IIdentityRegistry
    function ownerOf(uint256 agentId) public view override(ERC721, IIdentityRegistry) returns (address) {
        return super.ownerOf(agentId);
    }

    /// @inheritdoc IIdentityRegistry
    function tokenURI(uint256 agentId) public view override(ERC721, IIdentityRegistry) returns (string memory) {
        _requireOwned(agentId);
        return _agentURIs[agentId];
    }

    /// @notice Burn an agent identity NFT (only the owner can burn).
    function burn(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert TransferNotAllowed();
        delete _agentURIs[agentId];
        _burn(agentId);
    }

    // ─── Non-transferable ────────────────────────────────────────────────────

    function transferFrom(address, address, uint256) public pure override {
        revert TransferNotAllowed();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert TransferNotAllowed();
    }

    function approve(address, uint256) public pure override {
        revert TransferNotAllowed();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert TransferNotAllowed();
    }
}
