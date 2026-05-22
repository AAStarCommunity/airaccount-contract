// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AgentRegistry — maps agent execution wallets to their human AirAccount owners
/// @notice Any AirAccount owner can register their agent's wallet address.
///         Provides the reverse lookup needed by SuperPaymaster to verify sponsorship eligibility.
contract AgentRegistry {
    /// @dev agentWallet → humanOwner
    mapping(address => address) public agentWalletOwner;
    /// @dev humanOwner → agentWallet[] (for enumeration)
    mapping(address => address[]) public ownerAgents;

    event AgentRegistered(address indexed humanOwner, address indexed agentWallet);
    event AgentDeregistered(address indexed humanOwner, address indexed agentWallet);

    error NotAgentOwner();
    error AgentAlreadyRegistered();
    error InvalidAddress();

    /// @notice Register msg.sender as the owner of agentWallet.
    ///         Called by AirAccount.setAgentWallet() on behalf of the account owner.
    function registerAgent(address agentWallet) external {
        if (agentWallet == address(0)) revert InvalidAddress();
        if (agentWalletOwner[agentWallet] != address(0)) revert AgentAlreadyRegistered();
        agentWalletOwner[agentWallet] = msg.sender;
        ownerAgents[msg.sender].push(agentWallet);
        emit AgentRegistered(msg.sender, agentWallet);
    }

    /// @notice Deregister an agent wallet. Only the original registrant can deregister.
    function deregisterAgent(address agentWallet) external {
        if (agentWalletOwner[agentWallet] != msg.sender) revert NotAgentOwner();
        agentWalletOwner[agentWallet] = address(0);
        // Remove from ownerAgents array (swap-and-pop)
        address[] storage agents = ownerAgents[msg.sender];
        uint256 len = agents.length;
        for (uint256 i = 0; i < len; i++) {
            if (agents[i] == agentWallet) {
                agents[i] = agents[len - 1];
                agents.pop();
                break;
            }
        }
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

    /// @notice ERC-721-compatible stub required by IAgentIdentityRegistry.
    ///         Always returns address(0) — AgentRegistry does not use token IDs.
    function ownerOf(uint256 /* agentId */) external pure returns (address) {
        return address(0);
    }

    /// @notice Alias for deregisterAgent — matches IAgentIdentityRegistry.revokeAgent(address).
    function revokeAgent(address agentWallet) external {
        if (agentWalletOwner[agentWallet] != msg.sender) revert NotAgentOwner();
        agentWalletOwner[agentWallet] = address(0);
        address[] storage agents = ownerAgents[msg.sender];
        uint256 len = agents.length;
        for (uint256 i = 0; i < len; i++) {
            if (agents[i] == agentWallet) {
                agents[i] = agents[len - 1];
                agents.pop();
                break;
            }
        }
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

    /// @notice Returns agentWallets[index] for a given owner (for enumeration).
    function getAgentByIndex(address owner, uint256 index) external view returns (address) {
        return ownerAgents[owner][index];
    }

    /// @notice Returns count of agent wallets registered by this owner.
    function getAgentCount(address owner) external view returns (uint256) {
        return ownerAgents[owner].length;
    }
}
