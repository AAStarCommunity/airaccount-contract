# Guard + Tier Integration Plan (v2)

> Resolves: Guard initialization & immutability, algId pass-through, tier enforcement
> Target: v0.12.5 M4

## Problem Summary

| # | Issue | Severity | Current State |
|---|-------|----------|---------------|
| 1 | Guard.owner independent of Account.owner → social recovery breaks guard | Critical | Guard locked after recovery |
| 2 | `setGuard()` can be called anytime → attacker erases guard | Critical | No protection against removal |
| 3 | algId determined in validation but lost before execution | Structural | No tier enforcement possible |
| 4 | requiredTier() and guard.checkTransaction() never called | Feature gap | Modules exist, not wired |

## Core Design Decision: Account Self-Deploys Guard (Set-Once)

### Why not "setGuard" pattern?

The current `setGuard(address _guard) external onlyOwner` has two fatal flaws:
1. **Erasable**: Stolen key → `setGuard(address(0))` → all limits bypassed
2. **Owner mismatch**: Guard.owner ≠ Account.owner after social recovery

### Why not constructor-immutable?

If guard is a constructor parameter of Account, we get a circular dependency:
- Guard needs Account address (to bind `guard.account = account`)
- Account needs Guard address (to set `immutable guard`)
- CREATE2 can't resolve this: Account bytecode includes Guard address, so Account address depends on Guard address, which depends on Account address.

### Solution: `initializeGuard()` — Account Deploys Its Own Guard

The account deploys the guard contract **internally** in a single atomic call.
No circular dependency: the account exists first, then deploys guard with `address(this)`.

```
Account Creation                Guard Initialization
════════════════                ════════════════════

Factory.createAccount()         owner calls initializeGuard()
    │                               │
    ▼                               ▼
AAStarAirAccountV7              Account deploys guard internally:
  deployed with:                  guard = new AAStarGlobalGuard(
    entryPoint ✓                      address(this),  ← account address
    owner ✓                           dailyLimit,
    guard = address(0)                algIds
                                  );
                                  guardInitialized = true ← LOCKED FOREVER
```

**Security guarantees after initialization:**

| Operation | Allowed? | Why |
|-----------|----------|-----|
| Remove guard | ❌ | No `setGuard` function exists |
| Replace guard | ❌ | `guardInitialized` prevents re-init |
| Change guard.account | ❌ | `immutable` in guard constructor |
| Change dailyLimit | ⬇️ only | Can only decrease (tighten), never increase |
| Add algorithm | ✅ | More options = convenience, not less security |
| Remove algorithm | ❌ | Would weaken security |
| Social recovery | ✅ | Guard.account = account address (unchanged) |

## Architecture: Complete Data Flow

```
                        ERC-4337 Transaction Flow
                        ═════════════════════════

  ┌─────────────────────────────────────────────────────────────┐
  │ Phase 1: VALIDATION (EntryPoint → validateUserOp)           │
  │                                                             │
  │  signature[0] → algId routing                               │
  │  _validateSignature(hash, sig) → 0 or 1                    │
  │  _lastValidatedAlgId = algId   ← persist for execution     │
  │                                                             │
  │  [No guard side effects — ERC-7562 compliant]               │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ Phase 2: EXECUTION (EntryPoint → execute/executeBatch)      │
  │                                                             │
  │  algId = _lastValidatedAlgId                                │
  │                                                             │
  │  ┌─ Step 1: Tier Enforcement ─────────────────────────────┐ │
  │  │  tier = requiredTier(value)                            │ │
  │  │  if _algTier(algId) < tier → revert InsufficientTier   │ │
  │  └────────────────────────────────────────────────────────┘ │
  │                                                             │
  │  ┌─ Step 2: Guard Enforcement ────────────────────────────┐ │
  │  │  guard.checkTransaction(value, algId)                  │ │
  │  │  → Algorithm whitelist check (revert if not approved)  │ │
  │  │  → Daily spending accumulation + limit check           │ │
  │  └────────────────────────────────────────────────────────┘ │
  │                                                             │
  │  ┌─ Step 3: Execute ──────────────────────────────────────┐ │
  │  │  _call(dest, value, data)                              │ │
  │  └────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────┘
```

