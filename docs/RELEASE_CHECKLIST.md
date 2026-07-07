# Release Checklist (AirAccount contract)

The human pre-release gate. Run top-to-bottom **before** tagging + publishing. Auto-notes
categorization lives in `.github/release.yml`; this file is the correctness gate.

> Convention: tag = `vMAJOR.MINOR.PATCH[-beta.N]` (e.g. `v0.18.0-beta.2`). Sepolia betas are
> GitHub **pre-releases**; only a GA tag gets the **Latest** badge.

## 1. Code & version
- [ ] **On-chain version constants MATCH the exact release tag — including the prerelease suffix.**
      Bump `ACCOUNT_VERSION` + `FACTORY_VERSION` + `accountId()` (and any module VERSION) to e.g.
      `"0.18.0-beta.2"` as the **first** step of any (re)deploy. ⚠️ See Known Oversight #1.
- [ ] `forge build` clean; EIP-170 runtime size checked (`forge inspect <C> deployedBytecode`),
      headroom logged in the release notes.
- [ ] Full test suite green on **both** EVM targets: `forge test` (cancun) **and**
      `forge test --evm-version prague` (EIP-2537 crypto). Record both counts.

## 2. Deploy (Sepolia / mainnet)
- [ ] Deploy via `scripts/deploy-v*.ts` (TS+viem — `forge script` fails on macOS).
- [ ] Verify the deployed contracts self-report the new version on-chain (read `ACCOUNT_VERSION` /
      `FACTORY_VERSION`) — catches a forgotten version bump BEFORE publishing.
- [ ] Run on-chain E2E; record the headline tx hash(es).

## 3. Docs & config (the parts most often missed)
- [ ] **Update `CHANGELOG.md`** with the new entry (newest-first) BEFORE tagging. ⚠️ Known Oversight #2.
- [ ] **Regenerate ABI docs**: `pnpm gen:abi-docs`; commit `abi/AAStarAirAccountV7.full.json` +
      `docs/abi/` so the SDK consumes the right surface. ⚠️ Known Oversight #4.
- [ ] **Archive superseded addresses** in `.env.sepolia` (e.g. `AIRACCOUNT_V0XX_BETAn_*`); promote
      the new set to the canonical `AIRACCOUNT_V0XX_*` keys. ⚠️ Known Oversight #5.
- [ ] Update README addresses/version if it pins a specific deployment.
- [ ] **Do NOT commit deploy/e2e logs** (`deploy-*.log`, `e2e-*.log`) — they belong in `.gitignore`. ⚠️ Known Oversight #6.

## 4. GitHub release
- [ ] Tag matches the version constants exactly.
- [ ] Release body = CHANGELOG entry (what-changed + full address table + test counts + E2E tx).
- [ ] **Set the prerelease flag correctly**: betas = pre-release; GA = `prerelease=false` + Latest. ⚠️ Known Oversight #3.
- [ ] Cross-link the SDK PR if the release changes ABI / wire format.
- [ ] **Version numbers in outward text carry the product name** (⚠️ Known Oversight #8): CHANGELOG entry,
      release title/notes, PR titles, cross-repo (Cooperation-Center / issue) notes → write
      `airaccount-contract vX.Y.Z`, never a bare `vX.Y.Z`. The git tag itself stays clean semver
      (`vX.Y.Z` — no product name, don't break tooling). When reporting a sync, name both sides
      (e.g. "@aastar/sdk 0.37.0 synced to airaccount-contract v0.27.0").

## 5. E2E on-chain + Codex challenge (MANDATORY GATE)
A release does NOT meet the bar until ALL of the following pass (established 2026-06-16, owner-mandated):
- [ ] **Run the full E2E scenario set on-chain** against the deployed contracts — the 36-scenario plan in
      `docs/e2e/E2E_PLAN_v0.18.0-beta.2.md` (account variants, all algId tiers incl. **DVT P256+BLS combined sig**,
      session, recovery, modules, ForceExit, governance, + negative/revert scenarios). Phases:
      `scripts/e2e-v0172/08..16` (repointed to the release deployment) + `scripts/test-tiered-e2e.ts` (DVT C4/C5).
- [ ] **Record every on-chain tx** with its scenario / feature / params into `docs/e2e/E2E_RESULTS_<ver>.md`
      (the harness `recordResult` auto-appends tx + etherscan link; tiered DVT txs added manually).
- [ ] **Codex challenge** the recorded txs (`/codex:rescue --fresh`): per-tx verify REAL via Sepolia RPC
      (`eth_getTransactionReceipt` status, `to`, gas) AND feature-met (post-state), negatives correctly reverted.
- [ ] **Bar met only when Codex returns REAL + FEATURE-MET for every tx.** Paste the verdict into the results doc.
- [ ] Gas: harness must use `baseFee*2 + 2gwei` fees (⚠️ Known Oversight #7) or txs drop as underpriced.

---

## Known Oversights — DO NOT repeat (recorded from past releases)

These are real misses that shipped. Each release MUST re-check them.

1. **Version constant didn't track the precise release.**
   - v0.18 contracts self-reported `"0.17.2"` (fixed late in beta.2 via #104/#111).
   - `ACCOUNT_VERSION = FACTORY_VERSION = "0.18.0"` does **NOT** include the `-beta.N` suffix → on-chain
     you **cannot distinguish v0.18.0-beta.1 from beta.2** (different deployments, same self-reported
     string). **Fix next release:** version constant = the exact tag incl. prerelease suffix
     (`"0.18.0-beta.2"`), bumped as the first deploy step. *(Recorded 2026-06-15 per owner.)*
2. **CHANGELOG.md went stale** — v0.18.0-beta.1 and beta.2 were missing from it until this PR
   (it stopped at v0.17.2-beta.4). Update CHANGELOG **before** tagging, every time.
3. **Release prerelease/Latest flag wrong** — a release once showed as a bare tag (no Latest badge);
   had to flip `prerelease`/Latest after the fact. Set it correctly at publish.
4. **ABI docs not regenerated** with the deployment — SDK can drift. `pnpm gen:abi-docs` every release.
5. **Superseded addresses not archived** in `.env.sepolia` — keep `_BETAn_*` history + a clean canonical set.
6. **Deploy/E2E logs committed** — keep `deploy-*.log` / `e2e-*.log` out of git.
7. **Sepolia txs dropped as underpriced** (2026-06-16) — viem's default `baseFeeMultiplier` (1.2×) under-provisions
   on volatile Sepolia → createAccount txs silently dropped → cascading confirmation-timeouts + nonce snarls
8. **Bare version numbers in outward text** (2026-07-05, Cooperation-Center CC-14) — reporting a naked `0.37` /
   `v0.27` is ambiguous across independent version tracks (SDK / contract / DVT / SuperPaymaster / KMS all number
   separately; SDK 0.37.x ≠ airaccount-contract v0.27.0). **Fix:** outward text (CHANGELOG / release notes / PR
   titles / cross-repo comments) always writes `airaccount-contract vX.Y.Z`; the tag/version constants stay clean
   semver. Ecosystem-wide convention — all repos adopted.
   (worsened by killing runs mid-flight). FIX: wallet chain `fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2gwei }`
   (= proven deploy-script `baseFee*2 + tip`). UserOps: use `pimlico_getUserOperationGasPrice`. NEVER re-send on
   timeout (poll the receipt). Also: M3-era scripts drift vs current ABI — `TokenConfig` packed to uint128 (#82, the
   tuple-type change flips the function selector) and BLS sig dropped the trailing messagePoint (#45); update both.

> When a new oversight is found, append it here so the next release can't repeat it.
