# AirAccount Contract — Production Readiness (CC-30)

> **仓库**: airaccount-contract · **维护**: jason (@jhfnetboy)
> **最后更新**: 2026-07-09
> **当前版本**: v0.27.0（Sepolia 生产中）+ `[Unreleased]`（CC-27 改名 `AAStarBLSKeyRegistry`，待版本 bump 部署）
> **目标主网**: Optimism Mainnet (chainId 10) — 见 KI-7，仅 OP Stack 链支持 P256/WebAuthn
> **关联**: Seeder CC-30（全生态发布盘点）· 单一真相源汇总在 `YetAnotherAA/docs/PRODUCTION_READINESS.md`
> **文档整合自**: `docs/known-issues.md` · `docs/DEPLOYMENT-OP-MAINNET-ALPHA.md` · `docs/TODO.md` · `CHANGELOG.md` · open issues/PRs · memory

---

## 0. 核心原则（CC-30）

> **测试网 vs 主网唯一区别 = 配置（RPC / 合约地址 / env / owner Safe / DVT 节点 / aPNTs 地址）。合约代码逻辑零差异。**

代码侧已在 Sepolia 稳定运行（v0.27.0，900 forge 测试全绿 + 16 阶段 E2E）。距离主网的工作 **不是写代码**，而是：审计 + 主网部署运维 + 跨仓依赖就位 + 配置切换。

**发布节奏**：测试网（现已可发 beta）→ ~1 月观察小修 → 主网（等审计 + 5 仓两网就绪 + 配置切换）。

> ⚠️ **正式版（GA）门禁**：**未过外部安全审计（#29）前不发正式版**，只发 **beta / alpha**。审计由 jason 安排（外部付费，Code4rena / Cantina）。

---

## 1. 当前部署状态

### Sepolia（v0.27.0，已部署 + 链上验证）
| 合约 | 地址 |
|---|---|
| Factory | `0xf25621DF4c6100cdfe224054C2b09f2963bF487b` |
| Impl (AAStarAirAccountV7) | `0x4a76dEf9eE4EE44eF6D0B2a327a068B5B7931E1C` |
| Extension (isValidOwnerAuth 宿主) | `0xEcE87546989Da7df573b107D54a0ead0aCB49923` |
| Validator Router | `0xe68d6A7Bb60DA4caE62ceC2439722fc5eEF87a5c` |
| DVT BLS Validator (algId 0x01，CC-10 统一) | `0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC`（DVT 仓权威） |
| AgentRegistry | `0x239960EeA98cEC6f02608ED4Bc440b7d8442f3Da` |
| CC-22 e2e_account (owner-auth 参考账户) | `0x92EA8b02D34A4D5d10f0Db9Ea894e8bC72e292e8` |

### OP Mainnet
**未部署。** 无任何主网地址。部署脚本 `scripts/deploy-op-mainnet-alpha.ts` 待创建。

---

## 2. Production-Readiness 表

标注：`[测]` 测试网就能发 · `[主]` 主网前必须补 · `[配]` 两网只差配置

