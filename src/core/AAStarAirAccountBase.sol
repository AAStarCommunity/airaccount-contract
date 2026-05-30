// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {IAAStarAlgorithm} from "../interfaces/IAAStarAlgorithm.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";
import {ICalldataParser, ICalldataParserRegistry} from "../interfaces/ICalldataParser.sol";
import {AAStarAgentStorageLayout} from "./AAStarAgentStorageLayout.sol";
import {AirAccountExtension} from "./AirAccountExtension.sol";

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
abstract contract AAStarAirAccountBase is AAStarAgentStorageLayout {
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
    uint8 internal constant ALG_WEIGHTED    = 0x07;   // Weighted multi-signature (configurable per-source weights)
    // algId 0x10: Reserved for post-quantum signature scheme (ML-DSA/Dilithium).
    // Requires EVM precompile (EIP-TBD). Implementation deferred until precompile availability (~2027-2029).

    uint256 internal constant G2_POINT_LENGTH = 256;

    /// @dev EIP-7212 P256 verification precompile
    address internal constant P256_VERIFIER = address(0x100);

    /// @dev Recovery timelock
    uint256 internal constant RECOVERY_TIMELOCK = 2 days;

    /// @dev Recovery threshold: 2 out of 3 guardians
    uint256 internal constant RECOVERY_THRESHOLD = 2;

    // ─── State ────────────────────────────────────────────────────────

    // `entryPoint` (slot 0) and `owner` (slot 1) are declared in AAStarAgentStorageLayout so the
    // AgentExtension facet shares them across the fallback delegatecall boundary. Layout unchanged.

    /// @notice Singleton AgentExtension holding ERC-8004 agent functions, reached via fallback.
    /// @dev Deployed once per implementation in the constructor; baked into runtime as an immutable,
    ///      so all EIP-1167 clones of this implementation resolve to the same extension address.
    ///      Splitting agent code out keeps the account runtime under EIP-170's 24,576-byte limit.
    address public immutable agentExtension;


    // ── algId Pass-Through (validation → execution) ──
    // Uses transient storage (EIP-1153) to avoid cross-UserOp contamination.
    // When EntryPoint bundles multiple UserOps from the same sender,
    // validation runs for all ops before execution. A storage variable would
    // be overwritten by the last validation, but transient storage keyed by
    // nonce ensures each execution reads the correct algId.

    /// @dev Transient storage slot base for algId (slot = ALG_ID_SLOT_BASE + nonce)
    uint256 internal constant ALG_ID_SLOT_BASE = 0x0A1600;

    /// @dev Transient storage slot base for session key identifier (parallel queue to ALG_ID_SLOT_BASE).
    ///      Only populated when algId == ALG_SESSION_KEY. Consumed in _enforceGuard for scope check.
    ///      Encodes session type in the top byte:
    ///        0x01 → ECDSA session: remaining 20 bytes are the session key address
    ///        0x02 → P256 session:  remaining 31 bytes are the low 31 bytes of keccak256(keyX||keyY)
    uint256 internal constant SESSION_KEY_SLOT_BASE = 0x0A1700;

    /// @dev Transient storage slot base for accumulated signature weight (parallel queue to ALG_ID_SLOT_BASE).
    ///      Only populated when algId == ALG_WEIGHTED. Consumed in execute/executeBatch to resolve tier.
    uint256 internal constant WEIGHT_SLOT_BASE = 0x0A1800;

    /// @dev HIGH-3 FIX — transient slot holding keccak256(callData) of the UserOp currently being
    ///      validated or executed. Set at the entry of validateUserOp and execute/executeBatch.
    ///      The algId / weight / sessionKey transient entries are keyed by content
    ///      (slot = keccak256(callDataKey, tag)) instead of a shared, revert-rollback-able FIFO
    ///      read index. Because execute()'s msg.data equals the validated userOp.callData, each
    ///      UserOp reads exactly the authentication it validated under, even if an earlier op in
    ///      the same bundle reverts during execution. Reads are non-destructive (idempotent).
    ///      Residual edge: two ops with byte-identical callData in one bundle share a slot (last
    ///      validation wins) — narrow and fail-safe (the actions are identical), and still strictly
    ///      safer than the previous index that desynced on ANY execution revert.
    uint256 internal constant CALLDATA_KEY_SLOT = 0x0A1900;


    /// @dev Timelock for weakening weight-change proposals (M6.2)
    uint256 internal constant WEIGHT_CHANGE_TIMELOCK  = 2 days;
    /// @dev 2-of-3 guardians required to approve a weakening change
    uint256 internal constant WEIGHT_CHANGE_THRESHOLD = 2;
    /// @dev Proposals expire after 30 days if never executed
    uint256 internal constant WEIGHT_CHANGE_EXPIRY    = 30 days;

    /// @notice Read-only snapshot of the account's current configuration.
    ///         Used by off-chain UIs and tools like ForceExitModule to read account state.
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
    error SessionScopeViolation();
    error InvalidTierConfig();
    error CannotIncreaseTierLimit();
    error TierLimitSigExpired();
    /// @dev HIGH-2: Agent session keys must use execute(), not executeBatch(), when a hook module
    ///      (TierGuardHook) is installed. executeBatch does not invoke preCheck, so the hook's
    ///      session scope enforcement (callTargets / selectorAllowlist) would be bypassed.
    ///      Until per-call scope enforcement is implemented for batched calls, agent session ops
    ///      are restricted to single execute() calls.
    ///      TODO: implement per-call scope enforcement for executeBatch (tracking issue).
    error AgentSessionBatchNotSupported();
    // M7.2 ERC-7579 Module Management
    error ModuleAlreadyInstalled();
    error ModuleNotInstalled();
    error InvalidModuleType();
    /// @dev onInstall callback failed — module not initialized; install aborted.
    error ModuleInstallCallbackFailed(uint256 moduleTypeId, address module);
    error ModuleInvalid();
    error InstallModuleUnauthorized();
    error HookReverted();

    // M6.1 / M6.2
    error WeightConfigNotInitialized();

    error MinGuardianRequired();
    error InsufficientGuardianApprovals();
    error DuplicateGuardianSig();
    error InsecureWeightConfig();
    error InsufficientWeight(uint8 tier, uint8 provided, uint8 required);
    error WeakeningRequiresProposal();
    error WeightChangePending();
    error WeightChangeTimelockNotExpired();
    error WeightChangeNotApproved();
    error NoWeightChangeProposal();
    error WeightChangeAlreadyApproved();
    // M8.1 AgentRegistry / ERC-8004
    error AgentRegistrationFailed();
    error IdentityRegistrationFailed();
    error ReputationRegistryFailed();
    /// @dev Passed registry is not the official ERC-8004 deployment for this chain.
    error UnauthorizedRegistry();

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
    event WeightConfigUpdated(WeightConfig config);
    event WeightChangeProposed(WeightConfig proposed, address indexed proposedBy);
    event WeightChangeApproved(address indexed approvedBy, uint256 approvalCount);
    event WeightChangeExecuted(WeightConfig oldConfig, WeightConfig newConfig);
    event WeightChangeCancelled();
    event ModuleInstalled(uint256 indexed moduleTypeId, address indexed module);
    event ModuleUninstalled(uint256 indexed moduleTypeId, address indexed module);
    event AgentWalletSet(uint256 indexed agentId, address indexed agentWallet, address agentRegistry);
    event AgentIdentityMinted(uint256 indexed agentId, address indexed identityRegistry, string agentURI);
    event ERC8004WalletBound(uint256 indexed agentId, address indexed agentWallet, address indexed identityRegistry);
    event AgentReputationSubmitted(uint256 indexed agentId, address indexed reputationRegistry, int128 value, string tag1);

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

    // ─── Construction & Agent Fallback (diamond-lite) ─────────────────

    /// @dev Deploys the singleton AgentExtension and records it as an immutable. This runs in the
    ///      IMPLEMENTATION's constructor (creation code only — not part of EIP-170 runtime size),
    ///      so the ~2KB of agent logic leaves the account's runtime bytecode while every clone of
    ///      this implementation still resolves to one shared extension instance.
    constructor() {
        agentExtension = address(new AirAccountExtension());
    }

    /// @dev Routes any selector not defined on the account to the AgentExtension via delegatecall,
    ///      forwarding raw calldata (no re-encoding). delegatecall preserves msg.sender, address(this),
    ///      storage, events and reverts — so agent calls behave exactly as if they were inline.
    ///      Unknown selectors hit the extension, which has no matching function and reverts.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        address ext = agentExtension;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ─── Initialization ───────────────────────────────────────────────

    /// @dev Internal initializer — called by AAStarAirAccountV7.initialize() via the initializer modifier.
    ///      Guard must be pre-deployed by the factory (or test helper) before calling this.
    ///      Keeping guard deployment in this function would embed AAStarGlobalGuard's creation code
    ///      (~4,595 bytes) in the account's runtime, pushing it over EIP-170's 24,576-byte limit.
    /// @param _entryPoint ERC-4337 EntryPoint address
    /// @param _owner Initial account owner (ECDSA signer)
    /// @param _guardians Three guardian slots (address(0) = unused)
    /// @param _minDailyLimit Floor for guardDecreaseDailyLimit (0 = no floor)
    /// @param _guardAddr Pre-deployed AAStarGlobalGuard address, or address(0) for no guard
    function _initAccount(
        address _entryPoint,
        address _owner,
        address[3] memory _guardians,
        uint256 _minDailyLimit,
        address _guardAddr
    ) internal {
        entryPoint = _entryPoint;
        owner = _owner;

        // Initialize guardians (skip address(0) slots)
        for (uint8 i = 0; i < 3; i++) {
            address g = _guardians[i];
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

        // Accept pre-deployed guard (no guard creation here — keeps account runtime under EIP-170)
        if (_guardAddr != address(0)) {
            guard = AAStarGlobalGuard(_guardAddr);
            emit GuardInitialized(_guardAddr, guard.dailyLimit());
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

    /// @notice Set tier thresholds — INITIAL SETUP ONLY.
    ///         Callable exactly once, ever. After the first configuration (here or via
    ///         modifyTierLimitsWithGuardians), this function is permanently locked.
    ///         Any subsequent modification (increase, decrease, or disable) must go through
    ///         modifyTierLimitsWithGuardians(). Gating on a latch rather than on the current
    ///         limit values closes the bypass where a guardian reset to (0,0) would otherwise
    ///         re-open owner-only configuration.
    function setTierLimits(uint256 _tier1, uint256 _tier2) external onlyOwner {
        if (_tierLimitsInitialized) revert CannotIncreaseTierLimit();
        if (_tier2 > 0 && _tier1 > _tier2) revert InvalidTierConfig();
        _tierLimitsInitialized = true;
        tier1Limit = _tier1;
        tier2Limit = _tier2;
        emit TierLimitsSet(_tier1, _tier2);
    }

    /// @notice Modify tier limits after initial setup — requires RECOVERY_THRESHOLD guardian signatures.
    ///         Handles all post-init changes: increase, decrease, or reset to (0,0) to disable tiering.
    ///         Security principle: the authorization level to change a spending guard must match
    ///         the tier level being guarded (spending at T2 requires a guardian; modifying T2 does too).
    /// @param _tier1        New Tier 1 threshold (single-factor limit).
    /// @param _tier2        New Tier 2 threshold (dual-factor limit). 0 = T2 not used.
    /// @param deadline      Signature expiry timestamp — guardians must sign within this window.
    ///                      Prevents long-term signature hoarding and delayed replay attacks.
    /// @param guardianSigs  ECDSA signatures from RECOVERY_THRESHOLD distinct guardians.
    function modifyTierLimitsWithGuardians(
        uint256 _tier1,
        uint256 _tier2,
        uint256 deadline,
        bytes[] calldata guardianSigs
    ) external onlyOwner {
        if (_tier2 > 0 && _tier1 > _tier2) revert InvalidTierConfig();
        if (block.timestamp > deadline) revert TierLimitSigExpired();
        if (guardianSigs.length < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        bytes32 changeHash = keccak256(abi.encode(
            address(this), block.chainid, _tierLimitNonce, "MODIFY_TIER_LIMITS", _tier1, _tier2, deadline
        )).toEthSignedMessageHash();

        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < guardianSigs.length; i++) {
            address recovered = changeHash.recover(guardianSigs[i]);
            uint8 gIdx = _guardianIndex(recovered);
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _tierLimitNonce++;
        _tierLimitsInitialized = true; // lock out setTierLimits even if guardians configure tiers first
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

        // ALG_WEIGHTED (0x07): Weighted multi-signature — bitmap-driven variable-length
        if (firstByte == ALG_WEIGHTED) {
            _storeValidatedAlgId(ALG_WEIGHTED);
            return _validateWeightedSignature(userOpHash, signature[1:]);
        }

        // Raw ECDSA: 65-byte sig without algId prefix (backwards compat with M1)
        if (signature.length == 65) {
            _storeValidatedAlgId(ALG_ECDSA);
            return _validateECDSA(userOpHash, signature);
        }

        // All other → delegate to external validator router
        if (address(validator) == address(0)) return 1;
        _storeValidatedAlgId(firstByte);
        // SESSION_KEY: save session key identifier so _enforceGuard can verify contractScope/selectorScope.
        // ECDSA session layout: [algId(1)][account(20)][key(20)][ECDSASig(65)] = 106 bytes total
        //   → key address at signature[21:41], tag = 0x01
        // P256 session layout: [algId(1)][account(20)][keyX(32)][keyY(32)][r(32)][s(32)] = 149 bytes total
        //   → keyX at [21:53], keyY at [53:85], tag = 0x02
        if (firstByte == ALG_SESSION_KEY) {
            // Security: reject cross-account session key abuse.
            // sig[1:21] = account embedded in the session key signature.
            // Must equal address(this) — the account currently being validated.
            // Without this check an attacker can use account A's session key to
            // authorize UserOps on account B (audit HIGH finding 2026-03-20).
            if (signature.length < 21 || address(bytes20(signature[1:21])) != address(this)) return 1;

            if (signature.length == 106) {
                address ecdsaKey = address(bytes20(signature[21:41]));
                _storeSessionKey(bytes32(uint256(0x01) << 248 | uint256(uint160(ecdsaKey))));
            } else if (signature.length == 149) {
                bytes32 p256Hash = keccak256(abi.encodePacked(bytes32(signature[21:53]), bytes32(signature[53:85])));
                _storeSessionKey(bytes32(uint256(0x02) << 248 | (uint256(p256Hash) & type(uint248).max)));
            }
        }
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

        // LAYER 1: P256 passkey verifies userOpHash directly (shared with _validateP256)
        if (_validateP256(userOpHash, sigData[0:64]) != 0) return 1;

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

    /// @dev Shared BLS validation helper. Calls the BLS algorithm via validator router.
    ///      Returns 0 on success, 1 on failure (no validator, no BLS alg, or alg returned 1).
    ///      Extracts duplicated try/catch from _validateTripleSignature, _validateCumulativeTier2/3,
    ///      and _validateWeightedSignature to reduce bytecode size.
    function _callBLSValidator(bytes32 hash, bytes calldata blsData) private view returns (uint256) {
        if (address(validator) == address(0)) return 1;
        address blsAlg = validator.getAlgorithm(ALG_BLS);
        if (blsAlg == address(0)) return 1;
        try IAAStarAlgorithm(blsAlg).validate(hash, blsData) returns (uint256 r) {
            return r;
        } catch {
            return 1;
        }
    }

    /// @dev Verify a standard BLS payload laid out as
    ///      [nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][messagePointSig(65)].
    ///      Checks: strict length, owner-signed (userOpHash‖messagePoint) binding, and the aggregate
    ///      BLS signature via the validator router. Shared by cumulative T2/T3 and the weighted BLS
    ///      branch (identical logic — kept in one place to stay under EIP-170). Returns true on success.
    function _blsPayloadValid(bytes32 userOpHash, bytes calldata blsPayload) internal view returns (bool) {
        if (blsPayload.length < 32) return false;
        uint256 nodeIdsLength = uint256(bytes32(blsPayload[0:32]));
        if (nodeIdsLength == 0 || nodeIdsLength > 100) return false;
        uint256 baseOffset = 32 + nodeIdsLength * 32;
        if (blsPayload.length != baseOffset + 256 + 256 + 65) return false;
        bytes calldata messagePoint = blsPayload[baseOffset + 256:baseOffset + 512];
        bytes calldata messagePointSig = blsPayload[baseOffset + 512:baseOffset + 577];
        bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
        if (mpHash.recover(messagePointSig) != owner) return false;
        // BLS verify data omits the nodeIdsLength prefix: [nodeIds][blsSig][messagePoint]
        return _callBLSValidator(userOpHash, blsPayload[32:baseOffset + 512]) == 0;
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
        bytes calldata blsPayload = sigData[32:baseOffset + 512];
        return _callBLSValidator(userOpHash, blsPayload);
    }

    /**
     * @dev Validate weighted multi-signature (algId 0x07).
     *
     * Signature format (after algId byte stripped):
     *   [sourceBitmap(1)][P256?(64)][ECDSA?(65)][BLS_block?(variable)][guardian0?(65)][guardian1?(65)][guardian2?(65)]
     *
     * sourceBitmap bits: 0=P256, 1=ECDSA, 2=BLS, 3=guardian[0], 4=guardian[1], 5=guardian[2], 6-7=reserved(0)
     *
     * BLS block format: [nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][messagePointSig(65)]
     *
     * On success: stores accumulated weight in WEIGHT_SLOT_BASE queue and returns 0.
     * Returns 1 if any component signature is invalid, or if weight < tier1Threshold.
     */
    function _validateWeightedSignature(
        bytes32 userOpHash,
        bytes calldata sigData
    ) internal returns (uint256) {
        WeightConfig memory wc = weightConfig;
        if (wc.tier1Threshold == 0) revert WeightConfigNotInitialized();
        if (sigData.length < 1) return 1;

        uint8 bitmap = uint8(sigData[0]);
        if (bitmap & 0xC0 != 0) return 1; // bits 6-7 must be zero

        uint256 cursor = 1;
        uint8 accumulated = 0;

        // bit 0: P256 passkey (64 bytes: r, s)
        if (bitmap & 0x01 != 0) {
            if (sigData.length < cursor + 64) return 1;
            if (_validateP256(userOpHash, sigData[cursor:cursor + 64]) != 0) return 1;
            accumulated += wc.passkeyWeight;
            cursor += 64;
        }

        // bit 1: Owner ECDSA (65 bytes)
        if (bitmap & 0x02 != 0) {
            if (sigData.length < cursor + 65) return 1;
            if (_validateECDSA(userOpHash, sigData[cursor:cursor + 65]) != 0) return 1;
            accumulated += wc.ecdsaWeight;
            cursor += 65;
        }

        // bit 2: BLS aggregate (variable-length block) — shared helper does the strict-length
        // parse + owner messagePoint binding + BLS verify (also returns false if validator unset).
        if (bitmap & 0x04 != 0) {
            if (sigData.length < cursor + 32) return 1;
            uint256 nodeIdsLength = uint256(bytes32(sigData[cursor:cursor + 32]));
            if (nodeIdsLength == 0 || nodeIdsLength > 100) return 1;
            uint256 blsBlockLen = 32 + nodeIdsLength * 32 + 256 + 256 + 65;
            if (sigData.length < cursor + blsBlockLen) return 1;
            if (!_blsPayloadValid(userOpHash, sigData[cursor:cursor + blsBlockLen])) return 1;
            accumulated += wc.blsWeight;
            cursor += blsBlockLen;
        }

        // bits 3-5: Guardian[0..2] ECDSA (65 bytes each)
        bytes32 guardianHash = userOpHash.toEthSignedMessageHash();
        for (uint8 gi = 0; gi < 3; gi++) {
            if (bitmap & (uint8(1) << (3 + gi)) != 0) {
                if (gi >= _guardianCount) return 1;
                if (sigData.length < cursor + 65) return 1;
                address recovered = guardianHash.recover(sigData[cursor:cursor + 65]);
                if (recovered != _getGuardian(gi)) return 1;
                if (gi == 0) accumulated += wc.guardian0Weight;
                else if (gi == 1) accumulated += wc.guardian1Weight;
                else accumulated += wc.guardian2Weight;
                cursor += 65;
            }
        }

        // Reject if accumulated weight is insufficient for even Tier 1
        if (accumulated < wc.tier1Threshold) return 1;

        // L-1 fix (Codex 2026-05-30): reject trailing/extraneous bytes after the last consumed signature.
        // Without this, signature canonicalisation is broken — relayers/indexers using keccak256(signature)
        // as a uniqueness key would see distinct hashes for semantically identical signatures.
        // The ERC-4337 nonce prevents replay, so trailing bytes are not a security hole, but they ARE
        // a downstream-consumer footgun. Forge canonical form.
        if (cursor != sigData.length) return 1;

        _storeValidatedWeight(accumulated);
        return 0;
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

        // LAYER 2+3: BLS aggregate + owner messagePoint binding (shared helper)
        return _blsPayloadValid(userOpHash, sigData[64:]) ? 0 : 1;
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

        // LAYER 2: BLS aggregate + owner messagePoint binding (bytes between P256 and guardian sig)
        return _blsPayloadValid(userOpHash, sigData[64:sigData.length - 65]) ? 0 : 1;
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
        if (algId == ALG_WEIGHTED) return 0;          // weighted: tier resolved from accumulated weight in execute()
        return 0;                                      // unknown algId — fails all tier enforcement
    }

    // ─── Execution ────────────────────────────────────────────────────

    /// @notice Execute a single call from this account.
    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external onlyOwnerOrEntryPoint nonReentrant {
        // HIGH-3: key the transient queue reads by this op's callData (== validated userOp.callData
        // on the EntryPoint path). Set BEFORE hook dispatch so getCurrentAlgId()/getCurrentSessionKey()
        // peeks resolve to this op's entries.
        _setCallDataKey(keccak256(msg.data));
        // Hook dispatch BEFORE consuming algId — getCurrentAlgId() peeks at current queue entry.
        bool hookActive = _activeHook != address(0);
        if (hookActive) _dispatchHook(value);
        uint8 algId = msg.sender == entryPoint ? _consumeValidatedAlgId() : ALG_ECDSA;
        uint8 guardAlgId = algId;   // preserve pre-resolution algId for guard whitelist check
        if (algId == ALG_WEIGHTED) {
            algId = _resolveWeightedAlgId(_consumeValidatedWeight());
        }
        // Consume session key once per execute invocation (mirrors algId consumption).
        // Passed into _enforceGuard to prevent scope bypass in executeBatch.
        bytes32 taggedSessionKey = (algId == ALG_SESSION_KEY) ? _consumeSessionKey() : bytes32(0);
        // skipEthCheck is always false: the account calls guard.checkTransaction() directly.
        // TierGuardHook cannot call it because guard.checkTransaction has onlyAccount (msg.sender==account),
        // and the hook is a separate contract. Passing false here ensures daily limits are enforced
        // regardless of whether a hook is active.
        _enforceGuard(value, algId, guardAlgId, taggedSessionKey, dest, func, false);
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
        // HIGH-3: content-key the transient queue reads to this op's callData (== validated
        // userOp.callData on the EntryPoint path).
        _setCallDataKey(keccak256(msg.data));
        uint8 algId = msg.sender == entryPoint ? _consumeValidatedAlgId() : ALG_ECDSA;
        uint8 guardAlgId = algId;   // preserve pre-resolution algId for guard whitelist check
        if (algId == ALG_WEIGHTED) {
            algId = _resolveWeightedAlgId(_consumeValidatedWeight());
        }
        // Consume session key ONCE for the entire batch — same as algId is consumed once.
        // Fix: previously _consumeSessionKey() was called inside _enforceGuard (per-call),
        // so calls 2+ in the batch got bytes32(0) and skipped scope enforcement entirely.
        bytes32 taggedSessionKey = (algId == ALG_SESSION_KEY) ? _consumeSessionKey() : bytes32(0);
        // HIGH-2: Agent session keys must NOT use executeBatch when a TierGuardHook is active.
        // executeBatch does not invoke preCheck, so TierGuardHook's callTargets/selectorAllowlist
        // enforcement is bypassed for the entire batch. Until per-call scope enforcement for
        // batched calls is implemented, agent session ops are restricted to single execute() calls.
        // The standard-path session scope (taggedSessionKey != 0) is still enforced per-call via
        // _enforceGuard below; this guard only blocks the hook-validator path.
        if (algId == ALG_SESSION_KEY && _activeHook != address(0)) {
            revert AgentSessionBatchNotSupported();
        }
        // Note: hook dispatch is NOT called for executeBatch — preCheck is single-execute only.
        // The built-in guard still enforces limits per-call via _enforceGuard.
        for (uint256 i = 0; i < dest.length; i++) {
            _enforceGuard(value[i], algId, guardAlgId, taggedSessionKey, dest[i], func[i], false);
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

    /// @dev ERC-7579 preCheck(address,uint256,bytes) selector — keccak256 first 4 bytes.
    bytes4 private constant _PRECHECK_SEL = bytes4(keccak256("preCheck(address,uint256,bytes)"));

    /// @dev Dispatch ERC-7579 preCheck to the active hook module (if any).
    ///      Forwards the full execute() calldata (msg.data) as the `bytes msgData` parameter so
    ///      hook modules can inspect call target and inner selector for scope enforcement.
    ///      msg.data layout for execute(address,uint256,bytes):
    ///        [0:4]   execute() selector
    ///        [4:36]  dest (address padded)
    ///        [36:68] value (uint256)
    ///        [68:100] offset for func bytes param (= 0x60 relative to args start)
    ///        [100:132] func length
    ///        [132:]   func data
    ///      Reverts HookReverted() if hook call fails.
    function _dispatchHook(uint256 ethValue) private {
        address hook = _activeHook;
        bytes4 sel = _PRECHECK_SEL;
        bool ok;
        assembly {
            let cdSize := calldatasize()
            let m := mload(0x40)
            mstore(m,          sel)         // [0:4]   preCheck selector
            mstore(add(m,  4), caller())    // [4:36]  msgSender
            mstore(add(m, 36), ethValue)    // [36:68] msgValue
            mstore(add(m, 68), 0x60)        // [68:100] bytes offset = 96 (relative to args start)
            mstore(add(m,100), cdSize)      // [100:132] bytes length = calldatasize (= full execute calldata)
            calldatacopy(add(m, 132), 0, cdSize) // [132:] = full execute calldata (selector+args)
            // Total size: 4 + 32 + 32 + 32 + 32 + cdSize = 132 + cdSize
            let totalSize := add(132, cdSize)
            ok := call(gas(), hook, 0, m, totalSize, 0, 0)
        }
        if (!ok) revert HookReverted();
    }

    /// @param algId      Resolved algorithm id (post-weighted-resolution). Used for tier checks.
    /// @param guardAlgId Pre-resolution algorithm id. Passed to guard whitelist check so that
    ///                   approving ALG_WEIGHTED(0x07) covers its tier resolutions (0x02/0x04/0x05).
    ///                   Equals algId for all non-weighted algorithms.
    /// @param taggedSessionKey Pre-consumed session key identifier (bytes32(0) if not a session key op).
    ///        Consumed ONCE by execute()/executeBatch() so every call in a batch shares the same
    ///        scope restrictions — preventing scope bypass on calls 2+ in a batch.
    /// @param skipEthCheck When true, skip guard.checkTransaction (hook already called it to avoid
    ///        double-counting the daily ETH limit). false for direct owner calls and executeBatch
    ///        when no hook is active.
    function _enforceGuard(uint256 value, uint8 algId, uint8 guardAlgId, bytes32 taggedSessionKey, address dest, bytes calldata func, bool skipEthCheck) internal {
        // Cache guard address: avoids 3 separate SLOADs (COLD ~2100 + 2×WARM ~100 = ~2300 gas total)
        address guardAddr = address(guard);

        // ETH tier enforcement: cumulative daily spend prevents batch/multi-TX bypass
        if (tier1Limit > 0 || tier2Limit > 0) {
            uint256 alreadySpent = guardAddr != address(0) ? guard.todaySpent() : 0;
            uint8 required = requiredTier(alreadySpent + value);
            if (required > 0) {
                uint8 provided = _algTier(algId);
                if (provided < required) {
                    revert InsufficientTier(required, provided);
                }
            }
        }

        // ETH daily limit + algorithm whitelist (writes dailySpent so next batch call sees updated value)
        // guardAlgId: pre-resolution algId so guard whitelist sees ALG_WEIGHTED(0x07) when that's what
        // was approved — approving 0x07 should not require separately approving resolved 0x02/0x04/0x05.
        //
        // skipEthCheck is always false from execute() — the account holds the correct msg.sender for
        // guard.checkTransaction's onlyAccount modifier. TierGuardHook cannot call it directly.
        if (guardAddr != address(0) && !skipEthCheck) {
            guard.checkTransaction(value, guardAlgId);
        }

        // ERC20/DeFi token tier + daily limit enforcement (M5.1 + M6.6b)
        if (func.length >= 4 && guardAddr != address(0)) {
            _checkTokenGuard(dest, func, guardAlgId);
        }

        // SESSION KEY scope + velocity enforcement (v0.17.2 unified path).
        //
        // taggedSessionKey was consumed ONCE by the caller (execute/executeBatch), not per-call here,
        // so ALL calls in a batch share the same session identifier. The top byte encodes sessionType
        // (0x01 = ECDSA session, lower 20 bytes = key address; 0x02 = P256 session, lower 31 bytes
        // = truncated keyHash). The unified SessionKeyValidator at router[ALG_SESSION_KEY] enforces:
        //   - expiry / revoked
        //   - target scope: callTargets[] takes priority over legacy single contractScope
        //   - selector scope: selectorAllowlist[] takes priority over legacy single selectorScope
        //   - velocity: limit/window counter incremented per-call via recordCallForVelocity
        //
        // Per Codex P0-1 review: velocity SSTORE happens here in EXECUTE phase only (not validate).
        // Per Codex P0-2 review: this branch runs per-call from execute() / executeBatch() loops,
        // so batch paths automatically get array scope + velocity coverage.
        if (algId == ALG_SESSION_KEY && taggedSessionKey != bytes32(0)) {
            if (address(validator) == address(0)) revert SessionScopeViolation();
            address skValidator = IAAStarValidator(address(validator)).getAlgorithm(ALG_SESSION_KEY);
            if (skValidator == address(0)) revert SessionScopeViolation();

            uint8 sessionType = uint8(uint256(taggedSessionKey) >> 248);
            bytes32 keyOrHash;
            if (sessionType == 0x01) {
                // ECDSA session: lower 20 bytes (address) — bytes32 with address in low position
                keyOrHash = bytes32(uint256(uint160(uint256(taggedSessionKey))));
            } else {
                // P256 session: lower 248 bits (truncated keyHash); top byte already zero
                keyOrHash = bytes32(uint256(taggedSessionKey) & type(uint248).max);
            }

            // Scope check (view; reverts internally on violation).
            bytes4 sel = func.length >= 4 ? bytes4(func[:4]) : bytes4(0);
            (bool scopeOk, bytes memory scopeRet) = skValidator.staticcall(
                abi.encodeWithSignature(
                    "checkSessionScope(address,bytes32,uint8,address,bytes4)",
                    address(this), keyOrHash, sessionType, dest, sel
                )
            );
            if (!scopeOk) {
                // Bubble the validator's specific revert reason; falls back to generic if empty.
                if (scopeRet.length > 0) {
                    assembly { revert(add(scopeRet, 0x20), mload(scopeRet)) }
                }
                revert SessionScopeViolation();
            }

            // Velocity counter (state-mutating). msg.sender check in validator gates this to
            // address(this) — which IS the account; safe.
            // skipEthCheck path (e.g. executeFromExecutor pre-decoded) also runs this so
            // executor-routed session calls are equally rate-limited.
            (bool vOk, bytes memory vRet) = skValidator.call(
                abi.encodeWithSignature(
                    "recordCallForVelocity(address,bytes32,uint8)",
                    address(this), keyOrHash, sessionType
                )
            );
            if (!vOk) {
                if (vRet.length > 0) {
                    assembly { revert(add(vRet, 0x20), mload(vRet)) }
                }
                revert SessionScopeViolation();
            }
        }
    }

    // ─── Transient Storage AlgId Queue ────────────────────────────────

    /// @dev HIGH-3 FIX — record the content key (keccak256(callData)) of the UserOp currently
    ///      being validated or executed. Called at the entry of validateUserOp (validation phase,
    ///      key = keccak256(userOp.callData)) and execute/executeBatch (execution phase,
    ///      key = keccak256(msg.data), which equals the validated userOp.callData on the
    ///      EntryPoint path). All algId/weight/sessionKey entries are keyed by this value.
    ///
    /// @dev AUDIT NOTE — HIGH-3 residual (#52, classified LOW by AAStar 2026-05-30):
    ///      _setCallDataKey uses keccak256(callData) only. Within one bundle, two UserOps with
    ///      byte-identical callData but different nonces share the same transient slot, so a
    ///      lower-tier UserOp can read the algId written by a higher-tier UserOp.
    ///
    ///      Why this is LOW, not HIGH:
    ///        - Identical callData ⇒ identical (dest, value, func). Attacker cannot redirect funds,
    ///          change amount, or change function — they can only DUPLICATE an operation the
    ///          victim already authorized.
    ///        - Attacker gains zero value (recipient is the victim's chosen recipient, not attacker).
    ///        - Customer impact at worst: a griefing double-execution of a transfer the customer was
    ///          already going to make. No theft. No privilege escalation beyond what the high-tier
    ///          UserOp the customer is submitting already grants.
    ///        - Requires the attacker to already hold owner-ECDSA (itself a catastrophic compromise)
    ///          + a mempool-observable identical-callData high-tier UserOp + specific bundle ordering.
    ///
    ///      Tracked for full hardening in #52 (key by (sender, nonce, callData) + single-use
    ///      consumption). Future reviewers: do NOT classify this as High — see this note.
    function _setCallDataKey(bytes32 key) internal {
        assembly { tstore(CALLDATA_KEY_SLOT, key) }
    }

    /// @dev Transient slot for a queue entry of the current UserOp: keccak256(callDataKey, tag).
    ///      Uses scratch space (0x00–0x3f) only — does not touch the free-memory pointer at 0x40.
    function _queueSlot(uint256 tag) private view returns (uint256 slot) {
        assembly {
            mstore(0x00, tload(CALLDATA_KEY_SLOT))
            mstore(0x20, tag)
            slot := keccak256(0x00, 0x40)
        }
    }

    /// @notice Peek at the current UserOp's algId without consuming it.
    ///         Called by TierGuardHook.preCheck() during execute() so the hook enforces tier
    ///         limits using the same algId as the guard. Returns 0 (ALG_NONE) if none stored.
    function getCurrentAlgId() external view returns (uint256 algId) {
        uint256 slot = _queueSlot(ALG_ID_SLOT_BASE);
        assembly { algId := tload(slot) }
    }

    /// @notice Peek at the current UserOp's session key without consuming it.
    ///         Called by TierGuardHook.preCheck() for session scope enforcement (M8.P2).
    ///         Top byte: 0x01 = ECDSA session (lower 20 bytes = address), 0x02 = P256 session.
    function getCurrentSessionKey() external view returns (bytes32 taggedId) {
        uint256 slot = _queueSlot(SESSION_KEY_SLOT_BASE);
        assembly { taggedId := tload(slot) }
    }

    /// @dev Store the validated algId for the current UserOp (keyed by callData content).
    function _storeValidatedAlgId(uint8 algId) internal {
        uint256 slot = _queueSlot(ALG_ID_SLOT_BASE);
        assembly { tstore(slot, algId) }
    }

    /// @dev Read the current UserOp's validated algId (content-keyed, non-destructive).
    ///      HIGH-3 fix: keyed by keccak256(callData) instead of a revert-rollback-able FIFO read
    ///      index, so a prior op's execution revert in the same bundle cannot bleed its algId here.
    function _consumeValidatedAlgId() internal view returns (uint8 algId) {
        uint256 slot = _queueSlot(ALG_ID_SLOT_BASE);
        assembly { algId := tload(slot) }
    }

    /// @dev Store the tagged session key for the current UserOp. Top byte = 0x01/0x02.
    function _storeSessionKey(bytes32 taggedId) internal {
        uint256 slot = _queueSlot(SESSION_KEY_SLOT_BASE);
        assembly { tstore(slot, taggedId) }
    }

    /// @dev Read the current UserOp's session key (content-keyed, non-destructive).
    function _consumeSessionKey() internal view returns (bytes32 taggedId) {
        uint256 slot = _queueSlot(SESSION_KEY_SLOT_BASE);
        assembly { taggedId := tload(slot) }
    }

    /// @dev Store the accumulated signature weight for the current UserOp.
    function _storeValidatedWeight(uint8 weight) internal {
        uint256 slot = _queueSlot(WEIGHT_SLOT_BASE);
        assembly { tstore(slot, weight) }
    }

    /// @dev Read the current UserOp's accumulated weight (content-keyed, non-destructive).
    function _consumeValidatedWeight() internal view returns (uint8 weight) {
        uint256 slot = _queueSlot(WEIGHT_SLOT_BASE);
        assembly { weight := tload(slot) }
    }

    /// @dev ERC20/DeFi token guard enforcement shared by _enforceGuard and executeFromExecutor.
    ///      Checks DeFi parser registry first, falls back to native ERC20 transfer/approve parsing.
    ///      try/catch on getParser(): a buggy/malicious registry must not block execution (LOW audit 2026-03-20).
    function _checkTokenGuard(address dest, bytes calldata data, uint8 algId) internal {
        bool tokenHandled;
        if (parserRegistry != address(0)) {
            try ICalldataParserRegistry(parserRegistry).getParser(dest) returns (address parser) {
                if (parser != address(0)) {
                    try ICalldataParser(parser).parseTokenTransfer(data) returns (address tok, uint256 amt) {
                        if (tok != address(0) && amt > 0) {
                            guard.checkTokenTransaction(tok, amt, algId);
                            tokenHandled = true;
                        }
                    } catch {}
                }
            } catch {}
        }
        if (!tokenHandled && data.length >= 68) {
            bytes4 sel = bytes4(data[:4]);
            if (sel == ERC20_TRANSFER || sel == ERC20_APPROVE) {
                guard.checkTokenTransaction(dest, abi.decode(data[36:68], (uint256)), algId);
            }
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
    ///         Requires >= RECOVERY_THRESHOLD distinct guardian signatures to prevent unilateral removal.
    ///         Cannot remove when only 2 guardians remain (minimum 2 must be kept).
    /// @param index   Guardian slot to remove (0-indexed)
    /// @param guardianSigs At least RECOVERY_THRESHOLD guardian signatures over the removal hash
    function removeGuardian(uint8 index, bytes[] calldata guardianSigs) external onlyOwner {
        // Removal during active recovery would let a compromised owner cancel recovery with
        // pre-collected guardian sigs — bypassing the guardian-only cancelRecovery() guard.
        if (activeRecovery.newOwner != address(0)) revert RecoveryAlreadyActive();
        if (_guardianCount <= 2) revert MinGuardianRequired();
        if (index >= _guardianCount) revert InvalidGuardian();
        if (guardianSigs.length < RECOVERY_THRESHOLD || guardianSigs.length > _guardianCount)
            revert InsufficientGuardianApprovals();

        address guardianToRemove = _getGuardian(index);
        // Hash binds to the actual guardian address (not just index) to prevent mismatch
        // if slot order ever changes without incrementing the nonce.
        bytes32 removalHash = keccak256(abi.encode(
            address(this),
            block.chainid,
            _guardianRemovalNonce,
            "REMOVE_GUARDIAN",
            guardianToRemove
        ));
        bytes32 ethHash = removalHash.toEthSignedMessageHash();

        uint256 approvalBitmap = 0;
        for (uint256 i = 0; i < guardianSigs.length; i++) {
            address recovered = ethHash.recover(guardianSigs[i]);
            uint8 gIdx = _guardianIndex(recovered); // reverts NotGuardian if not a guardian
            uint256 bit = uint256(1) << gIdx;
            if (approvalBitmap & bit != 0) revert DuplicateGuardianSig();
            approvalBitmap |= bit;
        }
        if (_popcount(approvalBitmap) < RECOVERY_THRESHOLD) revert InsufficientGuardianApprovals();

        _guardianRemovalNonce++;

        for (uint8 i = index; i < _guardianCount - 1; i++) {
            _setGuardian(i, _getGuardian(uint8(i + 1)));
        }
        _setGuardian(_guardianCount - 1, address(0));
        _guardianCount--;

        emit GuardianRemoved(index, guardianToRemove);
    }

    /// @notice Propose a recovery: change owner to a new address.
    ///         Any guardian can propose. Requires RECOVERY_THRESHOLD approvals.
    function proposeRecovery(address _newOwner) external {
        if (_newOwner == address(0) || _newOwner == owner) revert InvalidNewOwner();
        for (uint8 i = 0; i < _guardianCount; i++) {
            if (_getGuardian(i) == _newOwner) revert InvalidNewOwner();
        }
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

        uint8 guardianIndex = _guardianIndex(msg.sender);
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


    /// @dev Map accumulated weight to the highest satisfied tier's representative algId.
    ///      Used in execute/executeBatch to translate ALG_WEIGHTED into a normal algId.
    function _resolveWeightedAlgId(uint8 weight) internal view returns (uint8) {
        WeightConfig memory wc = weightConfig;
        if (wc.tier3Threshold > 0 && weight >= wc.tier3Threshold) return ALG_CUMULATIVE_T3;
        if (wc.tier2Threshold > 0 && weight >= wc.tier2Threshold) return ALG_CUMULATIVE_T2;
        if (wc.tier1Threshold > 0 && weight >= wc.tier1Threshold) return ALG_ECDSA;
        return 0; // below tier1 — fails all tier and guard checks
    }


    receive() external payable {}
}
