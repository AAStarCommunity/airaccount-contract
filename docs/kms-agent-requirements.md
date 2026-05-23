# KMS Agent 需求规格

> 文档类型：KMS 团队需求交付物
> 作者：airaccount-contract 团队
> 最后更新：2026-05-23
> 关联：docs/agent-account-architecture.md §2, §4

---

## 0. 背景

AirAccount M8 引入两类 Agent：

| Agent 类型 | 私钥所有者 | 签名触发方式 |
|----------|----------|-----------|
| 助理型（Session Key） | 人类 AirAccount 授权的临时 EOA | 进程内签名（现有 SDK） |
| 自主型（Agent AirAccount）| Agent 拥有独立 AirAccount，agentKey 是其 owner | **本文档范围** |

自主型 Agent 的 agentKey 是一个独立 secp256k1/P-256 密钥对。该密钥对**必须**由 KMS 保管（TEE 隔离），不能以明文方式持久化在 Agent 进程内存或磁盘中。

---

## 1. 核心需求：新增 `/kms/sign-agent` 端点

### 1.1 端点规格

```
POST /kms/sign-agent
Content-Type: application/json
Authorization: Bearer <agent_credential>
```

**请求体**

```json
{
  "keyId":     "string",   // KMS 内部密钥标识符，由 /kms/create-agent-key 返回
  "payload":   "0x...",    // 需要签名的原始字节（hex 编码，32 bytes 的 keccak256 digest）
  "algorithm": "secp256k1" // 当前固定值；未来扩展支持 p256
}
```

**响应体（成功）**

```json
{
  "signature": "0x...",    // 65 字节 ECDSA 签名（r+s+v，EIP-191 兼容）
  "keyId":     "string",
  "address":   "0x..."     // 对应的 secp256k1 公钥衍生的以太坊地址
}
```

**错误码**

| HTTP 状态 | 场景 |
|---------|------|
| 401 | agent_credential 无效或已过期 |
| 403 | keyId 与 credential 不匹配（Agent 只能签名自己的 key） |
| 404 | keyId 不存在 |
| 422 | payload 格式错误（非 32 bytes hex） |
| 429 | 速率限制（防止 credential 泄露后的大规模签名攻击） |

### 1.2 与现有 `/kms/sign` 的区别

| 维度 | `/kms/sign`（现有） | `/kms/sign-agent`（新增） |
|-----|-----------------|------------------------|
| 认证方式 | WebAuthn（人类指纹/face ID）| agent_credential（见 §3） |
| 适用场景 | 人类手动操作 | Agent 程序自动调用 |
| 密钥类型 | 人类 owner key | agent owner key |
| 速率限制 | 低频（人类操作）| 高频（程序化，需额外限制）|

---

## 2. 新增 `/kms/create-agent-key` 端点

### 2.1 端点规格

```
POST /kms/create-agent-key
Content-Type: application/json
Authorization: Bearer <human_passkey_session_token>   // 必须是人类 WebAuthn 认证后的 token
```

**请求体**

```json
{
  "agentId":      "bytes32_hex",    // 合约层使用的 agentId（链上唯一标识）
  "humanAccount": "0x...",          // 人类的 AirAccount 合约地址（所有者）
  "label":        "string"          // 可选，方便管理的描述（如 "trading-bot-1"）
}
```

**响应体（成功）**

```json
{
  "keyId":           "string",    // KMS 内部唯一标识
  "agentAddress":    "0x...",     // 衍生的以太坊地址（用作 agentKey 参数传给 createAgentAccount）
  "agentCredential": "string",    // 初始 credential（JWT 或 opaque token），Agent 运行时持有
  "credentialExpiry": "ISO8601"   // credential 过期时间（建议 90 天，可续期）
}
```

**安全要求：**
- 此端点必须由**人类 WebAuthn session token** 调用（证明是人类在授权创建 Agent 密钥）
- `agentCredential` 只在创建时返回一次；KMS 只存储其哈希（类似 GitHub PAT 设计）
- `agentAddress` 的私钥永不离开 KMS TEE

---

## 3. Agent Credential 认证机制

### 3.1 设计意图

自主型 Agent 没有指纹/人脸，无法使用 WebAuthn。需要一种"程序可持有、可撤销、有时效"的凭证来向 KMS 证明身份。

### 3.2 Credential 格式（推荐：JWT HS256）

```
Header: { "alg": "HS256", "typ": "JWT" }
Payload: {
  "sub":     "<keyId>",           // 对应的 KMS keyId
  "iss":     "kms.airaccount",    // 颁发者
  "aud":     "kms.sign-agent",    // 受众
  "iat":     <unix_timestamp>,
  "exp":     <unix_timestamp>,    // 颁发时间 + 90 天
  "humanAccount": "0x...",        // 绑定的人类账户地址（用于审计）
  "agentId":      "bytes32_hex"   // 绑定的链上 agentId
}
Signature: HMAC-SHA256(header.payload, kms_secret)
```

KMS 持有签名密钥，Agent 只持有完整 JWT（不知道签名密钥）。

### 3.3 Credential 生命周期

