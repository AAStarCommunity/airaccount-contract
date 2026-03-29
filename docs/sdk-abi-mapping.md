# AirAccount V7 SDK ABI/API Mapping — User Scenario Reference

> **Target audience**: SDK developers integrating AirAccount V7 into frontend applications or backend services.
> **Contract version**: `airaccount.v7@0.16.0`
> **Last updated**: 2026-03-29

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Deployed Contract Addresses (Sepolia)](#2-deployed-contract-addresses-sepolia)
3. [Scenario 1: Account Creation](#3-scenario-1-account-creation)
4. [Scenario 2: Account State Queries](#4-scenario-2-account-state-queries)
5. [Scenario 3: Execute Transactions](#5-scenario-3-execute-transactions)
6. [Scenario 4: Tiered Security Configuration](#6-scenario-4-tiered-security-configuration)
7. [Scenario 5: Social Recovery](#7-scenario-5-social-recovery)
8. [Scenario 6: ERC-7579 Module Management](#8-scenario-6-erc-7579-module-management)
9. [Scenario 7: AI Agent Session Keys](#9-scenario-7-ai-agent-session-keys)
10. [Scenario 8: Force Exit L2](#10-scenario-8-force-exit-l2)
11. [Scenario 9: Privacy Transactions (Railgun)](#11-scenario-9-privacy-transactions-railgun)
12. [Scenario 10: EIP-7702 Delegate Account](#12-scenario-10-eip-7702-delegate-account)
13. [ABI Quick Reference Cheatsheet](#13-abi-quick-reference-cheatsheet)
14. [Signature Format Reference](#14-signature-format-reference)
15. [Custom Error Reference](#15-custom-error-reference)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     AirAccount V7 Architecture                       │
│                                                                       │
│  User / SDK                                                           │
│      │                                                                │
│      ▼                                                                │
│  EntryPoint v0.7  ◄──────────────────────────────────────────────┐   │
│  (0x000...7da032)                                                 │   │
│      │                                                            │   │
│      │ handleOps()                                                │   │
│      ▼                                                            │   │
│  ┌─────────────────────────────────────────────────────────┐     │   │
│  │        AAStarAirAccountV7  (EIP-1167 Clone)             │     │   │
│  │                                                         │     │   │
│  │  validateUserOp()  ──►  algId routing                   │     │   │
│  │     ├── 0x02 ECDSA (inline)                             │     │   │
│  │     ├── 0x03 P256 passkey (EIP-7212 precompile)         │     │   │
│  │     ├── 0x04 Cumulative T2 (P256 + BLS)                 │     │   │
│  │     ├── 0x05 Cumulative T3 (P256 + BLS + Guardian)      │     │   │
│  │     ├── 0x06 Combined T1 (P256 AND ECDSA)               │     │   │
│  │     ├── 0x07 Weighted MultiSig                          │     │   │
│  │     ├── 0x08 Session Key  ──► AgentSessionKeyValidator  │     │   │
│  │     └── ERC-7579 nonce-key routing ──► Validator Module │     │   │
│  │                                                         │     │   │
│  │  execute() / executeBatch()                             │     │   │
│  │     ├── ERC-7579 Hook (TierGuardHook.preCheck)          │─────┘   │
│  │     ├── Tier enforcement (algId → tier 1/2/3)          │         │
│  │     ├── AAStarGlobalGuard.checkTransaction()            │         │
│  │     └── AAStarGlobalGuard.checkTokenTransaction()       │         │
│  │                                                         │         │
│  │  ERC-7579 Module Registry                               │         │
│  │     ├── Validators (typeId=1)                           │         │
│  │     ├── Executors  (typeId=2)                           │         │
│  │     └── Hooks      (typeId=3)                           │         │
│  └──────────────────┬──────────────────────────────────────┘         │
│                     │                                                 │
│      ┌──────────────┴──────────────────┐                             │
│      │                                 │                             │
│      ▼                                 ▼                             │
│  AAStarGlobalGuard              ValidatorRouter                       │
│  (per-account,                  (BLS, SessionKey algos)               │
│   monotonic config)                                                   │
└─────────────────────────────────────────────────────────────────────┘

Key design properties:
- Non-upgradable (no proxy patterns)
- EIP-1167 clones: factory deploys one implementation, clones per user
- Guard is immutable per account — social recovery rotates owner, not address
- Transient storage (EIP-1153) for algId pass-through: validation → execution
- EIP-7212 P256 precompile required at 0x0000...0100
```

---

## 2. Deployed Contract Addresses (Sepolia)

| Contract | Address |
|---|---|
| Factory (AAStarAirAccountFactoryV7) | `0x9D0735E3096C02eC63356F21d6ef79586280289f` |
| Implementation (AAStarAirAccountV7) | `0xf01e3Dd359DfF8e578Ee8760266E3fB9530F07A0` |
| AgentSessionKeyValidator | `0xa3e52db4b6e0a9d7cd5dd1414a90eedcf950e029` |
| TierGuardHook | `0x73572e9e6138fd53465ee243e2fb4842cf86a787` |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

> The factory also exposes `defaultValidatorModule` and `defaultHookModule` getters pointing to the pre-installed module addresses.

---

## 3. Scenario 1: Account Creation

### Description

Create a new smart wallet for a user. Two paths exist: full manual configuration (`createAccount`) and a convenience path with community guardian defaults (`createAccountWithDefaults`). The counterfactual address can always be predicted before deployment.

### 3.1 createAccount — Full Configuration

**Solidity signature:**
```solidity
function createAccount(
    address owner,
    uint256 salt,
    AAStarAirAccountBase.InitConfig memory config
) external returns (address account)
```

**InitConfig struct fields:**
```solidity
struct InitConfig {
    address[3] guardians;                        // Recovery guardians (address(0) = unused slot)
    uint256 dailyLimit;                          // ETH daily spending limit in wei (0 = no guard)
    uint8[] approvedAlgIds;                      // Guard-approved algorithm IDs (see algId table)
    uint256 minDailyLimit;                       // Floor for decreaseDailyLimit (0 = no floor)
    address[] initialTokens;                     // ERC20 tokens with pre-configured limits
    AAStarGlobalGuard.TokenConfig[] initialTokenConfigs; // Per-token tier/daily configs, 1:1 with initialTokens
}
```

**TokenConfig struct:**
```solidity
struct TokenConfig {
    uint256 tier1Limit;  // Max cumulative token amount for Tier 1 (ECDSA only)
    uint256 tier2Limit;  // Max cumulative token amount for Tier 2 (P256+BLS)
    uint256 dailyLimit;  // Total daily token cap (0 = unlimited)
}
```

**SDK pseudocode:**
```typescript
import { encodeFunctionData, parseEther, parseUnits } from "viem";

const FACTORY_ADDRESS = "0x9D0735E3096C02eC63356F21d6ef79586280289f";
const FACTORY_ABI = [...]; // load from artifact

const config = {
  guardians: [guardian1, guardian2, "0x0000000000000000000000000000000000000000"] as const,
  dailyLimit: parseEther("1"),        // 1 ETH/day
  approvedAlgIds: [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], // all algIds
  minDailyLimit: parseEther("0.1"),   // floor: cannot reduce below 0.1 ETH
  initialTokens: [USDC_ADDRESS],
  initialTokenConfigs: [{
    tier1Limit: parseUnits("100", 6),  // $100 USDC Tier 1 max
    tier2Limit: parseUnits("1000", 6), // $1000 USDC Tier 2 max
    dailyLimit:  parseUnits("2000", 6), // $2000/day total
  }],
};

const txHash = await walletClient.writeContract({
  address: FACTORY_ADDRESS,
  abi: FACTORY_ABI,
  functionName: "createAccount",
  args: [ownerAddress, salt, config],
});
```

> **Note**: The account address is deterministic. If already deployed, `createAccount` returns the existing address without re-deploying.

---

### 3.2 createAccountWithDefaults — Convenience Path

**Solidity signature:**
```solidity
function createAccountWithDefaults(
    address owner,
    uint256 salt,
    address guardian1,
    bytes calldata guardian1Sig,
    address guardian2,
    bytes calldata guardian2Sig,
    uint256 dailyLimit
) external returns (address account)
```

**Guardian acceptance signature format:**

Guardians must sign the following domain hash **before** account creation:

```
keccak256(abi.encodePacked(
    "ACCEPT_GUARDIAN",
    block.chainid,
    address(factory),
    owner,
    salt
)).toEthSignedMessageHash()
```

This binds the acceptance to a specific (chain, factory, owner, salt) tuple, preventing cross-chain and cross-factory replay.

**SDK pseudocode:**
```typescript
import { keccak256, encodePacked, concat } from "viem";

// Step 1: Build the guardian acceptance domain hash
const domainPreimage = encodePacked(
  ["string", "uint256", "address", "address", "uint256"],
  ["ACCEPT_GUARDIAN", chainId, FACTORY_ADDRESS, ownerAddress, salt]
);
const domainHash = keccak256(domainPreimage);
// EIP-191 prefix for toEthSignedMessageHash
const ethSignedHash = keccak256(concat([
  "0x19457468657265756d205369676e6564204d6573736167653a0a3332",
  domainHash,
]));

// Step 2: Each guardian signs
const guardian1Sig = await guardian1Account.sign({ hash: ethSignedHash });
const guardian2Sig = await guardian2Account.sign({ hash: ethSignedHash });

// Step 3: Deploy
const txHash = await walletClient.writeContract({
  address: FACTORY_ADDRESS,
  abi: FACTORY_ABI,
  functionName: "createAccountWithDefaults",
  args: [
    ownerAddress,
    salt,
    guardian1Address,
    guardian1Sig,
    guardian2Address,
    guardian2Sig,
    parseEther("1"),  // dailyLimit
  ],
});
```

> **Defaults applied**: All 8 algIds approved (0x01–0x08), minDailyLimit = dailyLimit/10, community guardian added as third guardian, chain-specific token defaults configured.

---

### 3.3 getAddress / getAddressWithDefaults — Predict Address

```solidity
function getAddress(
    address owner,
    uint256 salt,
    AAStarAirAccountBase.InitConfig memory config
) public view returns (address)

function getAddressWithDefaults(
    address owner,
    uint256 salt,
    address guardian1,       // ignored in address computation
    address guardian2,       // ignored in address computation
    uint256 dailyLimit       // ignored in address computation
) public view returns (address)
```

> **Important**: `getAddress` includes `keccak256(guardians, dailyLimit)` in the salt to prevent front-running. `getAddressWithDefaults` uses only `keccak256(owner, salt)` because guardian acceptance signatures already prevent front-running.

```typescript
const accountAddress = await publicClient.readContract({
  address: FACTORY_ADDRESS,
  abi: FACTORY_ABI,
  functionName: "getAddressWithDefaults",
  args: [ownerAddress, salt, guardian1Address, guardian2Address, parseEther("1")],
});
```

---

### 3.4 ERC-7828 Chain-Qualified Address

```solidity
function getChainQualifiedAddress(address account) external view returns (bytes32)
function getAddressWithChainId(
    address owner,
    uint256 salt,
    AAStarAirAccountBase.InitConfig memory config
) external view returns (address account, bytes32 chainQualified)
```

Returns `keccak256(account ++ chainId)` for cross-chain disambiguation when the same CREATE2 salt is used on multiple L2s.

---

## 4. Scenario 2: Account State Queries

### Description

Read account state for UI display and precondition checks before building UserOps.

### 4.1 Owner and EntryPoint

```solidity
function owner() external view returns (address)
function entryPoint() external view returns (address)
function accountId() external pure returns (string memory)  // returns "airaccount.v7@0.16.0"
```

### 4.2 Guardian Queries

```solidity
function guardians(uint256 i) external view returns (address)
// i = 0, 1, or 2. Returns address(0) for empty slots.

function guardianCount() external view returns (uint8)
```

**SDK pseudocode:**
```typescript
const count = await publicClient.readContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "guardianCount",
});

const guardianAddresses = await Promise.all(
  Array.from({ length: Number(count) }, (_, i) =>
    publicClient.readContract({
      address: accountAddress,
      abi: ACCOUNT_ABI,
      functionName: "guardians",
      args: [BigInt(i)],
    })
  )
);
```

### 4.3 Tier Limits

```solidity
function tier1Limit() external view returns (uint256)
function tier2Limit() external view returns (uint256)
```

Tier semantics:
- `value <= tier1Limit` → Tier 1 required (ECDSA/P256 single-sig)
- `tier1Limit < value <= tier2Limit` → Tier 2 required (P256 + BLS dual-factor)
- `value > tier2Limit` → Tier 3 required (P256 + BLS + Guardian)
- Both zero → tiering disabled (no tier enforcement)

### 4.4 Weight Configuration

```solidity
function weightConfig() external view returns (WeightConfig memory)

struct WeightConfig {
    uint8 passkeyWeight;   // P256 passkey weight (default: 3)
    uint8 ecdsaWeight;     // Owner ECDSA weight  (default: 2)
    uint8 blsWeight;       // DVT BLS weight      (default: 2)
    uint8 guardian0Weight; // Guardian[0] weight  (default: 1)
    uint8 guardian1Weight; // Guardian[1] weight  (default: 1)
    uint8 guardian2Weight; // Guardian[2] weight  (default: 1)
    uint8 _padding;        // Reserved
    uint8 tier1Threshold;  // Min weight for Tier 1 (default: 3; 0 = config uninitialized)
    uint8 tier2Threshold;  // Min weight for Tier 2 (default: 5)
    uint8 tier3Threshold;  // Min weight for Tier 3 (default: 6)
}
```

### 4.5 Guard State

```solidity
// Read guard address
function guard() external view returns (AAStarGlobalGuard)

// On the guard contract:
function dailyLimit() external view returns (uint256)
function todaySpent() external view returns (uint256)
function remainingDailyAllowance() external view returns (uint256)
function approvedAlgorithms(uint8 algId) external view returns (bool)
function tokenConfigs(address token) external view returns (TokenConfig memory)
function tokenDailySpent(address token, uint256 dayNumber) external view returns (uint256)
```

### 4.6 Required Tier for a Value

```solidity
function requiredTier(uint256 txValue) public view returns (uint8)
// Returns: 0 (tiering not configured), 1, 2, or 3
```

### 4.7 ERC-7579 Module State

```solidity
function isModuleInstalled(
    uint256 moduleTypeId,      // 1=Validator, 2=Executor, 3=Hook
    address module,
    bytes calldata additionalContext  // pass "0x" (unused)
) external view returns (bool)

function supportsModule(uint256 moduleTypeId) external pure returns (bool)
// Returns true for moduleTypeId in {1, 2, 3}
```

### 4.8 ERC-1271 Signature Validation

```solidity
function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4)
// Returns 0x1626ba7e if owner ECDSA sig is valid, 0xffffffff otherwise
```

### 4.9 EntryPoint Deposit

```solidity
function getDeposit() public view returns (uint256)
function addDeposit() public payable
function withdrawDepositTo(address payable to, uint256 amount) external  // onlyOwner
```

### 4.10 Social Recovery State

```solidity
function activeRecovery() external view returns (
    address newOwner,
    uint256 proposedAt,
    uint256 approvalBitmap,
    uint256 cancellationBitmap
)
```

---

## 5. Scenario 3: Execute Transactions

### Description

Send a transaction from the account. All execution goes through the EntryPoint as a UserOperation. The signature format determines the tier and security level.

### 5.1 execute — Single Call

```solidity
function execute(
    address dest,
    uint256 value,
    bytes calldata func
) external  // onlyOwnerOrEntryPoint, nonReentrant
```

**SDK pseudocode (ECDSA Tier 1):**
```typescript
import { encodeFunctionData, keccak256, concat } from "viem";

// Build calldata for the account's execute()
const callData = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "execute",
  args: [targetAddress, parseEther("0.01"), "0x"],
});

// Get nonce from EntryPoint
const nonce = await publicClient.readContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "getNonce",
  args: [accountAddress, 0n],  // key=0 for built-in routing
});

// Get UserOpHash from EntryPoint
const userOpHash = await publicClient.readContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "getUserOpHash",
  args: [{ sender: accountAddress, nonce, initCode: "0x", callData, ...gasParams, signature: "0x" }],
});

// Sign with ECDSA (algId 0x02 prefix)
const ethHash = keccak256(concat([
  "0x19457468657265756d205369676e6564204d6573736167653a0a3332",
  userOpHash,
]));
const rawSig = await ownerAccount.sign({ hash: ethHash });
const signature = `0x02${rawSig.slice(2)}` as Hex; // prepend algId=0x02

// Submit
const txHash = await walletClient.writeContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "handleOps",
  args: [[{ sender: accountAddress, nonce, ..., signature }], beneficiary],
});
```

> **Direct owner call**: The owner EOA can also call `execute()` directly without going through EntryPoint. In this case, the algId is forced to `ALG_ECDSA` (Tier 1) and guard limits apply.

---

### 5.2 executeBatch — Batch Operations

```solidity
function executeBatch(
    address[] calldata dest,
    uint256[] calldata value,
    bytes[] calldata func
) external  // onlyOwnerOrEntryPoint, nonReentrant
```

**SDK pseudocode:**
```typescript
const callData = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "executeBatch",
  args: [
    [token1, token2],       // dest array
    [0n, 0n],               // value array
    [transferCalldata1, transferCalldata2],  // func array
  ],
});
```

> **Guard behavior in batches**: The tier is determined once from the algId of the UserOp. For each call in the batch, `guard.checkTransaction()` updates `dailySpent` so subsequent calls see the cumulative spend. This prevents batch-based tier bypass (e.g., 10 × 0.1 ETH when tier1Limit = 0.5 ETH).

---

### 5.3 executeFromExecutor — Executor Module Path

```solidity
function executeFromExecutor(
    bytes32 mode,                // Must be bytes32(0) (single call only)
    bytes calldata executionCalldata  // abi.encodePacked(target(20), value(32), calldata)
) external nonReentrant returns (bytes[] memory returnData)
// Caller must be an installed Executor module (moduleTypeId=2)
```

> This is called by an installed Executor module, not directly by the user. The mode must be `bytes32(0)` (single execution, no flags). Execution calldata is tightly packed: `address(20) ++ uint256(32) ++ bytes(remaining)`.

---

## 6. Scenario 4: Tiered Security Configuration

### Description

Configure per-account tier limits and update them. All tier changes are owner-controlled. Guard limits are monotonic (can only tighten).

### 6.1 Tier Overview

| Tier | algIds | Condition | Typical Use |
|------|--------|-----------|-------------|
| 1 | 0x02, 0x03, 0x06, 0x08 | `value <= tier1Limit` | Small daily transactions |
| 2 | 0x04 | `tier1Limit < value <= tier2Limit` | Medium transfers |
| 3 | 0x05, 0x01 | `value > tier2Limit` | Large transfers |

> When `tier1Limit == 0 && tier2Limit == 0`, tiering is disabled entirely.

### 6.2 setTierLimits

```solidity
function setTierLimits(uint256 _tier1, uint256 _tier2) external  // onlyOwner
// Constraint: _tier1 <= _tier2 when both are non-zero
```

```typescript
const callData = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "setTierLimits",
  args: [parseEther("0.1"), parseEther("1.0")],
  // Tier 1: up to 0.1 ETH, Tier 2: 0.1–1.0 ETH, Tier 3: >1.0 ETH
});
```

### 6.3 Guard Configuration (Monotonic Only)

```solidity
// Approve algorithm in guard (add-only, never revoke)
function guardApproveAlgorithm(uint8 algId) external  // onlyOwner

