// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";

/**
 * @title AAStarAirAccountBase
 * @notice Non-upgradable ERC-4337 smart wallet base with algId-based signature routing,
 *         tiered verification, P256 passkey, social recovery, and global guard.
 * @dev Signature dispatch:
 *      - Empty or 65-byte sig → inline ECDSA (algId=0x02 implied)
 *      - sig[0]=0x02 → inline ECDSA (explicit, strip prefix)
 *      - sig[0]=0x01 → triple signature: ECDSA×2 + BLS aggregate
 *      - sig[0]=0x03 → P256 WebAuthn passkey (EIP-7212)
 *      - Other algId  → external call via validator router
 */
abstract contract AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants ────────────────────────────────────────────────────

    uint8 internal constant ALG_BLS = 0x01;
    uint8 internal constant ALG_ECDSA = 0x02;
    uint8 internal constant ALG_P256 = 0x03;

    uint256 internal constant G2_POINT_LENGTH = 256;

    /// @dev EIP-7212 P256 verification precompile
    address internal constant P256_VERIFIER = address(0x100);

    /// @dev Recovery timelock
    uint256 internal constant RECOVERY_TIMELOCK = 2 days;

    /// @dev Recovery threshold: 2 out of 3 guardians
    uint256 internal constant RECOVERY_THRESHOLD = 2;

    // ─── Immutable State ──────────────────────────────────────────────

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint;

    // ─── Mutable State ───────────────────────────────────────────────

    /// @notice Account owner and ECDSA signer (mutable for social recovery)
    address public owner;

    /// @notice Optional validator router for external algorithms (BLS, PQ, etc.)
    IAAStarValidator public validator;

    /// @notice Optional BLS aggregator for batch verification
    address public blsAggregator;

    /// @notice Optional global guard for spending limits
    AAStarGlobalGuard public guard;

    // ── P256 Passkey ──

    /// @notice P256 public key x-coordinate
    bytes32 public p256KeyX;

    /// @notice P256 public key y-coordinate
    bytes32 public p256KeyY;

    // ── Tiered Routing ──

    /// @notice Tier thresholds: [0]=Tier1 max (ECDSA only), [1]=Tier2 max (dual factor)
    /// Above Tier2 max requires multi-sig (BLS triple)
    uint256 public tier1Limit; // e.g., 0.1 ETH — ECDSA only
    uint256 public tier2Limit; // e.g., 1 ETH — dual factor (ECDSA + P256)

    // ── Social Recovery (F28) ──

    /// @notice Recovery guardians (max 3)
    address[3] public guardians;

    /// @notice Number of active guardians
    uint8 public guardianCount;

    /// @notice Active recovery proposal
    RecoveryProposal public activeRecovery;

    struct RecoveryProposal {
        address newOwner;
        uint256 proposedAt;
        uint256 approvalBitmap; // bit 0 = guardian[0], bit 1 = guardian[1], bit 2 = guardian[2]
    }

    // ─── Custom Errors ────────────────────────────────────────────────

    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error NotOwner();
    error ArrayLengthMismatch();
    error CallFailed(bytes returnData);
    error InvalidP256Key();
    error TierNotConfigured();
    error GuardianAlreadySet();
    error InvalidGuardian();
    error MaxGuardiansReached();
    error NotGuardian();
    error NoActiveRecovery();
    error RecoveryTimelockNotExpired();
    error AlreadyApproved();
    error RecoveryNotApproved();
    error RecoveryAlreadyActive();
    error InvalidNewOwner();

    // ─── Events ───────────────────────────────────────────────────────

    event ValidatorSet(address indexed validator);
    event AggregatorSet(address indexed aggregator);
    event GuardSet(address indexed guard);
    event P256KeySet(bytes32 x, bytes32 y);
    event TierLimitsSet(uint256 tier1, uint256 tier2);
    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount);
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event RecoveryCancelled();
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    // ─── Modifiers ────────────────────────────────────────────────────

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != entryPoint) revert NotOwnerOrEntryPoint();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────

    constructor(address _entryPoint, address _owner) {
        entryPoint = _entryPoint;
        owner = _owner;
    }

    // ─── Configuration (owner only) ─────────────────────────────────

    function setValidator(address _validator) external onlyOwner {
        validator = IAAStarValidator(_validator);
        emit ValidatorSet(_validator);
    }

    function setAggregator(address _aggregator) external onlyOwner {
        blsAggregator = _aggregator;
        emit AggregatorSet(_aggregator);
    }

    function setGuard(address _guard) external onlyOwner {
        guard = AAStarGlobalGuard(_guard);
        emit GuardSet(_guard);
    }

    function setP256Key(bytes32 _x, bytes32 _y) external onlyOwner {
        if (_x == bytes32(0) && _y == bytes32(0)) revert InvalidP256Key();
        p256KeyX = _x;
        p256KeyY = _y;
        emit P256KeySet(_x, _y);
    }

    function setTierLimits(uint256 _tier1, uint256 _tier2) external onlyOwner {
        tier1Limit = _tier1;
        tier2Limit = _tier2;
        emit TierLimitsSet(_tier1, _tier2);
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
    ) internal returns (uint256 validationData) {
        // Empty signature → fail
        if (signature.length == 0) return 1;

        // Check first byte for known algId prefix (takes priority over length-based routing)
        uint8 firstByte = uint8(signature[0]);

        if (firstByte == ALG_BLS) {
            // BLS triple sig (any length > 1 routes here; malformed sigs return 1)
            return _validateTripleSignature(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_P256 && signature.length == 65) {
            // P256: algId(1) + r(32) + s(32) = 65 bytes
            return _validateP256(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_ECDSA) {
            // Explicit ECDSA: algId(1) + r(32) + s(32) + v(1) = 66 bytes
            if (signature.length == 66) {
                return _validateECDSA(userOpHash, signature[1:]);
            }
            return 1; // Wrong length for explicit ECDSA
        }

        // Raw ECDSA: 65-byte sig without algId prefix (backwards compat with M1)
        if (signature.length == 65) {
            return _validateECDSA(userOpHash, signature);
        }

        // All other → delegate to external validator router
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

    /// @dev P256 (secp256r1) passkey validation via EIP-7212 precompile
    /// @param sigData Format: [r(32)][s(32)] = 64 bytes
    function _validateP256(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal view returns (uint256) {
        if (sigData.length != 64) return 1;
        if (p256KeyX == bytes32(0) && p256KeyY == bytes32(0)) return 1;

        bytes32 r = bytes32(sigData[0:32]);
        bytes32 s = bytes32(sigData[32:64]);

        // EIP-7212: P256VERIFY(hash, r, s, x, y) → 1 if valid
        (bool success, bytes memory result) = P256_VERIFIER.staticcall(
            abi.encode(userOpHash, r, s, p256KeyX, p256KeyY)
        );

        if (success && result.length >= 32) {
            uint256 valid = abi.decode(result, (uint256));
            return valid == 1 ? 0 : 1;
        }

        return 1;
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
     *
     * When blsAggregator is set, returns aggregator address instead of doing BLS
     * verification (deferred to batch verification by EntryPoint).
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

        // If aggregator is set, return aggregator address for batch verification
        // EntryPoint will call aggregator.validateSignatures() for the batch
        if (blsAggregator != address(0)) {
            return uint256(uint160(blsAggregator));
        }

        // SECURITY 3: BLS aggregate verification via validator router (standalone mode)
        address blsAlg = validator.getAlgorithm(ALG_BLS);
        if (blsAlg == address(0)) return 1;

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

    // ─── Tiered Routing (F21) ────────────────────────────────────────

    /// @dev Determine the required algorithm tier based on transaction value.
    ///      Tier 1 (≤tier1Limit): ECDSA only
    ///      Tier 2 (≤tier2Limit): ECDSA + P256 dual factor
    ///      Tier 3 (>tier2Limit): BLS triple signature (multi-sig consensus)
    function requiredTier(uint256 txValue) public view returns (uint8) {
        if (tier1Limit == 0 && tier2Limit == 0) return 0; // Tiering not configured
        if (txValue <= tier1Limit) return 1;
        if (txValue <= tier2Limit) return 2;
        return 3;
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

    // ─── Social Recovery (F28) ───────────────────────────────────────

    /// @notice Add a recovery guardian. Max 3 guardians.
    function addGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0) || _guardian == owner) revert InvalidGuardian();
        if (guardianCount >= 3) revert MaxGuardiansReached();

        // Check not already set
        for (uint8 i = 0; i < guardianCount; i++) {
            if (guardians[i] == _guardian) revert GuardianAlreadySet();
        }

        guardians[guardianCount] = _guardian;
        emit GuardianAdded(guardianCount, _guardian);
        guardianCount++;
    }

    /// @notice Remove a guardian by index.
    function removeGuardian(uint8 index) external onlyOwner {
        if (index >= guardianCount) revert InvalidGuardian();

        address removed = guardians[index];

        // Shift remaining guardians
        for (uint8 i = index; i < guardianCount - 1; i++) {
            guardians[i] = guardians[i + 1];
        }
        guardians[guardianCount - 1] = address(0);
        guardianCount--;

        // Cancel any active recovery (guardian set changed)
        if (activeRecovery.newOwner != address(0)) {
            delete activeRecovery;
            emit RecoveryCancelled();
        }

        emit GuardianRemoved(index, removed);
    }

    /// @notice Propose a recovery: change owner to a new address.
    ///         Any guardian can propose. Requires RECOVERY_THRESHOLD approvals.
    function proposeRecovery(address _newOwner) external {
        if (_newOwner == address(0) || _newOwner == owner) revert InvalidNewOwner();
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();

        uint8 guardianIndex = _guardianIndex(msg.sender);

        activeRecovery = RecoveryProposal({
            newOwner: _newOwner,
            proposedAt: block.timestamp,
            approvalBitmap: 1 << guardianIndex
        });

        emit RecoveryProposed(_newOwner, msg.sender);
        emit RecoveryApproved(_newOwner, msg.sender, 1);
    }

    /// @notice Approve an active recovery proposal.
    function approveRecovery() external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();

        uint8 guardianIndex = _guardianIndex(msg.sender);
        uint256 bit = 1 << guardianIndex;
        if (activeRecovery.approvalBitmap & bit != 0) revert AlreadyApproved();

        activeRecovery.approvalBitmap |= bit;

        uint256 count = _popcount(activeRecovery.approvalBitmap);
        emit RecoveryApproved(activeRecovery.newOwner, msg.sender, count);
    }

    /// @notice Execute recovery after timelock and threshold are met.
    function executeRecovery() external {
        RecoveryProposal memory r = activeRecovery;
        if (r.newOwner == address(0)) revert NoActiveRecovery();
        if (block.timestamp < r.proposedAt + RECOVERY_TIMELOCK) {
            revert RecoveryTimelockNotExpired();
        }
        if (_popcount(r.approvalBitmap) < RECOVERY_THRESHOLD) {
            revert RecoveryNotApproved();
        }

        address oldOwner = owner;
        owner = r.newOwner;
        delete activeRecovery;

        emit RecoveryExecuted(oldOwner, r.newOwner);
        emit OwnerChanged(oldOwner, r.newOwner);
    }

    /// @notice Cancel active recovery. Only current owner can cancel.
    function cancelRecovery() external onlyOwner {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();
        delete activeRecovery;
        emit RecoveryCancelled();
    }

    /// @dev Find guardian index or revert
    function _guardianIndex(address addr) internal view returns (uint8) {
        for (uint8 i = 0; i < guardianCount; i++) {
            if (guardians[i] == addr) return i;
        }
        revert NotGuardian();
    }

    /// @dev Count set bits in a uint256
    function _popcount(uint256 x) internal pure returns (uint256 count) {
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }

    // ─── EntryPoint Deposit Management ────────────────────────────────

    function addDeposit() public payable {
        IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
    }

    function getDeposit() public view returns (uint256) {
        return IEntryPoint(entryPoint).balanceOf(address(this));
    }

    function withdrawDepositTo(address payable to, uint256 amount) external onlyOwner {
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
