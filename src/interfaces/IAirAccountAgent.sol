// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {AAStarAgentStorageLayout} from "../core/AAStarAgentStorageLayout.sol";

/// @title IAirAccountAgent
/// @notice ABI surface for the cold functions that AAStarAirAccountV7 routes to the singleton
///         AirAccountExtension via fallback + delegatecall (diamond-lite): ERC-8004 agent
///         identity/reputation and weighted-signature config governance.
/// @dev Because these functions are not declared on the account itself, typed Solidity callers
///      (tests, integrators) must address the account through this interface:
///        `IAirAccountAgent(address(account)).mintAgentIdentity(...)`.
///      Over-the-wire callers (SDK, EOAs) call by selector and hit the account fallback directly.
interface IAirAccountAgent {
    // ── ERC-8004 agent ──
    function setAgentWallet(
        uint256 agentId,
        address agentWallet,
        address agentRegistry,
        bytes calldata agentWalletSig
    ) external;

    function mintAgentIdentity(
        address identityRegistry,
        string calldata agentURI
    ) external returns (uint256 agentId);

    function bindERC8004AgentWallet(
        address identityRegistry,
        uint256 agentId,
        address agentWallet,
        uint256 deadline,
        bytes calldata signature
    ) external;

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
    ) external;

    function queryAgentReputation(
        address reputationRegistry,
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryDecimals);

    // ── Weighted-signature config governance (M6.1 / M6.2) ──
    function setWeightConfig(AAStarAgentStorageLayout.WeightConfig calldata config) external;
    function proposeWeightChange(AAStarAgentStorageLayout.WeightConfig calldata proposed) external;
    function approveWeightChange() external;
    function executeWeightChange() external;
    function cancelWeightChange() external;

    // ── Optional module-install timelock (KI-6 / issue #58) ──
    function moduleInstallTimelock() external view returns (uint256);
    function pendingModuleInstall()
        external
        view
        returns (address module, uint8 moduleTypeId, uint40 proposedAt, uint40 executeAfter, bytes32 initDataHash);
    function setModuleInstallTimelock(uint256 newTimelock, bytes calldata guardianSigs) external;
    function proposeModuleInstall(uint256 moduleTypeId, address module, bytes calldata initData) external;
    function executeModuleInstall(bytes calldata moduleInitData) external;
    function cancelModuleInstall() external;
}