// Decrease daily ETH limit (only decrease allowed)
function guardDecreaseDailyLimit(uint256 newLimit) external  // onlyOwner

// Add ERC20 token config (add-only, never remove)
function guardAddTokenConfig(
    address token,
    AAStarGlobalGuard.TokenConfig calldata config
) external  // onlyOwner

// Decrease a token's daily limit (only decrease allowed)
function guardDecreaseTokenDailyLimit(address token, uint256 newLimit) external  // onlyOwner
```

### 6.4 Weighted MultiSig Configuration (algId 0x07)

```solidity
function setWeightConfig(WeightConfig calldata config) external  // onlyOwner
// First call: direct owner setup
// Subsequent calls that weaken: requires guardian proposal (see proposeWeightChange)
```

**Validation rules:**
- `tier1Threshold > 0` (non-zero required)
- No single source weight can reach `tier1Threshold` alone (prevents single-point-of-failure)
- Thresholds must be non-decreasing: `tier1 <= tier2 <= tier3`

```typescript
const callData = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "setWeightConfig",
  args: [{
    passkeyWeight: 3,
    ecdsaWeight: 2,
    blsWeight: 2,
    guardian0Weight: 1,
    guardian1Weight: 1,
    guardian2Weight: 1,
    _padding: 0,
    tier1Threshold: 3,   // passkey alone = 3 >= 3: INVALID (single-point). Use 4+ with passkey=3.
    tier2Threshold: 5,
    tier3Threshold: 6,
  }],
});
// Note: passkeyWeight=3, tier1Threshold=4 is the minimum secure T1 config.
```

### 6.5 Weakening Weight Change (Guardian-Gated)

```solidity
function proposeWeightChange(WeightConfig calldata proposed) external  // onlyOwner
function approveWeightChange() external  // any guardian
function executeWeightChange() external  // anyone, after 2-day timelock + 2-of-3 approvals
function cancelWeightChange() external  // owner or any guardian
function pendingWeightChange() external view returns (WeightChangeProposal memory)
```

Timelock: 2 days. Approval threshold: 2-of-3 guardians. Expiry: 30 days from proposal.

---

## 7. Scenario 5: Social Recovery

### Description

Replace the account owner when the original private key is lost or compromised. Requires 2-of-3 guardian consensus plus a 2-day timelock. Guardians are set at account creation and can be updated by the owner.

### 7.1 Guardian Management

```solidity
function addGuardian(address _guardian) external  // onlyOwner, max 3 guardians
function removeGuardian(uint8 index) external     // onlyOwner, cancels active recovery
```

### 7.2 Recovery Flow

```
Guardian A calls proposeRecovery(newOwner)
          │
          │  (Proposal created with A's approval bit set)
          │  emit RecoveryProposed, RecoveryApproved (count=1)
          │
Guardian B calls approveRecovery()
          │
          │  emit RecoveryApproved (count=2)
          │
     [Wait 2 days — RECOVERY_TIMELOCK = 2 days]
          │
Anyone calls executeRecovery()
          │
          └─► owner = newOwner
              emit RecoveryExecuted, OwnerChanged
```

### 7.3 Function Signatures

```solidity
function proposeRecovery(address _newOwner) external
// Caller must be a guardian. Reverts RecoveryAlreadyActive if one is pending.

function approveRecovery() external
// Caller must be a guardian. Reverts AlreadyApproved if already voted.

function executeRecovery() external
// Anyone can call. Reverts if timelock not expired or threshold not met.

function cancelRecovery() external
// GUARDIAN ONLY — NOT the owner. Requires 2-of-3 guardian cancel votes.
// Owner cannot cancel: if key is stolen, attacker could block legitimate recovery.
```

> **clearStaleRecovery (SDK helper, not a contract function)**: On reused test accounts (fixed salts), a previous `activeRecovery` may persist. Clear it by calling `cancelRecovery()` from 2 guardians before calling `proposeRecovery()`.

### 7.4 SDK Pseudocode

```typescript
// Guardian A proposes recovery
const proposeTx = await guardian1WalletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "proposeRecovery",
  args: [newOwnerAddress],
});

