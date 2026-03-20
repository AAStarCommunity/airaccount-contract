# M6.3 Weight Config — Frontend Developer Guide

**Contract**: `AAStarAirAccountBase` (all deployed AirAccount V7 instances)
**Feature**: ALG_WEIGHTED (algId `0x07`) — owner configures per-source signature weights
**Schema**: `configs/weight-config-schema.json`
**Last updated**: 2026-03-20

---

## 1. On-Chain Data Structures

### WeightConfig struct (10 bytes, 1 storage slot)

```solidity
struct WeightConfig {
    uint8 passkeyWeight;   // P256/WebAuthn passkey  (slot weight)
    uint8 ecdsaWeight;     // Owner ECDSA key        (slot weight)
    uint8 blsWeight;       // DVT BLS aggregate      (slot weight)
    uint8 guardian0Weight; // Guardian[0] ECDSA      (slot weight)
    uint8 guardian1Weight; // Guardian[1] ECDSA      (slot weight)
    uint8 guardian2Weight; // Guardian[2] ECDSA      (slot weight)
    uint8 _padding;        // Reserved (always 0)
    uint8 tier1Threshold;  // Min accumulated weight for Tier 1 (small txns)
    uint8 tier2Threshold;  // Min accumulated weight for Tier 2 (medium txns)
    uint8 tier3Threshold;  // Min accumulated weight for Tier 3 (large txns)
}
```

### Security invariant (enforced on-chain)
- `tier1Threshold > 0` (0 means config uninitialized — ALG_WEIGHTED will fail)
- Each individual weight **must be < tier1Threshold** (no single source can alone pass Tier 1)
- This prevents single-point-of-failure even for Tier 1

### WeightChangeProposal struct (governance flow for weakening changes)

```solidity
struct WeightChangeProposal {
    WeightConfig proposed;
    uint256 proposedAt;       // block.timestamp of proposal
    uint256 approvalBitmap;   // bit 0 = guardian0 approved, bit 1 = guardian1, etc.
}
```

---

## 2. Contract Functions

### Read

```solidity
// Current weight config — returns WeightConfig tuple
function weightConfig() external view returns (
    uint8 passkeyWeight, uint8 ecdsaWeight, uint8 blsWeight,
    uint8 guardian0Weight, uint8 guardian1Weight, uint8 guardian2Weight,
    uint8 _padding,
    uint8 tier1Threshold, uint8 tier2Threshold, uint8 tier3Threshold
)

// Pending governance proposal (proposedAt == 0 means none pending)
function pendingWeightChange() external view returns (
    WeightConfig proposed,
    uint256 proposedAt,
    uint256 approvalBitmap
)
```

### Write (state-changing)

```solidity
// ── Direct set (only allowed if the change STRENGTHENS security) ──
// Caller: account owner (msg.sender == owner)
function setWeightConfig(WeightConfig calldata config) external onlyOwner

// ── Governance flow (required when WEAKENING security) ──
// Step 1: owner proposes
function proposeWeightChange(WeightConfig calldata proposed) external onlyOwner

// Step 2: each guardian approves (call once per guardian EOA)
function approveWeightChange() external   // msg.sender must be a configured guardian

// Step 3: anyone calls after 2-day timelock + 2-of-3 approvals
function executeWeightChange() external

// Cancel (owner or any guardian can cancel)
function cancelWeightChange() external
```

### What counts as "weakening"?
Any of: decrease in any source weight, OR decrease in any tier threshold. The contract reverts `setWeightConfig` for weakening changes and requires the governance flow instead.

---

## 3. TypeScript / Viem Integration

### 3.1 Read current config

