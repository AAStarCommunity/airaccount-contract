# AirAccount 合约架构与功能实现审阅（2026-03-10）

## 结论（简版）

- **不是“假实现”**：核心签名验证路径（ECDSA、P256、BLS 三重签名路由）、BLS 算法合约、BLS 聚合器、Factory CREATE2、社交恢复等都有可执行 Solidity 代码与对应 Foundry 测试文件。
- **但并非“全部功能已完整落地”**：文档宣称的“Tier 强制路由 + GlobalGuard 执行前硬拦截”在当前 `AAStarAirAccountV7` 主路径中没有被真正调用，属于“有模块、未闭环集成”。

## 关键核查点

1. 账户合约确实实现了 ERC-4337 的 `validateUserOp` 入口，且仅允许 EntryPoint 调用。  
2. 签名验证并非占位：`_validateSignature` 会按 algId 分流到 ECDSA / P256 / BLS triple / 外部路由器。  
3. BLS 验证器与聚合器都包含 EIP-2537 预编译调用（pairing / point add），不是空函数。  
4. 社交恢复（guardian、timelock、阈值审批）有完整状态机。  
5. **缺口**：`AAStarGlobalGuard.checkTransaction` 和 `requiredTier` 目前没有在 `validateUserOp` 或 `execute` 中被强制执行。

## 审阅建议

- 在 `validateUserOp` 中解析 `userOp.callData` 的 value + algId，强制执行：
  - `requiredTier(value)` 与签名算法一致性校验；
  - `guard.checkTransaction(value, algId)` 前置检查。
- 为上述“强制路径”补集成测试（成功/失败边界、每日限额跨天滚动、算法白名单冲突）。
- 若当前版本刻意分阶段交付，应在架构文档中明确标注“已实现”和“规划中”状态，避免过度声明。
