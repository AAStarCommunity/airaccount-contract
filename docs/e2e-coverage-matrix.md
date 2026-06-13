# E2E Coverage Matrix — WS-F (#90)

**Scope**: end-to-end (real on-chain) coverage for AirAccount, split into
(1) existing features verifiable NOW against the deployed **beta.4** contracts, and
(2) v0.18 features (WS-A/B/C/G, merged to `main`) that are **scaffolded but pending the v0.18 deploy**.

- **Live deployment**: v0.17.2-**beta.4** on Sepolia. Factory `0x3a9127a5f0b4ca734d54629d0c3ad9f52739c071`
  (env keys `AIRACCOUNT_V0172_BETA_*`). Confirmed live: `pnpm tsx scripts/e2e-v0172/01-smoke.ts` → 13/13.
- **v0.18 NOT deployed**: verified — the deployed beta.4 SessionKeyValidator has **no** `sessionKeyCount(...)`
  (reverts), i.e. the WS-C surface is absent on-chain. v0.18 E2E SKIPs until `AIRACCOUNT_V018_*` are set.
- Test harness: TypeScript + viem, `scripts/e2e-v0172/` (RPC from `.env.sepolia` `SEPOLIA_RPC_URL`).
- Capability → function → script map: [`docs/abi/capabilities.md`](abi/capabilities.md).
- Prior period report: [`docs/e2e-coverage-v0.17.2-beta.3.md`](e2e-coverage-v0.17.2-beta.3.md).

---

## Part 1 — Existing features (beta.4, runnable now)

Legend: ✅ covered & runnable · 🟡 partial / documented gap · ⏳ impractical on mainnet-Sepolia (multi-day timelock)

| # | Feature | E2E script(s) | Status | Notes |
|---|---------|---------------|--------|-------|
| 1 | Contract wiring / smoke | `01-smoke.ts` | ✅ | 13/13 **re-run vs beta.4 (this WS)** |
| 2 | Adversarial-fix regression | `02-security-fixes.ts` | ✅ | 8/8 **re-run vs beta.4 (this WS)**, read-only |
| 3 | View surface (7 contracts) | `03-views.ts` | ✅ | 27/27 **re-run vs beta.4 (this WS)**, read-only |
| 4 | Admin / privileged ops | `04-admin.ts` | ✅ | incl. `proposeAlgorithm` callable (ran beta.3) |
| 5 | Negative paths / custom errors | `06-negative.ts` | ✅ | 19/19 **re-run vs beta.4 (this WS)**, read-only |
| 6 | beta.3 feature constants/errors | `07-beta3-features.ts` | ✅ | VERSION + factory errors (ran beta.3) |
| 7 | Account creation (4 types) | `08-multi-account-types.ts` | ✅ | plain / agent / counterfactual (ran beta.3) |
| 8 | execute / executeBatch / deposit | `09-execute-transactions.ts` | ✅ | incl. dailyLimit guard revert (ran beta.3) |
| 9 | Session key grant/revoke/views | `10-session-key-txns.ts` | ✅ | ECDSA + P256 grant/revoke (ran beta.3) |
| 10 | Guardian recovery propose/approve/cancel | `11-guardian-recovery-module.ts` | ✅ | cancel = 2/3 guardians (ran beta.3) |
| 11 | ERC-7579 module install/uninstall | `11-guardian-recovery-module.ts` GR.9–12 | ✅ | ForceExitModule install/uninstall (ran beta.3) |
| 12 | ERC-4337 UserOp via bundler | `12-userop-bundler.ts` | ✅ | Pimlico self-paying + gasless, guard-enabled (beta.4 headline; on-chain proof `0x48934dee…`) |
| 13 | EIP-7702 delegate | `test-7702-delegate-e2e.ts`, `test-7702-stealth-e2e.ts` | 🟡 | delegate install + execute covered; native **type-4 tx** path is the #90 gap |
| 14 | Session-key UserOp (signed) | `test-session-key-userop-e2e.ts` | 🟡 | session-signed UserOp construction exists; velocity/expiry-trigger not asserted end-to-end |

### #90's four named gaps — disposition

| #90 gap | Disposition |
|---------|-------------|
| **Social recovery full flow** (propose → 72h → `executeRecovery`) | propose/approve/`cancelRecovery`(2/3) ✅ in `11`. `executeRecovery` needs a real **72h** wait ⏳ — impractical on Sepolia; covered by 42 unit tests. `clearStaleRecovery` boundary remains an un-scripted gap (runnable; small follow-up). |
| **Session-key UserOp** (velocity, expiry, P256 session) | grant/revoke ✅ (`10`); session-signed UserOp scaffold exists (`test-session-key-userop-e2e.ts`). Velocity-trigger + expiry-rejection via bundler is covered going forward by **v0.18 phase 15** (WS-C) — see Part 2. |
| **EIP-7702 type-4 tx** | delegate behaviour covered (`test-7702-delegate-e2e.ts`); native type-4 signing path 🟡. |
| **`proposeAlgorithm` + 7d timelock** | `proposeAlgorithm` callable ✅ (`04` AD-ROUTER.1); `executeProposal` needs **7 days** ⏳ — impractical; covered by `AAStarValidatorTest`. |

### Fresh beta.4 regression run (this WS-F)

Read-only phases re-run against the live beta.4 deployment on 2026-06-13:

| Phase | Result |
|-------|--------|
| `01-smoke` | **13/13 PASS** |
| `02-security-fixes` | **8/8 PASS** |
| `03-views` | **27/27 PASS** |
| `06-negative` | **19/19 PASS** |
| **Total (read-only)** | **67/67 PASS** |