## Implementation Details

### Change 1: AAStarGlobalGuard — Account-owned, monotonic config

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

/// @title AAStarGlobalGuard — Immutable spending guard bound to an AA account
/// @notice Deployed BY the account contract. Cannot be removed or transferred.
/// @dev Configuration is monotonic: limits can only tighten, algorithms can only be added.
contract AAStarGlobalGuard {
    /// @notice The AA account that owns this guard (immutable, set at construction)
    address public immutable account;

    uint256 public dailyLimit;
    mapping(uint256 => uint256) public dailySpent;
    mapping(uint8 => bool) public approvedAlgorithms;

    error OnlyAccount();
    error CanOnlyDecreaseLimit(uint256 current, uint256 requested);
    error CannotRevokeAlgorithm();
    error DailyLimitExceeded(uint256 requested, uint256 remaining);
    error AlgorithmNotApproved(uint8 algId);

    event DailyLimitDecreased(uint256 oldLimit, uint256 newLimit);
    event AlgorithmApproved(uint8 indexed algId);
    event SpendRecorded(uint256 indexed day, uint256 amount, uint256 totalSpent);

    modifier onlyAccount() {
        if (msg.sender != account) revert OnlyAccount();
        _;
    }

    constructor(address _account, uint256 _dailyLimit, uint8[] memory _algIds) {
        account = _account;
        dailyLimit = _dailyLimit;
        for (uint256 i = 0; i < _algIds.length; i++) {
            approvedAlgorithms[_algIds[i]] = true;
            emit AlgorithmApproved(_algIds[i]);
        }
    }

    // ─── Guard Check (called by account in execute) ─────────────

    function checkTransaction(uint256 value, uint8 algId) external returns (bool) {
        if (!approvedAlgorithms[algId]) revert AlgorithmNotApproved(algId);

        if (dailyLimit > 0 && value > 0) {
            uint256 today = block.timestamp / 1 days;
            uint256 spent = dailySpent[today];
            uint256 remaining = dailyLimit > spent ? dailyLimit - spent : 0;
            if (value > remaining) {
                revert DailyLimitExceeded(value, remaining);
            }
            dailySpent[today] = spent + value;
            emit SpendRecorded(today, value, spent + value);
        }

        return true;
    }

    function remainingDailyAllowance() external view returns (uint256) {
        if (dailyLimit == 0) return type(uint256).max;
        uint256 today = block.timestamp / 1 days;
        uint256 spent = dailySpent[today];
        return dailyLimit > spent ? dailyLimit - spent : 0;
    }

    // ─── Monotonic Configuration (only tighten, never loosen) ───

    /// @notice Decrease daily limit. Can NEVER increase.
    function decreaseDailyLimit(uint256 _newLimit) external onlyAccount {
        if (_newLimit >= dailyLimit) {
            revert CanOnlyDecreaseLimit(dailyLimit, _newLimit);
        }
        uint256 old = dailyLimit;
        dailyLimit = _newLimit;
        emit DailyLimitDecreased(old, _newLimit);
    }

    /// @notice Add a new approved algorithm. Can NEVER revoke.
    function approveAlgorithm(uint8 algId) external onlyAccount {
        approvedAlgorithms[algId] = true;
        emit AlgorithmApproved(algId);
    }

    // No revokeAlgorithm — monotonic security
    // No setDailyLimit (increase) — monotonic security
}
```

**Key properties:**
- `account` is `immutable` — set at construction, never changes, zero SLOAD cost
- No `owner` field — no sync problem with social recovery
- Daily limit: **decrease only** — can tighten but never loosen
- Algorithm whitelist: **add only** — can approve new ones, never revoke
- No self-destruct, no transferOwnership — guard is permanent

### Change 2: AAStarAirAccountBase — Guard initialization (set-once)

```solidity
// ── New storage ──
bool public guardInitialized;
uint8 internal _lastValidatedAlgId;

