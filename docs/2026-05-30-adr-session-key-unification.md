# ADR: Session-Key System Unification + Pre-Release Architecture Cleanup

**Date**: 2026-05-30
**Status**: Proposed (pending Codex adversarial review + execution)
**Target tag**: v0.17.2 (supersedes v0.17.1; the latter has unmerged Codex-found issues)
**Owners**: AAStar contract team

---

## 1. Context

The 2026-05-30 Codex pre-release review of `v0.17.1` returned `HOLD` with 2 High + 3 Medium + 3 Low findings plus 5 documentation inconsistencies. While triaging the findings we discovered the deeper root cause behind several of them: the codebase ships **two parallel session-key systems** (M6.4 `SessionKeyValidator` and M7+ `AgentSessionKeyValidator`/ASK) with incompatible signature formats and different access patterns (router-fallthrough vs ERC-7579 module install), plus two thin proxy contracts (`CompositeValidator`, `TierGuardHook`) whose responsibilities mostly duplicate logic already present in `AAStarAirAccountBase`.

Rather than band-aid each finding individually and keep the dual session-key complexity, we are doing a focused architecture cleanup as part of the same PR.

### Findings driving this ADR

| Origin | Finding | Resolved by |
|---|---|---|
| Codex H-1 | HIGH-3 residual (identical-callData replication) | AUDIT NOTE comment block (no code change) |
| Codex H-2 | `AgentRegistry.accountId()` prefix check forgeable | Factory whitelist (`isValidAccount[account]`) |
| Codex M-1 | `createAgentAccount` does not install TierGuardHook | Hook deleted entirely; scope check inlined |
| Codex M-2 | `ForceExitModule` pays from its own balance, not the account | Use `account.executeFromExecutor` |
| Codex M-3 | Factory `defaultValidatorModule` / `defaultHookModule` never installed | Both fields removed; both target modules deleted (see below) |
| Codex L-1 | `_validateWeightedSignature` accepts trailing bytes | `if (cursor != sigData.length) return 1;` |
| Codex L-2 | `accountId()` returns `0.16.0` | Update to `0.17.2` |
| Codex L-3 | `TierGuardHook.sol:167` fallback value 0x01 has misleading "ALG_ECDSA" comment | Hook deleted entirely; bug eliminated |
| Codex doc | KI-11 / KI-7 stale; CHANGELOG missing v0.17.x; DEPLOYMENT misleading | Doc cleanup in PR B |
| Internal | `SessionKeyValidator` deployed by `DeployAirAccountV017.s.sol:111` but **never registered at algId 0x08 in the router** — session keys are *broken* in the current deploy script | Add `router.registerAlgorithm(0x08, ...)` after deploy |
| Internal | Two parallel session-key systems (M6.4 + ASK) with incompatible sig formats and access patterns | Unify per this ADR |
| Internal | `CompositeValidator` is a 1222 B pure-proxy back to `account.validateCompositeSignature` | Delete contract + delete the `validateCompositeSignature` callback in V7 |

---

## 2. Decision

### 2.1 Unify session-key system into one (enhanced) `SessionKeyValidator`

- **Delete** `src/validators/AgentSessionKeyValidator.sol`
- **Extend** `src/validators/SessionKeyValidator.sol` (originally M6.4) to subsume all ASK functionality:
  - Existing fields kept: `expiry`, `contractScope`, `selectorScope`, `revoked`
  - **New fields**: `velocityLimit (uint16)`, `velocityWindow (uint32)`, `callTargets (address[])`, `selectorAllowlist (bytes4[])`
  - **New runtime state**: `sessionStates[account][key] → {callCount, windowStart}` for velocity
  - **Semantics**: if `callTargets` is non-empty, it takes priority over `contractScope` (multi-target). Same for `selectorAllowlist` vs `selectorScope`. Empty array = fall back to single-value field (backward compatible with existing `grantSession`).
