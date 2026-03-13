# AirAccount Gas Analysis Report

**Date**: 2026-03-10
**Network**: Sepolia (Cancun EVM)
**Compiler**: Solc 0.8.33, via-IR, 10k optimizer runs

---

## Executive Summary

AirAccount M3 achieves **127,249 gas** for a basic ECDSA UserOp execution on Sepolia — a **51% improvement over M2** (259,694 gas) and **75.7% improvement over the legacy YetAnotherAA** (523,306 gas).

---

## Deployment Costs

| Contract | Deployment Gas | Size (bytes) |
|----------|---------------|-------------|
| AAStarAirAccountFactoryV7 | 3,713,591 | 17,278 |
| AAStarAirAccountV7 (via factory) | 2,424,858 - 2,900,086 | 14,747 |
| AAStarAirAccountV7 (with guard) | 2,947,710 - 2,947,722 | 14,747 + guard |
| AAStarGlobalGuard | ~400,000 (bundled) | ~2,000 |
| AAStarBLSAggregator | 855,052 | 3,883 |

**Why does AAStarGlobalGuard (~2,000 bytes) cost ~400k gas?**

The confusion is that "small contract ≠ cheap deployment". EVM deployment cost formula:
```
Gas = CREATE opcode (32,000) + bytecodeStorage (200 gas/byte × size) + constructorExecution
```
2,000 bytes × 200 = **400,000 gas just for bytecode storage** — this is an EVM protocol constant.
`immutable` variables (`account`, `minDailyLimit`) are baked into bytecode, not stored separately,
but they do increase bytecode size. SSTORE calls in the constructor (dailyLimit, approvedAlgorithms)
add another ~50,000 gas. Total: ~480,000. The ~400k figure is a rough estimate.
The per-byte cost is unavoidable; only reducing bytecode size would help.

**Why does AAStarBLSAggregator (3,883 bytes) cost 855k gas?**
3,883 bytes × 200 = **776,600 gas** for bytecode storage alone.
The bytecode is large because: (1) `GENERATOR_POINT` is a 128-byte constant baked into bytecode;
(2) `P_HIGH`/`P_LOW` BLS field modulus constants; (3) multiple assembly-heavy functions
(`_g2Add`, `_verifyPairing`, `_negateG1Point`) generate dense bytecode.
This is a one-time cost shared by all users — economically fine.

**Account creation comparison:**

| Method | Gas | Notes |
|--------|-----|-------|
| `createAccount()` (no guard) | 2,424,858 | Minimal config, no guardians |
| `createAccount()` (with guard) | 2,900,086 | Full config with guardians |
| `createAccountWithDefaults()` | 2,947,710 | Convenience with community guardian |

---

## Signature Validation Gas (from Foundry tests)

| Operation | Gas | Notes |
|-----------|-----|-------|
| ECDSA validation (raw 65-byte) | ~45,000 | `_validateECDSA`: ecrecover + comparison |
| ECDSA with algId prefix (66-byte) | ~45,200 | +200 gas for prefix strip |
| P256 passkey validation | ~40,000 (mock) | EIP-7212 precompile, actual varies by chain |
| BLS triple signature | ~207,000 | 2× ECDSA + BLS aggregate (mock) |
| Cumulative T2 (P256+BLS) | ~103,000 | P256 precompile + BLS via validator |
| Cumulative T3 (P256+BLS+Guardian) | ~123,000 | T2 + guardian ECDSA recovery |

---

## Execution Gas

| Operation | Min | Avg | Max | Notes |
|-----------|-----|-----|-----|-------|
| `execute()` (single call) | 24,983 | 52,918 | 66,779 | Includes `_enforceGuard` |
| `executeBatch()` (multiple calls) | 26,409 | 64,767 | 141,319 | Per-call guard check |

---

## Social Recovery Gas

