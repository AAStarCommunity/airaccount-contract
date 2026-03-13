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

## M6.4 — Session Key (Time-Limited Contract Authorization)

**Decision (2026-03-13)**: Move from M5 backlog to M6.

### Motivation
Gaming and DeFi users need short-lived authorizations without signing every transaction.
WebAuthn/passkey prompts every 30 seconds break UX for interactive applications.

### Design (no base contract change)
- Implement as independent `IAAStarValidator` module (`SessionKeyValidator.sol`)
- Owner activates via normal signature: grants `{tempPubKey, expiry, contractScope, spendCap}`
- During validity: DVT nodes confirm UserOp fits session constraints → session key signs
- Expiry in hours (max 24h). Past expiry: validation fails automatically, no on-chain revoke needed
- No storage in `AAStarAirAccountBase` — all state in the validator module

### Scope
- [ ] `SessionKeyValidator.sol` — IAAStarValidator implementation
- [ ] Session activation flow (owner signs session grant)
- [ ] DVT constraint verification (contract scope + spend cap enforcement)
- [ ] Expiry handling (block.timestamp check)
- [ ] Unit tests + gaming scenario E2E test

---

## M6.5 — Will Execution (Inactivity-Triggered Transfer)

**Decision (2026-03-13)**: M6 feature, requires DVT off-chain work.

### Design
- `WillExecutor.sol` — standalone contract (not inside account)
- Owner pre-signs authorization: `{heirAddress, inactivityThreshold (seconds), chainScope}`
- DVT nodes scan daily across configured chains for last tx timestamp
- No activity detected: counter accumulates; threshold crossed → DVT submits aggregate proof
- On-chain: verify DVT aggregate signature + inactivity proof → execute transfer
- DVT nodes are observers+triggers only, no private key custody
- Hardest part: cross-chain inactivity aggregation (requires DVT multi-chain scanning)

### Scope
- [ ] `WillExecutor.sol` contract
- [ ] DVT off-chain scanner spec (heartbeat protocol)
- [ ] Cross-chain inactivity aggregation design
- [ ] Unit tests + long-form scenario test

---

## M6.6 — Privacy Integration (OAPD + Pluggable Calldata Parser)

**Decision (2026-03-13)**: Strategy A (OAPD) for near-term, pluggable parser for M6.

### Near-term (OAPD — no contract change)
Users who want Railgun/privacy-pool transactions create a **dedicated AirAccount** for privacy
operations. Main account and privacy account are separate. No guard integration needed.
- Deployment script supports `--privacy-account` flag to create OAPD pair
- Frontend shows two accounts: "Main" and "Private" (badge)

### M6 (Pluggable Calldata Parser)
- `_enforceGuard` supports registering external parser contracts per dest address
- Each parser implements `ICalldataParser.parse(calldata) → (token, amount)`
- Railgun parser, Privacy Pools parser deployed as separate contracts
- User registers parsers for specific dest addresses (one-time owner tx)
- Same plugin mechanism reused by Session Key (M6.4) and PolicyRegistry (long-term)

### Scope
- [ ] `ICalldataParser` interface
- [ ] Parser registry in AAStarAirAccountBase
- [ ] Railgun shield/unshield parser
- [ ] Privacy Pools deposit parser
- [ ] OAPD deployment script

---

## M6.7 — Post-Quantum Signature Support (FUTURE — awaiting EVM precompile)

**Decision (2026-03-13)**: Architecture ready, integration blocked by gas cost.

### Research Findings (kohaku pq-account / ZKNOX)
- Algorithms available: MLDSA (ML-DSA/Dilithium), MLDSAETH, FALCON, ETHFALCON
- All deployed on Sepolia + Arbitrum Sepolia, full Foundry test suite
- **Gas cost: 500k–5M gas** (100–1500× ECDSA precompile cost)
- Root cause: no EVM precompile for PQ algorithms — pure Solidity verification
- MLDSA public key: 1.3KB → requires separate `PKContract` deployment per user

### Why not now
A MLDSA UserOp would cost ~$50–$500 at normal gas prices. Completely unusable.
No EVM precompile proposal with concrete EIP + activation timeline exists as of 2026-03.

### Architecture compatibility
Our `IAAStarValidator` router supports plugging in PQ validation as `algId = 0x08`:
- Deploy `PQValidator.sol` wrapping ZKNOX verifier contracts
- Register in `AAStarValidator` with 7-day governance timelock
- Zero changes to `AAStarAirAccountBase` or factory

### Trigger condition
Revisit when: (a) EVM PQ precompile EIP reaches "Final" status, OR
              (b) PQ verification gas drops below 50k (optimized assembly/zkproof).

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
