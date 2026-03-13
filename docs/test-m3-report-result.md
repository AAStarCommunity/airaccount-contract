# AirAccount v0.12.5 M3 Test Report

> Network: **Sepolia Testnet** (chainId: 11155111)
> Date: 2026-03-09
> Branch: `v0.12.5`
> Commit: `5ba83a5`

---

## 1. Deployed Contract Addresses

### AirAccount Core (deployed by this project)

| Contract | Address | Deploy TX |
|----------|---------|-----------|
| AAStarBLSAlgorithm | `0xc2096e8d04beb3c337bb388f5352710d62de0287` | [`0xfc531b54...`](https://sepolia.etherscan.io/tx/0xfc531b5436b13c3f6df8180e42c6060f394908d5fde0cc70ef99b26b6b0ba3f9) |
| AAStarValidator | `0x730a162ce3202b94cc5b74181b75b11ebb3045b1` | [`0x8f482928...`](https://sepolia.etherscan.io/tx/0x8f482928ac6f7269390efebfc8082f733bc0bf25b5f793aa5c202d4aa1fabe79) |
| AAStarAirAccountFactoryV7 | `0x5ba18c50e0375fb84d6d521366069fe9140afe04` | [`0x0c514d7b...`](https://sepolia.etherscan.io/tx/0x0c514d7b97bbe16fa671f645e52074e7260643bdc09b13c2c9821a9661d2e53b) |
| AA Account (E2E test) | `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07` | [`0x5642b1f0...`](https://sepolia.etherscan.io/tx/0x5642b1f0298bb1b962bc638e584d38108800a99bd5a1a5349c9fd2e517b37f72) (createAccount via factory) |

### YetAnotherAA-Validator (M1 baseline, submodule deployment)

| Contract | Address | Deploy TX |
|----------|---------|-----------|
| Validator (YetAA) | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` | — (deployed from submodule) |
| Factory (YetAA) | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` | [`0x01cf479f...`](https://sepolia.etherscan.io/tx/0x01cf479fd0ddbe263ab2ef8dc2dc02bab39abeeb3fd2c5fffe7f98cfd097bb87) |
| Implementation (YetAA) | `0xab7d9A8Ab9e835c5C7D82829E32C10868558E0F8` | — |
| AA Account #1 (M1 E2E) | `0x30662d826926F4e3d6A453610CA2A0266F69C085` | [`0x01cf479f...`](https://sepolia.etherscan.io/tx/0x01cf479fd0ddbe263ab2ef8dc2dc02bab39abeeb3fd2c5fffe7f98cfd097bb87) (createAccount) |

### AAStar Ecosystem (from aastar-sdk config.sepolia.json)

| Contract | Address | Verified |
|----------|---------|----------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | on-chain ✓ |
| SuperPaymaster | `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A` | on-chain ✓ |
| PaymasterV4 | `0x67a70a578E142b950987081e7016906ae4F56Df4` | on-chain ✓ |
| aPNTs Token | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` | on-chain ✓ |
| GToken | `0x9ceDeC089921652D050819ca5BE53765fc05aa9E` | on-chain ✓ |
| MySBT | `0x677423f5Dad98D19cAE8661c36F094289cb6171a` | on-chain ✓ |
| Registry | `0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788` | on-chain ✓ |
| xPNTs Factory | `0x6EafdA3477F3eec1F848505e1c06dFB5532395b6` | on-chain ✓ |
| GTokenStaking | `0x1118eAf2427a5B9e488e28D35338d22EaCBc37fC` | on-chain ✓ |

---

## 2. Test Accounts

| Role | Address | Description |
|------|---------|-------------|
| Deployer / Operator / EOA Bundler | `0xb5600060e6de5E11D3636731964218E53caadf0E` | Deploys all contracts, acts as operator in SuperPaymaster, submits UserOps |
| AA Account (M2/M3 E2E) | `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07` | ERC-4337 smart wallet, created via AirAccount factory |
| AA Account (M1 baseline) | `0x30662d826926F4e3d6A453610CA2A0266F69C085` | YetAnotherAA-Validator baseline test account |
| Recipient (burn) | `0x000000000000000000000000000000000000dEaD` | Transfer target for E2E tests |

### BLS Test Nodes

| Node | Node ID | Registered On |
|------|---------|---------------|
| Node 1 | `0xb548c8e23d2df1158ebb19fe07eb1ac4d9c47f13b3c9d3aed83b206930506a6d` | Validator |
| Node 2 | `0x7f7e6290d0588435c6d12093b420fafc5b4c7ab23c73645ca7186189dca9537c` | Validator |

---

## 3. E2E Test Results (Sepolia On-Chain)

### M1: ECDSA E2E (YetAnotherAA-Validator baseline)

**AA Account**: `0x30662d826926F4e3d6A453610CA2A0266F69C085`

| Step | TX Hash | Block | Gas | Status |
|------|---------|-------|-----|--------|
| createAccount | [`0x01cf479f...`](https://sepolia.etherscan.io/tx/0x01cf479fd0ddbe263ab2ef8dc2dc02bab39abeeb3fd2c5fffe7f98cfd097bb87) | 10412568 | 207,774 | ✓ |
| Register BLS Node 1 | [`0x484d080a...`](https://sepolia.etherscan.io/tx/0x484d080abc3c1fa4c645004563b9f67be67b7103b539906bb5b42e721de05969) | 10412576 | 205,249 | ✓ |
| Register BLS Node 2 | [`0x3fbd66fb...`](https://sepolia.etherscan.io/tx/0x3fbd66fba288f52a9b982fbb6e3d38cdf07e2ffd77a24efd5ceed995022ed3c2) | 10412587 | 188,161 | ✓ |
| depositTo EntryPoint | [`0xe5b471b9...`](https://sepolia.etherscan.io/tx/0xe5b471b9422042532b16c5d9e668f347002e9bae7e73996582f003cfaf074650) | 10412961 | 45,599 | ✓ |
| handleOps (attempt 1) | [`0xa360b357...`](https://sepolia.etherscan.io/tx/0xa360b357e295673072bd08fcb15824c0e1bdf6a4d39d2db53f2db27eda354079) | 10412962 | 540,549 | ✓ outer, ✗ inner |
| Fund AA with ETH | [`0x12c032ce...`](https://sepolia.etherscan.io/tx/0x12c032cef26cf57dfbd5f5917e32f134a63a6cfa47b1d8d5283cd45485b03557) | 10412970 | 25,863 | ✓ |
| **handleOps (SUCCESS)** | [`0x2d9e841d...`](https://sepolia.etherscan.io/tx/0x2d9e841d46d8090e065943b88a46c2c9be0a09ccd5ec3ff99b336ae2cb8bd173) | **10412972** | **523,306** | **✓** |

**Result**: M1 ECDSA E2E on YetAA baseline: **523,306 gas**

---

### M2: BLS Triple-Sig E2E (AirAccount new contracts)

**AA Account**: `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07`

| Step | TX Hash | Block | Gas | Status |
|------|---------|-------|-----|--------|
| Deploy BLSAlgorithm | [`0xfc531b54...`](https://sepolia.etherscan.io/tx/0xfc531b5436b13c3f6df8180e42c6060f394908d5fde0cc70ef99b26b6b0ba3f9) | 10414874 | 1,405,249 | ✓ |
| Deploy Validator | [`0x8f482928...`](https://sepolia.etherscan.io/tx/0x8f482928ac6f7269390efebfc8082f733bc0bf25b5f793aa5c202d4aa1fabe79) | 10414875 | 403,831 | ✓ |
| Register ECDSA alg | [`0xa36838c7...`](https://sepolia.etherscan.io/tx/0xa36838c70a097e7ad69125c64b5301f2036e5ab3cd388a50fcb383e979c21090) | 10414876 | 47,815 | ✓ |
| Deploy Factory | [`0x0c514d7b...`](https://sepolia.etherscan.io/tx/0x0c514d7b97bbe16fa671f645e52074e7260643bdc09b13c2c9821a9661d2e53b) | 10414877 | 1,502,568 | ✓ |
| Register BLS Node 1 | [`0x215d79b3...`](https://sepolia.etherscan.io/tx/0x215d79b3258c3dcbacd8e3238da0685505c3f3b55f76da8b7cf48009465a9c16) | 10414879 | 205,155 | ✓ |
| Register BLS Node 2 | [`0x88285b30...`](https://sepolia.etherscan.io/tx/0x88285b304ae46bcda44cfd99a62ef4850c9eedced391efccf169d0d06a654080) | 10414880 | 188,055 | ✓ |
| createAccount | [`0x5642b1f0...`](https://sepolia.etherscan.io/tx/0x5642b1f0298bb1b962bc638e584d38108800a99bd5a1a5349c9fd2e517b37f72) | 10414881 | 1,094,370 | ✓ |
| setValidator | [`0xa1e36274...`](https://sepolia.etherscan.io/tx/0xa1e36274532b7715eab5ab055d866b6606d21b50eef47ffd09a8d8ed455efd55) | 10414882 | 44,906 | ✓ |
| depositTo EntryPoint | [`0x96ed12dc...`](https://sepolia.etherscan.io/tx/0x96ed12dc8d19c1b674ff6f3586f6c910f077a746809dc12c8a5b74acc131d37b) | 10414883 | 45,599 | ✓ |
| Fund AA with ETH | [`0xb503c143...`](https://sepolia.etherscan.io/tx/0xb503c143e26de57fe8e120621eb4c01a1dd0fdbf56e4b5b186b1235795e4a215) | 10414885 | 21,062 | ✓ |
| **handleOps (SUCCESS)** | [`0xf60f05f0...`](https://sepolia.etherscan.io/tx/0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff) | **10414886** | **259,694** | **✓** |

**Result**: M2 BLS Triple-Sig E2E: **259,694 gas** (−50.4% vs YetAA baseline 523,306)

---

### M3 F27: Gasless E2E (SuperPaymaster + aPNTs)

**AA Account**: `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07`

#### Preparation Transactions

| Step | TX Hash | Block | Gas | Status |
|------|---------|-------|-----|--------|
| Mint GToken to AA (default target) | [`0x25733b37...`](https://sepolia.etherscan.io/tx/0x25733b370b976111b94e1b38a0eef7e625c3b283c860367033f93714e5806005) | 10415162 | 53,314 | ✓ |
| safeMintForRole SBT (default target) | [`0x30898f2d...`](https://sepolia.etherscan.io/tx/0x30898f2dd79961e7a81386a7d61c6a6ab64dc08ff1d5a05accc93a4ccea3b45b) | 10415163 | 909,405 | ✓ |
| Mint aPNTs (default target) | [`0x8bbf56c0...`](https://sepolia.etherscan.io/tx/0x8bbf56c0c50eb5360a57cf99cb7a6b4e9c69e12197744e28612a34d62393b860) | 10415164 | 60,689 | ✓ |
| Mint GToken to AA | [`0xb2a6033b...`](https://sepolia.etherscan.io/tx/0xb2a6033b7d2090456d570011ea536c8676eb904648406fb1d063f6903951d07b) | 10415175 | 53,314 | ✓ |
| safeMintForRole SBT to AA | [`0x5c0e87a7...`](https://sepolia.etherscan.io/tx/0x5c0e87a7f74e80f53193c332a7f5cb01d2617a05777185511208ce985fbcc8d9) | 10415176 | 909,405 | ✓ |
| Mint aPNTs to AA | [`0x2d17ecbd...`](https://sepolia.etherscan.io/tx/0x2d17ecbdcc45e5a8b43acf76f267dcdadf5fb637e90f7e7ea17b8b9adcb53960) | 10415177 | 60,689 | ✓ |

#### Operator Setup

| Step | TX Hash | Block | Gas | Status |
|------|---------|-------|-----|--------|
| Approve GToken to Staking | [`0x273f9687...`](https://sepolia.etherscan.io/tx/0x273f9687d3eed829e65008a815a003eabffe66711ada56b5057e00d603b58833) | 10415215 | 28,845 | ✓ |
| registerRoleSelf (PAYMASTER_SUPER) | [`0xc90e375d...`](https://sepolia.etherscan.io/tx/0xc90e375dd6721d23d3114394ea5a9be017b4d7836018250ddbbe8593ec49dd47) | 10415216 | 428,790 | ✓ |
| configureOperator on SuperPaymaster | [`0x7d7ae990...`](https://sepolia.etherscan.io/tx/0x7d7ae99065fdad9cb057496d99b6d9cdd33a453b1cccf3b7bcfa9f85b57fac49) | 10415217 | 111,612 | ✓ |
| deposit 5000 aPNTs to SuperPaymaster | [`0xd0dd14ea...`](https://sepolia.etherscan.io/tx/0xd0dd14eab287689a3d01b5a0db15ebf30ab0a8bc505c370ac169d2a8db9a1b33) | 10415218 | 66,828 | ✓ |
| updatePrice (refresh stale cache) | [`0x503b20a4...`](https://sepolia.etherscan.io/tx/0x503b20a4ecd3fd5b537214ec22bb6eb7fb2f5b537a7ef451dfd5ee2da246757e) | 10415229 | 61,361 | ✓ |

#### Gasless handleOps (Failed Attempts)

| TX Hash | Block | Gas | Failure Reason |
|---------|-------|-----|----------------|
| [`0x649cf4fe...`](https://sepolia.etherscan.io/tx/0x649cf4fed67e4b0d3741f3ddffa7d7c02a4dae3e92343ba50acbc3dd319e1100) | 10415185 | 70,342 | Operator not configured (`isConfigured=false`) |
| [`0x4509e96f...`](https://sepolia.etherscan.io/tx/0x4509e96fd0fd27aeb136d65f76de44dbb20535e44cba6678d0af9bbc77c35db3) | 10415220 | 144,700 | Chainlink price cache stale (last updated 2026-02-19) |

#### Gasless handleOps (Success)

| TX Hash | Block | Gas | Nonce | Description |
|---------|-------|-----|-------|-------------|
| [`0xdb9cc4e0...`](https://sepolia.etherscan.io/tx/0xdb9cc4e040f172dd211a73dfef4dee1fef4c80cdea7790bd4f25854d07181f10) | **10415231** | **229,847** | 1 | Transfer 1 aPNTs to 0xdEaD (gasless) |
| [`0xec3fc24a...`](https://sepolia.etherscan.io/tx/0xec3fc24a548098cb644b3608683a3f1850419535d49d1afd7b0999d7f26f8775) | **10415236** | **161,459** | 2 | Transfer 1 aPNTs to 0xdEaD (gasless, second run) |

**Result**: AA 账户成功通过 SuperPaymaster 免 ETH 转账 aPNTs。gas 由 operator 的 aPNTs 抵押支付。

---

## 4. Foundry Unit Test Results

Total: **177 tests, 0 failures, 0 skips**

| Test Suite | Tests | Pass | Fail |
|------------|-------|------|------|
| AAStarAirAccountV7_M2Test | 11 | 11 | 0 |
| AAStarAirAccountV7M3Test | 18 | 18 | 0 |
| AAStarBLSAggregatorTest | 13 | 13 | 0 |
| AAStarBLSAlgorithmTest | 25 | 25 | 0 |
| AAStarBLSAlgorithmM3Test | 6 | 6 | 0 |
| AAStarGlobalGuardTest | 22 | 22 | 0 |
| AAStarValidatorTest | 13 | 13 | 0 |
| AAStarValidatorM3Test | 16 | 16 | 0 |
| SocialRecoveryTest | 31 | 31 | 0 |

### Test Coverage by Feature

| Feature | ID | Test File | Tests |
|---------|----|-----------|-------|
| GlobalGuard (daily limits, alg whitelist) | F19 | `AAStarGlobalGuard.t.sol` | 22 |
| P256 Passkey validation | F20 | `AAStarAirAccountV7_M3.t.sol` | 3 |
| Tiered signature routing | F21 | `AAStarAirAccountV7_M3.t.sol` | 5 |
| Governance Timelock (7-day proposal) | F22 | `AAStarValidator_M3.t.sol` | 16 |
| IAggregator (batch BLS) | F23 | `AAStarBLSAggregator.t.sol` | 13 |
| Cached Aggregated Keys | F24 | `AAStarBLSAlgorithm_M3.t.sol` | 6 |
| Social Recovery (2/3 guardians) | F28 | `SocialRecovery.t.sol` | 31 |
| M2 regression (ECDSA + BLS) | — | `AAStarAirAccountV7_M2.t.sol` | 11 |
| M3 integration (P256, aggregator, guard) | — | `AAStarAirAccountV7_M3.t.sol` | 18 |

---

## 5. AA Account Final State (on-chain verified)

**Account**: `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07`

| Property | Value |
|----------|-------|
| ETH Balance | 0.004 ETH |
| EntryPoint Nonce | 3 (3 successful UserOps) |
| aPNTs Balance | 98 (started 100, transferred 2 via gasless) |
| GToken Balance | 100 |
| SBT Held | true |
| sbtHolders in SuperPaymaster | true |

**Operator**: `0xb5600060e6de5E11D3636731964218E53caadf0E`

| Property | Value |
|----------|-------|
| isConfigured | true |
| aPNTs Balance (in PM) | 4,936.51 (deposited 5,000, spent ~63.5 on gas) |
| Exchange Rate | 1:1 (1e18) |
| xPNTs Token | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` (= aPNTs) |
| Treasury | `0xb5600060e6de5E11D3636731964218E53caadf0E` |

**SuperPaymaster**: `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A`

| Property | Value |
|----------|-------|
| EntryPoint Deposit | 0.2818 ETH |
| ETH/USD Price | 2,027.61 |
| Price Updated | 2026-03-09T13:44:36Z |
| Protocol Fee | 1,000 bps (10%) |

---

## 6. Gas Comparison Summary

| Milestone | Signature Type | Gas Used | vs Baseline |
|-----------|---------------|----------|-------------|
| M1 (YetAA baseline) | ECDSA (YetAnotherAA) | 523,306 | — |
| M2 (AirAccount) | BLS Triple-Sig | 259,694 | **−50.4%** |
| M3 F27 Gasless #1 | ECDSA + SuperPaymaster | 229,847 | — |
| M3 F27 Gasless #2 | ECDSA + SuperPaymaster | 161,459 | — |

---

## 7. Scripts

| Script | Purpose |
|--------|---------|
| `scripts/fund_aa_account_sepolia.ts` | Mint GToken + SBT + aPNTs to target AA account |
| `scripts/setup_operator_sepolia.ts` | Register operator role, configure SuperPaymaster, deposit aPNTs |
| `scripts/test-e2e-gasless.ts` | Full gasless UserOp E2E test (auto price cache refresh) |

---

## 8. Git Commit History

```
5ba83a5 feat: F27 gasless E2E verified on Sepolia — SuperPaymaster + aPNTs
472d805 feat: M3 contracts and tests — GlobalGuard, P256, tiered routing, IAggregator, social recovery
7d79278 feat: M2 complete — BLS triple-sig E2E verified on Sepolia (-50% gas vs YetAA)
827c2b1 feat: M1 complete — ECDSA E2E verified on Sepolia
2c71196 feat(m1): core account contracts, factory, tests, and E2E script
```
