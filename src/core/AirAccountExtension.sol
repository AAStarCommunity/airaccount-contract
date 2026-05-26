// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAgentStorageLayout} from "./AAStarAgentStorageLayout.sol";
import {IAirAccountAgent} from "../interfaces/IAirAccountAgent.sol";
import {IERC8004IdentityRegistry} from "../interfaces/IERC8004IdentityRegistry.sol";
import {IERC8004ReputationRegistry} from "../interfaces/IERC8004ReputationRegistry.sol";
import {ERC8004Addresses} from "../config/ERC8004Addresses.sol";

/// @title AirAccountExtension — cold-function facet for AAStarAirAccountV7 (diamond-lite)
/// @notice Holds the cold, loosely-coupled functions that were split out of AAStarAirAccountBase
///         to keep the account under EIP-170's 24,576-byte runtime limit:
///           - ERC-8004 agent identity / reputation / wallet binding
///           - weighted-signature config governance (setWeightConfig + change proposal flow)
///         Deployed once (singleton) per implementation; the account reaches it via fallback +
///         delegatecall, so all logic runs in the ACCOUNT's storage/context: msg.sender,
///         address(this), owner, guardians, events and reverts are exactly as if inline.
/// @dev This contract is NEVER used as a standalone account — its own storage is irrelevant; it
///      only executes under delegatecall. Errors/events/constants are redeclared here with the
///      SAME signatures as AAStarAirAccountBase, so selectors / topic0 (and therefore on-chain
///      behavior and test expectations) are identical to the previous inline implementation.
contract AirAccountExtension is AAStarAgentStorageLayout, IAirAccountAgent {
    // ─── Constants (mirror AAStarAirAccountBase) ─────────────────────────
    uint256 internal constant WEIGHT_CHANGE_TIMELOCK  = 2 days;
    uint256 internal constant WEIGHT_CHANGE_THRESHOLD = 2;
    uint256 internal constant WEIGHT_CHANGE_EXPIRY    = 30 days;

    // ─── Errors (same signatures/selectors as AAStarAirAccountBase) ──────
    error NotOwner();
    error Reentrancy();
    error InvalidGuardian();
    error NotGuardian();
    error AgentRegistrationFailed();
    error IdentityRegistrationFailed();
    error UnauthorizedRegistry();
    error RecoveryAlreadyActive();
    error InsecureWeightConfig();
    error WeakeningRequiresProposal();
    error WeightChangePending();
    error NoWeightChangeProposal();
    error WeightChangeAlreadyApproved();
    error WeightChangeNotApproved();
    error WeightChangeTimelockNotExpired();

    // ─── Events (same signatures/topic0 as AAStarAirAccountBase) ─────────
    event AgentWalletSet(uint256 indexed agentId, address indexed agentWallet, address agentRegistry);
    event AgentIdentityMinted(uint256 indexed agentId, address indexed identityRegistry, string agentURI);
    event ERC8004WalletBound(uint256 indexed agentId, address indexed agentWallet, address indexed identityRegistry);
    event AgentReputationSubmitted(uint256 indexed agentId, address indexed reputationRegistry, int128 value, string tag1);
    event WeightConfigUpdated(WeightConfig config);
    event WeightChangeProposed(WeightConfig proposed, address indexed proposedBy);
    event WeightChangeApproved(address indexed approvedBy, uint256 approvalCount);
    event WeightChangeExecuted(WeightConfig oldConfig, WeightConfig newConfig);
    event WeightChangeCancelled();

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Reentrancy guard using transient storage (EIP-1153) — slot 0 matches the account's guard,
    ///      so reentrancy state is shared correctly across the fallback boundary.
    modifier nonReentrant() {
        assembly {
            if tload(0) {
                mstore(0, 0xab143c06) // Reentrancy() selector
                revert(0x1c, 4)
            }
            tstore(0, 1)
        }
        _;
        assembly {
            tstore(0, 0)
        }
    }

    // ─── Shared guardian/bit helpers (mirror AAStarAirAccountBase) ───────

    function _getGuardian(uint8 i) private view returns (address) {
        if (i == 0) return _guardian0;
        if (i == 1) return _guardian1;
        return _guardian2;
    }

    function _guardianIndex(address addr) private view returns (uint8) {
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == addr) return i;
        }
        revert NotGuardian();
    }

    function _popcount(uint256 x) private pure returns (uint256 count) {
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }

    // ─── ERC-8004 Agent Identity Binding (M7.16) ─────────────────────────

    /// @notice Link an agent wallet to this AirAccount by registering it in AgentRegistry.
    function setAgentWallet(
        uint256 agentId,
        address agentWallet,
        address agentRegistry,
        bytes calldata agentWalletSig
    ) external onlyOwner {
        if (agentWallet == address(0) || agentRegistry == address(0)) revert InvalidGuardian();
        uint256 codeSize;
        assembly { codeSize := extcodesize(agentRegistry) }
        if (codeSize == 0) revert AgentRegistrationFailed();
        (bool ok,) = agentRegistry.call(
            abi.encodeWithSignature("registerAgent(address,bytes)", agentWallet, agentWalletSig)
        );
        if (!ok) revert AgentRegistrationFailed();
        emit AgentWalletSet(agentId, agentWallet, agentRegistry);
    }

    /// @dev Pin a registry argument to the official ERC-8004 deployment for this chain.
    function _requireOfficialIdentityRegistry(address r) private view {
        if (r != ERC8004Addresses.identityRegistry(block.chainid)) revert UnauthorizedRegistry();
    }

    function _requireOfficialReputationRegistry(address r) private view {
        if (r != ERC8004Addresses.reputationRegistry(block.chainid)) revert UnauthorizedRegistry();
    }

    /// @notice Mint an ERC-8004 agent identity NFT to this AirAccount via the official registry.
    function mintAgentIdentity(
        address identityRegistry,
        string calldata agentURI
    ) external onlyOwner nonReentrant returns (uint256 agentId) {
        _requireOfficialIdentityRegistry(identityRegistry);
        agentId = IERC8004IdentityRegistry(identityRegistry).register(agentURI);
        emit AgentIdentityMinted(agentId, identityRegistry, agentURI);
    }

    /// @notice Bind an execution wallet to an ERC-8004 agent identity NFT.
    function bindERC8004AgentWallet(
        address identityRegistry,
        uint256 agentId,
        address agentWallet,
        uint256 deadline,
        bytes calldata signature
    ) external onlyOwner nonReentrant {
        _requireOfficialIdentityRegistry(identityRegistry);
        if (agentWallet == address(0)) revert IdentityRegistrationFailed();
        IERC8004IdentityRegistry(identityRegistry).setAgentWallet(agentId, agentWallet, deadline, signature);
        emit ERC8004WalletBound(agentId, agentWallet, identityRegistry);
    }

    /// @notice Submit reputation feedback for an agent interaction via the official registry.
    function submitAgentReputation(
        address reputationRegistry,
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external onlyOwner nonReentrant {
        _requireOfficialReputationRegistry(reputationRegistry);
        IERC8004ReputationRegistry(reputationRegistry).giveFeedback(
            agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash
        );
        emit AgentReputationSubmitted(agentId, reputationRegistry, value, tag1);
    }

    /// @notice Query aggregated reputation for an agent across a set of clients.
    function queryAgentReputation(
        address reputationRegistry,
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryDecimals) {
        _requireOfficialReputationRegistry(reputationRegistry);
        return IERC8004ReputationRegistry(reputationRegistry).getSummary(
            agentId, clientAddresses, tag1, tag2
        );
    }

    // ─── Weighted Signature Management (M6.1 + M6.2) ─────────────────────

    /// @notice Set the weight configuration for algId 0x07. First-time: direct owner call.
    ///         Subsequent weakening changes require the guardian proposal flow (M6.2).
    function setWeightConfig(WeightConfig calldata config) external onlyOwner {
        _validateWeightConfig(config);

        WeightConfig memory current = weightConfig;
        if (current.tier1Threshold != 0 && _isWeakening(current, config)) {
            revert WeakeningRequiresProposal();
        }
        if (pendingWeightChange.proposedAt != 0) revert WeightChangePending();

        weightConfig = config;
        emit WeightConfigUpdated(config);
    }

    /// @notice Propose a weakening weight-config change (guardian-gated, M6.2).
    function proposeWeightChange(WeightConfig calldata proposed) external onlyOwner {
        _validateWeightConfig(proposed);
        if (!_isWeakening(weightConfig, proposed)) revert WeakeningRequiresProposal();
        if (pendingWeightChange.proposedAt != 0) revert WeightChangePending();
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();

        pendingWeightChange = WeightChangeProposal({
            proposed: proposed,
            proposedAt: block.timestamp,
            approvalBitmap: 0
        });
        emit WeightChangeProposed(proposed, msg.sender);
    }

    /// @notice Guardian approves the pending weight-change proposal.
    function approveWeightChange() external {
        if (pendingWeightChange.proposedAt == 0) revert NoWeightChangeProposal();
        if (block.timestamp > pendingWeightChange.proposedAt + WEIGHT_CHANGE_EXPIRY) revert NoWeightChangeProposal();

        uint8 guardianIndex = _guardianIndex(msg.sender);
        uint256 bit = uint256(1) << guardianIndex;
        if (pendingWeightChange.approvalBitmap & bit != 0) revert WeightChangeAlreadyApproved();

        pendingWeightChange.approvalBitmap |= bit;
        uint256 count = _popcount(pendingWeightChange.approvalBitmap);
        emit WeightChangeApproved(msg.sender, count);
    }

    /// @notice Execute an approved weight-change after timelock and threshold are met.
    function executeWeightChange() external {
        WeightChangeProposal memory p = pendingWeightChange;
        if (p.proposedAt == 0) revert NoWeightChangeProposal();
        if (block.timestamp > p.proposedAt + WEIGHT_CHANGE_EXPIRY) revert NoWeightChangeProposal();
        if (_popcount(p.approvalBitmap) < WEIGHT_CHANGE_THRESHOLD) revert WeightChangeNotApproved();
        if (block.timestamp < p.proposedAt + WEIGHT_CHANGE_TIMELOCK) revert WeightChangeTimelockNotExpired();

        WeightConfig memory oldConfig = weightConfig;
        weightConfig = p.proposed;
        delete pendingWeightChange;
        emit WeightChangeExecuted(oldConfig, p.proposed);
        emit WeightConfigUpdated(p.proposed);
    }

    /// @notice Cancel a pending weight-change proposal. Owner or any guardian can cancel.
    function cancelWeightChange() external {
        if (pendingWeightChange.proposedAt == 0) revert NoWeightChangeProposal();
        if (msg.sender != owner) {
            _guardianIndex(msg.sender);
        }
        delete pendingWeightChange;
        emit WeightChangeCancelled();
    }

    /// @dev Validate that a WeightConfig is internally consistent and secure.
    function _validateWeightConfig(WeightConfig calldata config) private pure {
        if (config.tier1Threshold == 0) revert InsecureWeightConfig();
        if (config.passkeyWeight   >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.ecdsaWeight     >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.blsWeight       >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian0Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian1Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.guardian2Weight >= config.tier1Threshold) revert InsecureWeightConfig();
        if (config.tier2Threshold != 0 && config.tier2Threshold < config.tier1Threshold) revert InsecureWeightConfig();
        if (config.tier3Threshold != 0 && config.tier3Threshold < config.tier2Threshold) revert InsecureWeightConfig();
        if (config.tier3Threshold != 0 && config.tier2Threshold == 0) revert InsecureWeightConfig();
    }

    /// @dev Returns true if proposed config is a weakening of current config.
    function _isWeakening(WeightConfig memory current, WeightConfig memory proposed) private pure returns (bool) {
        if (proposed.passkeyWeight   < current.passkeyWeight)   return true;
        if (proposed.ecdsaWeight     < current.ecdsaWeight)     return true;
        if (proposed.blsWeight       < current.blsWeight)       return true;
        if (proposed.guardian0Weight < current.guardian0Weight) return true;
        if (proposed.guardian1Weight < current.guardian1Weight) return true;
        if (proposed.guardian2Weight < current.guardian2Weight) return true;
        if (proposed.tier1Threshold  < current.tier1Threshold)  return true;
        if (proposed.tier2Threshold  < current.tier2Threshold)  return true;
        if (proposed.tier3Threshold  < current.tier3Threshold)  return true;
        return false;
    }
}
