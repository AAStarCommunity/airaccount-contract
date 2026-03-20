# AirAccount M6 — 技术路线决策记录

**决策时间**: 2026-03-20
**依据资料**: DSR-Research-Flow/research/EIP/ + research/wallet/ (437个账户相关EIP分析、AA生态数据、竞争格局)
**分支**: M6
**决策者**: Jason (CMU PhD) + Claude Code

> 本文档记录 2026-03-20 基于以太坊路线图研究做出的关键技术决策，供未来追溯参考。

---

## 背景：研究依据

| 文档 | 关键数据 |
|------|---------|
| `ethereum-account-evolution.md` | 437个账户相关EIP，EIP-7702(Pectra 2025-05-07激活)，EIP-7951(Fusaka 2025-12-03激活)，后量子EIP(8051/7619/7932)全部被Glamsterdam拒绝 |
| `report-2-aa-technical-comparison.md` | ZeroDev Kernel、Safe、Biconomy Nexus均已支持EIP-7702；ERC-7579成为模块化AA标准 |
| `report-3-signature-quantum-analysis.md` | ML-DSA(FIPS 204)、Falcon512(FIPS 206)推迟至2028+；Falcon-512 calldata比secp256k1大37倍 |
| `report-4-aa-ecosystem-data.md` | 4337月操作量峰值~4500万次；7702激活后4337量下降约22%，仍是主流；Pimlico占50%市场份额 |
| `report-5-security-analysis.md` | Bybit $15亿损失(2025-02)；EIP-7702有7种新攻击面；私钥有效性问题是7702核心风险 |
| `05_evm_aa_analysis.md` | 行业空白：去中心化Paymaster、Guardian集成Paymaster、紧急恢复Gas |
| `07_competitive_analysis.md` | Pimlico/Alchemy全部中心化SaaS；SuperPaymaster去中心化路线是唯一明确差异化 |

---

## 决策一：升级策略 — 不采用任何 Proxy 方案

**决策**: 维持现有非升级设计。不引入 UUPS、Transparent Proxy、Beacon Proxy、Diamond Pattern。

**理由**:
1. 对钱包合约，Proxy 升级机制本身即是最大攻击面。Owner 可随时换逻辑 = 用户资产安全依赖于 Owner 的善意
2. Beacon Proxy 更危险：一次升级批量影响所有用户
3. Bybit $15亿损失(2025-02)的根因即多签升级机制被绕过
4. AirAccount 当前 Factory 版本化 + 用户主动迁移 = 最诚实的信任假设

**否决方案**:

| 方案 | 否决理由 |
|------|---------|
| UUPS | Owner可随时换逻辑，用户被迫信任Owner |
| Beacon Proxy | 批量升级风险，一个私钥控制所有账户 |
| Diamond (EIP-2535) | 复杂度过高，facet管理引入新攻击面 |
| 无门控proxy | 等同于无安全保障 |

**采用方案**: Factory 版本注册 + 用户主动迁移（现状，继续执行）

---

## 决策二：中期引入 ERC-7579 模块化兼容层

**决策**: M6 阶段在 `AAStarAirAccountBase` 添加 ERC-7579 最小兼容接口，**不重写**现有逻辑。

**理由**:
1. ZeroDev Kernel、Safe、Biconomy Nexus 均已使用 ERC-7579，生态工具（paymaster SDK、session key wizard）开始依赖该接口
2. 添加兼容层不改变安全模型，只是让外部工具可以对话
3. 完整 7579 合规可推迟到 M7，M6 做最小 shim（~80 LOC）

**实施范围（M6）**:
- `accountId()` → `"airaccount.v7@0.15.0"`
- `supportsModule(moduleTypeId)` → validators(1), executors(2)
- `isModuleInstalled(1, module, "")` → `module == address(validator)`
- `installModule(1, module, "")` → map to `setValidator(module)`
- `supportsInterface(bytes4)` for ERC-165

**完整 7579 合规（M7）**: 模块替换需 owner + 1 guardian 2-of-2 多签，RecoveryModule 锁定不可卸载，模块替换 48h timelock

---

