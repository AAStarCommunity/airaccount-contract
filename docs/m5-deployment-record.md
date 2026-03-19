# AirAccount M5 Deployment Record

## Overview

- **Milestone**: M5 — ERC20 Token Guard, Governance Hardening, Zero-Trust Tier 1
- **Version**: v0.14.0
- **Branch**: `M5`
- **Deployed**: 2026-03-13
- **Deployer EOA**: `0xb5600060e6de5E11D3636731964218E53caadf0E`
- **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

---

## All Deployed Contracts — Sepolia (Complete Table)

> Cumulative across all milestones. Deployer: `0xb5600060e6de5E11D3636731964218E53caadf0E`

### Infrastructure (shared, milestone-independent)

| Contract | Address | Deploy Tx | Purpose |
|----------|---------|-----------|---------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | (ERC-4337 canonical) | UserOp bundler entrypoint |
| SuperPaymaster | `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A` | (external) | Gas sponsorship in aPNTs |
| aPNTs Token | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` | (external) | ERC-20 gas token |
| SBT | `0x677423f5Dad98D19cAE8661c36F094289cb6171a` | (external) | Soul-bound identity |
| Registry | `0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788` | (external) | Role-based SBT minting |
| Price Feed (Chainlink) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | (external) | ETH/USD oracle |

### AirAccount Contracts (by milestone)

| Milestone | Contract | Address | Deploy Tx | Gas Used | Notes |
|-----------|----------|---------|-----------|----------|-------|
| **YetAA (legacy)** | AAStarValidator | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` | `0x901a946407ef...c34a4f` | ~205k | Legacy; still functional |
| **YetAA (legacy)** | AAStarAccountFactoryV7 | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` | `0x570a6b84ae80...7f7a88` | — | Proxy factory |
| **M1** | AirAccount Factory V7 | `0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f` | (M1 E2E) | — | ECDSA-only |
| **M2** | AAStarBLSAlgorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | (M2 deploy) | — | BLS12-381 verifier |
| **M2** | AAStarValidator (router) | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` | (M2 deploy) | — | algId router |
| **M2** | AirAccount Factory V7 | `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` | (M2 deploy) | — | BLS triple sig |
| **M3** | AirAccount Factory V7 | `0xce4231da69015273819b6aab78d840d62cf206c1` | (M3 deploy) | — | Security hardened |
| **M4** | AirAccount Factory V7 | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | (M4 deploy) | — | Cumulative sigs + social recovery |
| **M5 r1** | AirAccount Factory V7 | `0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9` | `0xaca946016fe2...453a` | 5,302,643 | Superseded — see M5 r2 |
| **M5 r2** | AirAccount Factory V7 | `0xb1e9fede6894a1628232c7492262b22e32d69563` | `0x3f06cc25b3c7...22f7` | 5,565,757 | Superseded — see M5 r3 |
| **M5 r3** | AirAccount Factory V7 | `0x03d47604c5b04194ce4cc09d26e14eaf856875bc` | `0xc0bd2480a9b5...1e8` | 5,646,614 | Superseded — see M5 r4 |
| **M5 r4** | AirAccount Factory V7 | `0x24cd3231a8dd261da8cb1e6b017d1d1c4077c078` | `0xfb73609bd6ff826f7126ac6fea5a64d39c8502bb09c5ea2be1febba57afa1f47` | 5,663,960 | Superseded — see M5 r5 |
| **M5 r5** | **AirAccount Factory V7** | **`0xd72a236d84be6c388a8bc7deb64afd54704ae385`** | `0x2e457d3c529244f296b5756ebd4a55377d0966bb8e3617db6ed69543c4b8e401` | **5,672,318** | **Current — addr/dedup validation in constructor, all Codex+script fixes applied** |
| **M5** | **AAStarBLSAggregator** | **`0x7700aec8a15a94db5697c581de8c88ecf83b59ff`** | `0x5b6de23a144b...c0a27` | **855,052** | **F67 — IAggregator for batch BLS** |

### M5 Test Accounts (Sepolia)

