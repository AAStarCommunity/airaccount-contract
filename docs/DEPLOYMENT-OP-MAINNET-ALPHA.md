# AirAccount — OP Mainnet Alpha 部署计划

> 文档版本：2026-07-13（refreshed）
> 目标版本：**v0.28.0**（CC-27 改名 + version bump 已切；Sepolia 先跑 v0.28.0-beta，主网以观察后最新稳定版部署）
> 目标链：Optimism Mainnet (chainId=10) — 见 known-issues KI-7，仅 OP Stack 链支持 P256/WebAuthn
> 负责人：jason
> 状态：**待执行** — beta 期间持续更新此文档
>
> 📌 **主文档**：本文件是「主网部署操作手册」。**发布就绪总盘点（含审计门、依赖矩阵、测试网/主网差异、open issues/TODO 整合）见 [`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md)（CC-30 单一真相源）。**

---

## 总体策略

Sepolia beta 运行 2-3 周无严重问题后，以当时最新稳定版本部署 OP Mainnet Alpha。

**非升级架构**：无 proxy，无 UUPS。主网合约一旦部署不再更改。新功能需新版本合约 + 用户主动迁移资产。

---

## 前提条件检查 (MUST — 不满足不得部署)

### P1. 代码 & 测试

- [ ] `forge build` 编译干净，无 warning
- [ ] `forge test` 全部通过（当前 900 tests 全绿，Prague profile 亦全绿）
- [ ] Sepolia beta E2E 16/16 通过（Phase 01–16 全绿）
- [ ] Phase 11 GR.9-GR.12 (installModule/uninstallModule) 已修复并在 Sepolia 验证
- [ ] 无 HIGH/CRITICAL 未关闭的安全 issue
- [ ] `ACCOUNT_VERSION` 和 `FACTORY_VERSION` 常量与 git tag 完全一致（含 beta/RC 后缀规则）

### P2. 密钥管理 (主网不使用 .env PRIVATE_KEY)

```bash
# 一次性导入（本地加密存储，不存入任何 .env 文件）
cast wallet import mainnet-deployer --interactive
# 验证：
cast wallet address --account mainnet-deployer
```

- [ ] `mainnet-deployer` keystore 已在本地加密导入
- [ ] 部署地址有 ≥ 0.02 ETH OP ETH（OP gas 极便宜，0.01 ETH 绰绰有余）
- [ ] 不在任何 .env 文件中出现 `PRIVATE_KEY=0x...`（主网部署时通过 cast wallet 解密）

### P3. Gnosis Safe (协议 Owner)

- [ ] 在 OP Mainnet 部署 Gnosis Safe 多签（建议 2-of-3 或 3-of-5）
- [ ] Safe 地址记录到 `.env.op-mainnet` 为 `PROTOCOL_SAFE_ADDRESS`
- [ ] 同一个 Safe 同时作为 `COMMUNITY_GUARDIAN_ADDRESS`（或单独部署另一个 Safe）

### P4. DVT BLS 节点 (生产节点公钥 — KMS-TEE 托管，无需裸私钥)

> ⚠️ 请 @repo:dvt + @repo:kms 提供（CC-22 Variant B 已定 KMS-TEE 托管姿势）。
> **更新（2026-07-09）**：DVT 私钥密封在 KMS TEE，节点跑 **key-less `node_state.json`**（只有 `{nodeId, publicKey}`，无 privateKey）。
> 所以主网只需 **nodeId + 48B G1 pubkey**（KMS `BlsGenKey` provision 产出），**不在任何 .env 放裸 BLS 私钥**。

- [ ] 生产 DVT 节点 1：`BLS_PROD_NODE_ID_1` + `BLS_PROD_PUBLIC_KEY_1`（KMS provision）
- [ ] 生产 DVT 节点 2：`BLS_PROD_NODE_ID_2` + `BLS_PROD_PUBLIC_KEY_2`（KMS provision）
- [ ] 节点 `RUST_SIGNER_URL` 指向 KMS `/sign`，`RUST_SIGNER_REQUIRED=true`（fail-closed，不回退本地签）
- [ ] 主网 DVT validator 地址（@repo:dvt 提供，替换 Sepolia `0x539B…`）
- [ ] **Sepolia 测试节点 (`BLS_TEST_*`) + 已泄露测试键 (`0xb56000…`, KI-12) 禁止用于主网**

### P5. aPNTs Token 地址

@repo:sp 已于 2026-09-01 交付 OP 主网地址，但**本仓刻意仍留 `TBD`**。
token 配置在 `createAccount` 时**烘焙进不可变 guard**，填错不能改，只能让用户迁移账户。

**B1/B2 是「为什么现在不填」，B3 是「填的那一刻必须同时做对」——B3 已在本 PR 修好，B1/B2 仍未解除。**

```
aPNTs (OP mainnet, chainId 10)  0x0B41C78081B5A141eb4C3C7E7FD8E58A7Bde553B
  name "AAStar PNTs" · symbol "aPNTs" · decimals 18 · totalSupply 140,000e18
  code = 45 字节 EIP-1167 minimal proxy → impl 0xa19101bfa30495f23cef0ef354999b3e3f8b2ab9
  impl version() = "XPNTs-3.0.0-unlimited"（本仓当前 XPNTs-3.5.0）
  communityOwner() = 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3   ← code 长度 0 = EOA
```

- [ ] **B1 — owner 是 EOA，且可无限增发。** `communityOwner` 不是 CC-31 治理 Safe
      `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`（两者都以 `0x51` 开头，极易看串，但 Safe 在 OP 上有 ~172 字节
      代码，前者是 0）。版本串里的 `-unlimited` 是字面意思：`eth_call` 模拟 `mint(owner, 1e24)`（**全部供应量的 7 倍**）
      从该 EOA **成功**，从随机地址 revert（`0x8e4a23d6` + caller）——即无 cap、无 pause，单个外部私钥可任意稀释。
      这不只是 sp 侧治理卫生问题：本仓主网 guard 的 tier1/tier2/daily 三档**以 aPNTs 计价**，
      那把私钥因此实际控制着我们不可变限额的经济含义。**owner 转入 Safe 之前不得填入。**
- [ ] **B2 — 这个地址注定要变。** 45 字节 clone 把 impl 地址**硬编码在 runtime bytecode** 里，无 admin slot、
      无升级路径，所以 3.0.0 → 3.5.0 **无法原地升级**，只能部署新 clone = **新地址**。
      @repo:sp 已计划在 CC-115 B3 稳定后全面部署新版，故现在填入的任何地址都会在那次部署后作废。
- [x] **B3 — 预设按 6 位小数计价，而 aPNTs 是 18 位（已修，PR #239）。** `configs/token-presets.json` 里
      aPNTs 三条链（Sepolia / 以太坊主网 / OP 主网）都写着 `"decimals": 6`，限额也是按 6 位的形状写的，
      而链上 `decimals()` = **18**。照原样发上主网，standard 档 tier-1 限额是 **5×10⁻¹⁰ aPNTs**。
      失败方向是 **fail-closed**（任何转账都撞 `InsufficientTokenTier`，不是资金外流），但限额一旦烘焙进
      不可变 guard 就只能迁移账户。
      **为什么它能长期错着没人发现**：`loadTokenPresets`（`scripts/deploy-op-mainnet.ts:82`）把
      `tier*Limit` **原样喂进 `createAccount`**，却**从不读 `decimals`**——那个字段纯粹是文档，
      写错不会有任何东西报错，只会误导下一个照着它写限额的人。
      **当前挡住主网的是 `if (tokenData.address === "TBD") continue`**，也就是说
      「填入 P5 地址」这个动作本身就是引信。
      修法：三条链 `decimals` 6 → 18，27 个限额 × 10¹²（人类金额不变：100/1000/5000 等）。
- [ ] B1、B2 均消除后，再更新 `configs/token-presets.json` chain `"10"` 的 `aPNTs.address` 与本文 Token 预设表。
- [ ] 填入地址后**必须**跑 `node scripts/check-token-presets.mjs --chain 10`，要求 `EXIT=0` 且 aPNTs 行显示
      `OK decimals=18`。散文读着对不算数——该脚本对每个非 TBD token 断言
      `预设 decimals == 链上 decimals()` 并打印每档的人类金额。

> 顺带：B2 对 sp 是好消息——owner 只能在重新部署时修正，反正要发新 clone，两件事可以一次做完。

### P6. 基础设施

- [ ] OP Mainnet RPC URL（Alchemy/Infura）记录到 `.env.op-mainnet` 为 `OP_MAINNET_RPC_URL`
- [ ] Pimlico OP Mainnet bundler URL 记录为 `OP_MAINNET_BUNDLER_URL`
- [ ] SDK 仓库 `aastar-sdk` 已准备好 OP mainnet canonical 地址表（部署后补充）

---

## 发布分级门禁（更新 2026-07-09）

- **beta / alpha 版**：可在**未审计**下发（测试网 + 主网 alpha 早期），但须显式标注 beta/alpha + known-issues。
- **正式版 (GA)**：🔴 **外部安全审计（#29）为硬门禁 —— 未过审计不发 GA，只发 beta/alpha。** 审计由 jason 安排（Code4rena / Cantina），范围 `src/core/`、`src/validators/`、`src/modules/`。

### MUST（此前误列为 SHOULD，现提为硬性）
- [ ] **Etherscan verify** — 主网合约全部 verified（`forge verify-contract --chain 10`，key 在 `~/Dev/.env` / `.env.sepolia`）。当前 Sepolia 2/11，须先修 foundry source path 问题补齐 9 个。

### SHOULD
- [ ] WalletBeat 评分达标（当前 Sepolia 版本已通过）
- [ ] SDK E2E 测试对接 OP mainnet 合约地址通过

---

## 环境配置模板

创建 `.env.op-mainnet`（不提交到 git，不含任何 PRIVATE_KEY）：

```bash
# === OP Mainnet Alpha 环境配置 ===
# 不含 PRIVATE_KEY — 使用 cast wallet import mainnet-deployer

OP_MAINNET_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/<YOUR_KEY>
OP_MAINNET_RPC_URL2=https://optimism-mainnet.infura.io/v3/<YOUR_KEY>
OP_MAINNET_BUNDLER_URL=https://api.pimlico.io/v2/10/rpc?apikey=<KEY>

COMMUNITY_GUARDIAN_ADDRESS=<GNOSIS_SAFE_ON_OP_MAINNET>
PROTOCOL_SAFE_ADDRESS=<GNOSIS_SAFE_ON_OP_MAINNET>

# 生产 DVT 节点（由 DVT 团队提供，issue: YetAnotherAA-Validator#xxx）
BLS_PROD_NODE_ID_1=
BLS_PROD_PUBLIC_KEY_1=
BLS_PROD_NODE_ID_2=
BLS_PROD_PUBLIC_KEY_2=

# 部署后由脚本自动输出，回填到此处
# AIRACCOUNT_OP_ALPHA_FACTORY=
# AIRACCOUNT_OP_ALPHA_IMPL=
# AIRACCOUNT_OP_ALPHA_VALIDATOR_ROUTER=
# AIRACCOUNT_OP_ALPHA_SESSION_KEY_VALIDATOR=
# AIRACCOUNT_OP_ALPHA_BLS_ALGORITHM=
# AIRACCOUNT_OP_ALPHA_BLS_AGGREGATOR=
# AIRACCOUNT_OP_ALPHA_FORCE_EXIT_MODULE=
# AIRACCOUNT_OP_ALPHA_DELEGATE=
# AIRACCOUNT_OP_ALPHA_PARSER_REGISTRY=
# AIRACCOUNT_OP_ALPHA_AGENT_REGISTRY=
```

---

## 部署脚本说明

### 待创建：`scripts/deploy-op-mainnet-alpha.ts`

基于 `scripts/deploy-v0.20.ts` 改造，三处核心变动：

**① cast wallet 签名（不读 PRIVATE_KEY env）**

```typescript
import { execSync } from "child_process";

const keystoreAccount = process.argv.find(a => a.startsWith("--account"))?.split("=")[1]
  ?? process.argv[process.argv.indexOf("--account") + 1];
if (!keystoreAccount) { console.error("Usage: ... --account mainnet-deployer"); process.exit(1); }

// cast wallet private-key prompts for password interactively (tty required)
const pk = execSync(`cast wallet private-key --account ${keystoreAccount}`,
  { stdio: ["inherit", "pipe", "inherit"] }).toString().trim() as Hex;
const deployer = privateKeyToAccount(pk);
```

**② 链换成 OP Mainnet**

```typescript
import { optimism } from "viem/chains";
// chain: optimism, chainId: 10
// Explorer: https://optimistic.etherscan.io/tx/
// RPC: process.env.OP_MAINNET_RPC_URL
```

**③ 部署后自动 transferOwnership 到 Safe**

```typescript
const PROTOCOL_SAFE = process.env.PROTOCOL_SAFE_ADDRESS as Address;
if (PROTOCOL_SAFE && PROTOCOL_SAFE !== "0x0000000000000000000000000000000000000000") {
  await callOnce("transferOwnership(blsAlgorithm)", blsAlgorithm, OWNABLE_ABI, "transferOwnership", [PROTOCOL_SAFE], 80_000n);
  await callOnce("transferOwnership(validatorRouter)", validatorRouter, OWNABLE_ABI, "transferOwnership", [PROTOCOL_SAFE], 80_000n);
  await callOnce("transferOwnership(factory)", factory, OWNABLE_ABI, "transferOwnership", [PROTOCOL_SAFE], 80_000n);
  console.log(`✓ Ownership transferred to Safe: ${PROTOCOL_SAFE}`);
}
```

---

## 部署执行流程

### Day 0 — 最终检查

```bash
cd /Users/jason/Dev/aastar/airaccount-contract

# 1. 确认编译
forge build

# 2. 确认测试全绿
forge test --summary 2>&1 | tail -5

# 3. 确认 ACCOUNT_VERSION 与 tag 一致
grep -r "ACCOUNT_VERSION\|FACTORY_VERSION" src/core/*.sol

# 4. 确认 .env.op-mainnet 所有 MUST 字段已填
cat .env.op-mainnet | grep -E "^[A-Z]" | grep -v "^#"

# 5. 确认 deployer 余额
cast balance $(cast wallet address --account mainnet-deployer) --rpc-url $OP_MAINNET_RPC_URL
```

### Day 1 — 部署

```bash
# 执行部署（终端提示 cast wallet 密码）
pnpm tsx scripts/deploy-op-mainnet-alpha.ts --account mainnet-deployer 2>&1 | tee deploy-op-$(date +%Y%m%dT%H%M%SZ).log
```

脚本输出 10 个合约地址 + 6 条 wiring tx + ownership transfer。将输出回填到 `.env.op-mainnet`。

### Day 1 — 立即验证

```bash
# 1. 验证 Factory 版本号
cast call $AIRACCOUNT_OP_ALPHA_FACTORY "FACTORY_VERSION()(string)" --rpc-url $OP_MAINNET_RPC_URL

# 2. 验证 Impl 版本号
cast call $AIRACCOUNT_OP_ALPHA_IMPL "ACCOUNT_VERSION()(string)" --rpc-url $OP_MAINNET_RPC_URL

# 3. 验证 router 注册了 BLS + SessionKey
cast call $AIRACCOUNT_OP_ALPHA_VALIDATOR_ROUTER "algorithms(uint8)(address)" 1 --rpc-url $OP_MAINNET_RPC_URL
cast call $AIRACCOUNT_OP_ALPHA_VALIDATOR_ROUTER "algorithms(uint8)(address)" 8 --rpc-url $OP_MAINNET_RPC_URL

# 4. 验证 ownership 已转移到 Safe
cast call $AIRACCOUNT_OP_ALPHA_FACTORY "factoryAdmin()(address)" --rpc-url $OP_MAINNET_RPC_URL

# 5. 验证 EIP-7212 P256 precompile 可用
# 注意：precompile 地址的 bytecode 永远是 0x（这是正常的，不代表不可用）
# 通过实际调用来验证：有效的 precompile 会返回 32 字节（即使输入无效也返回 0x00..00）
# 不存在的 precompile 调用则返回空或 revert
cast call 0x0000000000000000000000000000000000000100 \
  0x$(python3 -c 'print("00"*160)') \
  --rpc-url $OP_MAINNET_RPC_URL
# 应返回 32 字节（0x000...000），代表 precompile 存在且可调用（全零输入验签失败是预期的）

# 6. 创建一个测试账户验证全链路
pnpm tsx scripts/e2e-create-test-account.ts  # （需适配 OP mainnet 地址）
```

### Day 2+ — 运营操作（手动，通过 Safe 执行）

以下操作需要通过 Gnosis Safe 多签，不放在自动化脚本中：

**addStake（视业务需要）**
- 如果使用 BLS 聚合路径，BLS Aggregator 需要在 EntryPoint 上 addStake
- 通过 Safe 调用 `blsAggregator.addStake(unstakeDelay)` with ETH value
- 典型值：0.1 ETH，unstakeDelay = 86400（24h）

**DVT 节点追加**
- 通过 Safe 调用 `blsAlgorithm.registerPublicKey(nodeId, pubKey)` 注册新节点

**BLS aggregator 轮换 —— 必须按计划内维护窗口排期，不是随时可做的运维动作**

`setBlsAggregator` 要求新 aggregator 与 registry 一致，并会 **bump `configVersion`**，这会打破
`epochConfigVersion[e] == configVersion`，使**所有已有 epoch 快照失效、必须由 keeper 重新 pin**。
在重新 pin 完成之前，**tier-2/3 fail-closed**（tier-1 不受影响）。因此：

- 轮换前后与 @repo:dvt keeper 协调重新 pin，并把这段窗口当作已知的降级窗口对外说明；
- 窗口内 `scripts/committee-health.mjs` 会正确报 CRITICAL，且 epoch 行会显示 `cfgMatch=false`——
  这是**预期读数，不是 keeper 故障**，排查顺序见 `docs/committee-health-monitoring.md`；
- 同理，紧跟轮换之后跑 E2E 会读到瞬时 sentinel，属预期而非回归。

三条腿（Registry / SuperPaymaster / DVTValidator 各自的 aggregator 指针）必须一起切。@repo:sp 报告
2026-08-30 曾只改 Registry 一个指针，分裂在 OP 主网上存活两天且无任何检查报红，现已加 `Check11_AggregatorPointers`
门禁阻断部署。本仓主网上线后如引入 aggregator，需把该指针纳入同一门禁。

**Etherscan 合约验证**（可在部署后任意时间执行）

```bash
forge verify-contract $AIRACCOUNT_OP_ALPHA_FACTORY AAStarAirAccountFactoryV7 \
  --chain 10 \
  --verifier etherscan \
  --etherscan-api-key $ETHERSCAN_API_KEY
# 对每个合约重复
```

---

## 合约部署 DAG（共 10 合约 + 6 wiring tx）

```
[1] AAStarBLSAlgorithm          (no deps)
[2] AAStarValidator             (no deps)          ← router
[3] AAStarBLSAggregator         (blsAlgorithm, entryPoint)
[4] SessionKeyValidator         (no deps)
[5] ForceExitModule             (no deps)
[6] AirAccountDelegate          (no deps)          ← EIP-7702
[7] CalldataParserRegistry      (no deps)
[8] AAStarAirAccountV7 impl     (no deps)          ← also auto-deploys AirAccountExtension
[9] AAStarAirAccountFactoryV7   (impl, entryPoint, communityGuardian, tokens, configs)
[10] AgentRegistry              (no deps)

Wire 1: router.registerAlgorithm(0x01, blsAlgorithm)
Wire 2: router.registerAlgorithm(0x08, sessionKeyValidator)
Wire 3: agentRegistry.bindFactory(factory)
Wire 4: factory.setAgentRegistry(agentRegistry)
Wire 5: blsAlgorithm.registerPublicKey(NODE_ID_1, PUBKEY_1)
Wire 6: blsAlgorithm.registerPublicKey(NODE_ID_2, PUBKEY_2)

Post-wire (if PROTOCOL_SAFE_ADDRESS set):
  blsAlgorithm.transferOwnership(safe)
  validatorRouter.transferOwnership(safe)
  factory.transferOwnership(safe)
```

**EntryPoint**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`（全链通用，不部署）  
**EIP-7212 P256 precompile**: `0x0000000000000000000000000000000000000100`（OP Mainnet Fjord 升级后原生支持）

---

## Token 预设（OP Mainnet，standard profile）

来自 `configs/token-presets.json` chain `"10"`：

| Token | 合约地址 | Tier 1 累计上限 | Tier 2 累计上限 | 每日上限 |
|-------|---------|---------------|---------------|--------|
| USDC | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | $500 | $5,000 | $10,000 |
| USDT | `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | $500 | $5,000 | $10,000 |
| WETH | `0x4200000000000000000000000000000000000006` | 0.5 ETH | 5 ETH | 10 ETH |
| WBTC | `0x68f180fcCe6836688e9084f035309E29Bf0A2095` | 0.05 BTC | 0.5 BTC | 1 BTC |
| aPNTs | **TBD** — 见 [P5](#p5-apnts-token-地址)，地址已交付但被 B1（EOA 可无限增发）+ B2（clone 不可升级，地址将变）阻塞 | 500 aPNTs | 5,000 aPNTs | 10,000 aPNTs |

---

## DVT 节点依赖

> 已在 [AAStarCommunity/YetAnotherAA-Validator](https://github.com/AAStarCommunity/YetAnotherAA-Validator) 提 issue

**需要 DVT 团队提供：**
1. 生产 DVT 节点的 `nodeId`（bytes32）和 `publicKey`（BLS G1 点，bytes）
2. 节点运行 SLA：主网上线后响应 BLS 签名请求的可用性承诺
3. 节点升级/替换的通知流程（替换需要通过 Safe 调用 `registerPublicKey`）

---

## 已知限制 & 后续计划

| 项目 | 说明 | 计划 |
|------|------|------|
| Phase 11 GR.9-11 | installModule/uninstallModule E2E 脚本 bug 已修复（2026-06-24） | 下次 Sepolia 跑完整 16 phases 验证 |
| PolicyRegistry | 计划中的 DVT 验证器注册，当前未实装 | 下个版本 opt-in ERC-7579 module |
| "Am I Dead?" | AI+DVT 遗嘱系统 | 长期路线图 |
| 多链扩展 | Base、Arbitrum | OP mainnet 稳定后 |
| 主网安全审计 | 强烈建议 | GA 前 |

---

## 版本历史

| 日期 | 变更 |
|------|------|
| 2026-06-24 | 初版：主网部署全计划，基于 Sepolia v0.19.0-beta.2 分析 |
| 2026-09-01 | P5 记录 @repo:sp 交付的 aPNTs 地址并说明三条阻塞（B1 EOA 无限增发 / B2 clone 地址将变 / B3 预设 6 位小数 vs 链上 18 位，已修）；新增 aggregator 轮换 → tier-2/3 fail-closed 的运营窗口条目；新增 `scripts/check-token-presets.mjs`（CC-46） |
