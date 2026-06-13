# Pimlico Bundler 兼容性深析

**背景**: Phase 12 E2E 测试中，带 guard 的 AirAccount 账户通过 Pimlico bundler 提交 UserOp 时失败了两次，原因各不相同。本文深入分析两次失败的根本机制，以及生产环境的对应影响。

---

## 失败一：`AlgorithmNotApproved(uint8(0))`

### 表象

带 guard 账户提交 UserOp 时，Pimlico 的 `eth_estimateUserOperationGas` 报错：
```
bundler error: AlgorithmNotApproved(uint8(0))
```

### 根本原因：ERC-4337 两阶段模拟 vs EIP-1153 瞬态存储

**AirAccount 的 algId 传递机制**（`AAStarAirAccountBase.sol`）：

```
validateUserOp(userOp, userOpHash, ...)
  → algId = _detectAlgorithm(signature)
  → tstore(ALGO_SLOT, algId)       ← EIP-1153 瞬态存储写入
  → return validationData

execute(to, value, data)
  → _enforceGuard()
      → algId = tload(ALGO_SLOT)   ← EIP-1153 瞬态存储读取
      → require(approvedAlgorithms[algId], ...)
```

这在**真实链上执行**时完全正确：
```
EntryPoint.handleUserOps(ops, ...) — 一笔 TX
  ├─ validateUserOp → tstore(ALGO_SLOT, 0x02)   [EIP-1153 写入]
  └─ execute → tload(ALGO_SLOT) = 0x02 ✓        [同一 TX，瞬态存储有效]
```

**Pimlico 的 gas 估算模型** 却把两个阶段分成**两次独立 `eth_call`**：

```
eth_estimateUserOperationGas(userOp, entryPoint):
  ├─ eth_call #1: simulateValidation(userOp)
  │    → validateUserOp → tstore(ALGO_SLOT, 0x02)
  │    → eth_call 结束 → EVM 清零瞬态存储 ← 关键！
  │
  └─ eth_call #2: simulateExecution(callData)
       → execute → tload(ALGO_SLOT) = 0  ← 已被清零
       → _enforceGuard(algId=0)
       → approvedAlgorithms[0] = false
       → revert AlgorithmNotApproved(uint8(0))
```

### 为什么 Pimlico 必须分开模拟

这不是 Pimlico 的 bug，而是 ERC-4337 规范要求的设计选择：

1. **分别定界**: `verificationGasLimit` 和 `callGasLimit` 是两个独立字段，需要单独测量。合并模拟无法给出准确的分项 gas 限制。

2. **验证阶段审查**: ERC-4337 spec 规定验证阶段有受限操作集（禁止访问外部合约 storage，禁止某些 opcode），bundler 必须单独检查这些限制，防止恶意 UserOp 在捆绑后影响其他 UserOp。

3. **批量优化**: bundler 可以缓存 `simulateValidation` 结果，在多次打包尝试中复用，而不需要重复跑完整模拟。

### EIP-1153 的 `eth_call` 语义

根据 EIP-1153 规范：
> "Transient storage is reset at the beginning of each transaction."

`eth_call` 创建一个全新的 EVM 执行上下文，等价于一笔新 transaction。因此每次 `eth_call` 开始时，瞬态存储都是干净的。这意味着：

- **同一 TX 内**：`tstore` 写入对后续 `tload` 可见 ✓
- **跨 eth_call**：`tstore` 写入对下一次 `eth_call` 的 `tload` 不可见 ✗

### 真实链上是否也有问题？

**没有**。在 EntryPoint 的真实 `handleUserOps` 执行路径中：
```
handleUserOps(ops, beneficiary):
  for each op:
    validateUserOp(op, ...)      ← validate
    execute(op.callData, ...)    ← execute
    // 同一 EVM 调用帧内，瞬态存储全程有效
```

validate 和 execute 在同一笔链上 TX 的同一 call 帧内执行，瞬态存储正常传递。Sepolia 上 UO.3 的 bundled TX（`0x69b8ac8c…`，Codex 已验证真实）即走这条路径，**正常通过**。

