# v0.17.2-beta.4 — Impact Assessment (boundary, security, performance, timing, SDK, guard)

This documents the full blast radius of the bundler-compat algId fix, answering: what changed, what is the boundary, and what every dependent (guard, SDK, tests, existing accounts) must do.

---

## 1. `getCurrentAlgId()` / `getCurrentSessionKey()` — status

**These functions are NOT removed. They are kept.**

- Their ORIGINAL consumer was `TierGuardHook.preCheck()`, which was **deleted in v0.17.2-beta.1**. So in the current codebase **no production/src contract calls them** — only 3 test assertions (`test/AAStarAirAccountV7_M7.t.sol`) and 2 stale code comments reference them.
- They are harmless read-only getters that peek at the same-frame transient algId/sessionKey queue.
- I considered deleting them to reclaim ~125 bytes of EIP-170 budget, but **kept them** because (a) tests exercise them, (b) removing is an external-ABI change for ~125 bytes, and (c) after dropping the heavier `executeBatch` decode we have **1,032 bytes** of headroom — no need.
- "Vestigial" = their original caller is gone; they still correctly expose the queue and may be used by a future external hook. No action needed.

---

## 2. Change boundary (what changed vs what did NOT)

**Changed (6 src files):**
| Contract | Change |
|---|---|
| `AAStarAgentStorageLayout` | **append** `approvedAlgorithms` at slot 24 (no existing slot moved) |
| `AAStarGlobalGuard` | whitelist REMOVED; `checkTransaction(value,algId)`→`recordSpend(value)`; `checkTokenTransaction`→`recordTokenSpend` (keeps algId); `approveAlgorithm`/`approvedAlgorithms`/`AlgorithmNotApproved` removed |
| `AAStarAirAccountBase` | `_initAccount` populates account whitelist; `guardApproveAlgorithm` writes account; `_enforceGuard` drops `guardAlgId`, calls record*; `_populateExecAlg` added |
| `AAStarAirAccountV7` | `validateUserOp` whitelist+per-op-tier gate; `executeUserOp` added (selector-allowlisted); `_validationTierOk` added |
| `AAStarAirAccountFactoryV7` | guard constructor no longer passed `approvedAlgIds` |
| `AirAccountDelegate` | ECDSA-only, constant algId, record* |

**NOT changed (reused as-is):** `AAStarValidator` (router), `SessionKeyValidator`, `ForceExitModule`, `AAStarBLSAlgorithm`, `AAStarBLSAggregator`, `CalldataParserRegistry`, `AgentRegistry` logic, all signature-verification algorithms, social recovery, module install/uninstall, agent/ERC-8004, weighted governance.

**Existing deployed accounts (beta.3):** UNAFFECTED. They are EIP-1167 clones bound to the old (immutable) impl. They keep old behavior (and the old bundler limitation). Non-upgradable by design → users migrate to a beta.4 account. No on-chain migration of existing accounts.

---

## 3. The GUARD and algId — answering "how does the guard know which algorithm to verify?"

**The guard never verified signatures.** Signature verification is done in `validateUserOp` → `_validateSignature` (and the validator router for BLS/session). The guard only ever did **policy accounting**. The `algId` the old guard received was used for exactly two things:

| Old guard use of algId | Where it moved |
|---|---|
| **Whitelist** `approvedAlgorithms[algId]` (is this algorithm allowed?) | → the **account** (`approvedAlgorithms`, slot 24), enforced in `validateUserOp` |
| **Token-tier math** (does the signature's tier cover the token amount?) | → **stays in the guard**: `recordTokenSpend(token, amount, algId)` keeps `algId` |

The **ETH tier** check (signature tier vs ETH value) was **already in the account**, not the guard — `_enforceGuard` (`AAStarAirAccountBase.sol:1110-1118`) reads only `guard.todaySpent()` (a number, no algId) and computes `_algTier(algId)` with the account's algId. So the guard's ETH path (`checkTransaction`) used `algId` ONLY for the whitelist revert.

**Therefore dropping `algId` from `recordSpend(value)` loses nothing** — the ETH daily limit is a pure value cap, and the only algId-dependent ETH logic (whitelist + tier) lives in the account. `recordTokenSpend` still carries `algId` for the per-token tier calculation. No algorithm information is lost; it is simply owned by the account (the correct owner) instead of the guard.

---

## 3a. Why ERC-7562 forbids reading the (unstaked) guard in validation

This is *the* constraint that shapes the whole design: it dictates what can move to `validateUserOp` and what must stay in execution.

**Why the rules exist.** In ERC-4337 a bundler **simulates `validateUserOp` off-chain** to decide whether to include a UserOp — it will not pay gas for an op that ultimately fails. A malicious account could make validation pass during simulation but behave differently once mined (e.g. by reading some external storage that another transaction changed in between), making the bundler include a doomed op and eat the gas — a DoS on bundlers. ERC-7562 (the validation rules) prevents this by restricting which storage `validateUserOp` may touch.

**What validation may read/write.**
1. The account's **own** storage (slots at the account's address) — unrestricted.
2. **Associated storage** of another contract: a slot of the form `keccak256(account ‖ x)` (i.e. a mapping keyed by the account address) in contract `A`; **or** *all* of `A`'s storage if `A` is **staked** (a stake makes `A` accountable — misbehavior can be throttled/slashed).
3. It may **not** read arbitrary storage of an **unstaked external** contract whose slots are not keyed by the account — precisely because that storage can change between simulation and inclusion, so validation results couldn't be trusted.

**Why AirAccount's guard is out of bounds.** `AAStarGlobalGuard` is a **separate, per-account, unstaked** contract, and its state (`approvedAlgorithms`, `dailySpent`, `tokenConfigs`) uses **plain slots** (one guard per account — not a mapping keyed by the account address). So to ERC-7562 it is exactly "an unstaked external contract with non-associated storage" → `validateUserOp` **cannot read it**. This is the original reason all guard checks lived in execution (and why algId had to be smuggled forward via transient storage — the thing the bundler split-simulation then cleared).

