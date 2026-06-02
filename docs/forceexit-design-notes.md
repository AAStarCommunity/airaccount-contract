# ForceExit Design Notes & Long-term Tracking

**Last updated**: 2026-06-02
**Status**: v0.17.2-beta.1 ships current design; Codex LOW-3 expiry mechanism REJECTED by user; minimum-viable stale-guardian fix accepted for v0.17.2-beta.2; full redesign discussion deferred to v0.18+ pending user feedback.

This document captures the discussion + decision context for the ForceExit subsystem. It exists because:
- Codex round 5 raised LOW-3 (proposal staleness)
- User pushed back on the proposed expiry-based fix
- The discussion surfaced a **larger gap**: user's mental model of ForceExit differs significantly from the current implementation
- The gap is too large to fix in beta.2 — needs proper design + user research

---

## 1. Current ForceExit Implementation (v0.17.2-beta.1)

### Real behaviour

`ForceExitModule.executeForceExit` does the following:

```solidity
// Mandatory pre-conditions:
accountL2Type[account] ∈ {L2_TYPE_OPTIMISM, L2_TYPE_ARBITRUM}   // L1 → revert UnsupportedL2Type
approvalBitmap count ≥ APPROVAL_THRESHOLD (= 2)                  // 2-of-3 guardian threshold

// Action: call the L2→L1 bridge from the account's balance
account.executeFromExecutor(bytes32(0),
    abi.encode(
        bridge,                         // L1MessagePasser (OP) or ArbSys
        proposal.value,                 // ETH amount (FIXED at propose time)
        bridge.initiateWithdrawal(target, gasLimit, proposal.data)
    )
)
```

The `executeFromExecutor` path goes through the account's `_enforceGuard(value, ALG_ECDSA, ...)` — meaning **Tier-1 daily ETH limit is enforced** (KI-13).

### What ForceExit currently does

