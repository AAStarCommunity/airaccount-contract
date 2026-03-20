# AirAccount V7 — 产品验收指南

**版本**: v0.15.0 (M7)
**更新日期**: 2026-03-20
**网络**: Sepolia 测试网 (Chain ID: 11155111)
**编译器**: Solidity 0.8.33，Cancun EVM，via-IR，optimizer_runs=1（EIP-170 合规）

> 合约完整清单、algId 表、功能说明详见 [`docs/contract-registry.md`](contract-registry.md)。

---

## 1. 产品定位

AirAccount 是面向大众用户的 **非可升级 ERC-4337 智能钱包**，核心价值主张：

- **手机一键支付**（Passkey/WebAuthn）完成小额付款
- **自动 DVT 联署**处理中等交易
- **Guardian 审批**大额转账
- **零 ETH**——通过 SuperPaymaster 用 aPNTs 代币支付 gas
- **社交恢复**——2-of-3 Guardian 阈值 + 2 天时间锁

### 1.1 两种账户类型

| 类型 | 适用用户 | 地址 | 安全模型 |
|------|---------|------|---------|
| **AirAccountV7**（主路径） | 新用户 | 全新 CREATE2 地址 | EIP-1167 clone，无私钥依赖 |
| **AirAccountDelegate**（入门路径） | 已有 MetaMask 等 EOA 的用户 | 原 EOA 地址不变 | EIP-7702 委托，私钥仍有效 |

> ⚠️ AirAccountDelegate 是**入门路径**，功能是 AirAccountV7 的子集（约 30%）。高价值用户应迁移到 AirAccountV7。

---

## 2. 完整功能清单

### 2.1 AirAccountV7 功能矩阵（主路径，M1–M7）

| 功能 | 状态 | algId | 里程碑 | 说明 |
|------|:----:|:-----:|:------:|------|
| **签名与验证** | | | | |
| ECDSA 验证 | ✅ | `0x02` | M1 | ecrecover，EIP-2 malleability 修复 |
| P256/WebAuthn Passkey | ✅ | `0x03` | M2 | EIP-7212 预编译，硬件绑定 |
| BLS12-381 聚合签名 | ✅ | `0x01` | M2 | EIP-2537 预编译，DVT 多节点 |
| 累积 Tier 2（P256+BLS） | ✅ | `0x04` | M4 | 两因子叠加 |
| 累积 Tier 3（P256+BLS+Guardian） | ✅ | `0x05` | M4 | 三因子叠加 |
| Combined T1（ECDSA+P256） | ✅ | `0x06` | M5 | 零信任双因子 |
| ALG_WEIGHTED 加权多签 | ✅ | `0x07` | M6.1 | 可配置权重+阈值，bitmap 驱动 |
| Session Key ECDSA | ✅ | `0x08` | M6.4 | DApp 服务端密钥，作用域限制 |
| Session Key P256 | ✅ | `0x08` | M6.4 | 用户 Passkey 授权，硬件绑定 |
| **Guard（支出保护）** | | | | |
| ETH 日限额 | ✅ | — | M3 | 每 UTC 日重置，不可绕过 |
| ERC20 token tier 检查 | ✅ | — | M5 | transfer/approve 自动解析 |
| DeFi 协议 Calldata 解析 | ✅ | — | M6.6b | UniswapV3 等协议的 swap 金额识别 |
| 算法白名单 | ✅ | — | M3 | 仅批准算法可通过 guard |
| 单调安全（只收紧不放松） | ✅ | — | M3 | 日限额只能降低，算法只能添加 |
| **Guardian 与恢复** | | | | |
| 社交恢复（2-of-3，2天时间锁） | ✅ | — | M4 | owner 不能取消（防私钥被盗） |
| Guardian 接受签名验证 | ✅ | — | M5 | 部署时链上验证 guardian 同意 |
| Guardian 轮换审批（governance） | ✅ | — | M6.2 | 降低安全设置需 guardian 投票+时间锁 |
| **账户管理** | | | | |
| 工厂 CREATE2 部署（EIP-1167 clone） | ✅ | — | M7 | 45 字节 proxy，EIP-170 合规 |
| getAddress（部署前预测地址） | ✅ | — | M1 | 确定性地址 |
| P256 Key 设置/更新 | ✅ | — | M2 | setP256Key(x, y) |
| 加权配置 | ✅ | — | M6.1 | setWeightConfig(tuple) |
| Parser Registry 绑定 | ✅ | — | M6.6b | setParserRegistry(addr) |
| BLS Aggregator 绑定 | ✅ | — | M2 | setAggregator(addr) |
| **其他** | | | | |
| 无 gas 交易（SuperPaymaster） | ✅ | — | M3 | aPNTs 支付 gas |
| OAPD（每 DApp 独立地址） | ✅ | — | M6.6a | 纯 TypeScript，零合约改动 |
| ERC-7579 最小兼容 shim | ✅ | — | M6 | accountId/supportsModule |
| EIP-7702 入门委托 | ✅ | — | M6.8 | AirAccountDelegate，见下节 |