// Guardian B approves
const approveTx = await guardian2WalletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "approveRecovery",
});

// Wait 2 days (172800 seconds)
// Then anyone can execute:
const executeTx = await anyWalletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "executeRecovery",
});
```

---

## 8. Scenario 6: ERC-7579 Module Management

### Description

Install and manage ERC-7579 modules on an account. AirAccount V7 supports three module types: Validator (1), Executor (2), and Hook (3). Installation requires guardian approval signatures.

### 8.1 Module Type IDs

| typeId | Type | Description | Example |
|--------|------|-------------|---------|
| 1 | Validator | Custom UserOp validation logic | AirAccountCompositeValidator |
| 2 | Executor | Can call `executeFromExecutor()` | AgentSessionKeyValidator (as executor) |
| 3 | Hook | `preCheck()` before every `execute()` | TierGuardHook |

### 8.2 installModule

```solidity
function installModule(
    uint256 moduleTypeId,
    address module,
    bytes calldata initData
) external  // onlyOwnerOrEntryPoint
```

**initData layout:**
```
[guardian_sig_1 (65 bytes)] [guardian_sig_2 (65 bytes, if threshold >= 100)] [module_init_data (remaining bytes)]
```

**Guardian signature count by threshold:**

| `_installModuleThreshold` | Sigs required |
|---------------------------|---------------|
| 0 (default, treated as 70) | 1 guardian sig |
| 1–40 | 0 sigs (owner-only) |
| 41–70 | 1 guardian sig |
| 71–100 | 2 guardian sigs |

**Guardian signature hash (v3 security fix — binds to module init config):**
```
keccak256(
    "INSTALL_MODULE" || block.chainid || address(account) || moduleTypeId || module || keccak256(moduleInitData)
).toEthSignedMessageHash()
```

**SDK pseudocode:**
```typescript
import { keccak256, encodePacked } from "viem";