## 决策三：EIP-7702 作为 EOA 用户入口桥（M6-7702 分支）

**决策**: 独立分支 `M6-7702` 实现 `AirAccountDelegate.sol`，完成后合并回 M6。

**理由**:
1. Pectra 已于 2025-05-07 激活，MetaMask/Coinbase/ZeroDev/Safe 均已生产支持 7702
2. 现有 150M+ EOA 用户（MetaMask、Rainbow 等）可通过 Type 4 交易委托到 AirAccount 实现，**地址不变**
3. 不做 7702 = 错过最大存量用户入口，AirAccount 只能服务新建账户用户

**7702 核心风险（已知，接受）**:
- 私钥有效性问题：私钥泄露可重置委托。因此 7702 更适合入口用途，长期高价值用户应迁移到原生 AirAccount
- 委托重置攻击：用签名 EOA 发 Type 4 tx 覆盖委托
- 缓解措施：guardian 接受签名 + 初始化锁，防止单点委托攻击

**技术选型**: `AirAccountDelegate` 独立合约，不继承 `AAStarAirAccountBase`，使用 ERC-7201 namespaced storage，重用 `AAStarGlobalGuard`

---

## 决策四：后量子签名 — 预留接口，近期不实现

**决策**: 不在 M6/M7 实现后量子签名。当前 `IAAStarAlgorithm` 接口已经是未来替换通道。

**理由**:
1. EIP-8051(ML-DSA)、EIP-7619(Falcon512)、EIP-7932 全部被 Glamsterdam **拒绝**，时间线推迟至 2028+
2. Falcon-512 calldata 比 secp256k1 大 37 倍，gas 成本极高
3. 市场和生态均未准备好

**实施**: 在 `docs/quantum-migration-path.md` 记录 BLS → ML-DSA 的迁移接口约定，无需代码变更

---

## 决策五：Native AA (EIP-7701) — 不依赖

**决策**: 不等待、不依赖 EIP-7701。

**理由**: EIP-7701 状态为 Stagnant，2027+ 且不确定。Vitalik 明确表示 ERC-4337 已足够好，7701 不是优先级。

---

## AirAccount 战略评估结论

### 已验证正确的选择

| 选择 | 验证事件 |
|------|---------|
| 非升级 + 社会恢复 | Bybit $15亿(2025-02)：升级机制是最大攻击面 |
| P256/WebAuthn | Fusaka(2025-12-03)激活 EIP-7951，AirAccount 已领先市场 |
| 去中心化 Paymaster | Pimlico 50%市场份额，全中心化 SaaS，差异化成立 |
| ERC-4337 v0.7 | 7702激活后仍是主流，月操作量仅降22% |

### 需要调整的方向

| 调整项 | 里程碑 | 优先级 |
|--------|--------|--------|
| EIP-7702 EOA 入口 | M6-7702 | 高 |
| ERC-7579 最小兼容层 | M6 | 中 |
| BLS 量子迁移路径文档 | M6 | 低 |
| ERC-7579 完整合规 | M7 | 中 |

### 不做的事情

| 不做 | 原因 |
|------|------|
| Proxy 升级 | 破坏信任模型 |
| Native AA 依赖 | Stagnant |
| 自建 Bundler | 红海，Pimlico 70%+市场 |
| 近期后量子签名 | 2028+，Glamsterdam被拒 |

---

## 执行计划概览

```
M6 主分支:
  ├── ERC-7579 最小兼容 shim (~80 LOC)
  ├── BLS 量子迁移路径文档 (docs/)
  └── 后续 M6 feature 继续

M6-7702 分支 (独立):
  ├── AirAccountDelegate.sol (~300 LOC)
  ├── test/AirAccountDelegate.t.sol (~25 tests)
  ├── scripts/test-7702-e2e.ts
  └── 完成后 merge → M6

M7 (未来):
  └── ERC-7579 完整合规 + guardian 门控模块替换
```

---

*本文档由 Claude Code 生成，基于 DSR-Research-Flow 研究报告 (2026-03-20)。*
*如需追溯决策依据，参见 `/Users/jason/Dev/mycelium/my-exploration/projects/DSR-Research-Flow/research/`。*
