# P-256 Guardian 技术规格

**Issue**: airaccount-contract #119 / AirAccount #102  
**版本**: v0.20.0-beta  
**状态**: 实现完成，测试通过（828 tests, 0 failed）

---

## 1. 背景与问题

### 1.1 现状

账户主签名已是 P-256（passkey），但 guardian 槽位只支持 secp256k1 EOA（`address`）。当普通用户想用 passkey 做 guardian 时，被迫走：

```
passkey(P-256) → 授权 KMS → KMS 用托管 secp256k1 私钥签名 → 链上 ecrecover
```

这将 KMS 引入了 guardian 信任链路，形成三类单点风险：
1. **可用性**：KMS 宕机 → guardian 签不出 → 社交恢复瘫痪
2. **持久性**：KMS 下线/密钥丢失 → passkey 无法重建 secp256k1 私钥（不同曲线）
3. **安全性**：KMS 作恶 → 可替 guardian 签恶意恢复，把 owner 改成攻击者

### 1.2 目标

Guardian 槽位支持 P-256 类型，让 passkey 本身就是钥匙：
- Guardian 密钥存在 iCloud / Google 账户，随设备同步
- 签名在本地完成，KMS 不再在 guardian 签名链路里
- 兼容现有 ECDSA guardian（不破坏任何已有账户）

---

## 2. 技术选型

### 2.1 签名验证路径

本实现选用 **简化 WebAuthn 路径**（不含 authenticatorData 验证）：

```
客户端签名:
  challenge = SHA256(keccak256_op_hash_bytes)   ← subtle.crypto.sign 内部执行
  sig = P256.sign(challenge)   via navigator.credentials.get() + WebAuthn API

合约验证:
  sha256_hash = sha256(keccak_op_hash)           ← 调用 sha256 precompile(0x02)
  P256_VERIFIER(sha256_hash, r, s, x, y)         ← EIP-7212 precompile(0x100)
```

**为什么选这条路而不是裸 keccak 传 precompile：**
- WebAuthn passkey 私钥由 OS/硬件保护，无法导出，只能通过 `navigator.credentials.get()` 调用，该 API 内部强制使用 ECDSA-SHA-256（即对消息 SHA-256 后再 P-256 签名）
- 直接传裸 keccak 给 precompile 要求客户端有"裸 P-256 签名"能力，passkey 不支持
- 本路径与 ERC-4337 生态（Coinbase Smart Wallet、Kernel v3）主流实践一致

**为什么不做完整 WebAuthn Assertion 验证（含 authenticatorData）：**
- 合约无法 enforce `rpId`（不知道前端域名），验证 authenticatorData 增加 ~5,000 gas 且无安全增益
- `challenge` 绑定已足够：`chainId + account + nonce + newOwner` 覆盖所有重放攻击面
- 简化实现仍保留 P-256 曲线安全属性，仅放弃 rpId 绑定这一层（应用层 SDK 负责）

### 2.2 哈希结构

```solidity
// keccak 层：绑定版本、链、账户、操作标签
bytes32 keccak_hash = keccak256(abi.encode(
    GUARDIAN_SIG_VERSION,  // 当前 = 4
    block.chainid,
    address(this),
    "P256_GUARDIAN",       // 域分隔符，防止与 ECDSA guardian hash 混淆
    opLabel,               // "PROPOSE_RECOVERY" / "APPROVE_RECOVERY" / etc.
    opData                 // abi.encode(_recoveryNonce, newOwner, ...)
));

// sha256 层：适配 WebAuthn 签名（subtle.crypto.sign 内部哈希）
bytes32 verify_hash = sha256(abi.encodePacked(keccak_hash));

// 合约传给 P256 precompile 的是 verify_hash
```

### 2.3 Guardian 类型编码

```
槽位中存储值 = P256_GUARDIAN_SENTINEL (address(0x7026))
  → 表示这个 slot 是 P-256 类型
  → 配套 (x, y) 存在平行存储变量
  
槽位中存储值 = 普通 EOA address
  → 表示这个 slot 是 ECDSA 类型（现有行为）
```

`0x7026` 的选择：
- 不是有效的 EOA（无已知私钥）
- 不是 `address(0)` / `address(1)` 等系统地址
- 字面含义：`0x7026 ≈ P026 → P-256`（可读）

