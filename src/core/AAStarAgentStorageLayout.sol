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
        uint8 passkeyWeight;   // P256 passkey signature weight (default: 3)
        uint8 ecdsaWeight;     // Owner ECDSA signature weight  (default: 2)
        uint8 blsWeight;       // DVT BLS aggregate weight      (default: 2)
        uint8 guardian0Weight; // Guardian[0] ECDSA weight      (default: 1)
        uint8 guardian1Weight; // Guardian[1] ECDSA weight      (default: 1)
        uint8 guardian2Weight; // Guardian[2] ECDSA weight      (default: 1)
        uint8 _padding;        // Reserved for future weight source
        uint8 tier1Threshold;  // Min weight for Tier 1 ops (default: 3; 0 = config uninitialized)
        uint8 tier2Threshold;  // Min weight for Tier 2 ops (default: 5)
        uint8 tier3Threshold;  // Min weight for Tier 3 ops (default: 6)
    }

    struct WeightChangeProposal {
        WeightConfig proposed;
        uint256 proposedAt;
        uint256 approvalBitmap; // bit i = guardian[i] approved
    }

    // ── State (slots 0..23 — must match the historical account layout exactly) ──

    /// @notice The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)
    address public entryPoint;                                                            // slot 0

    /// @notice Account owner and ECDSA signer (mutable for social recovery)
    address public owner;                                                                 // slot 1

    /// @notice Optional validator router for external algorithms (BLS, PQ, etc.)
    IAAStarValidator public validator;                                                    // slot 2

    /// @notice Optional BLS aggregator for batch verification
    address public blsAggregator;                                                         // slot 3

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
    ///      Only approveAlgorithm() mutates it (monotonic add). Appended at slot 24 — never reorder.
    mapping(uint8 => bool) public approvedAlgorithms;                                     // slot 24

    /// @dev Monotonic nonce for ERC-7579 module install/uninstall guardian signatures (issue #75).
    ///      Incremented after every successful installModule AND uninstallModule so a guardian
    ///      signature collected for one install can never be replayed after an uninstall+reinstall.
    ///      Appended at slot 25 — never reorder.
    uint256 internal _moduleManagementNonce;                                              // slot 25

    /// @dev Monotonic nonce for guardian-signed `setAggregatorWithGuardians` (issue #45). Prevents
    ///      replay of a guardian signature set across multiple aggregator changes.
    ///      Appended at slot 26 — never reorder.
    uint256 internal _aggregatorNonce;                                                    // slot 26
}