State-changing phases (`04,05,07–12`) were **not re-billed** this round — they passed against beta.3 and the
beta.4 execution path has on-chain proof (Pimlico tx `0x48934dee…`, see project memory / beta.4 capability map).
All signers are funded (Jason 9.4 ETH, Anni 1.14 ETH, Bob 0.20 ETH), so they are re-runnable on demand:
`pnpm tsx scripts/e2e-v0172/09-execute-transactions.ts`, etc.

---

## Part 2 — v0.18 features (WS-A/B/C/G) — scaffolded, PENDING DEPLOY

New scripts. Phases **13–15** call `requireV018()` and **SKIP (exit 0)** with a PENDING banner until the
v0.18 addresses are added to `.env.sepolia`. **Phase 16 is deliberately different**: it runs the
precompile-malleability proof `WSG.P1`/`WSG.P2` **unconditionally** (these need no v0.18 deploy), then
skips only the account-bound `WSG.1–4`; if `WSG.P1`/`WSG.P2` fail, the script exits non-zero rather than
masking it with a clean skip-exit. Encodings were verified against the merged v0.18 ABIs in `out/`.

| WS | Issue(s) | Feature | New script | What it asserts | Run readiness |
|----|----------|---------|------------|------------------|---------------|
| A | #75, #84 | Module-management **nonce replay protection** | `13-ws-a-module-nonce.ts` | `moduleManagementNonce()` increments on install **and** uninstall; after uninstall (confirmed via `isModuleInstalled==false`) a replayed nonce-0 install sig **reverts the exact `NotGuardian()` selector**; a fresh-nonce sig succeeds | after v0.18 deploy |
| B | #70, #77 | ForceExit **TOCTOU re-verify** | `14-ws-b-forceexit-toctou.ts` | module installed with a **valid L2 type** (so a passing guardian check would NOT hit `UnsupportedL2Type`); after 2 approvals, removing an approver guardian makes `executeForceExit` **revert the exact `ApproverNoLongerGuardian()` selector** | after v0.18 deploy |
| C | #83, #57 | Session-key **cap** + **sliding velocity** | `15-ws-c-sessionkey-cap-velocity.ts` | `sessionKeyCount` increments on grant / decrements on revoke (always run); cap enforcement (51st grant → **exact `TooManySessionKeys()` selector**) only runs under `RUN_FULL_CAP_TEST=1`, **recorded SKIP otherwise (never a trivial PASS)**. Velocity/expiry-trigger documented as bundler-path TODO | after v0.18 deploy |
| G | #78 | P256 **low-S** canonicality guard | `16-ws-g-p256-low-s.ts` | **WSG.P1/P2 run NOW on Sepolia**: prove the raw `0x100` precompile accepts BOTH `(r,s)` and `(r, n-s)` → so the high-S rejection is attributable solely to the contract guard. Then (post-deploy) `eth_call validateUserOp`: low-S → `0`, malleable high-S → `1` | P1/P2 **runnable now**; WSG.1–4 after v0.18 deploy |

**Assertion discipline**: every negative case in phases 13–16 asserts the **exact revert selector** via the
shared `expectRawCallRevert(..., "Selector()")` helper (or an exact `validationData` value for WS-G) — no test
counts an arbitrary revert/exception as PASS.

### Enabling the v0.18 E2E after deploy

Add to `.env.sepolia`:

```
AIRACCOUNT_V018_FACTORY=0x...
AIRACCOUNT_V018_IMPL=0x...
AIRACCOUNT_V018_SESSION_KEY_VALIDATOR=0x...
AIRACCOUNT_V018_FORCE_EXIT_MODULE=0x...
AIRACCOUNT_V018_VALIDATOR_ROUTER=0x...
```

Then:

```
pnpm tsx scripts/e2e-v0172/13-ws-a-module-nonce.ts
pnpm tsx scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts
pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts   # RUN_FULL_CAP_TEST=1 for the 50-grant cap loop
pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts
```

Pre-deploy verification already performed (no deploy required):
- v0.18 ABIs present in `out/`: `moduleManagementNonce`, `sessionKeyCount`, `setP256Key`, `validateUserOp`,
  `ForceExitModule.{proposeForceExit,approveForceExit,executeForceExit,getPendingExit}` — all **OK**.
- Sepolia secp256r1 precompile (`0x100`) is **active** (RIP-7212 vector → valid).
- **WS-G precompile-malleability proof is encoded as in-script assertions `WSG.P1`/`WSG.P2`**, verified via
  **read-only `eth_call` staticcalls to Sepolia precompile `0x100`** (these are NOT state-changing, so there
  is no tx hash) — both low-S (s ≤ N/2) and high-S (s > N/2) **verify at the precompile**, so the high-S
  rejection in `WSG.4` is attributable solely to the contract's low-S guard (#78), not the precompile.
  Reproducible now by running `pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts` (the `…-precompile` phase
  reports `2 passed, 0 failed`).

---

## Honest status summary

- **Ran this WS (real, verified)**: 67/67 read-only beta.4 regression tests (phases 01/02/03/06).
- **Pending funds / on-demand**: state-changing beta.4 phases (04,05,07–12) — passed in beta.3, re-runnable.
- **Pending v0.18 deploy (scaffolded + ABI-verified, cannot run yet)**: phases 13–16 (WS-A/B/C/G).
- **Impractical on Sepolia (timelock)**: social-recovery `executeRecovery` (72h), `proposeAlgorithm` execute (7d) — unit-test covered.
- **Small open follow-ups (runnable, not yet scripted)**: `clearStaleRecovery` boundary; native EIP-7702 type-4 signing path.
