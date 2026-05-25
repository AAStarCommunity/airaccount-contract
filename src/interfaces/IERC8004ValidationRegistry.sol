// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title IERC8004ValidationRegistry — ERC-8004 "Trustless Agents" Validation Registry
/// @notice Interface matching the official ERC-8004 ValidationRegistryUpgradeable.
///         Third-party validators post on-chain proof-of-validation records for agents.
///         NOTE: The ERC-8004 spec states the ValidationRegistry is still under active
///         development with the TEE community. These interfaces may change.
///
/// @dev Official deployments (same address across chains via CREATE2):
///      - Mainnet / OP Mainnet / Base / Arbitrum / ...: 0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58
///      - Sepolia / OP Sepolia / Base Sepolia / ...:     0x8004Cb1BF31DAf7788923b405b754f57acEB4272
interface IERC8004ValidationRegistry {
    // ─── Events ───────────────────────────────────────────────────────────────

    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string requestURI,
        bytes32 indexed requestHash
    );

    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );

    // ─── Initializer ─────────────────────────────────────────────────────────

    function initialize(address identityRegistry_) external;
    function getIdentityRegistry() external view returns (address);

    // ─── Write ────────────────────────────────────────────────────────────────

    /// @notice Request validation from a validator smart contract.
    /// @param validatorAddress  Address of the validator that should respond.
    /// @param agentId           ERC-8004 agent token ID to be validated.
    /// @param requestURI        URI to the validation request payload (IPFS or HTTPS).
    /// @param requestHash       keccak256 of the off-chain request payload.
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external;

    /// @notice Validator posts a response to a validation request.
    /// @param requestHash   Hash identifying the original request.
    /// @param response      Response code: 0=pending, 1=approved, 2=rejected.
    /// @param responseURI   URI to the validation response payload.
    /// @param responseHash  keccak256 of the off-chain response payload.
    /// @param tag           Optional tag (e.g. "security", "hallucination", "compliance").
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    // ─── Read ─────────────────────────────────────────────────────────────────

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    /// @notice Aggregate validation summary for an agent across validators.
    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse);

    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory requestHashes);

    function getValidatorRequests(address validatorAddress)
        external
        view
        returns (bytes32[] memory requestHashes);
}
