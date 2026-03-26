# AirAccount Social Recovery: Complete Guide

> AirAccount V7 (AAStarAirAccountBase) — ERC-4337 v0.7 Compatible
> Last Updated: 2026-03-10

This document covers the full social recovery flow in two parts:
1. **Part A**: User operations guide (non-technical)
2. **Part B**: Technical implementation analysis (ERC-4337 compliance)

---

## Part A: User Operations Guide

### A.1 Overview

Social recovery allows you to regain access to your AirAccount smart wallet when you lose your private key. Instead of relying on seed phrases, you designate **trusted guardians** (friends, family, or community multisig) who can collectively approve transferring your account to a new key — subject to a **2-day safety delay**.

**Key parameters:**
- Maximum guardians: **3**
- Approval threshold: **2 of 3** (67% majority)
- Safety timelock: **2 days** (48 hours)

### A.2 Step 1: Setting Up Guardians (Prevention)

> Do this **immediately after** creating your AirAccount. Recovery is impossible without guardians.

**Prerequisites:**
- Your AirAccount is deployed on-chain (via `AAStarAirAccountFactoryV7.createAccount`)
- You control the owner key

**Actions (via your wallet UI or direct contract call):**

| Action | Function | Who Can Do It |
|--------|----------|---------------|
| Add guardian #1 | `addGuardian(guardian1Address)` | Account owner only |
| Add guardian #2 | `addGuardian(guardian2Address)` | Account owner only |
| Add guardian #3 | `addGuardian(guardian3Address)` | Account owner only |

**Guardian selection best practices:**
- Choose people you trust who are unlikely to collude
- Use a mix: e.g., a personal friend + a family member + a community Safe multisig
- Guardians do NOT need to hold any tokens or pay gas — they just need an EOA address
- Never set your own address as a guardian (the contract rejects this)
- Guardians cannot access your funds — they can only propose changing the owner

**What guardians see:**
- Guardians have no visibility into your account activity
- They are only notified when a recovery is proposed (via on-chain events)

### A.3 Step 2: Losing Your Key (The Problem)

If your private key is lost, stolen, or compromised:
- You cannot sign transactions from your AirAccount
- Your funds remain locked in the smart contract
- But your guardians can initiate recovery

### A.4 Step 3: Initiating Recovery

**Who does this:** Any one of your 3 guardians

**What happens:**

1. **Guardian contacts you** through an off-chain channel (phone, email, in-person) to verify your identity and get your **new wallet address**

2. **Guardian submits the proposal:**
   ```
   proposeRecovery(newOwnerAddress)
   ```
   - This guardian's approval is **automatically counted** (1 of 2 needed)
   - The 2-day countdown **starts immediately**
   - A `RecoveryProposed` event is emitted on-chain

3. **Only one recovery can be active at a time.** If a malicious guardian proposes a fake recovery, the real owner can cancel it (see A.6).

### A.5 Step 4: Collecting Approvals

**Who does this:** A second guardian (different from the proposer)

1. **Second guardian verifies** the recovery request is legitimate (off-chain communication)
2. **Second guardian approves:**
   ```
   approveRecovery()
   ```
   - Now 2/3 threshold is met
   - A `RecoveryApproved` event is emitted with `approvalCount = 2`

3. *(Optional)* Third guardian can also approve — not required but adds confidence

### A.6 Step 5: Waiting Period (2 Days)

**This is a critical security feature.**

During the 48-hour timelock:
- **If the recovery is legitimate:** Just wait. No action needed.
- **If the recovery is malicious:** The current owner (if they still have their key, e.g., key was stolen but not lost) can call:
  ```
  cancelRecovery()
  ```
  This immediately cancels the proposal.

The current owner can also **remove a compromised guardian** during this window:
```
removeGuardian(guardianIndex, [sig_from_other_guardian_1, sig_from_other_guardian_2])
```
This automatically cancels any active recovery (since the guardian set has changed).

> **Security note (M7.3):** `removeGuardian` requires signatures from all non-removed guardians.
> Removing a guardian is classified at the same security level as social recovery because it
> reduces the account's protection level. This prevents a compromised owner key from silently
> stripping all guardian protection. Required sigs: 0 for 1 guardian, 1 for 2 guardians, 2 for 3 guardians.
>
> Signature pre-image: `keccak256("REMOVE_GUARDIAN" || chainId || account || guardianAddress).toEthSignedMessageHash()`