async function buildGuardianInstallSig(
  guardian: WalletClient,
  accountAddr: Address,
  moduleTypeId: bigint,
  moduleAddr: Address,
  moduleInitData: Hex = "0x",
  chainId: bigint = 11155111n
): Promise<Hex> {
  const moduleInitDataHash = keccak256(moduleInitData);
  const preimage = encodePacked(
    ["string", "uint256", "address", "uint256", "address", "bytes32"],
    ["INSTALL_MODULE", chainId, accountAddr, moduleTypeId, moduleAddr, moduleInitDataHash]
  );
  const installHash = keccak256(preimage);
  const ethSignedHash = keccak256(concat([
    "0x19457468657265756d205369676e6564204d6573736167653a0a3332",
    installHash,
  ]));
  return guardian.account.sign({ hash: ethSignedHash });
}

// Install composite validator (threshold=70 → 1 guardian sig required)
const guardianSig = await buildGuardianInstallSig(
  guardian1Wallet, accountAddress, 1n, COMPOSITE_VALIDATOR_ADDRESS
);
// initData = guardian sig (65 bytes) + module init bytes (empty here)
const initData = guardianSig; // 65 bytes, no module init data

await walletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "installModule",
  args: [1n, COMPOSITE_VALIDATOR_ADDRESS, initData],
});
```

**TierGuardHook install with init data:**
```typescript
// TierGuardHook onInstall expects: abi.encode(guardAddress, tier1Limit, tier2Limit)
const moduleInitData = encodeAbiParameters(
  parseAbiParameters("address, uint256, uint256"),
  [guardContractAddress, parseEther("0.1"), parseEther("1.0")]
);
const guardianSig = await buildGuardianInstallSig(
  guardian1Wallet, accountAddress, 3n, TIER_GUARD_HOOK_ADDRESS, moduleInitData
);
// initData = sig (65 bytes) + moduleInitData
const initData = concat([guardianSig, moduleInitData]);

await walletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "installModule",
  args: [3n, TIER_GUARD_HOOK_ADDRESS, initData],
});
```

### 8.3 uninstallModule

```solidity
function uninstallModule(
    uint256 moduleTypeId,
    address module,
    bytes calldata deInitData
) external  // onlyOwnerOrEntryPoint
// Always requires 2 guardian sigs, regardless of _installModuleThreshold
```

**Guardian signature hash for uninstall:**
```
keccak256(
    "UNINSTALL_MODULE" || block.chainid || address(account) || moduleTypeId || module
).toEthSignedMessageHash()
```

```typescript
const uninstallSig1 = await buildUninstallSig(guardian1Wallet, accountAddress, moduleTypeId, moduleAddress);
const uninstallSig2 = await buildUninstallSig(guardian2Wallet, accountAddress, moduleTypeId, moduleAddress);
const deInitData = concat([uninstallSig1, uninstallSig2]); // 130 bytes

await walletClient.writeContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "uninstallModule",
  args: [moduleTypeId, moduleAddress, deInitData],
});
```

### 8.4 isModuleInstalled

```solidity
function isModuleInstalled(
    uint256 moduleTypeId,
    address module,
    bytes calldata additionalContext
) external view returns (bool)
```

```typescript
const installed = await publicClient.readContract({
  address: accountAddress,
  abi: ACCOUNT_ABI,
  functionName: "isModuleInstalled",
  args: [1n, COMPOSITE_VALIDATOR_ADDRESS, "0x"],
});
```

### 8.5 ERC-7579 Nonce-Key Routing

When using an installed Validator module, the UserOp nonce encodes the validator address:

```typescript
// nonce key = validator address (in bits 64–223 of the 256-bit nonce)
const validatorAddress = COMPOSITE_VALIDATOR_ADDRESS; // installed Validator module
const nonceKey = BigInt(validatorAddress); // 160-bit address as key
const nonce = await publicClient.readContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "getNonce",
  args: [accountAddress, nonceKey],
});
// The resulting nonce = (nonceKey << 64) | sequentialNonce
```

---

## 9. Scenario 7: AI Agent Session Keys

### Description

Grant a time-limited, scope-restricted signing key to an AI agent or automated service. The agent can operate within defined spending caps, call target restrictions, and velocity limits without requiring the owner's key for every transaction.

### 9.1 grantAgentSession

```solidity
function grantAgentSession(
    address sessionKey,
    AgentSessionConfig calldata cfg
) external  // msg.sender = account (via execute() UserOp or direct owner call)

struct AgentSessionConfig {
    uint48  expiry;              // Unix timestamp — session expires after this
    uint16  velocityLimit;       // Max calls per velocityWindow (0 = unlimited)
    uint32  velocityWindow;      // Window in seconds for velocity limiting
    address spendToken;          // ERC-20 token for spend cap (address(0) = ETH)
    uint256 spendCap;            // Max cumulative spend this session (0 = unlimited)
    bool    revoked;             // Owner can revoke at any time
    address[] callTargets;       // Allowlisted contracts (empty = all allowed)
    bytes4[]  selectorAllowlist; // Allowed function selectors (empty = all allowed)
}
```

**SDK pseudocode:**
```typescript
const agentPrivKey = generatePrivateKey();
const agentAccount = privateKeyToAccount(agentPrivKey);

const expiry = BigInt(Math.floor(Date.now() / 1000) + 24 * 60 * 60); // 24h from now

const cfg = {
  expiry,
  velocityLimit: 10,                    // max 10 calls per window
  velocityWindow: 3600,                 // 1 hour window
  spendToken: "0x0000000000000000000000000000000000000000", // ETH
  spendCap: parseEther("0.5"),          // max 0.5 ETH total this session
  revoked: false,
  callTargets: [UNISWAP_ROUTER],        // only allowed to call Uniswap
  selectorAllowlist: ["0x5ae401dc"],    // only exactInputSingle()
};

// Grant: owner sends UserOp that calls account.execute(agentValidator, 0, grantCalldata)
const grantCalldata = encodeFunctionData({
  abi: AGENT_VALIDATOR_ABI,
  functionName: "grantAgentSession",
  args: [agentAccount.address, cfg],
});

const executeCalldata = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "execute",
  args: [AGENT_SESSION_KEY_VALIDATOR, 0n, grantCalldata],
});