---

## 3. 存储布局

### 3.1 新增 storage slots（接在现有 slot 29 之后）

```
slot 30  _guardianP256X0   ← guardian[0] 的 P-256 x 坐标
slot 31  _guardianP256Y0   ← guardian[0] 的 P-256 y 坐标
slot 32  _guardianP256X1
slot 33  _guardianP256Y1
slot 34  _guardianP256X2
slot 35  _guardianP256Y2
slot 36  _recoveryNonce    ← 防重放：每轮恢复结束自增
```

新增位置：`AAStarAgentStorageLayout.sol`，append-only（不重排任何现有 slot）。

### 3.2 `_recoveryNonce` 详解

**问题**：P-256 guardian 签名是链下产生、任意人可提交。如无 nonce：
```
轮 1: guardian1 签批准(newOwner=Alice)
轮 1 被 cancel 后:
轮 2 (攻击者提议 newOwner=Eve):
    攻击者重放轮 1 的签名 → bit1 自动被置
    只需再凑 1 个 guardian → 成功篡改 owner
```

**解决**：`opData` 包含 `_recoveryNonce`，cancel/execute 后 nonce 自增，旧签名失效。

**ECDSA guardian 无此问题原因**：ECDSA guardian 直接发 Ethereum tx（`msg.sender` 鉴权 + tx nonce 防重放），无链下签名。

---

## 4. 守卫数量与阈值

### 4.1 本次版本（v0.20）

保持 **2-of-3** 阈值，最多 3 个 guardian slot。可混用类型：
```
slot 0: ECDSA guardian (MetaMask)
slot 1: P-256 guardian (iPhone passkey)
slot 2: P-256 guardian (Google passkey)
→ 任意 2 of 3 批准即可触发恢复
```

### 4.2 后续扩展（独立 issue）

M-of-N (e.g. 3-of-5) 作为独立特性，需要：
- 扩展 guardian slot 数量（当前硬编码为 3）
- 可配置阈值 `_recoveryThreshold`
- 对应 EIP-170 headroom 和 gas 成本重新评估

---

## 5. 新增接口

### 5.1 Owner 管理接口（放在 AirAccountExtension，via fallback delegatecall）

```solidity
/// @notice 添加 P-256 类型 guardian
/// @param x P-256 公钥 x 坐标（uncompressed，secp256r1）
/// @param y P-256 公钥 y 坐标
/// @dev x/y 从 WebAuthn 注册返回的 getPublicKey() 提取
function addP256Guardian(bytes32 x, bytes32 y) external onlyOwner;

/// @notice 获取 guardian slot 的 P-256 公钥（slot 非 P-256 类型则返回 (0,0)）
function getGuardianP256Key(uint8 index) external view returns (bytes32 x, bytes32 y);
```

### 5.2 Social Recovery 接口（P-256 guardian 专用）

```solidity
/// @notice P-256 guardian 提议恢复
/// @param newOwner  目标 owner 地址
/// @param gIdx      guardian slot 索引（0/1/2）
/// @param sig       64 字节 P-256 签名 (r||s)，含低-S 规范化
function proposeRecoveryWithSig(address newOwner, uint8 gIdx, bytes calldata sig) external;

/// @notice P-256 guardian 批准已有恢复提案
/// @param gIdx  guardian slot 索引
/// @param sig   64 字节 P-256 签名
function approveRecoveryWithSig(uint8 gIdx, bytes calldata sig) external;

/// @notice P-256 guardian 取消已有恢复提案
/// @param gIdx  guardian slot 索引
/// @param sig   64 字节 P-256 签名
function cancelRecoveryWithSig(uint8 gIdx, bytes calldata sig) external;
```

### 5.3 混合签名管理接口

```solidity
/// @notice 混合签名修改 tier 限额（同时支持 ECDSA 和 P-256 guardian 签名）
/// @param signerIdxs  每个签名对应的 guardian slot 索引
/// @param guardianSigs ECDSA guardian: 65 字节 (r||s||v)；P-256 guardian: 64 字节 (r||s)
function modifyTierLimitsWithMixedGuardians(
    uint256 tier1, uint256 tier2, uint256 deadline,
    uint8[] calldata signerIdxs,
    bytes[] calldata guardianSigs
) external onlyOwner;

/// @notice 混合签名移除 guardian
function removeGuardianWithMixedSigs(
    uint8 index,
    uint8[] calldata signerIdxs,
    bytes[] calldata guardianSigs
) external;
```

