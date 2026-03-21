# Changelog

All notable changes to AirAccount contract will be documented in this file.

## Product Overview

AirAccount is a non-upgradable ERC-4337 smart wallet that makes crypto transactions as simple as mobile payments. Users authenticate with a passkey (fingerprint/face), and the wallet automatically applies the right level of security based on transaction value — small payments need just one tap, while large transfers require additional co-signatures from DVT nodes and trusted guardians. Gas fees can be paid in aPNTs tokens instead of ETH, enabling true zero-ETH-cost user experience. If the user loses their key, 2-of-3 guardians can recover the account through a timelocked social recovery process. All security rules (spending limits, algorithm whitelists) are enforced by an immutable guard that can only be tightened, never loosened.

---

<<<<<<< HEAD
=======
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

>>>>>>> main
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