```typescript
import { createPublicClient, http } from "viem";
import { sepolia } from "viem/chains";

const ACCOUNT_ABI = [
  {
    name: "weightConfig",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "passkeyWeight",   type: "uint8" },
      { name: "ecdsaWeight",     type: "uint8" },
      { name: "blsWeight",       type: "uint8" },
      { name: "guardian0Weight", type: "uint8" },
      { name: "guardian1Weight", type: "uint8" },
      { name: "guardian2Weight", type: "uint8" },
      { name: "_padding",        type: "uint8" },
      { name: "tier1Threshold",  type: "uint8" },
      { name: "tier2Threshold",  type: "uint8" },
      { name: "tier3Threshold",  type: "uint8" },
    ],
  },
  {
    name: "pendingWeightChange",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "proposed",        type: "tuple", components: [
          { name: "passkeyWeight",   type: "uint8" },
          { name: "ecdsaWeight",     type: "uint8" },
          { name: "blsWeight",       type: "uint8" },
          { name: "guardian0Weight", type: "uint8" },
          { name: "guardian1Weight", type: "uint8" },
          { name: "guardian2Weight", type: "uint8" },
          { name: "_padding",        type: "uint8" },
          { name: "tier1Threshold",  type: "uint8" },
          { name: "tier2Threshold",  type: "uint8" },
          { name: "tier3Threshold",  type: "uint8" },
      ]},
      { name: "proposedAt",      type: "uint256" },
      { name: "approvalBitmap",  type: "uint256" },
    ],
  },
] as const;

const client = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });

const config = await client.readContract({
  address: accountAddr,
  abi: ACCOUNT_ABI,
  functionName: "weightConfig",
});

// config.passkeyWeight, config.tier1Threshold, etc.
```

### 3.2 Set config directly (strengthening only)

```typescript
import { createWalletClient, http, encodeFunctionData } from "viem";

const SET_WEIGHT_CONFIG_ABI = [{
  name: "setWeightConfig",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{
    name: "config",
    type: "tuple",
    components: [
      { name: "passkeyWeight",   type: "uint8" },
      { name: "ecdsaWeight",     type: "uint8" },
      { name: "blsWeight",       type: "uint8" },
      { name: "guardian0Weight", type: "uint8" },
      { name: "guardian1Weight", type: "uint8" },
      { name: "guardian2Weight", type: "uint8" },
      { name: "_padding",        type: "uint8" },
      { name: "tier1Threshold",  type: "uint8" },
      { name: "tier2Threshold",  type: "uint8" },
      { name: "tier3Threshold",  type: "uint8" },
    ],
  }],
  outputs: [],
}] as const;

// Build the WeightConfig (must match struct field order exactly)
const newConfig = {
  passkeyWeight:   3,
  ecdsaWeight:     2,
  blsWeight:       2,
  guardian0Weight: 1,
  guardian1Weight: 1,
  guardian2Weight: 1,
  _padding:        0,
  tier1Threshold:  3,  // P256 alone = Tier 1
  tier2Threshold:  5,  // P256 + ECDSA = Tier 2
  tier3Threshold:  6,  // P256 + ECDSA + BLS = Tier 3
};

// This call is submitted as a UserOperation (not a direct tx)
// because the account is an ERC-4337 smart contract wallet.
// The owner signs the UserOp with their ECDSA key (algId 0x02).
const callData = encodeFunctionData({
  abi: SET_WEIGHT_CONFIG_ABI,
  functionName: "setWeightConfig",
  args: [newConfig],
});

// Pass callData to your ERC-4337 UserOp builder as the execute() payload:
// execute(dest=accountAddr, value=0, func=callData)
```

### 3.3 Governance flow (weakening change)

```typescript
// ── Step 1: Owner proposes ────────────────────────────────────────────────

const PROPOSE_ABI = [{
  name: "proposeWeightChange",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [{ name: "proposed", type: "tuple", components: [ /* same as above */ ] }],
  outputs: [],
}] as const;

// Submit via UserOp (owner signs)
const proposeCallData = encodeFunctionData({
  abi: PROPOSE_ABI,
  functionName: "proposeWeightChange",
  args: [weakerConfig],
});

// ── Step 2: Each guardian approves (direct tx, not UserOp) ───────────────

const APPROVE_ABI = [{
  name: "approveWeightChange",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [],
  outputs: [],
}] as const;

// Guardians send a DIRECT EOA transaction (they don't have an AA account)
const approveTx = await walletClient.writeContract({
  address: accountAddr,
  abi: APPROVE_ABI,
  functionName: "approveWeightChange",
  // walletClient.account = guardian EOA
});

// ── Step 3: Execute after 2-day timelock ─────────────────────────────────

const EXECUTE_ABI = [{
  name: "executeWeightChange",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [],
  outputs: [],
}] as const;

// Anyone can call (typically the owner or a guardian)
await walletClient.writeContract({
  address: accountAddr,
  abi: EXECUTE_ABI,
  functionName: "executeWeightChange",
});
```

