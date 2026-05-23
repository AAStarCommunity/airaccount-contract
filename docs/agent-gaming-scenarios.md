# Agent Session Key — 链游场景适配性分析

> 独立文档，响应 docs/agent-account-architecture.md 中的调研请求
> 最后更新：2026-05-22

---

## 0. 前言：为何不特指"链游"

jhf 的观点正确：未来所有在线游戏的资产默认上链，"链游"只是当前的过渡称呼。本文分析的是"需要实时高频操作、资产有链上价值"的游戏场景，这也是绝大多数未来游戏的形态。

---

## 1. 典型游戏场景拆分

### 场景 A：开放世界 RPG（Pixels / Illuvium 类）

**核心操作：**
- 频率：每分钟 5-20 次（移动、采集、战斗）
- 金额：小额代币（0.001-0.1 USD/次），偶有高价值物品交易
- 目标合约：游戏核心合约（移动、战斗）+ NFT 市场合约
- 时效性：需要低延迟（< 2s），但非实时毫秒级

**Session Key 适配性分析：**
| 约束维度 | 游戏需求 | Session Key 能力 | 匹配度 |
|---------|---------|-----------------|--------|
| 频率 | 20次/分钟 = 1200次/小时 | velocityLimit/velocityWindow 可配置 | ✅ |
| 金额上限 | 每次 < 0.1 USD | spendCap 累计上限 | ✅ |
| 目标白名单 | 只允许游戏合约 | callTargets[] | ✅ |
| 时效性 | 7天 session | expiry 可设任意时长 | ✅ |
| 撤销 | 家长控制/账号被盗时 | revokeAgentSession() 即时生效 | ✅ |

**结论：** 完全匹配。建议配置：
```
expiry: now + 7 days
velocityLimit: 1200, velocityWindow: 3600  // 每小时 1200 次
spendCap: 10 USDC  // 7天累计上限
callTargets: [gameContract, nftMarket]
```

---

### 场景 B：实时对战游戏（Gods Unchained / Axie 类卡牌/对战）

**核心操作：**
- 频率：对局期间每秒 1-5 次（出牌、技能），对局间隔较长
- 金额：对局本身基本免费，只有胜利奖励时有转账
- 目标合约：游戏逻辑合约（出牌/技能）+ 奖励分发合约
- 时效性：需要低延迟，链上确认可能是瓶颈

**Session Key 适配性分析：**

| 挑战 | 分析 | 解决方案 |
|-----|------|---------|
| **链上确认延迟**（1-5s） | 对于实时对战是致命的 | 游戏逻辑走 Layer 2 或 State Channel，只有最终结算上链 |
| 高频出牌（5次/秒）| velocityLimit 可以配到 300次/分钟 | ✅ 足够 |
| 奖励转账安全 | 奖励合约不在 callTargets 白名单内 | 奖励合约单独加入 callTargets |

**结论：** Session Key 适合"最终结算"模式，不适合每一步都上链的实时游戏。实时对战游戏的正确架构：
```
游戏逻辑（链下）→ 最终结算（链上，Session Key 签名）
```
这实际上是行业主流做法（ImmutableX、Ronin 的状态通道思路）。

---

### 场景 C：DeFi 套利/流动性挖矿机器人

**核心操作：**
- 频率：可能每分钟 10-100 次（监控 + 交易）
- 金额：高价值（可能数千 USD/次）
- 目标：Uniswap V3、Aave、Compound 等
- 时效性：需要抢占先机，延迟敏感

**Session Key 适配性分析：**

| 约束 | 挑战 | 匹配度 |
|-----|------|--------|
| spendCap | 高价值操作需要大 spendCap | ⚠️ spendCap 设太大=风险，设太小=功能受限 |
| Tier 1 限额 | Session Key 最高只能到 Tier 1 日限额 | ❌ 高价值 DeFi 超出 Tier 1 无法执行 |
| velocityLimit | 高频套利可能触发频率限制 | ⚠️ 需要配置足够高的 velocityLimit |

**结论：** Session Key **不适合**高价值 DeFi 机器人（受 Tier 1 日限额约束）。这类场景应该使用**自主型 Agent AirAccount**（路径 2），可以设置更高的 dailyLimit，但代价是撤销需要 48h social recovery。

---

### 场景 D：游戏内 AI 导师 / 助理（低价值辅助操作）

**核心操作：**
- 帮助玩家自动完成重复任务（日常任务、资源采集）
- 频率：低-中（每分钟 1-10 次）
- 金额：极低（< 0.01 USD/次）
- 目标：只有当前游戏合约

**Session Key 适配性分析：** ✅ 完美匹配

这是 Session Key 最典型的使用场景：用户授权 AI 助理在指定游戏合约内、指定金额范围内、指定时间内自动操作。

