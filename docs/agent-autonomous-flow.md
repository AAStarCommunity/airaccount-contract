# 自主型 Agent 账户 — 完整流程

> 类型：自主型（Autonomous Agent）  
> 机制：独立 AirAccount（createAgentAccount）  
> 账户归属：Agent 拥有独立的 AirAccount，可持有资产、自主支付  
> 状态：M8 PR #35 已实现合约层，UX 流程待完善

---

## 核心设计原则

Agent 拥有与人类等价的完整 AirAccount。差异：
- **Owner**：agent 的 EOA 密钥（存 KMS，程序化签名）
- **Guardian1**：人类的 AirAccount（合约地址，通过 ERC-1271 行使 guardian 权）
- **资产**：独立持有，可接收 x402 支付、DeFi 收益等

---

## 前提：人类已有 AirAccount（同辅助型）

---

## 自主型 Agent 账户创建流程

### Step 1：生成 Agent EOA 密钥

与辅助型 Step 1 相同：KMS 生成 EOA keypair，私钥存 TEE，返回 agentEOA address。

### Step 2：确定 Guardian 配置

`createAgentAccount` guardian 构成：

| Guardian | 来源 | 是否需要签名 |
|---------|------|------------|
| guardian1 | msg.sender = **人类的 AirAccount 合约地址** | ❌ 自动，无需签名 |
| guardian2 | 调用方传入 | ✅ 需要签名 |
| guardian3 | factory.defaultCommunityGuardian | ❌ 自动，无需签名（工厂信任） |

**guardian2 是核心 UX 问题**，有以下选项：

---

### guardian2 方案分析

#### 方案 A：使用人类自己的 P256 passkey 地址（推荐）

guardian2 = 人类 AirAccount 的 owner 地址（P256 公钥对应的地址）

**流程**：
```
App 计算 acceptHash：
  keccak256("ACCEPT_GUARDIAN" || chainId || factory || agentKey || salt)
  其中 salt = keccak256(humanAirAccountAddr || agentId)

App 请求人类用指纹签这个 hash
人类一次指纹 → 同时产生：
  (a) UserOp 签名（调用 createAgentAccount）
  (b) guardian2 接受签名（acceptHash）
```

**优点**：一次指纹完成所有操作，UX 最简洁  
**缺点**：guardian1（humanAirAccount 合约）和 guardian2（humanPasskeyAddr）都由同一人控制 → 社会恢复实质上是 1 人控制 2 票  
**安全评估**：可接受——agent 账户本来就是人类创建的，人类完全掌控是合理设计

#### 方案 B：用户指定第三方 guardian2

guardian2 = 家人 / 朋友 / 第二台设备

**流程**：
```
App 向 guardian2 发送邀请链接或 QR
guardian2 在自己设备上签 acceptHash（含具体 agentKey + salt）
App 收集签名后，人类指纹确认 createAgentAccount
```

**优点**：更去中心化，安全性更高  
**缺点**：需要协调另一个人，复杂度高，对普通用户不友好

#### 方案 C：社区 guardian 同时作为 guardian2（待实现）

guardian2 = defaultCommunityGuardian

**问题**：guardian2 和 guardian3 会是同一地址 → `DuplicateGuardian` revert  
**修复方式**：新建工厂函数 `createAgentAccountSimple`，guardian 配置改为仅 2 个：
```solidity
guardians: [msg.sender, defaultCommunityGuardian, address(0)]
```
合约层需要验证 address(0) guardian 的处理逻辑是否正确（社会恢复阈值变为 2-of-2）。

**优点**：一次指纹，零额外签名  
**缺点**：2-of-2 recovery，社区 guardian 需在线才能恢复（比 2-of-3 脆弱）；社区 guardian Safe 多签是否愿意为所有 agent 账户承担这个责任待确认

#### 方案 D：修改接受哈希为工厂级别（设计变更）

将社区 guardian 的接受哈希改为：`keccak256("ACCEPT_COMMUNITY_GUARDIAN" || chainId || factory)` ——一次性签名，对该工厂上所有账户有效。

**优点**：社区 Safe 一次签名，永久有效；用户端 UX = 一次指纹  
**缺点**：需要合约层修改接受哈希逻辑；安全含义：社区 guardian 预先承诺为该工厂上所有未来账户做 guardian，无法撤销单个账户的 guardian 身份

---

### 当前实现的完整流程（方案 A）

```
1. KMS 生成 agentEOA
2. App 计算 salt = keccak256(humanAirAccount || agentId)
3. App 计算 acceptHash（包含 agentKey + salt）
4. App 请求人类指纹
5. 人类指纹一次签名产生：
   - UserOp sig（调用 createAgentAccount）
   - guardian2Sig（acceptHash 用 P256 key 签）
6. factory.createAgentAccount(agentKey, agentId, humanPasskeyAddr, guardian2Sig, dailyLimit)
   → guardian1 = humanAirAccount (auto)
   → guardian2 = humanPasskeyAddr (verified by guardian2Sig)
   → guardian3 = community (auto)
   → 部署 agent AirAccount，owner = agentKey
```

**用户感知**：一次指纹，等待合约部署确认。

---

### Step 3：注册 ERC-8004 Agent 身份（可选，同辅助型）

`humanAirAccount → IdentityRegistry.register(agentURI)` → agentId NFT，owner = humanAirAccount

### Step 4：绑定 AgentRegistry（可选，为 gas 赞助）

`humanAirAccount.setAgentWallet(agentId, agentAirAccountAddr, agentRegistryAddr)`