| # | 项 | 评估 | 状态 | 阻塞主网? | 标注 |
|---|---|---|---|---|---|
| 1 | **核心账户合约栈**（工厂/impl/router/extension/BLS/session/agent registry） | v0.27.0 Sepolia 部署 + 链上验证；900 forge 测试全绿；16 阶段 E2E 通过 | ✅ 就绪 | 否 | [测]=[主] 代码 |
| 2 | **CC-27 改名 `AAStarBLSKeyRegistry`** | 源码级改名已合并（PR #182 / `fcf666a`），CI 全绿 | 🟡 源码 done，待版本 bump 部署生效 | 是（含在下条 release） | [主] |
| 3 | **切一个 tagged release**（bump 版本 + `[Unreleased]`→版本号） | ✅ **v0.28.0**：`ACCOUNT_VERSION`/`FACTORY_VERSION` 0.27.0→0.28.0 + CHANGELOG + 3 处测试断言，900 测试全绿。源码级 release，待部署 | 🟢 已 bump（待 tag+部署）| 是 | [测]→[主] |
| 4 | **外部安全审计（#29）** | 未做。非可升级钱包托管资金，GA 硬门禁 | 🔴 未开始（jason 安排） | **是（GA 阻塞）** | [主] |
| 5 | **Etherscan verify** | ✅ **8/9 verified**（Router/Impl/Factory/AgentRegistry/Extension/SessionKeyValidator/ForceExit/ParserRegistry）。方法跑通（`forge verify-contract` 用**合约名**不带路径 + `--chain 11155111` + 有效 key `~/Dev/.env`；此前「跑不了」是我路径写错，非 forge bug）。复用模块从各自部署版本 tag worktree 验（300 runs）。⬜ 仅剩 `AirAccountDelegate`（v0.20.0 EIP-7702 singleton）—— worktree submodule 漂移阻塞，需干净 v0.20.0 clone。脚本 `scripts/verify-sepolia.sh`。主网重部署=全新栈一把验全 | 🟢 8/9（1 冷门待补） | 基本完成 | [测]+[主] |
| 6 | **主网合约部署** | ✅ 骨架 `scripts/deploy-op-mainnet-alpha.ts` 已建（OP mainnet + cast wallet 签名 + P1–P6 守卫）；待配置（DVT 主网 validator / Safe / RPC / keystore）后运行 | 🟡 脚本就绪，待配置运行 | 是 | [主]+[配] |
| 7 | **主网 e2e_account**（CC-22 遗留） | 主网 impl 部署后按 cc22 脚本 mint + 回填 `contracts_mainnet.e2e_account`（脚本已参数化，见 §4） | 🟠 gated 在主网 impl | 是 | [主]+[配] |
| 8 | **OP 主网 Gnosis Safe**（协议 owner + community guardian，CC-31 / #135） | 未部署；主网合约 owner 必须是多签 | 🔴 未开始（需 jason 配置） | 是 | [主]（配置/运维） |
| 9 | **主网 GA 运维（#135）**：EntryPoint stake + Safe transferOwnership | 未做 | 🔴 未开始 | 是 | [主] |
| 10 | **生产 DVT 节点**（P4）：nodeId + BLS pubkey | ⚠️ **KMS-TEE 托管下无需裸私钥**（见 §5 说明）：只需 KMS provision 出的 nodeId + 48B pubkey；禁用 Sepolia 测试键 | 🟠 待 @repo:dvt + @repo:kms 提供主网 nodeId/pubkey | 是 | [主]（跨仓） |
| 11 | **aPNTs OP 主网地址**（P5） | `token-presets.json` chain 10 aPNTs 仍 `TBD`，须先部署 | 🟠 待 @repo:sp 部署 | 是（gasless 相关） | [主]+[配] |
| 12 | **P256 / EIP-7212 链约束（KI-7）** | 目标 OP Mainnet 有 precompile ✅；以太坊主网无 → WebAuthn 不可用（已决策选 OP） | ✅ 已决策 | 否 | [配]（选链） |
| 13 | **KI-14 calldata parser 禁用** | beta.1 起禁用 DeFi parser → 代币 tier 限额对 swap 类不强制（可接受 mitigation） | 🟡 已知限制 | 否（需明确「带此限制上线」） | [测]/[主] |
| 14 | **文档刷新** | `DEPLOYMENT-OP-MAINNET-ALPHA.md`（写 v0.20，过时）+ `known-issues.md`（v0.17.2）+ #178 docs 清理 | 🟠 housekeeping（本轮起刷新） | 否 | [测] |
| 15 | **SDK canonical 主网地址接线（SDK G1）** | 主网仍是旧 V3 栈；SDK 需 airaccount 主网地址接入 canonical | 🟠 gated 在 #6 | 是 | [主]+[配] |

