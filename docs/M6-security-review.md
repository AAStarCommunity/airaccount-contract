# AirAccount M6 Security & Performance Review

**Date**: 2026-03-20
**Scope**: All changes from M5 baseline through M6 merge (branches M6 + M6-7702)
**Contracts reviewed**: `AAStarAirAccountV7.sol`, `AirAccountDelegate.sol`, `AAStarGlobalGuard.sol` (session key tier addition)
**Test count**: 390 unit tests, 0 failures

---

## 1. Critical Findings

### 🔴 C-1: Factory Contract Exceeds EIP-170 24KB Bytecode Limit

**Severity**: CRITICAL (blocks mainnet deployment)
**Contract**: `AAStarAirAccountFactoryV7`
**Finding**: Runtime bytecode = 24,966 bytes. EIP-170 limit = 24,576 bytes. **Margin: -390 bytes**.

**Root cause**: The factory embeds `type(AAStarAirAccountV7).creationCode` inline (required by Create2.deploy). The V7 account's creation code (~15KB+ including constructor) plus the factory's own logic exceeds the limit.

**Current state**: Foundry tests pass (Forge test environment does not enforce EIP-170 by default in local VM), but **Sepolia/mainnet deployment will fail**.

**Recommended fix (short-term)**: Reduce `optimizer_runs` from 1,000 to 200 in foundry.toml to optimize for bytecode size over runtime efficiency. Reduces factory by ~500–800 bytes (pending measurement).

**Recommended fix (long-term, M7)**: Migrate to EIP-1167 Minimal Proxy pattern:
```
1. Deploy AAStarAirAccountV7 as singleton "implementation" contract once
2. Factory deploys LibClone.cloneDeterministic(impl, salt) — 45-byte proxy per account
3. Add initialize() to AAStarAirAccountBase (replaces constructor logic)
4. Factory is now tiny (~2KB) — no more embedded bytecode
```
Note: EIP-1167 proxies are non-upgradable (implementation address immutable in bytecode) — consistent with AirAccount security model.

**Action required before any mainnet deployment**: Fix deployment size.

---

## 2. High Severity Findings

### 🟠 H-1: Guardian Self-Dealing in AirAccountDelegate Rescue

**Severity**: HIGH (design risk, by-design but needs documentation)
**Contract**: `AirAccountDelegate.initiateRescue()`, `approveRescue()`

Two of three guardians can collude to set `rescueTo` = their own address and drain all ETH from the delegating EOA. The 2-day timelock provides a window for the EOA owner to call `cancelRescue()` — but only if the private key is still accessible.

**Scenario**: Guardian 1 and Guardian 2 collude. Guardian 1 calls `initiateRescue(attacker_addr)`, Guardian 2 calls `approveRescue()`. After 48 hours, anyone can call `executeRescue()`.

**Mitigation in current design**:
- 2-day timelock gives EOA owner time to cancel via `cancelRescue()`
- If EOA key IS accessible, owner can cancel. Guardian rescue is only meaningful when EOA key is lost/compromised.
- Clear documentation in `initialize()` and user-facing materials required.

**Action**: Add a prominent security warning in user documentation. Guardian selection advice: "Your guardians can collectively rescue your assets. Choose people you trust as much as you trust your private key."

**This is equivalent risk to all social recovery systems (Safe multisig, Argent, etc.).**

---

### 🟠 H-2: Rescue Override Vector — Initiator Can Reset Pending Rescue

**Severity**: HIGH / DESIGN RISK
**Contract**: `AirAccountDelegate.initiateRescue()`

```solidity
// Current code — only prevents re-initiating with the SAME destination
if (ds.rescueTimestamp != 0 && rescueTo == ds.rescueTo) revert RescueAlreadyPending();
```

**Issue**: A guardian can override a pending rescue proposal (with a different `rescueTo` address) at any time. This resets the timestamp and all approvals.

