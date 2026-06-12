# Changelog

All notable changes to AirAccount contract will be documented in this file.

## Product Overview

AirAccount is a non-upgradable ERC-4337 smart wallet that makes crypto transactions as simple as mobile payments. Users authenticate with a passkey (fingerprint/face), and the wallet automatically applies the right level of security based on transaction value — small payments need just one tap, while large transfers require additional co-signatures from DVT nodes and trusted guardians. Gas fees can be paid in aPNTs tokens instead of ETH, enabling true zero-ETH-cost user experience. If the user loses their key, 2-of-3 guardians can recover the account through a timelocked social recovery process. All security rules (spending limits, algorithm whitelists) are enforced by an immutable guard that can only be tightened, never loosened.

---

## [v0.17.2-beta.3] - 2026-06-12 (AlgTierLib refactor + quick-wins: version constants, custom errors, ForceExit hardening)

Delta release on top of v0.17.2-beta.2. **Code quality & observability release** — no behavioral changes to existing accounts. 4 contracts redeployed with version constants; existing accounts unaffected.

### New: Version constants (on-chain SDK version detection)

All main contracts now expose a `string public constant` version string, eliminating the need for off-chain version tracking:

| Contract | Constant | Value |
|---|---|---|
| `AAStarAirAccountV7` | `ACCOUNT_VERSION` | `"0.17.2"` |
| `AAStarAirAccountFactoryV7` | `FACTORY_VERSION` | `"0.17.2"` |
| `ForceExitModule` | `MODULE_VERSION` | `"0.17.2"` |
| `SessionKeyValidator` | `MODULE_VERSION` | `"0.17.2"` |

