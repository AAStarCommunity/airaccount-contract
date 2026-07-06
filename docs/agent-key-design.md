# Agent 私钥管理设计

> 最后更新：2026-05-23
> 状态：设计决策已确认，KMS 侧实现待启动
> 关联：docs/kms-agent-requirements.md · docs/agent-account-architecture.md

> ⚠️ **口径更正（2026-07-06 · 会话密钥统一，见 [#178](https://github.com/AAStarCommunity/airaccount-contract/issues/178)）**
> airaccount-contract v0.27.0 起，独立的 `AgentSessionKeyValidator`（M7 ERC-7579 安装式模块）已**删除**并统一进 `SessionKeyValidator`（router algId `0x08`，agent 作用域）；授权入口为 `SessionKeyValidator.grantSession()`（非 `grantAgentSession()`），不存在独立 algId。本文下方凡出现 `AgentSessionKeyValidator` / `grantAgentSession` / `enforceSessionScope` / `../src/validators/AgentSessionKeyValidator.sol` 等，均为 **M7 历史设计口径**，请以当前源码 `src/validators/SessionKeyValidator.sol` + [ADR 2026-05-30](2026-05-30-adr-session-key-unification.md) 为准。叙事重写在 #178 跟踪。

---

## 0. 安全前提：removeGuardian 的已知漏洞

**当前代码（AAStarAirAccountBase.sol:1279）：**
```solidity
function removeGuardian(uint8 index) external onlyOwner {
```

`removeGuardian` 是 `onlyOwner`，owner 可单独移除任意 guardian，且移除 guardian 会自动取消进行中的 recovery（1292-1295 行）。

**影响：** 若 owner 私钥泄露，攻击者可依次移除所有 guardian → 取消 recovery → 账户失控。

**已知缺口，待修复方向：**
- 短期：将 `removeGuardian` 的 guardian 最低数量保护为 1（至少保留一个 guardian，确保 recovery 路径存在）
- 长期（下一版本合约）：guardian 移除需要 guardian 多签或时间锁（不仅仅 owner 可操作）

**这一漏洞直接决定了下方两种 agent 设计的关键约束。**

---

## 1. 助理型 Agent（Session Key 模式）

### 1.1 设计决策

| 维度 | 决策 | 说明 |
|-----|------|------|
| session key 存在哪 | **KMS（TEE）** | 不在 agent 进程 RAM，不随进程重启消失 |
| 运行时谁发起签名 | agent 进程 → KMS `/kms/sign-session` | agent 持有调用凭证 |
| 人类何时参与 | **仅一次**（session 创建时，passkey 认证）| 之后 agent 自主运行，无需人类指纹 |
| session 有效期 | 有限期（建议 24h-7d），可续期 | 不能"永久"，每次续期需人类重新授权 |
| 受约束 | callTargets + selectorAllowlist + spendCap + velocityLimit | 合约层强制执行 |

### 1.2 完整流程

```
[Session 创建——人类操作，仅一次]

1. 人类 passkey 认证 → /kms/create-session-key
   请求体：{ account, agentId, constraints, expiry, webauthn_assertion }
   响应：{ keyId, sessionKeyAddr, agentCredential(JWT), grant_calldata }

2. KMS 在 TEE 内生成 secp256k1 密钥对，sessionKey 私钥永不离开 TEE

3. 人类（或 SDK 自动）把 grant_calldata（grantAgentSession 的签名 UserOp）提交上链
   → AgentSessionKeyValidator 记录 sessionKeyAddr 的权限

4. 人类把 agentCredential（JWT）安全传给 agent 进程

[Agent 运行时——全自动，无人类参与]

5. Agent 构造 UserOp，调 POST /kms/sign-session
   请求头：Authorization: Bearer <agentCredential>
   请求体：{ keyId, userOpHash }
   响应：{ signature }

6. Agent 把 signature 填入 UserOp，提交 Bundler

[Session 续期——需人类重新授权]

7. agentCredential 临近过期 → agent 通知人类 → 人类 passkey 重新授权
   （扩大 constraints 或更换 sessionKeyAddr 均需人类 passkey）
```

### 1.3 agentCredential 安全模型

agentCredential 是 JWT，绑定了：
```
{ keyId, agentId, account, chainId, constraints_hash, expiry }
```

KMS 持有签名密钥，agent 只持有完整 JWT（无法伪造）。

**agentCredential 泄露的影响：**
- 攻击者可以在 expiry 前用泄露的 credential 请求 KMS 签名
- 但签名必须满足 constraints（callTargets、spendCap 等在 KMS 内部验证）
- 且 credential 被 keyId 绑定——不能用于其他 session key
- 人类可随时调 `/kms/revoke-session-credential` 立即吊销

**关键限制：** agentCredential 是 bearer token，谁持有谁能用。比 WebAuthn 弱，但已是 agent 无生物特征时的最优实践（参考 OAuth2 Client Credentials）。

---

## 2. 自主型 Agent（Agent AirAccount）

### 2.1 设计决策（已确认）

| 维度 | 决策 | 说明 |
|-----|------|------|
| AirAccount owner | **人类的 AirAccount** | 不是 agentKey |
| agentKey 角色 | **session key（有约束）** | 通过 AgentSessionKeyValidator 授权 |
| agentKey 存在哪 | KMS（TEE）或进程 RAM | 同助理型处理方式 |
| 资产归属 | **agent 独立 AirAccount** | 与助理型的根本区别 |
| guardian 配置 | [guardian2, communityGuardian] | **2-of-2 可恢复**（人类是 owner，不在 guardian 列表，以代码为准） |

### 2.2 为何 owner 不能是 agentKey

因为当前代码 `removeGuardian` 是 `onlyOwner`：
- agentKey 被攻击 → 移除所有 guardian → 取消 recovery → 失控
- 人类做 owner → agentKey 最多是 session key → 泄露后损失被 constraints 限制 + 人类可 revoke

### 2.3 账户结构

```
Agent AirAccount   （以 AAStarAirAccountFactoryV7.createAgentAccount 实现为准）
├── owner: humanOwner（人类，msg.sender）— 完整控制权
├── guardian[0]: guardian2（人类指定第二 guardian）
├── guardian[1]: defaultCommunityGuardian
│   （2-of-2 恢复；humanOwner 是 owner 但**不**在 guardian 列表，避免 owner==guardian 约束）
└── agentKey: 以 session key 形式授权（AgentSessionKeyValidator.grantAgentSession）
              constraints: { callTargets, selectorAllowlist, spendCap(velocity), expiry }
```

### 2.4 完整流程

```
[账户创建——人类操作]

1. 人类 passkey 认证 → /kms/create-agent-session-key（同助理型 create-session-key）
   → 得到 agentKeyAddr + agentCredential

2. 人类调 createAgentAccount(agentKeyAddr, agentId, guardian2, ...)
   → 工厂部署 Agent AirAccount，owner = humanOwner

3. 人类调 grantAgentSession(agentKeyAddr, constraints) on Agent AirAccount
   → agentKey 获得受约束的 session key 能力

4. 人类把 agentCredential 传给 agent 进程

[Agent 运行时]

5. Agent 调 /kms/sign-session（同助理型），签名 UserOp
6. UserOp 通过 AgentSessionKeyValidator 验证（session key 路径）
7. TierGuardHook 执行时强制 callTargets/spendCap 约束

[agentKey 泄露时的恢复]

8. 人类调 revokeAgentSession(agentKeyAddr)——即时生效
9. 人类生成新的 agentKeyAddr，重新 grantAgentSession
   （不需要社会恢复，因为 owner 是人类，可以直接操作）
```

---

## 3. 两种类型对比

| 维度 | 助理型（Session Key）| 自主型（Agent AirAccount）|
|-----|---------------------|--------------------------|
| 操作谁的账户 | 人类账户 | Agent 独立账户 |
| 账户 owner | 人类 | 人类（！非 agentKey）|
| agentKey 角色 | session key（有约束）| session key（有约束）|
| agentKey 私钥位置 | KMS TEE | KMS TEE |
| 资产独立 | ❌ | ✅ |
| 即时撤销 | ✅ revokeAgentSession | ✅ revokeAgentSession |
| 社会恢复 | 不需要 | 仅当 owner（人类账户）本身被攻击时 |
| KMS 新接口需求 | `/kms/create-session-key` + `/kms/sign-session` | 相同接口复用 |

---

## 4. KMS 需要实现的新接口（两种类型共用）

### 4.1 `POST /kms/create-session-key`
- 认证：人类 WebAuthn passkey（必须）
- 功能：在 TEE 内生成 session key，返回 keyId + addr + agentCredential
- agentCredential 只返回一次，KMS 只存哈希

### 4.2 `POST /kms/sign-session`
- 认证：Bearer agentCredential（JWT）
- 功能：用 session key 私钥签名 userOpHash，在 TEE 内验证 constraints
- 速率限制：防 credential 泄露后大量签名

### 4.3 `POST /kms/revoke-session-credential`
- 认证：人类 WebAuthn passkey
- 功能：即时吊销指定 agentCredential，后续该 credential 请求返回 401

---

## 5. 当前代码缺口与 TODO

| 问题 | 严重度 | 建议 |
|-----|--------|------|
| `removeGuardian` 是 `onlyOwner`，无多签保护 | HIGH | 短期：保留最少 1 guardian；长期：guardian 移除需多签/时间锁 |
| KMS 新接口未实现 | BLOCKING | 见 AirAccount issue #3 |
| AgentSessionKeyValidator 执行路径 callTarget 强制（TODO 注释）| HIGH | PR #36 部分修复，需确认覆盖 nonce-key 路径 |

---

*关联：[kms-agent-requirements.md](kms-agent-requirements.md) · [agent-account-architecture.md](agent-account-architecture.md)*
