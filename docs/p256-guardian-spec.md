# P-256 Guardian 技术规格

**Issue**: airaccount-contract #119 / AirAccount #102  
**版本**: v0.20.0（已发布，Sepolia 部署 + 链上 P-256 recovery E2E 通过）  
**状态**: 实现完成，**844 tests, 0 failed**

> ⚠️ **以已发布的 v0.20.0 ABI + 合约实现为准。** 早期版本的本文档把验证路径写成"简化 WebAuthn
> 路径（不验 authenticatorData、sig = 64 字节 r‖s）"——那是**设计草稿，不是实现**。实际发布的合约
> 做的是**完整 WebAuthn Assertion 验证**：sig 是 ABI 编码的 assertion blob，且强制
> `clientDataJSONPrefix == '{"type":"webauthn.get","challenge":"'`。下文 §2、§5、§6 已对齐实现。
> 权威来源：`src/core/AirAccountExtension.sol::_verifyWebAuthnP256Sig` + `abi/AAStarAirAccountV7.full.json`。

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

### 2.1 签名验证路径（完整 WebAuthn Assertion）

实现做的是**完整 WebAuthn Assertion 验证**，与 `navigator.credentials.get()` 实际返回的数据结构逐字节一致：

```
客户端（passkey authenticator）:
  challenge = keccak_hash（合约派生的 32 字节，见 §2.2）
  navigator.credentials.get({ publicKey: { challenge, ... } })
  → 返回 authenticatorData、clientDataJSON、ES256 签名 (r, s)
  authenticator 内部对  authenticatorData || SHA256(clientDataJSON)  做 ECDSA-SHA-256 签名

合约验证（AirAccountExtension._verifyWebAuthnP256Sig）:
  1. abi.decode(sig) → (authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
  2. require authenticatorData.length >= 37  且  UP flag 置位: authenticatorData[32] & 0x01 != 0
  3. require clientDataJSONPrefix == '{"type":"webauthn.get","challenge":"'   ← 操作类型绑定
  4. clientDataJSON = clientDataJSONPrefix || base64url(challenge) || clientDataJSONSuffix
  5. payloadHash = sha256(authenticatorData || sha256(clientDataJSON))
  6. require uint256(s) <= SECP256R1_N_OVER_2   ← 低-S
  7. EIP-7212 precompile(0x100): abi.encode(payloadHash, r, s, x, y) 返回 1
```

**绑定 / 不绑定**（详见 §9.5）：
- **绑定**：P-256 曲线签名正确性、操作 `type`（`webauthn.get` 前缀严格匹配，防 `webauthn.create` 混淆）、`challenge` 域隔离（`chainId + account + nonce + 目标`）、UP flag。
- **不绑定**：`origin` / `rpIdHash`（平台层已强制 RP 绑定 + challenge 域隔离已覆盖重放面；与 webauthn-sol / Coinbase Smart Wallet 取舍一致）、UV flag（兼容仅 UP 的 authenticator）。

### 2.2 哈希结构

```solidity
// challenge：即 WebAuthn challenge（嵌入 clientDataJSON 并被签名覆盖）
bytes32 challenge = keccak256(abi.encode(
    GUARDIAN_SIG_VERSION,  // 当前 = 4 (uint8)
    block.chainid,
    address(this),
    "P256_GUARDIAN",       // 域分隔符，防止与 ECDSA guardian hash 混淆
    opLabel,               // "PROPOSE_RECOVERY" / "APPROVE_RECOVERY" / "REMOVE_GUARDIAN" / ...
    opData                 // 见 §6（按操作不同）
));

// clientDataJSON 由 prefix/suffix 包裹 base64url(challenge)，prefix 被合约强制为固定串：
//   clientDataJSON = '{"type":"webauthn.get","challenge":"' || base64url(challenge) || suffix
// 合约传给 P-256 precompile 的 payloadHash 就是 WebAuthn assertion 实际签名的内容：
bytes32 payloadHash = sha256(abi.encodePacked(authenticatorData, sha256(clientDataJSON)));
```

