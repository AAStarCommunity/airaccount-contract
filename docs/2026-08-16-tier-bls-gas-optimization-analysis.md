# Tier-2/3 BLS Verification Gas — Cost Breakdown & Optimization Analysis

**Date**: 2026-08-16
**Context**: CC-95 (Onion paper §5.1 tiered-gas benchmark). Measured on Sepolia, v0.29.0 account
`0xDEB4D32e0B1Ed32eFB12a7be1c92967de461E3B9`, n=10/tier, direct `EntryPoint.handleOps`.
**Companion**: `scripts/bench-tier-gas.ts` + `scripts/out/bench-tier-gas-1786851945.csv` (PR #199).

> ⚠️ Honesty note (a lesson from this session): the "hash-to-curve dominates" claim in an earlier
> CC-95 delivery was an **unmeasured inference and was wrong**. Everything below is either
> **measured** (via read-only `eth_estimateGas`) or **explicitly flagged as hypothesis**. Savings
> figures for the optimizations are **directional hypotheses, not proven** — they require the forge
> per-precompile trace (repo:dvt) and/or a measured comparison before anyone commits to a rewrite.

## 1. Dependency: what airaccount-contract relies on YAAA for

- **Path**: `validateUserOp` → `_validateCumulativeTier2/3` → `_blsPayloadValid` →
  `_callBLSValidator` (`src/core/AAStarAirAccountBase.sol:944`) → `validator(router).getAlgorithm(0x01)`
  → external `IAAStarAlgorithm(0x539B).validate(userOpHash, [nodeIds][aggSig])` (try/catch, view).
- **Dependency object**: YAAA `AAStarValidator` @ `0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC`
  (their `contracts/src/AAStarValidator.sol`, `validate()` / on-chain RFC-9380 hash-to-curve).
  > Line numbers (`validate()`@L221, `_hashToG2`@L257) come from a repo:dvt-reported trace whose
  > commit SHA I could **not verify** — the SHA I was given resolves in none of the public YAAA repos
  > (see §2 note). Treat them as **unverified / pending dvt publication**. This repo's YAAA submodule is
  > **stale** (does not match the deployed `validate(bytes32,bytes)`), so for the paper cite a
  > **verified, published dvt commit/artifact** once available — not our submodule, and not this trace.
- **Step**: tier-2 / tier-3 BLS signature verification. Note on algIds: the *account-side* tiered
  signature tags are `0x04` (cumulative T2) / `0x05` (cumulative T3); those paths **resolve the BLS
  algorithm slot `ALG_BLS = 0x01`** on the router (`getAlgorithm(0x01)` → 0x539B). CC-10 Decision A: the account
  **delegates** BLS verification to the external DVT validator. **airaccount does not own 0x539B**,
  so the dominant cost lives in a contract we cannot directly change.
- **Our own alternative**: `src/validators/AAStarBLSKeyRegistry.sol` (assembly-optimized, same
  `IAAStarAlgorithm` interface, no stake logic, aggregate-key cache removed for security HIGH-1).
  **Not currently mounted** — v0.29.0 mounts YAAA's 0x539B by design.

## 2. Measured cost breakdown (read-only estimateGas, reproducible)

Per tier-2 op, receipt.gasUsed ≈ 629k; tier1→2 delta ≈ **527k** ≈ the external `validate()` cost.

| Component | gas | share | how measured |
|---|---|---|---|
| `validate()` total | ~514k | 100% | `estimateGas(0x539B.validate(h,[nodeIds][agg]))` = 540,551 − intrinsic/calldata |
| ├ hash-to-curve (`hashToG2`) | ~66k | ~13% | `estimateGas(0x539B.hashToG2(h))` = 87,854 − intrinsic (incl. its internal MODEXP) |
| ├ pairing (k=2, consumed) | ~103k | ~20% | EIP-2537 schedule 32600·2+37700 |
| └ implementation overhead | ~345k | ~67% | remainder; **not** any single crypto primitive |

repo:dvt (contract owner) confirmed the ~345k is "point decode + subgroup checks + registered-pubkey
SLOADs + G1 aggregation + calldata parse".

> **Refinement (repo:dvt forge per-precompile trace, 2026-08-16) — UNVERIFIED, pending dvt publication.**
> The commit SHA I was given for this trace resolves in **none** of the public YAAA repos
> (`AAStarCommunity/{YetAnotherAA-Validator,YetAnotherAA,dvt}`, checked 2026-08-16; local `fetch --all`
> also absent; positive control passes). So the numbers below are **repo:dvt-reported, not independently
> reproduced** — do NOT cite them in the paper until dvt publishes a public commit + forge artifact.
> As reported: `validate()` = **458,380 gas** (forge test, **2-node bootstrap** — production DVT is 3-node,
> see correction below): hash-to-curve **51,088 (~11%)** · pairing k=2 **102,900 (~22%)** · G1ADD **375**
> → crypto floor **154,363 (~34%)**; **implementation overhead 304,017 (~66%)**, pure EVM (isRegistered
> SLOADs, decode, subgroup, RFC-9380 glue, memory).
> - **Stake is NOT in this 304,017 — and the ~56k forge-vs-chain gap is not all stake either.** The 55,620
>   gap (on-chain ~514k − forge 458,380) decomposes as: **h2c drift ~14,912** (66k on-chain vs 51,088
>   reported — the unreconciled item below, NOT stake) + the **2→3-node delta ~10,500** (on-chain is a live
>   3-node committee, this forge run is 2-node) + only **~30,208 attributable to `requireStake` per-node
>   stake SLOADs** (which still sit **outside** the 304,017 — they appear only on-chain). An earlier draft
>   called the whole ~56k "stake"; that over-attributes it ~1.85×.
> - **2→3 node correction.** Going from 2 to 3 registered nodes adds far more than the +375 G1ADD — each
>   extra node also costs its registered-pubkey SLOADs (128 B = 4 slots ≈ 8,400 cold) + `isRegistered`
>   (2,100) + decode/subgroup ≈ **~10,500/node** (consistent with §3②'s own ~32k ≈ 3×10,500 cache estimate).
>   So **production 3-node ≈ 469k**; 458,380 is a 2-node lower bound.
> - **h2c unreconciled.** The trace's aggregate 34/66 split is consistent with the estimateGas aggregate
>   split, but the two disagree ~30% on hash-to-curve alone (on-chain ~66k vs reported 51,088) — the
>   per-component h2c figure is itself not reconciled.

**Correct framing (agreed with repo:dvt, for DSR §5.1)**: estimating BLS cost from the EIP-2537
schedule (pairing only, 102,900) **underestimates the real on-chain cost ~5×**, and the gap's main
body is **implementation overhead, not any single cryptographic primitive**. The on-chain hash-to-curve
message-point recomputation (L257) is a **deliberate anti-oracle security design** (binds the aggregate
to the exact userOpHash, prevents cross-op replay) — a security↔gas trade-off, not waste.

## 3. Optimization options, ranked by leverage

### ① Optimize the validator implementation — largest non-precompile bucket (~304k), realistic headroom LARGE (measured — see §3① below) — owner: repo:dvt
The ~304k impl overhead (repo:dvt forge trace, unverified) is the largest non-precompile bucket. **Update
(2026-08-16, walking back an earlier over-claim):** repo:dvt reports YAAA's `AAStarValidator` is **already
assembly-optimized (~10 assembly blocks, precompile calls already asm)** — just like our own
`AAStarBLSKeyRegistry` (7 asm blocks). So **"port the assembly hot-paths" is NOT a lever** — both are
already assembly. Note the ~304,017 (forge, no-stake) is **NOT** mostly stake SLOADs — stake is only a
~30k on-chain surcharge (see §2; the full ~56k forge-vs-chain gap also includes h2c drift + the 2→3-node
delta, so ~30k of it is stake). The 304k is **RFC-9380 Solidity glue** (expand_message loop,
Fp field-reduction memory moves), point decode, subgroup checks, and calldata parse — but as the measured
comparison just below shows, it is **NOT inherent/structural**: our own registry does the equivalent crypto
in ~52k, so the bulk of YAAA's 304k is **implementation-dependent, not a floor**.
**"Structural floor" conjecture — MEASURED and REFUTED (2026-08-16).** I earlier conjectured both
implementations land at ~300k+ impl overhead (a structural floor). Measured second data point refutes it:
`AAStarBLSKeyRegistry.validate()` = **219,963 gas** (forge --gas-report, real 3-node golden,
`test/BLSReplayBinding.t.sol`; hashToG2 63,880) vs YAAA's `AAStarValidator.validate()` = **458,380**
(repo:dvt-reported, unverified) — **ours is ~48%, roughly half.** ⚠️ **Node-count caveat:** ours is a
**live 3-node** measurement, YAAA's 458,380 is a **2-node bootstrap** (§2); on a like-for-like production
3-node basis (YAAA ≈ **469k**, §2) the ratio is **~46.9%** and the gap **~248,917**. The derived figures
below use the reported 458,380 (2-node) and are therefore a lower bound on the gap. The gap is **not** purely EVM-layer:
our impl overhead ≈ 219,963 − (h2c 63,880 + pairing 102,900 + G1ADD 375) ≈ **52,808** vs YAAA's 304,017
→ EVM-layer gap **≈ 251,209**; but our hash-to-curve is **12,792 more expensive** than YAAA's (63,880 vs
51,088), which offsets it, netting the **total ~238,417 gap** (458,380 − 219,963). So the crypto floor is
**not** equal both sides (our h2c is ~25% pricier); the dominant term is still the EVM-layer impl gap
(~251k), partially clawed back by our costlier h2c.
So impl overhead is **NOT a shared structural floor** — implementation-dependent variance is large.
**Confound (do not over-read the other way either):** our registry has **no stake logic** (Safe-curated);
YAAA is **stake-bound Plan A v3**. The ~238k gap therefore mixes (a) YAAA's decentralized-staking machinery
(legitimate feature to keep) with (b) shared-code implementation-efficiency difference — **our side cannot
separate them** (we have no stake tier at all). So: do NOT claim "YAAA has 238k of waste", and do NOT claim
"structural floor". The clean split needs repo:dvt's own sub-trace (stake-SLOAD vs generic-glue). Our
`AAStarBLSKeyRegistry` stays a *reference* / weaker Safe-curated trust model — NOT a drop-in replacement (§4a).

### ② Cache the aggregate pubkey (~32k/op) — owner: repo:dvt (validator)
For a fixed node set (dvt1/2/3) the aggregate G1 pubkey is constant; caching it avoids re-SLOADing 3×
128-byte pubkeys + re-aggregating per op. airaccount's registry **removed** this cache for security
(HIGH-1: stale cache survives key rotation). A safe restoration uses a per-node `keyVersion` to
invalidate. Savings ~32k/op is an estimate; confirm with the trace.

### ③ Cross-op batching / aggregation — limited upside here
- **Already used**: multi-signer aggregation over the 3 DVT nodes → 1 signature, 1 pairing (not 3).
- **Cross-op (ERC-4337 IAggregator)**: in the *generic* case N ops' pairings combine into one
  multi-pairing (`32600·2N + 37700`), saving the (N−1)·37,700 fixed head (~34k/op at N=10). But
  **hash-to-curve does NOT batch** (per-message). Two repo-specific caveats: (i) this repo's own
  `src/aggregator/AAStarBLSAggregator.sol` is NOT a generic multi-pairing — it enforces the **same
  node set** across the batch and aggregates message points into a **constant 2-pairing** check
  (`e(G, aggSig)·e(-aggPK, aggMsgPt)`), a different (and cheaper-at-scale) shape; (ii) the **currently
  mounted DVT validator 0x539B exposes no `aggregator()`**, so batch aggregation is **unavailable on
  the deployed stack** today. Also tier-2/3 are high-value low-frequency ops → a bundle rarely holds
  many at once, so the practical opportunity is small regardless.

### ④ Move messagePoint off-chain (saves ~66k, security cost) — NOT recommended
On-chain hash-to-curve recomputation is the #45 anti-oracle fix. Accepting a caller-supplied point
reintroduces cross-op replay unless bound another way — and checking a supplied point is merely
*well-formed* is NOT the same as binding it to `userOpHash`; the only cheap way to guarantee that
binding is to recompute it on-chain. Security↔gas trade-off, not a free win. Document as a
considered-and-rejected alternative.

## 4. Who executes what

### 4a. Trust-model decision (DECIDED 2026-08-16): keep decentralization, do NOT swap the mount
The two contracts implement the same `IAAStarAlgorithm` interface but embody **different trust models**:
YAAA's 0x539B is a **permissionless, stake-bound (slashing) decentralized validator**; our
`AAStarBLSKeyRegistry` is a **Safe-curated, owner-gated, no-stake** key set. Swapping the mount to ours
would be cheaper/easier-to-maintain but would **replace decentralized+economically-secured verification
with a centrally-curated key list** — undermining the DVT's whole point and the paper's decentralization
narrative. And part of ours' lower cost is because it *does less* (no stake enforcement) — not a free
win. **Decision: keep 0x539B mounted (decentralized); optimize its implementation in place. Our registry
is a REFERENCE for the crypto hot-paths, not a replacement.**

- **airaccount-contract (us)**: owns the analysis + the reference implementation
  (`AAStarBLSKeyRegistry`). Optional airaccount-side substantiation: deploy our registry to Sepolia,
  register the 3 DVT pubkeys, `estimateGas validate()` on the same real aggregate → a measured
  "our approach = X gas vs YAAA 514k" before/after. This is the strongest paper evidence and the
  cleanest way to validate ①'s hypothesis without guessing.
- **repo:dvt (YAAA, owns 0x539B)**: run the forge per-precompile trace; evaluate porting the
  assembly approach + safe pubkey caching; measure before/after. Actual contract change is theirs.
- **DSR (paper)**: §5.1 upgrades from "measurement" to "measurement + optimization roadmap"
  (measured cost + where the gap is + concrete levers) — a stronger systems contribution.

## 5. Open items (must not be asserted as fact until closed)
- **Public, verifiable dvt artifact** for the per-precompile split (458,380 / 51,088 / 304,017): the SHA I
  was given resolves nowhere public — the split is currently **repo:dvt-reported, not independently
  reproduced** (§2). CLOSE by citing a published dvt commit + forge output.
- **3-node production trace**: the reported 458,380 is a **2-node bootstrap**; production ≈ 469k (§2).
- **Sub-split of YAAA's ~304k** into stake-SLOAD vs generic-glue — only repo:dvt can (its contract).
- §4.3 cumulative-tier path was NOT covered by the n=10 batch (benchmark account guard()==0);
  a guard-on rerun would measure that separate ~few-k overhead.

> Resolved this round (were open in earlier drafts): the per-precompile split is now *reported* in §2
> (though still unverified), and `AAStarBLSKeyRegistry.validate()` was measured cheaper than 0x539B in §3①
> (219,963) — both nonetheless remain pending an independently verifiable dvt artifact.