- **Sub-delegation (`delegateSession`) is dropped** — defer to v0.18+ when there is a real consumer.
- **Signature format**: keep M6.4 existing `[0x08][account(20)][key(20)][ECDSA(65)] = 106 bytes` (ECDSA) and `[0x08][account(20)][keyX(32)][keyY(32)][r(32)][s(32)] = 149 bytes` (P256). The ASK 66-byte format is not adopted — base already inline-parses 106/149.
- **Grant API**: keep both `grantSession` (EIP-712 owner sig — DApp/SP back-end on-boarding) and `grantSessionDirect` (`msg.sender == account` — UserOp from owner). Add a parameter to either or a parallel `grantSessionWithLimits()` that accepts the velocity + array fields.
- **Naming**: contract stays `SessionKeyValidator` (no rename); ABI-stable name across versions.

### 2.2 Delete `CompositeValidator` entirely

- It is a 1222 B pure proxy whose only logic is to call back into `account.validateCompositeSignature(...)`. `AAStarAirAccountBase._validateSignature` already natively dispatches all 8 algIds (0x01-0x08).
- Delete `src/validators/AirAccountCompositeValidator.sol`
- Delete `AAStarAirAccountV7.validateCompositeSignature` (no remaining caller)
- Delete `AAStarAirAccountFactoryV7.defaultValidatorModule` immutable + constructor param
- Delete `script/DeployAirAccountV017.s.sol` `new AirAccountCompositeValidator()` line + report entry
- Delete `test/SecurityFixes_M7_4.t.sol` H-5-related tests

### 2.3 Delete `TierGuardHook` entirely; inline its 1 useful staticcall into base

- It is a 1477 B contract whose `preCheck` does 3 wasted staticcalls (algId / sessionKey / dest+selector — all of which base already has directly) plus **1 useful staticcall** to `ASK.enforceSessionScope`.
- Since ASK is also being deleted, the useful staticcall becomes `SessionKeyValidator.checkSessionScope(account, key, dest, selector)` (a new view function on the enhanced M6.4 that handles multi-target + selector arrays).
- `base._enforceGuard` already does the equivalent staticcall for the simple `contractScope`/`selectorScope` path (L1108-1140). We **extend** that block to also check `callTargets[]` and `selectorAllowlist[]` against the enhanced session, plus enforce velocity on the validation-side counter.
- Delete `src/core/TierGuardHook.sol`
- Delete `AAStarAirAccountFactoryV7.defaultHookModule` immutable + constructor param
- Delete the deploy-script reference

### 2.4 Inline `accountSessionKeyValidator` lookup into base

- Add an immutable on V7 implementation: `address public immutable sessionKeyValidator;` (so `base._enforceGuard` can find the registry directly without doing `router.getAlgorithm(0x08)` and the associated potential-revert path)
- Factory's deploy script passes the deployed `SessionKeyValidator` address into V7's constructor.
- Existing `router.registerAlgorithm(0x08, sessionKeyValidator)` STILL happens (the router fallthrough in `base._validateSignature` calls `validator.validateSignature(...)` for the crypto verify) — bug fix to current deploy script.

### 2.5 Other locked-in items (already agreed)

- **H-1 AUDIT NOTE**: add a clear `// AUDIT NOTE — HIGH-3 residual (#52)` comment block above `_setCallDataKey` in `AAStarAirAccountBase` explaining why it's LOW (no asset redirect possible, requires owner-key compromise + identical-callData + bundle ordering).
- **H-2 AgentRegistry factory-whitelist**: replace the `accountId()` string-prefix check with an `isValidAccount[account]` mapping populated by the factory's `createAccount*` functions.
- **M-2 ForceExitModule executeFromExecutor**: rewrite `executeForceExit` to call `account.executeFromExecutor(mode, encode(target, value, calldata))` so the account pays from its own balance.
- **L-1**: `_validateWeightedSignature` ends with `if (cursor != sigData.length) return 1;`.
- **L-2**: `accountId()` → `"airaccount.v7@0.17.2"` (option A, version bump only — `0.17.1` was never deployed live).
- **L-3**: subsumed by the `TierGuardHook` deletion (the misleading-comment line ceases to exist).
- **Magic-number cleanup**: `AAStarGlobalGuard.sol:276` + `AAStarAirAccountFactoryV7.sol:388-391` change magic `0x01/0x03/0x04/0x05` to imported `ALG_*` constants (defer to PR B).