**SDK impact**: `abi/AAStarAirAccountV7.full.json` updated to 64 functions (+`ACCOUNT_VERSION` getter). SDK must update ABI. See [SDK issue](#) for tracking.

### Refactor: AlgTierLib — single source of truth for algId→tier mapping

Extracted `_algTier()` logic into `src/utils/AlgTierLib.sol` (internal library, compile-time inlined — zero gas overhead). Both `AAStarAirAccountBase` and `AAStarGlobalGuard` delegate to it. Previously maintained independently with a "must stay in sync" comment.

- **No behavioral change**: tier mapping is identical.
- **Maintenance benefit**: adding a new algId requires editing one file only.

### Fix: Factory — custom errors replace `require(string)`

All 15+ `require(condition, "string")` in `AAStarAirAccountFactoryV7` constructor, `createAccountWithDefaults`, and `createAgentAccount` replaced with typed custom errors. Same in `AAStarGlobalGuard` constructor.

**SDK impact**: if SDK catches factory errors by string message (e.g. `"Guardians required"`), switch to selector-based matching. New error names: `GuardiansRequired`, `GuardiansMustBeDistinct`, `DailyLimitRequired`, `AgentKeyRequired`, `Guardian2Required`, `CallerCannotBeGuardian2`, `AgentKeyCannotBeGuardian2`, `GuardianSigExpired`, `DeadlineTooFarInFuture`, `HumanOwnerCannotBeCommunityGuardian`, `Guardian2CannotBeCommunityGuardian`, `AgentKeyCannotBeCommunityGuardian`, `TokenConfigLengthMismatch`, `DefaultTokenAddressZero`, `DuplicateDefaultToken`, `InvalidDefaultTokenConfig`.

### Fix: ForceExitModule — incompatible account detection at install time

`onInstall` now verifies `guardians(0)` exists AND returns a non-zero address, failing loudly with `IncompatibleAccount` instead of creating a zombie module (installed but unable to accumulate approvals).

- **New error**: `error IncompatibleAccount();`
- Prevents a confusing UX state where the module appears installed but `approveForceExit` always reverts.

### Gas: Assembly Hamming weight (popcount)

`_popcount()` in `AAStarAirAccountBase` and `_countBits()` in `ForceExitModule` replaced with parallel bit-manipulation (standard Hamming weight algorithm). ~5-8x fewer opcodes for 3-guardian bitmaps. Semantically identical.

### isValidSignature NatSpec clarification

Improved `isValidSignature` NatSpec to explicitly document hash-prefix behavior: does NOT apply EIP-191 prefix; DeFi protocols (Permit2, OpenSea) pass struct hash directly; personal_sign callers must pre-prefix. Matches Gnosis Safe behavior. No code change.

### Tests: 5 new paths added (PR #73)

| Test | What it covers |
|---|---|
| `test_executeFromExecutor_reentrancy_reverts` | Proper re-entrant executor mock (ReentrantExecutor) confirms tstore nonReentrant guard blocks inner call |
| `test_installModule_zeroGuardianAccount_reverts` | Direct `initialize` with all-zero guardians → `NotGuardian` on installModule |
| `test_bundle_identicalCallData_secondValidateOverwritesFirst` | Documents known #52 limitation: two UserOps with identical callData share tslot; second validate overwrites first |
| `test_modifyTierLimitsWithGuardians_expiredDeadline_reverts` | Guardian sig with past deadline → `TierLimitSigExpired` |
| `test_modifyTierLimitsWithGuardians_replaySameNonce_reverts` | After first call, replaying nonce=0 sigs → `NotGuardian` (nonce increments, old sigs recover wrong address) |
| `test_ACCOUNT_VERSION_constant` | `account.ACCOUNT_VERSION() == "0.17.2"` |
| `test_onInstall_incompatibleAccount_reverts` | `ForceExitModule.onInstall` by a bare contract without `guardians()` → `IncompatibleAccount` |
| `test_onInstall_zeroGuardian_reverts` | Account with `guardians(0) == address(0)` → `IncompatibleAccount` |

### Sepolia deployment

> **Note**: Addresses TBD — fill in after redeployment. See `docs/DEPLOYMENT-v0.17.2-beta.3.md`.

| Contract | Address | vs beta.2 |
|---|---|---|
| **AAStarAirAccountV7 implementation (NEW)** | `TBD` | redeployed — ACCOUNT_VERSION |
| **AAStarAirAccountFactoryV7 (NEW)** | `TBD` | redeployed — custom errors + FACTORY_VERSION |
| **ForceExitModule (NEW)** | `TBD` | redeployed — IncompatibleAccount + MODULE_VERSION |
| **SessionKeyValidator (NEW)** | `TBD` | redeployed — MODULE_VERSION |
| Other 7 contracts | unchanged from beta.2 | identical bytecode, identical addresses |

### Tests

- forge test: **681/0/0** (29 suites, 7 new tests across PR #73 + PR #85)
- on-chain E2E: pending re-run against beta.3 addresses

---

## [v0.17.2-beta.2] - 2026-06-02 (ForceExit LOW-3 stale-guardian fix + Sepolia E2E + CI cleanup)

Delta release on top of v0.17.2-beta.1. **One Solidity source change**: `ForceExitModule.sol` — LOW-3 partial fix (stale-guardian check). One contract redeployed; other 10 keep their addresses.

### Security fix — Codex round 5 LOW-3 (partial, accepted scope)

`approveForceExit` now verifies the recovered signer is in **both** the proposal's guardian snapshot AND the account's **current** guardian set. A guardian rotated out via `removeGuardian` + `addGuardian` between propose and approve will revert `SignerNoLongerGuardian` even though their signature still matches the snapshot.

- **New error**: `error SignerNoLongerGuardian();`
- Closes Codex round 5 LOW-3 scenario 2 (of 4). Scenarios 1 / 3 / 4 (stale target / stale intent / forgotten pre-arm + lost key) are accepted residual risk; rationale + v0.18 redesign tracked in [#66](https://github.com/AAStarCommunity/airaccount-contract/issues/66).
- **Design stance evolved**: KI-10 (earlier round) previously concluded the snapshot mechanism is "Resolved" because guardian rotation CAN NOT invalidate approvals (continuity wins). beta.2 reverses this — rotation SHOULD invalidate approvals (freshness wins). See `docs/forceexit-design-notes.md` §5.

### Sepolia deployment

| Contract | Address | vs beta.1 |
|---|---|---|
| **ForceExitModule (NEW)** | `0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9` | redeployed ✅ Etherscan verified |
| ~~ForceExitModule (deprecated)~~ | ~~`0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9`~~ | beta.1 version, still on-chain but DEPRECATED |
| Other 10 contracts | unchanged from beta.1 | identical bytecode, identical addresses |

**Migration**: zero. ForceExitModule is per-account ERC-7579 install (moduleTypeId=2), not factory-default. No production AirAccount on beta.1 has installed it.

### Also in this release

- **6-phase on-chain E2E suite** (`scripts/e2e-v0172/`) — 79/79 PASS on Sepolia, 100% non-deferred ABI coverage
- **Etherscan verify workflow fixed** — `auto_detect_remappings = false` + explicit `account-abstraction/` remapping; all 11 contracts now verified
- **CI workflow optimization** — removed redundant `forge build` from ABI verify step (~15 min saved/run; previously hung)
- **Documentation**: `docs/DEPLOYMENT-v0.17.2-beta.2.md`, `docs/forceexit-design-notes.md`, `docs/abi-coverage-v0.17.2-beta.1.md`, `docs/e2e-results-v0.17.2-beta.1.md`
- **GitHub issues opened**: [#66 ForceExit long-term tracking](https://github.com/AAStarCommunity/airaccount-contract/issues/66), [#67 v0.18 roadmap](https://github.com/AAStarCommunity/airaccount-contract/issues/67)
- **PR #68 review follow-ups** (David, 2026-06-02): MEDIUM-1 TOCTOU-at-execute documented as accepted residual; LOW-1 KI-10 wording revised to reflect superseded design; LOW-3 verify script address updated; CHANGELOG (this entry) added.

### Tests

- forge test: **674/0/0** (29 suites, 3 new stale-guardian tests)
- on-chain E2E (Sepolia): **79/79 PASS**

### Known residual (documented, deferred)

- **MEDIUM-1 TOCTOU at execute** (David PR #68 review): `executeForceExit` checks bitmap ≥ 2 but does NOT re-verify approving guardians are still current. Bob approves while still valid → rotated out → bit stays set → 2-of-3 still reached. **No production accounts installed beta.1 ForceExitModule, so window not exploitable now.** Tracked in [#70](https://github.com/AAStarCommunity/airaccount-contract/issues/70) — v0.18 redesign will re-check at execute time (max 3 staticcalls).
- **NIT-1** (David): no `VERSION` constant on contracts; integrations cannot programmatically distinguish ForceExitModule beta.1 vs beta.2 from chain. Tracked in [#71](https://github.com/AAStarCommunity/airaccount-contract/issues/71) — defer to v0.18.
- LOW-3 scenarios 1/3/4 — see [#66](https://github.com/AAStarCommunity/airaccount-contract/issues/66).
- KI-13 ForceExit Tier-1 daily-limit constraint — folded into v0.18 Emergency Asset Sweep redesign.
- KI-14 parsers — currently mitigated by not-deploying.
- KI-15 EIP-7702 delegate DeFi parser — tied to 7702 GTM decision.

---

## [v0.17.2-beta.1] - 2026-05-31 (Session-Key Unification + Codex 4-Round Adversarial Review + David PR #61 Review)

### Highlights
- **Session-key system unified**: deleted `AgentSessionKeyValidator`, `AirAccountCompositeValidator`, `TierGuardHook` (~7.8 KB combined external bytecode). All session-key features (velocity rate limit, `callTargets[]`, `selectorAllowlist[]`, classic single contractScope/selectorScope) now live in a single enhanced `SessionKeyValidator` registered in the validator router at algId `0x08`.
- All 2026-05-30 Codex pre-release findings addressed (H-1 / H-2 / M-1 / M-2 / M-3 / L-1 / L-2 / L-3) — see ADR `docs/2026-05-30-adr-session-key-unification.md` for the architecture rationale + Codex adversarial review responses (§6.5).
- Two pre-existing bugs fixed along the way:
  1. v0.17.x deploy script never registered `SessionKeyValidator` at algId 0x08 → session keys silently unusable on a fresh deploy.
  2. M6.4 P256 session storage used full 256-bit `keccak256(x||y)` while `base._enforceGuard` looked up the 248-bit truncated form → P256 scope check was silently bypassed. Storage now uses `_p256StorageKey` everywhere.

### Architecture changes
- New `Session` struct in `SessionKeyValidator`: `{expiry, contractScope, selectorScope, revoked, velocityLimit, velocityWindow, callTargets[], selectorAllowlist[]}` — covers both the simple DApp/M6.4-style session AND the richer agent-grade controls.
- New entry points on `SessionKeyValidator`:
  - `checkSessionScope(account, keyOrHash, sessionType, dest, selector)` — view; reverts with specific errors (`CallTargetForbidden`, `SelectorForbidden`, `SessionExpired`, etc.) on violation.
  - `recordCallForVelocity(account, keyOrHash, sessionType)` — non-view; mutates the velocity counter. `msg.sender == account` gate prevents cross-account griefing.
- `base._enforceGuard` now per-call staticcalls `checkSessionScope` + calls `recordCallForVelocity` — single-execute and executeBatch paths uniformly covered.
- New EIP-191 typed-hash domains `GRANT_SESSION_V2` / `GRANT_P256_SESSION_V2` include all new fields (velocity + array hashes); replaces the v0.16 typed hash (no live signatures existed).
- `grantSession` / `grantSessionDirect` / `grantP256Session` / `grantP256SessionDirect` now take a `Session calldata cfg` struct (single API surface).

### Security fixes
- **H-1 (LOW)** — added an `AUDIT NOTE` block above `_setCallDataKey` documenting the identical-callData residual: griefing only, no asset redirect, requires owner-key compromise. Tracked for full hardening in [#52](https://github.com/AAStarCommunity/airaccount-contract/issues/52).
- **H-2** — `AgentRegistry.registerAgent` no longer relies on the forgeable `accountId()` prefix string. Constructor takes `airAccountImplementation`; `registerAgent` checks `extcodehash(caller()) == validCloneCodeHash` (EIP-1167 minimal proxy bytecode pre-hashed at construction). Cannot be forged without deploying the canonical clone.
- **M-1 + M-3** — `factory.defaultValidatorModule` / `defaultHookModule` / `agentSessionKeyValidator` fields + setter deleted (no per-account module install needed). Agent accounts now structurally identical to human accounts.
- **M-2** — `ForceExitModule.executeForceExit` rewritten to call `account.executeFromExecutor(bytes32(0), [target||value||data])`; previously called the bridge with `{value: value}` from the module's own (always-zero) balance — feature was non-functional.
- **L-1** — `_validateWeightedSignature` rejects trailing bytes after the last consumed signature (`cursor == sigData.length`).
- **L-2** — `accountId()` returns `"airaccount.v7@0.17.2"` (was 0.16.0).
- **L-3** — eliminated alongside the `TierGuardHook` deletion (the misleading-comment line ceased to exist).

### Pre-release hardening (Codex rounds 2-4 + David PR #61 review)

Beyond the initial round 1 findings (H-1..H-2 / M-1..M-3 / L-1..L-3) above, four further rounds of adversarial review surfaced these issues, all of which are fixed in this beta:

- **Round 2 (5 P1)** — `grantSession` accepted any `msg.sender` (off-chain sig verified separately); `AgentRegistry.registerAgent` bypassable via `Clones.clone(implementation)` (extcodehash-based whitelist superseded by factory-provenance `isValidAccount` mapping); `nonce-key 0x08` smuggling rejected at base; `bindFactory` made set-once.
- **Round 3 (2 HIGH + 1 supplemental)** —
  - **A1**: `grantSessionDirect` / `grantP256SessionDirect` access reverted to **owner-EOA only**. Round 2 had briefly allowed `msg.sender == account` to enable owner-via-UserOp grant, but this opened a confused-deputy attack (an unscoped existing session key could have the account call back into the validator and mint itself a new session, bypassing owner re-authorisation). UserOp / paymaster / gasless flows must now use `grantSession` + off-chain `ownerSig`. `revokeSession` keeps both caller paths (revoke only removes authority).
  - **A2**: `AgentRegistry.bindFactory` now requires `msg.sender == deployer` (new `immutable deployer = msg.sender` captured in constructor) — without this, any bystander could front-run the legitimate deploy and bind a malicious factory.
  - **Supplemental**: `AAStarAirAccountFactoryV7._markAccountValid` now reverts on registry failure (was silently swallowed). Bubbles registry's specific error; new error `AgentRegistryMarkValidFailed`. Prevents "ghost accounts" that exist on-chain but cannot `registerAgent`.
- **Round 4 (1 HIGH I had missed)** — the 5-arg `grantSessionDirect` / `grantP256SessionDirect` backward-compat **shims** still carried the `msg.sender != owner && msg.sender != account` check from before the round-3 A1 fix. Result: the confused-deputy attack closed in the new Session-struct overload was still reachable through the shim. Both shim caller checks tightened to owner-EOA-only. (Shims subsequently deleted entirely — see "API surface" below.)
- **David PR #61 human review** —
  - MEDIUM: shim removal pulled into this PR (was previously phased to PR B); v0.17.2 now ships without dead API surface.
  - LOW: `_ownerOf` reverts new `error NotAirAccount()` when the address is not an AirAccount-shaped contract (was returning `address(0)`, which collapsed two distinct failure modes into the same `NotAccountOwner` revert).

### API surface — backward-compat shims removed

`SessionKeyValidator` no longer exposes the 5-arg `(account, sessionKey, expiry, contractScope, selectorScope)` shim form of `grantSession` / `grantSessionDirect` / `grantP256Session` / `grantP256SessionDirect`. All four functions now take a single `Session calldata cfg` struct. Integrations must construct the struct (use `_sessionLegacy`-style helpers for legacy "simple session" behavior — `velocityLimit: 0`, empty `callTargets[]` / `selectorAllowlist[]`).

### KMS / SDK migration impact (cross-referenced in issues)

- **KMS** (issues [AAStarCommunity/AirAccount#7](https://github.com/AAStarCommunity/AirAccount/issues/7) round-1 + [#11](https://github.com/AAStarCommunity/AirAccount/issues/11) round 3+4 update): `/kms/sign-agent` must return **106 bytes** (`[0x08][account(20)][key(20)][ECDSA(65)]`), not the old 66-byte form. PR [AAStarCommunity/AirAccount#8](https://github.com/AAStarCommunity/AirAccount/pull/8) implements this in the TA (selected the "TA assembles full 106B" path over "SDK assembles" for zero-trust on `key` derivation).
- **SDK** (issue [AAStarCommunity/aastar-sdk#35](https://github.com/AAStarCommunity/aastar-sdk/issues/35)): drop the `0x08` prefix assembly; for UserOp / paymaster / gasless grant flows, switch from `grantSessionDirect` UserOp self-call to `grantSession` + off-chain owner sig + relayer.

### Test results
- 29 suites, **663 tests**, 0 failed, 0 skipped.
- 7 new regression tests added by Codex round 4 + David PR #61 review covering: H-2 EOA caller rejected; `grantSessionDirect` rejects `msg.sender == account`; `grantP256SessionDirect` rejects `msg.sender == account`; full confused-deputy chain via `account.execute(grantSessionDirect)`; session key self-revoke via `account.execute(revokeSession)`; `bindFactory` rejects non-deployer; `createAccount` reverts when `_markAccountValid` fails.

### ABI bundle regenerated

`abi/AAStarAirAccountV7.full.json` re-built via `node scripts/build-full-abi.mjs` after shim removal — drops the 5-arg shim entries from the merged bundle. CI staleness check passes. No runtime behavior change.

### EIP-170 budget (runtime bytecode; limit 24,576 B)
| Contract | v0.17.1 | v0.17.2 | Headroom |
|---|---|---|---|
| AAStarAirAccountV7 | 22,697 | **21,592** | 2,984 |
| SessionKeyValidator | 5,615 | 10,000 (est. after shim removal) | 14,576 |
| AgentRegistry | (n/a old check) | 3,078 | 21,498 |
| ForceExitModule | 1,477 | 4,833 | 19,743 |
| AgentSessionKeyValidator | 5,123 | **deleted** | — |
| AirAccountCompositeValidator | 1,222 | **deleted** | — |
| TierGuardHook | 1,477 | **deleted** | — |

### Coordination
- KMS-team breaking change ahead-of-time notice: [AAStarCommunity/AirAccount#7](https://github.com/AAStarCommunity/AirAccount/issues/7). Sig format changes from 66 B → 106 B (ECDSA session) / 149 B (P256 session); session grants use a single `Session` struct.

### ADR
See `docs/2026-05-30-adr-session-key-unification.md` for full decision record (alternatives considered, Codex P0/P1/P2 review responses, B-1..B-4 sub-decisions).

---

## [v0.17.1] - 2026-05-26 (Diamond-Lite EIP-170 Fix)

### Highlights
- Account runtime exceeded EIP-170's 24,576-byte limit; fix splits the cold ERC-8004 agent + weighted-signature governance functions into a singleton `AirAccountExtension` reached through the account's `fallback`+`delegatecall` (diamond-lite). Zero capability loss; storage byte-identical via shared `AAStarAgentStorageLayout`.
- HIGH-3 content-keyed transient validation queue (`keccak256(callData)` slot derivation).
- `createAgentAccount` default-installs `AgentSessionKeyValidator` (hybrid policy, factory-admin set-once).
- Published merged `abi/AAStarAirAccountV7.full.json` (V7 + `IAirAccountAgent`) so SDK/integrators can encode the fallback-routed agent functions.
- Account runtime: ~22,697 B (was 27,975 B pre-split).
- 798 unit tests.

### Tag
`v0.17.1` at commit `93eadac` (superseded by v0.17.2 — see above; v0.17.1 was tagged but never broadcast to any chain).

---

## [v0.17.0] - 2026-05-22 (M9 Security Hardening + ERC-8004 Official Integration)

### Highlights
- Factory front-run fix: salt now bound to the full config so an attacker cannot pre-create an account at the victim's counterfactual address with different parameters.
- ERC-1271 `isValidSignature` path.
- BLS / tier-check hardening.
- ERC-7579 hook `typeId` correctness + multi-typeId module lifecycle.
- Executor Tier-1 ceiling (executors cannot exceed Tier-1 spend).
- Session cleanup on uninstall.
- ERC-8004 official Identity / Reputation / Validation registries aligned (mainnet & testnet deterministic CREATE2 addresses pinned in `src/config/ERC8004Addresses.sol`).
- Autonomous agent account model: owner = human (`msg.sender`), agentKey = session key. The agent never holds owner rights; the privilege boundary is the account, not the key.

### Tag
`v0.17.0` / `freeze/m9-v0.17.0` at commit `b8b9a7c`.

---

## [v0.16.0] - 2026-03-21 (M7 In Progress — ERC-7579 Full Module Compliance + Agent Economy)

### M7 Milestone Status: **IN PROGRESS** 🔄
- 614 unit tests (up from 446 in M6)
- Scope: ERC-7579 installModule/uninstallModule/executeFromExecutor, TierGuardHook, CompositeValidator, AgentSessionKey, Railgun parser, ERC-7828, ERC-5564, ERC-8004, ForceExitModule
- Sepolia deployment: pending (C10/C12/C18 in progress)

### Added
- ERC-7579 full module compliance: installModule(), uninstallModule(), executeFromExecutor() (C1-C3)
- TierGuardHook — ERC-7579 Hook wrapping existing tier/guard enforcement (C4)
- AirAccountCompositeValidator — ERC-7579 Validator for weighted/cumulative signatures (C6)
- AgentSessionKeyValidator — AI agent session keys with velocity limiting, call allowlists, spend caps (C16)
- AgentSessionKeyValidator.delegateSession() — hierarchical sub-agent delegation with scope narrowing (C18)
- ForceExitModule — L2→L1 guardian-gated withdrawal for OP Stack and Arbitrum (C10)
- Factory pre-install default modules via new initialize() overload (C8)
- ERC-7828 getChainQualifiedAddress() for cross-chain address disambiguation (C9)
- ERC-5564 announceForStealth() in AirAccountDelegate (C15)
- ERC-8004 setAgentWallet() in AAStarAirAccountBase (C17)
- RailgunParser — ICalldataParser for Railgun V3 transact/shield selectors (C11)
- IERC7579Module interface (src/interfaces/IERC7579Module.sol)
- docs/audit-scope.md and docs/known-issues.md for CodeHawks audit prep (C12)
- deploy-multichain.ts script for Base/Arbitrum/OP Stack deployment (C10)
- scripts/test-m7-e2e.ts — post-deployment E2E test suite for M7 features

### Changed
- AAStarAirAccountFactoryV7: constructor +2 params (defaultValidatorModule, defaultHookModule)
- AAStarAirAccountV7.VERSION: "0.15.0" → "0.16.0", accountId: "airaccount.v7@0.16.0"
- AAStarAirAccountV7: validateUserOp() now routes by nonce-key to installed validator modules (C7)
- AAStarAirAccountBase: _guardianCount visibility private → internal (needed by uninstallModule)

### Tests
- 614 total (up from 446 in M6): +168 new tests across M7 features

---

## [v0.15.0] - 2026-03-21 (M6 Complete — Session Keys + Weighted Multi-Sig + Security Hardening)

### M6 Milestone Status: **COMPLETE** ✓
- 446/446 unit tests passing (all 23 test suites)
- M6 r4 Factory deployed to Sepolia: `0x34282bef82e14af3cc61fecaa60eab91d3a82d46`
- SessionKeyValidator r2 (7-day max) deployed: `0xcaba5a18e46f728b5330ea33bd099693a1b76217`
- All E2E tests verified on Sepolia (see table below)

### AirAccount M6 r4 (Sepolia)
- **Factory**: `0x34282bef82e14af3cc61fecaa60eab91d3a82d46`
- **Implementation**: `0xBc7F28a1999E989744a7B2c4E2bB0fb34392Db80`
- **SessionKeyValidator**: `0xcaba5a18e46f728b5330ea33bd099693a1b76217`
- **CalldataParserRegistry**: `0x7099eb39fbab795e66dd71fbeaace150edf1b3c3`
- **UniswapV3Parser**: `0x5671810ac8aa1857397870e60232579cfc519515`

### E2E Verification (Sepolia, M6 r4)
| Test | Scenarios | Result |
|------|-----------|--------|
| M6 Clone Factory + Guard Externalization | 12/12 | ✅ ALL PASS |
| M6 ALG_WEIGHTED + Governance (M6.1+M6.2) | 5/5 | ✅ ALL PASS |
| M6.4 Session Key (validate path) | 5/5 | ✅ ALL PASS |
| M6.4 Session Key Full UserOp (EntryPoint) | 10/10 | ✅ ALL PASS |
| Algorithm Tier Guard | 4/4 | ✅ ALL PASS |
| Factory Constructor Validation | 5/5 | ✅ ALL PASS |
| Tiered Signatures (T1/T2/T3) | 5/5 | ✅ ALL PASS |
| Social Recovery | 10/10 | ✅ ALL PASS |

### Added — M6 Features
- **ALG_SESSION_KEY (0x08)**: Time-limited session keys with contractScope/selectorScope enforcement. ECDSA + P256 variants. `SessionKeyValidator` with `grantSession`/`grantSessionDirect`/`revokeSession`.
- **ALG_WEIGHTED (0x07)**: Configurable per-source weights (passkey/ECDSA/BLS/guardians) with tiered thresholds. Guardian-gated weakening proposal with 7-day timelock (M6.2).
- **EIP-7702 Delegate**: `AirAccountDelegate` for EOA → smart wallet delegation.
- **CalldataParser**: Protocol-aware spending guard. `CalldataParserRegistry` + `UniswapV3Parser` (exactInputSingle + exactInput).
- **EIP-1167 Clone Factory (r4)**: Deterministic clone pattern resolves EIP-170 size limit. Factory 9,527B (was 30,172B), account 20,900B (was 25,913B).

### Security Fixes (M6)
- **HIGH: Factory front-run protection** — `createAccount` address binds to `keccak256(guardians, dailyLimit)` via configHash in CREATE2 salt. Prevents attacker from pre-deploying victim's counterfactual address with malicious guardians.
- **HIGH: Session key scope bypass in executeBatch** — `_consumeSessionKey()` was called per-call; calls 2+ skipped scope checks. Fixed: key consumed once at `executeBatch` level and passed as parameter to all `_enforceGuard` calls.
- **MEDIUM: ALG_WEIGHTED guard whitelist semantic fix** — `guardAlgId` (pre-resolution) now passed separately to guard whitelist check. Approving ALG_WEIGHTED(0x07) correctly covers its tier resolutions (0x02/0x04/0x05).
- **MEDIUM: Weight threshold monotonicity** — `tier1 ≤ tier2 ≤ tier3` enforced in both `setWeightConfig` and `proposeWeightChange` via extracted `_validateWeightConfig()` helper.
- **Session max duration**: `MAX_SESSION_DURATION = 7 days` (was 24h — too restrictive for real use cases).

### Refactoring
- Extract `_validateWeightConfig()` — eliminates 9-line copy-paste between `setWeightConfig` and `proposeWeightChange`.
- Extract `_getConfigHash()` — single definition of front-run protection hash.
- Cache `address guardAddr = address(guard)` in `_enforceGuard` — saves ~200 gas/call (3 SLOADs → 1).

---

## [v0.14.0] - 2026-03-13 (M5 Complete — Deploy Scripts + Security Hardening)

### M5 Milestone Status: **COMPLETE** ✓
- 280/280 unit tests passing (all test suites)
- M5 Factory deployed to Sepolia: `0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9`
- All three E2E tests verified on Sepolia (15/15 scenarios PASS)
- CI gate: `.github/workflows/test.yml` (forge test on all PRs)

### AirAccount M5 (Sepolia)
- **Factory**: `0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9`
- **Deploy TX**: `0xaca946016fe232b00ad4bec58674ff31d8471fb8371133d72ee8dcfc02ff453a`
- **Gas used**: 5,302,643

### E2E Verification (Sepolia)
| Test | Scenarios | Result |
|------|-----------|--------|
| M5.3 Guardian Acceptance | 6/6 | ✅ ALL PASS |
| M5.8 ALG_COMBINED_T1 | 3/3 | ✅ ALL PASS |
| M5.1 ERC20 Guard | 2/2 | ✅ ALL PASS |

- M5.3 Account (salt=700): `0x866E6B61211f82931dd0a6D9134b4836FA40C15a`
- M5.8 Account (salt=600): `0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32`
- M5.1 Account (ERC20 guard): `0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC`

### Added — Deployment Infrastructure

- **`scripts/deploy-m5.ts`** — Factory deployment with token preset auto-population:
  - Reads `configs/token-presets.json` for selected profile (conservative/standard/trader)
  - Auto-populates `initialTokens`/`initialTokenConfigs` for USDC/USDT/WETH/WBTC/aPNTs
  - Supports `TOKEN_PROFILE=<profile>` env override
  - Prints summary + next-step E2E commands after deploy

- **`configs/token-presets.json`** — Per-chain token tier/daily limit profiles:
  - Chains: Sepolia (11155111), Ethereum mainnet (1), Base (8453)
  - Tokens: USDC, USDT, WETH, WBTC, aPNTs
  - Profiles: conservative (beginner), standard (personal), trader (high volume)
  - All configs satisfy: `dailyLimit >= tier2Limit >= tier1Limit`

### Fixed — Security

- **`AAStarGlobalGuard`: `dailyLimit >= tier2Limit` invariant enforced** — previously, if `dailyLimit < tier2Limit`, the daily cap would fire silently before tier enforcement, making `tier2Limit` unreachable dead config. Now validated at add time with `InvalidTokenConfig` error.
- **`configs/default-personal.json`**: Added `ALG_COMBINED_T1 (0x06)` to `approvedAlgorithms` (was missing despite being added to factory's `_buildDefaultConfig`)

### Fixed — P256 Fallback Removed (fail-fast)

- **`AAStarAirAccountBase`**: Removed `p256FallbackVerifier` storage, setter, and fallback branch
- P256 now fails fast (returns 1) when EIP-7212 precompile unavailable — no expensive pure-Solidity fallback (~280k gas) that could cause unpredictable OOG
- Deploy documentation: EIP-7212 required; supported chains: all major L2s + Ethereum mainnet (Fusaka, 2025-12-03)

### Added — CI

- **`.github/workflows/test.yml`** — Foundry test gate on all PRs to `main`

### Added — M6 Planning

- **`docs/M6-plan.md`** expanded with M6.4–M6.7:
  - M6.4: Session Key (IAAStarValidator module, no base contract change)
  - M6.5: Will Execution (WillExecutor.sol + DVT off-chain scanner)
  - M6.6: Privacy — OAPD near-term; pluggable calldata parser for M6
  - M6.7: Post-Quantum — architecture ready, deferred (gas 500k–5M, no EVM precompile)

### Test Results

- Foundry: **280/280 passed** (16 test suites, 0 failed, 0 skipped)

---

## [v0.13.6] - 2026-03-13 (M5 Business Scenarios + Comprehensive Tests)

### Added — Business Context Documentation

- **`docs/M5-plan.md` — "Feature Business Scenarios — Before & After" section**: Each M5 feature (M5.1–M5.8) now documents:
  - Real-world user scenario it addresses (concrete attack/failure mode)
  - How the feature eliminates or mitigates the scenario
  - Measurable security/UX improvement with user impact context

### Added — Comprehensive Scenario Tests (`test/M5ScenarioTests.t.sol`)

- **22 new scenario-driven tests** organized by milestone, each named after the user story it validates:
  - **M5.1 (6 tests)**: ERC20 guard — small USDC passes, stolen ECDSA key blocked, batch bypass prevented, daily cap enforces multi-day drain limit, unconfigured token unrestricted, non-ERC20 calldata not intercepted
  - **M5.2 (2 tests)**: Governance — team finalizes setup and registration blocked, messagePoint cross-op replay prevented
  - **M5.3 (5 tests)**: Guardian acceptance — happy path, typo guardian rejected, zero guardian rejected, wrong owner binding, wrong salt replay blocked
  - **M5.7 (3 tests)**: Force guard — zero daily limit rejected, minimal non-zero accepted, raw `createAccount` still flexible
  - **M5.8 (6 tests)**: Zero-trust — both factors valid passes, TE key alone fails, device alone fails, standard ECDSA unaffected, combined T1 is tier-1, factory approves 0x06

### Added — E2E Test Scripts (Sepolia)

- **`scripts/test-m5-erc20-guard-e2e.ts`** — M5.1 ERC20 token guard E2E:
  - Deploys account with aPNTs guard (tier1=100, tier2=1000, daily=5000 aPNTs)
  - Scenario A: 50 aPNTs ECDSA => SUCCESS; Scenario B: 500 aPNTs ECDSA => InsufficientTokenTier
- **`scripts/test-m5-combined-t1-e2e.ts`** — M5.8 ALG_COMBINED_T1 zero-trust E2E:
  - Deploys account, registers P256 key, submits UserOp with combined 130-byte sig
  - Test A: both P256+ECDSA valid => SUCCESS; Test B: fake P256 => rejected; Test C: ECDSA-only backward compat
- **`scripts/test-m5-guardian-accept-e2e.ts`** — M5.3 guardian acceptance E2E (6 scenarios):
  - Test A: happy path (both guardians sign) => account created; Tests B–F: typo/zero/wrong-owner/wrong-salt/zero-limit all REVERT

### Fixed

- **`scripts/test-tiered-e2e.ts`** — F55 fix: `mpHash` now binds messagePoint to UserOp:
  `keccak256(concat([userOpHash, messagePoint]))` instead of `keccak256(messagePoint)`
  Prevents DVT node from replaying a (messagePoint, BLS sig) pair across different UserOps

### Test Results

- Foundry: **274/274 passed** (22 new M5 scenario tests in `test/M5ScenarioTests.t.sol` + 252 existing)

---

## [v0.13.5] - 2026-03-13 (M5.7 + M5.8)

### Added — M5.7: Force Guard Requirement

- **`createAccountWithDefaults` now requires `dailyLimit > 0`** — prevents accidentally creating unguarded production accounts via convenience method. Raw `createAccount` remains flexible for testing.

### Added — M5.8: Zero-Trust Tier 1 (ALG_COMBINED_T1 = 0x06)

- **`ALG_COMBINED_T1 = 0x06` constant** — new algorithm identifier
- **`_validateCombinedT1(userOpHash, sigData)` internal function** — simultaneously verifies P256 passkey AND owner ECDSA on-chain; neither alone is sufficient
  - Signature format (130 bytes): `[0x06][P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]`
  - P256 uses EIP-7212 precompile (with `p256FallbackVerifier` fallback from M5.4)
  - ECDSA signs `userOpHash.toEthSignedMessageHash()`
- **`_validateSignature` dispatch updated**: routes `0x06` → `_validateCombinedT1`
- **`_algTier(0x06)` = tier 1** — same spending limits as ECDSA Tier 1, but dual-factor enforced
- **Factory `_buildDefaultConfig` updated**: includes 0x06 in default approved algorithms (now 6 algIds: 0x01–0x06)

### Security

- Trust gap eliminated for `ALG_COMBINED_T1` users: chain independently verifies both P256 passkey (device-bound) and ECDSA (TE key). A compromised TE alone or stolen device alone cannot transact.

### Test Results

- Foundry: **252/252 passed** (7 new M5.8 tests in `test/AAStarAirAccountM5_8.t.sol` + 245 existing)

---

## [v0.13.3] - 2026-03-13 (M5.4)

### Added — Chain Compatibility & P256 Fallback (F60)

- **`p256FallbackVerifier` storage** in `AAStarAirAccountBase` — fallback pure-Solidity P256 verifier for chains without EIP-7212 precompile at `0x100`
- **`setP256FallbackVerifier(address)` owner function** — owner can configure fallback verifier post-deployment; set to `address(0)` to disable (precompile-required mode)
- **`P256FallbackVerifierSet(address)` event** — emitted when fallback is configured
- **`_validateP256` updated**: tries EIP-7212 precompile first; if precompile call fails or returns empty, falls back to configured verifier using same call interface: `staticcall(abi.encode(hash,r,s,x,y))` → `uint256(1)` for valid
- **Precompile address table** documented in `docs/M5-plan.md` — confirmed precompile addresses correct across all target chains

### Test Results

- Foundry: **245/245 passed** (8 new M5.4 tests in `test/AAStarAirAccountM5_4.t.sol` + 237 existing)

---

## [v0.13.2] - 2026-03-13 (M5.3)

### Added — Guardian Validation (Accept-Pattern)

- **`AAStarAirAccountFactoryV7.createAccountWithDefaults` updated signature**: now requires `guardian1Sig` and `guardian2Sig` acceptance signatures
  - Each guardian must sign: `keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()` (domain-separated since Codex audit fix 2026-03-19)
  - On-chain verification before account deployment — prevents typo/invalid guardian addresses
- **`GuardianDidNotAccept(address guardian)` error** — reverts if signature doesn't recover to declared guardian address
- Uses `ECDSA.tryRecover` (no-revert path) for safe handling of malformed signatures

### Test Results

- Foundry: **237/237 passed** (5 new M5.3 guardian acceptance tests in `AAStarAirAccountFactoryV7.t.sol` + 232 existing)

---

## [v0.13.1] - 2026-03-13 (M5.2)

### Added — Governance Hardening

- **`AAStarValidator.setupComplete` flag** — bool storage variable, initially `false`
- **`AAStarValidator.finalizeSetup()`** — owner-only, one-way: sets `setupComplete = true`, emits `SetupFinalized`. After this call, `registerAlgorithm` is permanently disabled.
- **`AAStarValidator.SetupAlreadyClosed` error** — reverts if `registerAlgorithm` is called after `finalizeSetup()`
- **`AAStarValidator.SetupFinalized` event** — emitted on finalization

### Fixed (Security)

- **F55 — messagePoint cross-op replay prevention**: `_validateCumulativeTier2` and `_validateCumulativeTier3` now require owner to sign `keccak256(abi.encodePacked(userOpHash, messagePoint))` instead of just `keccak256(messagePoint)`. This binds the messagePoint attestation to a specific UserOperation, preventing a DVT node from reusing a previously captured (userOpHash, messagePoint) pair from a different operation.

### Test Results

- Foundry: **232/232 passed** (6 new M5.2 tests in `AAStarValidator.t.sol` + 226 existing)
- All existing cumulative signature tests updated to sign `keccak256(userOpHash ++ messagePoint)`

---

## [v0.13.0] - 2026-03-13 (M5.1)

### Added — ERC20 Token-Aware Guard

- **`AAStarGlobalGuard.TokenConfig` struct** — per-token tier thresholds and daily cap in token's native units
- **`checkTokenTransaction(token, amount, algId)`** — enforces token tier limits (cumulative, prevents batch bypass) and daily cap; unconfigured tokens pass through with no limits
- **`addTokenConfig(token, config)`** — monotonic: add-only, never remove; reverts if already configured
- **`decreaseTokenDailyLimit(token, newLimit)`** — monotonic tighten-only for token daily cap
- **`tokenTodaySpent(token)`** — view for off-chain monitoring
- **Guard constructor extended**: accepts `address[] initialTokens, TokenConfig[] initialConfigs` — tokens configured at deployment (factory passes empty arrays by default)
- **`_enforceGuard` now parses ERC20 calldata** — detects `transfer(address,uint256)` (0xa9059cbb) and `approve(address,uint256)` (0x095ea7b3), extracts amount, calls `guard.checkTokenTransaction`
- **Account `guardAddTokenConfig(token, config)`** — owner pass-through to guard, monotonic
- **Account `guardDecreaseTokenDailyLimit(token, newLimit)`** — owner pass-through to guard
- **`InitConfig` extended** with `initialTokens` and `initialTokenConfigs` fields
- **`_algTier` mirrored in guard** — `_algTier(algId)` private function in guard for token tier enforcement; must stay in sync with account's `_algTier`
- **23 new unit tests** in `test/AAStarGlobalGuardM5.t.sol` — tier enforcement, daily limits, cumulative batch bypass prevention, monotonic config, ERC20 calldata parsing integration

### Security
- ERC20 token transfers (`value=0`) now subject to tier enforcement — previous M4 design allowed unlimited ERC20 transfers with ECDSA regardless of tier
- Batch bypass prevention applies to both ETH and ERC20 paths — cumulative read before each call, write after

### Test Results
- Foundry: **226/226 passed** (23 new M5.1 + 203 existing)
- Tiered E2E (Sepolia): 5/5 passed ✅
- Social Recovery E2E: 5/5 passed ✅ (added `clearStaleRecovery` idempotent cleanup)
- Gasless E2E: PASSED ✅ (163,999 gas)

---

## [v0.12.6] - 2026-03-12

### Added
- **`version()` view function** — returns contract version string `"0.12.6"`. All future releases will update this constant.
- **`VERSION` constant** — `string public constant VERSION = "0.12.6"` in `AAStarAirAccountV7`
- **`todaySpent()` view** — `AAStarGlobalGuard` exposes today's cumulative spend for external tier enforcement
- **Cumulative tier enforcement** — `_enforceGuard` now reads `guard.todaySpent()` and checks tier against `(alreadySpent + value)`, preventing two bypass patterns:
  - **Batch bypass**: `executeBatch([0.1 ETH × 10])` with ECDSA — each call individually ≤ tier1Limit but cumulatively exceeds it; second call reverts with `InsufficientTier`
  - **Multi-TX bypass**: 10 separate UserOps each ≤ tier1Limit — persistent `dailySpent` storage catches the cumulative total

### Fixed (GPT-5.2 Security Review)
- **Finding 1**: `_lastValidatedAlgId` storage variable → transient storage queue (`_storeValidatedAlgId` / `_consumeValidatedAlgId`). Prevents cross-UserOp algId contamination when EntryPoint bundles multiple ops from same sender.
- **Finding 2**: `AAStarBLSAlgorithm.registerPublicKey` — added `onlyOwner` (was permissionless, allowing BLS tier bypass)
- **Finding 5**: `setTierLimits` — added `tier1 <= tier2` validation to prevent misconfiguration
- **Finding 6**: `createAccountWithDefaults` — added non-zero guardian validation

### Documentation
- `docs/acceptance-guide.md` — product manager acceptance guide with full deployment, E2E flows, gas tables
- `docs/gpt52-review-response.md` — GPT-5.2 security review response with assessment and fix status
- `docs/M5-plan.md` — M5 milestone plan: ERC20 token guard, governance hardening, guardian validation, chain compatibility
- `CHANGELOG.md` — this file

### Known Design Notes
- `dailyLimit = 0` means **unlimited** (no cap), not "zero budget" — consistent with Guard's `if (dailyLimit > 0)` check
- DVT/BLS security value is **key isolation** (requires DVT cluster private keys), not on-chain anomaly detection; off-chain risk control is a protocol-layer concern
- Tier enforcement is ETH-only (msg.value); ERC20 value tiers planned for M5

### Test Results
- **Foundry**: 203/203 passing (+3 new cumulative tier tests)

---

## [v0.12.5-m4] - 2026-03-11

### Added
- **Cumulative signature model** — algId `0x04` (P256 + BLS) and `0x05` (P256 + BLS + Guardian ECDSA) for tiered multi-signature verification
- **`getConfigDescription()`** view function returning 12-field `AccountConfig` struct for frontend introspection
- **Config templates** — `configs/default-personal.json`, `high-security.json`, `developer-test.json`
- **Onboarding scripts** — 4-step flow: create keys → deploy account → test transfer → gasless transfer
- **Frontend pages** — config page, passkey registration, account creation, tier-aware transaction page
- **Weight-based multi-signature research** — `docs/M4.5-weighted-signature-research.md` (implementation deferred to M5)
- **Acceptance guide** — `docs/acceptance-guide.md` for product manager verification
- **Gasless E2E test report** — `docs/gasless-e2e-test-report.md` with full transaction data

### Fixed
- **BLS payload slice bug** in `_validateCumulativeTier2/Tier3` — was passing `blsPayload[0:]` (included `nodeIdsLength` prefix), now correctly passes `blsPayload[32:]`
- **Factory default config** — added algId `0x04` and `0x05` to `_buildDefaultConfig()` approved algorithms

### Changed
- Factory now approves 5 algorithms by default: ECDSA, BLS, P256, Cumulative T2, Cumulative T3

### Test Results
- **Foundry**: 200 tests passing
- **Sepolia E2E**: 15 tests passing (5 tiered + 5 social recovery + 1 gasless + 4 onboarding scripts)
- **M4 Factory**: `0x914db0a849f55e68a726c72fd02b7114b1176d88` (Sepolia)
- **Gas**: Tier1 140,352 / Tier2 278,634 / Tier3 288,351

---

## [v0.12.5-m3] - 2026-03-09

### Added
- **AAStarGlobalGuard** — immutable spending guard with daily limits and algorithm whitelist
- **Social recovery** — 2-of-3 guardian threshold with 2-day timelock
- **P256 passkey support** — EIP-7212 precompile integration for WebAuthn
- **Tiered signature routing** — value-based signature requirements (Tier 1/2/3)
- **Transient storage reentrancy guard** — EIP-1153 (~200 gas vs ~7100 SSTORE)
- **Security review** — `docs/security-review.md`
- **Gas analysis** — `docs/gas-analysis.md`
- **Gasless E2E** — SuperPaymaster integration verified on Sepolia

### Test Results
- **Foundry**: 176 tests passing
- **M3 Factory**: `0xce4231da69015273819b6aab78d840d62cf206c1` (Sepolia)
- **Gas**: 127,249 (vs M2 259,694 = -51%)

---

## [v0.12.5-m2] - 2026-03-07

### Added
- **BLS12-381 aggregate signature** — triple signature (ECDSA×2 + BLS) via EIP-2537 precompiles
- **AAStarBLSAlgorithm** — node registry, key aggregation, cached aggregate keys
- **AAStarValidator** — algorithm router with only-add registry and 7-day timelock governance

### Test Results
- **M2 Factory**: `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` (Sepolia)
- **Gas**: 259,694 (vs YetAA 523,306 = -50.4%)

---

## [v0.12.5-m1] - 2026-03-05

### Added
- **AAStarAirAccountV7** — core ERC-4337 account contract (non-upgradable)
- **AAStarAirAccountFactoryV7** — CREATE2 deterministic factory
- **Inline ECDSA validation** — 65-byte personal sign
- **EntryPoint deposit management** — addDeposit, getDeposit, withdrawDepositTo

### Test Results
- **M1 Factory**: `0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f` (Sepolia)
- **First E2E TX**: `0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81`