### 3.4 Check approval status

```typescript
const pending = await client.readContract({
  address: accountAddr,
  abi: ACCOUNT_ABI,
  functionName: "pendingWeightChange",
});

if (pending.proposedAt === 0n) {
  console.log("No pending proposal");
} else {
  const bitmap = pending.approvalBitmap;
  const g0Approved = (bitmap & 1n) !== 0n;
  const g1Approved = (bitmap & 2n) !== 0n;
  const g2Approved = (bitmap & 4n) !== 0n;
  const approvalCount = [g0Approved, g1Approved, g2Approved].filter(Boolean).length;

  const timelockExpiry = pending.proposedAt + BigInt(2 * 24 * 3600); // 2 days
  const isTimelockDone = BigInt(Math.floor(Date.now() / 1000)) >= timelockExpiry;

  console.log(`Approvals: ${approvalCount}/3 (need 2)`);
  console.log(`Timelock done: ${isTimelockDone}`);
  console.log(`Can execute: ${approvalCount >= 2 && isTimelockDone}`);
}
```

---

## 4. UI Components Required

### 4.1 Weight Simulator (no tx needed)

Show users: "if I check these sources, what tier can I reach?"

```typescript
function simulateWeight(
  sources: { passkey?: boolean; ecdsa?: boolean; bls?: boolean; g0?: boolean; g1?: boolean; g2?: boolean },
  config: WeightConfig
): { totalWeight: number; tier: 0 | 1 | 2 | 3 } {
  let w = 0;
  if (sources.passkey) w += config.passkeyWeight;
  if (sources.ecdsa)   w += config.ecdsaWeight;
  if (sources.bls)     w += config.blsWeight;
  if (sources.g0)      w += config.guardian0Weight;
  if (sources.g1)      w += config.guardian1Weight;
  if (sources.g2)      w += config.guardian2Weight;

  const tier = w >= config.tier3Threshold ? 3
             : w >= config.tier2Threshold ? 2
             : w >= config.tier1Threshold ? 1
             : 0;
  return { totalWeight: w, tier };
}
```

### 4.2 Validation before submit

```typescript
function validateWeightConfig(config: WeightConfig): string | null {
  if (config.tier1Threshold === 0) return "tier1Threshold cannot be 0";

  const sources = [
    config.passkeyWeight, config.ecdsaWeight, config.blsWeight,
    config.guardian0Weight, config.guardian1Weight, config.guardian2Weight,
  ];

  for (const w of sources) {
    if (w >= config.tier1Threshold) {
      return "No single source weight can equal or exceed tier1Threshold (single-point-of-failure)";
    }
  }

  if (config.tier2Threshold < config.tier1Threshold)
    return "tier2Threshold must be >= tier1Threshold";
  if (config.tier3Threshold < config.tier2Threshold)
    return "tier3Threshold must be >= tier2Threshold";

  const maxAchievable = sources.reduce((a, b) => a + b, 0);
  if (maxAchievable < config.tier3Threshold)
    return `tier3Threshold (${config.tier3Threshold}) unreachable — max weight is ${maxAchievable}`;

  return null; // valid
}
```

### 4.3 Preset loader

