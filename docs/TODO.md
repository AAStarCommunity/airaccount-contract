# AirAccount Contract — Technical TODO

Deferred optimization and feature tasks. Items not worth doing immediately but tracked here
to avoid being forgotten. Each item has a priority milestone and the reason it was deferred.

---

## Gas Optimizations

### [M5] Packed guardian storage
**Savings**: ~2,100 gas per storage read on social recovery path (~4,200 gas total for 2-of-3 threshold).
**Current state**: `address[3] public guardians` occupies 3 storage slots (1 SLOAD each on recovery).
`uint8 public guardianCount` occupies a separate 4th slot.
**Optimization**: Pack `guardianCount (1 byte)` + `guardian[0] (20 bytes)` into one slot (21 bytes < 32).
Store `guardian[1]` and `guardian[2]` in the next two slots as before, or pack all 3 with count.
**Why deferred**: Requires storage layout restructure in `AAStarAirAccountBase`. Since the contract
is non-upgradable, this only benefits new deployments. Recovery operations are already infrequent.
**Files**: `src/core/AAStarAirAccountBase.sol` — struct layout, `guardianCount` initialization,
`_guardianIndex()`, `proposeRecovery()`, `approveRecovery()`, `cancelRecovery()`, `executeRecovery()`.
**Reference**: `docs/gas-analysis.md` — Potential Future Optimizations table.

---

### [M5] Assembly-optimized ecrecover
**Savings**: ~500 gas per ECDSA UserOp (both validation and execution path).
**Current state**: Uses `ECDSA.recover()` from OpenZeppelin which has ABI-decoding overhead.
**Optimization**: Direct `ecrecover` precompile call in `_validateECDSA()`:
```solidity
// Replace:
address recovered = hash.recover(signature);
// With:
(uint8 v, bytes32 r, bytes32 s) = _splitSig(signature);
address recovered;
assembly {
    let ptr := mload(0x40)
    mstore(ptr, hash)
    mstore(add(ptr, 32), v)
    mstore(add(ptr, 64), r)
    mstore(add(ptr, 96), s)
    let success := staticcall(3000, 0x01, ptr, 128, ptr, 32)
    recovered := mload(ptr)
}
```
**Why deferred**: Savings are small (~500 gas). OZ implementation is battle-tested. Risk vs reward
favors keeping OZ until a bigger refactor pass is planned.
**Files**: `src/core/AAStarAirAccountBase.sol` — `_validateECDSA()`.

---

### [M5.5] Batch UserOp aggregation (SDK/backend integration)
**Savings**: ~40% gas reduction per UserOp when multiple ops share the same BLS node set.
**Current state**: `AAStarBLSAggregator` contract is fully implemented and deployed.
The aggregator defers BLS verification from N individual pairings to 1 shared pairing via
`e(G, sum(sigs)) = prod(e(aggPK_i, msgPt_i))` bilinearity.
**Remaining work**: SDK must:
1. Set `blsAggregator` on accounts that opt into batch mode
2. Group UserOps by node set in the bundler
3. Call `aggregateSignatures()` before submitting the bundle
4. Pass aggregated bundle to `EntryPoint.handleAggregatedOps()`
**Why deferred**: Pure SDK/backend work, no contract changes. Depends on bundler infrastructure.
**Reference**: `src/aggregator/AAStarBLSAggregator.sol`, `docs/M5-plan.md` section M5.5.

---

## Architecture / Features

### [M5] Packed guardian accept-pattern (Option B from M5 plan)
**Goal**: Require guardians to sign an acceptance transaction before becoming active.
Prevents griefing via `addGuardian(unknowingAddress)`.
**Approach**: Add `pendingGuardians` mapping, acceptance signature or on-chain `acceptGuardianship()` call.
**Reference**: `docs/M5-plan.md` section M5.3.

---

### [M5] setupComplete flag for AAStarValidator
**Goal**: Prevent Finding 3 — the bypass of 7-day timelock via direct `registerAlgorithm()`.
**Approach**: Add `bool public setupComplete` to `AAStarValidator`. Once set:
- `registerAlgorithm()` (immediate path) is permanently disabled
- Only `proposeAlgorithm` + `executeProposal` (7-day timelock) is allowed
- Owner calls `finalizeSetup()` after initial algorithm registration
**Reference**: `docs/gpt52-review-response.md` Finding 3, `docs/M5-plan.md` section M5.2.
**Files**: `src/validators/AAStarValidator.sol`.

---

### [M5] messagePoint binding context (governance hardening)
**Goal**: Bind `messagePoint` to the specific UserOp hash to prevent replay across transactions.
**Current state**: `messagePointSignature` proves the owner signed the messagePoint, but the
messagePoint itself is not explicitly bound to `userOpHash`. The BLS nodes independently bind
their signatures to the messagePoint — this is the existing protection.
**Approach**: Add `keccak256(userOpHash || messagePoint)` as the message for the owner's
`messagePointSignature`, replacing the current `keccak256(messagePoint)`.
**Why deferred**: Current design has implicit binding via BLS nodes' independent signing.
The explicit binding makes the security argument cleaner but is not an urgent fix.
**Reference**: `docs/M5-plan.md` section M5.2, `docs/gpt52-review-response.md` Finding 4.

---

### [v1.0] EIP-7702 delegation support
**Goal**: Eliminate ~2.4M gas account deployment cost. An EOA can temporarily delegate to
AirAccount logic via EIP-7702, making the account usable without deploying a contract.
**Current state**: Not applicable until EIP-7702 is widely deployed. ETH mainnet: Pectra (May 2025).
**Design change**: Account must be redesigned to not rely on `address(this)` being a separate
contract. Guard binding model changes significantly.
**Reference**: `docs/gas-analysis.md` Recommendations section.

---

## Monitoring / Operational

### [Ongoing] P256 precompile gas across L2s
Track EIP-7212 precompile gas costs on chains we support. Costs vary significantly:
- ETH mainnet: Fusaka (Dec 2025 estimated)
- OP Stack: Fjord + Isthmus
- Arbitrum: ArbOS 31+
**Reference**: `docs/M5-plan.md` section M5.4 — Chain Compatibility Table.

---

## Post-M5 Mandatory Runs

### Gasless E2E Test (after M5 completes)
Follow the same test standard as `docs/gasless-e2e-test-report.md`:
- Deploy M5 factory to Sepolia
- Fund account with aPNTs
- Execute gasless transfer via SuperPaymaster
- Verify ETH balance unchanged
- Record gas costs, tx hashes, block numbers
- Document any behavior changes from ERC20 token guard presence
- Save new report as `docs/m5-gasless-e2e-test-report.md`

### Deployment Record (after M5 completes)
Follow the same standard as `docs/yetanother-deployment-record.md`:
- Record all M5 deployed contract addresses
- TX hashes for each deployment
- Gas used per contract
- Etherscan verification links
- Network, deployer, EntryPoint version
- Known issues or notes
- Save as `docs/m5-deployment-record.md`

### Gas Analysis V2 (after M5 completes)
Update `docs/gas-analysis.md` with M5 gas measurements — see TODO section in that file.

---

*Last updated: 2026-03-13*
*Source analysis: `docs/gas-analysis.md` — Potential Future Optimizations*
