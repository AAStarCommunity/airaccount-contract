# KMS Agent 需求规格

> 文档类型：KMS 团队需求交付物
> 作者：airaccount-contract 团队
> 最后更新：2026-05-27
> 关联：docs/agent-account-architecture.md §2, §4 · docs/agent-key-design.md

---

## 0. 背景

AirAccount M8 引入两类 Agent。**两者的账户 owner 都是人类（passkey/WebAuthn 控制），agentKey 都是受约束的 session key（secp256k1 ECDSA）**——区别在“账户边界”，不在权限高低（详见 agent-account-architecture.md）：

| Agent 类型 | 账户归属 | agentKey 角色 | 签名触发方式 |
|----------|----------|----------|-----------|
| 助理型（Session Key） | 在**人类账户内**操作（无独立账户） | 人类账户上授权的 session key | Agent 程序持凭证调 KMS 签名 |
| 自主型（Agent AirAccount）| **独立 AirAccount**（owner=人类，可独立收款/持币） | 该独立账户上授权的 session key | 同上（**本文档范围**） |

> ⚠️ 口径更正：早期版本写过“自主型 agentKey 是账户 owner”，**与合约代码不符**。`createAgentAccount`（`AAStarAirAccountFactoryV7`）实际 `initialize(entryPoint, msg.sender, ...)` → **owner = 人类（msg.sender）**；agentKey 不是 owner，而是部署后通过 `grantAgentSession` 授权的受约束 session key。

agentKey 是一个独立 **secp256k1** 密钥对（链上用 `ecrecover` 验，非 P256；P256 仅人类 passkey 走 EIP-7212）。该密钥对**必须**由 KMS 保管（TEE 隔离），不能以明文持久化在 Agent 进程内存或磁盘中。

---

## 0.5 合约接口对齐（KMS / SDK 必须严格匹配 —— 联调前先对齐）

> 这是 KMS 返回的签名、SDK 拼装的 UserOp 与链上 `AgentSessionKeyValidator` 之间**唯一的硬交界点**。任何一处字节不匹配都会导致 `ecrecover` 取错地址 → 验证失败。

### A. UserOp 签名字节布局（链上 `AgentSessionKeyValidator.validateUserOp` 期望）

```
userOp.signature = 0x08 ‖ R(32) ‖ S(32) ‖ V(1)      // 共 66 字节
  · 第 0 字节固定 0x08（ALG_SESSION_KEY）—— 由 SDK 在 KMS 返回的 65 字节前拼上
  · 第 1..65 字节 = 标准 secp256k1 ECDSA 签名 r‖s‖v

被签哈希 = toEthSignedMessageHash(userOpHash)
         = keccak256("\x19Ethereum Signed Message:\n32" ‖ userOpHash)   // EIP-191 前缀
  ⚠️ KMS 要签的是【以太坊前缀哈希】，不是裸 userOpHash（eth_sign 语义）
  ⚠️ V 必须是 27/28（不是 0/1）—— 多数库默认 0/1，需归一化，否则 ecrecover 取错地址
```

- 合约侧：`recover(sig[1:66])` → 得到地址 → 查 `agentSessions[userOp.sender][recovered]`。
- **签名内不含账户地址**；跨账户隔离靠 `agentSessions[sender][recovered]` 二维映射。KMS 只需返回纯 65 字节签名，SDK 负责拼 `0x08` 前缀。
- KMS `/kms/sign-agent`（§1）返回的 65 字节即此处的 `R‖S‖V`。

### B. nonce-key 路由（SDK 构造 UserOp 时必须）

```
userOp.nonce 的高 192 位 key 的低 160 位 = AgentSessionKeyValidator 合约地址
即：nonce = (uint256(uint160(validatorAddr)) << 64) | sequence
```

账户 `validateUserOp` 据此把该 UserOp 路由到 `AgentSessionKeyValidator`（否则走内置 owner 验签）。**SDK 不这样拼 nonce，验证器根本不会被调用。**

### C. 上链授权接口（SDK 调用，需账户 owner 经 UserOp 发起）

```solidity
// 仅账户自身可调（msg.sender = 账户），即 owner 签名的 UserOp → execute → 此调用
function grantAgentSession(address sessionKey, AgentSessionConfig cfg);
function revokeAgentSession(address sessionKey);                 // 即时吊销

struct AgentSessionConfig {
    uint48    expiry;            // 必填，到期时间（必须 > now）
    uint16    velocityLimit;     // 每窗口最多调用次数（0 = 不限）
    uint32    velocityWindow;    // 窗口秒数（velocityLimit>0 时必须 >0）
    bool      revoked;
    address[] callTargets;       // 允许的目标合约（空 = 全允许），最多 20
    bytes4[]  selectorAllowlist; // 允许的函数选择器（空 = 全允许），最多 30
}
```

### D. 模块安装（取决于账户类型 —— 见 agent-account-architecture.md 的安装策略）

`AgentSessionKeyValidator` 是**独立的 ERC-7579 validator 模块合约**（非主账户、非 diamond-lite 扩展）。需通过 `installModule(typeId=1, validatorAddr, initData)` 登记到账户后才会被 nonce-key 路由命中。**安装本身惰性**（不授予任何权限；权限只来自 owner 授权的 `grantAgentSession`）。
- **自主型 agent 账户**（`createAgentAccount`）：建议**工厂默认安装**（零摩擦）。
- **普通人类账户**（要做助理型）：**opt-in 安装**（`installModule` 需 guardian 阈值签名）。
- （安装策略最终值见 issue/决策 #17。）

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
  "credentialExpiry": "ISO8601"   // credential 过期时间（默认 3 天，可续期）
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

### 3.2 Credential 格式（JWT HS256）

