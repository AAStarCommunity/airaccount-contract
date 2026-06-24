# AirAccount — OP Mainnet Alpha 部署计划

> 文档版本：2026-06-24
> 目标版本：v0.20.0 (当前 Sepolia beta 稳定后发布)
> 目标链：Optimism Mainnet (chainId=10)
> 负责人：jason
> 状态：**待执行** — beta 期间持续更新此文档

---

## 总体策略

Sepolia beta 运行 2-3 周无严重问题后，以当时最新稳定版本部署 OP Mainnet Alpha。

**非升级架构**：无 proxy，无 UUPS。主网合约一旦部署不再更改。新功能需新版本合约 + 用户主动迁移资产。

---

## 前提条件检查 (MUST — 不满足不得部署)

### P1. 代码 & 测试

- [ ] `forge build` 编译干净，无 warning
- [ ] `forge test` 全部通过（当前 805+ tests，Prague 22 tests）
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

### P4. DVT BLS 节点 (生产节点密钥)

> ⚠️ 已在 YetAnotherAA-Validator 仓库提 issue #DVT-MAINNET，请 DVT 团队提供以下信息

- [ ] 生产 DVT 节点 1：`BLS_PROD_NODE_ID_1` + `BLS_PROD_PUBLIC_KEY_1`
- [ ] 生产 DVT 节点 2：`BLS_PROD_NODE_ID_2` + `BLS_PROD_PUBLIC_KEY_2`
- [ ] 节点运行稳定，能响应 BLS 签名请求
- [ ] **Sepolia 测试节点 (`BLS_TEST_*`) 禁止用于主网**

### P5. aPNTs Token 地址

- [ ] aPNTs 在 OP Mainnet 已部署，地址已更新到 `configs/token-presets.json` 中 chain `"10"` 的 `aPNTs.address`
- [ ] 当前状态：`"address": "TBD"` — 部署前必须填入

### P6. 基础设施

- [ ] OP Mainnet RPC URL（Alchemy/Infura）记录到 `.env.op-mainnet` 为 `OP_MAINNET_RPC_URL`
- [ ] Pimlico OP Mainnet bundler URL 记录为 `OP_MAINNET_BUNDLER_URL`
- [ ] SDK 仓库 `aastar-sdk` 已准备好 OP mainnet canonical 地址表（部署后补充）

---

## 建议项 (SHOULD — 强烈建议但非硬性阻断)

- [ ] 外部安全审计（审计范围：`src/core/`、`src/validators/`、`src/modules/`）
- [ ] Etherscan 合约验证脚本就绪（`forge verify-contract --chain 10`）
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
cast code 0x0000000000000000000000000000000000000100 --rpc-url $OP_MAINNET_RPC_URL
# 应返回非 0x 的 bytecode

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
| aPNTs | **TBD** — 填入后更新 | — | — | — |

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
