# AirAccount Contract — Technical TODO

Deferred optimization and feature tasks. Items not worth doing immediately but tracked here
to avoid being forgotten. Each item has a priority milestone and the reason it was deferred.

---

## Gas Optimizations

### [M6] Factory deployment gas — EIP-1167 clone factory
**Current cost**: 5,104,901 gas (~0.05 ETH at 10 gwei mainnet). One-time per network.
**Root cause**: Solidity `new ContractName()` syntax embeds full initcode of both
`AAStarAirAccountV7` (~13k bytes) and `AAStarGlobalGuard` (~4k bytes) into the factory's
own bytecode. Factory runtime = 23,476 bytes × ~200 gas/byte ≈ 4.7M + overhead.

**Option A — EIP-1167 minimal proxy clone factory (recommended)**
- Deploy one `AAStarAirAccountV7` implementation contract once (~200k gas)
- `createAccount` clones it via 45-byte proxy: ~80–120k gas per account (vs current ~140–280k)
- Implementation address is hardcoded in clone bytecode — non-upgradable, satisfies design constraint
- Limitation: `AAStarGlobalGuard` has `immutable account` binding, must still be deployed fresh
  per account; guard deployment gas (~100k) cannot be eliminated by cloning
- Net factory deploy savings: ~4M gas (5.1M → ~1M)

**Option B — reduce optimizer_runs further**
- Current: 1,000 runs (down from 10,000), factory = 23,476 bytes
- At 200 runs: factory ≈ 21,754 bytes → deploy cost ~4.3M gas (~800k savings)
- Trade-off: higher per-call gas on every account transaction
- Not recommended — per-call cost compounds across all users

**Cost breakdown** (measured at deploy, 1,000 optimizer runs):

| 组成 | 字节数 | Gas 估算 |
|------|--------|---------|
| Factory 自身逻辑 | ~3k bytes | ~600k |
| 内嵌 V7 initcode | ~13k bytes | ~2.6M |
| 内嵌 Guard initcode | ~4k bytes | ~800k |
| 内嵌 V7 内的 Guard 引用等 | ... | ... |
| **合计** | **23,476 bytes × ~200 gas/byte** | **~4.7M + tx overhead** |
⏺ 贵是因为工厂部署时要把 AAStarAirAccountV7 + AAStarGlobalGuard 的完整 initcode 都打包进去（Solidity 的 new
  ContractName() 语法）。

  粗算：

  ┌───────────────────────────┬──────────────────────────────┬─────────────────────┐
  │           组成            │            字节数            │      Gas 估算       │
  ├───────────────────────────┼──────────────────────────────┼─────────────────────┤
  │ Factory 自身逻辑          │ ~3k bytes                    │ ~600k               │
  ├───────────────────────────┼──────────────────────────────┼─────────────────────┤
  │ 内嵌 V7 initcode          │ ~13k bytes                   │ ~2.6M               │
  ├───────────────────────────┼──────────────────────────────┼─────────────────────┤
  │ 内嵌 Guard initcode       │ ~4k bytes                    │ ~800k               │
  ├───────────────────────────┼──────────────────────────────┼─────────────────────┤
  │ 内嵌 V7 内的 Guard 引用等 │ ...                          │ ...                 │
  ├───────────────────────────┼──────────────────────────────┼─────────────────────┤
  │ 合计                      │ 23,476 bytes × ~200 gas/byte │ ~4.7M + tx overhead │
  └───────────────────────────┴──────────────────────────────┴─────────────────────┘

  不过这是一次性成本，factory 只部署一次，每个用户的账户创建 gas 是另算的（之前测试大概 140k-280k 量级）。

  如果你想压缩 factory 部署成本，主要有两个方向：

  方向 1：Clone Factory（EIP-1167 最小代理）
  - 部署一个 implementation 合约（一次）
  - 每个账户 clone() 一个 45-byte 代理，gas 降到约 80-120k
  - 代价：实现地址硬编码在 clone 字节码里，不能升级——但 clone 本质是不可升级的，符合你的设计原则
  - 限制：AAStarGlobalGuard 是 immutable account 绑定的，guard 还是得每次 new，这部分 gas 没法省

  方向 2：降低 optimizer_runs 继续优化
  - 我们从 10,000 降到 1,000 已经省了约 20 万 gas（5.3M → 5.1M）
  - 再往下 200 runs 能到约 4.3M，但 per-call gas 会上涨

  当前的 5.1M gas 在 Sepolia 上是 ~0.001 ETH（极低费率），主网按 10 gwei 算大约 5M × 10gwei = 0.05 ETH ≈ $100。如果
  factory 一个网络只部署一次，这个成本是可接受的。