```typescript
// Load from configs/weight-config-schema.json examples
const PRESETS = [
  {
    name: "Personal Standard",
    config: {
      passkeyWeight: 3, ecdsaWeight: 2, blsWeight: 0,
      guardian0Weight: 0, guardian1Weight: 0, guardian2Weight: 0, _padding: 0,
      tier1Threshold: 3, tier2Threshold: 5, tier3Threshold: 6,
    },
  },
  {
    name: "Family 2-of-3",
    config: {
      passkeyWeight: 0, ecdsaWeight: 0, blsWeight: 0,
      guardian0Weight: 2, guardian1Weight: 2, guardian2Weight: 2, _padding: 0,
      tier1Threshold: 2, tier2Threshold: 4, tier3Threshold: 6,
    },
  },
  {
    name: "High Security",
    config: {
      passkeyWeight: 3, ecdsaWeight: 0, blsWeight: 2,
      guardian0Weight: 2, guardian1Weight: 2, guardian2Weight: 0, _padding: 0,
      tier1Threshold: 5, tier2Threshold: 7, tier3Threshold: 9,
    },
  },
  {
    name: "DAO Treasury",
    config: {
      passkeyWeight: 1, ecdsaWeight: 1, blsWeight: 4,
      guardian0Weight: 3, guardian1Weight: 3, guardian2Weight: 3, _padding: 0,
      tier1Threshold: 4, tier2Threshold: 7, tier3Threshold: 11,
    },
  },
];
```

---

## 5. UI Flow Summary

```
User opens Weight Config page
│
├─ Read current weightConfig from chain
├─ Show current weights + tier thresholds
├─ Show "Weight Simulator" (checkbox per source → live tier calculation)
│
├─ User adjusts sliders
│   ├─ Validate with validateWeightConfig()
│   └─ Check if change is weakening vs strengthening
│
├─ [Strengthening] → call setWeightConfig() via UserOp
│   └─ Owner signs with current algId
│
└─ [Weakening] → Governance flow
    ├─ Step 1: Owner submits proposeWeightChange() via UserOp
    ├─ Step 2: Show pending proposal + guardian approval status
    │   ├─ Guardian0 approval button (direct EOA tx)
    │   ├─ Guardian1 approval button
    │   └─ Guardian2 approval button
    ├─ Countdown: 2-day timelock remaining
    └─ Step 3: executeWeightChange() (any EOA, shown when ready)
```

---

## 6. Events to Listen For

```solidity
event WeightConfigUpdated(WeightConfig config);         // direct set or execute complete
event WeightChangeProposed(WeightConfig proposed, address indexed proposedBy);
event WeightChangeApproved(address indexed guardian, uint256 approvalCount);
event WeightChangeExecuted(WeightConfig oldConfig, WeightConfig newConfig);
event WeightChangeCancelled();
```

```typescript
// Watch for approval events
const unwatch = client.watchContractEvent({
  address: accountAddr,
  abi: EVENTS_ABI,
  eventName: "WeightChangeApproved",
  onLogs: (logs) => {
    // Re-fetch pendingWeightChange and update UI
  },
});
```

---

## 7. Important Notes

1. **UserOp vs direct tx**: `setWeightConfig`, `proposeWeightChange` must be submitted as **UserOperations** (the account is an ERC-4337 smart wallet; only `execute()` + `executeBatch()` accept external calls). Guardians' `approveWeightChange()` is a **direct EOA transaction** since guardians are normal wallets.

2. **`_padding` field**: Always send as `0`. This is a reserved slot for a future 7th signature source.

3. **Weights are relative**: The values (0–255) have no unit — only their ratio and sum relative to thresholds matter. Example: `{p256=3, tier1=3}` and `{p256=6, tier1=6}` behave identically.

4. **No on-chain simulation**: The contract doesn't expose a "simulate" function. Do weight math client-side (`simulateWeight()` above) before showing the UI.

5. **Uninitialized config**: If `weightConfig.tier1Threshold == 0`, algId `0x07` will revert. Always initialize before granting ALG_WEIGHTED sessions.

6. **Timelock is 2 days**: After `proposeWeightChange`, guardians can approve immediately but `executeWeightChange` will revert until 48h have passed from the proposal timestamp.