| Salt | Address | Purpose | Creation Tx |
|------|---------|---------|-------------|
| 700 | `0x866E6B61211f82931dd0a6D9134b4836FA40C15a` | M5.3 Guardian acceptance | `0xed2fd9aa50c4...28f46` |
| 600 | `0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32` | M5.8 ALG_COMBINED_T1 | `0x1d872b6aba38...dc49a` |
| — | `0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC` | M5.1 ERC20 guard | `0xf1f92f44a165...c905` |
| 820 | `0xe196792cB06602165d8922FB30E52708a1d90390` | Gasless E2E | `0x21aebaeb631c...d436` |
| 810 | `0x5B037C9CEcCCFcD48c0552129Aca56D96F3D9cFE` | F67 BLS aggregator acc1 | `0x18e3b50cb9de...898f` |
| 811 | `0x272ed1D9b1eC6E2AeeEcD42Db290722E314e9645` | F67 BLS aggregator acc2 | `0x80ad870b4320...d73a` |

---

## M5 Feature Summary

| Feature | Description | Key Change |
|---------|-------------|------------|
| M5.1 | ERC20 Token Guard | Per-token tier/daily limits in `AAStarGlobalGuard` |
| M5.2 | Governance Hardening | `setupComplete` flag + messagePoint binds to userOpHash |
| M5.3 | Guardian Acceptance | `createAccountWithDefaults` verifies guardian signatures on-chain |
| M5.4 | Chain Compatibility | Fail-fast (no fallback): EIP-7212 + EIP-2537 required |
| M5.6 | Gas Optimization | Assembly `ecrecover` in `_validateECDSA`; BLS key cache script |
| M5.7 | Force Guard | `createAccountWithDefaults` rejects `dailyLimit = 0` |
| M5.8 | Zero-Trust Tier 1 | `ALG_COMBINED_T1 (0x06)`: P256 + ECDSA verified independently on-chain |

---

## Sepolia Testnet Deployment

### Network Configuration

| Item | Value |
|------|-------|
| Network | Sepolia (Chain ID: 11155111) |
| Deployer EOA | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| Deployed at | 2026-03-13 |
| Deploy script | `scripts/deploy-m5.ts` |
| Token profile | `standard` — 5 tokens (USDC/USDT/WETH/WBTC/aPNTs) baked into factory constructor via `configs/token-presets.json` |

### Deployed Factory

| Field | Value |
|-------|-------|
| Contract | `AAStarAirAccountFactoryV7.sol` |
| Address | `0x03d47604c5b04194ce4cc09d26e14eaf856875bc` |
| Tx Hash | `0xc0bd2480a9b549b57d6a16bc7ac62b6187a4d9e7fa666f810dabc6e9d031f1e8` |
| Gas Used | 5,646,614 |
| Etherscan | https://sepolia.etherscan.io/address/0x03d47604c5b04194ce4cc09d26e14eaf856875bc |
| Deploy TX | https://sepolia.etherscan.io/tx/0xc0bd2480a9b549b57d6a16bc7ac62b6187a4d9e7fa666f810dabc6e9d031f1e8 |
| Changes vs r2 | Packed guardian storage: `_guardian0+_guardianCount` in one slot; saves ~2,100 gas/read on social recovery path |

> **Note**: The factory includes `AAStarAirAccountV7` and `AAStarGlobalGuard` creation code embedded via constructor. Each `createAccount` call deploys both an account and a guard atomically. No implementation proxy — non-upgradable by design.

---

## E2E Test Accounts (Sepolia)

### Account A — Guardian Acceptance Test (M5.3)