### 2.6 Sub-decisions (B-1 / B-2 / B-3 / B-4)

| # | Question | Decision | Rationale |
|---|---|---|---|
| B-1 | Keep `delegateSession`? | **Drop** | Saves ~1500 B; no real consumer; can re-add when needed |
| B-2 | Signature format | **Keep M6.4 existing (106/149 bytes)** | Base already inline-parses; ASK's 66-byte format was an artifact of the now-removed ERC-7579 module path |
| B-3 | Keep both `grantSession` (EIP-712) and `grantSessionDirect`? | **Yes, both** | EIP-712 owner-sig grant is a genuine M6.4 capability (DApp back-end on-boarding) that ASK lacked |
| B-4 | Rename enhanced contract? | **Keep `SessionKeyValidator`** | Stable contract name across versions; "v6.4" / "v7" / "agent" labels are noise |

---

## 3. EIP-170 budget impact

| Contract | Before | After | Headroom (24,576 B) |
|---|---|---|---|
| V7 implementation | 22,697 B | ~23,000-23,200 B (+ ~300-500 B from inline scope check + immutable getter + ASK-removal cleanup) | ~1,400 B left |
| `SessionKeyValidator` (enhanced) | 5,615 B | ~7,500-8,000 B (+ velocity + arrays, - delegate not added) | ~16,500 B left |
| `AgentSessionKeyValidator` | 5,123 B | **0 (deleted)** | n/a |
| `AirAccountCompositeValidator` | 1,222 B | **0 (deleted)** | n/a |
| `TierGuardHook` | 1,477 B | **0 (deleted)** | n/a |

Net runtime bytecode deployed by the factory's deploy script: **−7,822 B + ~2,300 B = −5,500 B (saved)**.

Storage layout: **no `AAStarAgentStorageLayout` change** — all new state lives on the external `SessionKeyValidator` contract. Diamond-lite invariant preserved.

---

## 4. Backward compatibility / migration