### 延后/非阻塞（已跟踪，不 gating 本期发布）
- **Gas/字节码**：#136 EIP-7702 delegation（省 ~2.4M 部署 gas）· #149 WebAuthnLib 外置 · #21 BLS 聚合（待 bundler）· #20 EIP-2930 warmup · TODO.md EIP-1167 clone 工厂。
- **功能**：#161 native ETH tier limit · #133 带外确认阈值 · #26 后量子 validator · #27 EIP-8130 · #25 OAPD · #24 Railgun · #138 guard strict mode。
- **跟踪伞**：#112（BLS/DVT layer-1/GA 治理移交）· #67（KI-13/14/15 + ForceExit）· #66 ForceExit 通用化 · #137 0-guardian installModule guard。
- **代码 TODO**：`AAStarAirAccountBase.sol:210` executeBatch per-call scope（= KI-9，ERC-4337 设计约束）。

---

## 3. 依赖矩阵

### 谁依赖 airaccount-contract（我完成后需通知）
| 依赖方 | 依赖内容 | 通知点 |
|---|---|---|
| **@repo:yaaa** | 账户合约（工厂/validator 两网地址） | 主网部署后 |
| **@repo:sdk** | canonical 工厂/validator 地址（主网接入 CANONICAL_ADDRESSES[10]） | 主网部署后（照 CC-18 两阶段：ABI 先行、地址 apply 后切） |
| **@repo:kms / @repo:dvt** | `isValidOwnerAuth(bytes32,bytes)→0xa0cf00cf` 接口契约（CC-23，已入 INTERFACES.md）+ 主网 e2e_account（CC-22） | 接口变更时回 CC-23；主网 e2e_account 部署后回 CC-22 |

### airaccount-contract 依赖谁
| 被依赖方 | 我依赖的内容 | 状态 |
|---|---|---|
| **@repo:dvt** | 0x01 权威 BLS validator（Sepolia `0x539B…` 已挂载 CC-10）；**主网 validator 地址** + 生产节点 nodeId/pubkey | ⏳ 主网待提供 |
| **@repo:kms** | WebAuthn rpId/Origin 两网正确；DVT 密钥 KMS provision（key-less node_state） | ⏳ 主网待就位 |
| **@repo:sp** | aPNTs 主网地址（gasless） | ⏳ TBD |
| **jason / 配置** | OP 主网 Gnosis Safe、RPC、bundler URL、主网部署 keystore、**外部审计** | ⏳ 需你提供 |

---

## 4. 测试网 → 主网 配置差异（代码零改）

| 配置项 | Sepolia | OP Mainnet | 来源 |
|---|---|---|---|
| RPC | Sepolia RPC | `OP_MAINNET_RPC_URL` | `.env.op-mainnet` |
| Bundler | Pimlico Sepolia | Pimlico OP `.../v2/10/rpc` | `.env.op-mainnet` |
| 合约地址 | v0.27.0 栈（§1） | 主网部署后回填 | 部署脚本输出 |
| Owner | 测试 EOA | OP 主网 Gnosis Safe（多签） | CC-31 / #135 |
| DVT validator + 节点 | `0x539B…` + 测试节点 | 主网 validator + 生产节点 | @repo:dvt |
| aPNTs | Sepolia | OP 主网（TBD） | @repo:sp |
| 部署 key | `.env` 测试 key | `cast wallet` keystore（不进 .env） | P2 |
| Etherscan chain | 11155111 | 10 | verify 脚本 |
| e2e_account | `0x92EA…` | 主网 mint（cc22 脚本：`TARGET_CHAIN=mainnet`）| CC-22 |

