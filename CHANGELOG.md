# Changelog

All notable changes to AirAccount contract will be documented in this file.

## Product Overview

AirAccount is a non-upgradable ERC-4337 smart wallet that makes crypto transactions as simple as mobile payments. Users authenticate with a passkey (fingerprint/face), and the wallet automatically applies the right level of security based on transaction value — small payments need just one tap, while large transfers require additional co-signatures from DVT nodes and trusted guardians. Gas fees can be paid in aPNTs tokens instead of ETH, enabling true zero-ETH-cost user experience. If the user loses their key, 2-of-3 guardians can recover the account through a timelocked social recovery process. All security rules (spending limits, algorithm whitelists) are enforced by an immutable guard that can only be tightened, never loosened.

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