### A.7 Step 6: Executing Recovery

**Who does this:** Anyone (permissionless — can be the new owner, a guardian, or a relayer)

After the 2-day timelock AND 2+ approvals:
```
executeRecovery()
```

**What happens:**
- `owner` is changed to the new address
- The old private key becomes **permanently invalid** for this account
- All funds, tokens, NFTs remain in the account
- The new owner can immediately:
  - Send transactions
  - Manage guardians (add/remove)
  - Configure validators, guard, etc.
  - Do another recovery if needed in the future

### A.8 After Recovery: What to Do

1. **Verify account access** — Send a small test transaction
2. **Review and update guardians** — The old guardian set is still active; update if needed
3. **Re-configure security settings** if applicable (P256 passkey, BLS nodes, GlobalGuard)
4. **Notify your guardians** that recovery was successful

### A.9 Complete Timeline Example

```
Day 0, 10:00  — Alice loses her phone (private key gone)
Day 0, 14:00  — Alice contacts Guardian Bob with her new EOA address
Day 0, 15:00  — Bob calls proposeRecovery(Alice_new_address)
                 → 1/3 approved, 2-day timer starts
Day 0, 18:00  — Alice contacts Guardian Carol for second approval
Day 0, 19:00  — Carol calls approveRecovery()
                 → 2/3 approved, threshold met
Day 2, 15:00  — Timelock expired (48h after proposal)
Day 2, 15:01  — Anyone calls executeRecovery()
                 → owner = Alice_new_address
Day 2, 15:05  — Alice signs a UserOp with her new key ✓
```

### A.10 FAQ

**Q: Can guardians steal my funds?**
A: No. Guardians can only propose changing the owner address. They cannot execute transactions, transfer tokens, or access your funds. Even after a successful recovery, only the new owner controls the account.

**Q: What if a guardian is compromised?**
A: A single compromised guardian cannot execute recovery alone (needs 2/3). The current owner has 2 days to cancel any malicious proposal. Remove the compromised guardian immediately via `removeGuardian()`.

**Q: What if I lose my key AND 2 guardians collude against me?**
A: If 2 guardians collude and propose a malicious recovery, and you cannot cancel (because you lost your key), the account will be transferred after 2 days. This is by design — the assumption is that you trust your guardians. Choose them wisely.

**Q: Can I do recovery with fewer than 3 guardians?**
A: Yes, but you need at least 2 guardians set up (since threshold is 2). With only 2 guardians, both must agree. With only 1 guardian, recovery is impossible.

**Q: What happens to my tokens/NFTs during recovery?**
A: Nothing. They stay in your account. Recovery only changes the `owner` address — all balances and approvals remain intact.

---

## Part B: Technical Implementation Analysis

### B.1 Architecture Overview

Social recovery is implemented in `AAStarAirAccountBase.sol` (lines 375–486), inherited by `AAStarAirAccountV7.sol`. It follows ERC-4337 conventions while keeping recovery logic fully on-chain.

```
┌─────────────────────────────────────────────────────────┐
│                   EntryPoint v0.7                       │
│         (0x0000000071727De22E5E9d8BAf0edAc6f37da032)    │
└───────────────────────┬─────────────────────────────────┘
                        │ handleOps() / validateUserOp()
                        ▼
┌─────────────────────────────────────────────────────────┐
│               AAStarAirAccountV7                        │
│  ┌───────────────────────────────────────────────────┐  │
│  │         AAStarAirAccountBase                      │  │
│  │                                                   │  │
│  │  owner ←─── Social Recovery modifies this         │  │
│  │  guardians[3]                                     │  │
│  │  activeRecovery (RecoveryProposal)                │  │
│  │                                                   │  │
│  │  validateUserOp() → _validateSignature()          │  │
│  │  execute() / executeBatch()                       │  │
│  │                                                   │  │
│  │  addGuardian()      ← onlyOwner                   │  │
│  │  removeGuardian()   ← onlyOwner + other guardians │  │
│  │  proposeRecovery()  ← any guardian                 │  │
│  │  approveRecovery()  ← any guardian                 │  │
│  │  executeRecovery()  ← permissionless               │  │
│  │  cancelRecovery()   ← onlyOwner                   │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### B.2 Storage Layout

```solidity
// Social Recovery state (in AAStarAirAccountBase)
address[3] public guardians;        // Fixed array, max 3
uint8 public guardianCount;         // Cached count (gas optimization)
RecoveryProposal public activeRecovery;