// Send as owner UserOp with ECDSA sig...
```

### 9.2 delegateSession

```solidity
function delegateSession(
    address subKey,
    AgentSessionConfig calldata subCfg
) external  // msg.sender = a valid session key (parentKey)
// Sub-session scope cannot exceed parent session scope
```

Scope rules (all checked on-chain):
- `subCfg.expiry <= parentCfg.expiry`
- `subCfg.spendCap <= parentCfg.spendCap` (0 = unlimited, only allowed if parent also has 0)
- `subCfg.velocityLimit <= parentCfg.velocityLimit`
- `subCfg.callTargets` must be a subset of `parentCfg.callTargets`
- `subCfg.selectorAllowlist` must be a subset of `parentCfg.selectorAllowlist`

### 9.3 revokeAgentSession

```solidity
function revokeAgentSession(address sessionKey) external
// msg.sender = account. Immediately marks the session as revoked.
```

### 9.4 recordSpend

```solidity
function recordSpend(address account, address sessionKey, uint256 amount) external
// msg.sender must equal account. Tracks cumulative spend against spendCap.
// Reverts SpendCapExceeded if totalSpent + amount > spendCap.
```

### 9.5 Session Key Signature Format

When using the session key to sign a UserOp:

**ECDSA session key (106 bytes total):**
```
[algId (0x08, 1 byte)]
[account address (20 bytes)]  ← security: prevents cross-account replay
[session key address (20 bytes)]
[ECDSA signature (65 bytes)]
```

**P256 session key (149 bytes total):**
```
[algId (0x08, 1 byte)]
[account address (20 bytes)]  ← security: prevents cross-account replay
[keyX (32 bytes)]
[keyY (32 bytes)]
[r (32 bytes)]
[s (32 bytes)]
```

```typescript
async function buildSessionKeySig(
  agentAccount: ReturnType<typeof privateKeyToAccount>,
  accountAddress: Address,
  hash: Hex
): Promise<Hex> {
  const ethHash = keccak256(concat([
    "0x19457468657265756d205369676e6564204d6573736167653a0a3332",
    hash,
  ]));
  const rawSig = await agentAccount.sign({ hash: ethHash });
  // [0x08][account][agentAddress][sig]
  return concat([
    toHex(0x08, { size: 1 }),
    accountAddress,
    agentAccount.address,
    rawSig,
  ]) as Hex;
}
```

### 9.6 Session State Queries

```solidity
function agentSessions(address account, address sessionKey) external view returns (
    uint48 expiry,
    uint16 velocityLimit,
    uint32 velocityWindow,
    address spendToken,
    uint256 spendCap,
    bool revoked
)

function sessionStates(address account, address sessionKey) external view returns (
    uint256 callCount,
    uint256 windowStart,
    uint256 totalSpent
)

function sessionKeyOwner(address sessionKey) external view returns (address parentAccount)
function delegatedBy(address account, address subKey) external view returns (address parentKey)
```

### 9.7 ERC-7715/ERC-7710 Compatibility

`AgentSessionKeyValidator.validateUserOp()` returns `validationData` with the session expiry packed in the high 48 bits:

```
validationData = uint256(cfg.expiry) << 160
// High 48 bits = validUntil, low 48 bits = validAfter (0)
// EntryPoint will reject the UserOp if block.timestamp > validUntil
```

---

## 10. Scenario 8: Force Exit L2

### Description

Emergency withdrawal from an L2 directly to L1 without relying on the standard bridge UI. Requires 2-of-3 guardian approval. Supports OP Stack and Arbitrum.

### 10.1 proposeForceExit

```solidity
function proposeForceExit(
    address target,
    uint256 value,
    bytes calldata data
) external  // msg.sender = account owner
// Reads guardian snapshot from account at proposal time.
// Reverts AlreadyProposed if a proposal is pending.
```

```typescript
// Owner calls this via the account's execute():
const proposeCalldata = encodeFunctionData({
  abi: FORCE_EXIT_ABI,
  functionName: "proposeForceExit",
  args: [l1RecipientAddress, parseEther("0.5"), "0x"],
});

const executeCalldata = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "execute",
  args: [FORCE_EXIT_MODULE_ADDRESS, 0n, proposeCalldata],
});
```

### 10.2 approveForceExit

```solidity
function approveForceExit(
    address account,
    bytes calldata guardianSig   // ECDSA sig (65 bytes) from guardian
) external
```

**Guardian signature hash:**
```
keccak256(
    "FORCE_EXIT" || block.chainid || account || target || value || data || proposedAt
).toEthSignedMessageHash()
```

```typescript
const proposal = await publicClient.readContract({
  address: FORCE_EXIT_MODULE_ADDRESS,
  abi: FORCE_EXIT_ABI,
  functionName: "getPendingExit",
  args: [accountAddress],
});

const preimage = encodePacked(
  ["string", "uint256", "address", "address", "uint256", "bytes", "uint256"],
  ["FORCE_EXIT", chainId, accountAddress, proposal.target, proposal.value, proposal.data, proposal.proposedAt]
);
const msgHash = keccak256(preimage);
const ethSignedHash = keccak256(concat([
  "0x19457468657265756d205369676e6564204d6573736167653a0a3332",
  msgHash,
]));

const guardianSig = await guardian1Account.sign({ hash: ethSignedHash });

await guardian1WalletClient.writeContract({
  address: FORCE_EXIT_MODULE_ADDRESS,
  abi: FORCE_EXIT_ABI,
  functionName: "approveForceExit",
  args: [accountAddress, guardianSig],
});
```

### 10.3 executeForceExit / cancelForceExit

```solidity
function executeForceExit(address account) external
// Anyone can call once 2-of-3 guardians approved.
// Calls L2 bridge precompile (OP or Arbitrum).

function cancelForceExit(address account) external
// Must be called by account owner (msg.sender == account) or by the account itself.
```

### 10.4 L2 Type Configuration

The module stores the L2 type per account (set during onInstall):

| `l2Type` | Chain | Precompile |
|----------|-------|-----------|
| 1 | OP Stack (Optimism, Base, etc.) | `0x4200...0016` (L2ToL1MessagePasser) |
| 2 | Arbitrum One | `0x0000...0064` (ArbSys) |

```typescript
// ForceExitModule onInstall data:
const l2Type = 1; // OP Stack
const moduleInitData = encodeAbiParameters(
  parseAbiParameters("uint8"),
  [l2Type]
);
// Pass as initData in installModule() call
```

---

## 11. Scenario 9: Privacy Transactions (Railgun)

### Description

AirAccount integrates with Railgun for shielded transactions. The TierGuardHook includes a `RailgunParser` that extracts token amounts from Railgun `transact()` calldata, allowing the guard to enforce spending limits on shielded transfers.

### 11.1 Railgun Call Format

Railgun's `transact()` and `transactV2()` functions are detected by the guard's calldata parser registry. When a call targets a Railgun contract, the parser reads the token output commitments to determine the effective transfer value for tier enforcement.

**Railgun contract selectors:**
- `transact(...)` — `0x83f3084f` (V2)
- `transactV2(...)` — varies by chain

### 11.2 TierGuard with Railgun

The `TierGuardHook.preCheck()` enforces the guard limits even for Railgun calls. The algId is read from the account's transient storage queue (via `getCurrentAlgId()`).

```typescript
// No special SDK handling needed — the guard automatically handles Railgun calls
// when a CalldataParserRegistry is configured on the account:
const setParserCalldata = encodeFunctionData({
  abi: ACCOUNT_ABI,
  functionName: "setParserRegistry",
  args: [PARSER_REGISTRY_ADDRESS],  // address(0) to disable
});
```

### 11.3 One-Account-Per-DApp (OAPD)

For complete privacy isolation, the recommended pattern is to deploy separate AirAccount instances per DApp:

```typescript
// Deploy a dedicated account for a specific DApp (e.g., Uniswap)
const dappSalt = keccak256(encodePacked(["address", "string"], [ownerAddress, "uniswap"]));
const dappAccount = await factory.getAddressWithDefaults(ownerAddress, dappSalt, g1, g2, dailyLimit);
```

---

## 12. Scenario 10: EIP-7702 Delegate Account

### Description

An existing EOA (MetaMask, etc.) delegates to `AirAccountDelegate` to gain AirAccount features without changing its address. Uses EIP-7702 Type 4 transactions.

### 12.1 Activation Flow

```
1. User signs Type 4 transaction:
   authorization_list = [{
     chainId: 11155111,
     address: AirAccountDelegate_impl,
     nonce: current_eoa_nonce,
     sig: eoa_signature
   }]