**What this lets beta.4 do, and not do:**
- The **algorithm whitelist** is a static set, so it was **moved onto the account's own storage** (slot 24) — now `validateUserOp` may read it legally, and the whitelist is enforced authoritatively in validation. ✅
- The **cumulative / daily tier** needs `guard.todaySpent()` — a counter that *lives in the guard* and *changes on every spend*, i.e. exactly the kind of mutable external state the rules forbid in validation. So it **must stay in execution** (surfaced to clients at gas-estimation time via the `executeUserOp` simulation). Only the **per-op** tier (this op's value vs the account-local thresholds — own storage) can run in validation.

One line: *the bundler-safety rules confine validation reads to the account's own / associated / staked storage; a per-account unstaked guard qualifies for none of those, so its mutable counters are unreadable in validation — the static whitelist could move to the account, the dynamic limits could not.*

---

## 4. Call timing / sequencing

**Before:** `validateUserOp` `tstore(algId)` → (bundler clears transient between eth_calls) → `execute` `tload(algId)` → `guard.checkTransaction(value, algId)`. Broke under bundler split-simulation (algId=0).

**After:**
- **validateUserOp** (one eth_call): `_validateSignature` verifies + stores algId in the SAME frame → whitelist gate reads it (account storage) → per-op tier gate. Authoritative algorithm/tier gate; runs in estimation AND real handleOps.
- **executeUserOp** (the EntryPoint execution entry, one eth_call): `_populateExecAlg` re-derives algId from `userOp.signature` in THIS frame → `_setCallDataKey(keccak256(inner))` → self-`delegatecall(inner)` → `execute()`/`executeBatch()` read the same-frame algId → tier + `recordSpend`/`recordTokenSpend`.
- **owner-direct `execute()`** (no EntryPoint): `algId = ALG_ECDSA`, full guard accounting. Unchanged.

**Key invariant:** transient storage is now used **only within a single call frame** (validate's frame, or executeUserOp's frame) — never across the validate→execute eth_call boundary. That boundary crossing was the bug.

---

## 5. Security

- **Whitelist:** single source of truth (account), enforced in validation, ERC-7562-legal (own storage). No mirror → no desync.
- **Tier:** per-op fail-fast in validation; cumulative authoritative in execution (ERC-7562 forbids reading guard `todaySpent` in validation; surfaced to clients at estimation via the executeUserOp simulation revert).
- **`executeUserOp` selector allowlist:** only `execute`/`executeBatch` may be dispatched — nesting and arbitrary selectors revert (`UnsupportedInnerSelector`). Closes the CRITICAL where a nested, never-validated signature could forge a high algId.
- **`_populateExecAlg` no-reverify (except weighted):** safe because (a) in real handleOps the EntryPoint runs `validateUserOp` (which verifies that exact signature) before `executeUserOp` in the same tx; (b) the selector allowlist prevents reaching `_populateExecAlg` with a second unvalidated signature.
- **Reviewed:** Opus + Codex (4 rounds). Final verdict SHIP; 1 CRITICAL + 2 MEDIUM found and resolved.

---

## 6. Performance / gas

- `validateUserOp`: +1 SLOAD (whitelist) + per-op tier (cheap calldata read + 2 pure calls) when guard present. ~+2–3k gas.
- `executeUserOp` path: self-delegatecall overhead (~small) + `_populateExecAlg`. Non-weighted: cheap (prefix read). **Weighted: re-runs `_validateWeightedSignature` → the weighted signature is verified TWICE per bundler op (once in validate, once in execute).** Notable only for the rare weighted-via-bundler case; documented tradeoff (chosen for bytecode reuse / EIP-170).
- `recordSpend`: slightly cheaper (no whitelist SLOAD).
- Account runtime: 21,862 → 23,544 bytes (1,032 under EIP-170).

---

## 7. SDK impact (ACTION REQUIRED for @aastar/sdk)

1. **callData wrapping (breaking for bundler path):** for guard-enabled accounts going through a bundler, the SDK MUST set
   `userOp.callData = executeUserOp.selector ‖ <execute|executeBatch calldata>`
   instead of the bare `execute(...)` calldata. The EntryPoint v0.7 routes the wrapped callData to `executeUserOp`. (No-guard accounts can still use bare callData, but wrapping works universally.) Owner-direct (non-bundler) `execute()` is unchanged.
2. **Whitelist now read from the account:** `account.approvedAlgorithms(algId)` (was `guard.approvedAlgorithms`). `account.guardApproveAlgorithm(algId)` is unchanged in signature.
3. **Guard ABI changed:** `checkTransaction`/`checkTokenTransaction`/`approveAlgorithm`/`approvedAlgorithms` removed; `recordSpend`/`recordTokenSpend` added. Any SDK code calling the guard directly must update (most SDKs go through the account and are unaffected).
4. **ABI regenerated:** `abi/AAStarAirAccountV7.full.json` rebuilt (66 functions) to include `executeUserOp` + `approvedAlgorithms`. SDK must consume the new ABI.

---

## 8. Tests

- 730 unit tests pass (was 723 + new). 11 existing files migrated to the new guard API; 2 tier tests updated (under-tier now rejected in validation, not execution); 5 obsolete guard-whitelist stubs removed; new `test/Beta4AlgIdBundlerFix.t.sol` (10 cases: split-sim reproducer, tier resolution, whitelist gate, nesting rejection, per-op tier gate).
- E2E regression (Phase 08-12, incl. the guard-enabled-bundler case) runs post-deploy.

---

## 8a. Per-area test coverage + capability verdict

Every behavior touched by beta.4, mapped to its test(s) and a verdict: **UNCHANGED** (same capability, relocated/renamed), **CHANGED-GOOD** (intended improvement), or **CHANGED-BAD** (regression — none found). Full suite: **731 pass / 0 fail**.

| # | Changed area | Test(s) | Capability verdict |
|---|---|---|---|
| 1 | Whitelist owned by account (slot 24), populated from config | `test_whitelist_populatedOnAccountFromConfig`; factory tests `acc.approvedAlgorithms(...)` | **UNCHANGED** — whitelist still enforced, relocated to account. Single source of truth = **GOOD**. |
| 2 | `guardApproveAlgorithm` writes account, owner-gated | `test_guardApproveAlgorithm_writesAccountNotGuard`, `test_guardApproveAlgorithm_onlyOwner` | **UNCHANGED** — same monotonic-add semantics + access control. |
| 3 | `validateUserOp` whitelist gate | `test_validateUserOp_acceptsWhitelistedAlg`, `test_validateUserOp_rejectsNonWhitelistedAlg` | **CHANGED-GOOD** — non-whitelisted algId now rejected in validation (was execution); enables bundler. |
| 4 | `validateUserOp` per-op ETH tier gate | `test_validateUserOp_rejectsUnderTierValue`, `test_validateUserOp_acceptsWithinTierValue`; updated `WeightedSignature`/`M5Scenario` tier tests | **CHANGED-GOOD** — under-tier op fails fast in validation instead of wasting deposit at execution. |
| 5 | `executeUserOp` bundler-split execution | `test_executeUserOp_splitSimulation_executes` | **CHANGED-GOOD (the fix)** — guard account executes through the separate execution eth_call; no `AlgorithmNotApproved(0)`. |
| 6 | `executeUserOp` algId re-derivation (tier) | `test_executeUserOp_tieredAccount_resolvesAlgId`, `test_executeUserOp_rederivesNonEcdsaTierFromPrefix` | **CHANGED-GOOD** — correct tier resolved from signature in-frame (ECDSA + tier-3 prefix); not cleared-transient 0. |
| 7 | `executeUserOp` selector allowlist | `test_executeUserOp_rejectsNestedWrapper`, `test_executeUserOp_rejectsArbitrarySelector` | **CHANGED-GOOD** — closes the nested/arbitrary-selector tier bypass (Codex CRITICAL). |
| 8 | `executeUserOp` + `executeBatch` | `test_executeUserOp_executeBatch_runsAllCalls` | **UNCHANGED** — batch executes all calls through the wrapper. |
| 9 | Guard ETH daily limit via new path | `test_executeUserOp_dailyLimitStillEnforced`; `AAStarGlobalGuard.t.sol` recordSpend tests | **UNCHANGED** — daily limit still enforced (now via `recordSpend`). |
| 10 | Guard token tier + daily | `AAStarGlobalGuardM5.t.sol` `recordTokenSpend` tests | **UNCHANGED** — token tier + daily still enforced (algId kept for tier math). |
| 11 | Cumulative ETH tier (batch/multi-tx) | `WeightedSignature`/`M5Scenario`/`M7` cumulative tests | **UNCHANGED** — still authoritative in execution (`_enforceGuard`). |
| 12 | EIP-7702 `AirAccountDelegate` | `AirAccountDelegate.t.sol` (migrated) | **UNCHANGED** + now bundler-compatible (constant ECDSA algId). |
| 13 | Direct owner `execute()` path | existing execute tests + `test_directExecuteViaEntryPoint_tiered_revertsFromClearedAlgId` | **UNCHANGED** — owner-direct uses ALG_ECDSA, full guard. |
| 14 | Untouched subsystems: BLS/P256/cumulative/combined/session/weighted sig validation, social recovery, ERC-7579 modules, agent/ERC-8004, ForceExit, weighted governance | their existing suites (all green) | **UNCHANGED** — full regression suite (731) passes. |
| 15 | EIP-170 account size | `Eip170Size.t.sol` | within limit (23,419 / 24,576; 1,157 free). |

**Overall conclusion:** no capability was lost or weakened (**no CHANGED-BAD**). The whitelist/daily/tier/token/cumulative guarantees are all preserved (relocated or renamed, with tests confirming each). The *new* behaviors are all improvements: bundler compatibility (the goal), fail-fast validation rejection, a single source of truth for the whitelist, and a closed tier-bypass. The only costs are documented and accepted (weighted double-verify gas; cumulative tier stays execution-side per ERC-7562).

## 9. Residual / accepted

- Weighted-via-bundler double-verifies the weighted signature (gas). Accepted (rare; bytecode reuse).
- Cumulative tier not enforceable in validation (ERC-7562). Authoritative in execution + surfaced at estimation.
- Existing beta.3 accounts not retrofittable (non-upgradable). Migration to beta.4 required for bundler use.
