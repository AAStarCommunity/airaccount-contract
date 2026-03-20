// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";
import {ICalldataParser} from "../interfaces/ICalldataParser.sol";

/// @dev Minimal interface for CalldataParserRegistry — avoids circular import
interface ICalldataParserRegistry {
    function getParser(address dest) external view returns (address);
}

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
 *
 *      Guard enforcement:
 *      - Guard is deployed atomically in constructor (no unprotected window)
 *      - Guard.account = address(this) (immutable, survives social recovery)
 *      - Monotonic config: daily limit can only decrease, algorithms can only be added
 *      - Tier + guard checks enforced in execute/executeBatch before every _call
 */
abstract contract AAStarAirAccountBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─── Constants ────────────────────────────────────────────────────

    uint8 internal constant ALG_BLS = 0x01;
    uint8 internal constant ALG_ECDSA = 0x02;
    uint8 internal constant ALG_P256 = 0x03;
    uint8 internal constant ALG_CUMULATIVE_T2 = 0x04; // P256 + BLS
    uint8 internal constant ALG_CUMULATIVE_T3 = 0x05; // P256 + BLS + Guardian ECDSA
    uint8 internal constant ALG_COMBINED_T1 = 0x06;   // P256 AND ECDSA simultaneously (zero-trust Tier 1)
    uint8 internal constant ALG_SESSION_KEY = 0x08;   // Time-limited session key (ephemeral ECDSA, Tier 1)

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

    /// @notice Global guard for spending limits (set at construction, cannot be removed)
    AAStarGlobalGuard public guard;

    /// @notice Optional calldata parser registry for DeFi protocol support (address(0) = disabled)
    ///         When set, the guard uses protocol-specific parsers to understand DeFi calldata
    ///         (e.g., Uniswap swaps) rather than falling back to ERC20 transfer parsing only.
    address public parserRegistry;

    // ── algId Pass-Through (validation → execution) ──
    // Uses transient storage (EIP-1153) to avoid cross-UserOp contamination.
    // When EntryPoint bundles multiple UserOps from the same sender,
    // validation runs for all ops before execution. A storage variable would
    // be overwritten by the last validation, but transient storage keyed by
    // nonce ensures each execution reads the correct algId.

    /// @dev Transient storage slot base for algId (slot = ALG_ID_SLOT_BASE + nonce)
    uint256 internal constant ALG_ID_SLOT_BASE = 0x0A1600;

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

    // Packed storage: _guardian0 (20 bytes) + _guardianCount (1 byte) = 21 bytes — fits in one slot.
    // Saves 1 SLOAD (~2,100 gas) on every guardian check (proposeRecovery, approveRecovery, cancelRecovery).
    address private _guardian0;
    uint8 private _guardianCount;  // packed with _guardian0 in same 32-byte slot
    address private _guardian1;
    address private _guardian2;

    /// @notice Active recovery proposal
    RecoveryProposal public activeRecovery;

    struct RecoveryProposal {
        address newOwner;
        uint256 proposedAt;
        uint256 approvalBitmap;      // bit 0 = guardian[0], bit 1 = guardian[1], bit 2 = guardian[2]
        uint256 cancellationBitmap;  // same layout, for 2-of-3 cancel threshold
    }

    /// @notice Read-only snapshot of the account's current configuration
    struct AccountConfig {
        address accountOwner;
        address guardAddress;
        uint256 dailyLimit;
        uint256 dailyRemaining;
        uint256 tier1Limit;
        uint256 tier2Limit;
        address[3] guardianAddresses;
        uint8 guardianCount;
        bool hasP256Key;
        bool hasValidator;
        bool hasAggregator;
        bool hasActiveRecovery;
    }

    /// @notice Account initialization config (used by constructor)
    struct InitConfig {
        address[3] guardians;                      // Recovery guardians (address(0) = unused slot)
        uint256 dailyLimit;                        // Guard ETH daily spending limit in wei (0 = no guard)
        uint8[] approvedAlgIds;                    // Guard approved algorithms (empty = no guard)
        uint256 minDailyLimit;                     // Floor for decreaseDailyLimit (0 = no floor)
        address[] initialTokens;                   // ERC20 tokens with spending limits (may be empty)
        AAStarGlobalGuard.TokenConfig[] initialTokenConfigs; // Per-token tier/daily configs, 1:1 with initialTokens
    }

    // ─── Custom Errors ────────────────────────────────────────────────

    error NotEntryPoint();
    error NotOwnerOrEntryPoint();
    error NotOwner();
    error ArrayLengthMismatch();
    error CallFailed(bytes returnData);
    error InvalidP256Key();
    error InsufficientTier(uint8 required, uint8 provided);
    error GuardianAlreadySet();
    error InvalidGuardian();
    error MaxGuardiansReached();
    error NotGuardian();
    error NoActiveRecovery();
    error RecoveryTimelockNotExpired();
    error AlreadyApproved();
    error AlreadyCancelVoted();
    error RecoveryNotApproved();
    error RecoveryAlreadyActive();
    error InvalidNewOwner();
    error Reentrancy();
    error InvalidGuardianSignature();
    error InvalidTierConfig();

    // ─── Events ───────────────────────────────────────────────────────

    event ValidatorSet(address indexed validator);
    event AggregatorSet(address indexed aggregator);
    event GuardInitialized(address indexed guard, uint256 dailyLimit);
    event ParserRegistrySet(address indexed registry);
    event P256KeySet(bytes32 x, bytes32 y);
    event TierLimitsSet(uint256 tier1, uint256 tier2);
    event GuardianAdded(uint8 indexed index, address indexed guardian);
    event GuardianRemoved(uint8 indexed index, address indexed guardian);
    event RecoveryProposed(address indexed newOwner, address indexed proposedBy);
    event RecoveryApproved(address indexed newOwner, address indexed approvedBy, uint256 approvalCount);
    event RecoveryExecuted(address indexed oldOwner, address indexed newOwner);
    event RecoveryCancelVoted(address indexed votedBy, uint256 cancelCount);
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

    /// @dev Reentrancy guard using transient storage (EIP-1153, ~200 gas vs ~7100 for SSTORE)
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

    // ─── Constructor ──────────────────────────────────────────────────

    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _config Initialization config: guardians, guard daily limit, approved algorithms
    constructor(address _entryPoint, address _owner, InitConfig memory _config) {
        entryPoint = _entryPoint;
        owner = _owner;

        // Initialize guardians (skip address(0) slots)
        for (uint8 i = 0; i < 3; i++) {
            address g = _config.guardians[i];
            if (g != address(0)) {
                if (g == _owner) revert InvalidGuardian();
                // Check no duplicates with previously added guardians
                for (uint8 j = 0; j < _guardianCount; j++) {
                    if (_getGuardian(j) == g) revert GuardianAlreadySet();
                }
                _setGuardian(_guardianCount, g);
                emit GuardianAdded(_guardianCount, g);
                _guardianCount++;
            }
        }

        // Initialize guard atomically (no unprotected window)
        if (_config.approvedAlgIds.length > 0 || _config.dailyLimit > 0) {
            guard = new AAStarGlobalGuard(
                address(this),
                _config.dailyLimit,
                _config.approvedAlgIds,
                _config.minDailyLimit,
                _config.initialTokens,
                _config.initialTokenConfigs
            );
            emit GuardInitialized(address(guard), _config.dailyLimit);
        }
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

    /// @notice Set the calldata parser registry for DeFi protocol support.
    ///         Can be updated by owner (unlike guard which is immutable).
    ///         Set to address(0) to disable parser support.
    function setParserRegistry(address registry) external onlyOwner {
        parserRegistry = registry;
        emit ParserRegistrySet(registry);
    }

    function setP256Key(bytes32 _x, bytes32 _y) external onlyOwner {
        if (_x == bytes32(0) && _y == bytes32(0)) revert InvalidP256Key();
        p256KeyX = _x;
        p256KeyY = _y;
        emit P256KeySet(_x, _y);
    }

    function setTierLimits(uint256 _tier1, uint256 _tier2) external onlyOwner {
        if (_tier1 > _tier2 && _tier2 > 0) revert InvalidTierConfig();
        tier1Limit = _tier1;
        tier2Limit = _tier2;
        emit TierLimitsSet(_tier1, _tier2);
    }

    // ─── Guard Configuration (monotonic: only tighten, never loosen) ─

    /// @notice Approve a new algorithm in the guard (add-only, never revoke)
    function guardApproveAlgorithm(uint8 algId) external onlyOwner {
        guard.approveAlgorithm(algId);
    }

    /// @notice Decrease the guard's ETH daily limit (tighten-only, never increase)
    function guardDecreaseDailyLimit(uint256 newLimit) external onlyOwner {
        guard.decreaseDailyLimit(newLimit);
    }

    /// @notice Add a new ERC20 token config to the guard (monotonic: add-only, never remove)
    function guardAddTokenConfig(address token, AAStarGlobalGuard.TokenConfig calldata config) external onlyOwner {
        guard.addTokenConfig(token, config);
    }

    /// @notice Decrease a token's daily limit in the guard (tighten-only, never increase)
    function guardDecreaseTokenDailyLimit(address token, uint256 newLimit) external onlyOwner {
        guard.decreaseTokenDailyLimit(token, newLimit);
    }

    // ─── Guardian Public Getters (maintain interface from packed private storage) ──

    /// @notice Returns guardian address at index (0-2). Returns address(0) for empty slots.
    function guardians(uint256 i) external view returns (address) {
        if (i == 0) return _guardian0;
        if (i == 1) return _guardian1;
        if (i == 2) return _guardian2;
        return address(0);
    }

    /// @notice Returns number of active guardians.
    function guardianCount() external view returns (uint8) {
        return _guardianCount;
    }

    // ─── Config Introspection ────────────────────────────────────────

    /// @notice Returns a snapshot of the account's current configuration.
    ///         Useful for off-chain UIs to display account status and security posture.
    function getConfigDescription() external view returns (AccountConfig memory) {
        uint256 remaining = 0;
        uint256 limit = 0;
        if (address(guard) != address(0)) {
            remaining = guard.remainingDailyAllowance();
            limit = guard.dailyLimit();
        }

        return AccountConfig({
            accountOwner: owner,
            guardAddress: address(guard),
            dailyLimit: limit,
            dailyRemaining: remaining,
            tier1Limit: tier1Limit,
            tier2Limit: tier2Limit,
            guardianAddresses: [_guardian0, _guardian1, _guardian2],
            guardianCount: _guardianCount,
            hasP256Key: p256KeyX != bytes32(0),
            hasValidator: address(validator) != address(0),
            hasAggregator: blsAggregator != address(0),
            hasActiveRecovery: activeRecovery.newOwner != address(0)
        });
    }

    // ─── Signature Validation ─────────────────────────────────────────

    /**
     * @dev Validate signature with algId-based routing.
     *      Stores validated algId in transient storage queue for execute() to consume.
     *      Queue design prevents cross-UserOp contamination when EntryPoint bundles
     *      multiple UserOps from the same sender (all validations run before executions).
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
            _storeValidatedAlgId(ALG_BLS);
            return _validateTripleSignature(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_P256 && signature.length == 65) {
            _storeValidatedAlgId(ALG_P256);
            return _validateP256(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_CUMULATIVE_T2) {
            _storeValidatedAlgId(ALG_CUMULATIVE_T2);
            return _validateCumulativeTier2(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_CUMULATIVE_T3) {
            _storeValidatedAlgId(ALG_CUMULATIVE_T3);
            return _validateCumulativeTier3(userOpHash, signature[1:]);
        }

        if (firstByte == ALG_ECDSA) {
            if (signature.length == 66) {
                _storeValidatedAlgId(ALG_ECDSA);
                return _validateECDSA(userOpHash, signature[1:]);
            }
            return 1; // Wrong length for explicit ECDSA
        }

        // ALG_COMBINED_T1 (0x06): P256 passkey AND owner ECDSA — zero-trust Tier 1 (F74/F75/F76)
        // Signature format: [0x06][P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]
        if (firstByte == ALG_COMBINED_T1) {
            if (signature.length == 130) {
                _storeValidatedAlgId(ALG_COMBINED_T1);
                return _validateCombinedT1(userOpHash, signature[1:]);
            }
            return 1; // Wrong length
        }

        // Raw ECDSA: 65-byte sig without algId prefix (backwards compat with M1)
        if (signature.length == 65) {
            _storeValidatedAlgId(ALG_ECDSA);
            return _validateECDSA(userOpHash, signature);
        }

        // All other → delegate to external validator router
        if (address(validator) == address(0)) return 1;
        _storeValidatedAlgId(firstByte);
        return validator.validateSignature(userOpHash, signature);
    }

    /// @dev Inline ECDSA validation using direct ecrecover precompile.
    ///      ~500 gas saving vs OZ ECDSA.recover() — avoids bytes memory allocation.
    ///      Still enforces EIP-2 s-value malleability check.
    function _validateECDSA(
        bytes32 userOpHash,
        bytes calldata signature
    ) internal view returns (uint256) {
        if (signature.length != 65) return 1;
        bytes32 hash = userOpHash.toEthSignedMessageHash();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            // Read r, s, v directly from calldata (avoids bytes memory copy)
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            // v is the last byte of the 65-byte signature
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // EIP-2: reject malleable signatures — s must be in lower half of secp256k1 order
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return 1;
        }
        // Normalize v: some signers produce v=0/1 instead of 27/28
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return 1;

        address recovered;
        assembly {
            // ecrecover precompile (0x01): input = hash(32) | v(32) | r(32) | s(32)
            let ptr := mload(0x40)
            mstore(ptr,          hash)
            mstore(add(ptr, 32), v)
            mstore(add(ptr, 64), r)
            mstore(add(ptr, 96), s)
            let ok := staticcall(3000, 1, ptr, 128, ptr, 32)
            if ok { recovered := mload(ptr) }
        }

        return (recovered != address(0) && recovered == owner) ? 0 : 1;
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

        bytes memory callData = abi.encode(userOpHash, r, s, p256KeyX, p256KeyY);

        // EIP-7212 precompile at 0x100: P256VERIFY(hash, r, s, x, y) → 1 if valid
        // Deployment requirement: only deploy on chains with EIP-7212 precompile active.
        // If precompile is unavailable, fail fast rather than fall back to expensive Solidity.
        (bool success, bytes memory result) = P256_VERIFIER.staticcall(callData);
        if (!success || result.length < 32) return 1;
        return abi.decode(result, (uint256)) == 1 ? 0 : 1;
    }

    /**
     * @dev Validate ALG_COMBINED_T1 (0x06): P256 passkey AND owner ECDSA simultaneously.
     *
     * Zero-trust Tier 1 — chain independently verifies both keys, neither trusts the other.
     * A compromised TE (ECDSA only) or stolen device (P256 only) cannot transact alone.
     *
     * Signature format (129 bytes, after algId byte stripped):
     *   [P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]
     *
     * ECDSA signs userOpHash with EIP-191 prefix (same as ALG_ECDSA).
     * P256 verifies userOpHash directly against stored p256KeyX/p256KeyY.
     * Both must be valid; tier = 1 (same spending limits as ECDSA Tier 1).
     */
    function _validateCombinedT1(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal view returns (uint256) {
        if (sigData.length != 129) return 1;
        if (p256KeyX == bytes32(0) && p256KeyY == bytes32(0)) return 1;

        // LAYER 1: P256 passkey verifies userOpHash directly
        bytes32 p256r = bytes32(sigData[0:32]);
        bytes32 p256s = bytes32(sigData[32:64]);

        bytes memory p256CallData = abi.encode(userOpHash, p256r, p256s, p256KeyX, p256KeyY);
        (bool p256Success, bytes memory p256Result) = P256_VERIFIER.staticcall(p256CallData);
        if (!p256Success || p256Result.length < 32) return 1;
        if (abi.decode(p256Result, (uint256)) != 1) return 1;

        // LAYER 2: Owner ECDSA signs userOpHash (EIP-191 prefix)
        bytes32 ecdsaHash = userOpHash.toEthSignedMessageHash();
        bytes32 ecdsaR = bytes32(sigData[64:96]);
        bytes32 ecdsaS = bytes32(sigData[96:128]);
        // EIP-2: reject high-s signatures — consistent with _validateECDSA
        if (uint256(ecdsaS) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return 1;
        }
        uint8 ecdsaV = uint8(sigData[128]);
        if (ecdsaV < 27) ecdsaV += 27;

        address recovered;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, ecdsaHash)
            mstore(add(ptr, 32), ecdsaV)
            mstore(add(ptr, 64), ecdsaR)
            mstore(add(ptr, 96), ecdsaS)
            let ok := staticcall(3000, 1, ptr, 128, ptr, 32)
            if ok { recovered := mload(ptr) }
        }

        return (recovered != address(0) && recovered == owner) ? 0 : 1;
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

        // SECURITY 2: MessagePoint signature must validate messagePoint bound to userOpHash
        // Binding prevents replay of a valid (messagePoint, mpSig) pair across different UserOps
        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
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

    /**
     * @dev Validate cumulative tier 2 signature: P256 passkey + BLS aggregate.
     *
     * Signature format (after algId byte stripped):
     *   [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSignature(256)][messagePoint(256)][messagePointSignature(65)]
     *
     * Security layers:
     *   1. P256 passkey validates userOpHash (device-bound authentication)
     *   2. BLS aggregate validates messagePoint against registered nodes
     *   3. messagePointSignature binds messagePoint to owner (prevents manipulation)
     */
    function _validateCumulativeTier2(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal view returns (uint256) {
        if (address(validator) == address(0)) return 1;

        // LAYER 1: P256 passkey verification (first 64 bytes)
        if (sigData.length < 64) return 1;
        if (_validateP256(userOpHash, sigData[0:64]) != 0) return 1;

        // LAYER 2: BLS aggregate verification (remaining bytes)
        bytes calldata blsPayload = sigData[64:];

        // Parse nodeIds count
        if (blsPayload.length < 32) return 1;
        uint256 nodeIdsLength = uint256(bytes32(blsPayload[0:32]));
        if (nodeIdsLength == 0 || nodeIdsLength > 100) return 1;

        uint256 nodeIdsDataLength = nodeIdsLength * 32;
        // Expected: nodeIdsLength(32) + nodeIds(N*32) + blsSig(256) + messagePoint(256) + messagePointSig(65)
        uint256 expectedLength = 32 + nodeIdsDataLength + 256 + 256 + 65;
        if (blsPayload.length != expectedLength) return 1;

        uint256 baseOffset = 32 + nodeIdsDataLength;

        // Verify messagePoint signature (owner must sign userOpHash+messagePoint — prevents cross-op replay)
        bytes calldata messagePoint = blsPayload[baseOffset + 256:baseOffset + 512];
        bytes calldata messagePointSignature = blsPayload[baseOffset + 512:baseOffset + 577];

        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
        address mpRecovered = mpHash.recover(messagePointSignature);
        if (mpRecovered != owner) return 1;

        // BLS verification via validator router
        address blsAlg = validator.getAlgorithm(ALG_BLS);
        if (blsAlg == address(0)) return 1;

        // BLS payload for validator: nodeIds + blsSig + messagePoint (skip nodeIdsLength prefix)
        bytes calldata blsVerifyData = blsPayload[32:baseOffset + 512];

        try IAAStarAlgorithm(blsAlg).validate(userOpHash, blsVerifyData) returns (uint256 blsResult) {
            return blsResult;
        } catch {
            return 1;
        }
    }

    /**
     * @dev Validate cumulative tier 3 signature: P256 passkey + BLS aggregate + Guardian ECDSA.
     *
     * Signature format (after algId byte stripped):
     *   [P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSignature(256)][messagePoint(256)][messagePointSignature(65)][guardianECDSA(65)]
     *
     * Security layers:
     *   1. P256 passkey validates userOpHash (device-bound authentication)
     *   2. BLS aggregate validates messagePoint against registered nodes
     *   3. Guardian ECDSA co-sign: last 65 bytes must recover to one of guardians[0..2]
     */
    function _validateCumulativeTier3(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal view returns (uint256) {
        if (address(validator) == address(0)) return 1;

        // LAYER 1: P256 passkey verification (first 64 bytes)
        if (sigData.length < 64) return 1;
        if (_validateP256(userOpHash, sigData[0:64]) != 0) return 1;

        // LAYER 3: Guardian ECDSA co-sign (last 65 bytes)
        if (sigData.length < 129) return 1; // At minimum: 64 (P256) + 65 (guardian)
        bytes calldata guardianSig = sigData[sigData.length - 65:];

        bytes32 guardianHash = userOpHash.toEthSignedMessageHash();
        address guardianRecovered = guardianHash.recover(guardianSig);

        bool isGuardian = false;
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == guardianRecovered) {
                isGuardian = true;
                break;
            }
        }
        if (!isGuardian) return 1;

        // LAYER 2: BLS aggregate verification (bytes between P256 and guardian sig)
        bytes calldata blsPayload = sigData[64:sigData.length - 65];

        // Parse nodeIds count
        if (blsPayload.length < 32) return 1;
        uint256 nodeIdsLength = uint256(bytes32(blsPayload[0:32]));
        if (nodeIdsLength == 0 || nodeIdsLength > 100) return 1;

        uint256 nodeIdsDataLength = nodeIdsLength * 32;
        // Expected: nodeIdsLength(32) + nodeIds(N*32) + blsSig(256) + messagePoint(256) + messagePointSig(65)
        uint256 expectedLength = 32 + nodeIdsDataLength + 256 + 256 + 65;
        if (blsPayload.length != expectedLength) return 1;

        uint256 baseOffset = 32 + nodeIdsDataLength;

        // Verify messagePoint signature (owner must sign userOpHash+messagePoint — prevents cross-op replay)
        bytes calldata messagePoint = blsPayload[baseOffset + 256:baseOffset + 512];
        bytes calldata messagePointSignature = blsPayload[baseOffset + 512:baseOffset + 577];

        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
        address mpRecovered = mpHash.recover(messagePointSignature);
        if (mpRecovered != owner) return 1;

        // BLS verification via validator router
        address blsAlg = validator.getAlgorithm(ALG_BLS);
        if (blsAlg == address(0)) return 1;

        // BLS payload for validator: nodeIds + blsSig + messagePoint (skip nodeIdsLength prefix)
        bytes calldata blsVerifyData = blsPayload[32:baseOffset + 512];

        try IAAStarAlgorithm(blsAlg).validate(userOpHash, blsVerifyData) returns (uint256 blsResult) {
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

    /// @dev Map algId to its security tier level.
    ///
    ///      Tier model (cumulative factors):
    ///        Tier 1 — single factor:  ECDSA (0x02) or bare P256 passkey (0x03)
    ///        Tier 2 — dual factor:    P256 passkey + BLS DVT co-sign (0x04)
    ///        Tier 3 — triple factor:  P256 + BLS + Guardian ECDSA (0x05) or legacy BLS triple (0x01)
    ///
    ///      Bare P256 passkey (0x03) is Tier 1 — it is the default single-factor auth
    ///      for all standard transactions. DVT co-sign (BLS) is required for Tier 2+.
    function _algTier(uint8 algId) internal pure returns (uint8) {
        if (algId == ALG_CUMULATIVE_T3) return 3;     // P256 + BLS + Guardian ECDSA
        if (algId == ALG_BLS) return 3;               // legacy BLS triple (ECDSA×2 + BLS, M2 format)
        if (algId == ALG_CUMULATIVE_T2) return 2;     // P256 + BLS DVT co-sign
        if (algId == ALG_ECDSA) return 1;             // bare ECDSA
        if (algId == ALG_P256) return 1;              // bare P256 passkey (single-factor)
        if (algId == ALG_COMBINED_T1) return 1;       // zero-trust combined (P256 + ECDSA)
        if (algId == ALG_SESSION_KEY) return 1;       // session key (ephemeral, time-limited, Tier 1)
        return 0;                                      // unknown algId — fails all tier enforcement
    }

    // ─── Execution ────────────────────────────────────────────────────

    /// @notice Execute a single call from this account.
    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyOwnerOrEntryPoint nonReentrant {
        uint8 algId = msg.sender == entryPoint ? _consumeValidatedAlgId() : ALG_ECDSA;
        _enforceGuard(value, algId, dest, func);
        _call(dest, value, func);
    }

    /// @notice Execute a batch of calls from this account.
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata value,
        bytes[] calldata func
    ) external onlyOwnerOrEntryPoint nonReentrant {
        if (dest.length != value.length || dest.length != func.length) {
            revert ArrayLengthMismatch();
        }
        uint8 algId = msg.sender == entryPoint ? _consumeValidatedAlgId() : ALG_ECDSA;
        for (uint256 i = 0; i < dest.length; i++) {
            _enforceGuard(value[i], algId, dest[i], func[i]);
            _call(dest[i], value[i], func[i]);
        }
    }

    /// @dev Combined tier + guard enforcement, called before every _call.
    ///      algId is resolved once per execute/executeBatch invocation:
    ///      - EntryPoint calls: consumed from transient storage queue
    ///      - Direct owner calls: forced to ALG_ECDSA (tier 1)
    ///
    ///      Tier check uses CUMULATIVE daily spend to prevent bypass:
    ///      - Batch bypass: 10×0.1 ETH in one executeBatch with ECDSA would
    ///        total 1 ETH but each call is ≤ tier1Limit. Each call reads the
    ///        updated dailySpent (written by previous guard.checkTransaction),
    ///        so by call 2 alreadySpent+value crosses the tier1 boundary → reverts.
    ///      - Multi-TX bypass: 10 separate UserOps each ≤ tier1Limit. Same fix
    ///        works because dailySpent persists across transactions.
    /// @dev ERC20 transfer(address,uint256) and approve(address,uint256) selectors
    bytes4 internal constant ERC20_TRANSFER  = 0xa9059cbb;
    bytes4 internal constant ERC20_APPROVE   = 0x095ea7b3;

    function _enforceGuard(uint256 value, uint8 algId, address dest, bytes calldata func) internal {
        // ETH tier enforcement: cumulative daily spend prevents batch/multi-TX bypass
        if (tier1Limit > 0 || tier2Limit > 0) {
            uint256 alreadySpent = address(guard) != address(0) ? guard.todaySpent() : 0;
            uint8 required = requiredTier(alreadySpent + value);
            if (required > 0) {
                uint8 provided = _algTier(algId);
                if (provided < required) {
                    revert InsufficientTier(required, provided);
                }
            }
        }

        // ETH daily limit + algorithm whitelist (writes dailySpent so next batch call sees updated value)
        if (address(guard) != address(0)) {
            guard.checkTransaction(value, algId);
        }

        // ERC20/DeFi token tier + daily limit enforcement (M5.1 + M6.6b)
        if (func.length >= 4 && address(guard) != address(0)) {
            bool tokenHandled = false;

            // M6.6b: DeFi parser registry check (runs first, more specific)
            if (parserRegistry != address(0)) {
                address parser = ICalldataParserRegistry(parserRegistry).getParser(dest);
                if (parser != address(0)) {
                    (address tok, uint256 amt) = ICalldataParser(parser).parseTokenTransfer(func);
                    if (tok != address(0) && amt > 0) {
                        guard.checkTokenTransaction(tok, amt, algId);
                        tokenHandled = true;
                    }
                }
            }

            // Fallback: native ERC20 transfer/approve parsing (M5.1)
            if (!tokenHandled && func.length >= 68) {
                bytes4 sel = bytes4(func[:4]);
                if (sel == ERC20_TRANSFER || sel == ERC20_APPROVE) {
                    uint256 tokenAmount = abi.decode(func[36:68], (uint256));
                    guard.checkTokenTransaction(dest, tokenAmount, algId);
                }
            }
        }
    }

    // ─── Transient Storage AlgId Queue ────────────────────────────────

    /// @dev Push validated algId to transient storage queue.
    ///      Called during validateUserOp (validation phase).
    function _storeValidatedAlgId(uint8 algId) internal {
        assembly {
            let writeIdx := tload(ALG_ID_SLOT_BASE)
            tstore(add(add(ALG_ID_SLOT_BASE, 2), writeIdx), algId)
            tstore(ALG_ID_SLOT_BASE, add(writeIdx, 1))
        }
    }

    /// @dev Pop validated algId from transient storage queue.
    ///      Called during execute/executeBatch (execution phase).
    function _consumeValidatedAlgId() internal returns (uint8 algId) {
        assembly {
            let readIdx := tload(add(ALG_ID_SLOT_BASE, 1))
            algId := tload(add(add(ALG_ID_SLOT_BASE, 2), readIdx))
            tstore(add(ALG_ID_SLOT_BASE, 1), add(readIdx, 1))
        }
    }

    // ─── Social Recovery (F28) ───────────────────────────────────────

    /// @notice Add a recovery guardian. Max 3 guardians.
    function addGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0) || _guardian == owner) revert InvalidGuardian();
        if (_guardianCount >= 3) revert MaxGuardiansReached();

        // Check not already set
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == _guardian) revert GuardianAlreadySet();
        }

        _setGuardian(_guardianCount, _guardian);
        emit GuardianAdded(_guardianCount, _guardian);
        _guardianCount++;
    }

    /// @notice Remove a guardian by index.
    function removeGuardian(uint8 index) external onlyOwner {
        if (index >= _guardianCount) revert InvalidGuardian();

        address removed = _getGuardian(index);

        // Shift remaining guardians
        for (uint8 i = index; i < _guardianCount - 1; i++) {
            _setGuardian(i, _getGuardian(uint8(i + 1)));
        }
        _setGuardian(_guardianCount - 1, address(0));
        _guardianCount--;

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
            approvalBitmap: uint256(1) << guardianIndex,
            cancellationBitmap: 0
        });

        emit RecoveryProposed(_newOwner, msg.sender);
        emit RecoveryApproved(_newOwner, msg.sender, 1);
    }

    /// @notice Approve an active recovery proposal.
    function approveRecovery() external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();

        uint8 guardianIndex = _guardianIndex(msg.sender);
        uint256 bit = uint256(1) << guardianIndex;
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

    /// @notice Vote to cancel active recovery. Requires 2-of-3 guardian threshold.
    /// @dev Same security level as recovery itself. Owner cannot cancel because
    ///      if the key is stolen, the thief could block legitimate recovery.
    ///      Each guardian votes independently; when threshold is reached, recovery is cancelled.
    function cancelRecovery() external {
        if (activeRecovery.newOwner == address(0)) revert NoActiveRecovery();

        uint8 guardianIndex = _guardianIndex(msg.sender); // reverts if not guardian
        uint256 bit = uint256(1) << guardianIndex;
        if (activeRecovery.cancellationBitmap & bit != 0) revert AlreadyCancelVoted();

        activeRecovery.cancellationBitmap |= bit;
        uint256 count = _popcount(activeRecovery.cancellationBitmap);

        emit RecoveryCancelVoted(msg.sender, count);

        if (count >= RECOVERY_THRESHOLD) {
            delete activeRecovery;
            emit RecoveryCancelled();
        }
    }

    /// @dev Get guardian address by index from packed storage.
    function _getGuardian(uint8 i) private view returns (address) {
        if (i == 0) return _guardian0;
        if (i == 1) return _guardian1;
        return _guardian2;
    }

    /// @dev Set guardian address by index into packed storage.
    function _setGuardian(uint8 i, address addr) private {
        if (i == 0) { _guardian0 = addr; return; }
        if (i == 1) { _guardian1 = addr; return; }
        _guardian2 = addr;
    }

    /// @dev Find guardian index or revert
    function _guardianIndex(address addr) internal view returns (uint8) {
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == addr) return i;
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
