# YetAnotherAA-Validator Deployment Record

## Overview

- **Repository**: `lib/YetAnotherAA-Validator` (submodule from `https://github.com/fanhousanbu/YetAnotherAA-Validator`)
- **Version**: EntryPoint v0.7 only
- **Date**: 2026-03-09

---

## Sepolia Testnet Deployment

### Configuration

| Item | Value |
|------|-------|
| Network | Sepolia (Chain ID: 11155111) |
| Deployer EOA | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| RPC | `https://sepolia.drpc.org` (public) |
| Deployed at | 2026-03-09 03:47~03:50 UTC |

> **Note**: Alchemy RPC blocked multi-tx scripts for EIP-7702 delegated accounts (error: "in-flight transaction limit for delegated accounts"). Each contract was deployed in a separate transaction using public RPC. Three validator instances were created as a side effect of retry attempts; only the third one (`0xF780...`) is used.

---

### Deployed Contracts

#### AAStarValidator (in use)

| Field | Value |
|-------|-------|
| Contract | `AAStarValidator.sol` |
| Address | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` |
| Owner | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Tx Hash | `0x901a946407efe3a6f5e4bde5f128c8e35cdf814f5d19ab919f9776ef21c34a4f` |
| Block | 10412499 (0x9ee1d3) |
| Etherscan | https://sepolia.etherscan.io/tx/0x901a946407efe3a6f5e4bde5f128c8e35cdf814f5d19ab919f9776ef21c34a4f |

#### AAStarAccountV7 Implementation

| Field | Value |
|-------|-------|
| Contract | `AAStarAccountV7.sol` (proxy target) |
| Address | `0xA2e72b5159D29EC43434D7732Ad1F4F834998DD1` |
| Tx Hash | `0xfda85f2321a79a0ecb353bf68fa79c811c3c9906895586d7d3a17fc9791836db` |
| Block | 10412500 (0x9ee1d4) |
| Etherscan | https://sepolia.etherscan.io/tx/0xfda85f2321a79a0ecb353bf68fa79c811c3c9906895586d7d3a17fc9791836db |

#### AAStarAccountFactoryV7

| Field | Value |
|-------|-------|
| Contract | `AAStarAccountFactoryV7.sol` |
| Address | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` |
| Internal Implementation | `0xab7d9A8Ab9e835c5C7D82829E32C10868558E0F8` (deployed in constructor) |
| Tx Hash | `0x570a6b84ae80281ae222235c05aaa59b5257bcf47e96955651a0266f5d7f7a88` |
| Block | 10412501 (0x9ee1d5) |
| Etherscan | https://sepolia.etherscan.io/tx/0x570a6b84ae80281ae222235c05aaa59b5257bcf47e96955651a0266f5d7f7a88 |

#### Unused Validator Instances (retry side-effects, do not use)

| Address | Tx Hash | Note |
|---------|---------|------|
| `0xA7047632B2E639567F3f7ff288D357e640e69435` | `0x6b0614b55e2b51aa3fd8a6c5d22f5aa79d40e2b137ce9087eb175751e24b03c7` | retry attempt #1 |
| `0x75A7dc084982041ed5Cf5Fd04e2BfC23562F3DAF` | `0x2aa2b0a0756b28b524a7f115358c29ec7ef50d51c10ca13992e885de86fd3319` | retry attempt #2 |

---

### Key Environment Variables (`.env.sepolia`)

```bash
VALIDATOR_CONTRACT_ADDRESS=0xF780Cc3FB161F8df8C076f86E89CE8B685985395
AASTAR_ACCOUNT_FACTORY_ADDRESS=0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31
AASTAR_ACCOUNT_IMPLEMENTATION_ADDRESS=0xab7d9A8Ab9e835c5C7D82829E32C10868558E0F8
```

---

## Test AA Accounts (Sepolia)

These accounts were created during testing and should be reused for all subsequent Sepolia tests.

### Account #1 (Jason/Jason — BLS enabled)

