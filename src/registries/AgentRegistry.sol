// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title AgentRegistry — maps agent execution wallets to their human AirAccount owners
/// @notice Any AirAccount owner can register their agent's wallet address.
///         Provides the reverse lookup needed by SuperPaymaster to verify sponsorship eligibility.
contract AgentRegistry {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev agentWallet → humanOwner
    mapping(address => address) public agentWalletOwner;
    /// @dev humanOwner → agentWallet[] (for enumeration)
    mapping(address => address[]) public ownerAgents;
    /// @dev owner → agentWallet → index+1 in ownerAgents[owner] (0 = not in array)
    mapping(address => mapping(address => uint256)) private _agentIndexPlusOne;

    event AgentRegistered(address indexed humanOwner, address indexed agentWallet);
    event AgentDeregistered(address indexed humanOwner, address indexed agentWallet);

    error NotAgentOwner();
    error AgentAlreadyRegistered();
    error InvalidAddress();
    error InvalidAgentSignature();
    error SelfRegistrationForbidden();
    error NotSupported();

    /// @notice Register msg.sender (AirAccount) as the human owner of agentWallet.
    ///         agentWalletSig proves the caller controls agentWallet, preventing front-run griefing.
    /// @param agentWallet The agent's EOA address
    /// @param agentWalletSig ECDSA sig from agentWallet over:
    ///        keccak256(abi.encodePacked("REGISTER_AGENT", chainId, address(this), msg.sender, agentWallet)).toEthSignedMessageHash()
    function registerAgent(address agentWallet, bytes calldata agentWalletSig) external {
        if (agentWallet == address(0)) revert InvalidAddress();
        if (agentWallet == msg.sender) revert SelfRegistrationForbidden();
        if (agentWalletOwner[agentWallet] != address(0)) revert AgentAlreadyRegistered();
        // Verify agentWallet signed acceptance — prevents front-run griefing
        bytes32 hash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(this), msg.sender, agentWallet)
        ).toEthSignedMessageHash();
        if (ECDSA.recover(hash, agentWalletSig) != agentWallet) revert InvalidAgentSignature();
        agentWalletOwner[agentWallet] = msg.sender;
        ownerAgents[msg.sender].push(agentWallet);
        _agentIndexPlusOne[msg.sender][agentWallet] = ownerAgents[msg.sender].length;
        emit AgentRegistered(msg.sender, agentWallet);
    }

    /// @notice Deregister an agent wallet. Only the original registrant can deregister.
    function deregisterAgent(address agentWallet) external {
        if (agentWalletOwner[agentWallet] != msg.sender) revert NotAgentOwner();
        agentWalletOwner[agentWallet] = address(0);
        _removeFromOwnerArray(msg.sender, agentWallet);
        emit AgentDeregistered(msg.sender, agentWallet);
    }

    /// @notice Returns true if agentWallet is registered (has any owner).
    function isRegisteredAgent(address agentWallet) external view returns (bool) {
        return agentWalletOwner[agentWallet] != address(0);
    }

    /// @notice Returns count of agent wallets registered by this owner.
    ///         Implements IAgentIdentityRegistry.balanceOf(address) — returns actual count.
    function balanceOf(address humanOwner) external view returns (uint256) {
        return ownerAgents[humanOwner].length;
    }

    /// @notice Not supported — AgentRegistry does not use token IDs.
    ///         Reverts unconditionally. Exists only for IAgentIdentityRegistry interface compatibility.
    function ownerOf(uint256) external pure returns (address) {
        revert NotSupported();
    }

    /// @notice Alias for deregisterAgent — matches IAgentIdentityRegistry.revokeAgent(address).
    function revokeAgent(address agentWallet) external {
        if (agentWalletOwner[agentWallet] != msg.sender) revert NotAgentOwner();
        agentWalletOwner[agentWallet] = address(0);
        _removeFromOwnerArray(msg.sender, agentWallet);
        emit AgentDeregistered(msg.sender, agentWallet);
    }

    /// @notice Convenience lookup: returns the human AirAccount that registered agentWallet.
    ///         Returns address(0) if agentWallet is not registered.
    function getHumanOwner(address agentWallet) external view returns (address) {
        return agentWalletOwner[agentWallet];
    }

    /// @notice Returns all agent wallets registered by a human owner.
    function getAgents(address humanOwner) external view returns (address[] memory) {
        return ownerAgents[humanOwner];
    }

    /// @notice Paginated enumeration of agent wallets for a human owner.
    /// @param start Index to start from (0-based)
    /// @param count Maximum number of entries to return
    function getAgentsPage(address owner, uint256 start, uint256 count)
        external view returns (address[] memory page)
    {
        address[] storage all = ownerAgents[owner];
        uint256 total = all.length;
        if (start >= total) return new address[](0);
        uint256 end = start + count;
        if (end > total) end = total;
        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = all[i];
        }
    }

    /// @notice Returns agentWallets[index] for a given owner (for enumeration).
    function getAgentByIndex(address owner, uint256 index) external view returns (address) {
        return ownerAgents[owner][index];
    }

    /// @notice Returns count of agent wallets registered by this owner.
    function getAgentCount(address owner) external view returns (uint256) {
        return ownerAgents[owner].length;
    }

    /// @dev O(1) swap-and-pop removal using the index mapping.
    function _removeFromOwnerArray(address owner, address agentWallet) private {
        uint256 idxPlusOne = _agentIndexPlusOne[owner][agentWallet];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        address[] storage agents = ownerAgents[owner];
        uint256 last = agents.length - 1;
        if (idx != last) {
            address lastAgent = agents[last];
            agents[idx] = lastAgent;
            _agentIndexPlusOne[owner][lastAgent] = idx + 1;
        }
        agents.pop();
        delete _agentIndexPlusOne[owner][agentWallet];
    }
}
