# M6 Milestone Plan — Weight-Based Signatures & Advanced Security Modes

> **Status**: STUB — Planning deferred until M5 is complete.
> Created: 2026-03-13. Revisit after M5 deployment.

## Overview

M6 focuses on advanced configurability for power users who need custom security profiles
beyond the fixed Tier 1/2/3 model shipped in M4.

---

## M6.1 — Weight-Based Multi-Signature (algId 0x07)

Moved from M4.5 research phase. Full research and prototype design documented in
`docs/M4.5-weighted-signature-research.md`.

### Summary

Each signature source has a configurable weight. Transactions must accumulate enough
total weight to meet the tier threshold. Enables custom security profiles (DAO, family,
high-security) without changing the base tier model.

**New algId**: `0x07` — bitmap-based, variable signature set
**Signature format**: `[0x07][sourceBitmap(1)][P256?][ECDSA?][BLS?][guardian sigs?]`
**Storage**: `WeightConfig` struct (7 × uint8 = 1 storage slot)
**Gas overhead**: ~500 gas for bitmap parsing + weight accumulation

### Scope

- [ ] Add `WeightConfig` struct and storage to `AAStarAirAccountBase`
- [ ] Implement `_validateWeightedSignature()` (algId 0x07)
- [ ] Add weight governance: only owner can update weights, guardians can veto decreases
- [ ] Frontend config UI for weight customization
- [ ] Unit + E2E tests for all weight combinations
- [ ] Gas benchmark vs fixed tiers

**Reference**: `docs/M4.5-weighted-signature-research.md` — full design, prototype code, open questions.

---

## M6.2 — Guardian Consent for Weight Changes

If a weight change would reduce total max weight below the Tier 3 threshold (i.e., weakens
the highest security tier), require guardian approval before it takes effect.
Prevents owner from silently weakening their own security.

---

## M6.3 — Frontend Weight Configuration UI

Web interface for users to:
- View current weight configuration
- Simulate "would this signature set pass?" before submitting
- Adjust weights with guardian approval flow

---

## Deferred From M5

| Item | Reason | Reference |
|------|--------|-----------|
| Weight-based signatures (algId 0x07) | M4/M5 fixed tier model covers 95% of use cases; needs battle-testing first | M4.5 research doc |
| Guardian consent for security weakening | Depends on M6.1 weight model | M5.3 extension |
| Frontend weight UI | Needs M6.1 contract first | — |

---

## Prerequisites

- M5 fully deployed and battle-tested on mainnet
- `ALG_COMBINED_T1 = 0x06` (M5.8) proven in production — validates dual-factor on-chain
- Chain compatibility (M5.4) confirmed for all target L2s

---

*Last updated: 2026-03-13*
*Source: `docs/M4.5-weighted-signature-research.md`, `docs/M5-plan.md` M5.5 note*