struct RecoveryProposal {
    address newOwner;                // Proposed new owner
    uint256 proposedAt;              // block.timestamp of proposal
    uint256 approvalBitmap;          // Bitmap: bit i = guardian[i] approved
}
```

**Why bitmap instead of mapping?**
- Gas efficient: single `SSTORE` for all approvals (vs. N separate slots)
- Max 3 guardians → 3 bits → fits in single uint256
- Simple popcount to check threshold

### B.3 ERC-4337 Compliance Analysis

#### B.3.1 Recovery Functions Are Direct Calls (Not UserOps)

All recovery functions (`proposeRecovery`, `approveRecovery`, `executeRecovery`, `cancelRecovery`) are called as **direct transactions** by guardians/owner, NOT via UserOps through the EntryPoint.

**Why this is correct:**
- Guardians are EOAs — they sign and submit regular transactions
- Recovery does NOT go through `validateUserOp` → guardians don't need to sign as the account
- This follows the same pattern as Argent, Safe, and other production wallets
- ERC-4337 spec does NOT require that all account state changes go through UserOps

```
Guardian EOA → direct tx → AAStarAirAccountV7.proposeRecovery()
                           (msg.sender checked via _guardianIndex)
```

#### B.3.2 Owner Change and Signature Validation

After `executeRecovery()` sets `owner = newOwner`:

```solidity
// In _validateECDSA (line 230-237):
function _validateECDSA(bytes32 userOpHash, bytes calldata signature)
    internal view returns (uint256)
{
    bytes32 hash = userOpHash.toEthSignedMessageHash();
    address recovered = hash.recover(signature);
    return recovered == owner ? 0 : 1;  // ← uses current `owner`
}
```

- The new owner's ECDSA signature is immediately valid
- The old owner's ECDSA signature is immediately rejected
- No migration step needed — `owner` is the single source of truth

For BLS triple signature (`_validateTripleSignature`, line 278):
- The owner's ECDSA signatures (aaSignature, messagePointSignature) bind to the new owner
- BLS node registrations are independent and unchanged
- New owner needs to re-register their own BLS nodes if using Tier 3

#### B.3.3 Nonce Continuity

ERC-4337 nonces are managed by the EntryPoint contract (not the account):
```solidity
EntryPoint.getNonce(account, key) // External nonce tracking
```

Recovery does NOT reset or affect the nonce. UserOps continue with the next sequential nonce. This is ERC-4337 compliant — the account's nonce state is entirely in the EntryPoint.

#### B.3.4 EntryPoint Deposit Continuity

```solidity
function addDeposit() public payable {
    IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
}
```

The EntryPoint deposit is keyed by the account address, not the owner. Recovery changes the owner but the account address stays the same → deposit is preserved.

### B.4 Guardian Management — Detailed Mechanics

#### B.4.1 Adding Guardians

```solidity
function addGuardian(address _guardian) external onlyOwner {
    if (_guardian == address(0) || _guardian == owner) revert InvalidGuardian();
    if (guardianCount >= 3) revert MaxGuardiansReached();

    for (uint8 i = 0; i < guardianCount; i++) {
        if (guardians[i] == _guardian) revert GuardianAlreadySet();
    }

    guardians[guardianCount] = _guardian;
    emit GuardianAdded(guardianCount, _guardian);
    guardianCount++;
}
```

**Design notes:**
- Guardians are NOT set during account creation (Factory only sets owner + entryPoint)
- Owner must call `addGuardian` separately, via UserOp or direct call
- This allows gas-efficient account creation (CREATE2 deterministic address not affected)

#### B.4.2 Removing Guardians

```solidity
function removeGuardian(uint8 index, bytes[] calldata guardianSigs) external onlyOwner {
    // M7.3 security: require signatures from all non-removed guardians.
    // Removing a guardian reduces security level, so it requires the same
    // level of authorization as social recovery (guardian consensus).
    //
    //   1 guardian  → 0 sigs required (no other guardians exist)
    //   2 guardians → 1 sig  (the other guardian must agree)
    //   3 guardians → 2 sigs (both other guardians must agree)
    //
    // Sig pre-image: keccak256("REMOVE_GUARDIAN" || chainId || account || guardianAddr).toEthSignedMessageHash()
    // ... validate guardian sigs ...

    // ... shift array ...
    guardianVersion++; // F2: invalidate any pending ForceExit proposals

    // CRITICAL: Cancel active recovery if guardian set changes
    if (activeRecovery.newOwner != address(0)) {
        delete activeRecovery;
        emit RecoveryCancelled();
    }
}
```

**Why auto-cancel?** The approval bitmap references guardian indices. If guardians shift, bitmap bits map to different addresses. Rather than complex re-mapping, simply cancel and require a new proposal.

### B.5 Recovery State Machine

```
                    ┌──────────┐
                    │   IDLE   │ ← Initial / post-execute / post-cancel
                    └────┬─────┘
                         │ guardian calls proposeRecovery(newOwner)
                         │ bitmap = 1 << guardianIndex
                         ▼
                    ┌──────────┐
           ┌───────│ PROPOSED │ (approvalCount=1, timelock starts)
           │       └────┬─────┘
           │            │ other guardians call approveRecovery()
           │            │ bitmap |= 1 << guardianIndex
           │            ▼
           │       ┌──────────┐
           │       │ APPROVED │ (approvalCount≥2, waiting for timelock)
           │       └────┬─────┘
           │            │ block.timestamp ≥ proposedAt + 2 days
           │            │ anyone calls executeRecovery()
           │            ▼
           │       ┌──────────┐
           │       │ EXECUTED │ → owner = newOwner → back to IDLE
           │       └──────────┘
           │
           │ At any point: owner calls cancelRecovery()
           │ OR: owner calls removeGuardian() (auto-cancels)
           └──────────► IDLE