每个用户账户创建 gas 另算（约 140k–280k，与工厂部署无关）。

**Why deferred**: Factory is deployed once per network. At 10 gwei mainnet ~$100,
acceptable for launch. Clone pattern requires refactoring account initialization
(must use `initialize()` instead of constructor) which is a significant change.
**Watch trigger**: If deploying to multiple chains frequently, or if mainnet gas > 50 gwei.
**Files**: `src/core/AAStarAirAccountFactoryV7.sol`, `src/core/AAStarAirAccountV7.sol`

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

### [M7+] EIP-2930 access list warmup — reduce clone DELEGATECALL from cold to warm (Option 1)
**Savings**: ~2,500 gas per UserOp (2,600 cold → 100 warm for implementation address DELEGATECALL).
**Root cause**: M7 clone proxy pays 2,600 gas (EIP-2929 cold address) on every DELEGATECALL to
implementation. Option 3 (SLOAD pre-read) does NOT work — SLOAD warms storage slots, not addresses;
only CALL/DELEGATECALL/EXTCODESIZE opcodes warm an address.
**Option 1 — Bundler-level EIP-2930 access list (correct approach)**:
- SDK hints bundler to include implementation address in `accessList` of the outer `handleOps` tx
- Not a standard ERC-4337 field; requires bundler protocol extension (non-standard metadata hint)
- Short-term free path: batch packing — when a `handleOps` tx contains multiple UserOps for
  clone accounts sharing the same implementation, the 1st UserOp pays cold (2,600 gas),
  all subsequent ones pay warm (100 gas). Bundler automatically benefits with no SDK change.
**SDK work required (for explicit EIP-2930 path)**:
- When calling `eth_sendUserOperation`, include hint in metadata:
  `{"implementationAddress": "0x3C866080C6AA37697AeA43106956369071d26600"}`
- Bundler must support this extension to build `accessList` entry before broadcasting `handleOps`
- Without bundler support: rely on natural batch warmup (no SDK change needed, ~2500 gas saved
  when ≥2 accounts in same bundle share the implementation)
**Why deferred**: Requires bundler-protocol coordination. Natural batch warmup already provides
the benefit in production (most bundlers pack multiple UserOps per tx). Explicit access list
support is a nice-to-have; coordinate with Pimlico/Alchemy bundler teams at mainnet prep.
**Files**: SDK layer, no contract changes needed.

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


### [v1.0] EIP-7702 delegation support
**Goal**: Eliminate ~2.4M gas account deployment cost. An EOA can temporarily delegate to
AirAccount logic via EIP-7702, making the account usable without deploying a contract.
**Current state**: Not applicable until EIP-7702 is widely deployed. ETH mainnet: Pectra (May 2025).
**Design change**: Account must be redesigned to not rely on `address(this)` being a separate
contract. Guard binding model changes significantly.
**Reference**: `docs/gas-analysis.md` Recommendations section.

---

