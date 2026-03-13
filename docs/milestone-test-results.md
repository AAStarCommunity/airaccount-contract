# AirAccount v0.12.5 Milestone Test Results

> This document records all test evidence (unit tests, E2E on-chain transactions) for each milestone.
> Serves as the official verification record for milestone completion.

---

## Milestone 1: Core Account + ECDSA E2E

**Branch**: `v0.12.5`
**Tag**: `v0.12.5-m1`
**Date**: 2026-03-09
**Network**: Sepolia (chainId: 11155111)
**EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

### Features Completed

| # | Feature | Status |
|---|---------|--------|
| F05 | Foundry project init (`foundry.toml`, remappings) | ✅ |
| F01 | `IAAStarValidator` / `IAAStarAlgorithm` interfaces | ✅ |
| F02 | `AAStarAirAccountBase` (execute/executeBatch + inline ECDSA) | ✅ |
| F03 | `AAStarAirAccountV7` (EntryPoint v0.7 wrapper) | ✅ |
| F04 | `AAStarAirAccountFactoryV7` (CREATE2 factory) | ✅ |
| F06 | Unit tests (22 tests, 0 failures) | ✅ |
| F07 | Sepolia deployment script | ✅ |
| F08 | E2E: ECDSA UserOp → handleOps on-chain | ✅ |

---

### Unit Test Results

**Command**: `forge test -v`
**Result**: 22 passed, 0 failed, 0 skipped

#### AAStarAirAccountV7Test (15 tests)

| Test | Gas | Result |
|------|-----|--------|
| `test_validateUserOp_validSignature` | 20,036 | ✅ PASS |
| `test_validateUserOp_invalidSignature` | 19,883 | ✅ PASS |
| `test_validateUserOp_onlyEntryPoint` | 15,785 | ✅ PASS |
| `test_validateUserOp_paysPrefund` | 29,375 | ✅ PASS |
| `test_execute_fromEntryPoint` | 48,058 | ✅ PASS |
| `test_execute_fromOwner` | 47,983 | ✅ PASS |
| `test_execute_fromUnauthorized` | 13,066 | ✅ PASS |
| `test_executeBatch_success` | 126,453 | ✅ PASS |
| `test_executeBatch_arrayMismatch` | 13,551 | ✅ PASS |
| `test_executeBatch_arrayMismatch_funcs` | 14,019 | ✅ PASS |
| `test_addDeposit` | 45,711 | ✅ PASS |
| `test_withdrawDepositTo_notOwner` | 52,068 | ✅ PASS |
| `test_withdrawDepositTo` | 90,799 | ✅ PASS |
| `test_receiveEth` | 12,421 | ✅ PASS |
| `test_immutableState` | 11,211 | ✅ PASS |

#### AAStarAirAccountFactoryV7Test (7 tests)

| Test | Gas | Result |
|------|-----|--------|
| `test_createAccount` | 722,370 | ✅ PASS |
| `test_createAccount_deterministic` | 722,175 | ✅ PASS |
| `test_getAddress_matchesCreated` | 721,655 | ✅ PASS |
| `test_createAccount_differentOwners` | 1,430,989 | ✅ PASS |
| `test_createAccount_differentSalts` | 1,428,769 | ✅ PASS |
| `test_createAccount_emitsEvent` | 726,825 | ✅ PASS |
| `test_factoryEntryPoint` | 7,838 | ✅ PASS |

---

### E2E Test Results (Sepolia On-Chain)

**Script**: `scripts/test-e2e-ecdsa.ts` (via `bash test-e2e-ecdsa.sh`)
**Deployer/Signer**: `0xb5600060e6de5E11D3636731964218E53caadf0E`
**Deployer Balance**: 8.854 ETH (at time of test)

#### Step 1: Factory Deployment

| Field | Value |
|-------|-------|
| Contract | `AAStarAirAccountFactoryV7` |
| Address | `0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f` |
| Etherscan | https://sepolia.etherscan.io/address/0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f |

#### Step 2: Account Creation

| Field | Value |
|-------|-------|
| Contract | `AAStarAirAccountV7` |
| Account Address | `0x08923CE682336DF2f238C034B4add5Bf73d4028A` |
| Owner | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Owner Verified | ✅ |
| Creation Tx | `0xe35e428c992297788cea807490c8e9af050c5268d55957413446788fe7225ae6` |
| Etherscan | https://sepolia.etherscan.io/tx/0xe35e428c992297788cea807490c8e9af050c5268d55957413446788fe7225ae6 |

#### Step 3: EntryPoint Deposit + Account Funding