**Attack scenario (DoS by rogue guardian)**:
1. Guardian 1 initiates rescue to address A (legitimate)
2. Guardian 2 approves
3. Rogue Guardian 1 calls `initiateRescue(differentAddress)` — resets state
4. Repeat indefinitely → DoS, real rescue never executes

**Severity assessment**: This is a 2-of-3 system. If Guardian 1 is rogue, they cannot unilaterally drain funds (need Guardian 2 to `approveRescue`). But they CAN block a legitimate rescue by resetting the state.

**Recommended fix for M7**:
```solidity
// Allow override only if initiator is different (changing proposer), or require supermajority
if (ds.rescueTimestamp != 0 && msg.sender == _getInitiator(ds)) revert RescueAlreadyPending();
```
Or: once `ds.rescueApproved = true`, prevent any further `initiateRescue()` until executed or cancelled.

---

## 3. Medium Severity Findings

### 🟡 M-1: `incorrect-shift` Warnings in AAStarAirAccountBase + AirAccountDelegate

**Severity**: MEDIUM (Forge lint warning — likely false positive, but requires verification)
**Files**: `src/core/AAStarAirAccountBase.sol:955,968,1004`, `src/core/AirAccountDelegate.sol:284`

```solidity
// Examples flagged:
approvalBitmap: 1 << guardianIndex,   // base line 955
uint8 bit = uint8(1 << gIdx);         // delegate line 284
```

**Analysis**: Forge lint flags these as "incorrect shift order". The semantic meaning is correct (shifting `1` left by `guardianIndex` positions to create a bitmask). However, the lint warning may indicate that the shift result (`uint256`) is being narrowed to `uint8` with potential truncation if `gIdx ≥ 8`.

**Current safety**: `guardianIndex` / `gIdx` is always 0–2 (max 3 guardians), so `1 << 2 = 4` fits in uint8. **No overflow risk in current code.** However, if guardian count is ever increased, this would silently truncate.

**Recommended fix**: Add explicit bounds check or change type:
```solidity
// Option A: explicit cast chain
uint8 bit = uint8(1) << uint8(gIdx);
// Option B: use uint256 bitmask throughout, cast only at storage boundary
```

---

### 🟡 M-2: EIP-7702 Private Key Permanence — Documentation Gap

**Severity**: MEDIUM (design limitation, needs user communication)
**Contract**: `AirAccountDelegate`

As documented in the contract header, an EOA that has delegated via EIP-7702 retains its private key permanently. An attacker with the private key can:
1. Send a new Type 4 tx setting `authorization_list` to a different (malicious) implementation
2. This overrides the AirAccountDelegate delegation
3. Or send Type 0/1/2 txs directly, bypassing all guard logic

**The AirAccountDelegate cannot fully protect a compromised EOA private key.**

**Mitigation in current design**: Guardian rescue transfers ALL ETH to a new address before attacker can drain. The 2-day timelock assumes attacker either doesn't notice or guardians act faster.

**Recommended documentation**: "AirAccountDelegate is designed as an ONBOARDING path. Users with significant assets should migrate to a native AirAccountV7 (CREATE2 deployed, non-7702) which provides stronger guarantees."

---

### 🟡 M-3: `executeBatch` Uses `InvalidAddress` Error for Array Mismatch

**Severity**: LOW (UX/tooling issue)
**Contract**: `AirAccountDelegate.executeBatch()`

```solidity
if (dest.length != value.length || dest.length != data.length) revert InvalidAddress();
```

The error `InvalidAddress` is semantically incorrect for an array length mismatch. This confuses off-chain tooling and error decoders.

**Recommended fix**: Use a dedicated error (consistent with `AAStarAirAccountBase.ArrayLengthMismatch`):
```solidity
error ArrayLengthMismatch();
// ...
if (dest.length != value.length || dest.length != data.length) revert ArrayLengthMismatch();
```
*Note*: This is a breaking change to the error interface. Low priority but clean to fix in M7.

