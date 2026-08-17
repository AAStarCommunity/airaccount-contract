// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IAAStarValidator} from "../interfaces/IAAStarValidator.sol";
import {AAStarGlobalGuard} from "./AAStarGlobalGuard.sol";

/// @title AAStarAgentStorageLayout
/// @notice Shared persistent-storage layout for AAStarAirAccountBase and AirAccountExtension.
/// @dev Diamond-lite pattern: the account routes cold selectors (ERC-8004 agent + weight-config
///      governance) to a singleton extension via `fallback` + `delegatecall`. Because delegatecall
///      runs the extension code in the ACCOUNT's storage context, both contracts MUST agree on the
///      exact storage layout for every slot the extension touches.
///
///      Both AAStarAirAccountBase and AirAccountExtension inherit this contract FIRST, so the
///      linearized layout is identical and matches the historical account layout slot-for-slot
///      (verified with `forge inspect storageLayout`). Declaration order here is load-bearing —
///      do NOT reorder, retype, or insert fields except by appending at the end.
///
///      Only persistent state lives here. Constants, custom errors, events and modifiers are
///      declared in the consumers (same signatures → same selectors / topic0), and transient
///      (EIP-1153) slots are accessed by literal slot number, so they need no declaration.
abstract contract AAStarAgentStorageLayout is Initializable {
    // ── Structs referenced by state (shared so the extension can read/write them) ──

    struct RecoveryProposal {
        address newOwner;
        uint256 proposedAt;
        uint256 approvalBitmap;      // bit 0 = guardian[0], bit 1 = guardian[1], bit 2 = guardian[2]
        uint256 cancellationBitmap;  // same layout, for 2-of-3 cancel threshold
    }

    struct WeightConfig {
        // Each individual factor weight MUST be strictly less than tier1Threshold
        // (_validateWeightConfig enforces this). This ensures no single factor can
        // reach T1 alone — T1 always requires at least two factors (e.g. passkey +
        // KMS ECDSA). From the user's perspective T1 is "single passkey" because the
        // KMS TEE transparently co-signs with the stored EOA key; the contract sees
        // both P256 (bit 0) and ECDSA (bit 1) in the bitmap.
        uint8 passkeyWeight;   // P256 passkey signature weight  (recommended: 2; must be < tier1Threshold)
        uint8 ecdsaWeight;     // Owner ECDSA signature weight   (recommended: 2; must be < tier1Threshold)
        uint8 blsWeight;       // DVT BLS aggregate weight       (recommended: 2; must be < tier1Threshold)
        uint8 guardian0Weight; // Guardian[0] ECDSA weight       (recommended: 1; must be < tier1Threshold)
        uint8 guardian1Weight; // Guardian[1] ECDSA weight       (recommended: 1; must be < tier1Threshold)
        uint8 guardian2Weight; // Guardian[2] ECDSA weight       (recommended: 1; must be < tier1Threshold)
        uint8 _padding;        // Reserved for future weight source
        uint8 tier1Threshold;  // Min accumulated weight for Tier 1 ops (recommended: 3; 0 = uninitialised)
        uint8 tier2Threshold;  // Min accumulated weight for Tier 2 ops (recommended: 5)
        uint8 tier3Threshold;  // Min accumulated weight for Tier 3 ops (recommended: 6)
    }

    struct WeightChangeProposal {
        WeightConfig proposed;
        uint256 proposedAt;
        uint256 approvalBitmap; // bit i = guardian[i] approved
    }

    /// @dev Pending two-step module-install proposal (issue #58 / KI-6). Packed: module(20) +
    ///      moduleTypeId(1) + proposedAt(5) + executeAfter(5) = 31 bytes share one slot; initDataHash
    ///      and authHash occupy the next two slots.
    struct ModuleInstallProposal {
        address module;        // module contract to install
        uint8 moduleTypeId;    // 1=validator, 2=executor, 4=hook
        uint40 proposedAt;     // timestamp the proposal was created (0 = no active proposal)
        uint40 executeAfter;   // FIXED execution deadline captured at propose time = proposedAt +
                               // timelock-at-propose; never recomputed, so a later timelock change
                               // cannot move (or overflow) an existing proposal's window.
        bytes32 initDataHash;  // keccak256 of the module init data the execute step must reproduce
        bytes32 authHash;      // snapshot of keccak256(owner, guardian0..2, guardianCount) at propose
                               // time; execute reverts if the auth config changed during the window
                               // (owner replaced via social recovery, or any guardian add/remove).
    }

    // ── State (slots 0..23 — must match the historical account layout exactly) ──

    /// @notice The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)
    address public entryPoint;                                                            // slot 0

    /// @notice Account owner and ECDSA signer (mutable for social recovery)
    address public owner;                                                                 // slot 1

    /// @notice Optional validator router for external algorithms (BLS, PQ, etc.)
    IAAStarValidator public validator;                                                    // slot 2

    /// @dev RESERVED (slot 3). Previously `address public blsAggregator` — a per-account batch
    ///      aggregator. Removed in issue #45 Part B: the batch aggregator is now a SINGLE
    ///      protocol-level value on AAStarBLSKeyRegistry (`blsAlgorithm.aggregator()`), set only by the
    ///      protocol Safe. There is intentionally NO per-account aggregator and NO account-side
    ///      setter. The slot is retained (not deleted) to preserve the historical numbering of
    ///      slots 4..25 below — never reuse or reorder it.
    address private __reservedSlot3_blsAggregator;                                        // slot 3 (reserved)

    /// @notice Global guard for spending limits (set at construction, cannot be removed)
    AAStarGlobalGuard public guard;                                                       // slot 4

    /// @notice Optional calldata parser registry for DeFi protocol support (address(0) = disabled)
    address public parserRegistry;                                                        // slot 5

    /// @dev Installed module registry keyed by module type (1=validator, 2=executor, 4=hook).
    mapping(uint256 => mapping(address => bool)) internal _installedModules;              // slot 6

    /// @dev installModule permission threshold. 40=owner-only, 70=owner+1guardian(default), 100=owner+2.
    uint8 internal _installModuleThreshold;                                               // slot 7 (off 0)

    /// @dev Active ERC-7579 hook module address (at most one active hook per account).
    address internal _activeHook;                                                         // slot 7 (off 1)

    /// @notice P256 public key x-coordinate
    bytes32 public p256KeyX;                                                              // slot 8

    /// @notice P256 public key y-coordinate
    bytes32 public p256KeyY;                                                              // slot 9

    /// @notice Tier1 max (ECDSA only)
    uint256 public tier1Limit;                                                            // slot 10
    /// @notice Tier2 max (dual factor); above this requires multi-sig (BLS triple)
    uint256 public tier2Limit;                                                            // slot 11

    // Packed: _guardian0 (20 bytes) + _guardianCount (1 byte) share slot 12.
    address internal _guardian0;                                                          // slot 12 (off 0)
    uint8 internal _guardianCount;                                                        // slot 12 (off 20)
    address internal _guardian1;                                                          // slot 13
    address internal _guardian2;                                                          // slot 14
    uint256 internal _guardianRemovalNonce;                                               // slot 15
    uint256 internal _tierLimitNonce;                                                     // slot 16
    /// @dev Latches true the first time tier limits are ever configured. Never resets.
    bool internal _tierLimitsInitialized;                                                 // slot 17

    /// @notice Active recovery proposal
    RecoveryProposal public activeRecovery;                                               // slots 18-21

    /// @notice Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails.
    WeightConfig public weightConfig;                                                     // slot 22

    /// @notice Pending weight-change proposal (M6.2). proposedAt == 0 means none pending.
    WeightChangeProposal public pendingWeightChange;                                      // slot 23

    /// @notice Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4).
    /// @dev Moved here from AAStarGlobalGuard so the account can enforce the whitelist during
    ///      validateUserOp (ERC-7562 permits reading the account's OWN storage in validation,
    ///      but NOT the separate unstaked guard's storage). The guard no longer owns a whitelist,
    ///      eliminating the dual-source desync the mirror approach would have created.
    ///      Only approveAlgorithm() mutates it (monotonic add). Appended at slot 26 — never reorder.
    mapping(uint8 => bool) public approvedAlgorithms;                                     // slot 26 (forge inspect; comment was off-by-2)

    /// @dev Monotonic nonce for ERC-7579 module install/uninstall guardian signatures (issue #75).
    ///      Incremented after every successful installModule AND uninstallModule so a guardian
    ///      signature collected for one install can never be replayed after an uninstall+reinstall.
    ///      Appended at slot 27 — never reorder.
    uint256 internal _moduleManagementNonce;                                              // slot 27 (forge inspect; comment was off-by-2)

    /// @notice Optional per-account module-install timelock in seconds (issue #58 / KI-6).
    /// @dev 0 = disabled (default): module installs are immediate at the configured threshold,
    ///      preserving the legacy UX. When > 0, installing at the default owner+1-guardian threshold
    ///      becomes a two-step propose → (wait `_moduleInstallTimelock`) → execute flow, giving other
    ///      guardians/owner a window to cancel a single dual-key compromise. An elevated owner+2-guardian
    ///      authorization may still install immediately (bypass). Appended at slot 28 — never reorder.
    uint256 internal _moduleInstallTimelock;                                              // slot 28 (forge inspect; comment was off-by-2)

    /// @dev Pending module-install proposal (issue #58 / KI-6). proposedAt == 0 means none pending.
    ///      Appended at slots 29-31 (3-slot struct) — never reorder.
    ModuleInstallProposal internal _pendingModuleInstall;                                 // slots 29-31 (forge inspect; comment was off-by-2)

    // ── P-256 guardian keys (issue #119) — appended at slots 32-37; never reorder ──────────────
    // When a guardian slot holds P256_GUARDIAN_SENTINEL (address(0x7026)), the corresponding
    // key pair below stores the guardian's passkey public key (secp256r1 / P-256).
    // Unused slots hold (0, 0). Layout mirrors the three guardian address slots above.
    // NOTE: slot numbers below are the ACTUAL compiled slots (forge inspect storage-layout),
    // verified identical for AAStarAirAccountV7 and AirAccountExtension — this parity is what makes
    // the fallback→delegatecall sharing of these fields safe.

    /// @dev P-256 public key for guardian slot 0 (x-coord). Non-zero iff _guardian0 == SENTINEL.
    bytes32 internal _guardianP256X0;                                                      // slot 32
    /// @dev P-256 public key for guardian slot 0 (y-coord).
    bytes32 internal _guardianP256Y0;                                                      // slot 33
    /// @dev P-256 public key for guardian slot 1 (x-coord). Non-zero iff _guardian1 == SENTINEL.
    bytes32 internal _guardianP256X1;                                                      // slot 34
    /// @dev P-256 public key for guardian slot 1 (y-coord).
    bytes32 internal _guardianP256Y1;                                                      // slot 35
    /// @dev P-256 public key for guardian slot 2 (x-coord). Non-zero iff _guardian2 == SENTINEL.
    bytes32 internal _guardianP256X2;                                                      // slot 36
    /// @dev P-256 public key for guardian slot 2 (y-coord).
    bytes32 internal _guardianP256Y2;                                                      // slot 37

    /// @dev Monotonic counter incremented each time a recovery round ends (executeRecovery or
    ///      cancelRecovery). P-256 guardian signatures embed this nonce so a signature collected
    ///      during round N cannot be replayed in round N+1. Appended at slot 38.
    uint256 internal _recoveryNonce;                                                       // slot 38

    /// @dev Monotonic counter for guardian addition operations. Prevents replay of a
    ///      guardian-signed "add guardian X" message after that addition is completed.
    uint256 internal _guardianAdditionNonce;                                               // slot 39

    /// @dev CC-102 F-W5/F-W7: pending bootstrap guardian addition. The add that REACHES
    ///      RECOVERY_THRESHOLD (count 1 → 2) both completes a recovery quorum and lets an owner-only
    ///      signer subset reach Tier-3, so a stolen owner key could otherwise instantly self-add two
    ///      puppet guardians and irreversibly take over. That specific add is two-step + timelocked;
    ///      this holds the proposed guardian and its propose time. Packed: address(20) + uint40(5)
    ///      share one slot. Appended at slot 40. (0 address / 0 time = no pending addition.)
    address internal _pendingGuardian;                                                     // slot 40
    uint40  internal _pendingGuardianAt;                                                   // slot 40 (packed)

    // ── P-256 key slot helpers ─────────────────────────────────────────────────────────────────────
    // Shared by AAStarAirAccountBase (removeGuardian) and AirAccountExtension (all P-256 ops).
    // Defined here so both inheritors use a single implementation without duplicating logic.

    function _getP256Key(uint8 i) internal view virtual returns (bytes32 x, bytes32 y) {
        if (i == 0) return (_guardianP256X0, _guardianP256Y0);
        if (i == 1) return (_guardianP256X1, _guardianP256Y1);
        return (_guardianP256X2, _guardianP256Y2);
    }

    function _setP256Key(uint8 i, bytes32 x, bytes32 y) internal virtual {
        if (i == 0) { _guardianP256X0 = x; _guardianP256Y0 = y; return; }
        if (i == 1) { _guardianP256X1 = x; _guardianP256Y1 = y; return; }
        _guardianP256X2 = x; _guardianP256Y2 = y;
    }

    function _clearP256Key(uint8 i) internal virtual {
        if (i == 0) { _guardianP256X0 = 0; _guardianP256Y0 = 0; return; }
        if (i == 1) { _guardianP256X1 = 0; _guardianP256Y1 = 0; return; }
        _guardianP256X2 = 0; _guardianP256Y2 = 0;
    }
}
