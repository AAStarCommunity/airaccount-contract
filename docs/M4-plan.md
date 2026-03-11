# M4 Milestone Plan — Cumulative Signature + E2E Onboarding Flow

## Overview

M4 focuses on two main areas:
1. **Signature model upgrade**: From single-algorithm routing to cumulative multi-signature verification
2. **End-to-end onboarding flow**: From passkey creation to first transaction, script + page versions

## M3 Deployment (Prerequisite — DONE)

- **Factory**: `0xce4231da69015273819b6aab78d840d62cf206c1`
- **Test Account**: `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B`
- **E2E TX**: `0x912231d667b6c27a675ce0ebc08828a5d4aa13402423a6cd475b828d7df7a56a`
- **Gas**: 127,249 (vs M2 259,694 = **-51%**)

---

## M4.1 — Cumulative Signature Model (validateSignature Redesign) ✅ DONE

### Business Goal

Current tier model: each tier uses ONE signature type (ECDSA / P256 / BLS).
New model: higher tiers ACCUMULATE signatures — more value = more signatures required.

| Tier | Threshold | Required Signatures | User Experience |
|------|-----------|-------------------|-----------------|
| Small | ≤ user-configured | Passkey (P256 + auto EOA) | One-tap on phone |
| Medium | ≤ user-configured | Passkey + DVT/BLS aggregate | One-tap + background DVT verification |
| Large | > medium limit | Passkey + BLS + Guardian co-sign | One-tap + DVT + guardian confirms on their device |

### Technical Changes

**New constants:**
- `ALG_CUMULATIVE_T2 = 0x04` — P256 + BLS
- `ALG_CUMULATIVE_T3 = 0x05` — P256 + BLS + Guardian ECDSA

**New signature format:**
```
Tier 1: [0x03][P256 r(32)][P256 s(32)]  (65 bytes, same as current)
Tier 2: [0x04][P256 sig(64)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][msgPoint(256)][msgPointSig(65)]
Tier 3: [0x05][P256 sig(64)][BLS payload...][guardianECDSA(65)]
```

### Tasks

- [x] F29: Design new signature format spec (algId 0x04, 0x05)
- [x] F30: Implement `_validateCumulativeTier2()` — P256 + BLS
- [x] F31: Implement `_validateCumulativeTier3()` — P256 + BLS + Guardian
- [x] F32: Update `_algTier()` mapping for new algIds
- [x] F33: Unit tests for cumulative validation (all tiers) — 8 tests
- [x] F34: Integration test — tier enforcement with cumulative sigs

---

## M4.2 — Config Templates (Frontend-Loadable) ✅ DONE

### Tasks

- [x] F35: JSON config templates: `configs/default-personal.json`, `configs/high-security.json`, `configs/developer-test.json`
- [x] F36: Solidity view function `getConfigDescription()` with `AccountConfig` struct (12 fields)

---

## M4.3 — Onboarding Flow (Script Version) ✅ DONE

### Tasks

- [x] F37: `scripts/onboard-1-create-keys.ts` — P-256 passkey + KMS wallet + EOA derivation
- [x] F38: `scripts/onboard-2-create-account.ts` — Factory deploy + verify
- [x] F39: `scripts/onboard-3-test-transfer.ts` — ETH transfer via UserOp + KMS signing
- [x] F40: `scripts/onboard-4-gasless-transfer.ts` — Gasless via SuperPaymaster

---

## M4.4 — Onboarding Flow (Page Version) ✅ DONE

### Tasks

- [x] F41: Minimal frontend — Config page (load JSON, display fields, user adjusts)
- [x] F42: Passkey registration flow (WebAuthn `navigator.credentials.create()`)
- [x] F43: Account creation + test transaction page
- [x] F44: Transaction page — tier-aware display

---

## M4.5 — Weight-Based Multi-Signature (Research) ✅ DONE

### Tasks

- [x] F45: Research note — `docs/M4.5-weighted-signature-research.md`
  - Bitmap-based source selection (algId 0x06)
  - Configurable weights per source
  - Threshold per tier
  - Gas analysis and migration path
- [ ] F46: Prototype `_validateWeightedSignature()` — deferred to M5

---

## Test Results

### Foundry Unit Tests (200 passing)
- `test/CumulativeSignature.t.sol` — 8 tests
- `test/SocialRecovery.t.sol` — 37 tests
- `test/AAStarGlobalGuard.t.sol` — 26 tests
- `test/AAStarAirAccountV7_M2.t.sol` — 11 tests
- Plus all other existing test suites

### Sepolia E2E Tests (15 passing)

**Tiered Signature E2E** (5/5 passed, account `0x117C...`):
| Test | Description | Gas | Result |
|------|-------------|-----|--------|
| 1 | Tier 1 ECDSA (0.005 ETH) | 140,352 | PASS |
| 2 | Tier 2 P256+BLS (0.05 ETH) | 278,634 | PASS |
| 3 | Tier 3 P256+BLS+Guardian (0.15 ETH) | 288,351 | PASS |
| 4 | ECDSA → tier 2 amount (negative) | — | REVERTED (correct) |
| 5 | P256+BLS → tier 3 amount (negative) | — | REVERTED (correct) |

**Social Recovery E2E** (5/5 passed, accounts salt 200-203):
| Test | Description | Result |
|------|-------------|--------|
| 1 | Full recovery happy path (propose → approve → timelock) | PASS |
| 2 | Cancel recovery (2-of-3 guardian cancel) | PASS |
| 3 | Owner cannot cancel recovery | PASS |
| 4 | Stolen key cannot block recovery | PASS |
| 5 | Guardian P256 passkey independence | PASS |

**Gasless E2E** (1/1 passed):
| Test | Description | Gas (bundler) | Result |
|------|-------------|---------------|--------|
| 1 | Self-transfer via SuperPaymaster | 181,067 | PASS (0 ETH cost) |

### M4 Deployment (Sepolia)
- **Factory**: `0x914db0a849f55e68a726c72fd02b7114b1176d88`
- **Deploy TX**: `0x56305b7a734d19a6037f819999627565b9df093241f4aa1e9d39cc5946efbf7b`
- **Factory Gas**: 3,698,359

---

## Priority Order

1. ~~**M4.1** (F29-F34) — Cumulative signature model~~ ✅
2. ~~**M4.3** (F37-F40) — Script-based onboarding flow~~ ✅
3. ~~**M4.2** (F35-F36) — Config templates~~ ✅
4. ~~**M4.4** (F41-F44) — Page version~~ ✅
5. ~~**M4.5** (F45-F46) — Weight-based model research~~ ✅ (prototype deferred to M5)