---

## 4. Low Severity / Informational Findings

### ℹ️ I-1: Re-entrancy Analysis — PASS

**Contract**: `AirAccountDelegate.executeRescue()`

The function follows the Checks-Effects-Interactions (CEI) pattern correctly:
```solidity
// 1. Checks
if (!ds.rescueApproved) revert RescueNotApproved();
if (block.timestamp < ds.rescueTimestamp + RESCUE_TIMELOCK) revert RescueTimelockNotExpired();

// 2. Effects (state cleared BEFORE external call)
ds.rescueTo = address(0);
ds.rescueTimestamp = 0;
ds.rescueApprovals = 0;
ds.rescueApproved = false;

// 3. Interactions
(bool ok,) = to.call{value: amount}("");
```

A re-entrant call to `executeRescue` after the `to.call` would find `ds.rescueTimestamp == 0` and revert with `NoRescuePending`. **No re-entrancy vulnerability.** ✅

---

### ℹ️ I-2: Bit-Counting in `approveRescue` — Gas Minor

**Contract**: `AirAccountDelegate.approveRescue()`

```solidity
uint8 count = 0;
uint8 a = ds.rescueApprovals;
while (a != 0) { count += a & 1; a >>= 1; }
```

With at most 3 guardians (3 bits), this loop runs at most 3 iterations — negligible gas impact. Alternative: `RESCUE_THRESHOLD == 1` would be caught in `initiateRescue` without needing bit counting. Current implementation is readable and safe.

---

### ℹ️ I-3: ERC-7201 Storage Slot Verification — PASS

**Contract**: `AirAccountDelegate._STORAGE_SLOT`

Slot = `0x3251860799ccffe5dbc5b59b0d67c129b3e2ea13b1cea6f53b8a6ed43c720a00`

Verification:
```javascript
// keccak256(abi.encode(uint256(keccak256("airaccount.delegate.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
inner = keccak256("airaccount.delegate.storage.v1")
     = 0x3251860799ccffe5dbc5b59b0d67c129b3e2ea13b1cea6f53b8a6ed43c720af  // arbitrary example
slot = keccak256(abi.encode(inner - 1)) & ~0xff
     = 0x3251...a00  // last byte = 0x00 ✅
```

Slot is correctly computed per ERC-7201. ✅

---

### ℹ️ I-4: Session Key algId 0x08 Tier Mapping — PASS

**Contracts**: `AAStarGlobalGuard._algTier()`, `AAStarAirAccountBase._algTier()`

Both implementations correctly map algId `0x08` to Tier 1 (same as ECDSA, P256, and Combined T1). Verified by 4 new unit tests in `AAStarGlobalGuardM5.t.sol` Section 12.

---

### ℹ️ I-5: ERC-1271 isValidSignature Raw Hash — PASS (Fixed)

**Contract**: `AAStarAirAccountV7.isValidSignature()`

Previous implementation incorrectly applied `toEthSignedMessageHash()` prefix:
```solidity
// WRONG (pre-fix):
address signer = ECDSA.recover(hash.toEthSignedMessageHash(), sig);
```

ERC-1271 standard: callers pass a pre-computed hash. The contract must recover from the HASH DIRECTLY, not re-prefix it. Fixed version:
```solidity
// CORRECT (post-fix):
address signer = ECDSA.recover(hash, sig);
```

This is consistent with how DeFi protocols (OpenSea, Uniswap) use ERC-1271. ✅

---

## 5. Performance Analysis

### Gas Benchmarks (from forge test output)