| Operation | Gas | Notes |
|-----------|-----|-------|
| `proposeRecovery()` | ~324,000 | Write proposal + auto-approve |
| `approveRecovery()` | ~37,000 - 40,000 | Bitmap update |
| `cancelRecovery()` (single vote) | ~41,000 | Bitmap update |
| `cancelRecovery()` (threshold met → delete) | ~54,000 | Delete proposal |
| `executeRecovery()` | ~36,000 - 38,000 | Owner change + delete proposal |
| Full recovery flow (propose + approve + execute) | ~555,000 | 3 transactions total |

---

## Guard Gas Overhead

| Operation | Gas | Notes |
|-----------|-----|-------|
| `checkTransaction()` (within limit) | ~39,500 | SLOAD + SSTORE for dailySpent |
| `checkTransaction()` (zero value) | ~18,700 | Skip spending logic |
| `decreaseDailyLimit()` | ~19,800 | SSTORE |
| `approveAlgorithm()` | ~38,300 | SSTORE |
| `remainingDailyAllowance()` | ~10,400 | View function |

---

## Reentrancy Guard Comparison

| Method | Gas Cost | Notes |
|--------|----------|-------|
| EIP-1153 transient storage (current) | ~200 | `tload` + `tstore` |
| SSTORE-based (OpenZeppelin) | ~7,100 | Cold SLOAD + SSTORE |
| **Savings** | **~6,900 (97%)** | Per execute/executeBatch call |

---

## E2E UserOp Gas (Sepolia Actual)

| Version | Gas Used | Improvement | TX Hash |
|---------|----------|-------------|---------|
| YetAnotherAA (legacy) | 523,306 | baseline | — |
| AirAccount M1 (ECDSA) | ~200,000 | -61.8% | `0x8bb1b1...` |
| AirAccount M2 (BLS) | 259,694 | -50.4% | `0xf60f05...` |
| **AirAccount M3 (ECDSA)** | **127,249** | **-75.7%** | `0x912231...` |
| **AirAccount M4 Tier 1** (ECDSA) | **140,352** | -73.2% | `0x13d9ef...` |
| **AirAccount M4 Tier 2** (P256+BLS) | **278,634** | -46.8% | `0x28788d...` |
| **AirAccount M4 Tier 3** (P256+BLS+Guard) | **288,351** | -44.9% | `0xb59d86...` |

### Gas Breakdown (M3 ECDSA UserOp, estimated)

| Component | Gas | % |
|-----------|-----|---|
| EntryPoint overhead | ~21,000 | 16.5% |
| Signature validation (ECDSA) | ~45,000 | 35.4% |
| Execute + _enforceGuard | ~25,000 | 19.6% |
| ETH transfer (_call) | ~21,000 | 16.5% |
| Prefund + refund | ~15,000 | 11.8% |
| **Total** | **~127,000** | **100%** |

---

## Gas: Cumulative Tiers (M4 Actual vs Projection)

| Tier | Signature | Projected Gas | **Actual Gas** | Delta |
|------|-----------|--------------|----------------|-------|
| Tier 1 (ECDSA) | Raw ECDSA (65 bytes) | ~127,000 | **140,352** | +10% |
| Tier 2 (Cumulative) | P256 + BLS (2 nodes) | ~230,000 | **278,634** | +21% |
| Tier 3 (Cumulative) | P256 + BLS + Guardian | ~250,000 | **288,351** | +15% |
| Legacy BLS Triple | ECDSA×2 + BLS | ~260,000 | 259,694 (M2) | -0.1% |

**Note**: Actual M4 Tier 1 gas (140,352) is ~13k higher than M3 (127,249) due to guard initialization and tier enforcement overhead from the fully configured account (3 guardians, tier limits, algorithm whitelist). BLS verification gas depends heavily on node count; 2-node aggregate is cheapest.

### M4 Account Creation Gas

| Method | Gas | Notes |
|--------|-----|-------|
| `createAccount()` (full config, 3 guardians) | 2,976,645 | M4 Factory, Sepolia |
| `createAccount()` (ECDSA only, 3 guardians) | 2,879,353 | Social recovery test accounts |

