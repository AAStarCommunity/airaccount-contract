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

    /// @dev EIP-1167 minimal-proxy prefix (10 bytes) — runtime code emitted by OZ Clones.
    ///      Layout: prefix(10) + implementation(20) + suffix(15) = 45 bytes total.
    bytes10 internal constant EIP1167_PREFIX = hex"363d3d373d3d3d363d73";
    bytes15 internal constant EIP1167_SUFFIX = hex"5af43d82803e903d91602b57fd5bf3";

    /// @dev v0.17.2 H-2 fix: AirAccount implementation that valid callers must be a clone of.
    ///      Set in constructor to factory.implementation(). Replaces the v0.17.1
    ///      accountId() prefix-string check, which was forgeable by any contract returning
    ///      a string starting with "airaccount." — see Codex pre-release H-2 finding.
    address public immutable airAccountImplementation;

    /// @dev Pre-computed extcodehash of a valid EIP-1167 clone of airAccountImplementation.
    ///      Compared against extcodehash(msg.sender) in registerAgent for O(1) verification.
    bytes32 public immutable validCloneCodeHash;

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
    /// @dev v0.17.2: msg.sender is not an EIP-1167 clone of the bound AirAccount implementation.
    error CallerNotAirAccount();

    /// @param _airAccountImplementation The AirAccount V7 implementation address (factory.implementation()).
    ///         All valid callers of registerAgent must be EIP-1167 clones of this contract.
    constructor(address _airAccountImplementation) {
        if (_airAccountImplementation == address(0)) revert InvalidAddress();
        airAccountImplementation = _airAccountImplementation;
        validCloneCodeHash = keccak256(abi.encodePacked(
            EIP1167_PREFIX,
            _airAccountImplementation,
            EIP1167_SUFFIX
        ));
    }

    /// @notice Register msg.sender (AirAccount clone) as the human owner of agentWallet.
    ///         agentWalletSig proves the caller controls agentWallet, preventing front-run griefing.
    ///         Supports both EOA (ECDSA) and smart-contract (ERC-1271) agent wallets.
    /// @param agentWallet The agent's wallet address (EOA or smart contract)
    /// @param agentWalletSig Signature from agentWallet over:
    ///        keccak256(abi.encodePacked("REGISTER_AGENT", chainId, address(this), msg.sender, agentWallet)).toEthSignedMessageHash()
    function registerAgent(address agentWallet, bytes calldata agentWalletSig) external {
        // v0.17.2 H-2 fix: only EIP-1167 clones of the bound implementation may register.
        // Verifies msg.sender's runtime code is exactly the EIP-1167 minimal proxy pointing at
        // airAccountImplementation. Cannot be forged: an attacker cannot produce a contract
        // whose extcodehash matches without deploying the canonical clone (which only the factory
        // can do via Clones.cloneDeterministic / clone). Constant-gas check via extcodehash.
        bytes32 callerCodeHash;
        assembly { callerCodeHash := extcodehash(caller()) }
        if (callerCodeHash != validCloneCodeHash) revert CallerNotAirAccount();

        if (agentWallet == address(0)) revert InvalidAddress();
        if (agentWallet == msg.sender) revert SelfRegistrationForbidden();
        if (agentWalletOwner[agentWallet] != address(0)) revert AgentAlreadyRegistered();

        // HIGH-2: Verify agentWallet signed acceptance — supports EOA (ECDSA) and smart contract (ERC-1271).
        // Prevents front-run griefing by requiring the agent's explicit consent.
        bytes32 hash = keccak256(
            abi.encodePacked("REGISTER_AGENT", block.chainid, address(this), msg.sender, agentWallet)
        ).toEthSignedMessageHash();

        bool sigValid;
        uint256 codeSize;
        assembly { codeSize := extcodesize(agentWallet) }
        if (codeSize == 0) {
            // EOA: ECDSA recovery
            sigValid = (ECDSA.recover(hash, agentWalletSig) == agentWallet);
        } else {
            // Smart contract: ERC-1271
            (bool callOk, bytes memory result) = agentWallet.staticcall(
                abi.encodeWithSignature("isValidSignature(bytes32,bytes)", hash, agentWalletSig)
            );
            sigValid = callOk && result.length >= 32 && bytes4(result) == bytes4(0x1626ba7e);
        }
        if (!sigValid) revert InvalidAgentSignature();

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
        // LOW-1: overflow-safe bounds check — avoids start+count wraparound.
        if (start >= total || count == 0) return new address[](0);
        uint256 remaining = total - start; // safe: start < total
        uint256 size = count > remaining ? remaining : count;
        page = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            page[i] = all[start + i];
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