> 注：`base64url(challenge)` 是 32 字节定长 base64url（43 字符，无 padding），由合约的
> `_base64UrlEncode32` 在链上重建——SDK 拆 prefix/suffix 时必须让 challenge 紧跟在 prefix 之后。

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
/// @notice P-256 guardian 提议恢复（任何 relayer 可提交预签名 calldata）
/// @param newOwner  目标 owner 地址
/// @param gIdx      guardian slot 索引（0/1/2）
/// @param sig       WebAuthn assertion blob（低-S）:
///                  abi.encode(bytes authenticatorData, bytes clientDataJSONPrefix,
///                             bytes clientDataJSONSuffix, bytes32 r, bytes32 s)
function proposeRecoveryWithSig(address newOwner, uint8 gIdx, bytes calldata sig) external;

/// @notice P-256 guardian 批准已有恢复提案
/// @param gIdx  guardian slot 索引
/// @param sig   WebAuthn assertion blob（同上）
function approveRecoveryWithSig(uint8 gIdx, bytes calldata sig) external;

/// @notice P-256 guardian 取消已有恢复提案
/// @param gIdx  guardian slot 索引
/// @param sig   WebAuthn assertion blob（同上）
function cancelRecoveryWithSig(uint8 gIdx, bytes calldata sig) external;
```

### 5.3 混合签名管理接口

```solidity
/// @notice 混合签名修改 tier 限额（同时支持 ECDSA 和 P-256 guardian 签名）
/// @param signerIdxs  每个签名对应的 guardian slot 索引
/// @param guardianSigs ECDSA guardian: 65 字节 (r||s||v) eth-signed；
///                     P-256 guardian: WebAuthn assertion blob
///                     abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
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

challenge = keccak256(
    GUARDIAN_SIG_VERSION = 4,   // uint8
    chainId,                     // uint256
    accountAddress,              // address
    "P256_GUARDIAN",             // string domain tag
    opLabel,                     // string
    abi.encode(_recoveryNonce, newOwner)  // bytes opData
)

guardian 签名（完整 WebAuthn assertion）:
    navigator.credentials.get({publicKey: {challenge: <challenge 的 32 字节>, ...}})
    → 返回 authenticatorData + clientDataJSON + ES256 sig(r, s)
    其中 clientDataJSON 形如 '{"type":"webauthn.get","challenge":"' || base64url(challenge) || '",...}'
    实际被签内容（= 合约传给 EIP-7212 的 payloadHash）:
        payloadHash = SHA256(authenticatorData || SHA256(clientDataJSON))

提交给合约的 sig（SDK 组装）:
    sig = abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s)
    约束: clientDataJSONPrefix 必须严格等于 '{"type":"webauthn.get","challenge":"'
          challenge 必须紧跟其后；s 必须低-S（s <= n/2）
