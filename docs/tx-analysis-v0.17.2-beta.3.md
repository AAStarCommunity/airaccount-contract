# AirAccount v0.17.2-beta.3 — E2E TX 分析报告

**测试日期**: 2026-06-11 ~ 2026-06-12  
**网络**: Ethereum Sepolia  
**脚本**: `scripts/e2e-v0172/08~12-*.ts`  
**总 TX 数**: 45 笔链上 TX（全部 status=0x1）  
**Codex 独立验证**: 9 笔代表性 TX 全部确认为真实上链交易

---

## Codex 独立验证结果

Codex 通过 `eth_getTransactionReceipt` 验证了跨 Phase 08-12 的 9 笔代表性 TX：

| # | Phase / 操作 | TX Hash (前10位) | gasUsed | 结论 |
|---|---|---|---|---|
| 1 | Phase08 — createAccount (no guard) | `0xc20ed89b…` | 229,947 | ✅ REAL |
| 2 | Phase08 — createAgentAccount | `0x51fa3bee…` | 1,174,821 | ✅ REAL |
| 3 | Phase09 EX.1 — createAccountWithDefaults | `0xf87e267c…` | 1,198,077 | ✅ REAL |
| 4 | Phase10 — createAccountWithDefaults | `0x1f91ffe7…` | 1,198,077 | ✅ REAL |
| 5 | Phase10 — grantSession (DApp flow+sig) | `0x81b7176d…` | 99,375 | ✅ REAL |
| 6 | Phase11 — createAccountWithDefaults | `0x14fba9e5…` | 1,198,077 | ✅ REAL |
| 7 | Phase11 — installModule (ForceExitModule) | `0x0dd5d863…` | 97,114 | ✅ REAL |
| 8 | Phase11 — uninstallModule (2×guardian sig) | `0xb66593ac…` | 76,306 | ✅ REAL |
| 9 | Phase12 — UserOp via Pimlico bundler | `0x69b8ac8c…` | 105,676 | ✅ REAL — from=Pimlico bundler `0x4337…` |

**注**: TX9 的 `from` 为 Pimlico bundler 地址（`0x4337…` 前缀是 Pimlico 的标识），`to` 为 EntryPoint v0.7。Factory 地址与 `.env.sepolia` 中 `AIRACCOUNT_V0172_BETA_FACTORY` 完全一致。

---

## TX 分类与 AirAccount 功能对应

### 类型 1：账户创建 TX（Factory → per-account clone）

| 函数 | 典型 gas | AirAccount 功能 |
|------|---------|----------------|
| `createAccount(owner, salt, InitConfig)` | ~230k | 最小化创建：指定 owner + 可选 guard。`dailyLimit=0` 时不部署 AAStarGlobalGuard，适合 bundler/agent 账户 |
| `createAccountWithDefaults(owner, salt, g1, sig1, g2, sig2, dailyLimit)` | ~1.19M | 完整创建：3 guardian + guard + 日限额，guardian 离线预签 acceptance sig，一次 TX 完成所有部署 |
| `createAgentAccount(owner, salt, agentWallet, ...)` | ~1.17M | Agent 专属：自动安装 SessionKeyValidator（algId 0x08），绑定 AgentRegistry，factory-provenance 白名单 |

**为什么 `createAccountWithDefaults` gas 这么高？**  
单次 TX 同时完成：主账户 clone 部署 + `AAStarGlobalGuard`（per-account 合约）初始化 + 3 个 guardian 写入 + guard 注册到账户 storage。

---

### 类型 2：执行 TX（account → 任意目标）

| 函数 | 典型 gas | AirAccount 功能 |
|------|---------|----------------|
| `execute(to, value, calldata)` | 50–90k | 单笔调用：owner ECDSA 签名，guard 检查日限额 + ERC20 token 限额 + 算法白名单 |
| `executeBatch(calls[])` | ~53k | 批量调用：每次调用独立走 guard，不跨 call 累积限额 |
| `addDeposit(amount)` | ~60k | 向 EntryPoint 充值预付 gas（self-paying UserOp 前置步骤） |

**guard 校验链**: `execute` → `_enforceGuard(algId)` → 检查 `approvedAlgorithms[algId]` → 检查 `dailyLimitUsed + value ≤ dailyLimit` → 检查 ERC20 token limits。每笔 execute 都走这条链。

---

### 类型 3：Session Key TX（algId 0x08）

| 函数 | 典型 gas | AirAccount 功能 |
|------|---------|----------------|
| `grantSessionDirect(sessionPubKey, policy)` | ~70k | Owner 直接授权：时限 + callTargets + selectorAllowlist + velocity 速率限制 |
| `grantSession(sessionPubKey, policy, ownerSig)` | ~99k | DApp 流程：DApp 构造请求，用户在客户端签名，DApp 提交（无需用户自己发 TX）|
| `grantP256SessionDirect(p256PubKey, policy)` | ~70k | WebAuthn passkey 版：session key 是 P-256 公钥，硬件绑定，指纹授权 |
| `revokeSession(sessionId)` | ~60k | 吊销：基于 nonce，历史 grant sig 立即失效 |