// ── New errors ──
error GuardAlreadyInitialized();
error InsufficientTier(uint8 required, uint8 provided);

// ── New events ──
event GuardInitialized(address indexed guard, uint256 dailyLimit);

/// @notice Initialize the global guard. Can only be called ONCE.
/// @dev Account deploys the guard contract internally — no circular dependency.
/// @param _dailyLimit Daily spending limit in wei (0 = unlimited)
/// @param _algIds Initial approved algorithm IDs
function initializeGuard(
    uint256 _dailyLimit,
    uint8[] calldata _algIds
) external onlyOwner {
    if (guardInitialized) revert GuardAlreadyInitialized();

    // Account deploys guard with itself as the bound account
    guard = new AAStarGlobalGuard(address(this), _dailyLimit, _algIds);
    guardInitialized = true;

    emit GuardInitialized(address(guard), _dailyLimit);
}

// REMOVE: setGuard() — no longer exists, guard cannot be set/changed externally
```

**Why `guardInitialized` flag instead of checking `address(guard) != address(0)`?**
Extra safety: even if guard's CREATE somehow fails and returns address(0) (shouldn't happen but defense in depth), the flag prevents retry.

### Change 3: Remove setGuard, add guard config helpers

```solidity
// REMOVE entirely:
// function setGuard(address _guard) external onlyOwner { ... }

// ADD monotonic config helpers:

/// @notice Approve a new algorithm in the guard (add-only, never revoke)
function guardApproveAlgorithm(uint8 algId) external onlyOwner {
    if (address(guard) == address(0)) revert GuardNotInitialized();
    guard.approveAlgorithm(algId);
}

/// @notice Decrease the guard's daily limit (tighten-only, never increase)
function guardDecreaseDailyLimit(uint256 newLimit) external onlyOwner {
    if (address(guard) == address(0)) revert GuardNotInitialized();
    guard.decreaseDailyLimit(newLimit);
}
```

**Alternative**: User can also call via `execute(guardAddr, 0, abi.encodeCall(...))` since account is guard's `account`. The helpers are convenience.

### Change 4: algId persistence in _validateSignature

```solidity
function _validateSignature(
    bytes32 userOpHash,
    bytes calldata signature
) internal returns (uint256 validationData) {
    if (signature.length == 0) return 1;

    uint8 firstByte = uint8(signature[0]);

    if (firstByte == ALG_BLS) {
        _lastValidatedAlgId = ALG_BLS;
        return _validateTripleSignature(userOpHash, signature[1:]);
    }

    if (firstByte == ALG_P256 && signature.length == 65) {
        _lastValidatedAlgId = ALG_P256;
        return _validateP256(userOpHash, signature[1:]);
    }

    if (firstByte == ALG_ECDSA) {
        if (signature.length == 66) {
            _lastValidatedAlgId = ALG_ECDSA;
            return _validateECDSA(userOpHash, signature[1:]);
        }
        return 1;
    }

    if (signature.length == 65) {
        _lastValidatedAlgId = ALG_ECDSA; // backwards compat (M1)
        return _validateECDSA(userOpHash, signature);
    }

    if (address(validator) == address(0)) return 1;
    _lastValidatedAlgId = firstByte; // external algorithm
    return validator.validateSignature(userOpHash, signature);
}
```

**ERC-7562 compliance**: Writing to account's OWN storage slot during validation is explicitly allowed. `_lastValidatedAlgId` is the account's own slot.

**Gas**: ~2,900 (warm SSTORE value change). Future optimization: EIP-1153 `tstore`/`tload` = 200 gas.

### Change 5: Tier + Guard enforcement in execute

```solidity
// Map algId to security tier level
function _algTier(uint8 algId) internal pure returns (uint8) {
    if (algId == ALG_BLS) return 3;   // BLS triple = highest
    if (algId == ALG_P256) return 2;  // P256 passkey = medium
    return 1;                          // ECDSA = baseline
}