| Field | Value |
|-------|-------|
| Address | `0x866E6B61211f82931dd0a6D9134b4836FA40C15a` |
| Salt | 700 |
| Owner | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Guardian 1 | `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` |
| Guardian 2 | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` |
| Creation TX | `0xed2fd9aa50c445bde0c81307728bf5fec89249b41550f9a019684062cab28f46` |
| Creation Method | `createAccountWithDefaults` (guardian sigs verified on-chain) |

### Account B — Zero-Trust ALG_COMBINED_T1 Test (M5.8)

| Field | Value |
|-------|-------|
| Address | `0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32` |
| Salt | 600 |
| Owner | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| P256 Key X | `0x2b59c1d7df52300710294d12be4b0df8d35891aa972aaea93805f10f01053a6f` |
| P256 Key Y | `0xf9964ee6545613d77f16bedc3c63b2b16bee67e6bddecd194b259eb8f80229ae` |
| Creation TX | `0x1d872b6aba3814d8c5a6b77ac57583e237dd189720a308a0d7a0cb0449bdc49a` |
| P256 Reg TX | `0x70f2471b79e77b7920bf2c8855e71025a80d5588e4f32300745decf2ba697a0b` |

### Account C — ERC20 Token Guard Test (M5.1)

| Field | Value |
|-------|-------|
| Address | `0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC` |
| Salt | (auto, new deploy) |
| Token Guard | aPNTs — tier1=100, tier2=1000, daily=5000 (in aPNTs) |
| Creation TX | `0xf1f92f44a1658b9ced676fd72557e93a4618c6ea770763ae5bbc1d04d37ec905` |

---

## On-Chain E2E Test Results

### M5.3 — Guardian Acceptance Signature (6 Scenarios)

Script: `scripts/test-m5-guardian-accept-e2e.ts`

| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| A | Both guardians sign correctly | Account deployed | ✅ PASS |
| B | Sig from wrong guardian (typo simulation) | `GuardianDidNotAccept` | ✅ PASS |
| C | Zero address guardian | Revert "Guardians required" | ✅ PASS |
| D | Guardian signed for different owner | `GuardianDidNotAccept` | ✅ PASS |
| E | Guardian sig from different salt (replay) | `GuardianDidNotAccept` | ✅ PASS |
| F | `dailyLimit = 0` (M5.7) | Revert "Daily limit required" | ✅ PASS |

### M5.8 — ALG_COMBINED_T1 Zero-Trust (3 Scenarios)

Script: `scripts/test-m5-combined-t1-e2e.ts`

| # | Scenario | Expected | Result | Gas |
|---|----------|----------|--------|-----|
| A | Both P256 + ECDSA valid | UserOp succeeds | ✅ PASS | **162,081** |
| B | TE key only (fake P256) | Validation fails | ✅ PASS | — |
| C | ECDSA-only backward compat (algId=0x02) | UserOp succeeds | ✅ PASS | **114,403** |

### M5.1 — ERC20 Token Guard (2 Scenarios)

Script: `scripts/test-m5-erc20-guard-e2e.ts`

| # | Scenario | Expected | Result |
|---|----------|----------|--------|
| A | 50 aPNTs ECDSA (within tier1=100) | Transfer succeeds | ✅ PASS |
| B | 500 aPNTs ECDSA (exceeds tier1=100) | `InsufficientTokenTier(2,1)` | ✅ PASS |

### F67 — BLS Aggregator Integration (2 Steps)

Script: `scripts/test-m5-bls-aggregator-e2e.ts`

| # | Step | Expected | Result | Gas |
|---|------|----------|--------|-----|
| 1 | Deploy 2 accounts + `setAggregator` on each | `hasAggregator = true` | ✅ PASS | 47,757 × 2 |
| 2 | Single ECDSA UserOp on aggregator-configured account | UserOp succeeds | ✅ PASS | **137,528** |

- BLS Aggregator: `0x7700aec8a15a94db5697c581de8c88ecf83b59ff`
- Account 1 (salt=810): `0x5B037C9CEcCCFcD48c0552129Aca56D96F3D9cFE`
- Account 2 (salt=811): `0x272ed1D9b1eC6E2AeeEcD42Db290722E314e9645`

### Gasless E2E — M5 Factory

Script: `scripts/test-m5-gasless-e2e.ts`

| Phase | Step | Result | Key Data |
|-------|------|--------|---------|
| 0 | Create M5 account (salt=820) | ✅ | `0xe196792cB066...` |
| 1 | SBT + aPNTs + ETH funding | ✅ | SBT minted, 100 aPNTs minted |
| 2 | Build gasless UserOp (SuperPaymaster) | ✅ | paymasterAndData 72 bytes |
| 3 | Submit handleOps, verify zero ETH cost | ✅ PASS | Gas: **230,496**, ETH change: **0** |

- Gasless TX: `0x9b7ab29b9d9e8cbfea0f7db82718dd62f0dfcd3d9cf95d2c9182512f9a759778`
- Account: `0xe196792cB06602165d8922FB30E52708a1d90390`

**Total E2E: 15/15 scenarios PASS + F67 (2 steps) + Gasless (4 phases) all PASS**

---

## Gas Analysis

### Factory Deployment

| Operation | Gas | Notes |
|-----------|-----|-------|
| Deploy `AAStarAirAccountFactoryV7` | 5,302,643 | Includes embedded account + guard creation code |

### Account Creation (Unit Tests — Foundry)

| Method | Gas | Notes |
|--------|-----|-------|
| `createAccount` (minimal config) | ~2,797,000 | No token presets, no guardian sigs |
| `createAccount` (full config) | ~3,724,000 | With guard + algIds |
| `createAccountWithDefaults` | ~3,858,000–3,893,000 | Guardian sig verify + guard + 5 token presets |

> Unit test numbers include full EVM simulation overhead. On-chain numbers below are more accurate.

### UserOp Execution — On-Chain Sepolia

| Algorithm | algId | Sepolia Gas | Notes |
|-----------|-------|-------------|-------|
| ECDSA only (Tier 1) | 0x02 | **114,403** | Backward compatible path |
| ALG_COMBINED_T1 (Tier 1, zero-trust) | 0x06 | **162,081** | P256 precompile + ECDSA |
| P256 + BLS (Tier 2) | 0x04 | ~278,634* | From M4 E2E (unchanged in M5) |
| P256 + BLS + Guardian (Tier 3) | 0x05 | ~288,351* | From M4 E2E (unchanged in M5) |

*M4 values — M5 does not change T2/T3 validation paths.

### ALG_COMBINED_T1 Gas Breakdown (estimated)

| Component | Gas | Notes |
|-----------|-----|-------|
| EIP-7212 P256 precompile call | ~6,900 | `staticcall` to `0x100` |
| Assembly ECDSA `ecrecover` | ~3,000 | precompile at `0x01` |
| Signature decode + checks | ~500 | 130-byte parse |
| Guard checks (ETH + token) | ~5,000 | `checkTransaction` |
| `validateUserOp` overhead | ~10,000 | EntryPoint plumbing |
| `execute` call overhead | ~20,000 | Base EVM cost |
| **Total vs ECDSA-only overhead** | **+47,678** | 41.7% more gas for zero-trust guarantee |

### ERC20 Guard Overhead (per checkTokenTransaction)

| Scenario | Gas (unit test) | Notes |
|----------|-----------------|-------|
| Unconfigured token (passthrough) | ~22,300 | 1 SLOAD miss |
| Tier 1 check (within limit) | ~47,000–47,500 | 2 SLOADs + 1 SSTORE |
| Tier 2/3 check | ~47,500–70,000 | Cumulative spend + tier comparison |
| Daily limit exceeded (revert) | ~25,000 | Fails fast before SSTORE |
| Batch bypass attempt (cumulative) | ~51,000–51,500 | `tokenDailySpent` accumulates |

### Guard Function Gas (unit tests)

| Function | Min | Avg | Max | Notes |
|----------|-----|-----|-----|-------|
| `checkTransaction` (ETH) | 21,926 | 39,653 | 50,473 | Including SSTORE on spend |
| `checkTokenTransaction` (ERC20) | 30,782 | 45,314 | 55,970 | Tier + daily check |
| `addTokenConfig` | 21,925 | 51,368 | 91,280 | One-time config write |
| `approveAlgorithm` | 21,678 | 37,783 | 44,985 | One SSTORE |
| `decreaseDailyLimit` | 21,617 | 25,599 | 27,973 | One SSTORE |

### Validator Function Gas (unit tests)

| Function | Min | Avg | Max | Notes |
|----------|-----|-----|-----|-------|
| `validateUserOp` | 24,476 | 38,437 | 68,638 | Base validation |
| `execute` | 25,027 | 58,732 | 105,154 | Includes guard checks |
| `executeBatch` | 26,422 | 59,239 | 143,223 | Multiple calls |

### M5 vs M4 Gas Comparison

| Milestone | Operation | Gas | Change |
|-----------|-----------|-----|--------|
| M4 | Tier 1 ECDSA | 140,352 | baseline |
| M5 | Tier 1 ECDSA (algId=0x02) | ~114,403 | **-18.5%** (assembly ecrecover) |
| M5 | Tier 1 ALG_COMBINED_T1 (0x06) | 162,081 | +15.5% vs M4 ECDSA for zero-trust |
| M4 | Tier 2 P256+BLS | 278,634 | baseline |
| M5 | Tier 2 P256+BLS | ~278,634 | unchanged |
| M4 | Tier 3 P256+BLS+Guardian | 288,351 | baseline |
| M5 | Tier 3 P256+BLS+Guardian | ~288,351 | unchanged |

> The ECDSA gas improvement in M5 comes from replacing `ECDSA.recover()` with a direct inline assembly `ecrecover` precompile call, eliminating OZ library overhead (~26k gas savings).

---

## Token Presets (Standard Profile — Sepolia)

Reference config from `configs/token-presets.json`. **Not auto-populated at deploy** — tokens are configured post-deploy by calling `guardAddTokenConfig` on each account. The addresses below are the Sepolia values to use.

| Token | Address (Sepolia) | Tier 1 | Tier 2 | Daily |
|-------|-------------------|--------|--------|-------|
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | 500 USDC | 5,000 USDC | 10,000 USDC |
| USDT | `0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0` | 500 USDT | 5,000 USDT | 10,000 USDT |
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` | 0.5 WETH | 5 WETH | 10 WETH |
| WBTC | `0x29f2D40B0605204364af54EC677bD022dA425d03` | 0.05 WBTC | 0.5 WBTC | 1 WBTC |
| aPNTs | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` | 500 aPNTs | 5,000 aPNTs | 10,000 aPNTs |

All configs satisfy: `tier1Limit ≤ tier2Limit ≤ dailyLimit` (enforced by `_validateTokenConfig`).

---

## Unit Test Results

All tests run with `forge test --summary`:

| Suite | Tests | Status |
|-------|-------|--------|
| `AAStarAirAccountV7Test` | 15 | ✅ All pass |
| `AAStarAirAccountV7_M2Test` | 11 | ✅ All pass |
| `AAStarAirAccountV7M3Test` | 22 | ✅ All pass |
| `AAStarAirAccountM5_4Test` | 6 | ✅ All pass |
| `AAStarAirAccountM5_8Test` | 7 | ✅ All pass |
| `AAStarBLSAggregatorTest` | 13 | ✅ All pass |
| `AAStarBLSAlgorithmTest` | 25 | ✅ All pass |
| `AAStarBLSAlgorithmM3Test` | 6 | ✅ All pass |
| `AAStarGlobalGuardTest` | 26 | ✅ All pass |
| `AAStarGlobalGuardM5Test` | 29 | ✅ All pass |
| `AAStarValidatorTest` | 19 | ✅ All pass |
| `AAStarValidatorM3Test` | 16 | ✅ All pass |
| `CumulativeSignatureTest` | 8 | ✅ All pass |
| `M5ScenarioTests` | 22 | ✅ All pass |
| `SocialRecoveryTest` | 37 | ✅ All pass |
| `AAStarAirAccountFactoryV7Test` | 16 | ✅ All pass |
| **Total** | **280** | **✅ 0 failed** |

---

## Signature Format Reference

### ALG_COMBINED_T1 (0x06) — 130 bytes

```
[algId(1)][P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]
   0x06  +    32     +    32     +    32      +    32      +    1       = 130 bytes