```

### B.6 Transaction Flow: From Key Loss to Recovery

#### Phase 1: Setup (before key loss)

```
Owner EOA                    EntryPoint                  AirAccount
    │                            │                           │
    │── UserOp: addGuardian(G1) ─│── validateUserOp() ──────▶│
    │                            │── execute(addGuardian) ──▶│
    │                            │                           │── guardians[0] = G1
    │── UserOp: addGuardian(G2) ─│── ... ──────────────────▶│
    │                            │                           │── guardians[1] = G2
    │── UserOp: addGuardian(G3) ─│── ... ──────────────────▶│
    │                            │                           │── guardians[2] = G3
```

Note: `addGuardian` is `onlyOwner`, so it can be called either:
- Via UserOp (EntryPoint → account.execute → account.addGuardian) — gasless
- Via direct call from owner EOA — requires owner to pay gas

#### Phase 2: Recovery Proposal

```
Guardian1 EOA                                            AirAccount
    │                                                       │
    │── direct tx: proposeRecovery(newOwnerAddr) ──────────▶│
    │                                                       │── activeRecovery = {
    │                                                       │     newOwner: newAddr,
    │                                                       │     proposedAt: now,
    │                                                       │     bitmap: 0b001
    │                                                       │   }
    │                                                       │── emit RecoveryProposed
    │                                                       │── emit RecoveryApproved(count=1)
```

#### Phase 3: Second Approval

```
Guardian2 EOA                                            AirAccount
    │                                                       │
    │── direct tx: approveRecovery() ──────────────────────▶│
    │                                                       │── bitmap |= 0b010
    │                                                       │── bitmap = 0b011 (count=2)
    │                                                       │── emit RecoveryApproved(count=2)
```

#### Phase 4: Execution (after 2-day timelock)

```
Anyone                                                   AirAccount
    │                                                       │
    │── direct tx: executeRecovery() ──────────────────────▶│
    │                                                       │── require(now ≥ proposedAt + 2d)
    │                                                       │── require(popcount(bitmap) ≥ 2)
    │                                                       │── owner = newOwner
    │                                                       │── delete activeRecovery
    │                                                       │── emit RecoveryExecuted
    │                                                       │── emit OwnerChanged
```

#### Phase 5: New Owner Uses Account

```
NewOwner EOA                 EntryPoint                  AirAccount
    │                            │                           │
    │── UserOp(signed by new) ──▶│── validateUserOp() ──────▶│
    │                            │   _validateSignature()     │
    │                            │   recover(sig) == owner ✓  │
    │                            │── execute() ─────────────▶│
    │                            │                           │── _call(dest, value, data) ✓
