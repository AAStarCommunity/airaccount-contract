# AirAccount 功能 Review（M1 / M2 / M3）

> 范围：`work` 分支当前实现（核心合约 + 关键测试）
> 方法：代码静态审查（不依赖链上环境）

## 总结

- M1/M2 的主路径（ECDSA、BLS 三重签名、Factory、基础路由）结构清晰，接口拆分合理。
- M3 中有两个“**文档宣称已实现**”但“**主执行路径未真正生效**”的问题：
  1. **GlobalGuard 未接入账户执行路径**。
  2. **Tiered Routing 仅有配置/查询函数，未在签名校验或执行中强制执行**。

## 发现清单

### 1) [高] GlobalGuard 未在账户主路径中调用（F19 实际未生效）

**现象**
- `AAStarAirAccountBase` 提供了 `setGuard(address)` 存储 guard 地址，但在 `_validateSignature` / `validateUserOp` / `execute` / `executeBatch` 中没有对 `guard.checkTransaction(...)` 的调用。
- 因此即使配置了 `AAStarGlobalGuard`，日限额与算法白名单也不会对真实执行产生约束。

**证据**
- 账户侧仅有 guard 配置，无调用点：`setGuard` 与 `guard` 状态变量。 
- `execute`/`executeBatch` 直接 `_call`，无 guard 校验。 
- `AAStarGlobalGuard` 的核心逻辑仅定义在自身 `checkTransaction`，但未被账户主流程消费。 

**风险**
- 产品层面宣称“全局限额/白名单保护”与链上真实行为不一致，属于安全策略“看起来有、实际上没生效”。

**建议**
- 在账户执行路径里增加强制校验：
  - `validateUserOp` 阶段解析 `callData` 并调用 `guard.checkTransaction(value, algId)`；或
  - `execute`/`executeBatch` 每笔 call 前调用 guard。
- 同步补充“未配置 guard 时的行为定义”与回归测试（包含白名单拒绝、超额拒绝、多笔累积）。

---

### 2) [高] Tiered Routing 仅计算 tier，未参与决策（F21 实际未生效）

**现象**
- `requiredTier(txValue)` 只返回 tier 值；`setTierLimits` 只写入阈值。
- `_validateSignature` 仅依据签名前缀/长度分流（BLS/ECDSA/P256），没有把 `txValue` 对应 tier 与算法类型做一致性约束。
- `validateUserOp` 也未做 tier → algId 的绑定检查。

**风险**
- 高金额交易可继续使用低强度签名路径（例如 ECDSA）而不被拒绝，和“分层验证”的安全目标不一致。

**建议**
- 引入“交易金额 → 期望算法集合”映射并在 `validateUserOp` 强制检查。
- 建议至少覆盖：
  - Tier1 仅允许 ECDSA；
  - Tier2 强制双因子（或指定组合）；
  - Tier3 强制 BLS 三重签名；
  - 单测覆盖边界值（=tier1Limit、=tier2Limit、超限）。

---

### 3) [中] Validator 提案执行无 owner 限制（治理模型需明确）

**现象**
- `AAStarValidator.executeProposal(uint8)` 未使用 `OnlyOwner`。
- 当前实现是“owner 提案 + 任意地址到期执行”。

**影响评估**
- 若这是刻意的“开放执行”设计（常见 timelock executor 模式），则不是漏洞。
- 但若预期是“只有 owner 能执行治理动作”，则存在权限模型偏差。

**建议**
- 在文档中明确治理语义：
  - 方案 A：保留开放执行，并注明“任何人可执行已到期提案”；
  - 方案 B：增加 `onlyOwner`，与“owner 全流程治理”保持一致。

---

## 测试覆盖观察

- 现有 M3 测试已覆盖：P256 key 配置、tier 计算函数、guard 合约自身逻辑。 
- 但缺少“账户主流程集成测试”：
  - `setGuard` 后 `validateUserOp/execute` 是否真的被 guard 拦截；
  - 设置 tier 后高金额交易是否拒绝低等级算法。

## 建议的修复优先级

1. **P0（立刻）**：把 guard 和 tier 校验接入 `validateUserOp` 或执行路径，避免安全策略失效。  
2. **P1（本迭代）**：补齐集成测试，防止后续重构回归。  
3. **P2（文档）**：澄清 timelock 的执行权限语义。

