# AirAccount v0.16.0 — 产品验收文档（M1–M7 完整版）

**版本**: v0.16.0（M7 正式版）
**更新日期**: 2026-03-21
**网络**: Sepolia 测试网（Chain ID: 11155111）
**测试数**: 622 单元测试全部通过 ✅
**编译器**: Solidity 0.8.33，Cancun EVM，via-IR，optimizer_runs=10,000

---

## 目录

1. [产品定位与价值主张](#1-产品定位与价值主张)
2. [M1–M7 里程碑 Feature 完整清单](#2-m1m7-里程碑-feature-完整清单)
3. [用户旅程模拟（Product Manager 视角）](#3-用户旅程模拟)
4. [前端集成指南（开发者视角）](#4-前端集成指南)
5. [已部署合约地址（Sepolia）](#5-已部署合约地址)
6. [Validator / Keeper / Bundler 集成依赖](#6-validator--keeper--bundler-集成依赖)
7. [已知限制与风险分析](#7-已知限制与风险分析)
8. [极端情况处理手册](#8-极端情况处理手册)
9. [安全摘要](#9-安全摘要)
10. [待办事项（TODO List）](#10-待办事项)

---

## 1. 产品定位与价值主张

### 1.1 一句话描述

> AirAccount 是面向大众用户的**非可升级、隐私优先、多重签名 ERC-4337 智能钱包**——手机指纹完成小额付款，AI 代理自动执行 DeFi，Guardian 守护大额资产，零 ETH 余额即可使用。

### 1.2 核心差异点

| 对比维度 | 传统 EOA（MetaMask） | Safe 多签 | AirAccount M7 |
|---------|-------------------|---------|--------------|
| 私钥丢失 | 资产永久丢失 | — | 社交恢复，2-of-3 Guardian + 2天时间锁 |
| 签名复杂度 | 单一私钥 | N-of-M | **分级自动**：金额决定签名强度 |
| Gas 费用 | 需要 ETH | 需要 ETH | **零 ETH**，aPNTs 代付 |
| 手机友好 | 差（助记词） | 差 | **Passkey/FaceID 硬件级** |
| DeFi 保护 | 无 | 无 | **智能限额**：Tier 1/2/3 + 日限额 |
| AI 代理 | 不支持 | 不支持 | **AgentSessionKey** 速率/范围限制 |
| 隐私 | 无 | 无 | **Railgun 集成** + Stealth Address |
| 升级 | 随时 | 多签升级 | **非可升级**，代码即法律 |

### 1.3 两种账户类型

| 类型 | 入口 | 适用用户 | 地址变化 | 安全模型 |
|------|------|---------|---------|---------|
| **AirAccountV7**（主路径） | App 新建 Passkey | 新用户、高价值用户 | 全新 CREATE2 地址 | EIP-1167 clone，无私钥 |
| **AirAccountDelegate**（过渡路径） | 已有 MetaMask 用户 | Web3 老用户 | 原 EOA 地址不变 | EIP-7702 委托，原私钥仍有效 |

> ⚠️ AirAccountDelegate 是**过渡路径**，功能约为主路径的 30%。高价值用户最终应迁移到 AirAccountV7。

---

## 2. M1–M7 里程碑 Feature 完整清单

### 2.1 主路径（AirAccountV7）功能矩阵

#### 签名与验证

| Feature | algId | 里程碑 | 状态 | 说明 |
|---------|:-----:|:------:|:----:|------|
| ECDSA 单签 | `0x02` | M1 | ✅ | `ecrecover`，EIP-2 malleability 修复，65 字节 |
| P256/WebAuthn Passkey | `0x03` | M2 | ✅ | EIP-7212 预编译（`0x100`），硬件绑定，无私钥 |
| BLS12-381 DVT 聚合签名 | `0x01` | M2 | ✅ | EIP-2537 预编译（Prague+），多节点分布式验证 |
| 累积 Tier 2（P256+BLS） | `0x04` | M4 | ✅ | P256 ∩ BLS 双因子叠加 |
| 累积 Tier 3（P256+BLS+Guardian） | `0x05` | M4 | ✅ | 三因子叠加，大额必用 |
| Combined T1（ECDSA+P256 零信任） | `0x06` | M5 | ✅ | 同时要求两类密钥，防单点妥协 |
| ALG_WEIGHTED 加权多签 | `0x07` | M6.1 | ✅ | bitmap 驱动，可配置权重+阈值 |
| Session Key（ECDSA / P256） | `0x08` | M6.4 | ✅ | DApp 服务端/Passkey 授权，作用域+时限限制 |
| AgentSessionKey（AI 代理） | `0x08`扩展 | M7 | ✅ | 速率限制+调用目标白名单+支出上限 |
| 子代理委托（delegateSession） | — | M7 | ✅ | Session Key 可向下委托，范围只能收窄 |

#### Guard（支出保护）

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| ETH 日限额 | M3 | ✅ | 每 UTC 日自动重置，不可绕过 |
| Tier 1/2/3 阈值检查 | M3 | ✅ | 金额决定签名强度，链上强制 |
| 算法白名单 | M3 | ✅ | 只有批准的 algId 可通过 Guard |
| 单调安全（只收紧） | M3 | ✅ | 日限额只降不升，算法只增不减 |
| ERC20 Token tier 检查 | M5 | ✅ | `transfer`/`approve` 自动解析金额 |
| DeFi Calldata 解析（Uniswap V3） | M6.6b | ✅ | swap 金额链上识别，防绕过 |
| Railgun 隐私池限额检查 | M7 | ✅ | Railgun V3 deposit 解析，Guard 联动 |
| TierGuardHook（ERC-7579 集成） | M7 | ✅ | Guard 逻辑提取为可安装 Hook 模块 |

#### Guardian 与社交恢复

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| 社交恢复（2-of-3，2天时间锁） | M4 | ✅ | Owner 不能取消（防私钥被盗） |
| Guardian 接受签名验证 | M5 | ✅ | 部署时链上验证 Guardian 同意（域隔离） |
| Guardian 轮换治理 | M6.2 | ✅ | 降低安全设置需 Guardian 投票+时间锁 |
| Packed Guardian Storage | M6 | ✅ | 3 个 Guardian 存于 1 个 bytes32 slot，节省 gas |

#### ERC-7579 模块系统

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| `installModule` / `uninstallModule` | M7 | ✅ | Guardian 阈值门控，防单点妥协 |
| `executeFromExecutor` | M7 | ✅ | 已安装的 Executor 模块可调用账户执行 |
| TierGuardHook（Hook 模块） | M7 | ✅ | 工厂默认预装，不可单独卸载 |
| AirAccountCompositeValidator | M7 | ✅ | 工厂默认预装，统一处理 Weighted/Cumulative |
| AgentSessionKeyValidator | M7 | ✅ | AI 代理专用 Validator 模块 |
| nonce key → Validator 路由 | M7 | ✅ | nonce 高 192 位指定 Validator 模块 |

#### 账户管理与工厂

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| CREATE2 确定性地址 | M1 | ✅ | 部署前即知地址 |
| EIP-1167 Clone 工厂 | M7 | ✅ | 45 字节 proxy，EIP-170 合规（9,527B 工厂） |
| `createAccountWithDefaults`（Guardian 接受） | M5 | ✅ | 一键部署，Guardian 签名验证 |
| `getAddressWithDefaults` | M5 | ✅ | 预测地址，无需链上调用 |
| ERC-7828 链限定地址（跨链标识） | M7 | ✅ | `getChainQualifiedAddress(addr)` |
| `setP256Key(x, y)` | M2 | ✅ | 设置/更新 Passkey 公钥 |
| `setWeightConfig(tuple)` | M6.1 | ✅ | 配置加权签名权重和阈值 |
| `setParserRegistry(addr)` | M6.6b | ✅ | 绑定 Calldata Parser 注册表 |
| 默认 Token 配置（工厂级） | M7 | ✅ | 工厂部署时注入链特定 Token 限额 |

#### 隐私与互操作

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| OAPD（每 DApp 独立地址） | M6.6a | ✅ | salt = keccak256(owner ++ dappId)，纯链下 |
| Railgun 隐私池集成 | M7 | ✅ | `RailgunParser` + `CalldataParserRegistry` |
| ERC-5564 隐身地址公告 | M7 | ✅ | `announceForStealth(addr, ephemeralKey, meta)` |
| EIP-7702 EOA 委托 | M6.8 | ✅ | `AirAccountDelegate`，无需迁移 |

#### ForceExit（L2 强制退出）

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| ForceExitModule（OP Stack） | M7 | ✅ | 2-of-3 Guardian 门控，`L2ToL1MessagePasser` |
| ForceExitModule（Arbitrum） | M7 | ✅ | 2-of-3 Guardian 门控，`ArbSys.sendTxToL1` |

#### 无 Gas 交易

| Feature | 里程碑 | 状态 | 说明 |
|---------|:------:|:----:|------|
| SuperPaymaster（aPNTs 代 gas） | M3 | ✅ | SBT 门控，aPNTs 预锁定，postOp 精确扣减 |

---

## 3. 用户旅程模拟

### 3.1 旅程 A：新用户首次开户（主路径）

**用户背景**：小明，第一次接触 Web3，有 iPhone，没有 ETH。

```
[第 1 步] App 引导创建 Passkey
  → 系统提示：请录入面部 ID 作为钱包密钥
  → 底层：navigator.credentials.create()
  → 生成 P256 公钥 (x, y)，私钥永远在 SEP 安全芯片，无法导出

[第 2 步] 选择 Guardian（3 人守护）
  → 推荐：Guardian1 = 备用设备/Passkey
           Guardian2 = 信任的家人 EOA
           Guardian3 = AAStar 社区默认 Guardian（工厂预设）
  → 每位 Guardian 需在手机上确认（生成 ACCEPT_GUARDIAN 签名）

[第 3 步] 设置日限额
  → 小明选择：日限额 0.1 ETH（约 $350）
  → 低于此额度：FaceID 一次即可
  → 高于此额度：需要更多验证

[第 4 步] 账户部署（App 后台完成）
  → 调用 factory.createAccountWithDefaults(owner, salt, g1, g1sig, g2, g2sig, dailyLimit)
  → 链上验证：g1sig 和 g2sig 证明 Guardian 同意
  → 部署 EIP-1167 clone（45 字节 proxy）
  → 部署 AAStarGlobalGuard（日限额绑定）
  → 链上 Gas 由 AAStar 代付（首次部署 SuperPaymaster 赠送）

[完成] 小明的账户地址：由 owner+salt 确定性生成
  → 可收款：朋友直接向该地址转账
  → 可发款：FaceID 确认即可（小额）
```

**前端关键调用**：
```typescript
// 预测地址（无需 gas）
const address = await factory.read.getAddressWithDefaults([
  ownerAddr, salt, guardian1Addr, guardian2Addr, dailyLimit
]);

// 部署（需要 gas，由 Paymaster 代付）
await factory.write.createAccountWithDefaults([
  ownerAddr, salt,
  guardian1Addr, guardian1Sig,
  guardian2Addr, guardian2Sig,
  dailyLimit
]);
```

---

### 3.2 旅程 B：小额转账（Tier 1，FaceID 一键完成）

**场景**：小明向朋友转 0.01 ETH（< 日限额 0.1 ETH，algId=0x02 ECDSA 即可）。

```
[用户操作] 输入金额 0.01 ETH + 收款地址 → 按"发送"

[App 后台]
  1. 构建 UserOp（callData = account.execute(to, amount, "0x")）
  2. 从 EntryPoint 获取 nonce
  3. 计算 userOpHash
  4. 触发 FaceID（本质是请求签名 userOpHash 的 EIP-191 wrapped hash）
  5. 构造签名：0x02 ++ ECDSA(65B) = 66 字节
  6. 发送 UserOp 到 Bundler

[链上执行]
  EntryPoint.handleOps
    → account.validateUserOp（ECDSA 验证，algId=0x02）
    → account.execute → Guard.checkTransaction(0.01 ETH, 0x02)
      Guard: 0.01 ETH < 0.1 ETH 日限额 ✓，algId=0x02 在白名单 ✓
    → ETH 转账成功

[Gas] 约 111,674 gas，由 aPNTs 代付
[耗时] 用户感知约 2-3 秒
```

---

### 3.3 旅程 C：大额转账（Tier 3，需 Guardian 联署）

**场景**：小明向交易所转 2 ETH（> tier2Limit，需要 P256+BLS+Guardian 三因子，algId=0x05）。

```
[用户操作] 输入 2 ETH → App 提示"大额转账，需要 Guardian 确认"

[App 后台]
  1. 小明 FaceID（P256 签名 userOpHash）
  2. 后台 DVT 节点对 userOpHash 进行 BLS 聚合签名（2 个节点，自动）
  3. Push 通知发给 Guardian（家人手机）："有人请求转出 2 ETH，请确认"
  4. Guardian 在 App 上刷脸确认（ECDSA 签名）

[链上执行]
  algId=0x05 签名 = 0x05 ++ P256(r,s) ++ BLSPayload(609B) ++ GuardianECDSA(65B)
  Guard.checkTransaction(2 ETH, 0x05)：algId=0x05 对应 Tier 3 ✓

[用户感知] 全程约 10-30 秒（等待 Guardian 确认）
```

---

### 3.4 旅程 D：DApp 使用（Session Key 授权）

**场景**：小明在某 DeFi App 上交换代币，授权 App 在 24 小时内代签。

```
[授权步骤]
  1. App 生成临时 ECDSA 密钥对（sessionKey）
  2. App 请求小明用 FaceID 授权：
     "允许本 App 在 24 小时内，在 UniswapV3 上最多交换 500 USDC"
  3. 小明 FaceID 确认 → 生成 grantSig（EIP-191 包装）
  4. App 调用 sessionKeyValidator.grantSession(account, sessionKey, 24h, uniswapAddr, selector)

[交换时]
  App 自动构建 UserOp，用 sessionKey 签名（algId=0x08）
  无需用户再次确认，在授权范围内自动执行

[风险控制]
  - 过期自动失效（不需要手动撤销）
  - 超出 contractScope（uniswapAddr）的调用链上拒绝
  - 超出 selectorScope 的调用链上拒绝
  - 小明随时可调用 account.revokeSession() 即时撤销

前端调用：
  await sessionKeyValidator.write.grantSession([
    account, sessionKey, expiry, contractAddr, selector, ownerSig
  ]);
```

---

### 3.5 旅程 E：AI 代理（AgentSessionKey）

**场景**：小明授权 AI 助手在 1 周内自动执行 DeFi 策略，每天最多调用 10 次，累计支出不超过 1000 USDC。

```
[配置 AI 代理]
  grantAgentSession(account, agentKey, {
    expiry: now + 7 days,
    velocityLimit: 10,           // 每窗口最多 10 次
    velocityWindow: 24 * 3600,   // 窗口 = 24 小时
    spendToken: USDC,
    spendCap: 1000 USDC,
    callTargets: [uniswap, aave, compound],
    selectorAllowlist: [swap4b, supply4b, withdraw4b]
  });

[代理执行时]
  AI 自动签名 UserOp → validateUserOp 检查：
    ① agentKey 是否为该账户的 session key ✓
    ② 是否过期 ✓
    ③ 今日调用次数 < 10 ✓
    ④ callTarget 在白名单 ✓
    ⑤ 累计支出 < 1000 USDC ✓
  全部通过 → 执行

[子代理委托（M7 新增）]
  AI 主代理可以向子 AI 委托，但范围只能更窄：
  agentValidator.delegateSession(subAgentKey, {
    expiry: 3 days,       // ≤ 父代理 7 days
    spendCap: 200 USDC,   // ≤ 父代理 1000 USDC
    velocityLimit: 3,     // ≤ 父代理 10
    callTargets: [uniswap] // 子集
  });
```

---

### 3.6 旅程 F：私钥丢失 → 社交恢复

**场景**：小明手机丢失，需要 Guardian 帮助恢复账户控制权。

```
[发起恢复]
  Guardian 1（Bob）：account.proposeRecovery(newOwnerAddress)
  Guardian 2（Jack）：account.approveRecovery()
  — 等待 2 天时间锁 —

[执行恢复]
  任何人：account.executeRecovery()
  → owner 变为 newOwnerAddress
  → 原 owner 私钥失效（无法继续签名 UserOp）

[重要限制]
  - 只有 Guardian 才能发起/取消恢复，owner 不能（防攻击者阻止）
  - 时间锁 2 天，让真实 owner 有机会发现并通过 Guardian 取消
  - 取消恢复也需要 2-of-3 Guardian 投票
```

---

### 3.7 旅程 G：老用户过渡（EIP-7702 入门路径）

**场景**：老王有 MetaMask，不想换地址，但想要 Guard 保护。

```
[Step 1] 发送 EIP-7702 授权交易（Type 4 tx）
  authorization_list = [{
    chainId: 11155111,
    address: AirAccountDelegate地址,
    nonce: 当前 EOA nonce,
    签名: 用 MetaMask 私钥签
  }]
  → 老王的 EOA 代码变为指向 AirAccountDelegate

[Step 2] 初始化（目标是自己的 EOA 地址）
  调用 initialize(guardian1, g1sig, guardian2, g2sig, dailyLimit)
  → 部署绑定到该 EOA 的 Guard 合约

[使用]
  - 原 MetaMask 地址不变，朋友/交易所不需要更新
  - FaceID 签名（如果手机有 App 配合）
  - 或继续用 MetaMask 签名（ECDSA）

[重大风险]
  ⚠️ 私钥永远有效，EIP-7702 不撤销私钥
  ⚠️ 如果私钥泄露，攻击者可以覆盖 EIP-7702 委托
  建议：仅作过渡，高价值资产尽快迁移到原生 AirAccountV7
```

---

### 3.8 旅程 H：隐私交易（Railgun + 隐身地址）

**场景**：小明需要在链上进行一笔私密捐款，不想暴露资金来源。

```
[使用 Railgun 隐私池]
  1. 小明调用 account.execute(railgunProxy, amount, depositCalldata)
  2. CalldataParserRegistry 识别 railgunProxy，调用 RailgunParser
  3. RailgunParser 解析 depositCalldata → (USDC, 500)
  4. Guard.checkTokenTransaction(USDC, 500, algId) ← 限额检查仍然执行
  5. Railgun 内部混淆资金流向

[ERC-5564 隐身地址（接收端）]
  发送方调用：
  account.announceForStealth(stealthAddr, ephemeralPubKey, metadata)
  → 接收方扫描 ERC5564Announcer 事件，发现属于自己的资金
  → 用自己的私钥推导 stealthAddr 的私钥，取走资金
  → 链上只见 stealthAddr，与接收方公钥不关联
```

---

## 4. 前端集成指南

### 4.1 核心合约 ABI 索引

```typescript
// 所有 ABI 从 out/ 目录加载（forge build 生成）
import FactoryABI from '../out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json'
import AccountABI from '../out/AAStarAirAccountV7.sol/AAStarAirAccountV7.json'
import GuardABI  from '../out/AAStarGlobalGuard.sol/AAStarGlobalGuard.json'
import EntryPointABI from '../out/IEntryPoint.sol/IEntryPoint.json'
import SessionKeyABI from '../out/SessionKeyValidator.sol/SessionKeyValidator.json'
import AgentKeyABI  from '../out/AgentSessionKeyValidator.sol/AgentSessionKeyValidator.json'
```

### 4.2 工厂接口

```typescript
// ── 1. 预测账户地址（无 gas，链下可算）──────────────────────────────
// 方式 A：完整配置（createAccount 路径）
factory.read.getAddress([owner, salt, initConfig])
// 方式 B：简化配置（createAccountWithDefaults 路径）
factory.read.getAddressWithDefaults([owner, salt, g1, g2, dailyLimit])

// ── 2. 部署账户 ───────────────────────────────────────────────────────
// 方式 A：完整配置（开发/高级用户）
factory.write.createAccount([owner, salt, {
  guardians: [g1, g2, g3],           // address[3]，未用填 address(0)
  dailyLimit: parseEther("0.1"),
  approvedAlgIds: [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
  minDailyLimit: parseEther("0.01"),  // 10% 下限
  initialTokens: [USDC_ADDR],
  initialTokenConfigs: [{ tier1Limit: 500n*1e6n, tier2Limit: 5000n*1e6n, dailyLimit: 10000n*1e6n }]
}])

// 方式 B：默认配置（推荐，用于 App 用户）
// guardian1Sig = signMessage(keccak256(encodePacked("ACCEPT_GUARDIAN", chainId, factoryAddr, owner, salt)))
factory.write.createAccountWithDefaults([
  owner, salt, g1, guardian1Sig, g2, guardian2Sig, dailyLimit
])

// ── 3. 跨链地址标识（ERC-7828）────────────────────────────────────────
factory.read.getChainQualifiedAddress([accountAddr])  // bytes32，跨链唯一
```

### 4.3 账户接口

```typescript
// ── 执行 ─────────────────────────────────────────────────────────────
// 单笔调用（通过 UserOp）
callData = encodeFunctionData({ abi: AccountABI, functionName: 'execute',
  args: [targetAddr, valueInWei, calldata] })

// 批量调用
callData = encodeFunctionData({ abi: AccountABI, functionName: 'executeBatch',
  args: [[target1, target2], [val1, val2], [data1, data2]] })

// ── 账户配置 ──────────────────────────────────────────────────────────
// P256 公钥（Passkey 开户后调用一次）
account.write.setP256Key([pubKeyX, pubKeyY])

// 加权签名配置（ALG_WEIGHTED 用户）
account.write.setWeightConfig([{
  passkeyWeight: 2, ecdsaWeight: 2,
  guardianWeights: [1, 1, 1],
  tier1Threshold: 2, tier2Threshold: 4, tier3Threshold: 6
}])

// DeFi Parser Registry（DeFi 用户）
account.write.setParserRegistry([registryAddr])

// BLS Aggregator（BLS 用户）
account.write.setAggregator([aggregatorAddr])

// ── ERC-7579 模块管理 ─────────────────────────────────────────────────
// 安装 Validator 模块（需要 Guardian 阈值签名）
account.write.installModule([1, validatorAddr, initData])   // type 1 = Validator
account.write.installModule([2, executorAddr, initData])    // type 2 = Executor
account.write.installModule([4, hookAddr, initData])        // type 4 = Hook

// 卸载（需要 2-of-3 Guardian 投票）
account.write.uninstallModule([1, validatorAddr, deInitData])

// ── 查询 ──────────────────────────────────────────────────────────────
account.read.owner()                    // 当前 owner
account.read.guard()                    // Guard 合约地址
account.read.guardians()                // [g1, g2, g3]
account.read.isModuleInstalled([type, addr, ""])  // ERC-7579 查询
account.read.getDeposit()               // EntryPoint 存款余额
```

### 4.4 Guard 接口（只读为主）

```typescript
guard.read.account()          // 绑定的账户地址（不可变）
guard.read.dailyLimit()       // ETH 日限额（wei）
guard.read.todaySpent()       // 今日已使用 ETH（wei）
guard.read.tier1Limit()       // Tier 1 阈值
guard.read.tier2Limit()       // Tier 2 阈值
guard.read.minDailyLimit()    // 最低日限额下限
guard.read.isAlgorithmApproved([algId])  // algId 是否在白名单
guard.read.approvedAlgorithms()          // 白名单列表

// 降低日限额（只能降不能升，需要当前 owner 签名的 UserOp）
// 在 UserOp callData 中编码：
callData = encodeFunctionData({ abi: AccountABI, functionName: 'execute',
  args: [guardAddr, 0n, encodeFunctionData({ abi: GuardABI,
    functionName: 'decreaseDailyLimit', args: [newLimit] })] })
```

### 4.5 Session Key 接口

```typescript
// ── SessionKeyValidator（algId=0x08，M6.4）────────────────────────────
// 授权 Session Key（owner 签名）
const grantHash = await sessionKeyValidator.read.buildGrantHash([
  account, sessionKey, expiry, contractScope, selectorScope
])
const ownerSig = await account.signMessage({ message: { raw: grantHash } })
await sessionKeyValidator.write.grantSession([
  account, sessionKey, expiry, contractScope, selectorScope, ownerSig
])

// 撤销
await sessionKeyValidator.write.revokeSession([account, sessionKey])

// 签名格式（algId=0x08，ECDSA Session）：
// [0x08][account(20)][sessionKey(20)][ECDSASig(65)] = 106 字节

// ── AgentSessionKeyValidator（AI 代理，M7）───────────────────────────
await agentValidator.write.grantAgentSession([account, agentKey, {
  expiry: BigInt(Date.now()/1000 + 7*86400),
  velocityLimit: 10,
  velocityWindow: 86400,
  spendToken: USDC_ADDR,
  spendCap: 1000n * 10n**6n,
  revoked: false,
  callTargets: [UNISWAP_V3],
  selectorAllowlist: ['0x04e45aaf']  // exactInputSingle
}])

// 子代理委托（M7，父 Session Key 调用）
await agentValidator.write.delegateSession([subAgentKey, {
  expiry: ...,  // <= 父代理 expiry
  spendCap: ...,  // <= 父代理 spendCap
  // ...
}])

// 撤销
await agentValidator.write.revokeAgentSession([account, agentKey])
```

### 4.6 标准 UserOp 构建（ERC-4337 v0.7）

```typescript
import { toHex, encodeFunctionData, keccak256, hexToBytes } from 'viem'

// 1. 组装 UserOp
const userOp = {
  sender: accountAddr,
  nonce: await entryPoint.read.getNonce([accountAddr, 0n]),
  initCode: '0x',                   // 账户已部署填 0x
  callData,
  accountGasLimits: toHex((500_000n << 128n) | 200_000n, { size: 32 }),
  preVerificationGas: 60_000n,
  gasFees: toHex((maxPriorityFee << 128n) | maxFee, { size: 32 }),
  paymasterAndData: '0x',           // 自付 gas；Paymaster 见 §4.7
  signature: '0x'
}

// 2. 获取 hash（直接从 EntryPoint 查询，最准确）
const userOpHash = await entryPoint.read.getUserOpHash([userOp])

// 3. 签名（algId=0x02 ECDSA 示例）
const ownerSig = await ownerAccount.signMessage({ message: { raw: userOpHash } })
userOp.signature = ('0x02' + ownerSig.slice(2)) as `0x${string}`  // 66 字节

// 3b. P256 签名（algId=0x03）
// [0x03][r(32)][s(32)] = 65 字节，r/s 来自 WebAuthn authenticatorAssertionResponse

// 3c. ALG_WEIGHTED 签名（algId=0x07）
// [0x07][bitmap(1)][P256_r(32)][P256_s(32)][ECDSA_sig(65)] = 130 字节
// bitmap: bit0=P256, bit1=ECDSA, bit2=BLS, bit3/4/5=guardian[0/1/2]

// 4. 提交（直接走 Bundler）
const txHash = await walletClient.writeContract({
  address: ENTRYPOINT, abi: entryPointAbi,
  functionName: 'handleOps',
  args: [[userOp], bundlerAddr]
})
```

### 4.7 Paymaster（无 Gas 交易）

```typescript
// SuperPaymaster paymasterAndData 格式（72 字节）
paymasterAndData = concat([
  superPaymasterAddr,            // 20 字节
  toHex(verifyGasLimit, { size: 16 }),   // 16 字节
  toHex(postOpGasLimit, { size: 16 }),   // 16 字节
  operatorAddr                   // 20 字节
])

// 调用 Pimlico 或 Alchemy Bundler 时通过 pm_sponsorUserOperation 获取
// 或直接使用 AAStar 官方 Bundler（Sepolia）
```

### 4.8 社交恢复前端流程

```typescript
// Step 1：Guardian 发起提案
await account.write.proposeRecovery([newOwnerAddress])  // msg.sender = guardian

// Step 2：另一 Guardian 投票
await account.write.approveRecovery()  // msg.sender = 另一 guardian

// Step 3：等待 2 天时间锁后执行
await account.write.executeRecovery()  // 任何人可调用

// 查询恢复状态
const recovery = await account.read.activeRecovery()
// { newOwner, initiatedAt, approvalCount }
// 显示：距可执行还有 Math.max(0, initiatedAt + 2days - now) 秒

// 取消恢复（需要 2-of-3 Guardian）
await account.write.cancelRecovery()  // msg.sender = guardian，达到阈值时生效
```

---

## 5. 已部署合约地址

### 5.1 当前版本（M7，Sepolia）

| 合约 | 地址 | 说明 |
|------|------|------|
| **M7 Factory（最新）** | `0x9D0735E3096C02eC63356F21d6ef79586280289f` | EIP-1167 clone 工厂 |
| **M7 Implementation** | `0xf01e3Dd359DfF8e578Ee8760266E3fB9530F07A0` | 共享实现（24,497B） |
| **M7 Account（salt=2000）** | `0xb185C9634dCBC43F71bE7de15001A438eDC50DEb` | Guardian accept 部署，E2E 验证 ✅ |
| **M7 Account（salt=700）** | `0xCD1eE31b1D887FE7dC086b023Db162C84B499158` | createAccount 部署 |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ERC-4337 单例（官方） |

### 5.2 历史版本（保留，仍可用）

| 合约 | 地址 | 版本 | 说明 |
|------|------|------|------|
| M6 r4 Factory | `0x34282bef82e14af3cc61fecaa60eab91d3a82d46` | M6 | ALG_WEIGHTED，Session Key |
| M6 r2 Factory | `0xa3f03e9f6cde536a1b776162a9f0e462f2adbbbf` | M6.2 | clone 工厂首版 |
| M5 Factory r5 | `0xd72a236d84be6c388a8bc7deb64afd54704ae385` | M5 | ERC20 Guard，BLS DVT |
| M4 Factory | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | M4 | 累积签名 |
| BLS Algorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | M2 | BLS12-381 验证 |
| Validator Router | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` | M2 | algId 路由 |

> ℹ️ 旧版本合约保留。M5/M6 E2E 测试脚本仍指向对应版本，用于回归验证。

### 5.3 SuperPaymaster 生态（Sepolia）

| 合约 | 地址 |
|------|------|
| SuperPaymaster | `0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A` |
| aPNTs Token | `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` |
| SBT（身份） | `0x677423f5Dad98D19cAE8661c36F094289cb6171a` |
| Price Feed (Chainlink) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

### 5.4 测试 EOA 账户

| 角色 | 地址 | 私钥环境变量 |
|------|------|------------|
| Owner / Operator | `0xb5600060e6de5E11D3636731964218E53caadf0E` | `PRIVATE_KEY` |
| Guardian 1 (Bob，派生地址) | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` | `PRIVATE_KEY_BOB` |
| Guardian 2 (Jack) | `0x084b5F85A5149b03aDf9396C7C94D8B8F328FB36` | `PRIVATE_KEY_JACK` |

> ⚠️ `.env.sepolia` 中的 `ADDRESS_BOB_EOA` 与 `PRIVATE_KEY_BOB` 派生地址不符，脚本中务必用 `privateKeyToAccount(PRIVATE_KEY_BOB).address`，不要直接用 `ADDRESS_BOB_EOA`。

---

## 6. Validator / Keeper / Bundler 集成依赖

### 6.1 Bundler 依赖

AirAccount 使用 **ERC-4337 v0.7 PackedUserOperation**，需要支持 v0.7 的 Bundler。

| Bundler | 状态 | 配置 |
|---------|------|------|
| Alchemy AA | ✅ 推荐 | `SEPOLIA_RPC_URL` / `BUNDLER_URL` |
| Pimlico | ✅ 推荐 | `PIMLICO_BUNDLER_URL` |
| Candide (公共，无 key) | ✅ 测试用 | `CANDIDE_BUNDLER_URL` |
| 自建 Bundler | 需实现 v0.7 | 支持 `eth_sendUserOperation` v0.7 |

**注意**：Alchemy 免费版有"in-flight transaction limit"（并发限制），E2E 测试应串行运行。

### 6.2 BLS DVT 节点集成

BLS 签名（algId=0x01/0x04/0x05）需要链下 DVT 节点网络配合。

```
架构：
  用户 App → DVT Coordinator（链下服务）→ N 个 BLS 节点
                                          → 聚合签名（BLS12-381）
                                          → 返回 blsPayload（609 字节）

接入步骤：
  1. 节点运营方在 BLS Algorithm 合约注册（registerNode(pubKey)）
  2. 用户账户开户时选择 N 个 DVT 节点
  3. Coordinator 服务地址写入账户配置

已注册测试节点（Sepolia）：
  Node 1 pubkey: 0x0000...113489490... (BLS_TEST_PUBLIC_KEY_1 in .env.sepolia)
  Node 2 pubkey: 0x0000...102c3707... (BLS_TEST_PUBLIC_KEY_2 in .env.sepolia)
```

### 6.3 Keeper（时间触发）集成

以下功能需要链下 Keeper 或用户手动触发：

| 功能 | Keeper 职责 | 触发时机 |
|------|------------|---------|
| 社交恢复执行 | 调用 `executeRecovery()` | `initiatedAt + 2 days` 后 |
| EIP-7702 Rescue 执行 | 调用 `executeRescue()` | `rescueInitiatedAt + 2 days` 后 |
| Session Key 过期清理 | 可选，节省存储（gas） | `expiry` 后 |
| ForceExit 到 L1 | 调用 `finalizeWithdrawal()` | OP Stack: 7 天后；Arbitrum: ~1 天后 |

**推荐**：使用 Chainlink Automation 或 Gelato Network 作为 Keeper，或在 App 内置定时任务。

### 6.4 CalldataParser 集成（新增 DeFi 协议）

要让 Guard 识别新的 DeFi 协议，需要：

```solidity
// 1. 实现 ICalldataParser 接口
contract MyProtocolParser is ICalldataParser {
    function parse(bytes calldata data)
        external pure returns (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
    { ... }
}

// 2. 在 Registry 注册（Registry owner 授权后执行）
registry.registerParser(MY_PROTOCOL_ADDR, address(myParser));

// 3. 用户将 Registry 绑定到账户
account.execute(accountAddr, 0, abi.encodeCall(account.setParserRegistry, registryAddr))
```

**当前已注册（Sepolia）**：
- UniswapV3 Router：`0x7464d5ec6891099d299e434ba1727a0a3f07b907`
- Railgun Proxy：通过 `RailgunParser` 注册

### 6.5 预编译依赖表

| 预编译 | 地址 | EIP | 需要功能 | 当前状态 |
|--------|------|-----|---------|---------|
| P256VERIFY | `0x100` | EIP-7212 | algId=0x03/0x04/0x05/0x06 | ✅ Sepolia Pectra+ |
| BLS12-381（G1/G2/Pairing） | `0x0b`–`0x12` | EIP-2537 | algId=0x01/0x04/0x05 | ✅ Sepolia Prague+ |
| TSTORE/TLOAD | 内置 | EIP-1153 | algId 跨函数传递 | ✅ Cancun+ 全链 |

---

## 7. 已知限制与风险分析

### 7.1 非可升级设计

- **风险**：发现漏洞无法热修复，需要用户主动迁移资产到新版本工厂的账户。
- **缓解**：非可升级意味着已审计代码永远不变，用户有充分理由信任；每次升级发布前充分测试和审计。
- **极端情况**：若发现严重漏洞，将部署新工厂，通过 App 推送迁移指南，Guardian 辅助迁移。

### 7.2 EIP-7702 私钥永久有效

- **风险**：AirAccountDelegate 用户的 EOA 私钥无法被撤销，硬件被盗即资产危险。
- **缓解**：Rescue 流程可在 2 天内转移 ETH 资产到新地址；建议 30 天内迁移到原生 AirAccountV7。
- **不适用场景**：持有 >$10,000 资产的用户不应长期使用 AirAccountDelegate。

### 7.3 CalldataParser 信任假设

- **风险**：Registry owner 可以注册返回虚假金额的恶意 Parser，绕过 Guard 限额。
- **当前状态**：Registry owner = EOA（测试阶段可接受）。
- **主网要求**：Registry owner **必须**是 Gnosis Safe 3-of-5 + 48h Timelock，才能安全上主网。

### 7.4 BLS 聚合依赖链下节点

- **风险**：DVT 节点宕机时，algId=0x04/0x05 签名无法完成，Tier 2/3 交易被阻塞。
- **缓解**：用户配置降级路径（如当 DVT 不可用时 Guardian 手动联署，algId=0x05 也可工作）。
- **建议**：生产环境至少运行 5 个节点，阈值 3-of-5。

### 7.5 P256/BLS 链兼容性

- **P256（algId=0x03/0x06）**：仅限 Pectra+ 链。Ethereum mainnet 主网 Pectra 已激活（2025 Q1）；L2 视具体情况，OP Stack Fjord+ ✅，Arbitrum ✅，zkSync ✅。
- **BLS（algId=0x01/0x04/0x05）**：仅限 Prague/Pectra+ 链。EIP-2537 在 Ethereum Pectra 中激活；L2 取决于各链升级进度。
- **退路**：若部署到不支持预编译的链，仅 algId=0x02（ECDSA）和 0x07（Weighted ECDSA-only）可用。

### 7.6 M7 Clone 代理开销

- 每次调用增加约 4,000–5,000 gas（冷 DELEGATECALL）。
- 批量打包多个 M7 账户 UserOp 时，第 2+ 个账户降至 ~100 gas（地址变 warm）。
- 相比 LightAccount、SimpleAccount 仍有竞争力（见 §2 Gas 对比表）。

---

## 8. 极端情况处理手册

### 极端情况 1：所有 Guardian 失联

```
现象：发起社交恢复后无法凑够 2 个 Guardian 投票
处理：
  1. owner 私钥仍有效时，正常使用账户（Guard 仍保护资产）
  2. 在 App 内发起 Guardian 替换提案（需要 owner + 至少 1 个 Guardian）
  3. 若只有 1 个 Guardian 响应，无法完成恢复 → 资产被 Guard 日限额保护
  4. 极端情况：owner 私钥和全部 Guardian 同时丢失 → 资产永久锁定
  预防措施：
    - 每年检查一次 Guardian 是否仍可联系
    - Guardian 3 建议使用 AAStar 社区 Guardian（专业看护服务）
```

### 极端情况 2：单 Guardian 合谋

```
现象：1 个 Guardian 和 2 个陌生人合谋提议恢复到攻击者地址
处理：
  - 提议时 owner 会收到通知（App 监听 RecoveryProposed 事件）
  - owner 在 2 天时间锁内联系其他 Guardian 发起取消（需要 2-of-3 投票取消）
  - 2 天后方可执行，owner 有足够反应时间
  风险评估：低（需要 2 人合谋 + owner 2 天内无响应才能成功）
```

### 极端情况 3：Gas 费飙升（Bundler 拒绝低费 UserOp）

```
现象：高 gas 时期 Bundler 拒绝提交 UserOp
处理：
  1. 增加 maxFeePerGas（App 实时查询 eth_gasPrice）
  2. 切换 Bundler（Pimlico 备用 → Candide 公共）
  3. 如使用 SuperPaymaster：aPNTs 会多扣（按实际 gas 计算），不影响成功率
  4. 极端情况：直接从 EOA 调用（降级路径，owner 私钥紧急使用）
```

### 极端情况 4：L2 Sequencer 宕机（ForceExit 场景）

```
现象：L2 Sequencer 宕机，无法提交 UserOp
处理（OP Stack）：
  1. 2-of-3 Guardian 通过 L1 向 L2ToL1MessagePasser 发起 ForceExit
  2. 等待 7 天挑战期
  3. 在 L1 上领取资产

处理（Arbitrum）：
  1. 2-of-3 Guardian 通过 ForceExitModule 调用 ArbSys.sendTxToL1
  2. 等待约 1 天
  3. 在 L1 上领取资产

前提：账户需要安装 ForceExitModule（工厂默认不预装，需用户手动安装）
```

### 极端情况 5：Session Key 被盗

```
现象：DApp 服务端被攻击，sessionKey 私钥泄露
处理：
  1. owner 立即调用 sessionKeyValidator.revokeSession(account, sessionKey)
     → 链上即时生效，无需等待
  2. 已执行的交易无法撤销，但 Guard 日限额限制了损失
  建议：高价值操作不使用 Session Key，日限额 Tier 1 设置保守值
```

---

## 9. 安全摘要

### 9.1 测试覆盖

| 类型 | 数量 | 状态 |
|------|:----:|:----:|
| Foundry 单元测试 | **622** | ✅ 全部通过 |
| Sepolia E2E 测试 | **约 80+** | ✅ 全部通过（M1–M7） |
| 内部安全审计 | 3 轮 | ✅（docs/audit_report_*.md） |
| 正式第三方审计 | 0 | ⏳ 待申请（见 TODO-001） |

### 9.2 安全机制矩阵

| 攻击向量 | 防御机制 | 位置 |
|---------|---------|------|
| 单私钥被盗 | 社交恢复 + 时间锁 | `AAStarAirAccountBase` |
| 大额盗转 | Tier 分级 + Guard 日限额 | `AAStarGlobalGuard` |
| DeFi 恶意合约 | Calldata 解析 + Token 限额 | `CalldataParserRegistry` |
| 工厂前抢跑 | CREATE2 盐绑定 owner+guardian | `AAStarAirAccountFactoryV7` |
| 模块安装攻击 | Guardian 阈值门控 | `AAStarAirAccountV7` |
| Session Key 滥用 | 作用域+到期+即时撤销 | `SessionKeyValidator` |
| AI 代理失控 | 速率限制+支出上限+目标白名单 | `AgentSessionKeyValidator` |
| 跨账户污染 | TSTORE 按账户地址命名空间 | `AAStarValidator` |
| L2 Sequencer 审查 | ForceExitModule | `ForceExitModule` |

### 9.3 不变量（Invariants）

1. **Guard 不可升级**：`AAStarGlobalGuard.account` 构造后不变，无法换绑
2. **日限额单调递减**：Guard 限额只能降低，永远不能提高
3. **社交恢复需要 2/3**：单 Guardian 无法独立完成恢复，2 天时间锁无法绕过
4. **模块安装需要 Guardian**：单 owner 私钥无法安装恶意模块
5. **Session Key 隔离**：Account A 的 Session Key 无法验证 Account B 的 UserOp
6. **algId 路由无降级**：无效 algId 直接 revert，不会降级到更弱算法

---

## 10. 待办事项（TODO List）

> 以下为 M7 发版后尚未完成的任务，需要持续推进。

---

### TODO-001：正式第三方安全审计 🔴 高优先级

**负责人**：Jason（需要手动申请）
**依赖**：M7 合约层已完成（✅）

**操作步骤**：
1. **申请 CodeHawks 竞争性审计**
   - 网站：https://codehawks.com
   - 联系 Cyfrin：说明公共品（public goods）属性，申请 reduced-cost 审计
   - 审计范围文档：`docs/audit-scope.md`（已完成）
   - 已知问题文档：`docs/known-issues.md`（已完成）
   - 目标奖金池：$15,000–$20,000

2. **同步申请 Immunefi Bug Bounty**（审计后）
   - 需要先完成正式审计
   - 初始 Vault 预算：~$50,000

3. **准备材料**
   - 审计范围：`src/` 下 4,456 行 Solidity（详见 `docs/audit-scope.md`）
   - 测试覆盖报告：`forge coverage`
   - 内部审计报告：`docs/audit_report_2026_03_19_comprehensive.md`

---

### TODO-002：前端 / 移动 App SDK 开发 🔴 高优先级

**负责人**：前端团队（独立 Repo：`airaccount-sdk`）

| 功能 | 包 | 优先级 |
|------|-----|:------:|
| Passkey 创建与签名 | `@webauthn-p256/core` | P0 |
| P256 UserOp 签名 | viem + noble/curves | P0 |
| Session Key 管理 | 封装 SessionKeyValidator ABI | P0 |
| UserOp 构建助手 | 封装 §4.6 流程 | P0 |
| ENS 地址解析 | `viem/ens` | P1 |
| EIP-1193 Provider 包装 | `@mipd/store` + EIP-6963 | P1 |
| Ledger/Trezor 硬件钱包 | `@ledgerhq/hw-app-eth` | P1 |
| Helios 轻客户端 | `@a16z/helios` | P2 |
| x402 AI 微支付 | `@x402/core` | P2 |
| 每 DApp 独立地址（OAPD） | salt 推导工具函数 | P1 |

**SDK 接口设计原则**：
```typescript
// 目标接口风格（供参考）
import { AirAccount } from '@aastar/airaccount-sdk'

const account = await AirAccount.connect({
  factory: '0x9D07...',
  owner: passkeyAccount,
  guardians: [g1, g2],
  dailyLimit: parseEther('0.1'),
  bundler: 'https://api.pimlico.io/...'
})

await account.send({ to: recipient, value: parseEther('0.01') })
// → 自动选择 algId，自动构建 UserOp，自动提交 Bundler
```

---

### TODO-003：多链部署 🟡 中优先级

**状态**：`deploy-multichain.ts` 脚本已完成，等待执行

| 链 | 状态 | ForceExit 类型 | 备注 |
|----|------|---------------|------|
| Sepolia（测试网） | ✅ 已部署 | — | |
| Ethereum Mainnet | ⏳ 待部署 | — | 需审计后 |
| OP Mainnet | ⏳ 待执行 | `L2ToL1MessagePasser` | EIP-7212 ✅ |
| Base Mainnet | ⏳ 待执行 | OP Stack 同上 | `token-presets.json` 已配 |
| Arbitrum One | ⏳ 待执行 | `ArbSys.sendTxToL1` | |
| zkSync Era | ⏳ 规划中 | zkSync 原生退出 | |

**部署命令**：
```bash
CHAIN=optimism pnpm tsx scripts/deploy-multichain.ts
CHAIN=base pnpm tsx scripts/deploy-multichain.ts
```

---

### TODO-004：CalldataParser Registry 治理升级 🟡 中优先级

**当前状态**：Registry owner = EOA（开发阶段）
**主网要求**：移交给 Gnosis Safe 3-of-5 + 48h Timelock

步骤：
1. 部署 Gnosis Safe（3-of-5，含 Jason + AAStar 核心成员）
2. 部署 TimelockController（48h delay）
3. `registry.transferOwnership(timelockAddr)`
4. 后续新增 Parser 需要 Safe 多签提案 → 48h 后生效

---

### TODO-005：BLS DVT 生产节点网络 🟡 中优先级

**当前状态**：2 个测试节点（`BLS_TEST_PUBLIC_KEY_1/2`），仅用于 E2E 测试
**生产要求**：5+ 独立节点，3-of-5 阈值，地理分布

步骤：
1. 招募节点运营方（DVT 节点运营激励设计）
2. 节点软件开发（DVT Coordinator + BLS 签名服务）
3. 在 BLS Algorithm 合约注册节点公钥
4. App 端接入 DVT Coordinator API

---

### TODO-006：SuperPaymaster 集成测试 🟡 中优先级

**当前状态**：SuperPaymaster 合约已部署，E2E 测试通过（1 笔），但缺少：
- aPNTs 自动充值流程（当余额不足时如何提示用户）
- 与 M7 工厂账户的完整集成测试（当前 E2E 基于 M5 账户）
- Bundler 的 `pm_sponsorUserOperation` 接口对接

---

### TODO-007：ERC-7579 模块生态接入 🟢 低优先级

AirAccount M7 已完整实现 ERC-7579 Validator / Executor / Hook 接口，可接入：
- **ZeroDev 插件生态**（via Kernel 兼容层）
- **Rhinestone 模块市场**（Registry 风格模块安装）
- **自定义 Executor 模块**（如 DCA 策略、自动 Rebalancing）

接入步骤：
1. 验证 `IERC7579Account` 接口兼容性（`accountId()` 返回 `aastar.airaccount.v0.16.0`）
2. 测试第三方模块安装流程（`installModule` + Guardian 签名）
3. 上架 Rhinestone 模块注册表

---

### TODO-008：WalletBeat 评分优化 🟢 低优先级

参考 `docs/walletbeat-assessment.md`，当前已完成 Stage 1 大部分项目：
- ⏳ Stage 1 / S1-1：正式安全审计（见 TODO-001）
- ⏳ Stage 1 / S1-2：硬件钱包 SDK 集成（见 TODO-002）
- ⏳ Stage 2 / S2-4：多链部署（见 TODO-003）

---

### TODO-009：ForceExit 模块部署与测试 🟢 低优先级

**当前状态**：`ForceExitModule.sol` 合约代码已完成，29 个单元测试通过
**待完成**：
- Sepolia 上部署合约
- 接入测试账户，验证 OP Stack 和 Arbitrum 路径的实际链上流程
- 提供用户 App 内"紧急退出"UI

---

### TODO-010：CHANGELOG 合并冲突修复 🟢 低优先级

`CHANGELOG.md` 第 11 行存在 `<<<<<<< HEAD` 合并冲突标记，需手动清理。

---

*文档版本：v1.0.0（2026-03-21）*
*下一次更新：审计完成后更新第三方审计结果*