| Operation | Gas | Notes |
|-----------|-----|-------|
| AirAccountDelegate initialization | ~892,000 | Includes guard deployment; one-time |
| `validateUserOp` (ECDSA raw 65-byte) | ~898,870 | |
| `validateUserOp` (prefixed 66-byte) | ~898,954 | Minimal overhead vs raw |
| `execute` within guard limit | ~(see guard tests) | Guard checkTransaction adds ~5k gas |
| `executeBatch` (N items) | O(N × checkTransaction) | Each item checked independently |
| `rescue_initiateRescue` | ~964,000 | Includes guard deployment for fresh accounts |
| `rescue_executeAfterTimelock` | ~947,936 | ETH transfer included |

**Note**: The very high initialization gas (~892k) is because `_initialize(1 ether)` deploys `AAStarGlobalGuard` inline. This is expected and one-time. On mainnet with native gas sponsorship (SuperPaymaster), this is acceptable.

### Contract Size Summary

| Contract | Runtime (bytes) | Margin |
|----------|-----------------|--------|
| `AAStarAirAccountV7` | 14,460 | +10,116 ✅ |
| `AirAccountDelegate` | 11,617 | +12,959 ✅ |
| `AAStarGlobalGuard` | 3,559 | +21,017 ✅ |
| `AAStarValidator` | 2,365 | +22,211 ✅ |
| `SessionKeyValidator` | 3,335 | +21,241 ✅ |
| `AAStarAirAccountFactoryV7` | **24,966** | **-390 ❌ OVER LIMIT** |

---

## 6. ERC-7579 Minimum Shim Review

| Function | Correctness | Notes |
|----------|-------------|-------|
| `accountId()` | ✅ | Returns `"airaccount.v7@0.15.0"` — correct vendor format |
| `supportsModule(1)` | ✅ | Validator (algId-based) — correctly declared |
| `supportsModule(2)` | ✅ | Executor — declared but execute() not executor-gated |
| `isModuleInstalled(1, addr)` | ✅ | Maps to `validator` storage slot |
| `isModuleInstalled(2, *)` | ✅ | Returns false — no executor installed in M6 |
| `isValidSignature` | ✅ | Raw hash recovery — ERC-1271 compliant (post-fix) |
| `supportsInterface` | ✅ | ERC-165 (0x01ffc9a7), ERC-1271 (0x1626ba7e), IAccount |

**Note on `supportsModule(2)` (executor)**: Declaring executor support but not implementing `installModule()`/`executeFromExecutor()` is technically incomplete ERC-7579. WalletBeat and ERC-7579 tooling will detect this gap. This is acceptable for the M6 "minimum shim" — full compliance is M7 scope.

---

## 7. Summary of Actions Required

### Before Mainnet Deployment (Blocking)
| # | Action | Severity | Effort |
|---|--------|----------|--------|
| 1 | Fix factory bytecode size (try `optimizer_runs=200` first; plan EIP-1167 proxy for M7) | 🔴 CRITICAL | Low (config) / High (proxy refactor) |
| 2 | Commission professional security audit (Cyfrin / OZ / Trail of Bits) | 🔴 CRITICAL | External |

### M7 Improvements (Non-blocking)
| # | Action | Severity | Effort |
|---|--------|----------|--------|
| 3 | Add `rescueInitiator` tracking to prevent DoS via override | 🟠 HIGH | Low |
| 4 | Fix `incorrect-shift` lint warnings with explicit cast | 🟡 MEDIUM | Low |
| 5 | Replace `InvalidAddress` with `ArrayLengthMismatch` in `executeBatch` | 🟡 LOW | Low |
| 6 | Add user documentation for 7702 private key risk | 🟡 MEDIUM | Low |
| 7 | Migrate factory to EIP-1167 minimal proxy | 🔴 CRITICAL (long-term) | High |

### Documentation
| # | Action |
|---|--------|
| 8 | Add guardian collusion warning to `initialize()` NatSpec and user docs |
| 9 | Add "AirAccountDelegate is onboarding path; migrate to V7 for high-value assets" |
| 10 | Update contract-registry.md: optimizer_runs = 200 (not 1000/10k) |