function execute(
    address dest,
    uint256 value,
    bytes calldata func
) external onlyOwnerOrEntryPoint {
    _enforceGuard(value);
    _call(dest, value, func);
}

function executeBatch(
    address[] calldata dest,
    uint256[] calldata value,
    bytes[] calldata func
) external onlyOwnerOrEntryPoint {
    if (dest.length != value.length || dest.length != func.length) {
        revert ArrayLengthMismatch();
    }
    for (uint256 i = 0; i < dest.length; i++) {
        _enforceGuard(value[i]);
        _call(dest[i], value[i], func[i]);
    }
}

/// @dev Combined tier + guard enforcement, called before every _call
function _enforceGuard(uint256 value) internal {
    uint8 algId = _lastValidatedAlgId;

    // Tier enforcement (skip if not configured)
    if (tier1Limit > 0 || tier2Limit > 0) {
        uint8 required = requiredTier(value);
        if (required > 0) {
            uint8 provided = _algTier(algId);
            if (provided < required) {
                revert InsufficientTier(required, provided);
            }
        }
    }

    // Guard enforcement (skip if not initialized)
    if (address(guard) != address(0)) {
        guard.checkTransaction(value, algId);
    }
}
```

### Change 6: Social recovery — zero changes needed

```solidity
function executeRecovery() external {
    // ... existing checks ...
    owner = r.newOwner;
    delete activeRecovery;
    // Guard is unaffected:
    //   guard.account == address(this) == unchanged
    //   guardInitialized == true == unchanged
    //   dailyLimit, approvedAlgorithms == unchanged
    //
    // New owner can:
    //   - guardApproveAlgorithm() ← add new algorithms ✓
    //   - guardDecreaseDailyLimit() ← tighten limits ✓
    //   - Cannot remove guard ✓
    //   - Cannot increase limits ✓
}
```

## Tier Enforcement Truth Table

| Value | Tier | algId | algTier | Result |
|-------|------|-------|---------|--------|
| 0.05 ETH | 1 (≤0.1) | ECDSA | 1 | ✅ Pass |
| 0.05 ETH | 1 | BLS | 3 | ✅ Pass (over-secured OK) |
| 0.5 ETH | 2 (≤1.0) | ECDSA | 1 | ❌ InsufficientTier(2, 1) |
| 0.5 ETH | 2 | P256 | 2 | ✅ Pass |
| 0.5 ETH | 2 | BLS | 3 | ✅ Pass (over-secured OK) |
| 5 ETH | 3 (>1.0) | ECDSA | 1 | ❌ InsufficientTier(3, 1) |
| 5 ETH | 3 | P256 | 2 | ❌ InsufficientTier(3, 2) |
| 5 ETH | 3 | BLS | 3 | ✅ Pass |
| any | 0 (unconfigured) | any | any | ✅ Pass |

## Account Lifecycle with Guard

```
Phase 1: Account Creation
═════════════════════════
Factory.createAccount(owner, salt)
  → AAStarAirAccountV7 deployed
  → guard = address(0), guardInitialized = false
  → Account is functional but unguarded

Phase 2: Guard Initialization (ASAP after creation, ideally same UserOp batch)
═══════════════════════════════════════════════════════════════════════════════
owner calls: account.initializeGuard(1 ether, [0x01, 0x02, 0x03])
  → Account internally deploys AAStarGlobalGuard(address(this), 1 ether, [BLS, ECDSA, P256])
  → guard = deployed address
  → guardInitialized = true  ← LOCKED FOREVER
  → From now on, every execute() checks guard

Phase 3: Normal Usage
═════════════════════
UserOp → validateUserOp(_lastValidatedAlgId = ECDSA)
       → execute(dest, 0.05 ETH, data)
         → _enforceGuard(0.05 ETH): tier=1, alg=ECDSA(1) → ✅
         → guard.checkTransaction(0.05 ETH, ECDSA) → daily OK → ✅
         → _call() → ✅

