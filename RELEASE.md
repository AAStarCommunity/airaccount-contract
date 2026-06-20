# Release Process — AirAccount Smart Contracts

Standardized, repeatable release runbook. **Every release MUST complete every mandatory step.**
This document is the single source of truth for how a version ships. Update it when the process changes.

> Legend: ☑ mandatory · ◻ conditional (only when the trigger applies)

---

## 0. Pre-flight

- ☑ All feature/refactor PRs for the release are merged into the release branch.
- ☑ Working tree clean; on the release branch.
- ☑ `foundry` + `node` + `pnpm` installed; submodules initialized.

## 1. Version bump

- ☑ `AAStarAirAccountV7.ACCOUNT_VERSION` updated.
- ☑ `AAStarAirAccountFactoryV7.FACTORY_VERSION` updated (MUST match ACCOUNT_VERSION).
- ☑ Grep for stale version strings: `grep -rn "0\.<prev>\.0" src/ script/ README.md`.

## 2. Full test suite (incl. real-passkey E2E)

- ☑ `forge test` — default suite green (no `--ffi`; FFI-only suites self-skip).
- ☑ `forge test --ffi` — full suite incl. `test/P256WebAuthnRealSig.t.sol` (real secp256r1 via
  OZ `P256.verifySolidity` + real ES256 assertions from `test/webauthn/gen_p256_assertion.mjs`).
- ☑ `forge test --evm-version prague` — EIP-2537/7212-dependent paths.
- ☑ Record the totals (passed/failed/skipped) in the CHANGELOG entry.
- ☑ **No mocked cryptography may stand in for a security claim.** Any regression test asserting a
  security property MUST be shown to FAIL when the fix is reverted (see §3 adversarial rule).

## 3. Adversarial review — line-by-line Codex challenge (loop until SHIP)

- ☑ Run a holistic adversarial review of the full release diff (`git diff main...<branch>`).
- ☑ Fix every CRITICAL/HIGH/MEDIUM. Re-run review. Repeat until **SHIP** with zero
  CRITICAL/HIGH/MEDIUM. LOWs may be deferred only with an explicit, documented decision.
- ☑ **Anti-cheat rule:** fixes are real contract changes, never test-layer masking. For each
  security fix, prove the regression test catches the bug by temporarily reverting the fix and
  confirming the test FAILS (a positive control + negative test together is acceptable).
- ☑ Record rounds + findings + verdict in the CHANGELOG.
- ◻ Independent second-opinion review (e.g. clestons) where required by branch protection.

## 4. ABI regeneration (CI-gated)

- ☑ `node scripts/build-full-abi.mjs` → commit `abi/AAStarAirAccountV7.full.json`
  (merged diamond-lite fallback surface; verify "no selector collisions").
- ☑ `node scripts/build-full-abi.mjs --check` passes.
- ☑ **Run a full `forge build` first** — `out/` must contain the whole tree or the ABI/docs come out partial.

## 5. ABI docs regeneration (CI-gated)

- ☑ `pnpm gen:abi-docs` → commit `docs/abi/reference.md` + `docs/abi/selectors.md`.
- ☑ `pnpm gen:abi-docs:check` passes (must match CI's full-build state — see §4 note).

## 6. CHANGELOG finalize

- ☑ Collapse the `[Unreleased]` hardening sections into one `[vX.Y.Z] - <date>` entry.
- ☑ List breaking changes explicitly (ABI surface, event topic0, signing payloads).
- ☑ Note accepted/documented design tradeoffs and known limitations.

## 7. Transaction-record archival

- ☑ Archive the release validation tx records (gas + call traces) under
  `docs/tx-archive/v<version>.md` — at minimum the real-passkey E2E flows and any on-chain E2E run.
- ◻ For on-chain (testnet/mainnet) E2E: archive tx hashes + explorer links.

## 8. README refresh

- ☑ Update `## Status:` to the new version + one-paragraph summary of what changed.
- ☑ Update the Contracts / Deployed Contracts sections if addresses changed (§9).
- ☑ Update any "vX" section headers that now lag.

## 9. Deployment + address update

- ◻ If this release ships new bytecode to a network: deploy via the documented script, then
  create `docs/DEPLOYMENT-v<version>.md` and update **every** address reference (README, SDK
  config, `.env` templates, `src/config/*Addresses.sol` if applicable).
- ◻ If code-only (no redeploy): state "no redeploy; addresses unchanged from v<prev>" in the release notes.

## 10. Merge to main

- ☑ CI fully green on the release branch.
- ☑ Obtain required approval(s). NOTE: repo ruleset requires a re-approval from someone **other
  than the last pusher** — any commit (incl. ABI/doc regen) staleness-invalidates a prior approval,
  so push ALL release commits BEFORE requesting the final approval, then merge once.
- ☑ Merge (merge commit, to preserve the release history). Confirm `gh pr list --state open` is empty.

## 11. GitHub standard release

- ☑ Tag `v<version>` on the merge commit.
- ☑ `gh release create v<version>` with notes derived from the CHANGELOG entry (highlights,
  breaking changes, test totals, Codex verdict, known limitations).
- ☑ Attach/link the regenerated ABI (`abi/AAStarAirAccountV7.full.json`).

## 12. SDK issue (MANDATORY)

- ☑ File an issue on `AAStarCommunity/aastar-sdk` documenting every breaking change for integrators
  (ABI surface moves, event topic0 changes, signing-payload changes, new APIs). Title:
  `chore(contracts): v<version> breaking changes for SDK`. Link the release + CHANGELOG.
- ☑ This step is **non-optional** — a contract release is not "done" until the SDK is notified.

---

## v0.20.0 execution log

| Step | Status | Notes |
|---|---|---|
| 1 Version bump | ☑ | ACCOUNT_VERSION 0.20.0; FACTORY_VERSION 0.20.0 |
| 2 Tests | ☑ | 844 pass `--ffi` (4 real-passkey E2E); prague green |
| 3 Codex challenge | ☑ | P-256: 5 rounds; refactor: APPROVED; release holistic: R1(2M+2L)→R2(1M+1L)→R3(1L)→final(1H+1M)→**SHIP**. clestons re-review APPROVED. |
| 4 ABI | ☑ | 67 functions, 16 fallback-routed, no collisions |
| 5 ABI docs | ☑ | 33 contracts, 372 functions |
| 6 CHANGELOG | ☑ | finalized below the hardening sections |
| 7 Tx archive | ☑ | `docs/tx-archive/v0.20.0.md` (real-passkey E2E gas) |
| 8 README | ☑ | Status → v0.20.0 |
| 10 Merge to main (code) | ☑ | code merged via #120 (merge commit d07eea8) |
| 9 Deploy/addresses | ☑ | Sepolia full stack deployed 2026-06-20 (blocks 11098656–11098665) via `scripts/deploy-v0.20.ts`. `docs/DEPLOYMENT-v0.20.0.md` written; README + tx-archive updated. Sourcify verification submitted (impl/extension/factory). Etherscan key invalid — re-verify when refreshed. Deploy PR pending merge. |
| 11 GitHub release | ⏳ | after the deploy PR merges — tag `v0.20.0` + notes listing deployed addresses |
| 12 SDK issue | ⏳ | after §11 — references release + deployed addresses |
