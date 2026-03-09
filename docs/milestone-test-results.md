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

**Status**: 🔄 In Progress
**Branch**: `v0.12.5`

*(Results will be recorded upon completion)*

---

## Milestone 3: AirAccount Features

**Status**: ⏳ Pending
**Branch**: `v0.12.5`

*(Results will be recorded upon completion)*