| Field | Value |
|-------|-------|
| Account Address | `0x30662d826926F4e3d6A453610CA2A0266F69C085` |
| creator | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| signer | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Private Key | `PRIVATE_KEY_JASON` in `.env.sepolia` |
| validator | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` |
| useAAStarValidator | `true` |
| salt | `0` |
| Factory used | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` |
| Creation Tx | `0x01cf479fd0ddbe263ab2ef8dc2dc02bab39abeeb3fd2c5fffe7f98cfd097bb87` |
| Block | 10412568 (0x9ee218) |
| Etherscan | https://sepolia.etherscan.io/tx/0x01cf479fd0ddbe263ab2ef8dc2dc02bab39abeeb3fd2c5fffe7f98cfd097bb87 |
| Gas Used | 207,774 |

---

## Registered BLS Nodes (Sepolia Validator)

All nodes registered to validator `0xF780Cc3FB161F8df8C076f86E89CE8B685985395`.

### Test Nodes for E2E (private key known — use for `scripts/test-e2e-bls.ts`)

Keys derived deterministically: `keccak256("aastar-bls-test-node-1/2") % BLS12-381_ORDER`
All values also stored in `.env.sepolia` under `BLS_TEST_*`.

#### Test Node 1

| Field | Value |
|-------|-------|
| Node ID (`BLS_TEST_NODE_ID_1`) | `0xb548c8e23d2df1158ebb19fe07eb1ac4d9c47f13b3c9d3aed83b206930506a6d` |
| Private Key (`BLS_TEST_PRIVATE_KEY_1`) | `0x415b218f139073cd5b8141f5fe4942bf8606db10b3cb77afd83b206a30506a6c` |
| Public Key G1 128B (`BLS_TEST_PUBLIC_KEY_1`) | `0x00000000000000000000000000000000113489490564124e9b034121664478b7c91fa2b1536578e76e20d583a38a018fa6c25ad56175b247a2fb505b498c324900000000000000000000000000000000179a2b925370557752e090838a6c0d752eaa013d86f353b460427952679b67b4dd11543c7ceebf2366a8454270e78f5e` |
| Registration Tx | (confirmed on Sepolia 2026-03-09) |

#### Test Node 2

| Field | Value |
|-------|-------|
| Node ID (`BLS_TEST_NODE_ID_2`) | `0x7f7e6290d0588435c6d12093b420fafc5b4c7ab23c73645ca7186189dca9537c` |
| Private Key (`BLS_TEST_PRIVATE_KEY_2`) | `0x0b90bb3da6bb06ed9397488baa7f22f7078ed6af3c75085da718618adca9537b` |
| Public Key G1 128B (`BLS_TEST_PUBLIC_KEY_2`) | `0x00000000000000000000000000000000102c370763358b7f3b43be6ec9f483642e9261ddeb1e723ee1673dbbc9bcadb865584195012ab0bcbccdbac1470d51cc000000000000000000000000000000000aa43b032460056909a61247957a5ad2981f2da469efb0a4f162c87b07eba0cf9f72b0d1ce6a15537518a31e9e52707b` |
| Registration Tx | `0x0dddabd95c47360347249715da982bd2a1b9a803f4146ce1b70c01024cca971f` |
| Etherscan | https://sepolia.etherscan.io/tx/0x0dddabd95c47360347249715da982bd2a1b9a803f4146ce1b70c01024cca971f |

### Legacy Nodes from Deploy Script (private key unknown — do not use for E2E)

From `script/DeployAAStarV7.s.sol` test vectors. Private keys not available.

| # | Node ID | Registration Tx |
|---|---------|----------------|
| 1 | `0xf26f8bdca182790bad5481c1f0eac3e7ffb135ab33037dd02b8d98a1066c6e5d` | `0x484d080abc3c1fa4c645004563b9f67be67b7103b539906bb5b42e721de05969` |
| 2 | `0xc0e74ed91b71668dd2619e1bacaccfcc495bdbbd0a1b2a64295550c701762272` | `0x3fbd66fba288f52a9b982fbb6e3d38cdf07e2ffd77a24efd5ceed995022ed3c2` |

---

## Test Results

All tests run on 2026-03-09 against Sepolia deployments.

### Unit Tests (Local Foundry)

```
forge test --gas-report
59 tests, 0 failed
```

| Suite | Tests | Result |
|-------|-------|--------|
| `AAStarValidator.t.sol` | 35 | ✅ All pass |
| `AAStarAccountV7.t.sol` | 10 | ✅ All pass |
| `AAStarAccountV8.t.sol` | 14 | ✅ All pass |