```
人类 WebAuthn 认证
  → POST /kms/create-agent-key
  ← agentCredential (JWT, 90天有效)
  
  [Agent 运行时]
  → POST /kms/sign-agent (Bearer JWT)
  ← signature

[到期前 7 天]
  → POST /kms/refresh-agent-credential (需要原 credential + 人类 WebAuthn 重新授权)
  ← new_credential

[撤销]
  → POST /kms/revoke-agent-credential (人类 WebAuthn 授权)
  ← 204 No Content
  所有使用旧 credential 的签名请求立即返回 401
```

### 3.4 Credential 存储建议（Agent 侧）

| 方案 | 安全性 | 复杂度 | 推荐场景 |
|-----|--------|--------|---------|
| 环境变量（`AGENT_KMS_CREDENTIAL`）| 中等 | 低 | 开发/测试 |
| Docker Secret / K8s Secret | 较高 | 中等 | 生产容器化部署 |
| 硬件安全模块（HSM）/ 本地 KMS | 高 | 高 | 高价值 Agent |

**最低要求：** credential 不得写入日志、不得提交到代码仓库、不得明文写入数据库。

---

## 4. 可选方案：KMS 硬件随机数生成端点

对于不依赖 KMS 长期存储私钥、选择"进程内安全随机生成+进程内持有"的场景（jhf 提到的方案2），KMS 提供硬件熵源：

```
POST /kms/hwrng
Content-Type: application/json
Authorization: Bearer <human_passkey_session_token>

Request:  { "bytes": 32 }
Response: { "entropy": "0x..." }  // 32 bytes TRNG output from HSM
```

**用途：** Agent 启动时调用一次，获取高质量熵源，在进程内生成 secp256k1 密钥对，私钥只存在 RAM 中（进程重启后消失，需重新生成并更新链上 agentKey）。

**适用条件：** 仅适合短期临时 Agent（任务结束即销毁），不适合需要跨进程持久化身份的长期 Agent。

---

## 5. HD 钱包衍生方案（可选架构）

如果 KMS 团队希望支持从人类主密钥衍生 Agent 子密钥（BIP32），可增加以下端点：

```
POST /kms/derive-agent-key
Authorization: Bearer <human_passkey_session_token>

Request:
{
  "masterKeyId": "string",          // 人类主密钥的 KMS keyId
  "derivationPath": "m/44'/60'/0'/1/<agentIndex>"  // BIP44 agent 路径
}

Response:
{
  "childKeyId":   "string",
  "agentAddress": "0x..."
}
```

**衍生路径约定：**
- `m/44'/60'/0'/0/x`：人类 OAPD 子账户（现有）
- `m/44'/60'/0'/1/x`：Agent 密钥（新增，agent index 从 0 递增）

**好处：** 一个主密钥可管理所有 Agent 子密钥，备份恢复只需备份主密钥。
**代价：** 任意一个子密钥泄露不影响其他子密钥（硬化衍生路径 `'` 保证隔离）。

---

## 6. 安全要求汇总

| 要求 | 优先级 | 说明 |
|-----|--------|------|
| `/kms/sign-agent` 速率限制 | P0 | 防止 credential 泄露后大量签名 |
| Agent credential 单次可见 | P0 | 创建后 KMS 只存哈希，不可再次获取明文 |
| keyId 与 credential 绑定校验 | P0 | Agent 只能签名自己的 key，不能横向访问 |
| Credential 撤销即时生效 | P0 | 人类可随时通过 WebAuthn 撤销任意 Agent credential |
| 签名请求审计日志 | P1 | 记录 keyId + 调用时间 + 请求 IP，供安全审计 |
| Credential 续期需人类重认证 | P1 | 防止 Agent 自我续期导致 credential 永久有效 |
| TEE 内存隔离 | P0 | Agent 私钥的 sign 操作必须在 TEE 内完成，不暴露到外部 |

---

## 7. M8 集成时序

```
[人类 onboarding 时]
1. 人类 passkey 认证 → WebAuthn session token
2. POST /kms/create-agent-key { agentId, humanAccount }
   ← { keyId, agentAddress, agentCredential }
3. agentCredential 交给 Agent 进程（安全传输）
4. 人类调用 createAgentAccount(agentKey=agentAddress, ...) 上链

[Agent 运行时]
5. Agent 构造 UserOp，需要 agentKey 签名
6. POST /kms/sign-agent { keyId, payload: userOpHash }
   ← { signature }
7. Agent 将 signature 填入 UserOp.signature，提交 Bundler
```

---

## 8. 待确认事项

| 问题 | 当前状态 | 负责方 |
|-----|---------|--------|
| credential 格式：JWT vs opaque token | 待确认 | KMS 团队 |
| KMS 是否已有 TRNG 硬件熵端点 | 待确认 | KMS 团队 |
| 是否支持 BIP32 HD 衍生 | 可选 | KMS 团队 |
| credential 最大有效期 | 建议 90 天，待确认 | KMS 团队 |
| 速率限制阈值（次/分钟） | 待确认 | KMS 团队 |
| 签名审计日志保存时长 | 待确认 | KMS 团队 |

---

*关联文档：[agent-account-architecture.md](agent-account-architecture.md) §2 §4 · [agent-autonomous-flow.md](agent-autonomous-flow.md)*