**Session Key 的核心价值**: DApp 代理用户在受限范围内操作（callTargets + selectorAllowlist + velocity 笼子），不需每次用户签名——但 DApp 无法突破这些限制去做其他操作。Agent 账户用同一套机制实现自主操作权限。

---

### 类型 4：Guardian / 社会恢复 TX

| 函数 | 典型 gas | AirAccount 功能 |
|------|---------|----------------|
| `proposeRecovery(newOwner)` | ~107k | Guardian 提议换 owner：写入 `activeRecovery` 状态，启动 72h timelock |
| `approveRecovery()` | ~39k | 第 N 个 guardian 审批：`approvalBitmap` 第 N 位置 1，2/3 达到阈值后 timelock 开始倒计时 |
| `cancelRecovery()` | 52k / 41k | Guardian 投票取消：需 2/3 guardian 投 cancel，**不是 owner 决定**（防私钥泄露后攻击者取消恢复） |
| `installModule(typeId, module, initData)` | ~97k | ERC-7579 模块安装：owner 发起 + guardian 签名 initData 作授权（防止恶意模块安装） |
| `uninstallModule(typeId, module, deInitData)` | ~76k | 模块卸载：`deInitData` = `sig1 ‖ sig2`（130 bytes，min(guardianCount, 2) 个 guardian 联名） |

**关键设计**: guardian 签名域分离，每个操作用不同的域哈希，防止跨操作签名重放。

---

### 类型 5：ERC-4337 UserOp TX（via Bundler）

这类 TX 不直接由 owner EOA 发出，由 bundler（如 Pimlico）代发：

| 步骤 | 调用方 | 内容 |
|------|--------|------|
| `pimlico_getUserOperationGasPrice` | 客户端 | 查询当前 Sepolia oracle 费用（必须用 oracle，不能固定值）|
| `eth_estimateUserOperationGas` | 客户端 → Pimlico | 估算 callGasLimit / verificationGasLimit / preVerificationGas |
| `EntryPoint.getUserOpHash(packedUserOp)` | 链上 readContract | 计算链上 hash（必须用 packed 格式：`accountGasLimits` + `gasFees` 为 bytes32）|
| 签名 `userOpHash` | 客户端 | `signMessage({ raw: userOpHash })`，走 EIP-191（合约 `_validateECDSA` 内部加 prefix）|
| `eth_sendUserOperation` | 客户端 → Pimlico | bundler 打包提交，from=Pimlico EOA，to=EntryPoint，gas 从账户 EntryPoint 存款扣 |
| `eth_getUserOperationReceipt` | 客户端（轮询） | 等待 bundler 确认，返回 bundledTxHash |

**与直接 execute 的区别**:
- 直接 execute：owner EOA 发 TX，自己付 gas（ETH 从 EOA 钱包扣）
- UserOp：bundler 发 TX，gas 从账户在 EntryPoint 的预充值扣，或由 Paymaster 代付
- 这是 ERC-4337 "账户抽象"的核心：把 TX 发送者（bundler）和 gas 支付者（account/paymaster）分离

---

## Phase 08-12 完整测试结果摘要

| Phase | 功能域 | 测试数 | 通过 |
|-------|--------|--------|------|
| 08 | 多类型账户创建（createAccount / createAgentAccount / createAccountWithDefaults） | 8 | 8 ✅ |
| 09 | Execute 变体（ETH 转账 / executeBatch / addDeposit / revert 场景） | 10 | 10 ✅ |
| 10 | Session Key（grant ECDSA / grant P256 / grantSession DApp flow / revoke） | 11 | 11 ✅ |
| 11 | Guardian 社会恢复 + ERC-7579 模块 install/uninstall | 12 | 12 ✅ |
| 12 | ERC-4337 UserOp via Pimlico（self-paying）| 4 | 4 ✅ |
| **合计** | — | **45** | **45 ✅** |

详细每测试 TX hash 见 [`docs/e2e-results-v0.17.2-beta.3.md`](e2e-results-v0.17.2-beta.3.md)。  
调试踩坑记录见 [`docs/e2e-v0172-beta3-pitfalls-and-results.md`](e2e-v0172-beta3-pitfalls-and-results.md)。

---

## 关键发现：带 guard 账户与 Pimlico bundler 不兼容

见 [`docs/pimlico-bundler-compatibility.md`](pimlico-bundler-compatibility.md)（单独深析）。

简述：AirAccount 用 EIP-1153 瞬态存储传递 `algId`（validate→execute），但 Pimlico 的 gas 估算把 validateUserOp 和 execute 拆成两次独立 `eth_call`，两次调用之间瞬态存储清零，guard 收到 `algId=0` → 拒绝。在真实链上 TX（`handleUserOps`）中不存在此问题，但 Pimlico 预提交估算阶段就会 revert。

生产用途的 bundler 兼容性需要修改 `algId` 传递机制（不依赖瞬态存储），或选用支持合并 validate+execute 模拟的 bundler。
