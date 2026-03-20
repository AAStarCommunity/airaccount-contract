# AirAccount — Contract Registry & Feature Overview

**Version**: v0.15.0 (M6)
**Date**: 2026-03-20
**Network**: Sepolia Testnet (Chain ID: 11155111)
**Compiler**: Solidity 0.8.33, Cancun EVM, via-IR, 10k optimizer runs

---

## 1. Source Contract Inventory

All contracts live under `src/`. Submodule `lib/YetAnotherAA-Validator` is read-only.

### 1.1 Core Contracts (`src/core/`)

| Contract | Lines | Description |
|----------|-------|-------------|
| `AAStarAirAccountBase.sol` | ~900 | Abstract base for all AirAccount variants. Implements ERC-4337 `validateUserOp`, tiered signature dispatch (`_algTier`), global guard enforcement (`_enforceGuard`), social recovery, guardian management, P256 key storage, daily ETH limit, pluggable calldata parser registry. All security invariants live here. |
| `AAStarAirAccountV7.sol` | ~50 | Concrete account contract (M6-current). Extends `AAStarAirAccountBase`. Deployed per-user by the factory. Non-upgradable. |
| `AAStarAirAccountFactoryV7.sol` | ~200 | CREATE2 factory. `createAccountWithDefaults(owner, salt, g1, g1sig, g2, g2sig, dailyLimit)` — requires both guardian acceptance signatures. `getAddressWithDefaults(...)` — counterfactual address prediction (view). Factory validates all default token configs at constructor time. |
| `AAStarGlobalGuard.sol` | ~300 | Per-account immutable spending guard. Enforces ETH daily limit, ERC20 token tier limits (ECDSA=Tier1, P256=Tier1, BLS=Tier3, SessionKey=Tier1), cumulative daily token spend tracking. Monotonic: limits can only decrease, algorithms can only be added. |
| `CalldataParserRegistry.sol` | ~80 | Singleton registry mapping `dest address → ICalldataParser`. Only-add (parsers cannot be removed). Ownership-controlled. Used by `_enforceGuard` to resolve DeFi protocol calldata before falling back to native ERC20 parsing. |

### 1.2 Validator Contracts (`src/validators/`)

| Contract | Lines | Description |
|----------|-------|-------------|
| `AAStarValidator.sol` | ~150 | Validator router. Maps `algId` (first byte of signature) to algorithm contract via `IAAStarAlgorithm`. Only-add registry with optional 7-day governance timelock for new additions. |
| `AAStarBLSAlgorithm.sol` | ~350 | BLS12-381 signature verification for Tier 2 and Tier 3. Uses EIP-2537 precompiles. Maintains a node registry of 128-byte G1 public keys. Supports pre-cached aggregated keys for gas savings. algId: `0x01`. |
| `SessionKeyValidator.sol` | ~250 | Time-limited session key authorization (M6.4). Stores `sessions[account][sessionKey] → Session{expiry, contractScope, selectorScope, revoked}`. Owner grants sessions via off-chain signature (`grantSession`) or direct call (`grantSessionDirect`). Validates 105-byte `[account(20)][sessionKey(20)][ECDSASig(65)]` signatures. algId: `0x08`. |

### 1.3 Parser Contracts (`src/parsers/`)

| Contract | Lines | Description |
|----------|-------|-------------|
| `UniswapV3Parser.sol` | ~80 | Implements `ICalldataParser` for Uniswap V3 SwapRouter. Supports `exactInputSingle` (selector `0x414bf389`) and `exactInput` (selector `0xc04b8d59`). Returns `(tokenIn, amountIn)` so the guard can apply token tier limits to DeFi swaps. Unknown selectors return `(address(0), 0)`. |

### 1.4 Interface Contracts (`src/interfaces/`)

| Interface | Description |
|-----------|-------------|
| `IAAStarAlgorithm.sol` | `validate(bytes32 userOpHash, bytes signature) → uint256`. Every algorithm module (BLS, Session Key, etc.) implements this. Return 0 = success, 1 = failure. |
| `IAAStarValidator.sol` | Router interface: `validateSignature(bytes32 userOpHash, bytes signature) → uint256`. Accounts call this when an algId requires an external module. |
| `ICalldataParser.sol` | `parseTokenTransfer(bytes data) → (address token, uint256 amount)`. Every DeFi protocol parser implements this. Returns `(address(0), 0)` if calldata is not recognized. |

### 1.5 Aggregator Contracts (`src/aggregator/`)

