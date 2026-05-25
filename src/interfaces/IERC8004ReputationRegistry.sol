// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IERC8004ReputationRegistry — ERC-8004 "Trustless Agents" Reputation Registry
/// @notice Interface matching the official ERC-8004 ReputationRegistryUpgradeable.
///         Callers (clients) submit signed fixed-point feedback for agent interactions.
///         Aggregation functions (`getSummary`) provide trust signals across many clients.
///
/// @dev Official deployments (same address across chains via CREATE2):
///      - Mainnet / OP Mainnet / Base / Arbitrum / ...: 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
///      - Sepolia / OP Sepolia / Base Sepolia / ...:     0x8004B663056A597Dffe9eCcC1965A193B7388713
///
///      Feedback value: signed fixed-point, value / 10^valueDecimals.
///      E.g. value=95, decimals=2 means 0.95 (95% satisfaction).
///      Self-feedback (client == agentWallet) is rejected by the registry.
interface IERC8004ReputationRegistry {
    // ─── Events ───────────────────────────────────────────────────────────────

    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        int128 value,
        uint8 valueDecimals,
        string indexed indexedTag1,
        string tag1,
        string tag2,
        string endpoint,
        string feedbackURI,
        bytes32 feedbackHash
    );

    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 indexed feedbackIndex
    );

    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        address indexed responder,
        string responseURI,
        bytes32 responseHash
    );

    // ─── Initializer ─────────────────────────────────────────────────────────

    function initialize(address identityRegistry_) external;
    function getIdentityRegistry() external view returns (address);

    // ─── Write ────────────────────────────────────────────────────────────────

    /// @notice Submit feedback for an agent interaction.
    /// @param agentId       ERC-8004 agent token ID.
    /// @param value         Signed fixed-point score (e.g. 95 with decimals=2 → 0.95).
    /// @param valueDecimals Decimal places for `value`.
    /// @param tag1          Primary category tag (e.g. "quality").
    /// @param tag2          Secondary tag (e.g. "task:summarize").
    /// @param endpoint      The agent endpoint/API that served the request.
    /// @param feedbackURI   URI to detailed feedback data (IPFS or HTTPS).
    /// @param feedbackHash  keccak256 of the off-chain feedback payload.
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    /// @notice Revoke a previously submitted feedback entry.
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

    /// @notice Agent owner appends a response to a feedback record.
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external;

    // ─── Read ─────────────────────────────────────────────────────────────────

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);

    function readAllFeedback(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2,
        bool includeRevoked
    )
        external
        view
        returns (
            address[] memory clients,
            uint64[] memory feedbackIndexes,
            int128[] memory values,
            uint8[] memory valueDecimals,
            string[] memory tag1s,
            string[] memory tag2s,
            bool[] memory revokedStatuses
        );

    /// @notice Aggregate reputation score across a set of clients for a specific tag.
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    function getResponseCount(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        address[] calldata responders
    ) external view returns (uint64 count);

    function getClients(uint256 agentId) external view returns (address[] memory);

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
}