```
Header: { "alg": "HS256", "typ": "JWT", "kid": "<secretVersion>" }   // kid = kms_secret 版本号（轮换用）
Payload: {
  "sub":     "<keyId>",           // 对应的 KMS keyId（per-agent 绑定）
  "iss":     "kms.airaccount",    // 颁发者
  "aud":     "kms.sign-agent",    // 受众
  "iat":     <unix_timestamp>,
  "exp":     <unix_timestamp>,    // 颁发时间 + 3 天
  "humanAccount": "0x...",        // 绑定的人类账户地址（用于审计）
  "agentId":      "bytes32_hex"   // 绑定的链上 agentId
}
Signature: HMAC-SHA256(header.payload, kms_secret[kid])
```

**关于 `kms_secret`（务必理解，避免混淆）：**
- HMAC（HS256）是**对称**的——**没有公钥/私钥之分**。同一把 `kms_secret` **既签发又验证** JWT，只存在 KMS（TEE）内一份，永不导出。
- **这是“钥匙 B”，与“钥匙 A（agent 的 secp256k1 签名 EOA）”是两把不同的钥匙**：钥匙 A 签 UserOp（每 agent 一把，HD 派生或新建）；钥匙 B 签 JWT 凭证本身（默认全局一把）。
- **JWT 的授权范围是 per-agent**（payload 的 `keyId` + KMS 的 keyId↔credential 绑定校验 → 一张 JWT 只能让 KMS 用“它绑定的那个 agent 的钥匙 A”签名，碰不到别的 agent）。
- **单点风险 + 链上兜底**：若 `kms_secret` 泄露，可伪造任意 agent 的 JWT；但被签出的 UserOp 仍受**链上 session 约束（callTargets/spendCap/expiry）+ 人类 `revokeAgentSession` 即时止血**限制 → 损失有界。**资金安全锚在合约，KMS 凭证只是 API 访问层。**

### 3.3 Credential 生命周期（默认 3 天，单次可见）

```
人类 WebAuthn 认证
  → POST /kms/create-agent-key
  ← agentCredential (JWT, 默认 3 天有效；明文只返回一次，KMS 只存哈希 = 单次可见)

  [Agent 运行时]
  → POST /kms/sign-agent (Bearer JWT)
  ← signature   // 重发新 JWT 时 agent EOA 不变，只换这张 API 票

[到期前]
  → POST /kms/refresh-agent-credential (需原 credential + 人类 WebAuthn 重新授权)
  ← new_credential   // 同一个 agent EOA，发新 JWT；不新建 session key，不换 EOA

[撤销]
  → POST /kms/revoke-agent-credential (人类 WebAuthn 授权)
  ← 204；旧 credential 的请求立即 401
```

> **三层独立、勿混**：① agent EOA（链上身份，常态不变，仅疑似泄露/主动轮换时换）；② 链上 session 授权（grantAgentSession，到期人类重 grant，**同一 EOA**）；③ JWT 凭证（API 票，3 天到期 refresh，**仍指同一 EOA**）。JWT 续期 ≠ 重建 session key ≠ 换 EOA。

### 3.5 `kms_secret` 轮换（自动 + 重叠窗口 —— 安全可管理）

需求：`kms_secret` 不能“一把用到底永不换”。机制 = **kid 版本 + 重叠窗口**：

```
· 每把 kms_secret 带版本号 kid（v1, v2 …），JWT 头携带签发时所用的 kid。
· 签发：永远用“当前最新”那把（current kid）。
· 验证：按 JWT 头的 kid 选对应 secret 验；接受所有“未退役”的版本。

[自动轮换，建议每 30 天一次，KMS 内定时任务，全程 TEE 内]
  T0  生成新 secret（新 kid）→ 立即成为 current（此后新 JWT 用它签）
      旧 secret 保留“只验不签”一段【重叠窗口】= ≥ JWT 最长有效期(3 天)，建议留 7 天
  T0+重叠窗口  退役删除旧 secret
  → 轮换不会误杀轮换前签出、尚未过期的 JWT；任意时刻最多 2 把 secret 并存（1 签 + 1 仅验）

[紧急轮换] 另提供 admin 接口：疑似泄露时立即生成新 kid、并可强制缩短旧 kid 重叠窗口。
```

要求：① `kms_secret`（所有版本）永不出 TEE；② 默认初始化时创建第一把（v1）；③ 自动轮换周期与重叠窗口可配置（默认 30d / 7d）；④ admin 紧急轮换接口需最高权限鉴权 + 审计。

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
| `kms_secret` 仅存 TEE + kid 轮换 | P0 | JWT 签名密钥永不出 TEE；自动轮换(默认30d)+重叠窗口(≥3d,建议7d)+admin紧急轮换（见 §3.5） |
| `kms_secret` 单点泄露由链上兜底 | P0 | 即便泄露，签出的 UserOp 仍受链上 session 约束 + 人类即时 revoke 限制（资金锚在合约） |

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
| credential 格式 | **已定：JWT HS256 + kid 轮换** | — |
| credential 有效期 | **已定：默认 3 天** | — |
| `kms_secret` 轮换周期 / 重叠窗口 | **已定：默认 30 天 / ≥3 天(建议7天)**，数值可配置 | KMS 团队确认可行性 |
| agentKey 派生 | **默认 HD 派生(m/44'/60'/0'/1/x)，可新建** | KMS 团队 |
| KMS 是否已有 TRNG 硬件熵端点 | 待确认 | KMS 团队 |
| 速率限制阈值（次/分钟） | 待确认（建议默认值） | KMS 团队 |
| 签名审计日志保存时长 | 待确认 | KMS 团队 |

---

*关联文档：[agent-account-architecture.md](agent-account-architecture.md) §2 §4 · [agent-autonomous-flow.md](agent-autonomous-flow.md)*
