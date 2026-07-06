# 辅助型 Agent 账户 — 完整流程

> 类型：助理型（Assistant Agent）  
> 机制：Session Key（algId 0x08）  
> 账户归属：Agent 在人类 AirAccount 内操作，无独立账户  
> 状态：M7 已实现，可用

> ⚠️ **口径更正（2026-07-06 · 会话密钥统一，见 [#178](https://github.com/AAStarCommunity/airaccount-contract/issues/178)）**
> airaccount-contract v0.27.0 起，独立的 `AgentSessionKeyValidator`（M7 ERC-7579 安装式模块）已**删除**并统一进 `SessionKeyValidator`（router algId `0x08`，agent 作用域）；授权入口为 `SessionKeyValidator.grantSession()`（非 `grantAgentSession()`），不存在独立 algId。本文下方凡出现 `AgentSessionKeyValidator` / `grantAgentSession` / `TierGuardHook` 等，均为 **M7 历史设计口径**（TierGuardHook 亦已删除，约束改由 SessionKeyValidator + 执行侧 guard 承担），请以当前源码 `src/validators/SessionKeyValidator.sol` + [ADR 2026-05-30](2026-05-30-adr-session-key-unification.md) 为准。叙事重写在 #178 跟踪。

---

## 核心设计原则

Agent 是代码，无法使用指纹。**授权与执行分离**：
- **授权阶段**：人类用指纹签名，决定 agent 能做什么
- **执行阶段**：Agent 用 KMS 中的 EOA 密钥签名 UserOp，不需要指纹

---

## 前提：人类已有 AirAccount

标准创建流程（已有）：
1. 用户指纹 → KMS 生成 P256 keypair，私钥存 TEE
2. 用户提供 guardian1（备用设备）、guardian2（亲友），各自签 acceptHash
3. 工厂部署 AirAccount：`owner = P256PublicKeyAddr, guardians = [g1, g2, community]`
4. 社区 guardian（`defaultCommunityGuardian`）由工厂自动注入，**不需要签名**

---

## 辅助型 Agent 开通流程

### Step 1：生成 Agent EOA 密钥

**系统动作**（用户不感知）：
```
AirAccount KMS API → generateEOAKeypair()
→ 返回 agentEOA address（公钥）
→ 私钥存入 KMS TEE，通过 API Key 授权签名（无需 WebAuthn）
```

> 与人类密钥的差别：人类密钥通过指纹调用 KMS 签名；agent 密钥通过 API Key 调用 KMS 签名，KMS 需开放一个非 WebAuthn 认证的签名端点。这是当前 KMS 需要新增的能力。

### Step 2：在 ERC-8004 注册 Agent 身份 NFT

**用户操作**：在 App 填写 agent 名称/用途，指纹确认

**链上动作**：
```
humanAirAccount → UserOp → IdentityRegistry.register(agentMetadataURI)
→ 返回 agentId（uint256）
→ NFT ownerOf(agentId) = humanAirAccount   ← 人类持有 NFT，不是 agent
```

> ERC-8004 NFT 是经济归属凭证，不是 agent 的身份凭据。agent 执行时不依赖这个 NFT。

### Step 3：绑定 Agent EOA 到 AgentRegistry

**用户操作**：上一步完成后，App 自动执行（用户无感知）

**链上动作**：
```
humanAirAccount.setAgentWallet(agentId, agentEOA, agentRegistryAddr)
→ 内部调用 AgentRegistry.registerAgent(agentEOA)
→ AgentRegistry: agentWalletOwner[agentEOA] = humanAirAccount
```

**作用**：SuperPaymaster 查询 `AgentRegistry.isRegisteredAgent(agentEOA)` → true → 赞助 agent 的 gas 费

### Step 4：授权 Session Key

**用户操作**：App 展示授权详情，用户指纹确认

```
授权示例 UI：
"授权 [DeFi 助手] 在接下来 7 天内：
  - 每天最多操作 30 USDC
  - 每小时最多调用 100 次
  - 只能调用 Uniswap V3 合约"
```

**链上动作**：
```
humanAirAccount → UserOp → AgentSessionKeyValidator.grantAgentSession(
    agentEOA,
    AgentSessionConfig{
        expiry:         now + 7 days,    // 必须设置，不能永久
        velocityLimit:  100,             // 每小时最多 100 次
        velocityWindow: 3600,
        spendToken:     USDC,
        spendCap:       30e6,            // 30 USDC 累计上限
        callTargets:    [uniswapV3],     // 只允许调用 Uniswap
        selectorAllowlist: [...],        // 可选：进一步限制函数
        revoked:        false
    }
)
```

### Step 5：Agent 日常执行

**Agent 运行时逻辑**：
```
1. Agent 确定要执行的操作（如：swap 10 USDC for ETH）
2. 构造 UserOp（calldata = execute(uniswap, 0, swapData)）
3. 调用 KMS API：sign(userOpHash, agentEOAKeyId)
4. 组装签名：signature = [0x08 | ECDSASign(agentKey, userOpHash)]  // 0x08 = ALG_SESSION_KEY
5. 提交 UserOp 到 Bundler
```

**验证链**：
```
EntryPoint → humanAirAccount.validateUserOp
  → nonce key 路由 → AgentSessionKeyValidator.validateUserOp
    ✓ 检查 expiry、revoked、velocityLimit、spendCap
    ✓ 存储 sessionKey 到 transient storage（M8 PR #36 修复）
  → TierGuardHook.preCheck
    ✓ algId=0x08 → Tier 1
    ✓ 日限额检查
    ✓ enforceSessionScope：callTargets、selectorAllowlist（M8 PR #36 修复）
  → execute 在人类账户内执行
```

### Step 6：撤销

- **主动撤销**：`revokeAgentSession(agentEOA)` → 下一个 UserOp 立即失效
- **自动到期**：expiry 到达后自动失效，无需任何操作

---

## 约束边界

| 约束 | 来源 | 优先级 |
|------|------|--------|
| Tier 1 日限额 | GlobalGuard | 最高，不可绕过 |
| spendCap（累计）| AgentSessionKeyValidator | 会话级 |
| velocityLimit/Window | AgentSessionKeyValidator | 频率限制 |
| callTargets | AgentSessionKeyValidator + TierGuardHook | 目标白名单 |
| selectorAllowlist | AgentSessionKeyValidator + TierGuardHook | 函数白名单 |
| expiry | AgentSessionKeyValidator | 时效性 |

---

## 系统依赖项（当前缺口）

| 依赖 | 状态 | 说明 |
|------|------|------|
| AgentSessionKeyValidator（ERC-7579 模块） | ✅ M7 已实现 | 已部署 |
| TierGuardHook enforceSessionScope 集成 | ✅ M8 PR #36 | callTargets 在 execute() 路径执行 |
| AgentRegistry 合约 | ✅ M8 PR #34 | SuperPaymaster 反向查询 |
| KMS 非 WebAuthn 签名端点 | ❌ 待实现 | agent 程序化调用 KMS 签名，不走指纹 |
| SuperPaymaster 配置 `setAgentRegistries` | ❌ 待链上执行 | 部署 AgentRegistry 后执行一次 |

---

## 挑战与漏洞

### 1. KMS 非 WebAuthn 端点安全边界
Agent 通过 API Key 调用 KMS 签名，一旦 API Key 泄露，agent 的所有权限暴露。  
**缓解**：Session Key 的 spendCap + callTargets 限制了损失上限；API Key 应绑定具体的 agentEOA 和账户范围。

### 2. Session Key 不能跨账户使用
AgentSessionKeyValidator 在验证时检查 `address(this) == sig[1:21]`，防止同一个 agentEOA 被用于操作其他账户。  
**影响**：一个 agent 要操作多个人类账户，需要每个账户分别 grantAgentSession。

### 3. ERC-8004 步骤是否必须？
ERC-8004 注册仅为 SuperPaymaster 的 gas 赞助提供依据。如果 agent 自行支付 gas（账户内有 ETH），可完全跳过 Step 2 和 Step 3。  
**建议**：ERC-8004 注册设为可选步骤，在 App 中明确标注"开启 Gas 赞助需要此步骤"。

### 4. 速率限制窗口的重置问题
`velocityWindow` 是固定长度滑动窗口，不是每小时整点重置。agent 可以在窗口边界集中调用达到 2x 速率。  
**评估**：可接受，业界标准行为，不是安全漏洞。

---

*最后更新：2026-05-22*