### 5.4 对 AAStarAirAccountBase 的最小改动

```solidity
// 新增常量
address internal constant P256_GUARDIAN_SENTINEL = address(0x7026);

// 新增 errors
error InvalidP256GuardianKey();
error DuplicateP256GuardianKey();
error InvalidP256GuardianSignature(uint8 gIdx);

// 新增 event
event P256GuardianAdded(uint8 indexed index, bytes32 x, bytes32 y);

// addGuardian() 增加一行检查
if (g == P256_GUARDIAN_SENTINEL) revert InvalidGuardian();

// executeRecovery() 末尾增加
_recoveryNonce++;

// cancelRecovery() 取消成功分支增加
_recoveryNonce++;
```

---

## 6. 签名哈希规格（SDK 对接标准）

### 6.1 提议/批准恢复

```
opLabel = "PROPOSE_RECOVERY"  （提议）
opLabel = "APPROVE_RECOVERY"  （批准）

keccak_hash = keccak256(
    GUARDIAN_SIG_VERSION = 4,   // uint8
    chainId,                     // uint256
    accountAddress,              // address
    "P256_GUARDIAN",             // string domain tag
    opLabel,                     // string
    abi.encode(_recoveryNonce, newOwner)  // bytes
)

verify_hash = SHA256(keccak_hash)   // 32 bytes

guardian 签名:
    navigator.credentials.get({publicKey: {challenge: keccak_hash_bytes, ...}})
    → 返回 authenticatorData + clientDataJSON + sig(r, s)
    注意: clientDataJSON.challenge = base64url(keccak_hash_bytes)
    实际被签内容: SHA256(authenticatorData || SHA256(clientDataJSON))
    
    简化场景（不含 authenticatorData 验证）:
    verify_hash ≈ SHA256(keccak_hash_bytes) [近似，SDK 需与合约对齐]
```

### 6.2 取消恢复

```
keccak_hash = keccak256(
    GUARDIAN_SIG_VERSION = 4,
    chainId,
    accountAddress,
    "P256_GUARDIAN",
    "CANCEL_RECOVERY",
    abi.encode(_recoveryNonce, activeRecovery.newOwner)
)
verify_hash = SHA256(keccak_hash)
```

### 6.3 修改 Tier 限额

```
keccak_hash = keccak256(
    GUARDIAN_SIG_VERSION = 4,
    chainId,
    accountAddress,
    "P256_GUARDIAN",
    "MODIFY_TIER_LIMITS",
    abi.encode(_tierLimitNonce, tier1, tier2, deadline)
)
verify_hash = SHA256(keccak_hash)
```

---

## 7. Gas 成本参考

| 操作 | 预估 Gas | 备注 |
|------|----------|------|
| `addP256Guardian` | ~75,000 | 3× SSTORE new(sentinel+x+y) |
| `addGuardian` (ECDSA，现有) | ~50,000 | 1× SSTORE new |
| `proposeRecoveryWithSig` | ~110,000 | sha256+P256验证+activeRecovery init |
| `approveRecoveryWithSig` | ~32,000 | sha256+P256验证+bitmap update |
| `cancelRecoveryWithSig` | ~32,000 | sha256+P256验证+bitmap update |
| `executeRecovery` (现有) | ~45,000 | owner update+delete+nonce++ |
| `removeGuardianWithMixedSigs` | ~95,000 | 2× sig verify + storage shift |
| **完整恢复（提议+批准+执行）** | **~187,000** | 3 笔 tx 合计 |

*sha256 precompile: ~200 gas；P256 precompile: ~3,450 gas（EIP-7212 指定值）*

Sepolia / L2（5 gwei）：完整恢复 ~$0.05-0.2  
Ethereum mainnet（20 gwei，$3500/ETH）：完整恢复 ~$10-15

---

## 8. 兼容性