### [M6] Guard strict mode — blockUnconfiguredTokens flag
**Background**: Kimi 2.5 audit correctly identified that unconfigured ERC20 tokens pass through
the guard without tier limits. This is an explicit design decision (opt-in per token), but
power users / high-security accounts may want to block ALL token transfers unless the token
is explicitly configured.
**Approach**: Add `bool public blockUnconfiguredTokens` to `AAStarGlobalGuard`.
- Default: `false` (current behavior, backward compatible)
- When `true`: `checkTokenTransaction` reverts for any token not in `tokenConfigs`
- Can only be set to `true` by account owner (monotonic: once enabled, cannot disable)
**Risk mitigated**: Stolen ECDSA key cannot drain long-tail/airdrop tokens not in the config.
**Files**: `src/core/AAStarGlobalGuard.sol` — `checkTokenTransaction()`, new setter.

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

## Protocol Forward Compatibility

### [M7+] EIP-8130 / Native AA compatibility layer
**Goal**: Ensure AirAccount can migrate to protocol-level native AA without full rewrite
when Ethereum adopts a native AA standard (EIP-8130 or EIP-8141, target: Hegota 2026 H2).

**Key actions required (priority order)**:

1. **Verifier adapter contract** — Wrap `IAAStarAlgorithm` as EIP-8130 `IVerifier`:
   `IAAStarAlgorithm.validate(bytes32, bytes) → uint256`
   wraps to: `IVerifier.verify(bytes32, bytes) → bytes32 ownerId`
   Cost: ~50 LOC adapter, zero changes to existing algorithm contracts.

2. **ownerId migration** — Expand owner identity from `address` (20 bytes) to `bytes32`
   (full keccak256, ~2^85 quantum collision resistance vs current ~2^53).
   Affects: owner storage layout + `_validateOwner()` in `AAStarAirAccountBase.sol`.

3. **Account Lock ↔ Social Recovery alignment** — Map `cancelRecovery()` timelock pattern
   to EIP-8130 `lock() / requestUnlock() / unlock()` 3-step lifecycle.

4. **algId ↔ verifier type namespace**:
   `0x02 ECDSA → K1(0x01)` adapter only;
   `0x03 P256 → P256_WEBAUTHN(0x03)` align WebAuthn data format;
   `0x01 BLS → Custom(0x00)` deploy as permissionless verifier contract.

**Why deferred**: EIP-8130 is Draft, competing with EIP-8141 (Vitalik-backed, higher adoption
probability). Acting before Hegota EIP selection is confirmed = wasted migration cost.
**Watch trigger**: Hegota fork EIP finalization (expected Q3 2026).
**Full plan**: `docs/eip-8130-upgrade-plan.md`
**Background analysis**: `docs/eip-8130-analysis.md`

---

---

## Security / Guard

### [M8] `installModule` guard for 0-guardian accounts
**Context**: `uninstallModule` uses `min(_guardianCount, 2)` to avoid permanently locking modules
when an account has fewer than 2 guardians. Side effect: a `_guardianCount=0` account gets
`sigsRequired=0`, meaning owner can uninstall any module (including `TierGuardHook`) without
guardian approval.
**Current stance**: Intentional for 0-guardian accounts created via raw `createAccount` path
(caller accepts weaker security). Production accounts via `createAccountWithDefaults` always
have 3 guardians → `sigsRequired=2`.
**Proposed fix**: Add `if (_guardianCount == 0) revert InstallModuleUnauthorized()` at the top
of both `installModule` and `uninstallModule`, preventing 0-guardian accounts from using the
module system entirely.
**Why deferred**: 0-guardian accounts are a degenerate edge case with no production path.
Fixing it changes contract bytecode → requires redeployment.
**Watch trigger**: If `createAccount` with 0 guardians becomes an exposed API surface (SDK, UI).
**Files**: `src/core/AAStarAirAccountV7.sol` — `installModule()`, `uninstallModule()`.
**Raised by**: @fanhousanbu in PR #12 review (2026-04-09).

---

*Last updated: 2026-04-10*
*Source analysis: `docs/gas-analysis.md` — Potential Future Optimizations*