Phase 4: Social Recovery
════════════════════════
guardian1.proposeRecovery(newOwner) → ✅
guardian2.approveRecovery() → ✅
[2 days pass]
anyone.executeRecovery() → owner = newOwner ✅
  → guard unchanged: guard.account == address(this) == unchanged
  → dailyLimit unchanged, approvedAlgorithms unchanged

Phase 5: New Owner Uses Account
════════════════════════════════
newOwner UserOp → validateUserOp(sig by newOwner) → ✅
               → execute(dest, 0.05 ETH, data) → guard enforced → ✅
newOwner calls: account.guardApproveAlgorithm(0x04) → ✅ (add new alg)
newOwner calls: account.guardDecreaseDailyLimit(0.5 ether) → ✅ (tighten)
newOwner calls: account.guardDecreaseDailyLimit(2 ether) → ❌ CanOnlyDecreaseLimit
```

## Attack Scenarios Blocked

| Attack | Before (vulnerable) | After (blocked) |
|--------|-------------------|-----------------|
| Key stolen → erase guard | `setGuard(address(0))` → ✅ succeeds | No `setGuard` function → ❌ |
| Key stolen → increase limit | `guard.setDailyLimit(MAX)` → ✅ | Only `decreaseDailyLimit` exists → ❌ |
| Key stolen → revoke algorithm whitelist then use weak alg | `guard.revokeAlgorithm(BLS)` → ✅ | No revoke function → ❌ |
| Social recovery → guard locked | New owner can't configure guard → broken | Guard.account = address(this) → ✅ works |
| Deploy fake guard | `setGuard(maliciousAddr)` → ✅ | Account deploys guard internally → ❌ |

## Edge Case: Account Created Without Guard

Accounts without guard initialization work normally — no tier enforcement, no daily limits.
This is a conscious user choice (e.g., testing, small-value accounts).

If the user later realizes they want a guard:
- Call `initializeGuard()` — works anytime (if not already initialized)
- Once initialized, permanent

If the key is stolen BEFORE guard initialization:
- Attacker could call `initializeGuard()` with their own favorable config
- **Mitigation**: documentation should strongly recommend initializing guard in the same UserOp batch as account creation
- **Future mitigation**: Factory variant that deploys account + guard atomically

## Files to Modify

| File | Changes |
|------|---------|
| `src/core/AAStarGlobalGuard.sol` | Full rewrite: `owner` → `account` (immutable), monotonic config, constructor takes algIds |
| `src/core/AAStarAirAccountBase.sol` | Remove `setGuard`, add `initializeGuard` (set-once), `_lastValidatedAlgId`, `_enforceGuard`, `_algTier`, modify execute/executeBatch/_validateSignature |
| `test/AAStarGlobalGuard.t.sol` | Rewrite for account-owned model + monotonic tests |
| `test/AAStarAirAccountV7_M3.t.sol` | Add tier enforcement + guard integration tests |
| `test/SocialRecovery.t.sol` | Add: guard survives recovery + new owner config tests |

**No changes needed:**
- `AAStarAirAccountV7.sol` — validateUserOp unchanged
- `AAStarAirAccountFactoryV7.sol` — guard not in factory (account self-deploys)
- `AAStarValidator.sol` / `AAStarBLSAlgorithm.sol` — unaffected

## Gas Impact

| Operation | Before | After | Delta |
|-----------|--------|-------|-------|
| validateUserOp | ~25,000 | ~27,900 | +2,900 (SSTORE algId) |
| execute (no guard) | ~21,000 | ~21,300 | +300 (SLOAD + tier check) |
| execute (with guard) | ~21,000 | ~28,000 | +7,000 (guard external call) |
| executeBatch (N, guard) | ~21k+N×8k | ~21k+N×15k | +N×7,000 |
| initializeGuard (one-time) | 0 | ~200,000 | Guard deployment cost |

Guard deployment (~200k gas) is one-time. Per-transaction overhead (~7k with guard, ~300 without) is comparable to Safe's guard module (~8k).