### 影响范围

| 场景 | 结果 |
|------|------|
| 真实链上 TX via bundler | ✅ 正常（瞬态存储在同 TX 有效）|
| Pimlico `eth_estimateUserOperationGas` | ❌ 失败（两次 eth_call 清零）|
| 其他使用合并模拟的 bundler | ✅ 可能正常（取决于 bundler 实现）|
| AirAccount 自己的 `cast send` / `viem.writeContract` | ✅ 正常（直接调用，无两阶段估算）|

### 当前解决方案（测试用）

Phase 12 使用 `dailyLimit=0`（不部署 guard），`_enforceGuard` 发现 `guard == address(0)` 直接 return，跳过 `tload`。这让 Pimlico 的估算阶段通过，但这不是生产环境应有的账户形态。

---

## 失败二：`AA21 didn't pay prefund`

### 表象

解决 guard 问题后，UserOp 在 Pimlico 端成功通过估算，但实际提交时 EntryPoint 报错 `AA21`：
```
EntryPoint revert: AA21 didn't pay prefund
```

### 根本原因：固定 gas 参数 × oracle 实际费用 > 存款余额

**初始代码使用固定 gas 参数**（调试阶段的硬编码值）：
```typescript
const MFG  = 1_500_000_000n  // maxFeePerGas = 1.5 gwei（硬编码）
const VGL  = 500_000n        // verificationGasLimit = 500k（保守大值）
const CGL  = 300_000n        // callGasLimit = 300k（保守大值）
const PVG  = 100_000n        // preVerificationGas = 100k（保守大值）
```

**EntryPoint 的 prefund 计算**（`handleUserOps` 实际执行前）：
```solidity
uint256 requiredPrefund = 
    (verificationGasLimit + callGasLimit + preVerificationGas) × maxFeePerGas
= (500k + 300k + 100k) × maxFeePerGas
= 900k × actual_maxFeePerGas
```

**Pimlico 的行为**：Pimlico 不会用我们填写的 `maxFeePerGas=1.5 gwei`，而是**替换为 oracle 当前基础费**（Sepolia 当时约 13 gwei）来计算 prefund 充足性：

```
900k × 13 gwei = 11,700,000 gwei = 0.0117 ETH
账户 EntryPoint 存款 = 0.005 ETH
0.0117 > 0.005 → AA21
```

### 为什么 Pimlico 要替换 maxFeePerGas

Pimlico 必须保证自己能从 EntryPoint 追回 gas 成本。如果 bundler 接受 `maxFeePerGas=1.5 gwei` 的 UserOp，但 Sepolia 实际需要 13 gwei 才能打包，会出现：

1. Bundler 以 13 gwei 提交 TX（真实费用）
2. 但只能从账户 EntryPoint 存款追回 1.5 gwei × gasUsed
3. Bundler 亏损

所以 Pimlico 在 prefund 检查时使用**当前 oracle 费用**（不是用户填的费用）来估算，确保账户存款够覆盖实际成本。

### 两个 bug 叠加

问题是两个独立错误叠加：
1. `VGL + CGL + PVG = 900k`（保守过高，实际只需约 200k）
2. `maxFeePerGas` 未用 oracle（Pimlico 内部换用 13 gwei）

单独任何一个都可能过关，两个叠加就必然失败。

### 正确流程（已在最终代码中修复）

```typescript
// Step 1: 查 Pimlico oracle 费用（必须用，不能固定值）
const gasPrice = await bundlerRpc(PIMLICO_URL, "pimlico_getUserOperationGasPrice", [])
const mfg  = BigInt(gasPrice.standard.maxFeePerGas)    // ~13 gwei
const mpfg = BigInt(gasPrice.standard.maxPriorityFeePerGas)

// Step 2: 用 oracle 费用作 hint，让 Pimlico 估算实际 gas limits
const estimates = await bundlerRpc(PIMLICO_URL, "eth_estimateUserOperationGas", [{
  ...stubUserOp,
  maxFeePerGas: toHex(mfg),     // 告诉 Pimlico 用真实费用
  maxPriorityFeePerGas: toHex(mpfg),
}, ENTRY_POINT])
const cgl = BigInt(estimates.callGasLimit)       // 实际估算值（远小于 300k）
const vgl = BigInt(estimates.verificationGasLimit)
const pvg = BigInt(estimates.preVerificationGas)

// prefund = (vgl + cgl + pvg) × mfg ≈ 200k × 13 gwei = 0.0026 ETH
// 存款 0.05 ETH 足够覆盖 ✓
```