- **Live deployments**: v0.17.1 was tagged but **not deployed** anywhere (factory addresses in `DEPLOYMENT-v0.17.1.md` are placeholders `0x...`). Therefore there are zero live ASK sessions to migrate, and zero live M6.4 sessions to migrate.
- **SDK (`@aastar/sdk` PR #29 / #31)**: was already approved against v0.17.1's ABI which exposes ASK. SDK will need a minor update for v0.17.2 — drop ASK type, use enhanced `SessionKeyValidator` for both human and agent session keys. New issue to file on `aastar-sdk` repo.
- **SuperPaymaster**: relies on `AgentRegistry`, not on the session-key validator. H-2 changes `AgentRegistry` registration API. SP team needs to be notified of new whitelist mechanism (it doesn't directly call `accountId()`).
- **Documentation**:
  - `docs/contract-registry.md` §1.2 update validator list
  - `docs/known-issues.md` KI-11 (text update for H-1 AUDIT NOTE alignment) + KI-7 (P256 fallback claim is wrong, no fallback exists — fail-fast)
  - `docs/sdk-abi-mapping.md` collapse two session-key APIs into one
  - `docs/erc-8004-integration.md` no change (orthogonal)
  - `CHANGELOG.md` add v0.17.0 / v0.17.1 / v0.17.2 entries
  - `DEPLOYMENT-v0.17.1.md` → rename `DEPLOYMENT-v0.17.2.md`

---

## 5. Alternatives considered

### A. Move all session-key logic into V7 (full inline)
**Rejected** — would push V7 to ~27,800 B, blowing EIP-170. Even with aggressive optimization, ASK + M6.4 storage + logic ≥ 4 KB, with only 1,879 B headroom available.

### B. Unify into enhanced `SessionKeyValidator` *(this ADR)*
Chosen.

### C. Keep both, only inline ASK's scope-check call into base
**Rejected** — leaves two parallel session-key systems with incompatible sig formats; SDK / docs / users keep the dual-system tax for v0.18+; no data-migration savings since neither system has live data yet (so paying the integration tax twice).

### D. Drop M6.4, keep only ASK
**Rejected** — ASK was designed as ERC-7579 install module; standardizing on it would mean keeping the per-account install gas cost + the "only one validator per algId" complexity. M6.4's router-fallthrough pattern is cheaper and aligns with how all other algIds work in the codebase.

---

## 6. Consequences

**Positive**:
- One session-key system → simpler SDK, simpler docs, simpler audits going forward
- Deploys ~5.5 KB less bytecode
- Three contracts deleted (Composite, Hook, ASK) → smaller surface
- Hook slot freed (owners can install custom hooks if needed)
- M6.4 deploy-script registration bug fixed in the same PR
- v0.17.2 supersedes v0.17.1 cleanly (latter never deployed)

**Negative**:
- `SessionKeyValidator` grows from 5,615 B to ~7,500-8,000 B; still under EIP-170 with large margin
- V7 grows slightly (+300-500 B), bringing it to ~23,200 B — closer to EIP-170 limit but still ~1,400 B headroom
- `delegateSession` (sub-delegation) feature lost — to be re-evaluated for v0.18+
- All tests touching ASK or hook need rewrite/migration to the enhanced `SessionKeyValidator`

**Risks**:
- Test rewrite is the biggest single chunk of work; needs careful coverage
- Inline velocity check in `_enforceGuard` (state mutation) must be ERC-4337-validation-compliant (cannot mutate state during validation phase) — design `_enforceGuard` velocity mutation to happen during `execute()` only, OR move counter check to `SessionKeyValidator.validateSignature` (which runs in validation phase as part of the router fallthrough)
- Enhanced `SessionKeyValidator` is a NEW deployed contract — needs full unit + integration test coverage before any beta tag

---

## 6.5 Codex adversarial review response (2026-05-30, agent a717e9f65a2b9058a)

Codex returned **PLAN NEEDS REVISION** with 3 P0 (release-blocker), 4 P1 (same-release), 4 P2 (recommended) findings. Below: each finding acknowledged + plan revision.

### P0 — release blockers (must be in PR A)

**P0-1: velocity SSTORE must NEVER occur in validation phase (ERC-4337 / EIP-7562 mempool rule)**
- Evidence: `src/validators/AgentSessionKeyValidator.sol:239-250` (existing ASK does this — pre-existing bug masked by us never deploying through a real bundler that enforces 7562)
- Decision:
  - Enhanced `SessionKeyValidator.validateSignature(...)` (router fallthrough path) stays **view-only**. Velocity field is read for early-reject check only; no SSTORE.
  - Add `SessionKeyValidator.recordCallForVelocity(address account, address key) external` (state-mutating, only callable from the account).
  - `base._enforceGuard` calls `recordCallForVelocity` after scope check passes. `_enforceGuard` already runs in `execute` / `executeBatch` / `executeFromExecutor`, **never** in `validateUserOp`. ERC-4337-clean.
  - Accept the per-bundle race: 2 simultaneous in-flight UserOps may both pass validation, increment to N+2; documented as design trade-off (same as expiry checks).

**P0-2: executeBatch per-call array scope check**
- Evidence: `src/core/AAStarAirAccountBase.sol:983-1000` (batch already runs `_enforceGuard` per call), `src/core/TierGuardHook.sol:69-123` (hook only ran in single-execute path)
- Decision:
  - All array scope enforcement lives inside `SessionKeyValidator.checkSessionScope(account, key, dest, selector)` (view function).
  - `_enforceGuard` invokes `checkSessionScope` per-call (no special batch logic).
  - Single + batch paths uniformly covered. Hook deletion does not introduce regression — actually fixes M8.P2 batch-bypass note at L988-991.

**P0-3: EIP-170 — don't inline array loops in V7**
- Evidence: V7 currently 22,697 B / 1,879 B headroom; arrays + velocity + immutable getter inline est. exceeds margin
- Decision:
  - V7 **does NOT inline** `callTargets[]` or `selectorAllowlist[]` iteration. Iteration lives in `SessionKeyValidator.checkSessionScope`.
  - V7 contains only: immutable `sessionKeyValidator` getter (~50 B), 1 staticcall to `checkSessionScope` (~80 B), 1 call to `recordCallForVelocity` (~80 B) inside `_enforceGuard` ext. ≈ 200-250 B (not 300-500).
  - Must run `forge build --sizes` after every commit on this branch and gate against EIP-170; abort + redesign if margin drops below 500 B.
  - Add `test/Eip170Size.t.sol` assertion update if needed.

### P1 — same-release required

**P1-1: Clean up V7:195-209 ASK 66-byte recovery branch**
- After deleting ASK, the `if (algId == ALG_SESSION_KEY && userOp.signature.length >= 66)` branch in V7's nonce-key routing path becomes dead. Remove that block; nonce-key routing for ALG_SESSION_KEY no longer applies (session keys use base native dispatch + router only).

**P1-2: Deploy script register 0x08** (already in plan, confirmed by Codex)
- `script/DeployAirAccountV017.s.sol` adds `router.registerAlgorithm(0x08, d.sessionKeyValidator)` after the SessionKeyValidator deploy.

**P1-3: KMS / E2E / SDK doc breaking-change**
- Evidence: `docs/kms-agent-requirements.md:29-47` (hard-codes 66-byte format), `scripts/test-m7-e2e.ts:451-465` (constructs 66-byte sigs), `docs/sdk-abi-mapping.md:906-955, 992-1032, 1561-1581` (internally inconsistent already)
- Decision: v0.17.2 release is a **breaking change** for KMS / SDK consumers.
  - PR B: update all three docs to specify 106-byte (ECDSA session) / 149-byte (P256 session) formats with the `[0x08][account(20)][key(20)][sig]` layout.
  - Update `scripts/test-m7-e2e.ts` to construct the new format.
  - Open a coordinated issue on `aastar-sdk` repo + notify KMS team via Slack DM.

**P1-4 (REVISED — see also User feedback 2026-05-30 below): replace `grantSession` / `grantSessionDirect` outright, do NOT add parallel WithLimits functions**
- Original Codex concern: "silent extension of old function binds new fields to existing typed hashes — security risk."
- **Reality**: v0.17.2 is a fresh, never-deployed release. There are ZERO live `grantSession` typed-hash signatures on any chain. Codex's silent-extension concern is real *in principle* but **moot in our context** (nothing to break backward-compat with).
- Decision:
  - **Replace** `grantSession` / `grantSessionDirect` signatures to accept a single `Session calldata cfg` struct containing all fields (old: expiry/contractScope/selectorScope/revoked; new: velocityLimit/velocityWindow/callTargets[]/selectorAllowlist[]).
  - One new EIP-191 typed-hash domain `"GRANT_SESSION_V2"` (or equivalent), encoding the full struct.
  - Backward-equivalence: callers wanting "legacy behavior" pass `velocityLimit=0` and empty arrays — semantically identical to the old `grantSession`.
  - No parallel functions; SDK / docs have a single API surface.
  - Old `grantSession` / `grantSessionDirect` ABI-stable variants are NOT preserved — they had no live consumer.

### P2 — recommended for same release

**P2-1: Preserve ASK's hard limits** — Carry over `MAX_CALL_TARGETS = 20` + `MAX_SELECTORS = 30` constants to enhanced `SessionKeyValidator` (prevents gas-bomb on iteration). Enforce in `grantSessionWithLimits`.

**P2-2: factory + V7 constructor signatures** — V7 constructor adds `address _sessionKeyValidator` (stored as immutable). Factory passes it through. Existing factory `defaultValidatorModule`/`defaultHookModule` params + immutables deleted in same commit.

**P2-3: ADR explicit deferment of ERC-7715 / ERC-7710** — Stated here: enhanced `SessionKeyValidator` implements `IAAStarAlgorithm` (router fallthrough) and does NOT implement `IERC7579Validator` (nonce-key module). ERC-7715 (wallet_grantPermissions) and ERC-7710 (Delegation) standard alignment is **deferred to v0.18+** for re-design when there is a concrete consumer requirement.

**P2-4: WalletBeat doc downgrade** — `docs/walletbeat-assessment.md:235-255, 372-383` change "Full ERC-7579" → "ERC-7579 module surface (validator type 1 partial; executor type 2 supported; fallback type 3 used internally via diamond-lite; hook type 4 surface available but no default hooks installed)". Honest.

### Revised V7 / SessionKeyValidator interaction (after Codex P0 revisions)

```
ValidateUserOp phase (NO SSTORE allowed):
  base._validateSignature(sig) for ALG_SESSION_KEY:
    - cross-account check (sig[1:21] == address(this))           [existing]
    - store taggedSessionKey to transient                         [existing]
    - fall-through to validator.validateSignature(sig)            [existing]
      → router → SessionKeyValidator.validateSignature(sig)
        - dispatches 105/148 by length                            [existing]
        - ECDSA / P256 verify                                     [existing]
        - check expiry/revoked                                    [existing]
        - check velocity counter (READ only, would-exceed)        [NEW, view]
        - return 0/1 (no SSTORE)
        # NOTE: 66-byte ASK format dispatch DELETED

Execute / ExecuteBatch / ExecuteFromExecutor phase:
  base._enforceGuard(... taggedSessionKey ... dest, func):
    - existing scope check for static contractScope/selectorScope  [existing]
    - IF callTargets[] or selectorAllowlist[] non-empty:           [NEW]
        sessionKeyValidator.checkSessionScope(account, key, dest, selector)
        (staticcall — view, handles arrays + limits)
        reverts on violation
    - IF velocityLimit > 0:                                        [NEW]
        sessionKeyValidator.recordCallForVelocity(account, key)
        (call — SSTORE the counter, reverts if exceeded)
```

This split satisfies Codex P0-1 (no SSTORE in validate), P0-2 (per-call in batch via `_enforceGuard`), P0-3 (no array iteration in V7).

---

## 7. Execution plan summary (full plan in PR description)

1. **Pre-flight**: ADR committed (this file); Codex adversarial review of the plan.
2. **PR A — Architecture cleanup + security fixes**:
   - Delete: `AirAccountCompositeValidator.sol`, `TierGuardHook.sol`, `AgentSessionKeyValidator.sol`, V7's `validateCompositeSignature`, factory's `defaultValidatorModule`/`defaultHookModule` fields
   - Enhance: `SessionKeyValidator.sol` (velocity + arrays)
   - Modify: `base._enforceGuard` (multi-target scope + velocity check), `base._setCallDataKey` (AUDIT NOTE), `AgentRegistry` (factory whitelist), `ForceExitModule` (executeFromExecutor), `_validateWeightedSignature` (cursor check), V7 `accountId()` (version), V7 constructor (sessionKeyValidator immutable)
   - Fix: deploy script register M6.4 at 0x08
   - Migrate: all tests touching deleted modules to use enhanced `SessionKeyValidator`
3. **PR B — docs + version + magic-number cleanup**: independent, can land in parallel.
4. **v0.17.2 tag** after both PRs merge.

Detailed file:line plan accompanies the Codex challenge prompt.
