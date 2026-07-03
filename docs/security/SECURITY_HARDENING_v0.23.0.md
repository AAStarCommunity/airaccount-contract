# AirAccount — Global Security Hardening Report (v0.23.0)

> Date: 2026-07-03 · Scope: full contract architecture (~7,600 LOC, 25 contracts) · Method: 6-subsystem
> parallel adversarial audit + manual verification of every High. Prior audit rounds (M1–M7, multiple
> Codex passes) are treated as resolved; this report targets **residual, systemic, architectural** risk.

---

## 0. On the goal "100% security"

There is no 100% in smart contracts, and it would be dishonest to hand you a report that implies otherwise —
especially for a **non-upgradable** wallet with **off-chain trust anchors** (a TEE-held owner key, a DVT
quorum, an owner-controlled parser registry). Any of those, if compromised, defeats on-chain logic that is
otherwise perfect. So this report reframes the target as a **defensible, explicit assurance level**:

> **Target invariants (achievable):**
> 1. No **single stolen key** (owner ECDSA *or* device passkey *or* one guardian) can move more than the
>    **Tier-1 limit** or take over the account.
> 2. No **single guardian** can either seize the account *or* permanently deny its governance.
> 3. No **unprivileged actor** (mempool observer, DApp, relayer, installed module, session key) can gain
>    anything beyond what its grant explicitly allows.
> 4. Every **privileged singleton** (router / aggregator / parser registry / factory admin) is a
>    multisig + timelock + monitored, and its blast radius is bounded and documented.
>
> **The audit's core finding:** the codebase is ~90% of the way to invariants 1–4, with **high per-function
> quality**, but there are **four confirmed gaps where the marketed threat model ("survive owner-key
> compromise") is wider than the enforced one**, plus a cluster of "the guard is a conditional, not
> universal, backstop" issues. None are trivially exploitable today; several are one small commit from
> closed. The rest of this document is the register + a cost/benefit roadmap.

---

## 1. Global trust model (the map you judge "safe" against)

```
                         ┌───────────────────────── OFF-CHAIN TRUST (not enforceable on-chain) ─────────┐
   owner ECDSA key ──────┤ KMS / TEE           DVT node quorum          parser-registry owner (Safe)     │
   device passkey  ──────┘   (T1 co-sign)      (T2/T3 BLS factor)       (token-limit correctness)        │
                         └────────────────────────────────────────────────────────────────────────────┘
                                    │                     │                          │
   UserOp ─► EntryPoint ─► Account.validateUserOp ─(algId route)─► validator router (SHARED SINGLETON)
                                    │                                          │  BLS algo / session-key (SHARED)
                        ┌───────────┴───────────┐
                        │  VALIDATION (stateless)│  approvedAlgorithms whitelist + per-op tier gate
                        └───────────┬───────────┘  (⚠ skipped when guard == 0)
                                    │  content-keyed transient algId queue  (binds validation ↔ execution)
                        ┌───────────┴───────────┐
                        │  EXECUTION (stateful)  │  execute / executeBatch / executeFromExecutor
                        └───────────┬───────────┘
                                    ▼
                    AAStarGlobalGuard  ── the "last line" ──  ETH daily cap + cumulative tier + token limits
                        (immutable, per-account, monotone)      ⚠ opt-in: no guard if dailyLimit==0
                                    ▲                            ⚠ token amount comes from PARSER (shared, add-only)
                                    │                            ⚠ strict mode OFF by default (unconfigured tokens free)
   ─── SEPARATE CHANNEL that never reaches the guard ───► ERC-1271 isValidSignature(owner ECDSA) ─► DApp transferFrom
   ─── SEPARATE facet (fallback→delegatecall) ─────────► AirAccountExtension: recovery / modules / weight gov
   ─── SEPARATE deploy path ───────────────────────────► Factory.createAccountWithDefaults (guardians unbound)
```

Everything to the right of a ⚠ is where "global, not local" judgement matters: each is individually
reasonable, but their **composition** is where the residual risk lives.

---

## 2. Findings register (ranked; every High manually verified)

Severity = impact × likelihood within the wallet's **stated** threat model (survive owner-key compromise;
resist mempool front-run; bound delegated authority). "Conv." = independently flagged by ≥2 audit tracks
(higher confidence). "Status" = verified live / dormant / by-design-but-mismarketed.