| Contract | Description |
|----------|-------------|
| `AAStarBLSAggregator.sol` | ERC-4337 aggregator for batching BLS signatures across multiple UserOps. Reduces per-UserOp BLS verification cost in bundled blocks. |

---

## 2. Algorithm ID (algId) Reference Table

The first byte of every UserOp signature is the `algId`. It determines the signature type and security tier.

| algId | Name | Tier | Contract | Status |
|-------|------|------|----------|--------|
| `0x01` | BLS Legacy Triple | Tier 3 | `AAStarBLSAlgorithm` | Registered in Validator Router |
| `0x02` | ECDSA | Tier 1 | (inline in base) | Native |
| `0x03` | P256 (Passkey/WebAuthn) | Tier 1 | (inline in base) | Native |
| `0x04` | Cumulative T2 (P256 + BLS) | Tier 2 | (inline in base) | Native |
| `0x05` | Cumulative T3 (P256 + BLS + Guardian) | Tier 3 | (inline in base) | Native |
| `0x06` | Combined T1 (ECDSA + P256 combined) | Tier 1 | (inline in base) | Native |
| `0x08` | Session Key (ephemeral ECDSA, time-limited) | Tier 1 | `SessionKeyValidator` | M6.4 — register in Validator Router |

**Tier definitions**:
- **Tier 1**: ECDSA / P256 / Session Key — for transactions ≤ tier1Limit (e.g., ≤ 0.1 ETH or ≤ 100 USDC)
- **Tier 2**: P256 + BLS dual-factor — for tier1Limit < tx ≤ tier2Limit
- **Tier 3**: P256 + BLS + Guardian — for tx > tier2Limit

---

## 3. Deployed Addresses (Sepolia)

### 3.1 Infrastructure (shared)

| Contract | Address |
|----------|---------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SuperPaymaster | `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A` |
| aPNTs Token | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` |
| SBT (Identity) | `0x677423f5Dad98D19cAE8661c36F094289cb6171a` |
| Chainlink ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

### 3.2 AirAccount Core (by milestone)

| Milestone | Contract | Address |
|-----------|----------|---------|
| M2 | BLS Algorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` |
| M2 | Validator Router | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` |
| M3 | Factory | `0xce4231da69015273819b6aab78d840d62cf206c1` |
| M4 | Factory | `0x914db0a849f55e68a726c72fd02b7114b1176d88` |
| M5 | Factory r5 (current) | `0xd72a236d84be6c388a8bc7deb64afd54704ae385` |

> M6 deploys: `SessionKeyValidator`, `CalldataParserRegistry`, `UniswapV3Parser` — addresses assigned per deployment

### 3.3 Test Accounts (EOA)

| Role | Address |
|------|---------|
| Owner / Bundler | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Guardian 1 (Anni) | `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` |
| Guardian 2 (Bob) | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` |
| Guardian 3 (Charlie) | `0x4F0b7d0EaD970f6573FEBaCFD0Cd1FaB3b64870D` |

---

## 4. Milestone Feature Overview (M1 – M6)

### M1 — ECDSA E2E ✅
Single-owner ERC-4337 account. ECDSA signature (algId `0x02`). Factory with CREATE2. Basic ETH transfer.

### M2 — BLS Triple Signature ✅
BLS12-381 algorithm (algId `0x01`) using EIP-2537 precompiles. Validator router for external algorithm dispatch. 50% gas reduction vs YetAnotherAA (259k → 127k).

### M3 — Security Hardening ✅
P256/WebAuthn support (algId `0x03`). Non-upgradable enforcement. Atomic guard deployment. Immutable `guard.account` binding. KMS integration for passkey signing.

### M4 — Cumulative Signatures + Tiers ✅
Tiered signature model: T2 = P256+BLS (`0x04`), T3 = P256+BLS+Guardian (`0x05`). Cumulative spend tracking prevents batch bypass. Social recovery: 2-of-3 guardian threshold, 2-day timelock, owner cannot cancel.

### M5 — ERC20 Guard + Governance + Zero-Trust ✅
Token-tier enforcement: ERC20 `transfer`/`approve` calldata parsed, amount checked against per-token tier limits. Validator router governance: 7-day timelock for new algorithm proposals. Guardian acceptance signatures required at account creation. Zero-trust Tier 1: direct owner calls always use ECDSA regardless of msg.sender. Factory eager validation. Packed guardian storage. 298 unit tests.

