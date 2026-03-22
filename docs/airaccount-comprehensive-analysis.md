# AirAccount 综合分析报告 v1.0

> **版本**: v1.0
> **日期**: 2026-03-20
> **作者**: AAStar Team
> **状态**: 正式发布

---

## 目录

1. [里程碑功能清单与进度 (M1–M7)](#1-里程碑功能清单与进度-m1m7)
2. [技术演进路线图](#2-技术演进路线图)
3. [Gas 消耗对比分析](#3-gas-消耗对比分析)
4. [安全特性业界对比](#4-安全特性业界对比)
5. [业界竞品综合分析](#5-业界竞品综合分析)
6. [差距分析与优势总结](#6-差距分析与优势总结)
7. [发展目标与路线图](#7-发展目标与路线图)
8. [多链部署计划](#8-多链部署计划)

---

## 1. 里程碑功能清单与进度 (M1–M7)

AirAccount 遵循渐进式里程碑开发模式，每个里程碑在前一版本基础上叠加核心特性，同时保持 Sepolia 链上端到端（E2E）验证。

| 里程碑 | 版本 | 状态 | 核心算法 | 主要功能 | Factory 地址 | 代表性 Gas |
|--------|------|------|----------|----------|--------------|------------|
| **M1** | v0.10.x | ✅ 完成 | ALG_ECDSA(0x02) | 基础 ECDSA 钱包，ERC-4337 v0.6，单所有者，Sepolia E2E | `0x26Af...FAcD` | 523,306 (YetAA baseline) |
<<<<<<< HEAD
| **M2** | v0.11.x | ✅ 完成 | ALG_BLS(0x01), ALG_ECDSA(0x02), ALG_P256(0x04) | BLS 三重签名（ECDSA + P256/WebAuthn + BLS），Solc 0.8.33，DVT aggregator | `0x5Ba1...Afe04` | 259,694 (-50.4%) |
| **M3** | v0.12.x | ✅ 完成 | ALG_ECDSA(0x02) | 安全加固，2-of-3 Guardian 社交恢复，24h timelock，domain separation，fail-fast 验证 | `0xce42...206c1` | 127,249 (-75.7% vs M1) |
| **M4** | v0.12.5 | ✅ 完成 | ALG_ECDSA, ALG_P256, ALG_BLS | 累积签名分层安全（T1/T2/T3），DVT messagePoint 绑定，社交恢复 E2E，salt 寻址 | `0x914d...6d88` | T1: 140,352 / T2: 278,634 / T3: 288,351 |
| **M5** | v0.14.0 | ✅ 完成 | ALG_COMBINED_T1(0x06), ALG_ECDSA, ALG_P256, ALG_BLS | ERC20 守卫，治理锁，Guardian 接受签名，零信任 T1（P256 AND ECDSA），跨操作回放防护 | `0x1ffa...c3b9` | 280/280 测试通过 |
| **M6** | v0.15.x | ✅ 完成 | ALG_WEIGHTED(0x03), ALG_SESSION_KEY(0x08) | Session Key，CalldataParserRegistry，EIP-170 合规，加权多签，审计修复（HIGH+LOW），OAPD E2E | `r2: Sepolia 已部署` | T2 Weighted: 168,731 / 合约 20,900B |
=======
| **M2** | v0.11.x | ✅ 完成 | ALG_BLS(0x01), ALG_ECDSA(0x02), ALG_P256(0x03) | BLS 三重签名（ECDSA + P256/WebAuthn + BLS），Solc 0.8.33，DVT aggregator | `0x5Ba1...Afe04` | 259,694 (-50.4%) |
| **M3** | v0.12.x | ✅ 完成 | ALG_ECDSA(0x02) | 安全加固，2-of-3 Guardian 社交恢复，24h timelock，domain separation，fail-fast 验证 | `0xce42...206c1` | 127,249 (-75.7% vs M1) |
| **M4** | v0.12.5 | ✅ 完成 | ALG_ECDSA, ALG_P256, ALG_BLS | 累积签名分层安全（T1/T2/T3），DVT messagePoint 绑定，社交恢复 E2E，salt 寻址 | `0x914d...6d88` | T1: 140,352 / T2: 278,634 / T3: 288,351 |
| **M5** | v0.14.0 | ✅ 完成 | ALG_COMBINED_T1(0x06), ALG_ECDSA, ALG_P256, ALG_BLS | ERC20 守卫，治理锁，Guardian 接受签名，零信任 T1（P256 AND ECDSA），跨操作回放防护 | `0x1ffa...c3b9` | 280/280 测试通过 |
| **M6** | v0.15.x | ✅ 完成 | ALG_WEIGHTED(0x07), ALG_SESSION_KEY(0x08) | Session Key，CalldataParserRegistry，EIP-170 合规，加权多签，审计修复（HIGH+LOW），OAPD E2E | `r2: Sepolia 已部署` | T2 Weighted: 168,731 / 合约 20,900B |
>>>>>>> main
| **M7** | 计划中 | 🔲 规划 | ERC-7579 完整实现 | L2 多链部署，隐私层（Railgun/Kohaku），ERC-8004 Agent 身份，x402 支付，Agent Session Keys | 待部署 | 目标 500+ 测试 |

### M5 详细功能清单

| 功能 | 描述 | 审计状态 |
|------|------|----------|
| ALG_COMBINED_T1 (0x06) | P256 AND ECDSA 双因子，任一单独均不足 | ✅ 已审计 |
| ERC20 Token 分层守卫 | 每 token 独立 T1/T2/T3 阈值 + 每日上限 | ✅ |
| Guardian 接受签名 | 账户创建前链上验证 guardian 承诺 | ✅ |
| Governance 锁 | setupComplete 单向锁，防后门算法注入 | ✅ |
| messagePoint 绑定 | 绑定到 userOpHash，防跨操作回放 | ✅ |
| Factory 默认 Token 配置 | 工厂部署时设置默认 token 守卫参数 | ✅ |

### M6 详细功能清单

| 功能 | 描述 | 审计状态 |
|------|------|----------|
| ALG_WEIGHTED (0x03) | bitmap 配置权重阈值多签（P256+ECDSA） | ✅ 已修复 HIGH 审计项 |
| ALG_SESSION_KEY (0x08) | 时间限制委托签名，支持 P256 或 ECDSA | ✅ |
| SessionKeyValidator | grantSessionDirect / revokeSession，owner 可撤销 | ✅ |
| CalldataParserRegistry | 可插拔 DeFi calldata 解析（UniswapV3Parser） | ✅ |
| EIP-170 合规 | 账户合约 20,900B（限制 24,576B，有余量） | ✅ |
| 跨账户 Session Key 绑定 | sig[1:21] == address(this) 防跨账户重用 | ✅ HIGH 审计修复 |
| Parser try/catch | reverting parser 不阻塞 execute() | ✅ LOW 审计修复 |
| Packed Guardian Storage | 3 guardians 存储于 2 slots（原 3 slots） | ✅ gas 优化 |
| OAPD E2E 验证 | One-Account-Per-DApp 隔离模型链上验证 | ✅ |

---

## 2. 技术演进路线图

```
AirAccount 技术演进时间轴 (2025–2026)
══════════════════════════════════════════════════════════════════════════════

2025 Q1                    2025 Q2-Q3                 2025 Q4-2026 Q1
    │                           │                           │
    ▼                           ▼                           ▼

╔══════════╗            ╔══════════════╗            ╔══════════════════════╗
║    M1    ║──────────▶ ║   M2 + M3   ║──────────▶ ║     M4 + M5 + M6    ║
║ v0.10.x  ║            ║ v0.11-0.12  ║            ║   v0.12.5-v0.15.x   ║
╚══════════╝            ╚══════════════╝            ╚══════════════════════╝
    │                           │                           │
    │ • ERC-4337 v0.6           │ • M2: BLS 三重签名        │ • M4: 累积签名 T1/T2/T3
    │ • ECDSA 单签名            │ • P256 WebAuthn 支持      │ • DVT messagePoint 绑定
    │ • Sepolia E2E             │ • Solc 0.8.33 升级        │ • M5: ERC20 守卫
    │ • YetAA 523,306 gas       │ • M3: 安全加固            │ • 零信任 ALG_COMBINED_T1
    │                           │ • Guardian 社交恢复        │ • Governance 单向锁
    │                           │ • 24h timelock            │ • M6: Session Key
    │                           │ • Domain separation        │ • CalldataParser
    │                           │ • Gas: 127,249 (-75.7%)   │ • EIP-170 合规
    │                           │                           │ • 441/441 测试通过
    ▼                           ▼                           ▼

Gas:  523,306              127,249              140,352(T1) / 168,731(T2 Weighted)
Tests: —                   —                   441/441 ✅

══════════════════════════════════════════════════════════════════════════════

2026 Q2 目标 (M7)
    │
    ▼
╔════════════════════════════════════════════════════════════╗
║                          M7 (计划中)                       ║
║                          v0.16.x+                          ║
╚════════════════════════════════════════════════════════════╝
    │
    │ • ERC-7579 完整合规（installModule, executeFromExecutor）
    │ • L2 多链部署: OP Mainnet → Base → Arbitrum One
    │ • 隐私层: Railgun/Kohaku shielded pools
    │ • ERC-8004 Agent 身份标准
    │ • x402 HTTP 微支付协议集成
    │ • Agent Session Keys（AI 代理授权）
    │ • Code4rena 或 Immunefi 专业审计
    │ • 目标 500+ 测试用例
    ▼

关键设计原则演进:
┌─────────────────────────────────────────────────────────────┐
│ M1-M2: 功能验证期 — 确定多签名算法组合                        │
│ M3-M4: 安全加固期 — guardian 恢复 + 分层验证                  │
│ M5-M6: 工程完善期 — 守卫 + session key + 审计修复             │
│ M7:    扩张期    — 多链 + ERC-7579 + Agent 经济                │
└─────────────────────────────────────────────────────────────┘

签名算法演进:
  M1: [ECDSA]
  M2: [ECDSA | P256 | BLS]
  M4: [T1=ECDSA] [T2=P256+BLS] [T3=P256+BLS+Guardian]
  M5: [ALG_COMBINED_T1=P256∧ECDSA] [T2] [T3] + ERC20 Guard
  M6: [ALG_WEIGHTED=bitmap权重] [ALG_SESSION_KEY=时间限制] + Parser
  M7: [ERC-7579模块化] [Agent专属] [跨链统一]
```

---

## 3. Gas 消耗对比分析

### 3.1 AirAccount 内部里程碑 Gas 演进

下表展示 AirAccount 各里程碑在 Sepolia 链上的 E2E 验证 Gas 数据。

| 里程碑 | 操作类型 | Gas 消耗 | 相比 M1 变化 | 相比上一版本 |
|--------|----------|----------|--------------|--------------|
| M1 / YetAA Baseline | ECDSA UserOp 完整验证 | 523,306 | — | — |
| M2 | BLS 三重签名 UserOp | 259,694 | **-50.4%** | -50.4% |
| M3 | ECDSA 优化后 UserOp | 127,249 | **-75.7%** | -51.0% |
| M4 T1 | ECDSA 单因子 | 140,352 | -73.2% | +10.3%* |
| M4 T2 | P256 + BLS 双因子 | 278,634 | -46.7% | +119.0%* |
| M4 T3 | P256 + BLS + Guardian | 288,351 | -44.9% | +128.7%* |
| M6 T2 Weighted | P256 + ECDSA 加权多签 | 168,731 | -67.7% | vs T2: -39.4% |

> *M4 相比 M3 Gas 增加是因为 M4 引入了累积签名分层（T2/T3 需要多重签名），功能大幅增强。M6 T2 Weighted 相比 M4 T2 降低 39.4% 体现了工程优化效果。

### 3.2 与业界主流 AA 方案横向对比

注意: AirAccount 账户创建 Gas 高于简单账户，因为部署时包含 AAStarGlobalGuard（不可变支出限制），但运行时执行 Gas 具有竞争力。

| 方案 | 账户部署 Gas | ETH 转账 Gas | 特殊优势 | ERC-7579 | 审计状态 |
|------|-------------|-------------|----------|----------|----------|
| **EOA 基准** | N/A | 21,000 | 最低 gas | — | — |
| **Alchemy Light Account v2** | 145,887 | 69,068 | 最便宜部署，最多部署量（730万） | 部分 | 已审计 |
| **ZeroDev Kernel v3.1** | 148,553 | 67,700 | 最完整 ERC-7579，模块化 | ✅ 完整 | 已审计 |
| **Coinbase Smart Wallet** | 179,751 | 70,271 | Passkey 原生，Base 生态 | 部分 | 已审计 |
| **Biconomy Nexus** | 210,078 | ~73,000 | ERC-7579 参考实现，30+ 链 | ✅ 完整 | 已审计 |
| **Safe v1.4.x** | ~355,000 | ~107,000 | 最高 TVL（$100B+），最可信 | 部分 | 多次审计 |
| **ERC-4337 SimpleAccount** | 383,218 | 68,871 | 参考实现 | ❌ | 已审计 |
| **AirAccount M3 ECDSA** | ~2,947,710† | 127,249 | 非升级，分层安全，Guardian | ❌ | 内部审计 |
| **AirAccount M6 T1** | ~5,492,508‡ | ~140,352 | Session Key，Calldata Parser | 部分 | 内部审计 |

> †M3 账户创建包含 AAStarGlobalGuard 部署（不可变守卫合约）
> ‡M6 Factory 部署含 SessionKeyValidator + CalldataParserRegistry

**结论**: AirAccount 运行时 execution Gas（127,249 ~ 168,731）与业界头部方案（69,068 ~ 107,000）相差约 1.5-2.5x，主要来自额外安全特性开销（Guardian 验证、ERC20 守卫、Session Key 检查）。在 L2 上这些差异的美元成本几乎可以忽略不计。

### 3.3 各操作类型 Gas 分解

| 操作类型 | Gas 估算 | 来源 |
|----------|----------|------|
| ECDSA 签名验证 | ~45,000 | gas-analysis.md |
| P256/WebAuthn (EIP-7212 预编译) | ~40,000 | gas-analysis.md |
| BLS 三重验证 | ~207,000 | gas-analysis.md |
| 累积 T2 (P256 + BLS) | ~103,000 | gas-analysis.md |
| 累积 T3 (P256 + BLS + Guardian) | ~123,000 | gas-analysis.md |
| ERC-4337 EntryPoint 固定开销 | ~47,000–50,000 | 行业标准 |
| ERC20 守卫检查 | ~8,000–12,000 | 估算 |
| Session Key 验证额外开销 | ~15,000–20,000 | 估算 |
| Guardian 社交恢复提案 | ~80,000–100,000 | 估算 |
| Guardian 社交恢复执行 | ~60,000–80,000 | 估算 |

### 3.4 Layer 2 Gas 经济学

L2 上 Gas 成本已接近经济上可忽略。以下为不同网络的估算美元成本（基于典型 Gas Price）：

| 网络 | Gas Price | AirAccount T1 执行成本 | AirAccount T2 执行成本 | 说明 |
|------|-----------|----------------------|----------------------|------|
| Ethereum Mainnet | ~20 gwei | ~$5.60 | ~$9.50 | 较贵，不适合高频小额 |
| Sepolia Testnet | ~1 gwei | ~$0.003 | ~$0.005 | 测试网，近似免费 |
| OP Mainnet | ~0.001 gwei | **<$0.001** | **<$0.001** | 近乎免费 |
| Base Mainnet | ~0.001 gwei | **<$0.001** | **<$0.001** | 近乎免费 |
| Arbitrum One | ~0.01 gwei | **<$0.01** | **<$0.01** | 极低成本 |

> 注：以 ETH=$3,000 估算，实际价格随市场波动。L2 上 AA 的额外 Gas 开销（vs EOA）在美元成本上几乎为零，这是 M7 优先部署 L2 的核心原因。

---

## 4. 安全特性业界对比

下表对比 AirAccount 与业界主要 AA 钱包的安全特性覆盖情况。

| 安全特性 | AirAccount M6 | Safe v1.4 | ZeroDev Kernel v3 | Coinbase Smart Wallet | Argent |
|----------|:-------------:|:---------:|:-----------------:|:--------------------:|:------:|
| **非升级设计（无 proxy/无管理员密钥）** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **ECDSA 签名验证** | ✅ M1 | ✅ | ✅ | ✅ | ✅ |
| **WebAuthn / P256 Passkey** | ✅ M2 | ❌ | ✅ | ✅ | ❌ |
| **BLS 聚合签名** | ✅ M2 | ❌ | ❌ | ❌ | ❌ |
| **社交恢复（Guardian）** | ✅ M3 | ✅ (Module) | ✅ (Plugin) | ❌ | ✅ (2018年发明) |
| **Guardian 接受签名（链上承诺）** | ✅ M5 | ❌ | ❌ | ❌ | 部分 |
| **Timelock（社交恢复冷却期）** | ✅ 24h M3 | 部分 | 部分 | ❌ | ✅ |
| **Domain separation（跨链重放防护）** | ✅ M3 | ✅ | ✅ | ✅ | ✅ |
| **ERC20 Token 分层支出限制** | ✅ M5 | ❌ | ❌ (需插件) | ✅ (Spend Permissions) | ❌ |
| **零信任 T1（双因子必须同时满足）** | ✅ M5 ALG_COMBINED_T1 | ❌ | ❌ | ❌ | ❌ |
| **Governance 单向锁（防算法后注入）** | ✅ M5 | ❌ | ❌ | ❌ | ❌ |
| **跨操作 messagePoint 回放防护** | ✅ M5 | N/A | N/A | N/A | N/A |
| **Session Key（时间限制委托）** | ✅ M6 | ❌ (需插件) | ✅ Smart Sessions | ✅ | ❌ |
| **跨账户 Session Key 绑定防护** | ✅ M6 审计修复 | N/A | 未知 | 未知 | N/A |
| **Calldata Parser（DeFi 感知守卫）** | ✅ M6 | ❌ | ❌ | ❌ | ❌ |
| **不可变全局守卫（不可绕过支出限制）** | ✅ M3 | ❌ | ❌ | ❌ | ❌ |
| **OAPD 隔离模型** | ✅ M6 | ❌ | ❌ | ❌ | ❌ |
| **ERC-7579 完整模块化** | 部分 | 部分 | ✅ | 部分 | ❌ |
| **EIP-7702 EOA 委托** | ❌ M7 计划 | ❌ | 实验性 | ❌ | ❌ |
| **隐私层（Railgun/zkSNARK）** | ❌ M7 计划 | ❌ | ❌ | ❌ | ✅ (zkSync) |
| **专业外部审计** | 部分 (内部) | ✅ 多次 | ✅ | ✅ | ✅ |
| **Bug Bounty 计划** | ❌ | ✅ $2M | ✅ | ✅ | ✅ |

### 安全特性评分

| 方案 | 独特安全特性数量 | 核心优势 |
|------|----------------|----------|
| AirAccount M6 | 9（独有特性） | 非升级 + 零信任 T1 + Calldata Parser + OAPD |
| Safe v1.4 | 4 | 多次审计 + 最高 TVL + 企业级信任 |
| ZeroDev Kernel v3 | 3 | 最完整 ERC-7579 + Smart Sessions |
| Coinbase Smart Wallet | 3 | Spend Permissions + Passkey + Base 生态 |
| Argent | 3 | 社交恢复发明者 + zkSync + 时间锁 |

---

## 5. 业界竞品综合分析

### 5.1 EVM AA 钱包定位矩阵

```
                        安全性 / 去中心化
                              ▲
                              │
              AirAccount M6 ──┼── (高安全 + 研究阶段)
              (非升级,零信任)  │
                              │
    Safe ────────────────────┼──── (高安全 + 成熟生态)
    (企业多签,$100B TVL)      │
                              │
                              │  ZeroDev Kernel
                              │  (模块化 + 灵活)
                              │
─────────────────────────────┼──────────────────────────────▶ 易用性 / 生态
   最低←                     │                          →最高
                              │  Biconomy Nexus
                              │  (30+ chains)
                              │
                              │   Coinbase SW  Light Account
                              │   (Passkey)    (最便宜部署)
                              │
                              ▼
                         中心化风险
```

### 5.2 各竞品详细分析

#### Safe (Gnosis Safe)
- **定位**: 企业级多签钱包，最高 TVL（$100B+），最多外部审计
- **优势**: 7M+ 账户，$2M Bug Bounty，ERC-7579 Safe{Core}，最高信任度
- **劣势**: 部署成本高（~355,000 gas），升级历史带来风险，复杂度高
- **与 AirAccount 关系**: AirAccount 在安全哲学上与 Safe 最相近（保守设计），但 AirAccount 更激进地选择了非升级路径

#### ZeroDev Kernel v3
- **定位**: 最完整 ERC-7579 实现，模块化插件生态
- **优势**: Smart Sessions、Batched Calls、最低 ETH 转账 Gas（67,700）、丰富插件市场
- **劣势**: 模块化引入攻击面，复杂插件链难以审计
- **与 AirAccount 关系**: M7 ERC-7579 合规目标参考 Kernel 架构

#### Coinbase Smart Wallet
- **定位**: Base 生态原生钱包，Passkey 优先，ERC-7677 Paymaster
- **优势**: Spend Permissions、Passkey 无密码体验、Base 生态深度集成
- **劣势**: Base 链中心化依赖，功能范围较窄
- **与 AirAccount 关系**: AirAccount ERC20 Guard 与 Spend Permissions 功能重叠，但 AirAccount 不可升级且链无关

#### Biconomy Nexus
- **定位**: ERC-7579 参考实现，30+ 链部署，Smart Sessions
- **优势**: 最广泛 L2 支持，完整 ERC-7579，专注开发者体验
- **劣势**: 功能复杂度高，Gas 略高（~73,000 ETH 转账）
- **与 AirAccount 关系**: M7 多链部署将与 Biconomy 竞争开发者市场

#### Alchemy Light Account v2
- **定位**: 最便宜、最多部署量（730万账户）
- **优势**: 145,887 gas 部署，生态成熟，简单可靠
- **劣势**: 功能简单，无高级安全特性
- **与 AirAccount 关系**: 不直接竞争，AirAccount 面向安全需求更高的用户群

#### Argent
- **定位**: 社交恢复发明者（2018），zkSync Era 专注
- **优势**: 最成熟的社交恢复 UX，zkEVM 深度集成
- **劣势**: 生态局限于 zkSync，EVM 主链支持弱
- **与 AirAccount 关系**: AirAccount 的 Guardian 社交恢复参考了 Argent 设计，但在链上承诺机制上有创新

### 5.3 竞争优势分析

AirAccount 在以下维度具有明确竞争优势：

1. **非升级安全哲学**: 业界唯一坚持无 proxy、无管理员密钥、完全不可变的 AA 钱包，对安全性要求极高的用户（企业财库、DeFi 重度用户）有独特吸引力

2. **零信任 T1 (ALG_COMBINED_T1)**: P256 AND ECDSA 双因子同时要求，业界独有。解决了"单一密钥丢失导致资产全失"的根本问题

3. **DeFi 感知型守卫**: CalldataParserRegistry 允许智能合约理解交易语义（如 Uniswap swap 金额），而非仅检查 ETH 值，更精准防护

4. **Agent 经济就绪**: Session Key + OAPD + M7 计划中的 ERC-8004 Agent 身份，使 AirAccount 成为最早为 AI Agent 经济设计的 AA 钱包之一

5. **Guardian 链上承诺**: 账户创建前要求 guardian 链上签名承诺，防止 guardian 部署后反悔，业界少见

---

## 6. 差距分析与优势总结

### 6.1 技术差距（需要追赶）

| 差距项 | 当前状态 | 竞品现状 | 优先级 | 计划里程碑 |
|--------|----------|----------|--------|------------|
| ERC-7579 完整合规 | 部分实现（缺 installModule, executeFromExecutor） | Kernel、Nexus 已完整 | 高 | M7 |
| 多链部署 | Sepolia only | 竞品普遍 10-30+ 链 | 高 | M7 (OP→Base→Arbitrum) |
| EIP-7702 EOA 委托 | 未实现 | Kernel 实验性 | 中 | M7+ |
| 专业外部审计 | 内部审计 + AI 审计 | 竞品均有 Code4rena/Trail of Bits | 高 | M7（Code4rena 或 Immunefi） |
| ERC-7677 Paymaster 集成 | 未完整 | Coinbase、Biconomy 已集成 | 中 | M7 |
| 账户创建 Gas 优化 | ~2.9M-5.5M（含守卫部署） | 竞品 145K-355K | 低* | 架构约束，非优先 |
| 隐私层 | 未实现 | Argent (zkSync)、Railgun 独立 | 中 | M7 |
| 浏览器插件 / 移动 App | 无（合约层仅） | Safe、Argent、Coinbase 均有 | 低 | M8+ |

> *AirAccount 更高的账户创建 Gas 是架构设计决策（部署不可变守卫），不是技术缺陷。

### 6.2 设计优势（领先特性）

| 优势项 | AirAccount | 竞品 | 描述 |
|--------|------------|------|------|
| 非升级设计 | ✅ 核心原则 | 均使用 proxy | 最强信任保证，无管理员密钥风险 |
| ALG_COMBINED_T1 | ✅ 独有 | 无 | P256 ∧ ECDSA 真正双因子零信任 T1 |
| Governance 单向锁 | ✅ 独有 | 无 | setupComplete 防后门算法注入 |
| Guardian 链上承诺 | ✅ 独有 | 无同等机制 | 账户创建前验证 guardian 意愿 |
| Calldata Parser Registry | ✅ 独有 | 无（需链下） | DeFi 协议感知型链上守卫 |
| OAPD 隔离模型 | ✅ 独有 | 无 | One-Account-Per-DApp 最小权限暴露 |
| ERC20 Token 分层守卫 | ✅ M5 | Coinbase Spend Permissions（类似） | Token 级别 T1/T2/T3 + 每日上限 |
| messagePoint 跨操作回放防护 | ✅ M5 | 标准 nonce 但无 DVT 绑定 | DVT 节点 messagePoint 绑定 userOpHash |

### 6.3 市场定位差距

| 维度 | AirAccount | 目标状态 |
|------|------------|----------|
| **品牌认知度** | 学术/研究圈内 | M7 后开发者社区可见 |
| **生态集成** | Sepolia 独立运行 | M7 后接入 Pimlico/Alchemy Bundler |
| **TVL** | $0 (未主网上线) | M7 后目标小规模验证 |
| **开发者文档** | 内部文档为主 | M7 后需公开 SDK 文档 |
| **社区规模** | AAStar 核心团队 | 目标 M7 后开放贡献 |

---

## 7. 发展目标与路线图

### 7.1 短期目标 (M7, 2026 Q2)

**核心技术目标**:

| # | 目标 | 描述 | 优先级 |
|---|------|------|--------|
| M7.1 | ERC-7579 完整合规 | 实现 installModule, executeFromExecutor, executeFromModule | P0 |
| M7.2 | OP Mainnet 部署 | 第一个 L2 主网上线，完整 E2E 验证 | P0 |
| M7.3 | Base Mainnet 部署 | 第二 L2，ERC-7677 Paymaster 集成 | P0 |
| M7.4 | Arbitrum One 部署 | 第三 L2 | P1 |
| M7.5 | Code4rena 公开审计 | 提交到 Code4rena 或 Immunefi 竞赛审计 | P0 |
| M7.6 | 500+ 测试用例 | 覆盖所有分支，fuzzing 测试 | P1 |
| M7.7 | ERC-8004 Agent 身份 | Agent 钱包身份标准支持 | P1 |
| M7.8 | x402 HTTP 支付 | AI Agent 微支付协议集成 | P1 |
| M7.9 | Agent Session Keys | AI 代理专属权限委托 | P1 |
| M7.10 | 隐私层集成 | Railgun/Kohaku shielded pool 接口 | P2 |
| M7.11 | EIP-7702 支持 | EOA 委托兼容 | P2 |
| M7.12 | ERC-7677 完整集成 | Paymaster 标准完整支持 | P2 |

**测试目标**:
- 当前: 441/441 测试通过 (M6)
- M7 目标: 500+ 测试，包含 fuzzing 和 formal verification

### 7.2 中期目标 (2026 H2)

| 目标 | 描述 |
|------|------|
| **PolicyRegistry** | DVT 验证器去中心化 Paymaster 验证注册表 |
| **MushroomDAO 治理** | 将 AirAccount 协议治理迁移至 MushroomDAO |
| **SDK 发布** | TypeScript/viem SDK，开发者可直接集成 |
| **Mainnet 首次部署** | 以太坊主网小规模验证（监控模式） |
| **"Am I Dead?" 系统** | AI + DVT 链上遗嘱执行系统（长期愿景之一） |
| **跨链账户抽象** | 统一账户地址跨多条 L2 |

### 7.3 长期愿景

AirAccount 的长期愿景是成为 **AI 代理经济时代的基础设施钱包**——

1. **安全哲学引领**: 证明非升级、零信任、不可变设计可以在用户体验和安全性之间取得平衡

2. **Agent Economy 基础设施**: 随着 AI Agent 大规模上链，AirAccount 的 Session Key + OAPD + Agent Identity 架构成为 Agent 钱包的参考标准

3. **学术贡献**: 将 AirAccount 的创新设计（ALG_COMBINED_T1、Calldata Parser、Guardian 链上承诺）整理为学术论文，提交 DSR 方法论框架下的研究成果

4. **Mycelium Protocol 节点**: AirAccount 作为 Mycelium Protocol 去中心化协作网络的钱包基础层

```
长期生态愿景:
┌─────────────────────────────────────────────────────────────┐
│                    AirAccount Ecosystem                      │
│                                                             │
│  AirAccount ──── PolicyRegistry ──── MushroomDAO           │
│       │                │                    │               │
│  Agent Session   DVT Paymaster        Community            │
│  Keys (M7)       Verification         Governance           │
│       │                │                    │               │
│  x402 微支付     去中心化 Gas 代付      OpenPNTs/             │
│  AI Agent 钱包   防Pimlico垄断          HyperCapital         │
│       │                                    │               │
│  "Am I Dead?"  ──────────────────────  遗嘱系统            │
│  AI + DVT 验证                        链上资产继承           │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. 多链部署计划

### 8.1 Sepolia (已完成 M6)

所有 M1-M6 里程碑均已在 Sepolia 测试网完成链上 E2E 验证。

| 合约 | 地址 | 里程碑 |
|------|------|--------|
| YetAA Validator | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` | YetAA |
| YetAA Factory | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` | YetAA |
| AirAccount M1 Factory | `0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f` | M1 |
| AirAccount M1 Account | `0x08923CE682336DF2f238C034B4add5Bf73d4028A` | M1 |
| AirAccount M2 BLS Algo | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | M2 |
| AirAccount M2 Router | `0x730a162Ce3202b94cC5B74181B75b11eBB3045B1` | M2 |
| AirAccount M2 Factory | `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` | M2 |
| AirAccount M2 Account (salt=1) | `0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07` | M2 |
| AirAccount M3 Factory | `0xce4231da69015273819b6aab78d840d62cf206c1` | M3 |
| AirAccount M3 Account | `0x4bFf3539b73CA3a29d89C00C8c511b884211E31B` | M3 |
| AirAccount M4 Factory | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | M4 |
| AirAccount M4 Tiered Account | `0x117C702AC0660B9A8f4545c8EA9c92933E6925d7` | M4 |
| AirAccount M5 Factory | `0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9` | M5 |
| AirAccount M6 Factory (r2) | 已部署 Sepolia，待补充完整地址 | M6 |

### 8.2 OP Mainnet 部署计划

**目标**: M7 首个 L2 主网部署，验证 AirAccount 在低 Gas 环境的经济模型

**准备步骤**:

1. **环境配置**:
   ```bash
   # .env 需要添加:
   OP_MAINNET_RPC_URL=https://mainnet.optimism.io
   # PRIVATE_KEY 与 Sepolia 共用
   ```

2. **部署脚本**: 基于 `scripts/deploy-m6-r2.ts` 修改，targeting OP chain (chainId: 10)
   ```typescript
   const chain = optimism; // viem chain definition
   const client = createPublicClient({ chain, transport: http(process.env.OP_MAINNET_RPC_URL) });
   ```

3. **合约验证**: 使用 Etherscan OP 验证（`https://api-optimistic.etherscan.io`）

4. **E2E 验证**: 重新运行完整 441 测试套件指向 OP Mainnet RPC

5. **Gas 预算估算**（基于 M6 数据）:
   - Factory 部署: 5,492,508 gas × ~0.001 gwei = **~$0.016**（极低成本）
   - Account 创建: ~2,947,710 gas × ~0.001 gwei = **~$0.009**
   - UserOp 执行: ~140,352 gas × ~0.001 gwei = **~$0.0004**

**关键检查项**:
- [ ] EIP-170 合规（已满足，20,900B < 24,576B）
- [ ] EIP-7212 P256 预编译（OP Mainnet 已支持）
- [ ] ERC-4337 EntryPoint v0.6 部署在 OP（`0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789`）
- [ ] BLS12-381 预编译兼容性验证（EIP-2537）

### 8.3 Base Mainnet 部署计划

**目标**: M7 第二 L2，优先集成 ERC-7677 Paymaster（Coinbase 生态）

**特殊考量**:
- Base 是 Coinbase Smart Wallet 主场，需要差异化定位
- 可接入 Pimlico Paymaster（Base 支持）或 Coinbase Paymaster
- ERC-7677 `pm_getPaymasterData` 接口集成

**部署步骤**: 与 OP 类似，修改 chain 为 `base`（chainId: 8453）

```bash
BASE_MAINNET_RPC_URL=https://mainnet.base.org
# 或使用 Alchemy Base RPC
```

### 8.4 部署地址汇总（规划）

| 网络 | 状态 | Factory 地址 | 预期部署时间 |
|------|------|-------------|------------|
| Sepolia | ✅ M6 完成 | 见 8.1 详表 | 已完成 |
| OP Mainnet | 🔲 M7 计划 | 待部署 | 2026 Q2 |
| Base Mainnet | 🔲 M7 计划 | 待部署 | 2026 Q2 |
| Arbitrum One | 🔲 M7 计划 | 待部署 | 2026 Q3 |
| Ethereum Mainnet | 🔲 M8+ | 待部署 | 2026 Q4+ |

---

## 附录 A: 合约规格汇总

| 合约 | Solidity 版本 | EVM 目标 | 优化 Runs | Via-IR | EIP-170 合规 |
|------|--------------|----------|-----------|--------|-------------|
| AAStarAirAccountV7 | 0.8.33 | Cancun | 10,000 | ✅ | ✅ (20,900B) |
| AAStarAirAccountFactoryV7 | 0.8.33 | Cancun | 10,000 | ✅ | ✅ (9,527B) |
| SessionKeyValidator | 0.8.33 | Cancun | 10,000 | ✅ | ✅ |
| CalldataParserRegistry | 0.8.33 | Cancun | 10,000 | ✅ | ✅ |
| UniswapV3Parser | 0.8.33 | Cancun | 10,000 | ✅ | ✅ |

## 附录 B: 关键 E2E 交易记录

| 里程碑 | 交易哈希 | 说明 |
|--------|---------|------|
| M1 | `0x8bb1b199f427dfc49e5fe40f2f3278cb1a48587824b78263051c8c4d81d77a81` | AirAccount V7 首次 E2E |
| M2 BLS | `0xf60f05f044a1b0a6d2922b3e4b2284d828b5a09b9c2452fe102af8f1eb0c10ff` | BLS 三重签名 E2E，Gas 259,694 |
| M3 Security | `0x912231d667b6c27a675ce0ebc08828a5d4aa13402423a6cd475b828d7df7a56a` | 安全加固后 E2E，Gas 127,249 |

---

*本报告基于截至 2026-03-20 的代码库状态生成，数据来源于链上 E2E 验证记录、gas-analysis.md 及 DSR 竞品研究。*