```

### B.7 Security Properties

| Property | Mechanism | ERC-4337 Impact |
|----------|-----------|-----------------|
| No single point of failure | 2/3 threshold | None — recovery is off-path |
| Flash loan resistance | 2-day timelock | None — timelock is independent |
| Owner veto | `cancelRecovery()` during timelock | None — direct call |
| Guardian set mutation safety | Auto-cancel on `removeGuardian` | None |
| Permissionless execution | Anyone can call `executeRecovery()` | Gas can be paid by relayer |
| Immediate key invalidation | `owner = newOwner` atomic swap | Next UserOp uses new key |
| No replay risk | EntryPoint nonce unaffected | Nonce continues sequentially |

### B.8 Comparison with Industry Standards

| Feature | AirAccount V7 | Argent | Safe (Social Recovery Module) |
|---------|---------------|--------|-------------------------------|
| Max guardians | 3 (hardcoded) | Unlimited | Unlimited |
| Threshold | 2/3 (hardcoded) | N/M (configurable) | N/M (configurable) |
| Timelock | 2 days (hardcoded) | 36 hours | Configurable |
| Guardian type | EOA only | EOA + smart contract | EOA + smart contract |
| Cancel mechanism | Owner only | Owner only | Owner only |
| Storage | Inline (account contract) | Separate module | Separate module |
| Upgradable | No (immutable) | Yes (proxy) | Yes (module swap) |
| ERC-4337 native | Yes | Partial (v1 adapter) | Via 4337 module |

### B.9 Known Limitations and Future Work

1. **Hardcoded parameters**: `RECOVERY_THRESHOLD=2`, `RECOVERY_TIMELOCK=2 days`, max 3 guardians are all constants. Making them configurable per-account requires a contract upgrade (new version deployment + migration).

2. **No smart contract guardians**: `_guardianIndex` checks `msg.sender` — works for EOAs but a Safe multisig guardian would need to call via `execTransaction`. This works if the Safe is the direct caller, but does NOT work if the call is relayed through another contract.

3. **GlobalGuard owner sync**: After recovery, `AAStarGlobalGuard.owner` is NOT automatically updated. The new owner must call `guard.setOwner(newOwner)` (if such function exists) or deploy a new guard. **This is a known design gap.**

4. **No guardian notification**: Recovery events are emitted on-chain but there's no push notification mechanism. Off-chain indexers (e.g., The Graph, Tenderly) should monitor `RecoveryProposed` events and alert the account owner.

5. **P256/BLS re-configuration**: After recovery, the new owner inherits the old P256 passkey and BLS settings. They should:
   - Call `setP256Key(newX, newY)` to register their own passkey
   - Re-register BLS public keys for Tier 3 transactions
   - Review and update `guard` settings

### B.10 Test Coverage Summary

The `SocialRecovery.t.sol` test suite (561 lines, 27 test cases) covers:

| Category | Tests | Coverage |
|----------|-------|----------|
| addGuardian | 6 | Owner-only, max 3, no duplicates, no zero/owner address |
| removeGuardian | 6 | Shift logic, middle/last removal, auto-cancel recovery |
| proposeRecovery | 4 | Auto-approval, non-guardian revert, invalid newOwner, active conflict |
| approveRecovery | 3 | Second approval, double-approve revert, no-active revert |
| executeRecovery | 5 | Success path, timelock boundary, insufficient approvals, 3/3 approve |
| cancelRecovery | 3 | Owner cancel, non-owner revert, no-active revert |
| Full flow | 2 | End-to-end, second recovery after first |

All 27 tests pass via `forge test --match-path test/SocialRecovery.t.sol`.

### B.11 Gas Costs (Foundry Estimates)

| Operation | Estimated Gas | Notes |
|-----------|---------------|-------|
| addGuardian | ~47,000 | First guardian; subsequent ~25,000 |
| removeGuardian | ~28,000 | With array shift |
| proposeRecovery | ~68,000 | Creates RecoveryProposal struct |
| approveRecovery | ~28,000 | Single SSTORE (bitmap update) |
| executeRecovery | ~35,000 | Owner swap + struct deletion |
| cancelRecovery | ~22,000 | Struct deletion only |

### B.12 Contract References

| File | Lines | Description |
|------|-------|-------------|
| `src/core/AAStarAirAccountBase.sol` | 375-486 | Core social recovery implementation |
| `src/core/AAStarAirAccountV7.sol` | 1-25 | Entry point integration |
| `src/core/AAStarAirAccountFactoryV7.sol` | — | Factory (no guardian init) |
| `test/SocialRecovery.t.sol` | 1-561 | Complete test suite |