---

## Optimization Opportunities

### Already Implemented
1. **via-IR compilation** — enables cross-function optimization
2. **10k optimizer runs** — balance between deploy cost and runtime gas
3. **Transient storage reentrancy** — 97% cheaper than SSTORE
4. **Inline ECDSA/P256** — no external contract call overhead for common paths
5. **Immutable entryPoint** — PUSH instead of SLOAD

### Potential Future Optimizations

| Optimization | Estimated Savings | Complexity | Status |
|-------------|-------------------|------------|--------|
| BLS key caching (aggregateKeys) | ~20,000 per multi-node verify | Low | ✅ Ready — `cacheAggregatedKey()` already in `AAStarBLSAlgorithm`. Backend must call it before submitting batched UserOps. Zero contract changes. |
| Assembly-optimized ecrecover | ~500 per ECDSA | Low | ✅ Ready — Replace OZ `ECDSA.recover()` with direct `ecrecover` precompile assembly in `_validateECDSA`. Straightforward refactor. |
| Batch UserOp aggregation | ~40% per op in batch | Medium | 📋 TODO (M5.5) — `AAStarBLSAggregator` contract is done. Remaining work is SDK/backend integration. |
| Packed guardian storage | ~2,100 per read (1 slot vs 3) | Medium | 📋 TODO (M5) — Pack `guardianCount + guardian[0]` into one slot (21 bytes < 32). Requires storage layout refactor. |
| EIP-7702 delegation | ~21,000 (no account deployment) | High | 📋 TODO (v1.0) — Next major version. Eliminates account deployment entirely. |

### Contract Size

| Contract | Size | Limit (24,576) | % Used |
|----------|------|----------------|--------|
| AAStarAirAccountV7 | 14,747 | 24,576 | 60.0% |
| AAStarAirAccountFactoryV7 | 17,278 | 24,576 | 70.3% |
| AAStarGlobalGuard | ~2,000 | 24,576 | 8.1% |

Plenty of headroom for adding cumulative validation and weight-based features.

---

## Comparison with Industry

| Wallet | Simple Transfer Gas | Notes |
|--------|-------------------|-------|
| **AirAccount M3** | **127,249** | Non-upgradable, guard + tiers |
| SimpleAccount (Pimlico) | ~120,000 | No guard, no recovery |
| LightAccount (Alchemy) | ~115,000 | Lightweight, upgradable |
| Kernel (ZeroDev) | ~150,000 | Modular, ERC-7579 |
| Safe (4337 module) | ~180,000 | Proxy + module overhead |
| Biconomy v2 | ~160,000 | Modular, ECDSA default |

AirAccount M3 is competitive with the lightest wallets despite including guard enforcement, tiered verification, and social recovery. The ~7k overhead vs SimpleAccount is the cost of security features (guard check, tier check, reentrancy guard).

---

## Recommendations

### Immediately Actionable (no contract changes required)

1. **Enable BLS key caching** — call `AAStarBLSAlgorithm.cacheAggregatedKey(nodeIds)` once per node
   set before submitting batched UserOps. Saves ~20k gas per Tier 2/3 transaction. Backend task only.

2. **Assembly-optimized ecrecover** — replace `ECDSA.recover()` from OZ with direct `ecrecover`
   precompile call in `_validateECDSA`. Saves ~500 gas per ECDSA UserOp. See `docs/TODO.md`.

### Deferred to M5 / Future Versions

3. **Pack guardian addresses** — saves ~4k gas on recovery operations. See `docs/TODO.md`.
4. **Batch UserOp aggregation** — SDK/backend integration for `AAStarBLSAggregator`. See `docs/TODO.md`.
5. **EIP-7702 delegation** — next major version, eliminates account deployment cost entirely.
6. **Monitor P256 precompile gas** across L2s — gas costs vary significantly between chains.
   Reference: `docs/M5-plan.md` section M5.4 for chain compatibility table.