| Field | Value |
|-------|-------|
| Deposit Amount | 0.01 ETH |
| Deposit Tx | `0x2c47969a98fc0dfcbc66ffd6b5de736ac443c0decc5f3d1088efc86c8540d45c` |
| Etherscan | https://sepolia.etherscan.io/tx/0x2c47969a98fc0dfcbc66ffd6b5de736ac443c0decc5f3d1088efc86c8540d45c |
| Account Fund Amount | 0.005 ETH |
| Fund Tx | `0xc38328b981e7123a6bdc4df62cc4890309b8243c758ba0a6ec9d9f45800e1868` |
| Etherscan | https://sepolia.etherscan.io/tx/0xc38328b981e7123a6bdc4df62cc4890309b8243c758ba0a6ec9d9f45800e1868 |

#### Step 4: UserOp Construction

| Field | Value |
|-------|-------|
| Nonce | 0 |
| callData | `execute(0x...dEaD, 0.001 ETH, 0x)` |
| verificationGasLimit | 500,000 |
| callGasLimit | 200,000 |
| preVerificationGas | 60,000 |
| maxPriorityFee | 0.001000003 gwei |
| maxFeePerGas | 0.009617203 gwei |

#### Step 5: ECDSA Signature

| Field | Value |
|-------|-------|
| userOpHash | `0x22508f9ee6ac8615f5da5f65eee4cd09f330d11e8e4454c9917b47cfdcea5504` |
| Signature Length | 65 bytes |
| Signature (prefix) | `0x18f1cd48be6442805b17...` |

#### Step 6: handleOps Submission

| Field | Value |
|-------|-------|
| Gas Estimate | 295,848 |
| Gas Used | 97,258 |
| Block | 10,414,752 |
| **Tx Hash** | **`0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81`** |
| **Etherscan** | **https://sepolia.etherscan.io/tx/0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81** |

#### Step 7: Verification

| Field | Value |
|-------|-------|
| Recipient | `0x000000000000000000000000000000000000dEaD` |
| Recipient Balance Before | 2,359.341030431844027603 ETH |
| Recipient Balance After | 2,359.342030431844027603 ETH |
| **Amount Received** | **0.001 ETH ✅** |
| Account Deposit After | 0.009999261348279952 ETH |

---

### Key Transaction Summary