### M6.4 — Session Key (Time-Limited Authorization) ✅
`SessionKeyValidator.sol` — algId `0x08`. Owner grants a session key with expiry, optional contract/selector scope. DApps sign UserOps with the session key. Session can be revoked instantly by owner or account. Tier 1 (same spending limits as ECDSA). No account storage changes needed. Off-chain E2E: `scripts/test-session-key-e2e.ts`.

### M6.6a — OAPD (One Account Per DApp) ✅
Zero Solidity changes. `OAPDManager` TypeScript class. Derives deterministic salt from `keccak256(ownerAddress + dappId)`. Same owner + different DApps → different account addresses → cross-DApp correlation impossible. All accounts share the same guardian pair and social recovery path. E2E: `scripts/test-oapd-e2e.ts`.

### M6.6b — Pluggable Calldata Parser ✅
`ICalldataParser` interface. `CalldataParserRegistry` singleton maps `dest → parser`. `UniswapV3Parser` understands Uniswap V3 `exactInputSingle` / `exactInput` calldata. `_enforceGuard` in the account checks the registry first; if parser returns a recognized token/amount, applies tier enforcement; otherwise falls back to native ERC20 parsing. Enables token tier enforcement for DeFi protocol calls where `value=0`. E2E: `scripts/test-calldata-parser-e2e.ts`.

---

## 5. Test Coverage

| Suite | Tests | Status |
|-------|-------|--------|
| `AAStarAirAccountV7.t.sol` | 15 | ✅ |
| `AAStarAirAccountV7_M2.t.sol` | 12 | ✅ |
| `AAStarAirAccountV7_M3.t.sol` | 22 | ✅ |
| `AAStarAirAccountM5_4.t.sol` | 8 | ✅ |
| `AAStarAirAccountM5_8.t.sol` | 9 | ✅ |
| `AAStarAirAccountFactoryV7.t.sol` | 25 | ✅ |
| `AAStarBLSAlgorithm.t.sol` | 25 | ✅ |
| `AAStarBLSAlgorithm_M3.t.sol` | 6 | ✅ |
| `AAStarBLSAggregator.t.sol` | 13 | ✅ |
| `AAStarGlobalGuard.t.sol` | 26 | ✅ |
| `AAStarGlobalGuardM5.t.sol` | 41 | ✅ |
| `AAStarValidator.t.sol` | 19 | ✅ |
| `AAStarValidator_M3.t.sol` | 16 | ✅ |
| `CalldataParser.t.sol` | 20 | ✅ |
| `CumulativeSignature.t.sol` | 8 | ✅ |
| `M5ScenarioTests.t.sol` | 22 | ✅ |
| `SessionKeyValidator.t.sol` | 21 | ✅ |
| `SocialRecovery.t.sol` | 37 | ✅ |
| **Total** | **345** | **0 failed** |

### E2E Scripts (Sepolia)

| Script | Feature | Tests |
|--------|---------|-------|
| `scripts/test-tiered-e2e.ts` | M4 Tier 1/2/3 signatures | 5 |
| `scripts/test-social-recovery-e2e.ts` | M4 Social recovery | 5 |
| `scripts/test-gasless-complete-e2e.ts` | M5 SuperPaymaster gasless | 1 |
| `scripts/test-factory-validation-e2e.ts` | M5 Factory guardian acceptance | 5 |
| `scripts/test-session-key-e2e.ts` | M6.4 Session Key | 5 |
| `scripts/test-oapd-e2e.ts` | M6.6a OAPD | 6 |
| `scripts/test-calldata-parser-e2e.ts` | M6.6b Calldata Parser | 5 |

---

## 6. Security Properties

| Property | Mechanism |
|----------|-----------|
| Non-upgradable | No proxy, no UUPS. New features require new contract + user migration. |
| Atomic guard | Guard deployed in account constructor — no window without a guard. |
| Guard binding | `guard.account` immutable — guard cannot be detached or repointed. |
| Monotonic security | Daily limits can only decrease; approved algorithms only grow; token configs only added. |
| Guardian acceptance | Both personal guardians must sign domain-separated hash before account creation. |
| Recovery owner-lockout | Owner cannot cancel recovery — prevents stolen key from blocking rescue. |
| Cross-UserOp isolation | Validated algId stored in transient storage, consumed in execution — prevents contamination. |
| Session key safety | Session expiry enforced on-chain; scope restricts to contract/selector; instant revocation by owner. |
| Parser safety | Parsers are optional and only-add; if parser fails gracefully (`→ (0,0)`), ERC20 fallback applies. |
