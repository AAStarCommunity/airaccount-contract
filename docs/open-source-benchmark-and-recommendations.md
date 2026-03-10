# AirAccount 对标开源实现（simple-team-account / light-account）与架构建议

> 更新时间：2026-03-10

## 1) 先回答你的核心问题

### Q1. 当前账户合约是不是完全从零开始？

结论：**不是完全从零开始**，但当前仓库里也**无法直接逐行比对**这两个子模块源码（本环境无法拉取 submodule）。

- 有明确的外部基线：仓库通过 `.gitmodules` 声明了 `lib/simple-team-account` 和 `lib/light-account` 作为子模块。  
- 你们产品文档也明确写了“基于 simple-team-account / light-account / kernel 的模式吸收”。  
- 当前 `src/` 的实现风格，确实体现了“吸收经验后自研重构”的特征：非升级、ERC-4337 入口、工厂 CREATE2、可插拔验证器路由、BLS 聚合等。

> 但因为这次 CI 容器无法访问 GitHub（403），我不能做“函数级别来源映射表”（例如“这一段来自 simple-team-account 第几行”）。

---

## 2) 从现有代码看，已经吸收了哪些“成熟模式”

### 2.1 light-account / ERC-4337 主线模式（偏账户骨架）

- `validateUserOp` + `missingAccountFunds` 预付逻辑是标准 ERC-4337 账户主路径。  
- `onlyEntryPoint`、`execute/executeBatch` 的账户边界清晰。
- `AAStarAirAccountFactoryV7` 使用 CREATE2 提供 counterfactual 地址，这是一线 AA 项目的工厂常规模式。

### 2.2 simple-team-account 类经验（偏多签/多算法）

- 你们把“多算法签名”和“高安全等级交易需要更强签名”的思想落到了 `_validateSignature` 分流设计：ECDSA、P256、BLS triple。  
- BLS 路径不是假逻辑：既支持账户内验证，也支持 aggregator 批验证。

### 2.3 YetAnotherAA + bundler 生态经验（偏 BLS 性能）

- 把 BLS 算法从账户中解耦为 `AAStarBLSAlgorithm`，并配套 `AAStarBLSAggregator`，这与主流 ERC-4337 的“account + aggregator”解耦方向一致。

---

## 3) 与产品文档目标相比，当前差距在哪

你们 docs 目标非常清晰：
- 非升级；
- 分层安全（Tier1/2/3）；
- Global Guard 硬红线；
- 可扩展验证器。

当前代码里，**模块都在**，但“强制闭环”还有一段路：
- `requiredTier()` 已实现；
- `AAStarGlobalGuard.checkTransaction()` 已实现；
- 但 `AAStarAirAccountV7.validateUserOp()` 目前只做签名校验 + prefund，没有把 tier/guard 强制纳入主路径。

这意味着现在更接近“可配置能力齐全”，而不是“架构红线强制执行完成”。

---

## 4) 站在开源 repo 肩膀上的可落地建议（安全 + 易用）

### 建议 A（最高优先级）：把策略强制纳入验证主路径

在 `validateUserOp` 内完成：
1. 解析 `userOp.callData`（至少提取 `value` 与目标函数类型）；
2. 从 signature 提取 `algId`；
3. 执行 `requiredTier(value)` 与 `algId` 一致性检查；
4. 若配置了 `guard`，执行 `guard.checkTransaction(value, algId)`；
5. 再进入 `_validateSignature`。

**收益**：把文档中的“硬红线”从配置项变成强制约束。

### 建议 B：引入 light-account 风格的“状态命名空间/布局约束”

虽然你们目前是非代理架构，但仍建议在关键状态（owner、guard、validator、tier）旁建立“布局注释与 slot 固化约定”。

**收益**：
- 后续 v8/v9 迁移、审计、脚本迁移更稳；
- 降低社交恢复/多验证器扩展时的存储碰撞风险。

### 建议 C：引入 simple-team-account 风格的“签名域分离与意图绑定”

BLS triple 已做了 messagePoint 二次绑定，这是好的；建议进一步：
- 明确不同签名片段的 domain tag；
- 把 chainId、entryPoint、account address、nonce 域统一写入签名意图。

**收益**：降低跨链重放、跨账户重放、跨模块误签名风险。

### 建议 D：账户配置“最小可用模板化”

把账户初始化沉淀成 2~3 个模板（个人版、团队版、恢复优先版）：
- 预设 tier limit；
- 预设 allowed algorithms；
- 预设 guardians/恢复窗口。

**收益**：产品易用性显著提升，减少“用户可配过多导致不安全”的问题。

### 建议 E：测试升级为“策略闭环测试矩阵”

在现有测试基础上新增：
- Tier × algId 全矩阵（应通过/应拒绝）；
- guard 算法白名单 + 日限额跨天；
- aggregator 路径与 non-aggregator 路径一致性；
- social recovery 与 tier/guard 的交互边界。

**收益**：把“功能存在”提升为“策略正确性可证明”。

---

## 5) 建议的三阶段落地顺序

- **Phase 1（1~2 周）**：完成 `validateUserOp` 强制策略闭环 + 测试矩阵。
- **Phase 2（1 周）**：模板化初始化（Factory 参数分层），补齐运维脚本。
- **Phase 3（持续）**：按 PQ / 隐私执行器接入节奏扩展 validator/executor，同时保持 guard 为硬约束。

---

## 6) 本次审阅的环境限制

- 尝试拉取 `lib/simple-team-account` 与 `lib/light-account` 失败（GitHub CONNECT tunnel 403）。
- 因此本文件给的是“仓库内证据 + 架构一致性”判断，不是“逐行源码血缘追踪”。