| Step | Tx Hash | Etherscan Link |
|------|---------|---------------|
| Factory Deploy | `0xe35e42...` (in creation tx) | [View](https://sepolia.etherscan.io/address/0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f) |
| Account Create | `0xe35e428c9922...fe7225ae6` | [View](https://sepolia.etherscan.io/tx/0xe35e428c992297788cea807490c8e9af050c5268d55957413446788fe7225ae6) |
| EP Deposit | `0x2c47969a98fc...8540d45c` | [View](https://sepolia.etherscan.io/tx/0x2c47969a98fc0dfcbc66ffd6b5de736ac443c0decc5f3d1088efc86c8540d45c) |
| Account Fund | `0xc38328b981e7...800e1868` | [View](https://sepolia.etherscan.io/tx/0xc38328b981e7123a6bdc4df62cc4890309b8243c758ba0a6ec9d9f45800e1868) |
| **handleOps** | **`0x8bb1b199f427...d81d77a81`** | [**View**](https://sepolia.etherscan.io/tx/0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81) |

---

### Contract Source Files (M1)

| File | Lines | Description |
|------|-------|-------------|
| `src/interfaces/IAAStarValidator.sol` | ~15 | Validator router interface |
| `src/interfaces/IAAStarAlgorithm.sol` | ~10 | Algorithm implementation interface |
| `src/core/AAStarAirAccountBase.sol` | ~176 | Abstract base: ECDSA validation, execute, deposit mgmt |
| `src/core/AAStarAirAccountV7.sol` | ~25 | EntryPoint v0.7 thin wrapper |
| `src/core/AAStarAirAccountFactoryV7.sol` | ~51 | CREATE2 factory |
| `test/AAStarAirAccountV7.t.sol` | — | 15 unit tests |
| `test/AAStarAirAccountFactoryV7.t.sol` | — | 7 unit tests |
| `script/DeployAirAccountV7.s.sol` | — | Foundry deploy script |
| `scripts/test-e2e-ecdsa.ts` | ~360 | E2E test script |

---

## Milestone 2: BLS Migration + YetAA Replacement

**Branch**: `v0.12.5`
**Tag**: `v0.12.5-m2`
**Date**: 2026-03-09
**Solidity**: 0.8.33, optimizer 10,000 runs, Cancun EVM

### Features Completed

| # | Feature | Status |
|---|---------|--------|
| F09 | `AAStarBLSAlgorithm` — BLS verification + assembly optimization | ✅ |
| F10 | `AAStarValidator` — algId router + algorithm registry | ✅ |
| F11 | `AAStarAirAccountBase` — algId routing (inline ECDSA + external BLS) | ✅ |
| F12 | Triple signature (ECDSA×2 + BLS aggregate) | ✅ |
| F13 | Node management (ABI-compatible with YetAA NestJS) | ✅ |
| F14 | Assembly optimization (mstore, calldatacopy) | ✅ |
| F15 | Sepolia deployment | ✅ |
| F17 | BLS E2E: Triple-sig UserOp → handleOps on-chain | ✅ |

### Unit Test Results

**Command**: `forge test`
**Result**: 71 passed, 0 failed, 0 skipped

| Test Suite | Tests | Status |
|------------|-------|--------|
| AAStarAirAccountV7Test (M1) | 15 | ✅ |
| AAStarAirAccountFactoryV7Test (M1) | 7 | ✅ |
| AAStarValidatorTest (M2) | 13 | ✅ |
| AAStarBLSAlgorithmTest (M2) | 25 | ✅ |
| AAStarAirAccountV7_M2Test (M2) | 11 | ✅ |

### Deployed Addresses (Sepolia, Solc 0.8.33)

| Contract | Address |
|----------|---------|
| AAStarBLSAlgorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` |
| AAStarValidator (router) | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` |
| AAStarAirAccountFactoryV7 | `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` |
| AA Account (salt=1) | `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07` |

### E2E Test Results (Sepolia On-Chain)

**Script**: `scripts/test-e2e-bls.ts` (viem + @noble/curves)
**Deployer/Signer**: `0xb5600060e6de5E11D3636731964218E53caadf0E`

#### BLS Node Registration

| Node | Node ID | Registration Tx |
|------|---------|----------------|
| Node 1 | `0xb548c8...506a6d` | `0x215d79b3258c3dcbacd8e3238da0685505c3f3b55f76da8b7cf48009465a9c16` |
| Node 2 | `0x7f7e62...a9537c` | `0x88285b304ae46bcda44cfd99a62ef4850c9eedced391efccf169d0d06a654080` |

#### Account Setup

| Step | Tx Hash |
|------|---------|
| Account Create (salt=1) | `0x5642b1f0298bb1b962bc638e584d38108800a99bd5a1a5349c9fd2e517b37f72` |
| Set Validator | `0xa1e36274532b7715eab5ab055d866b6606d21b50eef47ffd09a8d8ed455efd55` |
| EP Deposit (0.01 ETH) | `0x96ed12dc8d19c1b674ff6f3586f6c910f077a746809dc12c8a5b74acc131d37b` |
| Fund Account (0.005 ETH) | `0xb503c143e26de57fe8e120621eb4c01a1dd0fdbf56e4b5b186b1235795e4a215` |

#### Triple Signature Construction

| Field | Value |
|-------|-------|
| userOpHash | `0x7ca8923f12d32f47dc94eecae2b45c78ec2d311c16e9a421eed9f6bd3f882613` |
| BLS signing scheme | Long (G2 signatures, G1 public keys) |
| BLS dry-run verification | **VALID** ✅ |
| Signature length | 739 bytes (1 algId + 32 count + 2×32 nodeIds + 256 blsSig + 256 msgPoint + 65 aaSig + 65 mpSig) |

#### handleOps Submission

| Field | Value |
|-------|-------|
| Gas Estimate | 456,896 |
| **Gas Used** | **259,694** |
| Block | 10,414,886 |
| **Tx Hash** | **`0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff`** |
| **Etherscan** | **https://sepolia.etherscan.io/tx/0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff** |

### Gas Comparison: AirAccount vs YetAnotherAA

| Metric | YetAnotherAA | AirAccount M2 | Improvement |
|--------|-------------|---------------|-------------|
| handleOps total | 523,306 gas | **259,694 gas** | **-50.4%** |
| BLS verification (estimated) | ~407,730 gas | ~160,000 gas | ~-60% |
| Assembly optimization | byte-by-byte copy | mstore/calldatacopy | Eliminated ~300k overhead |

### Contract Source Files (M2)

| File | Description |
|------|-------------|
| `src/validators/AAStarBLSAlgorithm.sol` | BLS verification + node management (assembly optimized) |
| `src/validators/AAStarValidator.sol` | Generic algorithm router (algId-based) |
| `src/core/AAStarAirAccountBase.sol` | Updated: algId routing, triple signature, validator config |
| `test/AAStarValidator.t.sol` | 13 tests: registration, routing, ownership |
| `test/AAStarBLSAlgorithm.t.sol` | 25 tests: node mgmt, input validation, gas estimate |
| `test/AAStarAirAccountV7_M2.t.sol` | 11 tests: ECDSA compat, algId routing, triple sig |
| `scripts/test-e2e-bls.ts` | BLS E2E (viem + @noble/curves) |
| `script/DeployFullSystem.s.sol` | Foundry deployment script |

---

## Milestone 3: AirAccount Features

**Branch**: `v0.12.5`
**Date**: 2026-03-10
**Status**: ✅ Complete

### Features Completed

| # | Feature | Status |
|---|---------|--------|
| F20 | `AAStarGlobalGuard` — immutable spending guard (ETH daily limit) | ✅ |
| F21 | Guard monotonic: limit only decreases | ✅ |
| F22 | Social recovery: 2-of-3 guardian threshold + timelock | ✅ |
| F23 | `createAccountWithDefaults`: guardian non-zero validation | ✅ |
| F24 | P256 passkey registration (`setP256Key`) | ✅ |
| F25 | `AAStarValidator` governance: 7-day timelock for algorithm changes | ✅ |
| F26 | Gasless E2E via SuperPaymaster (aPNTs as gas token) | ✅ |

### Unit Test Results

**Result**: 97 passed, 0 failed, 0 skipped

| Suite | Tests | Status |
|-------|-------|--------|
| AAStarAirAccountV7Test | 15 | ✅ |
| AAStarAirAccountV7_M2Test | 11 | ✅ |
| AAStarAirAccountV7M3Test | 22 | ✅ |
| AAStarValidatorTest | 13 | ✅ |
| AAStarValidatorM3Test | 16 | ✅ |
| AAStarBLSAlgorithmTest | 25 | ✅ |
| AAStarGlobalGuardTest | 26 | ✅ |

### Deployed Addresses (Sepolia)

| Contract | Address |
|----------|---------|
| AirAccount Factory V7 (M3) | `0xce4231da69015273819b6aab78d840d62cf206c1` |
| M3 Test Account | `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` |

### E2E Tests (Sepolia)

| Test | Result | TX / Notes |
|------|--------|------------|
| M3 ECDSA UserOp | ✅ PASS | Gas: 127,249 (-51% vs M2) |
| Gasless (SuperPaymaster + aPNTs) | ✅ PASS | ETH unchanged; aPNTs deducted as gas |

**Reference**: `docs/gasless-e2e-test-report.md`, `docs/test-m3-report-result.md`

---

## Milestone 4: Cumulative Signatures + Social Recovery

**Branch**: `v0.12.5`
**Date**: 2026-03-11
**Status**: ✅ Complete

### Features Completed

| # | Feature | Status |
|---|---------|--------|
| F30 | Cumulative Tier 2: `ALG_T2 (0x04)` — P256 + BLS dual factor | ✅ |
| F31 | Cumulative Tier 3: `ALG_T3 (0x05)` — P256 + BLS + Guardian | ✅ |
| F32 | `_algTier()` mapping: 0x01/0x03/0x04→Tier2, 0x02→Tier1, 0x05→Tier3 | ✅ |
| F33 | Social recovery: `proposeRecovery` + `approveRecovery` + `executeRecovery` | ✅ |
| F34 | Recovery timelock (48h) + 2-of-3 threshold | ✅ |
| F35 | Transient storage queue for cross-boundary algId passing | ✅ |
| F36 | `registerPublicKey` restricted to `onlyOwner` | ✅ |
| F37 | `setTierLimits` validates `tier1 <= tier2` | ✅ |

### Unit Test Results

**Result**: 200+ passed, 0 failed

| Suite | Tests | Status |
|-------|-------|--------|
| CumulativeSignatureTest | 8 | ✅ |
| SocialRecoveryTest | 37 | ✅ |
| AAStarAirAccountV7M3Test | 22 | ✅ |
| All prior suites | — | ✅ |

### Deployed Addresses (Sepolia)

| Contract | Address |
|----------|---------|
| AirAccount Factory V7 (M4) | `0x914db0a849f55e68a726c72fd02b7114b1176d88` |
| Tier test account (salt=400) | `0x117C702AC0660B9A8f4545c8EA9c92933E6925d7` |

### E2E Gas Results (Sepolia)

| Algorithm | Gas Used | Notes |
|-----------|----------|-------|
| Tier 1 ECDSA (0x02) | **140,352** | Single ECDSA sig |
| Tier 2 P256+BLS (0x04) | **278,634** | Dual factor |
| Tier 3 P256+BLS+Guardian (0x05) | **288,351** | Triple factor |
| Social Recovery (full flow) | **395,570** | 2-of-3 guardians, 48h timelock |

**5 tiered tests + 5 social recovery tests ALL PASSED on Sepolia**

---

## Milestone 5: ERC20 Guard + Zero-Trust Tier 1

**Branch**: `M5`
**Date**: 2026-03-13
**Status**: ✅ Complete

### Features Completed

| # | Feature | Status |
|---|---------|--------|
| F47-F53 | M5.1 ERC20 Token Guard (per-token tier/daily limits) | ✅ |
| F54-F55 | M5.2 Governance hardening (setupComplete + messagePoint binding) | ✅ |
| F56, F58 | M5.3 Guardian acceptance signatures | ✅ |
| F59-F61 | M5.4 Chain compatibility (fail-fast, no fallback) | ✅ |
| F71-F73 | M5.7 Force guard (dailyLimit > 0 required) | ✅ |
| F74-F79 | M5.8 ALG_COMBINED_T1 (0x06): P256 + ECDSA zero-trust | ✅ |
| F67 | M5.6 BLS aggregator: deploy + setAggregator | ✅ |
| — | dailyLimit ≥ tier2Limit invariant fix | ✅ |
| — | Token presets (conservative/standard/trader) | ✅ |
| — | Gasless E2E re-run with M5 factory | ✅ |

### Unit Test Results

**Command**: `forge test --summary`
**Result**: **280/280 passed**, 0 failed, 0 skipped (16 suites)

| Suite | Tests | Status |
|-------|-------|--------|
| AAStarAirAccountV7Test | 15 | ✅ |
| AAStarAirAccountV7_M2Test | 11 | ✅ |
| AAStarAirAccountV7M3Test | 22 | ✅ |
| AAStarAirAccountM5_4Test | 6 | ✅ |
| AAStarAirAccountM5_8Test | 7 | ✅ |
| AAStarBLSAggregatorTest | 13 | ✅ |
| AAStarBLSAlgorithmTest | 25 | ✅ |
| AAStarBLSAlgorithmM3Test | 6 | ✅ |
| AAStarGlobalGuardTest | 26 | ✅ |
| AAStarGlobalGuardM5Test | 29 | ✅ |
| AAStarValidatorTest | 19 | ✅ |
| AAStarValidatorM3Test | 16 | ✅ |
| CumulativeSignatureTest | 8 | ✅ |
| M5ScenarioTests | 22 | ✅ |
| SocialRecoveryTest | 37 | ✅ |
| AAStarAirAccountFactoryV7Test | 16 | ✅ |

### Deployed Addresses (Sepolia)

| Contract | Address | Deploy Tx | Gas |
|----------|---------|-----------|-----|
| AirAccount Factory V7 (M5) | `0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9` | `0xaca946016fe2...453a` | 5,302,643 |
| AAStarBLSAggregator | `0x7700aec8a15a94db5697c581de8c88ecf83b59ff` | `0x5b6de23a144b...c0a27` | 855,052 |

### E2E Test Results (Sepolia)

| Test | Scenarios | Result | Key Gas |
|------|-----------|--------|---------|
| M5.3 Guardian Acceptance | 6/6 | ✅ ALL PASS | — |
| M5.8 ALG_COMBINED_T1 | 3/3 | ✅ ALL PASS | 162,081 (zero-trust) / 114,403 (ECDSA) |
| M5.1 ERC20 Guard | 2/2 | ✅ ALL PASS | — |
| F67 BLS Aggregator | 2 steps | ✅ ALL PASS | 47,757 (setAggregator) |
| Gasless E2E (M5 factory) | 4 phases | ✅ ALL PASS | 230,496 (bundler), 0 ETH account cost |

### Gas Comparison: M4 → M5

| Operation | M4 Gas | M5 Gas | Change |
|-----------|--------|--------|--------|
| Tier 1 ECDSA | 140,352 | **114,403** | **-18.5%** |
| Tier 1 ALG_COMBINED_T1 | — | **162,081** | New feature |
| Tier 2 P256+BLS | 278,634 | ~278,634 | Unchanged |
| Tier 3 P256+BLS+Guard | 288,351 | ~288,351 | Unchanged |
| Gasless (bundler) | ~200k | **230,496** | ERC20 guard overhead |

**Reference**: `docs/m5-deployment-record.md`