> 注意：这里 agentWallet 是 agent 的 **AirAccount 地址**，不是 EOA 地址。

### Step 5：为 Agent 账户注资

```
humanAirAccount → execute(agentAirAccount, amount, "")  // 转 ETH
或
ERC-20 transfer(agentAirAccount, amount)
或
agent 通过 x402 协议自主获取收入
```

### Step 6：Agent 自主操作

```
Agent 运行时：
1. 构造 UserOp（sender = agentAirAccount）
2. KMS API 签名：signature = [0x02 | ECDSA(agentEOAKey, userOpHash)]  // 普通 ECDSA，Tier 1
3. 提交 Bundler
4. EntryPoint → agentAirAccount.validateUserOp → ECDSA 验证
5. execute，GlobalGuard 日限额执行
```

Agent 有完整 AirAccount 能力：executeBatch、ERC-7579 模块、任意合约交互（在 dailyLimit 内）。

---

## 社会恢复（Agent 账户被攻破时）

```
发起恢复（需要 2-of-3 guardian）：
  guardian1（humanAirAccount）：人类用指纹签 UserOp → humanAirAccount 发出 proposeRecovery
  guardian2（humanPasskeyAddr / 第三方）：直接签 proposeRecovery

48h timelock 后执行恢复，更换 agentKey
```

> guardian1 是合约（humanAirAccount），其 guardian 投票通过 ERC-1271 验证：  
> `humanAirAccount.isValidSignature(recoveryHash, humanPasskeySig)` → 有效  
> 人类用自己的指纹控制 guardian1 投票。

---

## 社区 Guardian 签名问题（你的疑问）

**结论**：社区 guardian（`defaultCommunityGuardian`）在 `createAccountWithDefaults` 和 `createAgentAccount` 中均**无需签名**，工厂直接注入地址。这是正确设计——工厂部署者在 constructor 时信任该地址，合约本身是信任锚，无需每次验证。

所谓"社区 guardian 需要部署服务"的说法只在以下情形成立：方案 C/D 中把社区 guardian 变成 guardian2，而 guardian2 需要签名。当前实现（guardian3 = community）不存在这个问题。

---

## 当前实现缺口

| 项目 | 状态 | 说明 |
|------|------|------|
| `createAgentAccount` 合约函数 | ✅ M8 PR #35 | 已实现，需 guardian2Sig |
| AgentRegistry 合约 | ✅ M8 PR #34 | 已实现 |
| KMS 非 WebAuthn 签名端点 | ❌ 待实现 | agent 程序化调用签名 |
| App 层 guardian2Sig 自动生成 | ❌ 待实现 | 用人类指纹为 guardian2 签名 |
| `createAgentAccountSimple`（方案 C） | ❌ 可选 | 减少 guardian2 要求 |

---

## 挑战与漏洞

### 1. guardian1 是合约地址，不是 EOA
`guardian1 = humanAirAccount`（合约），社会恢复提案需要从 humanAirAccount 发出 UserOp。如果人类账户本身被攻破（passkey 丢失），guardian1 的投票能力也丧失。  
**缓解**：有 guardian2 和 community 作为另外 2 票，2-of-3 仍可恢复。

### 2. agent EOA 在 KMS 的安全级别
自主型 agent 持有大量资产，若 KMS 的 API Key 被盗 → agent 可签任意金额的 UserOp（仅受 dailyLimit 限制）。  
**缓解**：为 agent 账户设置较低的 dailyLimit；重要资产放在 KMS TEE 保护等级最高的 key 下；考虑为 agent 账户安装 TierGuardHook + SpendCap 模块。

### 3. 自主型 agent 无 Session 时效性约束
辅助型有 expiry，自主型没有——agent EOA 永久是 owner 直到社会恢复。  
**反驳**：这是设计目标，自主型 agent 需要长期持续运行。如需临时限制可通过 dailyLimit 和 TierGuardHook 实现。

### 4. 替代方案：不新建账户，继续用 Session Key 但扩展权限
如果 agent 只需要持有少量独立资产，可给 agent EOA 单独转 ETH，让 agent 在辅助型路径下自己支付 gas（不依赖 SuperPaymaster 赞助）。这样无需新建账户，所有操作仍在人类账户 SessionKey 约束内。  
**适用场景**：agent 持有小额资产且不需要对外暴露独立地址。

### 5. 方案 A 的 guardian 集中化问题
方案 A 中 guardian1 和 guardian2 均由同一个人控制（合约 + passkey）。如果用户手机和 KMS 同时被攻破，攻击者同时获得 guardian1 的控制权（通过 humanAirAccount）和 guardian2 的签名能力。  
**评估**：这种双重攻破概率极低，且社区 guardian（guardian3）仍可阻止。可接受。

---

## 路径对比（辅助型 vs 自主型）

| 维度 | 辅助型（Session Key） | 自主型（独立 AirAccount） |
|------|---|---|
| 是否需要新账户 | ❌ | ✅ |
| 创建复杂度 | 一次指纹 | 一次指纹（方案 A）|
| Agent 密钥 | KMS EOA，有 expiry | KMS EOA，永久 |
| 独立持有资产 | ❌ | ✅ |
| x402 独立支付 | ❌（消费人类账户）| ✅ |
| 最大操作额 | Tier 1 日限额上限 | dailyLimit（可设更高）|
| 即时撤销 | ✅ 一笔 tx | ❌ 社会恢复 48h |
| 适合场景 | DeFi 助手、通知响应、自动化 | 独立商业模式、资产管理 AI |

---

*最后更新：2026-05-22*