2. EOA's code becomes: 0xef0100 || AirAccountDelegate_address

3. User sends Type 2 tx to own address calling initialize():
   myEOA.initialize(guardian1, g1Sig, guardian2, g2Sig, dailyLimit)
```

### 12.2 initialize

```solidity
function initialize(
    address guardian1,
    bytes calldata g1Sig,
    address guardian2,
    bytes calldata g2Sig,
    uint256 dailyLimit
) external
// msg.sender must equal address(this) — the EOA calls itself
```

**Guardian acceptance signature for 7702 (different domain from V7):**
```
keccak256(abi.encodePacked(
    "ACCEPT_GUARDIAN_7702",
    block.chainid,
    address(this),   // the EOA address
    guardian         // the guardian's address
)).toEthSignedMessageHash()
```

### 12.3 execute / executeBatch

```solidity
function execute(address dest, uint256 value, bytes calldata data) external
function executeBatch(
    address[] calldata dest,
    uint256[] calldata value,
    bytes[] calldata data
) external
// Caller must be EntryPoint or address(this)
```

### 12.4 Guardian Rescue (replaces Social Recovery)

For EIP-7702 accounts, recovery is a "rescue" (asset transfer to new address) rather than owner rotation, because the EOA address cannot be changed.

```solidity
function initiateRescue(address rescueTo) external  // guardian only
function approveRescue() external                    // guardian only
function executeRescue() external                    // anyone, after timelock + 2-of-3 approvals
function cancelRescue() external                     // guardian only (2-of-3 cancel votes)
```

Timelock: 2 days. Approval threshold: 2-of-3 guardians.

### 12.5 View Functions

```solidity
function owner() external view returns (address)         // always returns address(this)
function entryPoint() external pure returns (address)    // 0x0000000071727De22E5E9d8BAf0edAc6f37da032
function getGuard() external view returns (address)
function getGuardians() external view returns (address[3] memory)
function isInitialized() external view returns (bool)
function getRescueState() external view returns (
    address rescueTo,
    uint256 rescueTimestamp,
    uint8 rescueApprovals,
    bool approved,
    uint8 cancellations
)
```

### 12.6 ERC-5564 Stealth Address

```solidity
function announceForStealth(
    address announcer,
    address stealthAddress,
    bytes calldata ephemeralPubKey,
    bytes calldata metadata
) external  // OnlySelf (must be called by the EOA itself)
```

Calls the ERC-5564 Announcer at `0x55649E01B5Df198D18D95b5cc5051630cfD45564` (same address on Ethereum mainnet and Sepolia).

---

## 13. ABI Quick Reference Cheatsheet

### AAStarAirAccountFactoryV7

| Function | Parameters | Access | EntryPoint Required |
|----------|-----------|--------|---------------------|
| `createAccount` | `(address owner, uint256 salt, InitConfig config)` | Anyone | No |
| `createAccountWithDefaults` | `(address owner, uint256 salt, address g1, bytes g1Sig, address g2, bytes g2Sig, uint256 dailyLimit)` | Anyone | No |
| `getAddress` | `(address owner, uint256 salt, InitConfig config)` view | Anyone | No |
| `getAddressWithDefaults` | `(address owner, uint256 salt, address g1, address g2, uint256 dailyLimit)` view | Anyone | No |
| `getChainQualifiedAddress` | `(address account)` view | Anyone | No |
| `getAddressWithChainId` | `(address owner, uint256 salt, InitConfig config)` view | Anyone | No |
| `implementation` | `()` view | Anyone | No |
| `entryPoint` | `()` view | Anyone | No |
| `defaultCommunityGuardian` | `()` view | Anyone | No |
| `defaultValidatorModule` | `()` view | Anyone | No |
| `defaultHookModule` | `()` view | Anyone | No |

### AAStarAirAccountV7 — Core

| Function | Parameters | Access | EntryPoint Required |
|----------|-----------|--------|---------------------|
| `initialize(no guard)` | `(address ep, address owner, InitConfig config)` | initializer | No |
| `initialize(with guard)` | `(address ep, address owner, InitConfig config, address guardAddr)` | initializer | No |
| `validateUserOp` | `(PackedUserOperation userOp, bytes32 hash, uint256 missingFunds)` | EntryPoint only | Yes |
| `execute` | `(address dest, uint256 value, bytes func)` | Owner or EntryPoint | Optional |
| `executeBatch` | `(address[] dest, uint256[] value, bytes[] func)` | Owner or EntryPoint | Optional |
| `executeFromExecutor` | `(bytes32 mode, bytes executionCalldata)` | Installed Executor only | No |
| `validateCompositeSignature` | `(bytes32 hash, bytes sig)` | Installed Validator only | No |

### AAStarAirAccountV7 — ERC-7579

| Function | Parameters | Access | EntryPoint Required |
|----------|-----------|--------|---------------------|
| `installModule` | `(uint256 typeId, address module, bytes initData)` | Owner or EntryPoint | Optional |
| `uninstallModule` | `(uint256 typeId, address module, bytes deInitData)` | Owner or EntryPoint | Optional |
| `isModuleInstalled` | `(uint256 typeId, address module, bytes ctx)` view | Anyone | No |
| `supportsModule` | `(uint256 typeId)` pure | Anyone | No |
| `accountId` | `()` pure | Anyone | No |
| `isValidSignature` | `(bytes32 hash, bytes sig)` view | Anyone | No |
| `supportsInterface` | `(bytes4 interfaceId)` pure | Anyone | No |
| `getCurrentAlgId` | `()` view | Anyone (hooks) | No |

### AAStarAirAccountBase — Configuration

| Function | Parameters | Access | Notes |
|----------|-----------|--------|-------|
| `setValidator` | `(address validator)` | Owner only | Sets external validator router |
| `setAggregator` | `(address aggregator)` | Owner only | Sets BLS batch aggregator |
| `setParserRegistry` | `(address registry)` | Owner only | Sets DeFi calldata parser |
| `setP256Key` | `(bytes32 x, bytes32 y)` | Owner only | Required for P256 algIds |
| `setTierLimits` | `(uint256 tier1, uint256 tier2)` | Owner only | tier1 <= tier2 |
| `setWeightConfig` | `(WeightConfig config)` | Owner only | First setup or strengthening |
| `setAgentWallet` | `(uint256 agentId, address wallet, address registry)` | Owner only | ERC-8004 binding |
| `guardApproveAlgorithm` | `(uint8 algId)` | Owner only | Monotonic (add-only) |
| `guardDecreaseDailyLimit` | `(uint256 newLimit)` | Owner only | Only decrease |
| `guardAddTokenConfig` | `(address token, TokenConfig config)` | Owner only | Add-only |
| `guardDecreaseTokenDailyLimit` | `(address token, uint256 newLimit)` | Owner only | Only decrease |
| `addGuardian` | `(address guardian)` | Owner only | Max 3 |
| `removeGuardian` | `(uint8 index)` | Owner only | Cancels active recovery |
| `proposeWeightChange` | `(WeightConfig proposed)` | Owner only | For weakening changes |
| `approveWeightChange` | `()` | Any guardian | 2-day timelock |
| `executeWeightChange` | `()` | Anyone | After timelock + 2-of-3 |
| `cancelWeightChange` | `()` | Owner or guardian | |

### AAStarAirAccountBase — Recovery

| Function | Parameters | Access | Notes |
|----------|-----------|--------|-------|
| `proposeRecovery` | `(address newOwner)` | Any guardian | Starts 2-day timelock |
| `approveRecovery` | `()` | Any guardian | Cast approval vote |
| `executeRecovery` | `()` | Anyone | After timelock + 2-of-3 |
| `cancelRecovery` | `()` | Guardians only | 2-of-3 cancel threshold |

### AAStarAirAccountBase — Deposit

| Function | Parameters | Access | Notes |
|----------|-----------|--------|-------|
| `addDeposit` | `()` payable | Anyone | Deposits ETH to EntryPoint |
| `getDeposit` | `()` view | Anyone | Reads EP balance |
| `withdrawDepositTo` | `(address payable to, uint256 amount)` | Owner only | Withdraws from EP |

### AgentSessionKeyValidator

| Function | Parameters | Access | Notes |
|----------|-----------|--------|-------|
| `grantAgentSession` | `(address sessionKey, AgentSessionConfig cfg)` | Account (msg.sender) | |
| `delegateSession` | `(address subKey, AgentSessionConfig subCfg)` | Valid session key | Scope cannot escalate |
| `revokeAgentSession` | `(address sessionKey)` | Account (msg.sender) | Immediate |
| `enforceSessionScope` | `(address account, address sessionKey, address target, bytes4 sel)` view | Anyone | Check before execute |
| `recordSpend` | `(address account, address sessionKey, uint256 amount)` | Account only | Track spend cap |
| `validateUserOp` | `(PackedUserOperation userOp, bytes32 hash)` | EntryPoint | Returns expiry in high bits |

### ForceExitModule

| Function | Parameters | Access | Notes |
|----------|-----------|--------|-------|
| `proposeForceExit` | `(address target, uint256 value, bytes data)` | Account owner | Reads guardians from account |
| `approveForceExit` | `(address account, bytes guardianSig)` | Anyone (with valid sig) | |
| `executeForceExit` | `(address account)` | Anyone | After 2-of-3 approvals |
| `cancelForceExit` | `(address account)` | Account or owner | |
| `getPendingExit` | `(address account)` view | Anyone | Full proposal including arrays |

---

## 14. Signature Format Reference

### algId Byte Table

| algId | Name | Total Bytes | Tier | Notes |
|-------|------|-------------|------|-------|
| `0x01` | BLS Triple (legacy M2) | variable | 3 | ECDSA×2 + BLS aggregate |
| `0x02` | ECDSA | 66 (with prefix) or 65 (raw) | 1 | Standard EIP-191 sig |
| `0x03` | P256 Passkey | 65 | 1 | EIP-7212 precompile |
| `0x04` | Cumulative T2 | variable | 2 | P256 + BLS DVT |
| `0x05` | Cumulative T3 | variable | 3 | P256 + BLS + Guardian |
| `0x06` | Combined T1 | 130 | 1 | P256 AND ECDSA simultaneously |
| `0x07` | Weighted MultiSig | variable | resolved | bitmap-driven, tier from weight |
| `0x08` | Session Key | 106 (ECDSA) or 149 (P256) | 1 | Via external validator |

---

### algId 0x02 — ECDSA (66 bytes)

```
[0x02][r (32)][s (32)][v (1)]
```

- Hash: `keccak256("\x19Ethereum Signed Message:\n32" || userOpHash)`
- Signer must equal `owner`
- EIP-2: `s` value must be in lower half of secp256k1 order
- Also accepted: raw 65-byte sig without algId prefix (backwards compatibility)

---

### algId 0x03 — P256 Passkey (65 bytes)

```
[0x03][r (32)][s (32)]
```

- Verified via EIP-7212 precompile at `0x0000...0100`
- Hash signed: `userOpHash` directly (no EIP-191 prefix)
- Requires `p256KeyX` and `p256KeyY` to be set on the account via `setP256Key()`

---

### algId 0x04 — Cumulative Tier 2 (variable length)

```
[0x04]
[P256_r (32)]
[P256_s (32)]
[nodeIdsLength (32)]              ← number of BLS nodes
[nodeIds (nodeIdsLength × 32)]
[blsSignature (256)]
[messagePoint (256)]
[messagePointSignature (65)]     ← owner signs keccak256(userOpHash || messagePoint)
```

Total minimum: `1 + 64 + 32 + 32 + 256 + 256 + 65 = 706 bytes` (with 1 node)

---

### algId 0x05 — Cumulative Tier 3 (variable length)

```
[0x05]
[P256_r (32)]
[P256_s (32)]
[nodeIdsLength (32)]
[nodeIds (nodeIdsLength × 32)]
[blsSignature (256)]
[messagePoint (256)]
[messagePointSignature (65)]     ← owner signs keccak256(userOpHash || messagePoint)
[guardianECDSA (65)]             ← any of guardians[0..2] signs userOpHash
```

Total minimum: `1 + 64 + 32 + 32 + 256 + 256 + 65 + 65 = 771 bytes` (with 1 node)

---

### algId 0x06 — Combined T1 / Zero-Trust (130 bytes)

```
[0x06]
[P256_r (32)]
[P256_s (32)]
[ECDSA_r (32)]
[ECDSA_s (32)]
[ECDSA_v (1)]
```

- Both P256 and ECDSA must be valid
- Neither alone can authorize a transaction (zero-trust)

---

### algId 0x07 — Weighted MultiSig (variable, bitmap-driven)

```
[0x07]
[sourceBitmap (1)]
[P256_r+s (64 bytes, if bit 0 set)]
[ECDSA r+s+v (65 bytes, if bit 1 set)]
[BLS block (variable, if bit 2 set)]
[guardian0 ECDSA (65 bytes, if bit 3 set)]
[guardian1 ECDSA (65 bytes, if bit 4 set)]
[guardian2 ECDSA (65 bytes, if bit 5 set)]
```

**sourceBitmap bits:**

| Bit | Source | Weight (default) |
|-----|--------|-----------------|
| 0 | P256 passkey | 3 |
| 1 | Owner ECDSA | 2 |
| 2 | BLS aggregate | 2 |
| 3 | Guardian[0] | 1 |
| 4 | Guardian[1] | 1 |
| 5 | Guardian[2] | 1 |
| 6-7 | Reserved | must be 0 |

**BLS block format within Weighted (bit 2):**
```
[nodeIdsLength (32)]
[nodeIds (N × 32)]
[blsSignature (256)]
[messagePoint (256)]
[messagePointSignature (65)]
```

**Tier resolution from accumulated weight:**
- `weight >= tier3Threshold` → resolved as ALG_CUMULATIVE_T3 (Tier 3)
- `weight >= tier2Threshold` → resolved as ALG_CUMULATIVE_T2 (Tier 2)
- `weight >= tier1Threshold` → resolved as ALG_ECDSA (Tier 1)
- `weight < tier1Threshold` → fails all tier checks

---

### algId 0x08 — Session Key (106 or 149 bytes)

**ECDSA session (106 bytes):**
```
[0x08]
[account address (20)]   ← must equal UserOp.sender
[session key address (20)]
[ECDSA r+s+v (65)]
```

**P256 session (149 bytes):**
```
[0x08]
[account address (20)]   ← must equal UserOp.sender
[keyX (32)]
[keyY (32)]
[r (32)]
[s (32)]
```

> The account address in bytes [1:21] must match `address(this)` of the account being validated. This prevents cross-account session key abuse.

---

### AirAccountCompositeValidator — ERC-7579 Nonce-Key Routing

When using the composite validator module via nonce-key routing, the UserOp signature is the full composite signature (starting with 0x04, 0x05, or 0x07). The validator calls back to `account.validateCompositeSignature()`.

```typescript
// Nonce key = address of the installed AirAccountCompositeValidator
const nonceKey = BigInt(COMPOSITE_VALIDATOR_ADDRESS);
const nonce = await publicClient.readContract({
  address: ENTRYPOINT,
  abi: ENTRYPOINT_ABI,
  functionName: "getNonce",
  args: [accountAddress, nonceKey],
});
// UserOp.nonce = (nonceKey << 64) | seqNonce

