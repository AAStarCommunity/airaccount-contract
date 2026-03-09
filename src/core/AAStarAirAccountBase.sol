// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";

/**
 * @title AAStarAirAccountBase
 * @notice Non-upgradable ERC-4337 smart wallet base with algId-based signature routing.
 * @dev Signature dispatch:
 *      - Empty or 65-byte sig → inline ECDSA (algId=0x02 implied)
 *      - sig[0]=0x02 → inline ECDSA (explicit, strip prefix)
 *      - sig[0]=0x01 → triple signature: ECDSA×2 + BLS aggregate (external call via validator)
 *      - Other algId  → external call via validator router
 *
 *      Child contracts (V7/V8) implement validateUserOp from IAccount.
 */
abstract contract AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants ────────────────────────────────────────────────────

    uint8 internal constant ALG_BLS = 0x01;
    uint8 internal constant ALG_ECDSA = 0x02;
    uint8 internal constant ALG_P256 = 0x03;

    uint256 internal constant G2_POINT_LENGTH = 256;

    // ─── Immutable State ──────────────────────────────────────────────

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint;

    /// @notice Account owner and ECDSA signer
    address public immutable owner;

    // ─── Mutable State (M2+) ──────────────────────────────────────────

    /// @notice Optional validator router for external algorithms (BLS, PQ, etc.)
    IAAStarValidator public validator;

    // ─── Custom Errors ────────────────────────────────────────────────

    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error NotOwner();
    error ArrayLengthMismatch();
    error CallFailed(bytes returnData);

    // ─── Events ───────────────────────────────────────────────────────

    event ValidatorSet(address indexed validator);

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != entryPoint) revert NotOwnerOrEntryPoint();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(address _entryPoint, address _owner) {
        entryPoint = _entryPoint;
        owner = _owner;
    }

    // ─── Validator Configuration ──────────────────────────────────────

    /// @notice Set or update the validator router. Only owner can call.
    function setValidator(address _validator) external {
        if (msg.sender != owner) revert NotOwner();
        validator = IAAStarValidator(_validator);
        emit ValidatorSet(_validator);
    }

    // ─── Signature Validation ─────────────────────────────────────────

    /**
     * @dev Validate signature with algId-based routing.
     * @param userOpHash Hash of the UserOperation (from EntryPoint).
     * @param signature  The signature bytes. First byte = algId for routing.
     * @return validationData 0 on success, 1 (SIG_VALIDATION_FAILED) on failure.
     */
    function _validateSignature(
        bytes32 userOpHash,
        bytes calldata signature
    ) internal view returns (uint256 validationData) {
        // Empty signature → fail
        if (signature.length == 0) return 1;

        // Default ECDSA: 65-byte sig without algId prefix (backwards compat with M1)
        if (signature.length == 65) {
            return _validateECDSA(userOpHash, signature);
        }

        // Route by algId (first byte)
        uint8 algId = uint8(signature[0]);
        bytes calldata sigData = signature[1:];

        if (algId == ALG_ECDSA) {
            // Explicit ECDSA with prefix
            return _validateECDSA(userOpHash, sigData);
        }

        if (algId == ALG_BLS) {
            // Triple signature: ECDSA×2 + BLS aggregate
            return _validateTripleSignature(userOpHash, sigData);
        }

        // All other algIds → delegate to external validator router
        if (address(validator) == address(0)) return 1;
        return validator.validateSignature(userOpHash, signature);
    }

    /// @dev Inline ECDSA validation (EIP-191 personal sign)
    function _validateECDSA(
        bytes32 userOpHash,
        bytes calldata signature
    ) internal view returns (uint256) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(signature);
        return recovered == owner ? 0 : 1;
    }

    /**
     * @dev Validate triple signature: ECDSA×2 binding + BLS aggregate verification.
     *
     * Signature format (after algId byte stripped):
     *   [nodeIdsLength(32)][nodeIds(N×32)][blsSignature(256)][messagePoint(256)][aaSignature(65)][messagePointSignature(65)]
     *
     * Security layers:
     *   1. aaSignature validates userOpHash (binds to specific UserOp)
     *   2. messagePointSignature validates messagePoint (prevents manipulation)
     *   3. BLS aggregate validates messagePoint against registered nodes
     */
    function _validateTripleSignature(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal view returns (uint256) {
        if (address(validator) == address(0)) return 1;

        // Parse nodeIds count
        if (sigData.length < 32) return 1;
        uint256 nodeIdsLength = uint256(bytes32(sigData[0:32]));
        if (nodeIdsLength == 0 || nodeIdsLength > 100) return 1;

        uint256 nodeIdsDataLength = nodeIdsLength * 32;
        uint256 expectedLength = 32 + nodeIdsDataLength + 256 + 256 + 65 + 65;
        if (sigData.length != expectedLength) return 1;

        uint256 baseOffset = 32 + nodeIdsDataLength;

        // Extract ECDSA signatures
        bytes calldata aaSignature = sigData[baseOffset + 512:baseOffset + 577];
        bytes calldata messagePointSignature = sigData[baseOffset + 577:baseOffset + 642];
        bytes calldata messagePoint = sigData[baseOffset + 256:baseOffset + 512];

        // SECURITY 1: AA signature must validate userOpHash
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(aaSignature);
        if (recovered != owner) return 1;

        // SECURITY 2: MessagePoint signature must validate messagePoint
        bytes32 mpHash = keccak256(messagePoint).toEthSignedMessageHash();
        address mpRecovered = mpHash.recover(messagePointSignature);
        if (mpRecovered != owner) return 1;

        // SECURITY 3: BLS aggregate verification via validator router
        // Route through IAAStarAlgorithm.validate interface
        // BLS algorithm's validate expects: nodeIds(N×32) + blsSig(256) + messagePoint(256)
        address blsAlg = validator.getAlgorithm(ALG_BLS);
        if (blsAlg == address(0)) return 1;

        // Build BLS validation payload: nodeIds + blsSig + messagePoint
        bytes calldata blsPayload = sigData[32:baseOffset + 512];

        try IAAStarAlgorithm(blsAlg).validate(userOpHash, blsPayload) returns (uint256 blsResult) {
            return blsResult;
        } catch {
            return 1;
        }
    }

    /// @dev Extract nodeIds array from sigData
    function _extractNodeIds(bytes calldata sigData, uint256 count) internal pure returns (bytes32[] memory nodeIds) {
        nodeIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            nodeIds[i] = bytes32(sigData[32 + i * 32:64 + i * 32]);
        }
    }

    // ─── Execution ────────────────────────────────────────────────────

    /// @notice Execute a single call from this account.
    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyOwnerOrEntryPoint {
        _call(dest, value, func);
    }

    /// @notice Execute a batch of calls from this account.
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata func
    ) external onlyOwnerOrEntryPoint {
        if (dest.length != value.length || dest.length != func.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], value[i], func[i]);
        }
    }

    // ─── EntryPoint Deposit Management ────────────────────────────────

    function addDeposit() public payable {
        IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
    }

    function getDeposit() public view returns (uint256) {
        return IEntryPoint(entryPoint).balanceOf(address(this));
    }

    function withdrawDepositTo(address payable to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        IEntryPoint(entryPoint).withdrawTo(to, amount);
    }

    // ─── Internal Helpers ─────────────────────────────────────────────

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            (success);
        }
    }

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    receive() external payable {}
}