- **现有 ECDSA guardian** 不受影响：`proposeRecovery / approveRecovery / cancelRecovery / modifyTierLimitsWithGuardians / removeGuardian` 全部保留，行为不变
- **混用场景**：同一账户可以 1 ECDSA + 2 P-256，或 3 P-256，任意组合，2-of-3 阈值不变
- **EIP-170**：所有新函数在 `AirAccountExtension`（当前 headroom ~12,275 字节）；主合约新增 ~80 字节

---

## 9. 初始化时设置 guardian（init-time）

`InitConfig` 已扩展，支持账户创建时同时设置 P-256 guardian（1 笔 tx 完成，无空窗期）：

```solidity
struct InitConfig {
    address[3] guardians;        // ECDSA guardian（address(0) = 空槽）
    bytes32[3] guardianP256X;    // P-256 guardian x 坐标（非零 iff 对应 guardians[i] == address(0)）
    bytes32[3] guardianP256Y;    // P-256 guardian y 坐标
    ...
}
```

**推荐初始化流程（SDK 引导）：**
- 用户用手机 Face ID 注册 passkey A → `owner` 主签名密钥
- 引导注册 passkey B（iCloud Keychain）→ `guardianP256X/Y[0]`
- 引导注册 passkey C（Google Passkey）→ `guardianP256X/Y[1]`
- 一次 `factory.createAccount(owner, config)` 完成所有设置
- Guardian 可以是任意类型（ECDSA MetaMask / Apple passkey / Google passkey），用户自选

## 9.5 签名验证范围与威胁模型（on-chain verification scope）

合约在链上验证 WebAuthn assertion 时，**绑定**以下内容、**不绑定** origin/rpId：

**绑定（on-chain enforced）**
- **签名正确性**：P-256（secp256r1）验证 `sha256(authenticatorData || sha256(clientDataJSON))`，公钥为注册时存储的 `(x, y)`。
- **operation type**：`clientDataJSONPrefix` 必须严格等于 `{"type":"webauthn.get","challenge":"`。这关闭了 type 混淆（`webauthn.create` 注册断言被当作 `webauthn.get` 恢复断言重放）以及任意 JSON prefix 滥用。所有主流平台 authenticator（iOS/macOS Safari、Android/Chrome、Windows Hello）的 assertion 都是 `type` 在前、`challenge` 紧随其后的紧凑格式。
- **challenge 域隔离**：challenge = `keccak256(abi.encode(version, chainId, address(this), "P256_GUARDIAN", opLabel, opData))`，其中 `opData` 含 `_recoveryNonce` + `newOwner`。因此签名绑定到特定链、特定账户、特定 recovery 轮次与目标 owner，无法跨账户/跨轮重放。
- **UP flag**：`authenticatorData[32] & 0x01` 必须置位（User Present）。

**不绑定（链下/平台层职责，刻意为之）**
- **origin / rpIdHash**：不在链上校验。理由：(1) **平台层已强制 RP 绑定** —— 为 `airaccount` 的 rpId 注册的 passkey，浏览器/OS 只会在该 rpId 对应的 origin 下用它签名，钓鱼站无法调出该 passkey；(2) challenge 已做域隔离，签名无法被挪用到其他账户/操作；(3) 社交恢复还有 2-of-3 consensus + 2 天 timelock + cancel 投票的深度防御。这与业界主流链上 WebAuthn 验证器（webauthn-sol / Coinbase Smart Wallet、Daimo）的取舍一致——它们同样不在链上校验 origin/rpId。
- **UV (User Verification / 生物识别) flag**：不强制，以兼容仅 UP 的 authenticator。

> 该取舍在 #120 的多轮对抗 review 中被显式评估并由维护者确认。合约不可升级，因此此处为最终决策。

## 10. 不在本次范围内

- M-of-N 阈值（N > 3）→ 独立 issue
- 链上 origin/rpIdHash 绑定 → 刻意不做（见 §9.5），依赖平台层 RP 绑定 + challenge 域隔离
- KMS 侧代码变更 → 无需（见 AirAccount #102 结论）

---

## 10. 关联

- **合约实现（本 issue）**: airaccount-contract #119
- **KMS 架构说明**: AirAccount #102（结论：KMS 无需代码变更）
- **SDK 更新通知**: aastar-sdk（待发 issue）
- **YAA 独立性主线**: YetAnotherAA #311
