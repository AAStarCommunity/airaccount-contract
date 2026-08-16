# bench-tier-gas outputs — how to cite (READ BEFORE using the CSV)

Companion to `scripts/bench-tier-gas.ts`. File: `bench-tier-gas-<salt>.csv` (CC-95 / Onion §5.1).

## ⚠️ Which column to cite

**Cite `receipt_gasUsed`. Do NOT cite `event_actualGasUsed` for cross-tier ratios.**

`event_actualGasUsed` (from `UserOperationEvent`) = internal execution gas **+ the script's
hard-coded `preVerificationGas = 80_000`** (a **synthetic constant, not an estimate**), and it does
**not** include the real ~21,000 intrinsic + calldata. That fixed 80k substitutes for the real ~27k,
injecting a near-constant **≈ +53,000 gas** bias — which is **+52% on tier-1** but only +7.6% / +7.3%
on tier-2/3, so it *distorts the very ratio §5.1 exists to report*:

| ratio | from `receipt_gasUsed` (cite this) | from `event_actualGasUsed` (biased) |
|---|---|---|
| tier2 / tier1 | 6.17× | 4.37× |
| tier3 / tier1 | 6.25× | 4.41× |

Citing the event column would understate the tier-2 premium by ~29%. Use `receipt_gasUsed`.
(`event_actualGasCost` is wei and varies with gas price — not a gas figure; do not cite as cost.)

## Headline numbers (receipt_gasUsed, n=10, median)

| tier | factors | median gasUsed | note |
|---|---|---|---|
| 1 | P256 (0x03) | 101,948 | run#1=119,036 is a cold-storage first-write outlier (+17,100, nonce slot 0→nonzero SSTORE); use **median**, not mean (mean 103,654 is +1.68% skewed) |
| 2 | P256 + BLS3 (0x04) | 629,363 | deterministic (event var = 0) |
| 3 | + guardian (0x05) | 637,037 | deterministic |

- **delta tier1→2 = 527,415** (receipt). NOTE: this is NOT "pure BLS pairing" — it is the full BLS
  verification path + `0x03→0x04` validator dispatch + tier-2 threshold branch + ~5,196 gas extra
  calldata (BLS payload). Measured 5.0× vs the pre-registered ~106k prediction (see CC-95).
- **delta tier2→3 = 7,674** (receipt). ~2.6× the pre-registered "~3,000 guardian ecrecover + branch".

## Provenance (the CSV rows alone are not self-describing)

- Chain: **Sepolia (11155111)**; blocks **11,498,622–11,498,660**; 30 unique tx / 30 unique blocks.
- EntryPoint v0.7 `0x0000000071727De22E5E9d8BAf0edAc6f37da032`; Factory `0x65C30aCA6305c16b69E0262C5c1b57A77E57EE4A`;
  ValidatorRouter `0x0D4D69BE6dEC7F74A804ceFa7733674ba11A8c23`; BLS validator (algId 0x01) `0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC` (YAAA AAStarValidator).
- Benchmark account: `0xDEB4D32e0B1Ed32eFB12a7be1c92967de461E3B9` (freshly created; salt/account differ per run — deltas reproduce, absolute values are per-account).
- BLS: live 3-node DVT aggregate (dvt1/2/3.aastar.io, aNode v1.13.1), G2 point-add aggregation, verified on-chain vs registered pubkeys.
- Submission: **direct `EntryPoint.handleOps`, one op/tx** (NOT a bundler). `preVerificationGas` = **80,000 (synthetic)**; `accountGasLimits` = verificationGasLimit 900k ‖ callGasLimit 200k (constant across tiers).
- **SCOPE**: `dailyLimit = 0` ⇒ no `AAStarGlobalGuard` deployed ⇒ this measures **tiered signature-verification cost only**; the §4.3 cumulative-tier / anti-splitting path (`requiredTier(alreadySpent+value)` + `recordSpend`) is **NOT exercised** by this batch (guard()==0 on-chain). A guard-on run would add a separate ~few-k overhead.

## Cost breakdown of the tier-2/3 BLS verify (repo:dvt-reported — UNVERIFIED)

See `docs/2026-08-16-tier-bls-gas-optimization-analysis.md` — repo:dvt forge per-precompile trace.
**The commit SHA for this trace is unverified**: it resolves in no public YAAA repo as of 2026-08-16, so
**do NOT cite these figures in the paper** until dvt publishes a public commit + forge artifact.
As reported: validate() 458,380 (2-node bootstrap) = hash-to-curve 51,088 (11%) + pairing 102,900 (22%)
+ G1ADD 375 + impl overhead 304,017 (66%) [sums to 458,380]. Cost is dominated by **implementation
overhead, NOT hash-to-curve** (an earlier draft wrongly said the latter). Production DVT is **3-node**
(this benchmark's own on-chain aggregate is dvt1/2/3): the like-for-like breakdown is **≈ 469k**; the
458,380 above is the reported **2-node** bootstrap, so treat it as a lower bound.
