# AirAccount V7 — Product Acceptance Guide

**Version**: v0.15.0 (M6)
**Date**: 2026-03-20
**Network**: Sepolia Testnet (Chain ID: 11155111)
**Compiler**: Solidity 0.8.33, Cancun EVM, via-IR, 10k optimizer runs

> For full contract inventory, algId table, and feature descriptions see [`docs/contract-registry.md`](contract-registry.md).

---

## 1. Product Overview

AirAccount is a **non-upgradable ERC-4337 smart wallet** designed for mass-market adoption. Core value proposition:

- **One-tap on phone** (Passkey/WebAuthn) for small payments
- **Automatic DVT co-sign** for medium transactions
- **Guardian approval** for large transfers
- **Zero ETH needed** — gas paid via aPNTs token through SuperPaymaster
- **Social recovery** — 2-of-3 guardian threshold with timelock

The cumulative signature model ensures higher-value transactions require MORE authentication factors, not different ones. Users don't "switch modes" — they simply approve, and the system adds signatures as needed.

---

## 2. Deployed Contracts (Sepolia)

### AirAccount Core

| Contract | Address | Role |
|----------|---------|------|
| **M5 Factory r5 (current)** | [`0xd72a236d84be6c388a8bc7deb64afd54704ae385`](https://sepolia.etherscan.io/address/0xd72a236d84be6c388a8bc7deb64afd54704ae385) | M5 factory with guardian acceptance + token guard defaults |
| **M4 Factory** | [`0x914db0a849f55e68a726c72fd02b7114b1176d88`](https://sepolia.etherscan.io/address/0x914db0a849f55e68a726c72fd02b7114b1176d88) | Creates AA accounts with cumulative sig support |
| **M3 Factory** | [`0xce4231da69015273819b6aab78d840d62cf206c1`](https://sepolia.etherscan.io/address/0xce4231da69015273819b6aab78d840d62cf206c1) | Previous version factory |
| EntryPoint (v0.7) | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) | ERC-4337 singleton |
| Validator Router | [`0x730a162Ce3202b94cC5B74181B75b11eBB3045B1`](https://sepolia.etherscan.io/address/0x730a162Ce3202b94cC5B74181B75b11eBB3045B1) | Routes signatures to algorithm contracts |
| BLS Algorithm | [`0xc2096E8D04beb3C337bb388F5352710d62De0287`](https://sepolia.etherscan.io/address/0xc2096E8D04beb3C337bb388F5352710d62De0287) | BLS12-381 verification + node registry |

> M6 contracts (SessionKeyValidator, CalldataParserRegistry, UniswapV3Parser) are deployed per-environment. See E2E scripts for deployment instructions.

### SuperPaymaster Ecosystem

| Contract | Address | Role |
|----------|---------|------|
| SuperPaymaster | [`0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A`](https://sepolia.etherscan.io/address/0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A) | Gas sponsorship in exchange for aPNTs |
| aPNTs Token | [`0xDf669834F04988BcEE0E3B6013B6b867Bd38778d`](https://sepolia.etherscan.io/address/0xDf669834F04988BcEE0E3B6013B6b867Bd38778d) | ERC-20 gas payment token |
| SBT (Identity) | [`0x677423f5Dad98D19cAE8661c36F094289cb6171a`](https://sepolia.etherscan.io/address/0x677423f5Dad98D19cAE8661c36F094289cb6171a) | Soul-bound identity gating |
| Registry | [`0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788`](https://sepolia.etherscan.io/address/0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788) | Role-based SBT minting |
| Price Feed (Chainlink) | [`0x694AA1769357215DE4FAC081bf1f309aDC325306`](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306) | ETH/USD oracle |

### Test Accounts (EOA)

| Role | Address |
|------|---------|
| Owner / Operator / Bundler | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Guardian 1 (Anni) | `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` |
| Guardian 2 (Bob) | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` |
| Guardian 3 (Charlie) | `0x4F0b7d0EaD970f6573FEBaCFD0Cd1FaB3b64870D` |

### Test AA Accounts

| Account | Salt | Factory | Purpose |
|---------|------|---------|---------|
| `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` | — | M3 | Standard ECDSA + gasless tests |
| `0x117C702AC0660B9A8f4545c8EA9c92933E6925d7` | 400 | M4 | Tiered signature tests (3 guardians) |
| salt 200-203 | 200-203 | M4 | Social recovery test accounts |

---

## 3. Environment Setup & Deployment

### 3.1 Prerequisites

```bash
# Install dependencies
pnpm install

# Verify Foundry
forge --version    # Solc 0.8.33 required

# Build contracts
forge build
```

### 3.2 Environment Configuration

Create `.env.sepolia` with:

```bash
SEPOLIA_RPC_URL=<Alchemy/Infura RPC URL>
PRIVATE_KEY=<deployer EOA private key>
PRIVATE_KEY_ANNI=<guardian 1 private key>
PRIVATE_KEY_BOB=<guardian 2 private key>
PRIVATE_KEY_CHARLIE=<guardian 3 private key>

# KMS (for passkey-based signing)
KMS_BASE_URL=https://kms.aastar.io
KMS_API_KEY=<api key>

# Deployed addresses
AIRACCOUNT_FACTORY=0x914db0a849f55e68a726c72fd02b7114b1176d88
ENTRYPOINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032
VALIDATOR_ROUTER=0x730a162Ce3202b94cC5B74181B75b11eBB3045B1
BLS_ALGORITHM=0xc2096E8D04beb3C337bb388F5352710d62De0287
```

### 3.3 Deploy a New Factory

```bash
# Compile first
forge build

# Deploy via TypeScript (Foundry has macOS transport issues)
pnpm tsx scripts/deploy-m5.ts
```

The Factory constructor takes `(entryPoint, communityGuardian)`. For testing, pass `address(0)` as community guardian.

### 3.4 Initial Configuration After Deployment

After deploying a Factory and creating an account, configure:

1. **Set Validator Router**: `account.setValidator(routerAddress)` — enables BLS and external algorithms
2. **Set P256 Key**: `account.setP256Key(x, y)` — registers passkey public key
3. **Set Tier Limits**: `account.setTierLimits(tier1Wei, tier2Wei)` — e.g., 0.1 ETH / 1 ETH
4. **Fund EntryPoint Deposit**: `account.addDeposit{value: 0.1 ether}()` — for gas prefund
5. **[M6.4]** Register `SessionKeyValidator` in the Validator Router for algId `0x08`
6. **[M6.6b]** Deploy `CalldataParserRegistry`, register parsers, call `account.setParserRegistry(registryAddr)`

---

## 4. Core Features

### 4.1 Signature Tiers (Cumulative Model)

| Tier | Threshold | Signature | algId | UX |
|------|-----------|-----------|-------|-----|
| Tier 1 | ≤ tier1Limit (e.g., 0.1 ETH) | ECDSA only | `0x02` | One tap |
| Tier 2 | ≤ tier2Limit (e.g., 1 ETH) | P256 Passkey + BLS DVT | `0x04` | One tap + background DVT |
| Tier 3 | > tier2Limit | P256 + BLS + Guardian co-sign | `0x05` | One tap + DVT + guardian confirms |

**Key design**: Higher tiers ACCUMULATE signatures. Tier 3 includes everything in Tier 2, plus a guardian co-sign. Users don't "switch" — the system adds requirements as value increases.

### 4.2 Global Guard (Spending Limits)

- Deployed atomically in account constructor — no unprotected window
- `guard.account` is immutable — survives social recovery
- **Monotonic security**: daily limit can only decrease, algorithms can only be added (never removed)
- Daily spending tracked per UTC day (resets at midnight)

### 4.3 Social Recovery

- 3 guardian slots (backup key, trusted person, community Safe)
- **2-of-3 threshold** for both approval and cancellation
- **2-day timelock** between approval and execution
- Owner CANNOT cancel recovery (prevents stolen key from blocking)
- Guardian set changes auto-cancel active recovery proposals

### 4.4 Gasless Transactions (SuperPaymaster)

- User holds SBT (soul-bound identity token) + aPNTs (gas token)
- SuperPaymaster sponsors ETH gas, deducts aPNTs from user
- Price conversion via Chainlink ETH/USD oracle
- User's ETH balance is UNCHANGED after transaction

### 4.5 ERC20 Token-Tier Guard (M5)

Per-token spending limits enforced by `AAStarGlobalGuard`:
- Configure with `TokenConfig{tier1Limit, tier2Limit, dailyLimit}` per token address
- `transfer`/`approve` calldata parsed automatically — amount checked against tier limits
- Daily cumulative spend tracked per UTC day; prevents batch-bypass attacks
- Config is only-add, only-decrease (monotonic)

### 4.6 Session Key (M6.4)

Grant a DApp limited signing power without exposing the owner key:
- `sessionKeyValidator.grantSession(account, sessionKey, expiry, contractScope, selectorScope, ownerSig)`
- DApp signs UserOps with the session key; validator checks expiry + signature
- Tier 1 limits apply (same as ECDSA); owner can revoke instantly
- algId `0x08` — register `SessionKeyValidator` in the Validator Router

### 4.7 One Account Per DApp — OAPD (M6.6a)

Privacy isolation: each DApp sees a different on-chain address:
- `OAPDManager.saltForDapp(dappId)` — deterministic salt from `keccak256(owner + dappId)`
- `getOrCreateAccount(dapp, clients...)` — deploys or returns existing account
- All OAPD accounts share the same owner key, guardian pair, and social recovery path
- Zero Solidity changes — pure TypeScript feature using existing CREATE2 factory

### 4.8 Pluggable Calldata Parser (M6.6b)

Token tier enforcement for DeFi protocol calls (e.g., Uniswap swaps with `value=0`):
- `CalldataParserRegistry` maps `dest address → ICalldataParser` (singleton, only-add)
- `UniswapV3Parser` handles `exactInputSingle` and `exactInput` — returns `(tokenIn, amountIn)`
- Account calls registry in `_enforceGuard` before native ERC20 parsing
- Unknown destinations / unknown selectors fall back to ERC20 parsing silently

### 4.9 Config Templates

Three pre-built JSON configs in `configs/`:

| Template | Daily Limit | Tier1 | Tier2 | Use Case |
|----------|-------------|-------|-------|----------|
| `default-personal.json` | 1 ETH | 0.1 ETH | 1 ETH | Everyday wallet |
| `high-security.json` | 0.5 ETH | 0.05 ETH | 0.5 ETH | High-value storage |
| `developer-test.json` | 10 ETH | 1 ETH | 5 ETH | Development/testing |

### 4.10 Config Introspection

Call `getConfigDescription()` (view function) to get a complete snapshot:

```solidity
struct AccountConfig {
    address accountOwner;
    address guardAddress;
    uint256 dailyLimit;
    uint256 dailyRemaining;
    uint256 tier1Limit;
    uint256 tier2Limit;
    address[3] guardianAddresses;
    uint8 guardianCount;
    bool hasP256Key;
    bool hasValidator;
    bool hasAggregator;
    bool hasActiveRecovery;
}
```

---

## 5. Standard ERC-4337 Transaction Flow

### 5.1 Full Flow Diagram

```
  User                 Bundler              EntryPoint           AA Account          Guard
  ────                 ───────              ──────────           ──────────          ─────
   │                      │                      │                    │                 │
   │ 1. Build UserOp      │                      │                    │                 │
   │ 2. Sign (ECDSA/P256) │                      │                    │                 │
   │─────────────────────>│                      │                    │                 │
   │                      │                      │                    │                 │
   │                      │ 3. handleOps([op])   │                    │                 │
   │                      │─────────────────────>│                    │                 │
   │                      │                      │                    │                 │
   │                      │                      │ 4. validateUserOp  │                 │
   │                      │                      │───────────────────>│                 │
   │                      │                      │   _validateSignature│                 │
   │                      │                      │   _lastValidatedAlgId = algId        │
   │                      │                      │   _payPrefund       │                 │
   │                      │                      │<───────────────────│                 │
   │                      │                      │                    │                 │
   │                      │                      │ 5. execute(dest,val,data)            │
   │                      │                      │───────────────────>│                 │
   │                      │                      │                    │ 6. _enforceGuard │
   │                      │                      │                    │────────────────>│
   │                      │                      │                    │ tier check      │
   │                      │                      │                    │ daily limit     │
   │                      │                      │                    │ algo whitelist  │
   │                      │                      │                    │<────────────────│
   │                      │                      │                    │                 │
   │                      │                      │                    │ 7. _call(target)│
   │                      │                      │<───────────────────│                 │
   │                      │                      │                    │                 │
   │                      │ 8. refund gas        │                    │                 │
   │                      │<─────────────────────│                    │                 │
```

### 5.2 Building a UserOp (v0.7 PackedUserOperation)

```typescript
import { encodeFunctionData, toHex } from 'viem';

// 1. Encode callData
const callData = encodeFunctionData({
  abi: accountAbi,
  functionName: 'execute',
  args: [recipientAddress, amountInWei, '0x']
});

// 2. Get nonce
const nonce = await publicClient.readContract({
  address: entryPoint, abi: entryPointAbi,
  functionName: 'getNonce', args: [accountAddress, 0n]
});

// 3. Pack gas parameters (v0.7 format)
const accountGasLimits = toHex(
  (BigInt(150_000) << 128n) | BigInt(100_000), // verificationGas | callGas
  { size: 32 }
);
const gasFees = toHex(
  (BigInt(2_000_000_000) << 128n) | BigInt(3_000_000_000), // maxPriorityFee | maxFee
  { size: 32 }
);

// 4. Assemble UserOp
const userOp = {
  sender: accountAddress,
  nonce,
  initCode: '0x',         // '0x' if account already deployed
  callData,
  accountGasLimits,
  preVerificationGas: 50_000n,
  gasFees,
  paymasterAndData: '0x', // empty for self-pay, or 72 bytes for paymaster
  signature: '0x'         // placeholder
};

// 5. Get hash and sign
const userOpHash = await publicClient.readContract({
  address: entryPoint, abi: entryPointAbi,
  functionName: 'getUserOpHash', args: [userOp]
});

// ECDSA personal sign (65 bytes)
const signature = await walletClient.signMessage({
  message: { raw: userOpHash }
});
userOp.signature = signature;

// 6. Submit
const txHash = await walletClient.writeContract({
  address: entryPoint, abi: entryPointAbi,
  functionName: 'handleOps',
  args: [[userOp], bundlerAddress]
});
```

### 5.3 Key v0.7 Differences from v0.6

| Field | v0.6 | v0.7 |
|-------|------|------|
| Gas limits | Separate `verificationGasLimit`, `callGasLimit` | Packed `accountGasLimits` (bytes32) |
| Gas prices | Separate `maxPriorityFeePerGas`, `maxFeePerGas` | Packed `gasFees` (bytes32) |
| Paymaster | Separate `paymasterAndData` | Same field but different packing |

---

## 6. Gasless Transaction Flow (User Perspective)

### 6.1 What the User Sees

1. **First time**: App creates a passkey (one biometric prompt) → derives EOA → deploys AA account
2. **Before first gasless tx**: App auto-mints SBT (identity) and aPNTs (gas credits)
3. **Making a transfer**: User taps "Send" → confirms with fingerprint/face → transaction completes
4. **Gas cost**: 0 ETH. aPNTs balance decreases slightly.

### 6.2 What Happens Under the Hood

```
Step 1: Check prerequisites
  ├── SBT held by AA account? (identity gate)
  ├── aPNTs balance sufficient? (gas credits)
  ├── SuperPaymaster EntryPoint deposit sufficient?
  └── Price cache fresh? (ETH/USD from Chainlink, <4200s old)

Step 2: Build gasless UserOp
  ├── callData = execute(recipient, amount, 0x)
  ├── paymasterAndData = [paymaster(20)][verifyGas(16)][postOpGas(16)][operator(20)]
  │                       72 bytes total
  └── signature = ECDSA personal sign of userOpHash

Step 3: Submit to EntryPoint
  ├── Bundler calls handleOps([userOp], beneficiary)
  ├── EntryPoint calls AA.validateUserOp → signature check ✓
  ├── EntryPoint calls SuperPaymaster.validatePaymasterUserOp
  │   ├── Check SBT held ✓
  │   ├── Check aPNTs balance ✓
  │   └── Pre-charge: lock aPNTs ✓
  ├── EntryPoint calls AA.execute(dest, value, data) ✓
  └── EntryPoint calls SuperPaymaster.postOp
      └── Deduct actual gas cost in aPNTs from AA account

Step 4: Verification
  ├── AA account ETH balance: UNCHANGED
  ├── AA account aPNTs balance: decreased by gas cost (in aPNTs)
  └── Bundler ETH balance: decreased (paid gas), refunded by EntryPoint
```

### 6.3 Gasless Test Transaction (Verified)

| Item | Value |
|------|-------|
| TX Hash | [`0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175`](https://sepolia.etherscan.io/tx/0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175) |
| AA Account | `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` |
| Action | Self-transfer 0.0001 ETH |
| Gas Used | 181,067 |
| ETH Cost to User | **0** |
| Bundler ETH Cost | ~181,067 × gasPrice |

---

## 7. Gas Analysis

### 7.1 UserOp Gas by Signature Type

| Scenario | Gas Used | TX Hash |
|----------|----------|---------|
| **M3 ECDSA** (baseline) | 127,249 | [`0x912231...`](https://sepolia.etherscan.io/tx/0x912231d667b6c27a675ce0ebc08828a5d4aa13402423a6cd475b828d7df7a56a) |
| **M4 Tier 1** (ECDSA + guard) | 140,352 | [`0x13d9ef...`](https://sepolia.etherscan.io/tx/0x13d9ef74a12eeb97ad880b5d72e0be9abe44906534a69b270fcc36fff8b214d4) |
| **M4 Tier 2** (P256 + BLS) | 278,634 | [`0x28788d...`](https://sepolia.etherscan.io/tx/0x28788d7c03f96594e733224aedd14bd094036576683c3b8108264656ad76403d) |
| **M4 Tier 3** (P256 + BLS + Guardian) | 288,351 | [`0xb59d86...`](https://sepolia.etherscan.io/tx/0xb59d86c7df12b604ff3099a8fa04ed41c47e1339fea0fd0d6275c31cb499d648) |
| **Gasless** (via SuperPaymaster) | 181,067 | [`0xbf8296...`](https://sepolia.etherscan.io/tx/0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175) |

### 7.2 Gas Breakdown (Tier 1 ECDSA, ~140k)

| Component | Gas | % |
|-----------|-----|---|
| EntryPoint overhead | ~21,000 | 15% |
| ECDSA validation | ~45,000 | 32% |
| Guard + tier check | ~39,500 | 28% |
| ETH transfer (_call) | ~21,000 | 15% |
| Prefund + refund | ~15,000 | 10% |

### 7.3 Industry Comparison

| Wallet | Simple Transfer Gas | Features |
|--------|-------------------|----------|
| **AirAccount M3** | **127,249** | Guard + tiers + recovery |
| SimpleAccount (Pimlico) | ~120,000 | No guard, no recovery |
| LightAccount (Alchemy) | ~115,000 | Lightweight, upgradable |
| Kernel (ZeroDev) | ~150,000 | Modular ERC-7579 |
| Safe (4337 module) | ~180,000 | Proxy + module overhead |

### 7.4 Deployment Costs

| Contract | Gas |
|----------|-----|
| Factory (M4) | 3,698,359 |
| Account (with guard, 3 guardians) | ~2,977,000 |
| Account (no guard) | ~2,425,000 |

---

## 8. Validator & BLS Node Information

### 8.1 Validator Router

The Validator Router (`AAStarValidator`) maps `algId` (first byte of signature) to algorithm contract addresses:

| algId | Algorithm | Contract | Tier | Status |
|-------|-----------|----------|------|--------|
| `0x01` | BLS12-381 aggregate | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | 3 | Registered |
| `0x02` | ECDSA | (inline in account) | 1 | Native |
| `0x03` | P256 (Passkey/WebAuthn) | (inline in account) | 1 | Native |
| `0x04` | Cumulative T2 (P256 + BLS) | (inline in account) | 2 | Native |
| `0x05` | Cumulative T3 (P256 + BLS + Guardian) | (inline in account) | 3 | Native |
| `0x06` | Combined T1 (ECDSA + P256) | (inline in account) | 1 | Native |
| `0x08` | Session Key (M6.4) | `SessionKeyValidator` | 1 | Register in router |

- **Only-add registry**: algorithms can be registered but never removed or replaced
- **Timelock**: `proposeAlgorithm` → 7-day wait → `executeProposal` (for future additions)
- **Immediate path**: `registerAlgorithm` (owner only, for initial setup)

### 8.2 BLS Node Registry

BLS nodes are registered in `AAStarBLSAlgorithm`:

- `registerPublicKey(nodeId, publicKey)` — registers a 128-byte G1 public key
- `aggregateKeys(nodeIds)` — computes and optionally caches aggregated public key
- `cacheAggregatedKey(nodeIds)` — pre-computes for gas savings (~20k/tx)
- Current registered nodes: query via `getRegisteredNodeCount()` and `getRegisteredNodes(offset, limit)`

### 8.3 Precompile Dependencies

| Precompile | Address | EIP | Required By | Available On |
|------------|---------|-----|-------------|-------------|
| P256VERIFY | `0x100` | EIP-7212 | Tier 2, Tier 3 | Sepolia (post-Pectra), some L2s |
| BN_G1ADD | `0x0b` | EIP-2537 | BLS aggregate | Sepolia (post-Prague) |
| BN_PAIRING | `0x0f` | EIP-2537 | BLS aggregate | Sepolia (post-Prague) |

---

## 9. Test Scripts

### 9.1 Available Test Suites

| Script | Tests | Command |
|--------|-------|---------|
| Foundry unit tests | 345 tests | `forge test -vv` |
| Tiered signature E2E | 5 tests | `pnpm tsx scripts/test-tiered-e2e.ts` |
| Social recovery E2E | 5 tests | `pnpm tsx scripts/test-social-recovery-e2e.ts` |
| Gasless E2E | 1 test | `pnpm tsx scripts/test-gasless-complete-e2e.ts` |
| Factory validation E2E | 5 tests | `pnpm tsx scripts/test-factory-validation-e2e.ts` |
| Session Key E2E | 5 tests | `pnpm tsx scripts/test-session-key-e2e.ts` |
| OAPD E2E | 6 tests | `pnpm tsx scripts/test-oapd-e2e.ts` |
| Calldata Parser E2E | 5 tests | `pnpm tsx scripts/test-calldata-parser-e2e.ts` |

### 9.2 Onboarding Scripts (Demo Flow)

| Script | Purpose |
|--------|---------|
| `scripts/onboard-1-create-keys.ts` | Generate P-256 passkey + KMS wallet + derive EOA |
| `scripts/onboard-2-create-account.ts` | Deploy AA account via Factory |
| `scripts/onboard-3-test-transfer.ts` | ETH transfer via UserOp + KMS signing |
| `scripts/onboard-4-gasless-transfer.ts` | Gasless transfer via SuperPaymaster |

### 9.3 Running Tests

```bash
# Foundry unit tests (local, fast)
forge test -vv

# Sepolia E2E tests (requires .env.sepolia with funded EOAs)
pnpm tsx scripts/test-tiered-e2e.ts
pnpm tsx scripts/test-social-recovery-e2e.ts
pnpm tsx scripts/test-gasless-complete-e2e.ts
```

### 9.4 Test Results Summary

**Foundry**: 345/345 passed

**Sepolia E2E**: 32/32 passed

| Suite | Test | Result | Gas |
|-------|------|--------|-----|
| Tiered | Tier 1 ECDSA (0.005 ETH) | PASS | 140,352 |
| Tiered | Tier 2 P256+BLS (0.05 ETH) | PASS | 278,634 |
| Tiered | Tier 3 P256+BLS+Guardian (0.15 ETH) | PASS | 288,351 |
| Tiered | ECDSA → tier 2 amount (negative) | REVERTED ✓ | — |
| Tiered | P256+BLS → tier 3 amount (negative) | REVERTED ✓ | — |
| Recovery | Full happy path (propose → approve → timelock → execute) | PASS | ~555k |
| Recovery | Cancel recovery (2-of-3 cancel) | PASS | — |
| Recovery | Owner cannot cancel | PASS | — |
| Recovery | Stolen key cannot block recovery | PASS | — |
| Recovery | Guardian P256 passkey independence | PASS | — |
| Gasless | Self-transfer via SuperPaymaster | PASS | 181,067 |
| Factory | Guardian acceptance + token config validation | PASS | — |
| Session Key | Deploy + grant + validate + revoke | PASS | — |
| Session Key | Expired session rejected | PASS | — |
| OAPD | 3 DApps → 3 different addresses | PASS | — |
| OAPD | Same dapp → same address (idempotent) | PASS | — |
| Calldata Parser | Deploy registry + register Uniswap parser | PASS | — |
| Calldata Parser | Parse exactInputSingle (1000 USDC) | PASS | — |
| Calldata Parser | Unknown selector → (address(0), 0) | PASS | — |

---

## 10. Frontend Pages (Minimal Demo)

Located in `pages/`:

| Page | Function |
|------|----------|
| Config page | Load JSON template, display 12 config fields, user adjusts |
| Passkey registration | WebAuthn `navigator.credentials.create()` flow |
| Account creation | Deploy account + verify on-chain |
| Transaction page | Tier-aware display, shows required signatures |

Run locally:
```bash
cd pages
pnpm install
pnpm dev    # Opens at http://localhost:5173
```

---

## 11. Known Limitations

1. ~~**ERC20 value not tracked**~~: Fixed in M5 (native `transfer`/`approve` parsing) + M6.6b (pluggable parser for DeFi protocols).
2. **Chain compatibility**: P256 precompile (EIP-7212) and BLS precompiles (EIP-2537) only available on chains with Pectra/Prague upgrades.
3. **Non-upgradable**: Bug fixes require new Factory deployment + user migration.
4. ~~**Single bundle same-sender**~~: Fixed — uses transient storage queue to prevent cross-UserOp algId contamination.
5. **Session key scope enforcement**: `contractScope` and `selectorScope` are stored but not enforced in `validate()` — enforcement is intended for the guard layer. Full enforcement requires additional guard integration in a future milestone.

---

## 12. Security Summary

See `docs/security-review.md` and `docs/audit_report_2026_03_19_comprehensive.md` for full reviews. Key points:

- **Architecture**: Non-upgradable, atomic deployment, monotonic security
- **Guard**: Immutable binding, only-tighten config, daily reset, ERC20 + DeFi tier enforcement
- **Recovery**: 2-of-3 threshold, 2-day timelock, owner cannot cancel
- **Session Key**: Expiry enforced on-chain, instant revocation by owner, Tier 1 spending limits
- **OAPD**: Cross-DApp address isolation via deterministic salt, no Solidity changes
- **Parser**: Only-add registry, graceful fallback, no parser can bypass guard
- **345 unit tests** + 32 E2E tests covering all critical paths
- **Open items**: Session key scope enforcement (guard layer integration), fuzz testing, formal verification, mainnet audit