P256 signs:  userOpHash  (raw, no EIP-191 prefix)
ECDSA signs: keccak256("\x19Ethereum Signed Message:\n32" || userOpHash)
```

### ALG_CUMULATIVE_T2 (0x04) — variable

```
[algId(1)][P256_r(32)][P256_s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][mpSig(65)]
```

### ALG_CUMULATIVE_T3 (0x05) — variable

```
[algId(1)][P256_r(32)][P256_s(32)][nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][mpSig(65)][guardianIdx(1)][guardianSig(65)]
```

### messagePoint Binding (M5.2 fix)

```solidity
// Before M5.2 (vulnerable to cross-UserOp replay):
bytes32 mpHash = keccak256(messagePoint).toEthSignedMessageHash();

// After M5.2 (binds to specific UserOp):
bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
```

---

## Supported Deployment Chains

Both EIP-7212 (P256, `0x100`) and EIP-2537 (BLS, `0x0b`/`0x0f`) are required. No fallback.

| Chain | EIP-7212 (P256) | EIP-2537 (BLS) | Deploy Status |
|-------|-----------------|----------------|---------------|
| Sepolia testnet | ✅ | ✅ | ✅ **Deployed** |
| Ethereum mainnet | ✅ Fusaka 2025-12-03 | ✅ Pectra 2025-05-07 | Planned |
| Base | ✅ Fjord 2024-07-10 | ✅ Isthmus 2025-05-09 | Planned |
| Optimism | ✅ Fjord 2024-07-10 | ✅ Isthmus 2025-05-09 | Planned |
| Arbitrum One | ✅ ArbOS 31 ~2024 Q3 | ✅ ArbOS 51 2026-01-08 | Planned |

---

## Key Environment Variables (`.env.sepolia`)

```bash
AIRACCOUNT_M5_FACTORY=0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9
FACTORY_ADDRESS=0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9
AIRACCOUNT_M5_ACCOUNT_GUARDIAN_TEST=0x866E6B61211f82931dd0a6D9134b4836FA40C15a
AIRACCOUNT_M5_ACCOUNT_COMBINED_T1=0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32
AIRACCOUNT_M5_ACCOUNT_ERC20_GUARD=0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC
```

---

## Known Gaps (Deferred to M6 or Later)

| Item | Status | Reason | Reference |
|------|--------|--------|-----------|
| F57: Frontend guardian onboarding flow | ❌ Deferred | Out of contract repo scope | M5.3 |
| F62: Multi-chain deployment script | ❌ Deferred | Sepolia only; mainnet/L2 pending | M5.4 |
| F67: BLS aggregator `setAggregator` | ✅ Done | Deployed + configured on test accounts | M5.6 |
| F68: SDK `handleAggregatedOps` bundler | ❌ Deferred | Requires off-chain bundler infrastructure | M5.6 |
| F69: NodeId compression (bytes32→uint8) | ❌ Deferred | Contract change; modest savings; breaks sig format | M5.6 |
| F70: E2E batch gas benchmark | ✅ Done (partial) | Single UserOp benchmark done; full batch needs F68 | M5.6 |
| Gasless E2E re-run with M5 factory | ✅ Done | `scripts/test-m5-gasless-e2e.ts` — M5 factory + new account | Post-M5 |

---

## Previous Milestone References

| Milestone | Factory | Notes |
|-----------|---------|-------|
| M1 (ECDSA E2E) | N/A | YetAnotherAA factory used |
| M2 (BLS) | `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` | BLS triple signature |
| M3 (Security) | `0xce4231da69015273819b6aab78d840d62cf206c1` | Gas −51% vs M2 |
| M4 (Cumulative) | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | Tiered sigs + social recovery |
| **M5 (ERC20 Guard)** | **`0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9`** | **Current** |

---

*Last updated: 2026-03-13*
*Deploy script: `scripts/deploy-m5.ts`*
*E2E scripts: `scripts/test-m5-*.ts`*
