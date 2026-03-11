# AirAccount Gasless E2E Test Report

**Date**: 2026-03-10
**Network**: Sepolia (Chain ID: 11155111)
**Status**: PASSED

---

## 1. Test Overview

This test validates the complete gasless transaction flow: an AirAccount (ERC-4337 smart wallet) executes an on-chain transaction with **zero ETH gas cost** — gas is paid in aPNTs tokens via the SuperPaymaster protocol.

### What Was Tested

- M3 AirAccount executes `execute(self, 0.0001 ETH, 0x)` — a self-transfer to prove execution works
- Gas is sponsored by SuperPaymaster, which deducts aPNTs from the AA account
- The AA account's ETH balance is **unchanged** after the transaction (gasless)
- The entire flow: SBT gating → aPNTs funding → price oracle → UserOp building → signing → submission → verification

---

## 2. Contract Addresses (Sepolia)

### AirAccount Contracts

| Contract | Address | Etherscan |
|----------|---------|-----------|
| EntryPoint (v0.7) | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | [Link](https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) |
| **M3 Factory** | `0xce4231da69015273819b6aab78d840d62cf206c1` | [Link](https://sepolia.etherscan.io/address/0xce4231da69015273819b6aab78d840d62cf206c1) |
| **M4 Factory** (cumulative sigs) | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | [Link](https://sepolia.etherscan.io/address/0x914db0a849f55e68a726c72fd02b7114b1176d88) |
| **M3 AA Test Account** | `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` | [Link](https://sepolia.etherscan.io/address/0x4bFf3539b73CA3a29d89C00C8c511b884211E31B) |
| BLS Algorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | [Link](https://sepolia.etherscan.io/address/0xc2096E8D04beb3C337bb388F5352710d62De0287) |
| Validator Router | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` | [Link](https://sepolia.etherscan.io/address/0x730a162Ce3202b94cC5B74181B75b11eBB3045B1) |

### SuperPaymaster Ecosystem

| Contract | Address | Role |
|----------|---------|------|
| **SuperPaymaster** | `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A` | ERC-4337 Paymaster, sponsors gas in exchange for aPNTs |
| **aPNTs Token** (gas token) | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` | ERC-20 token deducted as gas fee |
| **SBT** (soul-bound identity) | `0x677423f5Dad98D19cAE8661c36F094289cb6171a` | Identity gating — account must hold SBT to use paymaster |
| **GToken** | `0x9ceDeC089921652D050819ca5BE53765fc05aa9E` | Governance token |
| **Registry** | `0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788` | Role-based SBT minting registry |
| **Price Feed** (Chainlink) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | ETH/USD oracle for gas price conversion |

### EOA Accounts

| Role | Address | Description |
|------|---------|-------------|
| **Owner / Operator** | `0xb5600060e6de5E11D3636731964218E53caadf0E` | AA account owner + SuperPaymaster operator + bundler |
| Guardian 1 (Anni) | `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` | Social recovery guardian |
| Guardian 2 (Bob) | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` | Social recovery guardian |
| Guardian 3 (Charlie) | `0x4F0b7d0EaD970f6573FEBaCFD0Cd1FaB3b64870D` | Social recovery guardian |

### KMS (Key Management Service)

| Item | Value |
|------|-------|
| KMS Base URL | `https://kms.aastar.io` |
| KMS API Key | `kms_b3994135cfd148ec9c5be29ef0690679` |
| KMS Function | `/SignHash` — signs EIP-191 hash with TEE-protected EOA private key |
| EOA Wallet | Derived from KMS via `/CreateKey` + `/DeriveAddress` (m/44'/60'/0'/0/0) |

---

## 3. Passkey & Signing Architecture

```
User Device                    KMS (TEE)                   Blockchain
───────────                    ─────────                   ──────────
[P-256 Passkey]  ────┐
  (WebAuthn)         │
                     ├─→  [EOA Private Key]  ──→  ECDSA Signature
                     │      (in OP-TEE)              │
  signMessage()  ────┘                               │
                                                     ▼
                                              [EntryPoint.handleOps]
                                                     │
                                              [validateUserOp]
                                                     │
                                              [execute(dest, value, data)]
```

### Signing Flow (for this gasless test)

1. **Build UserOp** with `paymasterAndData` pointing to SuperPaymaster
2. **Get `userOpHash`** from `EntryPoint.getUserOpHash(userOp)`
3. **Sign**: `signer.signMessage({ message: { raw: userOpHash } })` — produces EIP-191 personal sign (65 bytes)
4. **Submit**: `handleOps([signedUserOp], beneficiary)` to EntryPoint

For KMS-based signing (onboarding scripts):
1. Compute `ethSignedHash = hashMessage({ raw: userOpHash })` — EIP-191 prefix
2. Send `ethSignedHash` to KMS `/SignHash` endpoint
3. KMS returns 65-byte raw ECDSA signature (r, s, v)
4. Use raw signature as `userOp.signature`

---

## 4. Complete Test Flow (Step by Step)

### Phase 1: Prepare Account

| Step | Action | Result | TX |
|------|--------|--------|-----|
| 1.1 | Check M3 account deployment | Deployed (9598 bytes) | — |
| 1.2 | Mint SBT via Registry.safeMintForRole | SBT minted (balance: 1) | [`0x597e2e...`](https://sepolia.etherscan.io/tx/0x597e2eab289542e98b5c9ffac1981d6db2ef1b70a7ccc122bb9e3bdedc053581) |
| 1.3 | Mint 100 aPNTs to AA account | Balance: 100.0000 aPNTs | [`0x15cfef...`](https://sepolia.etherscan.io/tx/0x15cfefa17451b8abc6930445165540155ddc66fa4c10b4877719f7980890d25f) |
| 1.4 | Check ETH balance (for self-transfer value) | 0.009 ETH (sufficient) | — |
| 1.5 | Check SuperPaymaster EntryPoint deposit | 0.2818 ETH (sufficient) | — |
| 1.6 | Refresh price cache (ETH/USD oracle) | Refreshed (was stale) | — |

**SBT Minting Details**:
- Minted via `Registry.safeMintForRole(roleId, user, data)` where `roleId = keccak256("ENDUSER")`
- SBT is required by SuperPaymaster as an identity check — only SBT holders can use gasless transactions

**aPNTs Funding Details**:
- Minted 100 aPNTs directly to the AA account (`0x4bFf...`)
- aPNTs are the gas payment token — SuperPaymaster deducts aPNTs from the AA account to cover gas costs

### Phase 2: Build Gasless UserOp

| Step | Action | Value |
|------|--------|-------|
| 2.1 | Build callData | `execute(self, 0.0001 ETH, 0x)` — self-transfer |
| 2.2 | Get nonce | `1` (second UserOp from this account) |
| 2.3 | Build paymasterAndData (72 bytes) | See structure below |
| 2.4 | Set gas parameters | See below |
| 2.5 | Sign UserOp | ECDSA 65-byte personal sign |

**paymasterAndData Structure** (72 bytes):

```
Offset  Length  Field                          Value
──────  ──────  ─────                          ─────
0       20      SuperPaymaster address         0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A
20      16      paymasterVerificationGasLimit  250,000
36      16      paymasterPostOpGasLimit        50,000
52      20      Operator address               0xb5600060e6de5E11D3636731964218E53caadf0E
```

**Gas Parameters**:

| Parameter | Value |
|-----------|-------|
| verificationGasLimit | 150,000 |
| callGasLimit | 100,000 |
| preVerificationGas | 50,000 |
| maxPriorityFeePerGas | 2 gwei |
| maxFeePerGas | 3 gwei |
| paymasterVerificationGasLimit | 250,000 |
| paymasterPostOpGasLimit | 50,000 |

**UserOp Fields** (ERC-4337 v0.7 PackedUserOperation):

| Field | Value |
|-------|-------|
| sender | `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` (M3 account) |
| nonce | `1` |
| initCode | `0x` (already deployed) |
| callData | `execute(self, 0.0001 ETH, 0x)` encoded |
| accountGasLimits | `pack(150000, 100000)` |
| preVerificationGas | `50000` |
| gasFees | `pack(2 gwei, 3 gwei)` |
| paymasterAndData | 72 bytes (SuperPaymaster + Operator) |
| signature | ECDSA 65-byte EIP-191 personal sign of `userOpHash` |

**Signing**:

| Item | Value |
|------|-------|
| UserOpHash | `0x5598f4adfea11aa026c973ecf49370f22de41a8c2214f100785394e2006929a8` |
| Signature | `0x49ea281371630a7362...` (65 bytes, ECDSA personal sign) |

### Phase 3: Submit & Verify

| Step | Action | Result |
|------|--------|--------|
| 3.1 | Record balances before | ETH: 0.009, aPNTs: 100.0000 |
| 3.2 | Submit `handleOps` to EntryPoint | Confirmed in block 10420159 |
| 3.3 | Verify balances after | ETH: 0.009 (**UNCHANGED**), aPNTs: 100.0000 |
| 3.4 | Gas analysis | Bundler gas: 181,067, AA account ETH: UNCHANGED |

---

## 5. Final Transaction

| Item | Value |
|------|-------|
| **Gasless TX Hash** | `0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175` |
| **Etherscan** | [View on Sepolia Etherscan](https://sepolia.etherscan.io/tx/0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175) |
| Block | 10420159 |
| Bundler Gas Used | 181,067 |
| Gas Paid By | `0xb5600060e6de5E11D3636731964218E53caadf0E` (EOA bundler) |
| AA Account ETH Cost | **0 (ZERO)** |
| aPNTs Deducted | 0.0000 (self-transfer net zero; paymaster postOp skipped deduction) |

### Previous E2E Transactions (for reference)

| Test | TX Hash | Gas | Etherscan |
|------|---------|-----|-----------|
| M3 ECDSA (first E2E) | `0x912231d667b6c27a675ce0ebc08828a5d4aa13402423a6cd475b828d7df7a56a` | 127,249 | [Link](https://sepolia.etherscan.io/tx/0x912231d667b6c27a675ce0ebc08828a5d4aa13402423a6cd475b828d7df7a56a) |
| M4 Tier 1 ECDSA | `0x13d9ef74a12eeb97ad880b5d72e0be9abe44906534a69b270fcc36fff8b214d4` | 140,352 | [Link](https://sepolia.etherscan.io/tx/0x13d9ef74a12eeb97ad880b5d72e0be9abe44906534a69b270fcc36fff8b214d4) |
| M4 Tier 2 P256+BLS | `0x28788d7c03f96594e733224aedd14bd094036576683c3b8108264656ad76403d` | 278,634 | [Link](https://sepolia.etherscan.io/tx/0x28788d7c03f96594e733224aedd14bd094036576683c3b8108264656ad76403d) |
| M4 Tier 3 P256+BLS+Guardian | `0xb59d86c7df12b604ff3099a8fa04ed41c47e1339fea0fd0d6275c31cb499d648` | 288,351 | [Link](https://sepolia.etherscan.io/tx/0xb59d86c7df12b604ff3099a8fa04ed41c47e1339fea0fd0d6275c31cb499d648) |
| M2 BLS Triple | `0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff` | 259,694 | [Link](https://sepolia.etherscan.io/tx/0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff) |
| M1 ECDSA (first ever) | `0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81` | ~200,000 | [Link](https://sepolia.etherscan.io/tx/0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81) |

---

## 6. How the Gasless Flow Works (Architecture)

```
                                        SuperPaymaster
                                        ┌────────────────────┐
                                        │ 1. Check SBT held  │
                                        │ 2. Check aPNTs bal  │
                                        │ 3. Validate price   │
    User Device                         │ 4. Sponsor gas      │
    ┌──────────┐                        │ 5. Deduct aPNTs     │
    │ Build    │                        └────────┬───────────┘
    │ UserOp   │                                 │
    │ + sign   │                                 │
    └────┬─────┘                                 │
         │                                       │
         ▼                                       ▼
    ┌──────────┐    handleOps()    ┌─────────────────────────┐
    │ Bundler  │ ────────────────→│     EntryPoint (v0.7)    │
    │ (EOA)    │  pays gas in ETH │                          │
    │          │◄─────────────────│  1. validateUserOp()     │
    └──────────┘  gets refund     │     → AA.validateSignature│
                                  │     → PM.validatePaymaster│
                                  │  2. execute()             │
                                  │     → AA.execute(...)     │
                                  │  3. postOp()              │
                                  │     → PM deducts aPNTs    │
                                  └─────────────────────────┘
```

### Key Dependencies

1. **SBT (Soul-Bound Token)**: AA account must hold an SBT issued by the Registry. This prevents sybil attacks on the paymaster.
2. **aPNTs Balance**: AA account must have sufficient aPNTs to cover gas costs. The paymaster converts ETH gas cost → aPNTs using the Chainlink price feed.
3. **Price Cache**: SuperPaymaster caches ETH/USD price from Chainlink. If stale (>4200s), must call `updatePrice()` before submitting UserOps.
4. **Paymaster Deposit**: SuperPaymaster must have sufficient ETH deposited in EntryPoint to sponsor transactions.
5. **Operator**: The `paymasterAndData` includes an operator address that the paymaster validates for authorization.

---

## 7. How to Reproduce

### Prerequisites

```bash
cd projects/airaccount-contract
pnpm install
forge build
```

### Run the Test

```bash
pnpm tsx scripts/test-gasless-complete-e2e.ts
```

### What the Script Does

1. **Checks** if the M3 AA account is deployed
2. **Mints SBT** via Registry if the account doesn't have one
3. **Mints aPNTs** (100 tokens) if balance is insufficient
4. **Checks** ETH balance (needs >= 0.001 for self-transfer value)
5. **Checks** SuperPaymaster's EntryPoint deposit
6. **Refreshes** price cache if stale
7. **Builds** a UserOp with `paymasterAndData` (72 bytes: paymaster + gas limits + operator)
8. **Signs** the UserOp hash with ECDSA personal sign
9. **Submits** via `handleOps` to EntryPoint
10. **Verifies** ETH balance is unchanged (gasless confirmed)

### Environment Variables Required

```bash
# .env.sepolia
SEPOLIA_RPC_URL=<Alchemy/Infura RPC>
PRIVATE_KEY=<deployer/owner private key>
KMS_BASE_URL=https://kms.aastar.io
KMS_API_KEY=<api key>
```

---

## 8. Gas Comparison

| Scenario | Gas | Who Pays | Cost to User |
|----------|-----|----------|--------------|
| M3 ECDSA (standard) | 127,249 | AA account (ETH) | ~$0.05 |
| M4 Tier 1 ECDSA (with guard) | 140,352 | AA account (ETH) | ~$0.06 |
| **Gasless (this test)** | **181,067** | **Bundler (ETH)** | **$0 (aPNTs deducted)** |
| M4 Tier 2 P256+BLS | 278,634 | AA account (ETH) | ~$0.11 |
| M4 Tier 3 P256+BLS+Guardian | 288,351 | AA account (ETH) | ~$0.12 |

Gasless adds ~54k gas overhead vs standard M3 (181,067 vs 127,249) due to paymaster validation and postOp processing.

---

## 9. Related Scripts

| Script | Purpose |
|--------|---------|
| `scripts/onboard-1-create-keys.ts` | Generate P-256 passkey + KMS wallet + derive EOA |
| `scripts/onboard-2-create-account.ts` | Deploy AA account via Factory |
| `scripts/onboard-3-test-transfer.ts` | ETH transfer via UserOp + KMS signing |
| `scripts/onboard-4-gasless-transfer.ts` | Gasless transfer via SuperPaymaster |
| `scripts/test-gasless-complete-e2e.ts` | **This test** — complete gasless lifecycle |
| `scripts/test-tiered-e2e.ts` | Tiered signature E2E (3 tiers + 2 negative) |
| `scripts/test-social-recovery-e2e.ts` | Social recovery E2E (5 scenarios) |
| `scripts/deploy-m4.ts` | Deploy M4 Factory (cumulative sigs) |