### 2.2 AirAccountDelegate 功能矩阵（入门路径，7702）

| 功能 | 状态 | 与 AirAccountV7 的差异 |
|------|:----:|----------------------|
| ECDSA 验证 | ✅ | 仅 algId=0x02，无其他算法 |
| ETH 日限额 | ✅ | 同 AirAccountV7 |
| execute / executeBatch | ✅ | 同 AirAccountV7 |
| 无 gas 交易（SuperPaymaster） | ✅ | 同 AirAccountV7 |
| Guardian Rescue（资产转移） | ✅ | ⚠️ 不同：转移 ETH 资产，而非转移 owner 控制权 |
| P256/BLS/加权签名 | ❌ | 不支持 |
| ERC20 token tier 检查 | ❌ | execute() 只有 ETH guard，无 token 检查 |
| DeFi Calldata 解析 | ❌ | 不支持 |
| Session Key | ❌ | 不支持 |
| OAPD | ❌ | 不支持 |
| Guardian 添加/删除 | ❌ | 初始化固定 2 个，不可变更 |

---

## 3. 已部署合约（Sepolia）

### 3.1 AirAccount 核心（当前版本）

| 合约 | 地址 | 角色 |
|------|------|------|
| **M7 Factory（当前）** | [`0xa3f03e9f6cde536a1b776162a9f0e462f2adbbbf`](https://sepolia.etherscan.io/address/0xa3f03e9f6cde536a1b776162a9f0e462f2adbbbf) | EIP-1167 clone 工厂，EIP-170 合规（9,527B） |
| **M7 Implementation** | [`0x3C866080C6AA37697AeA43106956369071d26600`](https://sepolia.etherscan.io/address/0x3C866080C6AA37697AeA43106956369071d26600) | 所有 M7 clone 账户的共享实现（20,900B） |
| M5 Factory r5 | [`0xd72a236d84be6c388a8bc7deb64afd54704ae385`](https://sepolia.etherscan.io/address/0xd72a236d84be6c388a8bc7deb64afd54704ae385) | M5 完整功能工厂（历史版本） |
| M4 Factory | [`0x914db0a849f55e68a726c72fd02b7114b1176d88`](https://sepolia.etherscan.io/address/0x914db0a849f55e68a726c72fd02b7114b1176d88) | M4 累积签名版本 |
| EntryPoint v0.7 | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) | ERC-4337 单例 |
| Validator Router | [`0x730a162Ce3202b94cC5B74181B75b11eBB3045B1`](https://sepolia.etherscan.io/address/0x730a162Ce3202b94cC5B74181B75b11eBB3045B1) | algId → 算法合约路由 |
| BLS Algorithm | [`0xc2096E8D04beb3C337bb388F5352710d62De0287`](https://sepolia.etherscan.io/address/0xc2096E8D04beb3C337bb388F5352710d62De0287) | BLS12-381 验证 + 节点注册 |

### 3.2 SuperPaymaster 生态

| 合约 | 地址 | 角色 |
|------|------|------|
| SuperPaymaster | [`0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A`](https://sepolia.etherscan.io/address/0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A) | aPNTs 换 ETH gas |
| aPNTs Token | [`0xDf669834F04988BcEE0E3B6013B6b867Bd38778d`](https://sepolia.etherscan.io/address/0xDf669834F04988BcEE0E3B6013B6b867Bd38778d) | ERC-20 gas 代币 |
| SBT（身份） | [`0x677423f5Dad98D19cAE8661c36F094289cb6171a`](https://sepolia.etherscan.io/address/0x677423f5Dad98D19cAE8661c36F094289cb6171a) | 灵魂绑定身份门控 |
| Price Feed (Chainlink) | [`0x694AA1769357215DE4FAC081bf1f309aDC325306`](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306) | ETH/USD 预言机 |

### 3.3 测试账户（EOA）

| 角色 | 地址 |
|------|------|
| Owner / Operator / Bundler | `0xb5600060e6de5E11D3636731964218E53caadf0E` |
| Guardian 1 (Bob) | `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C` |
| Guardian 2 (Jack) | `0x084b5F85A5149b03aDf9396C7C94D8B8F328FB36` |
| Guardian 3 (Charlie) | `0x4F0b7d0EaD970f6573FEBaCFD0Cd1FaB3b64870D` |

### 3.4 测试 AA 账户

| 账户 | Salt | 工厂 | 用途 |
|------|------|------|------|
| `0xBe9245282E31E34961F6E867b8B335437a8fF78b` | 800 | M7 | M7 E2E（ECDSA + ALG_WEIGHTED） |
| `0xfab5b2cf392c862b455dcfafac5a414d459b6dcc` | 701 | M5 | M6 E2E（ALG_WEIGHTED + Guardian Consent） |
| `0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32` | — | M5 | M5 COMBINED_T1 测试 |
| `0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC` | — | M5 | M5 ERC20_GUARD 测试 |
| `0x117C702AC0660B9A8f4545c8EA9c92933E6925d7` | 400 | M4 | 分级签名测试（3 个 guardian） |
| salt 200–203 | 200–203 | M4 | 社交恢复测试账户 |

---

## 4. 环境准备与部署

### 4.1 前置条件

```bash
pnpm install
forge --version    # 需要 Solc 0.8.33
forge build
```

### 4.2 环境变量（.env.sepolia）

```bash
SEPOLIA_RPC_URL=<Alchemy/Infura RPC URL>
PRIVATE_KEY=<部署者 EOA 私钥>
PRIVATE_KEY_BOB=<Guardian 1 私钥>
PRIVATE_KEY_JACK=<Guardian 2 私钥>

# 已部署地址
AIRACCOUNT_M6_R2_FACTORY=0xa3f03e9f6cde536a1b776162a9f0e462f2adbbbf
AIRACCOUNT_M6_R2_IMPL=0x3C866080C6AA37697AeA43106956369071d26600
FACTORY_ADDRESS=0xa3f03e9f6cde536a1b776162a9f0e462f2adbbbf
ENTRYPOINT_ADDRESS=0x0000000071727De22E5E9d8BAf0edAc6f37da032
```

### 4.3 部署新工厂

```bash
forge build
pnpm tsx scripts/deploy-m6-r2.ts
# Forge 在 macOS 有 transport 问题，统一用 TypeScript + viem 部署
```

M7 工厂构造参数：`(entryPoint, communityGuardian, tokens[], tokenConfigs[])`。
测试时 communityGuardian 传 `address(0)`，tokens 传空数组。

### 4.4 账户初始化后配置

```bash
# 1. 设置 P256 公钥（Passkey 用户）
account.setP256Key(x, y)

# 2. 设置加权签名配置（ALG_WEIGHTED 用户）
account.setWeightConfig({passkeyWeight, ecdsaWeight, ..., tier1Threshold, tier2Threshold, tier3Threshold})

# 3. 设置 DeFi Parser Registry（可选，DeFi 用户）
account.setParserRegistry(registryAddr)

# 4. 充值 EntryPoint（自付 gas 用户）
account.addDeposit{value: 0.1 ether}()

# 5. 注册 SessionKeyValidator（Session Key 用户）
validatorRouter.registerAlgorithm(0x08, sessionKeyValidatorAddr)
```

---

## 5. 标准 ERC-4337 交易流程

### 5.1 完整流程图

```
  User                 SDK / Bundler        EntryPoint           AA Account          Guard
  ────                 ─────────────        ──────────           ──────────          ─────
   │                        │                    │                    │                 │
   │ 1. 构建 UserOp          │                    │                    │                 │
   │ 2. 签名（ECDSA/P256）   │                    │                    │                 │
   │───────────────────────>│                    │                    │                 │
   │                        │ 3. handleOps([op]) │                    │                 │
   │                        │───────────────────>│                    │                 │
   │                        │                    │ 4. validateUserOp  │                 │
   │                        │                    │───────────────────>│                 │
   │                        │                    │  _validateSignature│                 │
   │                        │                    │  tstore(algId)     │                 │
   │                        │                    │  payPrefund        │                 │
   │                        │                    │<───────────────────│                 │
   │                        │                    │ 5. execute(dest,val,data)            │
   │                        │                    │───────────────────>│                 │
   │                        │                    │                    │ 6. _enforceGuard│
   │                        │                    │                    │────────────────>│
   │                        │                    │                    │  tier check     │
   │                        │                    │                    │  daily limit    │
   │                        │                    │                    │  algo whitelist │
   │                        │                    │                    │  token check    │
   │                        │                    │                    │<────────────────│
   │                        │                    │                    │ 7. _call(target)│
   │                        │                    │<───────────────────│                 │
   │                        │ 8. refund gas      │                    │                 │
   │                        │<───────────────────│                    │                 │
```

### 5.2 构建 UserOp（TypeScript + viem）

```typescript
import { encodeFunctionData, toHex, keccak256, concat } from 'viem';

// 1. 编码 callData
const callData = encodeFunctionData({
  abi: accountAbi,
  functionName: 'execute',
  args: [recipientAddress, amountInWei, '0x']
});

// 2. 获取 nonce
const nonce = await publicClient.readContract({
  address: ENTRYPOINT, abi: entryPointAbi,
  functionName: 'getNonce', args: [accountAddress, 0n]
});

// 3. 打包 gas 参数（v0.7 格式，两个 uint128 打包进 bytes32）
const accountGasLimits = toHex(
  (300_000n << 128n) | 100_000n,   // verificationGasLimit | callGasLimit
  { size: 32 }
);
const gasFees = toHex(
  (3_000_000_000n << 128n) | 2_000_000_000n,  // maxFeePerGas | maxPriorityFeePerGas
  { size: 32 }
);

// 4. 组装 UserOp
const userOp = {
  sender: accountAddress,
  nonce,
  initCode: '0x',
  callData,
  accountGasLimits,
  preVerificationGas: 60_000n,
  gasFees,
  paymasterAndData: '0x',   // 自付 gas 为空；Paymaster 为 72 字节
  signature: '0x'
};

// 5. 获取 hash 并签名（algId=0x02 ECDSA）
const userOpHash = await publicClient.readContract({
  address: ENTRYPOINT, abi: entryPointAbi,
  functionName: 'getUserOpHash', args: [userOp]
});
const ethHash = keccak256(concat([
  toHex(Buffer.from('\x19Ethereum Signed Message:\n32')),
  userOpHash
]));
const rawSig = await owner.sign({ hash: ethHash });
userOp.signature = concat(['0x02', rawSig]);  // algId 前缀

// 6. 提交
const txHash = await walletClient.writeContract({
  address: ENTRYPOINT, abi: entryPointAbi,
  functionName: 'handleOps',
  args: [[userOp], bundlerAddress]
});
```

### 5.3 各算法签名格式

| algId | 算法 | 签名格式 | 总长度 |
|:-----:|------|---------|:------:|
| `0x02` | ECDSA | `[0x02][r(32)][s(32)][v(1)]` | 66B |
| `0x03` | P256 Passkey | `[0x03][r(32)][s(32)]` | 65B |
| `0x04` | 累积 T2（P256+BLS） | `[0x04][P256_r(32)][P256_s(32)][blsPayload]` | 可变 |
| `0x05` | 累积 T3（+Guardian） | `[0x05][P256_r(32)][P256_s(32)][blsPayload][guardian_r(32)][s(32)][v(1)]` | 可变 |
| `0x06` | Combined T1 | `[0x06][P256_r(32)][P256_s(32)][ECDSA_r(32)][s(32)][v(1)]` | 130B |
| `0x07` | ALG_WEIGHTED | `[0x07][bitmap(1)][各分量按 bitmap 顺序]` | 可变 |
| `0x08` | Session Key | `[0x08][account(20)][key(20)][ECDSASig(65)]` | 106B |

---

## 6. 无 gas 交易流程（SuperPaymaster）

### 6.1 用户视角

1. **首次**：App 创建 Passkey → 部署 AA 账户 → 自动领取 SBT 和 aPNTs
2. **转账前**：余额中有 aPNTs（gas 代币）
3. **转账时**：点击"发送" → 指纹/面部确认 → 交易完成
4. **gas 费**：0 ETH，aPNTs 余额略微减少

### 6.2 底层流程

```
paymasterAndData = [SuperPaymaster(20B)][verifyGasLimit(16B)][postOpGasLimit(16B)][operator(20B)]

EntryPoint.handleOps
  → AA.validateUserOp（ECDSA 验证）
  → SuperPaymaster.validatePaymasterUserOp
      → 检查 SBT ✓
      → 检查 aPNTs 余额 ✓
      → 预锁定 aPNTs
  → AA.execute（实际转账）
  → SuperPaymaster.postOp
      → 按实际 gas 用量扣减 aPNTs
```

---

## 7. Gas 成本分析

### 7.1 实测数据（Sepolia，2026-03-20，ECDSA algId=0x02）

| 账户版本 | 空调用 | ETH 转账 | ERC20 转账 | 架构特点 |
|---------|-------:|---------:|----------:|---------|
| M5 COMBINED_T1 | 71,397 | 105,591 | **117,181** | 无 token tier 限额 |
| M5 ERC20_GUARD | 71,397 | 105,619 | **142,268** | token tier 全开 |
| M6 | 71,601 | 106,289 | **120,277** | 同 M5 架构，增加 ALG_WEIGHTED |
| M7 | 76,511 | 111,674 | **150,854** | EIP-1167 clone（+~4,000 gas 代理开销） |

> M7 比 M5/M6 多约 5,000 gas：EIP-1167 proxy 每次调用增加一次 DELEGATECALL（冷地址 2,600 gas + 栈帧开销）。批量打包多个 M7 账户 UserOp 时，后续账户自动受益（同一实现地址变 warm，降至 ~100 gas）。

### 7.2 各签名模式实测（M4，Sepolia）

| 签名模式 | Gas | TX Hash |
|---------|----:|---------|
| ECDSA（Tier 1） | 140,352 | [`0x13d9ef...`](https://sepolia.etherscan.io/tx/0x13d9ef74a12eeb97ad880b5d72e0be9abe44906534a69b270fcc36fff8b214d4) |
| P256+BLS（Tier 2） | 278,634 | [`0x28788d...`](https://sepolia.etherscan.io/tx/0x28788d7c03f96594e733224aedd14bd094036576683c3b8108264656ad76403d) |
| P256+BLS+Guardian（Tier 3） | 288,351 | [`0xb59d86...`](https://sepolia.etherscan.io/tx/0xb59d86c7df12b604ff3099a8fa04ed41c47e1339fea0fd0d6275c31cb499d648) |
| ALG_WEIGHTED P256+ECDSA（M7） | 94,712 | [`0x2f5d38...`](https://sepolia.etherscan.io/tx/0x2f5d384c76c740ed5b90cd3eb712d7eaf4e95c1c113e44b638bd1c2a060fbe91) |
| 无 gas（SuperPaymaster） | 181,067 | [`0xbf8296...`](https://sepolia.etherscan.io/tx/0xbf8296da54b567b8d4cd8153482e24273d1011458bb4d38b2515a51cb023b175) |

### 7.3 业界横向对比（ERC20 转账）

| 钱包 | Gas | Guard | 社交恢复 | 分级验证 |
|------|----:|:-----:|:-------:|:-------:|
| LightAccount (Alchemy) | ~110,000 | ✗ | ✗ | ✗ |
| SimpleAccount (Pimlico) | ~115,000 | ✗ | ✗ | ✗ |
| **AirAccount M5 (COMBINED_T1)** | **117,181** | ✓ | ✓ | ✓ |
| **AirAccount M6** | **120,277** | ✓ token | ✓ | ✓ |
| **AirAccount M5 (ERC20_GUARD)** | **142,268** | ✓✓ token+tier | ✓ | ✓ |
| Kernel (ZeroDev) | ~145,000 | 可选 | 可选 | ✗ |
| **AirAccount M7** | **150,854** | ✓✓ token+tier | ✓ | ✓ |
| Biconomy v2 | ~155,000 | ✗ | ✗ | ✗ |
| Safe (4337 module) | ~175,000 | ✗ | ✓ | ✗ |

### 7.4 部署成本（M7）

| 合约 | Gas | 说明 |
|------|----:|------|
| M7 工厂（含 implementation 部署） | 7,193,152 | 一次性，所有用户共享 |
| 账户创建（clone + guard + initialize） | ~1,542,000 | 每用户一次 |
| Guard 合约部署（含于账户创建） | ~480,000 | 每账户一次 |

---

## 8. 各核心功能详解

### 8.1 分级签名（累积模型）

| Tier | 适用金额 | 签名方式 | algId | 用户操作 |
|------|---------|---------|:-----:|---------|
| Tier 1 | ≤ tier1Limit（如 0.1 ETH） | ECDSA | `0x02` | 一键指纹 |
| Tier 2 | ≤ tier2Limit（如 1 ETH） | P256 Passkey + BLS DVT | `0x04` | 一键 + 后台 DVT |
| Tier 3 | > tier2Limit | P256 + BLS + Guardian 联署 | `0x05` | 一键 + DVT + Guardian 确认 |

**累积设计**：更高的 Tier 包含更低 Tier 的所有签名。用户不"切换模式"，系统按金额自动叠加验证要求。

### 8.2 ALG_WEIGHTED 加权多签（M6.1）

```
bitmap（1字节）：bit0=P256, bit1=ECDSA, bit2=BLS, bit3=guardian[0], bit4=guardian[1], bit5=guardian[2]

示例配置：
  passkeyWeight=2, ecdsaWeight=2, guardian*Weight=1
  tier1Threshold=3, tier2Threshold=4, tier3Threshold=6

  P256(2) + ECDSA(2) = 4 >= tier2Threshold → 等效 Tier 2
  ECDSA(2) 单独      = 2 < tier1Threshold  → 拒绝
```

### 8.3 Guard 支出保护

- `checkTransaction(value, algId)`：ETH 转账限额检查
- `checkTokenTransaction(token, amount, algId)`：ERC20 + DeFi swap 限额检查
- 单调安全：日限额只能降低，算法只能添加
- guard.account 不可变，绕不过

### 8.4 社交恢复

```
proposeRecovery(newOwner)  ← 任意 guardian 发起
approveRecovery()          ← 其他 guardian 投票（需 2-of-3）
                             2天时间锁等待
executeRecovery()          ← 任何人执行，owner 改为 newOwner

注意：owner 不能调用 cancelRecovery()（防私钥被盗后阻止恢复）
     取消需要 2-of-3 guardian 投票
```

### 8.5 Session Key（M6.4）

**ECDSA Session（DApp 服务端自动化）**：
```typescript
// 链下签名授权
const grantHash = await sessionKeyValidator.buildGrantHash(
  account, sessionKeyAddress, expiry, contractScope, selectorScope
);
const ownerSig = await owner.sign({ hash: grantHash });
await sessionKeyValidator.grantSession(account, sessionKey, expiry, scope, selector, ownerSig);

// 执行时签名格式：[0x08][account(20)][key(20)][ECDSA(65)] = 106 bytes
```

**P256 Session（用户 Passkey 自动化）**：
- 硬件绑定，无法导出私钥
- 验证通过 EIP-7212 P256VERIFY 预编译（0x100）
- 签名格式：`[0x08][account(20)][keyX(32)][keyY(32)][r(32)][s(32)]` = 149 bytes

两种 Session Key 共同约束：
- 最长 30 天到期
- contractScope + selectorScope 在执行阶段链上强制验证
- Tier 1 日限额同样适用
- owner 或账户本身可随时即时撤销

### 8.6 DeFi Calldata Parser（M6.6b）

解决 Uniswap 等 DeFi 协议 swap（value=0 的 token 转移）绕过 guard 的问题：

```
普通 ERC20：transfer(to, amount) → guard 原生识别
Uniswap swap：exactInputSingle({tokenIn, amountIn, ...}) → value=0，原生 guard 看不懂

CalldataParserRegistry[UniswapV3Router] = UniswapV3Parser
  → parseTokenTransfer(calldata) → (tokenIn, amountIn)
  → guard.checkTokenTransaction(tokenIn, amountIn, algId)
```

**信任假设**：Registry owner 在生产环境必须是 Gnosis Safe 多签（Phase 3）或 DAO（Phase 4），防止注册恶意 parser（返回小金额绕过限额）。

**治理路线**：
- Phase 1（当前）：单 EOA，开发/测试
- Phase 2：Timelock（48h 延迟），主网早期
- Phase 3：Gnosis Safe 3-of-5 + Timelock，成熟主网
- Phase 4：DAO 治理投票 + Timelock，完全去中心化

### 8.7 EIP-7702 AirAccountDelegate（M6.8，入门路径）

适用场景：用户有 MetaMask/硬件钱包，不想换地址，但想获得 AirAccount 保护。

**启用流程**：
```
Step 1: 发送 Type 4 tx（EIP-7702 授权）
  authorization_list = [{ chainId, AirAccountDelegate地址, nonce, 签名 }]
  → EOA code 变为 0xef0100 || AirAccountDelegate地址

Step 2: 发送 Type 2 tx（初始化，目标是自己的地址）
  调用 initialize(guardian1, g1sig, guardian2, g2sig, dailyLimit)
  → 两个 guardian 需提前签名表示接受
  → 部署 AAStarGlobalGuard 绑定到该 EOA
```

**紧急 Rescue 流程**（私钥泄露时）：
```
guardian1: initiateRescue(newSafeAddress)  → 2天时间锁开始
guardian2: approveRescue()                 → 达到 2-of-3
等待2天后任何人: executeRescue()            → 所有 ETH 转到 newSafeAddress
```

**重要限制**：
> EIP-7702 不会使私钥失效。Rescue 后攻击者仍持有私钥，可发起新的 EOA 交易。AirAccountDelegate 保护的是资产，不是密钥本身。建议发生安全事件后迁移到原生 AirAccountV7。

---

## 9. Validator 与 BLS 节点

### 9.1 algId 路由表

| algId | 算法 | 实现位置 | Tier |
|:-----:|------|---------|:----:|
| `0x01` | BLS12-381 聚合 | 外部合约（需注册） | 2/3 |
| `0x02` | ECDSA | 账户内联 | 1 |
| `0x03` | P256 Passkey | 账户内联 | 1 |
| `0x04` | 累积 T2（P256+BLS） | 账户内联 | 2 |
| `0x05` | 累积 T3（+Guardian） | 账户内联 | 3 |
| `0x06` | Combined T1（ECDSA+P256） | 账户内联 | 1 |
| `0x07` | ALG_WEIGHTED | 账户内联 | 可配置 |
| `0x08` | Session Key | 外部 SessionKeyValidator | 1 |

### 9.2 预编译依赖

| 预编译 | 地址 | EIP | 需要哪些功能 | 可用链 |
|--------|------|-----|------------|--------|
| P256VERIFY | `0x100` | EIP-7212 | Tier 2/3，P256，Combined T1 | Sepolia Pectra+，部分 L2 |
| BN_G1ADD | `0x0b` | EIP-2537 | BLS 聚合 | Sepolia Prague+ |
| BN_PAIRING | `0x0f` | EIP-2537 | BLS 聚合 | Sepolia Prague+ |

---

## 10. 测试套件

### 10.1 单元测试（Foundry）

```bash
forge test -vv          # 434 个测试，全部通过
forge test --summary    # 精简输出
```

### 10.2 Sepolia E2E 测试

| 脚本 | 测试数 | 命令 |
|------|:------:|------|
| M6 r2 E2E（clone factory + guard） | 12 | `pnpm tsx scripts/test-m6-r2-e2e.ts` |
| M6 Weighted + Guardian Consent | 5 | `pnpm tsx scripts/test-m6-weighted-e2e.ts` |
| 分级签名 | 5 | `pnpm tsx scripts/test-tiered-e2e.ts` |
| 社交恢复 | 5 | `pnpm tsx scripts/test-social-recovery-e2e.ts` |
| 无 gas | 1 | `pnpm tsx scripts/test-gasless-complete-e2e.ts` |
| 工厂验证 | 5 | `pnpm tsx scripts/test-factory-validation-e2e.ts` |
| Session Key | 5 | `pnpm tsx scripts/test-session-key-e2e.ts` |
| OAPD | 6 | `pnpm tsx scripts/test-oapd-e2e.ts` |
| Calldata Parser | 5 | `pnpm tsx scripts/test-calldata-parser-e2e.ts` |
| EIP-7702 Delegate | 1 | `pnpm tsx scripts/test-7702-delegate-e2e.ts` |
| **Gas Benchmark** | 4账户×3测试 | `pnpm tsx scripts/gas-benchmark.ts` |

### 10.3 测试结果汇总

**Foundry 单元测试**: 434/434 通过

**Sepolia E2E 关键结果**:

| 测试 | 结果 | Gas |
|------|:----:|----:|
| M7 clone factory 部署 | ✅ | 1,541,979 |
| M7 账户状态验证（owner/guard/guardian/limit/alg） | ✅ 8/8 | — |
| M7 ECDSA UserOp | ✅ | 76,487 |
| M7 ALG_WEIGHTED P256+ECDSA | ✅ | 94,712 |
| M6 ALG_WEIGHTED P256+ECDSA（Tier 2） | ✅ | 168,731 |
| Tier 1 ECDSA（0.005 ETH） | ✅ | 140,352 |
| Tier 2 P256+BLS（0.05 ETH） | ✅ | 278,634 |
| Tier 3 P256+BLS+Guardian（0.15 ETH） | ✅ | 288,351 |
| 社交恢复完整流程 | ✅ | ~555,000 |
| 无 gas（SuperPaymaster） | ✅ | 181,067 |

---

## 11. 已知限制

1. **非可升级**：Bug 修复需要新工厂部署 + 用户资产迁移。
2. **链兼容性**：P256（EIP-7212）和 BLS（EIP-2537）仅在 Pectra/Prague 后的链上可用。
3. **M7 clone 代理开销**：每次调用 +~4,000 gas（冷 DELEGATECALL），批量打包可降至 ~100 gas。
4. **AirAccountDelegate 功能子集**：约为 AirAccountV7 的 30%，仅 ECDSA + ETH guard + Guardian Rescue。
5. **7702 私钥风险**：EIP-7702 不撤销私钥，高价值用户最终应迁移到原生 AirAccountV7。
6. **CalldataParser 信任假设**：主网上线前 Registry owner 必须移交给 Gnosis Safe 多签。

---

## 12. 安全摘要

完整报告见 `docs/security-review.md` 和 `docs/audit_report_2026_03_19_comprehensive.md`。

| 维度 | 机制 |
|------|------|
| 架构 | 非可升级，原子部署，单调安全 |
| Guard | 不可变绑定，只收紧配置，ERC20 + DeFi tier 强制执行 |
| 恢复 | 2-of-3 阈值，2 天时间锁，owner 不能取消 |
| Session Key | 到期链上强制，即时撤销，Tier 1 限额适用 |
| OAPD | 确定性 salt 跨 DApp 地址隔离 |
| Parser | 只增不减注册，优雅 fallback，parser 只能收紧不能绕过 guard |
| 测试覆盖 | 434 单元测试 + 50 E2E 测试，覆盖所有关键路径 |
| 开放项 | Fuzz 测试，形式化验证，主网审计（计划中） |