存款也从 0.005 ETH 增加到 0.05 ETH，覆盖 Sepolia 费用波动（当前约 0.003 ETH，留有 15× 余量）。

---

## 两次失败的本质区别

| | 失败一 | 失败二 |
|---|---|---|
| 错误码 | `AlgorithmNotApproved(uint8(0))` | `AA21 didn't pay prefund` |
| 触发阶段 | Pimlico gas 估算阶段 | EntryPoint 执行阶段 |
| 根本原因 | AirAccount 架构与 Pimlico 模拟模型不兼容 | 我们对 Pimlico 费用模型理解错误 |
| 是否 Pimlico bug | 否，符合 ERC-4337 spec | 否，Pimlico 保护自身不亏损的合理行为 |
| 真实链上是否存在 | 否（handleUserOps 单 TX，瞬态存储有效）| 是（存款不够的话链上也会 AA21）|
| 修复难度 | 高（需改合约 algId 传递机制）| 低（用 oracle + 估算即可）|

---

## 生产影响评估

### 短期（当前 v0.17.2-beta.3）

带 guard 的真实用户账户无法通过 Pimlico 的 **estimation 阶段**（只影响估算，链上执行无问题）。意味着：
- 自己发 TX（cast / viem）：✅ 正常
- 通过 bundler 提交 UserOp（如 Pimlico）：❌ estimation 失败，无法提交

### 根本修复方向

**方案 A：改 algId 传递机制（推荐）**

不用瞬态存储，改为在 signature 里编码 algId。`_validateECDSA` 已有向后兼容路径（65 字节原始 sig → 自动识别为 ECDSA），可以扩展为：
```
signature = algId (1 byte) || actual_sig (65 bytes)
```
`execute` 里的 `_enforceGuard` 从 `msg.data` 中的 userOp.signature 重新解出 algId，不依赖瞬态存储。

**代价**: 需要修改 `AAStarAirAccountBase.sol` 的 validate 和 execute，以及所有签名路径。属于破坏性改动，需要新版本和用户迁移。

**方案 B：换支持合并模拟的 bundler**

部分 bundler（如 Candide）可以配置为合并 validate+execute 在同一 `eth_call` 内模拟。`scripts/e2e-v0172/12-userop-bundler.ts` 中已预留 `CANDIDE_URL` 环境变量，但未完成测试。

**代价**: 依赖特定 bundler 实现，不具通用性。

**方案 C：accept 现状，记录为 KI**

带 guard 账户要用 bundler，当前必须绕过估算（手动指定 gas limits，跳过 Pimlico estimation）。这是 known issue，待 v0.18 的 algId 重构再解决。

### 建议

将此问题加入 `docs/known-issues.md` 作为 **KI-16**，并在 v0.18 设计时把 "algId 不依赖瞬态存储" 作为设计目标之一。Phase 12 的 `no-guard` 账户是测试基础设施的临时方案，不应出现在生产账户形态中。

---

## 参考

- [`scripts/e2e-v0172/12-userop-bundler.ts`](../scripts/e2e-v0172/12-userop-bundler.ts) — Phase 12 源码（含详细注释）
- [`docs/e2e-v0172-beta3-pitfalls-and-results.md`](e2e-v0172-beta3-pitfalls-and-results.md) — 全部 10 个踩坑记录
- [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153) — Transient storage opcodes
- [ERC-4337 spec](https://eips.ethereum.org/EIPS/eip-4337) — UserOperation 验证/执行阶段定义