| Capability | Status |
|---|---|
| **Anyone can execute** (after ≥2 guardian approvals) | ✅ Yes |
| **L2→L1 bridge withdrawal** | ✅ Yes (Optimism / Arbitrum only) |
| **Pre-armed by owner while key works, executed later by anyone** | ✅ Yes (that's the actual design pattern) |
| **Move ETH** to L1 recipient | ✅ Yes, but **only the fixed `value`** specified at propose time |
| **Move ERC20** to recipient | ❌ No — proposal.data must be hand-crafted to include ERC20 transfer calldata, and even then it's a single bridge call |
| **"All balance"** drain | ❌ No — propose-time fixed amount |
| **L1 Ethereum / Sepolia support** | ❌ No — `accountL2Type` defaults 0, reverts UnsupportedL2Type |
| **Tier-1 daily limit bypass** | ❌ No — KI-13 |

---

## 2. User's Mental Model (2026-06-02 discussion)

> 私钥已经没有了,他执行不了也没意愿;别人帮你执行 = 正常。一步到位把我的资产转移到我备份的这个目标的账户中。包括所有 ERC20 和所有 ETH。

User's expectation: **emergency total-asset sweep to a pre-specified backup address**.

| User expects | Current implementation | Gap |
|---|---|---|
| Anyone can execute | ✅ | none |
| One-shot transfer of all assets | ❌ (fixed amount only) | **large** |
| All ETH | ❌ (fixed `value`) | **gap** |
| All ERC20 | ❌ (not implemented at all) | **large** |
| Backup address valid forever | ✅ (proposal never expires) | aligned |
| L1 + L2 universal | ❌ (L2 bridge only) | **large** |

The user's mental model is a much simpler, more powerful primitive than the current L2-bridge-specific implementation. The current name "ForceExit" suggests the user's interpretation but the implementation is narrower.

---

## 3. Codex LOW-3 (round 5) — Expiry Mechanism — REJECTED

### Codex's concern

`pendingExit[account]` persists forever until cancel or execute. Three scenarios:

1. **Stale target**: owner pre-arms with target=`0xMETAMASK_2024`; loses access to that wallet 2 years later; key on AirAccount lost; guardians execute → funds go to dead address.
2. **Stale guardian**: 1 guardian signs at T0; owner later rotates guardians (Bob replaced by Carol); old Bob signature still validates against the snapshot in `pendingExit.guardians`; some current guardian (or even Bob himself) approves → 2 approvals reached even though current guardian set never consented to this proposal.
3. **Stale intent**: friendship sours; owner forgot to cancel proposal targeting (now-ex-)friend's address; key lost; ex-friend persuades one current guardian; funds drained to ex-friend.

### Codex proposed fix

Add `expiry` field to `ExitProposal`; reject `approve` + `execute` after `block.timestamp > expiry`; suggest 30-90 day window.

### Why user rejected (2026-06-02)

> 这是一个备份措施。如果你没事比如说 90 天就让用户备份一次,或者叫确认更新一次,对用户来说是一种负担。这种备份是私钥丢失或被盗的备份,本身就是相对比较低频的。如果对用户造成心智负担的话,实际上是一个麻烦。
>
> 最理想的状态就是用户找一个比如说硬件钱包或者是一个比较稳妥的钱包地址,或者是朋友亲人的钱包地址,然后设置之后就一直有效。

**User's reasoning** — three points:

1. **Frequency mismatch**: Emergency exit is a low-frequency event (most users never trigger it). Forcing 90-day re-confirmation creates UX burden on every user for a feature only a tiny fraction will ever use.
2. **Ideal backup is long-term**: A well-chosen backup address (hardware wallet, family member, trusted relative) **should not change** over years. Asking users to re-confirm every quarter implicitly suggests their choice was wrong.
3. **Mental burden = bad design**: Low-frequency interaction that demands periodic attention is a worse UX than a permanent setting + alternative safeguards.

### User-accepted alternatives

1. **Stale-guardian check at approve time** (this beta.2 — see §5 below): If the user **rotates guardians**, any old proposal signed by a removed guardian becomes invalid. The signature recovery check happens against current guardians, not the snapshot.
2. **dApp-layer guidance**: When the user calls `addGuardian` / `removeGuardian`, the dApp should warn: "You have a pending ForceExit proposal signed by `<old guardian>`. The signature is now invalid. Please ask `<new guardian>` to sign before this proposal can execute."
3. **Long-term tracking** (this doc + GitHub issue): If real users start hitting "stale target" issues, revisit the decision.

---

## 4. Scenarios — Updated Risk Map Under User's Decision

| Scenario | LOW-3 with expiry mitigates? | Stale-guardian check mitigates? | dApp guidance mitigates? | Residual risk |
|---|---|---|---|---|
| 1. Stale target (forgotten 2-year-old backup addr) | ✅ partial | ❌ | ⚠️ if dApp warns | **YES — user must self-manage** |
| 2. Stale guardian (Bob removed, Bob signs old proposal) | ✅ | ✅ | — | none |
| 3. Stale intent (ex-friend address) | ✅ | ❌ | ⚠️ owner must cancel while key works | **YES — owner discipline** |
| 4. Forgotten pre-arm + lost key | ✅ partial | ❌ | ❌ | **YES** |

Net: **scenarios 1, 3, 4 still have residual risk under user's decision**. These are accepted as social/UX problems rather than security vulnerabilities, because:
- Funds go to user-chosen address (not stolen by attacker)
- Owner has option to cancel while key works
- Failure mode = "money in your own old wallet" rather than "money in attacker's wallet"

**Tradeoff**: ~3 edge cases of lost-but-traceable funds vs UX cost of forcing every user to re-confirm every 90 days. User picks the latter as the better trade.

---

## 5. Beta.2 Concrete Fix: Stale-Guardian Check

### Code change

In `approveForceExit`, after computing the signer via `_proposalHash` + ECDSA recover, **also** verify that the recovered signer is still in the account's **current** guardian set (not just the snapshot):

```solidity
function approveForceExit(address account, bytes calldata guardianSig) external {
    ExitProposal storage proposal = pendingExit[account];
    if (proposal.proposedAt == 0) revert NoProposal();

    bytes32 msgHash = _proposalHash(account, proposal.target, proposal.value, proposal.data, proposal.proposedAt);
    address signer = msgHash.toEthSignedMessageHash().recover(guardianSig);

    // (1) Existing: match signer to a guardian slot in the SNAPSHOT
    uint256 bit = _guardianBit(proposal.guardians, signer);
    if (bit == type(uint256).max) revert InvalidGuardianSig();

    // (2) NEW (round 5 LOW-3 fix per beta.2 decision): also verify signer is in
    //     the CURRENT guardian set. If owner has rotated guardians since propose,
    //     the old guardian's signature is invalid even though it's in the snapshot.
    address[3] memory currentGuardians = _readGuardians(account);
    bool stillGuardian = false;
    for (uint256 i = 0; i < 3; i++) {
        if (currentGuardians[i] == signer) { stillGuardian = true; break; }
    }
    if (!stillGuardian) revert SignerNoLongerGuardian();

    if (proposal.approvalBitmap & (uint256(1) << bit) != 0) revert AlreadyApproved();
    proposal.approvalBitmap |= (uint256(1) << bit);
    emit ExitApproved(account, signer, proposal.approvalBitmap);
}
```

### What this prevents

- Scenario 2 (stale guardian): if Bob was removed, his old signature cannot accumulate an approval bit even if it matches the snapshot.

### What this does NOT prevent

- Scenario 1, 3, 4 (stale target, stale intent, forgotten pre-arm) — these require either expiry or owner discipline.

### Test plan

- `test_approveForceExit_revertsOnRemovedGuardian` — propose, remove Bob, Bob signs → `SignerNoLongerGuardian`
- `test_approveForceExit_succeedsWithCurrentGuardian` — propose, Alice (still current) signs → success
- `test_approveForceExit_revertsOnGuardianRotated` — propose, swap Bob → Carol, Bob signs → revert; Carol signs → success
- E2E on Sepolia: 1 new test in Phase 6 negative + 1 new in Phase 5 lifecycle

### Estimated effort

- ~10 lines Solidity (1 new error + 5-line current-guardian check)
- 3 forge tests, 2 E2E tests
- Documentation update in known-issues.md (mark LOW-3 partially-resolved)

---

## 6. Long-term Discussion: ForceExit Redesign for v0.18+

If user feedback reveals scenarios 1, 3, 4 are causing real losses, **redesign ForceExit** as a more general primitive. Sketch:

### Proposed v0.18+ design: "Emergency Asset Sweep"

```solidity
struct AssetSweepProposal {
    address target;                    // Where to send everything
    address[] erc20Tokens;             // ERC20 contracts to sweep (empty = ETH only)
    bool     includeETH;               // Sweep native ETH balance too
    uint256  proposedAt;
    uint256  approvalBitmap;
    address[3] guardians;              // Snapshot for transparency
}

function proposeAssetSweep(address target, address[] calldata erc20Tokens, bool includeETH) external {
    // Same access control as today: msg.sender == installed account
    // Same: AlreadyProposed if pending
}

function executeAssetSweep(address account) external {
    // Verify approvals ≥ threshold
    // Verify current-guardian check on each approval (the stale-guardian fix above)
    // Then drain:
    //   for each token: IERC20(token).transfer(target, IERC20(token).balanceOf(account))
    //   if includeETH: target.call{value: address(account).balance}("")
    // SKIP _enforceGuard daily limit — guardian consent is the authority
    // (this is the KI-13 long-term fix, applied here as well)
}
```

### Key design questions to resolve later

1. **L1 vs L2 unification**: Single primitive that works on Ethereum L1, Optimism, Arbitrum without separate code paths.
2. **Gas budgeting**: How much gas does "sweep 20 ERC20 + ETH" consume? Need to test + cap.
3. **Token discovery**: Who decides which ERC20 to sweep? Owner specifies at propose time? Or sweep from a pre-registered token list?
4. **Re-entrancy**: ERC20 callbacks during sweep — must be safe (use `transfer` not `transferFrom`, OZ ReentrancyGuard).
5. **Partial failures**: If 1 ERC20.transfer reverts, does the whole sweep revert? Or skip that token and continue?
6. **Backward compat**: Keep current `executeForceExit` (L2-bridge) as a separate path, or fully replace?

### Open: long-term tracking GitHub issue

A separate issue captures this discussion + invites user feedback over the beta period.

---

## 7. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-02 | Reject LOW-3 expiry mechanism | UX burden too high for low-frequency feature; ideal backup is long-term stable |
| 2026-06-02 | Accept stale-guardian fix for beta.2 | 10-line change, closes one of three staleness scenarios cleanly |
| 2026-06-02 | Defer "all-asset sweep" redesign to v0.18+ | New feature, not bugfix; needs separate design + user research |
| 2026-06-02 | Open long-term tracking issue | Revisit if real users hit staleness scenarios 1/3/4 |

If you're reading this in the future and the decisions look wrong, **check the long-term tracking issue first** — user observations may have updated the priors.