### 🔴 HIGH

| # | Finding | Where | Why it matters (global) | Status |
|---|---------|-------|-------------------------|--------|
| **H-A** | **ERC-1271 `isValidSignature` is an unconditional Tier-1 owner side-door.** Owner ECDSA over *any* hash → ERC-1271 magic, with **no tier / guard / cumulative check**. | `AAStarAirAccountV7.sol:156` | A stolen owner key signs a Permit2 / EIP-2612 permit; the DApp `transferFrom`s arbitrary ERC20 — **`execute()` and therefore `_enforceGuard` are never reached**. The tier system only governs *account-initiated* calls, not *signature-settled* value. This is the single widest gap between "survive owner compromise" (marketed) and reality. | Verified. Partly inherent ERC-1271 semantics, but contradicts the "uncircumventable tier" claim. |
| **H-B** | **`_isWeakening` ignores weight *increases*.** Weakening is flagged only on *decreases*, so a compromised owner raises passkey/ecdsa weights (each `< tier1Threshold`) and — with owner-only factors — accumulates into **Tier-3**, no guardian consent. | `AirAccountExtension.sol:699` (gated `:617`) | Defeats the guardian-proposal flow whose entire purpose is stopping an owner from unilaterally lowering the bar. Precondition: weighted mode (algId 0x07) configured. | Verified logic bug. |
| **H-C** | **`createAccountWithDefaults` binds guardians to neither the address nor the signed digest.** Salt = `keccak256(owner,salt)`; ACCEPT_GUARDIAN digest omits guardian identities. | `Factory:315,599` | Mempool attacker front-runs with **their own** guardian addresses + self-signatures → same counterfactual address, victim `owner`, **attacker guardians** → social-recovery takeover after 2 days (owner can't cancel; needs 2-of-3). The prior "guardian-swap fix" covered the `createAccount` (configHash-in-salt) path, **not** this sibling. | Verified. Live iff the convenience path is used by the SDK. |
| **H-D** | **`onlyOwnerOrSelf` self-call escalation.** Any authority that can make the account call *itself* — an installed **executor module** *or* an **unscoped session key** — can invoke `execute(address(this), setTierLimits / setWeightConfig / modifyTierLimits…)`, which `onlyOwnerOrSelf` accepts, and **raise the very limits meant to bound it**. | `V7:354` + `Base:296` + `Ext:617,1332`; session `SessionKeyValidator:492` | Two independent audit tracks converged here. The `onlyOwnerOrSelf` modifier (added v0.20.3 for gasless self-config) composes with the executor/session models — each individually correct — into an authority-widening seam. | Verified. **Conv. (×2).** |
| H-E | **UniswapV3Parser `exactInput` reads wrong ABI offsets** → records `amount = deadline` (~0 vs 18-dec limits) and `token = garbage` (→ unconfigured → unlimited). Guard sees ~0 spend on real multi-hop swaps. | `UniswapV3Parser.sol:103` | If ever enabled, a swap path drains funds under the guard's nose. Root: single-dynamic-struct arg has an outer tuple-offset word the parser skips (dev comment shows the confusion). `exactInputSingle` is correct. | Verified — but **DORMANT**: parsers are `KI-14, disabled`, not registered in any deployment. **Must fix before enabling.** |
| H-F | **Parsers decode only the FIRST array element** (`shield(ShieldRequest[])`, `transact(Transaction[])`, multi-hop). Elements `[1..N]` unaccounted → cumulative-tier "batch bypass" defeated *before* the guard sees it. | `RailgunParser.sol:112` (+ design) | Same class as H-E: parser under-report = guard bypass. | Verified — **DORMANT** (parsers disabled). |

### 🟠 MEDIUM

| # | Finding | Where | Note |
|---|---------|-------|------|
| **M-A** | **Guard *and* algId whitelist are opt-out at birth.** `createAccount` deploys no guard when `dailyLimit==0`; `_enforceGuard` is then a no-op, **and** the `approvedAlgorithms` whitelist + per-op tier gate are skipped (`V7:241` is `&& guard != 0`). Such an account is still `markValid`'d → SuperPaymaster sponsors it identically. | `Factory:274`, `V7:241`, `Base:1497` | **Conv. (×4).** A guard-less account loses the spending backstop *and* the router-algId containment (see systemic risk S-2). The "uncircumventable hardcoded ceiling" holds only for guarded accounts. |
| **M-B** | **Token-limit TCB is weak: parser registry is `onlyOwner`, non-monotonic, add-only, and its output is trusted verbatim** (no `token==dest` check, no amount bound, no post-call balance-delta). | `Base:464,1678`; `CalldataParserRegistry:50` | **Conv. (×2).** A compromised registry owner (or any parser bug, cf. H-E/F) silently converts "hard limit" → "no limit" for every account, and add-only means bugs can't be patched in place — only a full registry migration. Unlike the immutable guard / monotonic whitelist, this control breaks the project's own "only-tighten" philosophy. |
| **M-C** | **`validateUserOp` reverts (not `return 1`) on malformed ECDSA** in 4 higher-tier paths using OZ `.recover` (high-S / bad-v). | `Base:1001,1090,1163,1239` | Violates the ERC-4337/7562 revert-free invariant the team enforces elsewhere (WebAuthn path even documents it). Bounded (bundler drops the op; no theft) but is a spec/robustness gap and a same-class regression. Fix: `tryRecover` + `!=0`. |
| **M-D** | **Recovery proposals never expire** → on a 2-guardian account, one compromised guardian `proposeRecovery` (free, no sig) **permanently wedges** all guardian/weight governance (can't execute, can't cancel, can't expire). A malicious guardian also front-runs its own eviction. | `Ext:1196,1214,1268` | Asymmetric toward denial: 1 guardian can DoS governance forever, though it can never reach the 2-of-3 needed to take over. Fix: proposal expiry (mirror weight-change/module-install) and/or owner-cancel-while-sub-threshold. |
| M-E | **BLS registration performs no on-chain proof-of-possession** despite a `_POP_` DST → rogue-key aggregate setting; contained only by `onlyOwner` (Safe) + off-chain enrollment. **No per-account DVT node-set authorization** (#45 Fix 2 gap). | `AAStarBLSAlgorithm.sol:77,588` | Safe *only* because BLS is always a *second* factor behind owner ECDSA. If BLS ever becomes a sole/differentiating authority, a colluding registered DVT quorum forges approvals across all accounts. Off-chain trust assumption — state it explicitly. |

### 🟡 LOW / INFO (condensed)

- **Process/CI:** storage-layout parity is convention-only (slot comments already drifted "off-by-2"); no CI guard; no selector-uniqueness assertion across the account+Extension ABI. → both are cheap CI gates.
- **`_disableInitializers()` not called** on the impl (benign for clones, but an anti-pattern footgun); **`initialize` not factory-restricted** (relies on atomic deploy+init).
- **`setStrictMode(false)`** is a non-monotonic (loosening) setter — contradicts the guard's "only tighten" header.
- **Router `AAStarValidator` uses single-step `transferOwnership`** (BLS algo correctly uses Ownable2Step) — governance-bricking on fat-finger.
- **`uint8` weight accumulation can overflow-revert** `validateUserOp` (owner-misconfig DoS); cap the sum ≤255.
- **P256 guardian key not deduped vs the owner passkey**; **P256 guardian weight is silently dead in weighted mode** (fails closed).
- **7702 `AirAccountDelegate.cancelRescue` is guardian-only** but NatSpec claims a 2-day owner-cancel window — **materially misleading**; 2 colluding guardians drain all ETH with zero owner recourse. `execute` sweeps ETH only. Delegate is explicitly an onboarding tier to migrate off.
- **`isValidOwnerAuth` / `_verifyWebAuthnOwnerSig` logic is duplicated** across Extension and Base — future drift risk (the very drift the view exists to prevent).
- Session **velocity** limiter is soft/cross-bundle-racy (documented, accepted — hard caps live in the guard).

### ✅ Verified SOUND (do not spend budget re-hardening these)

KMS relay-mode sig domain (binds chainId+factory+owner+salt+P256+configHash+nonce+deadline); `createAccount`/`createAgentAccount` front-run resistance; AgentRegistry provenance (factory-gated `markValid`, no forgery); guard per-account immutability + monotonic ETH/token limits + `minDailyLimit` floor; BLS message-point on-chain recompute from `userOpHash` (#45 Fix 1), set-once router/aggregator, Safe-owned Ownable2Step aggregator; cumulative-sig parsing bounds (no layer-skip/overlap); WebAuthn/P256 challenge & prefix binding, low-S, both-key-zero, precompile-fail handling; `_validateECDSA` and `isValidOwnerAuth` tag-0x01 (EIP-2 low-S, v-normalize, ecrecover(0)); content-keyed validation↔execution algId binding; ForceExit (owner-proposed, guard-capped, TOCTOU-safe); guardian signed-domain completeness + 2-of-3 threshold consistency + P256/ECDSA dispatch (no type confusion) + guardian-count floor; module-install auth-hash binding (invalidates on owner/guardian drift); transient reentrancy guard shared correctly across the delegatecall boundary; fallback target is a fixed immutable (no arbitrary-delegatecall/upgrade risk).

---

## 3. Systemic risks (the "global, not local" core — these are *design* properties, not bugs)

- **S-1 · The enforced threat model is narrower than the marketed one.** "Survive owner-key compromise"
  holds for value flowing through **guarded, account-initiated `execute`** — but **not** for ERC-1271
  signature-settled value (H-A), **not** for weighted-tier config (H-B), **not** for self-call config via
  executor/session (H-D). A stolen owner key is more powerful than "Tier-1 only." This is the report's
  headline: close H-A/B/D and the marketing becomes true; leave them and it's aspirational.
- **S-2 · The guard is a *conditional* backstop, not a universal one.** No guard when `dailyLimit==0`
  (M-A); strict mode OFF by default so non-ETH/unconfigured tokens are unbounded (module-install blast
  radius is "everything except ETH + configured tokens"); token amounts come from a shared, add-only,
  owner-mutable **parser** whose correctness is load-bearing and currently buggy-if-enabled (M-B, H-E/F).
- **S-3 · Shared singletons × non-upgradeability = bounded-but-unpatchable blast radius.** Router,
  BLS algo, aggregator, session-key validator, parser registry, and the Extension are singletons reused
  across every account and release. A compromise or bug in one is **systemic**, and there is **no on-chain
  fix** — only social migration of every account. Non-upgradeability is a deliberate, defensible choice; it
  caps achievable assurance and makes *governance discipline on the singleton owners* the top operational
  control.
- **S-4 · Off-chain anchors are the real ceiling.** KMS/TEE compromise = owner compromise = S-1 applies.
  DVT quorum collusion = BLS tier forged (M-E). Parser-registry-owner compromise = token limits off (M-B).
  The contract cannot enforce these; they must be covered by operational security + monitoring.

---

## 4. Hardening roadmap — by cost / benefit

Cost axis is dominated by one hard constraint: **the main account has only 222 bytes of EIP-170 headroom.**
On-account fixes are essentially impossible; everything must land in the **Extension (1,389 B)**, the
**factory/guard** (ample room), off-chain, or via refactor. This is factored into every estimate below.

### Tier 0 — do now (small diffs, high benefit, no new architecture)

| Fix | Addresses | Effort | Impact / cost | EIP-170 |
|-----|-----------|--------|---------------|---------|
| **Reject `target == address(this)` in `executeFromExecutor`; block `dest == account` in session `checkSessionScope`** | **H-D** | ~10 LOC | Cleanly severs the self-call escalation seam. No UX loss (executors/sessions never need to call the account itself). | account: tiny; session: in validator (no headroom issue) |
| **`_isWeakening`: also return true on any weight *increase*** (or validate weights vs tier2/tier3) | **H-B** | ~6 LOC | Closes owner-unilateral tier collapse. Cost: raising weights now needs the guardian proposal flow (correct behavior). | Extension |
| **Bind `guardian1,guardian2` into `createAccountWithDefaults` salt *and* ACCEPT_GUARDIAN digest** | **H-C** | ~4 LOC | Kills the front-run takeover. Cost: changes the counterfactual address derivation for this path → SDK + any docs must update. | factory (room) |
| **Replace `.recover` → `tryRecover`+`!=0` in the 4 validation paths** | **M-C** | ~8 LOC | Restores ERC-4337 revert-free compliance. | Base (tiny) |
| **CI gate: `forge inspect storageLayout` parity (account vs Extension) + selector-uniqueness across merged ABI + storage-snapshot diff on PR** | F4/F6 (S-3) | ~1 day CI | Makes the load-bearing storage invariant compiler-checked instead of convention. Zero runtime cost. | none |
| **`_disableInitializers()` in a production impl build; document the "impl deploys clone+init atomically" invariant** | F2/F3 | ~2 LOC | Removes anti-pattern + documents a load-bearing assumption. | account (tiny) |
| **`setStrictMode` one-way (on-only); router → Ownable2Step; cap `Σweights ≤ 255`; dedup P256 guardian vs owner passkey; fix 7702 `cancelRescue` NatSpec** | LOWs | ~1 day | Removes footguns + a materially misleading safety claim. | mixed |

### Tier 1 — next (medium cost, meaningful assurance gain)

| Fix | Addresses | Effort | Impact / cost |
|-----|-----------|--------|---------------|
| **Decide & document the ERC-1271 policy.** Either (a) scope `isValidSignature` to reject bare owner-ECDSA for value-bearing typed data / require the same tier factors, or (b) explicitly document that bearer/permit tokens are outside the tier guarantee and the account should not hold them under a tier policy. | **H-A / S-1** | design + code | The biggest single closure of the marketed-vs-enforced gap. Cost: option (a) can break generic DApp signing UX → needs careful scoping (e.g. a per-DApp allowlist or an EIP-712 domain filter). |
| **Make the guard universal.** Require `dailyLimit > 0` in `createAccount` (or always deploy a guard with a high sentinel cap); default **strict mode ON** for new accounts; treat guard-less accounts distinctly in the paymaster/risk layer. | **M-A / S-2** | code + product | Turns the guard from conditional to universal backstop. Cost: UX/onboarding friction + airdrop-token handling → mitigate with a generous default cap + easy `addTokenConfig`. |
| **Harden the parser TCB.** (i) Fix H-E/H-F **before** any parser is enabled; (ii) make `parserRegistry` monotonic + guardian-gated (match the guard's immutability model) with a governed replace path; (iii) add a **post-execution balance-delta assertion** in `execute`/`executeBatch` so parser output is advisory, not load-bearing. | **M-B / H-E/F / S-2** | medium | (iii) is the strongest structural fix — it makes token limits enforced by *actual* balance change, not by parser honesty (ERC-4337 forbids this at validation, but execution can do it). Cost: extra SLOADs/gas per token op. |
| **Recovery proposal expiry** (+ optional owner-cancel-while-sub-threshold). | **M-D** | ~15 LOC | Removes the only permanent single-guardian governance DoS. | Extension |
| **De-duplicate `_verifyWebAuthnOwnerSig`** into one shared internal used by both Base and Extension. | LOW | refactor | Removes the drift risk the view was built to prevent. |

### Tier 2 — strategic (high cost, for "maximum assurance" posture)

| Investment | Addresses | Payoff |
|-----------|-----------|--------|
| **DVT per-account node-set authorization + on-chain BLS proof-of-possession** (#45 Fix 2) | M-E / S-4 | Lets BLS become a trustworthy standalone differentiating factor instead of "second factor behind owner ECDSA." Prereq before any tier trusts DVT alone. |
| **Formal verification** of the two load-bearing invariants: (a) validation-approved tier == execution-enforced tier for every callData; (b) guard limits monotone + never bypassed by any `execute*` path. Certora/Halmos/SMT. | S-1/S-2 | Converts "we reviewed it" into "it is proven for all inputs" on the two properties that actually protect funds. |
| **Singleton migration framework** — a documented, tested, monitored process (and tooling) to migrate every account off a compromised/buggy singleton, since there is no on-chain upgrade. | S-3 | Turns non-upgradeability from "unpatchable" into "recoverable with effort." This is the real answer to "what if a singleton has a bug." |
| **Monitoring + circuit-breaker** — off-chain watchers on router/registry/aggregator owner actions, guardian-set changes, and large approvals; a guardian-consensus pause on the singletons (tension with immutability — pause the *router*, not the account). | S-3/S-4 | Detects the off-chain-anchor compromises the contract can't prevent. |
| **Top-tier external audit + bug bounty** scoped to the *systemic* properties (S-1..S-4), not per-function. | all | Independent adversarial coverage of exactly the composition risks internal review is weakest at. |

---

## 5. Impact assessment (what each tier buys, honestly)

- **After Tier 0 (≈2–3 days):** the four owner-compromise/front-run escalations (H-B, H-C, H-D) and the
  compliance gap (M-C) are closed; the storage/selector invariants become machine-checked. **Invariants
  2 & 3 (no single-guardian takeover, no unprivileged gain) are essentially met.** H-A remains a documented
  ERC-1271 caveat. This is the highest ROI work by far.
- **After Tier 1 (≈2–3 weeks):** the guard becomes a **universal** backstop, the parser TCB stops being
  load-bearing, ERC-1271 is policy-decided, and single-guardian DoS is gone. **Invariant 1 (single stolen
  key ≤ Tier-1) is met for all value flows**, not just account-initiated ones. This is the point where the
  "survive owner-key compromise" claim becomes defensible.
- **After Tier 2 (quarter-scale):** DVT becomes trustable standalone, the two fund-protecting invariants
  are *proven*, and the non-upgradeability risk is mitigated by a real migration path + monitoring.
  **Invariant 4 (bounded, governed, monitored singletons) is met.** This is the realistic ceiling.

**What remains uncloseable even after all three tiers (the honest residual):**
1. **KMS/TEE compromise = owner compromise.** If the TEE holding the owner key is broken, Tier-1 value is
   gone regardless of on-chain logic. Mitigation is operational (TEE attestation, key rotation), not contract.
2. **DVT quorum collusion** and **guardian collusion (2-of-3)** are trust assumptions by design.
3. **Non-upgradeability** means any *newly discovered* bug class still requires social migration; the
   framework (Tier 2) shortens but never eliminates that.
4. **Parser/oracle correctness** for arbitrary future DeFi protocols is an ongoing review burden, not a
   solved problem.

That residual — not "100%" — is the true security posture, and it is a *good* one once Tiers 0–1 land.

---

## 6. Recommended immediate actions (this week)

1. Confirm whether the SDK uses `createAccountWithDefaults` (→ sets H-C to live/dormant).
2. Confirm the parser-registry deployment state (→ keeps H-E/H-F dormant until fixed).
3. Land Tier 0 as a single hardening PR (all fit in Extension/factory/CI; the main account's 222 B headroom
   is untouched by every Tier-0 item except the ~1-word `executeFromExecutor` guard — verify size after).
4. Make the ERC-1271 (H-A) and guard-universality (M-A) **product decisions** — they have UX trade-offs and
   should not be decided unilaterally in code review.
```
```