**e2e_account 是什么**（回答常见疑问）：它是一个**智能合约账户**（从 v0.27.0 工厂部署的 direct-mode `AAStarAirAccountV7` 实例），**不是 EOA**；其 **owner 是一个 EOA**（Sepolia 上 = Jason EOA `0xb56000…` = DVT dvt1 operator key）。用途是给 DVT/KMS 一个实现了 `isValidOwnerAuth→0xa0cf00cf` 的真实账户跑 owner-gated 签名。**创建方式 = 主网 impl/工厂部署之后，手工跑脚本 mint**：`AIRACCOUNT_MAINNET_FACTORY=<主网工厂>` + `TARGET_CHAIN=mainnet` + `pnpm tsx scripts/cc22-ownerauth-e2e-account.ts`（脚本 header 已固化步骤）。

---

## 5. 发布门 & 说明

### GA 硬门禁
1. **外部安全审计（#29）** — 未过审计不发正式版，只发 beta/alpha。审计由 jason 安排。范围 `src/core/ src/validators/ src/modules/`。
2. **Etherscan verify** — 主网合约必须全部 verified（当前 Sepolia 2/11，须先修 foundry source path 问题把 9 个补齐，主网同法走 chainid 10）。
3. **主网 owner = Gnosis Safe** + EntryPoint stake + transferOwnership（#135）。

### 生产 DVT 密钥 —— KMS-TEE 托管下还需要密钥吗？
**不需要裸私钥落盘。** CC-22 Variant B（KMS-TEE BLS 托管）确定的姿势：
- DVT 节点跑 **key-less `node_state.json`**（只有 `{nodeId, publicKey}`，**无 privateKey**）；BLS 私钥密封在 KMS TEE，签名走 `RUST_SIGNER_URL` → KMS `/sign`。
- 主网 provision：KMS `BlsGenKey`（门在 `KMS_BLS_PROVISIONING=1`）产出 48B 压缩 G1 pubkey → 写 `{nodeId=keccak256(EIP-2537 pubkey), publicKey}`。
- 所以主网 P4 我方需要的是 **@repo:kms/@repo:dvt 提供的 nodeId + pubkey**（用于配置/注册），**不是** `.env` 里的 `BLS_PROD_*_PRIVATE_KEY`。DEPLOYMENT doc 的 P4 措辞据此更新。

---

## 6. 原始盘点（open issues / PRs / TODO / memory）

- **Open PRs**: 无。
- **主网/发布相关 open issues**: #29（审计·GA门禁）· #135（主网 GA ops）· #112（延后启用跟踪：BLS/DVT-L1/GA治理移交）· #178（docs 清理）· #28（EIP-7212 gas 监控）· #67（KI 伞）。
- **延后功能/优化 issues**: #136 #149 #21 #20 #161 #133 #26 #27 #25 #24 #138 #137 #66（见 §2 延后区）。
- **代码 TODO/FIXME**: 1 处（`AAStarAirAccountBase.sol:210`，KI-9 executeBatch scope，设计约束）。
- **known-issues（KI-1..15）**: 多为有意设计权衡；主网相关重点 = KI-7（P256/OP-only，已决策）、KI-14（parser 禁用，已知限制）、KI-12（测试键泄露，仅测试网）。
- **memory 技术债**: CC-22 主网 e2e_account 回填 · DEPLOYMENT/known-issues 文档过时待刷新 · verify 未补齐。

---

## 7. 结论

- **测试网（beta）**：✅ 现已可发。代码/测试就绪，v0.27.0 Sepolia 稳定。
- **主网（正式版/GA）**：🔴 阻塞在 **① 外部审计（#29，jason）② 主网部署（脚本+Safe+keystore）③ 跨仓依赖两网就位（dvt 主网 validator+节点、sp aPNTs、kms 密钥 provision）④ verify 补齐**。
- **可独立先做的 airaccount 侧 to-do**（不等外部）：切 release（bump 版本 + 落地改名）· 创建主网部署脚本骨架 · 修 verify 的 foundry source path · 刷新过时文档。