### On-Chain Tests (Sepolia)

| # | Test | Method | Result | Gas / Notes |
|---|------|--------|--------|-------------|
| 1 | Counterfactual address prediction | `factory.getAddress(creator, signer, validator, true, 0)` | ✅ `0x30662d...C085` | view call |
| 2 | Pre-deployment code check | `cast code` | ✅ `0x` (empty) | view call |
| 3 | Create AA account | `factory.createAccount(...)` | ✅ deployed | 207,774 gas |
| 4 | Account code on-chain | `cast code` | ✅ has bytecode | view call |
| 5 | `creator()` correct | `account.creator()` | ✅ `0xb5600...` | view call |
| 6 | `signer()` correct | `account.signer()` | ✅ `0xb5600...` | view call |
| 7 | `getValidationConfig()` | returns validator addr + useValidator=true | ✅ correct | view call |
| 8 | `entryPoint()` | returns EntryPoint v0.7 address | ✅ `0x00000...da032` | view call |
| 9 | Factory idempotency | `getAddress` after creation | ✅ same address | view call |
| 10 | BLS key registration #1 | `validator.registerPublicKey(nodeId, pubKey)` | ✅ registered | ~205k gas |
| 11 | BLS key registration #2 | `validator.registerPublicKey(nodeId, pubKey)` | ✅ registered | ~205k gas |
| 12 | Node count after registration | `validator.getRegisteredNodeCount()` | ✅ `2` | view call |
| 13 | Gas estimate (1 node) | `validator.getGasEstimate(1)` | ✅ 195,000 | view call |
| 14 | Gas estimate (3 nodes) | `validator.getGasEstimate(3)` | ✅ 204,000 | view call |
| 15 | Gas estimate (5 nodes) | `validator.getGasEstimate(5)` | ✅ 213,000 | view call |
| 16 | EntryPoint deposit | `account.getDeposit()` | ✅ `0` (unfunded) | view call |

### Gas Report Summary (from unit tests)

| Operation | Min | Avg | Max |
|-----------|-----|-----|-----|
| `createAccount` (factory) | — | 207,822 | — |
| `validateUserOp` (ECDSA path) | 396 | 47,910 | 97,785 |
| `validateUserOp` (BLS path, mock) | — | — | 173,330 |
| `_parseAndValidateAAStarSignature` | — | 167,063 | — |
| `verifyAggregateSignature` (real BLS12-381) | 33,150 | 116,907 | **437,278** |
| `validateAggregateSignature` (pure view) | — | 404,562 | — |
| `registerPublicKey` | 23,520 | 180,245 | 205,261 |
| `account.initialize` | — | 94,491 | — |

> BLS `validateUserOp` real cost (mock replaced with real pairing) ≈ 600k+ gas total on L1. On Optimism the gas unit cost is the same but price is ~100–1000× cheaper in USD.

---

## Signature Structure Reference

From colleague's analysis:

```
UserOp.signature layout (abi.encodePacked):
  [0:32]          nodeIds count (uint256)
  [32:32+N×32]    nodeIds (bytes32[])          — N BLS node IDs
  [+0:+256]       BLS aggregate signature      — G2 point (256 bytes)
  [+256:+512]     messagePoint                 — G2 point (256 bytes)
  [+512:+577]     aaSignature                  — ECDSA (65 bytes)
  [+577:+642]     messagePointSignature        — ECDSA (65 bytes)

Total = 674 + (N × 32) bytes
Example (3 nodes): 32 + 96 + 256 + 256 + 65 + 65 = 770 bytes
```

---

## Optimism Mainnet Deployment

**Status**: Pending — requires manual `cast wallet` keystore password entry.

Planned addresses will differ from Sepolia (different deployer nonce).

```bash
# Command to run (human executes):
forge script script/DeployAAStarV7.s.sol:DeployAAStarV7System \
  --rpc-url https://opt-mainnet.g.alchemy.com/v2/4Cp8njSeL62sQANuWObBv \
  --account optimism-deployer \
  --sender <DEPLOYER_ADDRESS> \
  --broadcast \
  --verify \
  --etherscan-api-key MZD22FX482CHDAN2NIVP5Q6V6B4Y3WFKSS
```