---

### 场景 E：NFT 自动挂单 / 地板价监控机器人

**核心操作：**
- 监控 NFT 市场，自动挂单/撤单/买入
- 频率：中（每小时 50-200 次）
- 金额：中等（0.1-10 ETH/次）
- 目标：NFT 市场合约（OpenSea Seaport、Blur）

**Session Key 适配性分析：**

| 约束 | 挑战 | 解决方案 |
|-----|------|---------|
| Tier 1 限额 | 单笔 > Tier 1 = 拒绝 | ⚠️ 低地板价 NFT 可以，高价值 NFT 不行 |
| callTargets | NFT 市场合约是固定的 | ✅ 可以只允许 Seaport 合约 |

**结论：** 低价值 NFT（< Tier 1 日限额）✅；高价值 NFT 机器人需要自主型 AirAccount。

---

## 2. Session Key 机制 vs 行业方案对比

### 2.1 ZeroDev Kernel Session Keys

```solidity
// ZeroDev 的权限配置
struct Permission {
    address target;
    bytes4 functionSelector;
    uint256 valueLimit;      // 单笔金额限制
    bytes[] conditions;      // 参数级别的限制（ABI 编码）
}
```

**差异：**
- ZeroDev 支持**参数级别**的限制（如 swap 金额 > 100 USDC 才允许），AirAccount 只到函数选择器级别
- ZeroDev **没有 velocityLimit**（频率限制），AirAccount 有 → AirAccount 更适合防止 API Key 泄露后高频攻击
- ZeroDev 支持多个 Session Key 组合，AirAccount 的 `delegateSession()` 有类似的子委托能力

### 2.2 Safe + PasskeyPlugin

- Safe 的 Session Key 需要 Safe 多签批准，门槛高
- 适合企业/团队场景，不适合个人 AI Agent
- AirAccount 单 passkey 即可授权，UX 更简单

### 2.3 MetaMask Delegation Toolkit (ERC-7715)

```
wallet_grantPermissions({
    permissions: [{
        type: "erc20-transfer",
        data: { allowance: "100000000" }  // 100 USDC
    }]
})
```

- MetaMask 的抽象程度更高（协议级权限描述），AirAccount 更底层（合约+选择器级）
- MetaMask 需要 MetaMask 浏览器插件，AirAccount 是账户抽象原生支持
- 两者不互斥：AirAccount 可以作为 ERC-7715 的执行层

### 2.4 Coinbase x402 协议

x402 是"HTTP 402 Payment Required"协议的 Web3 实现：
```
Agent → GET /api/premium-data
Server → 402 Payment Required
         { amount: "0.001 USDC", recipient: "0x..." }
Agent → 构造 USDC transfer UserOp，用 Session Key 签名，提交 Bundler
Agent → 重新发起请求（带支付证明）
Server → 200 OK + 数据
```

AirAccount Session Key **完全支持** x402 场景，只需在 `callTargets` 中包含 USDC 合约，`selectorAllowlist` 包含 `transfer(address,uint256)` 选择器。

---

## 3. 场景适配矩阵汇总

| 游戏/AI 场景 | Session Key（助理型）| 自主型 AirAccount | 推荐 |
|------------|---------------------|-----------------|------|
| 开放世界 RPG 日常任务 | ✅ | 可 | Session Key |
| 实时对战（最终结算）| ✅ | 可 | Session Key + L2 |
| 实时对战（每步上链）| ❌ 延迟问题 | ❌ | State Channel |
| 低价值 NFT 机器人 | ✅ | 可 | Session Key |
| 高价值 NFT/DeFi 机器人 | ❌ Tier 1 上限 | ✅ | 自主型 AirAccount |
| AI 助理（x402 自动付费）| ✅ | 可 | Session Key |
| 游戏 AI 导师 | ✅ | 不必要 | Session Key |
| 独立商业 AI Agent | ❌ | ✅ | 自主型 AirAccount |

---

## 4. 待验证的技术问题

| 问题 | 优先级 | 方式 |
|-----|--------|-----|
| velocityLimit 在真实高频游戏中的性能（gas 消耗）| P1 | Foundry gas test |
| Bundler 对同一 sender 的包含频率限制 | P1 | 集成测试 |
| session key 在 L2（Optimism/Arbitrum）的 gas 实际成本 | P1 | 链上测试 |
| x402 端到端测试（助理型 agent + USDC 支付）| P1 | M8 产品化后 |
| 高并发场景（多 agent 同时使用同一人类账户）| P2 | 架构评审 |

---

*最后更新：2026-05-22*
*关联文档：[agent-assistant-flow.md](agent-assistant-flow.md) · [agent-autonomous-flow.md](agent-autonomous-flow.md)*