// Signature is the full T2/T3/Weighted composite sig with algId prefix
const signature = buildCumulativeT2Sig(...); // starts with 0x04
```

---

### Guardian Signatures for Module Install/Uninstall

```typescript
// Install (1 guardian sig at threshold=70):
hash = keccak256("INSTALL_MODULE" || chainId || account || typeId || module || keccak256(moduleInitData))
sig = guardian.sign(hash.toEthSignedMessageHash())
initData = concat([sig, moduleInitData])

// Uninstall (always 2 guardian sigs):
hash = keccak256("UNINSTALL_MODULE" || chainId || account || typeId || module)
sig1 = guardian1.sign(hash.toEthSignedMessageHash())
sig2 = guardian2.sign(hash.toEthSignedMessageHash())
deInitData = concat([sig1, sig2])
```

---

## 15. Custom Error Reference

### AAStarAirAccountBase / V7

| Error | Selector | Trigger Condition |
|-------|----------|------------------|
| `NotEntryPoint()` | | Caller is not `entryPoint` |
| `NotOwnerOrEntryPoint()` | | Caller is not owner or entryPoint |
| `NotOwner()` | | Caller is not owner |
| `ArrayLengthMismatch()` | | `dest.length != value.length` in executeBatch |
| `CallFailed(bytes)` | | Target call reverted |
| `InvalidP256Key()` | | Setting P256 key to (0, 0) |
| `InsufficientTier(uint8 required, uint8 provided)` | | Transaction value requires higher tier signature |
| `GuardianAlreadySet()` | | Guardian address already in list |
| `InvalidGuardian()` | | zero address, or guardian == owner |
| `MaxGuardiansReached()` | | Trying to add 4th guardian |
| `NotGuardian()` | `0xef6d0f02` | Caller is not a guardian |
| `NoActiveRecovery()` | | Recovery functions called without active proposal |
| `RecoveryTimelockNotExpired()` | `0xaa40cfc6` | `executeRecovery` before 2-day timelock |
| `AlreadyApproved()` | | Guardian already approved this recovery |
| `AlreadyCancelVoted()` | | Guardian already voted to cancel |
| `RecoveryNotApproved()` | | Insufficient guardian approvals for executeRecovery |
| `RecoveryAlreadyActive()` | `0x6e5510ce` | `proposeRecovery` when one is already pending |
| `InvalidNewOwner()` | | new owner is zero or same as current owner |
| `Reentrancy()` | `0xab143c06` | Reentrant call detected via transient storage |
| `InvalidGuardianSignature()` | | Guardian sig doesn't recover to expected address |
| `SessionScopeViolation()` | | Session key used outside allowed contract/selector |
| `InvalidTierConfig()` | | tier1 > tier2 when both non-zero |
| `ModuleAlreadyInstalled()` | | Module already installed, or second hook install |
| `ModuleNotInstalled()` | | Module not in registry |
| `InvalidModuleType()` | | typeId not in {1, 2, 3}, or mode != 0 in executeFromExecutor |
| `ModuleInvalid()` | | Module address is zero or has no bytecode |
| `InstallModuleUnauthorized()` | | Insufficient or invalid guardian sigs for installModule |
| `HookReverted()` | | Active hook's `preCheck()` call failed |
| `WeightConfigNotInitialized()` | | ALG_WEIGHTED used before setWeightConfig() |
| `InsecureWeightConfig()` | | Single weight >= tier1Threshold, or threshold ordering violated |
| `InsufficientWeight(uint8 tier, uint8 provided, uint8 required)` | | Accumulated weight below required threshold |
| `WeakeningRequiresProposal()` | | Direct setWeightConfig with weaker config; use proposeWeightChange |
| `WeightChangePending()` | | proposeWeightChange called while one is already pending |
| `WeightChangeTimelockNotExpired()` | | executeWeightChange before 2-day timelock |
| `WeightChangeNotApproved()` | | executeWeightChange without 2-of-3 approvals |
| `NoWeightChangeProposal()` | | Weight change operations without pending proposal |
| `WeightChangeAlreadyApproved()` | | Guardian already approved this weight change |

### AAStarGlobalGuard

| Error | Trigger Condition |
|-------|------------------|
| `OnlyAccount()` | Caller is not the bound account |
| `CanOnlyDecreaseLimit(uint256 current, uint256 requested)` | Trying to increase ETH daily limit |
| `BelowMinDailyLimit(uint256 requested, uint256 minimum)` | New limit below minDailyLimit floor |
| `DailyLimitExceeded(uint256 requested, uint256 remaining)` | ETH spend exceeds daily allowance |
| `AlgorithmNotApproved(uint8 algId)` | AlgId not in approvedAlgorithms whitelist |
| `TokenAlreadyConfigured(address token)` | Calling addTokenConfig on existing token |
| `TokenCanOnlyDecreaseLimit(address token, ...)` | Trying to increase token daily limit |
| `TokenDailyLimitExceeded(address token, ...)` | Token spend exceeds daily token allowance |
| `InsufficientTokenTier(uint8 required, uint8 provided)` | Token transfer requires higher tier sig |
| `InvalidTokenConfig(address token, ...)` | tier1 > tier2 or tier2 > daily or tiers without dailyLimit |

### AgentSessionKeyValidator

| Error | Trigger Condition |
|-------|------------------|
| `SessionExpired()` | Session past expiry timestamp |
| `SessionRevoked()` | Session marked revoked |
| `SessionNotFound()` | No session for (account, sessionKey) pair |
| `VelocityLimitExceeded(uint16 limit, uint256 count)` | Too many calls in velocity window |
| `SpendCapExceeded(uint256 cap, uint256 spent)` | Cumulative spend exceeds cap |
| `CallTargetForbidden(address target)` | Target not in callTargets allowlist |
| `SelectorForbidden(address target, bytes4 selector)` | Selector not in selectorAllowlist |
| `InvalidExpiry()` | expiry <= block.timestamp |
| `OnlyAccountOwner()` | recordSpend called by non-account |
| `CallerNotSessionKey()` | delegateSession caller has no session |
| `ScopeEscalationDenied()` | Sub-session tries to exceed parent scope |
| `ParentSessionExpired()` | Parent session expired/revoked during delegation |
| `MaxTargetsExceeded()` | callTargets.length > 20 |

### ForceExitModule

| Error | Trigger Condition |
|-------|------------------|
| `AlreadyProposed()` | proposeForceExit with pending proposal |
| `NoProposal()` | approve/execute/cancel without pending proposal |
| `AlreadyApproved()` | Guardian already approved this proposal |
| `NotEnoughApprovals()` | executeForceExit before 2-of-3 approvals |
| `InvalidGuardianSig()` | Recovered signer not in guardian snapshot |
| `UnsupportedL2Type()` | l2Type not in {1, 2} |
| `NotOwner()` | cancelForceExit caller is not account owner |

### AirAccountDelegate (EIP-7702)

| Error | Trigger Condition |
|-------|------------------|
| `AlreadyInitialized()` | initialize() called twice |
| `NotInitialized()` | Functions called before initialize() |
| `OnlySelfOrEntryPoint()` | execute/executeBatch called by unauthorized |
| `OnlySelf()` | Owner-only functions called by others |
| `OnlyGuardian()` | Rescue functions called by non-guardian |
| `InvalidGuardianSignature(address guardian)` | Guardian acceptance sig mismatch |
| `NoRescuePending()` | Rescue functions without active proposal |
| `RescueTimelockNotExpired()` | executeRescue before 2-day timelock |
| `RescueNotApproved()` | executeRescue without 2-of-3 approvals |
| `GuardianAlreadyApproved()` | Guardian already approved rescue |
| `GuardianAlreadyCancelVoted()` | Guardian already voted to cancel rescue |
| `RescueAlreadyPending()` | initiateRescue when one is pending |
| `InvalidAddress()` | zero address in guardian or rescueTo |
| `ArrayLengthMismatch()` | executeBatch array length mismatch |
| `CallFailed(bytes reason)` | Target call reverted |

---

*This document reflects the AirAccount V7 contract state as of milestone M7, branch `M7`, commit `70b4695`. All Sepolia addresses are live and verified as of 2026-03-21.*
