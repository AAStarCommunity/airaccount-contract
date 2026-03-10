# M4 Milestone Plan — Cumulative Signature + E2E Onboarding Flow

## Overview

M4 focuses on two main areas:
1. **Signature model upgrade**: From single-algorithm routing to cumulative multi-signature verification
2. **End-to-end onboarding flow**: From passkey creation to first transaction, script + page versions

---

## M4.1 — Cumulative Signature Model (validateSignature Redesign)

### Business Goal

Current tier model: each tier uses ONE signature type (ECDSA / P256 / BLS).
New model: higher tiers ACCUMULATE signatures — more value = more signatures required.

| Tier | Threshold | Required Signatures | User Experience |
|------|-----------|-------------------|-----------------|
| Small | ≤ user-configured | Passkey (P256 + auto EOA) | One-tap on phone |
| Medium | ≤ user-configured | Passkey + DVT/BLS aggregate | One-tap + background DVT verification |
| Large | > medium limit | Passkey + BLS + Guardian co-sign | One-tap + DVT + guardian confirms on their device |

### Why Cumulative

- **Passkey as base**: Every operation goes through passkey — this is the user's sole interaction (fingerprint/face). The EOA key is stored in TEE/KMS and auto-signs alongside passkey.
- **DVT/BLS prevents passkey forgery**: Even if passkey is phished, attacker can't control multiple independent DVT nodes doing BLS aggregate verification.
- **Guardian prevents large theft**: Highest-value operations need real human confirmation — family member or community Safe multisig.

### Technical Changes

**New signature format:**
```
Tier 1: [0x03][P256 r(32)][P256 s(32)]  (65 bytes, same as current)
Tier 2: [0x04][P256 sig(64)][BLS aggregate payload]
Tier 3: [0x05][P256 sig(64)][BLS aggregate payload][guardian ECDSA sig(65)]
```

**_validateSignature changes:**
- algId 0x04 → verify P256 first, then verify BLS aggregate → both must pass
- algId 0x05 → verify P256, then BLS, then guardian ECDSA → all three must pass
- `_lastValidatedAlgId` stores the composite tier (0x04 = tier 2, 0x05 = tier 3)

**_algTier mapping update:**
```solidity
function _algTier(uint8 algId) internal pure returns (uint8) {
    if (algId == 0x05) return 3;  // P256 + BLS + Guardian
    if (algId == 0x04) return 2;  // P256 + BLS
    if (algId == ALG_P256) return 1;  // P256 only (small)
    if (algId == ALG_ECDSA) return 1; // Backwards compat
    if (algId == ALG_BLS) return 3;   // Legacy BLS triple
    return 1;
}
```

### Tasks

- [ ] F29: Design new signature format spec (algId 0x04, 0x05)
- [ ] F30: Implement `_validateCumulativeTier2()` — P256 + BLS
- [ ] F31: Implement `_validateCumulativeTier3()` — P256 + BLS + Guardian
- [ ] F32: Update `_algTier()` mapping for new algIds
- [ ] F33: Unit tests for cumulative validation (all tiers)
- [ ] F34: Integration test — tier enforcement with cumulative sigs

---

## M4.2 — Config Templates (Frontend-Loadable)

### Business Goal

User must explicitly see and confirm all account configuration. No hidden defaults.
Frontend loads a JSON config template, displays it, user adjusts and confirms.

### Tasks

- [ ] F35: Create JSON config templates (e.g., `configs/default-personal.json`, `configs/high-security.json`)
  - Daily limit, tier thresholds, guardian addresses, approved algorithms
  - Human-readable labels and descriptions for each field
- [ ] F36: Solidity view function `getConfigDescription()` returning struct with all current config values
  - Allows frontend to query on-chain config for display

---

## M4.3 — Onboarding Flow (Script Version)

### Business Goal

Full account creation pipeline:
1. User creates Passkey (P256 key pair via WebAuthn)
2. Passkey triggers KMS to generate EOA private key (stored in TEE secure storage)
3. EOA address derived → used as account owner
4. User reviews and confirms config (daily limit, guardians, tier thresholds)
5. Factory creates account with config
6. Test transaction executed to verify everything works

### Tasks

- [ ] F37: TypeScript script — Passkey simulation + EOA key generation via KMS mock
  - Use `viem` for all chain interactions
  - Simulate WebAuthn credential creation
  - Mock KMS/TEE key derivation (real integration deferred)
- [ ] F38: TypeScript script — Account creation via Factory
  - Load config template JSON
  - Call `createAccountWithDefaults()` or `createAccount()`
  - Verify account deployed, print config summary
- [ ] F39: TypeScript script — Test transaction (ETH transfer)
  - Build UserOperation with Passkey signature
  - Submit via bundler → EntryPoint → account.execute()
  - Verify on-chain state
- [ ] F40: TypeScript script — Gasless transaction via SuperPaymaster
  - Same as F39 but with paymasterAndData
  - Verify zero ETH cost for user

---

## M4.4 — Onboarding Flow (Page Version)

### Business Goal

Simple web page that wraps the script flow with a UI.

### Tasks

- [ ] F41: Minimal frontend — Config page
  - Load default config JSON
  - Display all fields with labels
  - User can modify values
  - Confirm button triggers account creation
- [ ] F42: Passkey registration flow
  - WebAuthn `navigator.credentials.create()` integration
  - Display public key, derive expected account address
- [ ] F43: Account creation + test transaction page
  - Show creation progress
  - Execute test transaction
  - Display results and account summary
- [ ] F44: Transaction page — send ETH / interact with contract
  - Tier-aware: show which signature level will be required
  - For medium/large amounts, show additional verification steps

---

## M4.5 — Weight-Based Multi-Signature (Research / Future)

### Business Goal

Beyond fixed 2-of-3, support weighted signatures:
- Owner passkey = weight 3
- DVT BLS = weight 2
- Guardian = weight 1 each
- Threshold configurable (e.g., need weight ≥ 4 for medium, ≥ 6 for large)

### Tasks

- [ ] F45: Research note — weighted signature model design
- [ ] F46: Prototype `_validateWeightedSignature()` (if time permits)

---

## Priority Order

1. **M4.1** (F29-F34) — Cumulative signature model (core contract change)
2. **M4.3** (F37-F40) — Script-based onboarding flow (proves the model works)
3. **M4.2** (F35-F36) — Config templates (supports onboarding)
4. **M4.4** (F41-F44) — Page version (after scripts work)
5. **M4.5** (F45-F46) — Weight-based model (research for future)

---

## Dependencies

- M4.1 must complete before M4.3 (scripts need the new signature format)
- M4.2 can run in parallel with M4.1
- M4.4 depends on M4.3 (page wraps working scripts)
- M4.5 is independent research, can start anytime