```

### 6.2 取消恢复

```
challenge = keccak256(
    GUARDIAN_SIG_VERSION = 4,
    chainId,
    accountAddress,
    "P256_GUARDIAN",
    "CANCEL_RECOVERY",
    abi.encode(_recoveryNonce, activeRecovery.newOwner)
)
// guardian 签名 + sig 组装：完整 WebAuthn assertion blob，同 §6.1
```

### 6.3 修改 Tier 限额

```
challenge = keccak256(
    GUARDIAN_SIG_VERSION = 4,
    chainId,
    accountAddress,
    "P256_GUARDIAN",
    "MODIFY_TIER_LIMITS",
    abi.encode(_tierLimitNonce, tier1, tier2, deadline)
)
// guardian 签名 + sig 组装：完整 WebAuthn assertion blob，同 §6.1
```

### 6.4 移除 Guardian（REMOVE_GUARDIAN）

> #120 final-review [HIGH] 后变更：opData 现在绑定 **slot index + P-256 公钥**。因为 P-256 guardian
> 在地址槽共用 sentinel `0x7026`，旧的 `abi.encode(nonce, guardianToRemove)` 对每个 P-256 槽都相同，
> 一个"移除槽 A"的签名可被重放去移除槽 B。新 payload 绑定具体槽与公钥，杜绝跨槽重放。

```
opLabel = "REMOVE_GUARDIAN"
opData = abi.encode(
    _guardianRemovalNonce,  // uint256
    index,                  // uint8   被移除的 slot
    guardianToRemove,       // address 该槽的 guardian 地址（P-256 槽为 sentinel 0x7026）
    p256X,                  // bytes32 该槽的 P-256 x（ECDSA 槽为 0）
    p256Y                   // bytes32 该槽的 P-256 y（ECDSA 槽为 0）
)
challenge = keccak256(GUARDIAN_SIG_VERSION=4, chainId, accountAddress, "P256_GUARDIAN", opLabel, opData)
// 每个 signer（混合 ECDSA / P-256）对该 challenge 签名：
//   ECDSA signer → 65 字节 eth-signed sig
//   P-256 signer → WebAuthn assertion blob（同 §6.1）
```

> `addGuardianWithMixedSigs` / `addP256GuardianWithMixedSigs` 的 opData 为
> `abi.encode(_guardianAdditionNonce, guardian或x,y)`，opLabel 分别为 `"ADD_GUARDIAN"` /
> `"ADD_P256_GUARDIAN"`（域分隔，防跨函数重放）。

---

## 7. Gas 成本参考

| 操作 | Gas | 备注 |
|------|----------|------|
| `addP256Guardian` | ~75,000 | 3× SSTORE new(sentinel+x+y) |
| `addGuardian` (ECDSA，现有) | ~50,000 | 1× SSTORE new |
| `proposeRecoveryWithSig` | **150,831**（Sepolia 实测）| 完整 WebAuthn：base64url 重建 + sha256×2 + EIP-7212 + activeRecovery init |
| `approveRecoveryWithSig` | **84,559**（Sepolia 实测）| 完整 WebAuthn 验证 + bitmap update |
| `cancelRecoveryWithSig` | ~85,000（估，同 approve 路径）| 完整 WebAuthn 验证 + cancel bitmap |
| `executeRecovery` (现有) | ~45,000 | owner update+delete+nonce++ |
| `removeGuardianWithMixedSigs` | ~95,000+ | N× sig verify + storage shift |

*P256VERIFY precompile @ 0x100: ~6,900 gas（L1 EIP-7951 指定值；OP-Stack RIP-7212 为 3,450）；sha256 precompile: ~200 gas。propose/approve 为
v0.20 Sepolia 链上实测（见 `docs/tx-archive/v0.20.0.md`）——比早期"简化路径"预估高，因为完整 WebAuthn
要在链上 base64url 重建 clientDataJSON 并做两次 sha256。*

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
- **ERC-7579 模块治理的 P-256 授权** → 已知限制，后续 issue。`installModule` / `proposeModuleInstall` / `setModuleInstallTimelock` 等需 guardian-consensus 的模块治理路径目前仅接受 65 字节 ECDSA guardian 签名（`_checkGuardianSigs`）。**纯 P-256 guardian 集**无法授权这些操作（社交恢复、guardian 增删、tier 限额修改均已全面支持 P-256，不受影响；owner-only 与低 threshold 的模块路径也不受影响）。后续将像 recovery 一样为模块治理增加混合签名分发。
- KMS 侧代码变更 → 无需（见 AirAccount #102 结论）

---

## 10. 关联

- **合约实现（本 issue）**: airaccount-contract #119
- **KMS 架构说明**: AirAccount #102（结论：KMS 无需代码变更）
- **SDK 更新通知**: aastar-sdk（待发 issue）
- **YAA 独立性主线**: YetAnotherAA #311
