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
      **补充（pr-daemon 复核）**：限额只能收紧、不能放宽——`addTokenConfig` 对已配置的 token 直接
      `TokenAlreadyConfigured` revert，`decreaseTokenDailyLimit` 拒绝任何调大，而 `guard` 在 `initialize`
      里一次性绑定。所以填错限额对**已创建的账户是永久的**，唯一补救是账户迁移，不存在"改配置重来"。
- [ ] B1、B2 均消除后，再更新 `configs/token-presets.json` chain `"10"` 的 `aPNTs.address` 与本文 Token 预设表。
- [ ] **交接验收：只认自己对链的读数，不认对方部署日志。**
      @repo:sp 报告他们原先的部署断言跑在 `stopBroadcast` **之后的模拟里**；该部署是四笔交易，
      **tx2 与 tx3 之间 token 的 `communityOwner` 就是部署者 EOA**。若 tx3 掉了而 tx1/tx2 已上链，
      脚本会在模拟上退出 0，而链上留着一个 EOA 持有的活代币——我们会收到一个「已断言过 A1」的地址。
      他们已改为可重跑的 `15_VerifyAPNTs.s.sol`，并明确要求我们自己跑。**本仓验收照此执行**：

      ```bash
      T=<新 token>; F=<新 factory>; SAFE=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114
      cast call $T "communityOwner()(address)" --rpc-url $OP   # 必须 == $SAFE
      cast call $F "owner()(address)"          --rpc-url $OP   # 必须 == $SAFE
      cast code $SAFE --rpc-url $OP | wc -c                    # 必须 > 2（"0x" 之外有内容）
      cast call $T "decimals()(uint8)"         --rpc-url $OP   # 必须 == 18
      cast call $T "totalSupply()(uint256)"    --rpc-url $OP
      cast call $F "APNTS_PRICE_MAX()(uint256)" --rpc-url $OP  # 决定永久限额，必须自读
      ```

      ⚠️ **`cast code` 那行不能省、也不能用地址串比较代替**：治理 Safe `0x51eDf11f…` 与旧 aPNTs 的
      EOA owner `0x51Ac6949…` **都以 `0x51` 开头**，肉眼极易看串（本仓第一轮就差点)。

      ⚠️ **终态断言不覆盖过程。** 上面六行验的全是**最终状态**——但部署者在 tx2→tx3 间隙持有
      `communityOwner` 时可以自铸、可以加白名单 spender，而做完这些之后再把 owner 交给 Safe，
      `communityOwner()` 和 `owner()` 读出来**一模一样**（Codex 在 @repo:sp 的验证器里发现的）。
      所以必须一并断言 **fresh-clone 状态**，它才是排除"路上发生过什么"的那部分：

      ```bash
      cast call $T "totalSupply()(uint256)" --rpc-url $OP    # 必须 == 0（没有自铸）
      # 外加：无额外 auto-approved spender（工厂除外）、无对部署者的自授权、
      #       各项限额仍为 initialize 默认值
      ```

      `totalSupply() == 0` 不是"顺手记一个数"，**它就是那条断言**。
- [ ] **顺序写死：填入地址 → 跑 `node scripts/check-token-presets.mjs --chain 10 --require-verified`
      且 `EXIT=0` → 才可部署。**
      顺序是硬要求,不是建议:地址还是 `TBD` 时脚本拿不到链上真值,它要挡的正是「填入地址」之后那一刻。
      **判据是退出码,不是读输出里的字符串**——`--require-verified` 让任何仍是 TBD 的 token 直接算失败,
      所以「有没有真的对着链验过」由机器判定。（人去分辨 `OK decimals=18` 和
      `OK against DECLARED decimals=18` 是可以漏看的,漏看不会报错还会指错地方。）
      脚本断言的是**限额本身**——`BigInt(tier1Limit) == parseUnits(期望人类金额, 链上 decimals)`,
      期望值（aPNTs standard = 500/5000/10000）显式写在脚本里、不从被检查的文件推导，否则检查是循环的。
      只断言 `decimals` 相等是不够的:那会放过「decimals 改对了、限额仍是旧尺度」的文件，而那正是 B3 本身。
      脚本另有一条**跨链一致性**检查(常开):同一 symbol 在各链声明的 `decimals` 必须一致,且只要有任一条链
      对着链验过,其他链的声明就必须等于它。aPNTs 在 Sepolia 上验出 18,于是 chain 10 即便地址仍是 `TBD`、
      `decimals` 与限额彼此自洽,写 `6` 也会当场被判失败——**这是声明路径唯一能被看见的方式**。

> 顺带：B2 对 sp 是好消息——owner 只能在重新部署时修正，反正要发新 clone，两件事可以一次做完。

**更正（2026-09-01，@repo:sp 自我更正）——`XPNTs-3.5.0` 并没有强制上限，所以版本升级本身不解 B1**：
`issuanceCap` **不是 mint 闸门**。唯一的 `_mint` 调用点在 `mint(address,uint256)`，只有 `onlyFactoryOrOwner`
守卫、**没有 cap 检查**；`issuanceCap` 只被 view `isOverIssued()` 读（供 DVT 调用），默认 0（未设），
之后由 `communityOwner` 设定。也就是说 3.5.0 买到的是**可观测性 + owner 自愿声明的上限**，不是强制天花板。
⇒ **真正修掉「EOA 可无限增发」的是 owner 变成 Safe，不是版本号**。Safe 依然能无限增发，只是不能单方面做，
且 `isOverIssued()` 会标出来。本文 B1 的措辞据此保持不变（B1 说的一直是 owner，不是版本）。

**⚠️ 待 Jason 决策 —— aPNTs 的档位不可能按美元计价,这是算术上的,不是偏好问题**

Jason 已确认 aPNTs 是 **xPoint（行政定价的社区积分）**，价格 `$0.02` 由工厂
`updateAPNTsPrice`（`onlyOwner`，单次 ±30%，绝对 MIN/MAX）调整，**这是有意的治理接口而非缺陷**。
已上链核实：工厂 `0x864971a26384d9DCC7115f0bBC428e2623F28b6e`（`xPNTsFactory-2.1.0-clone-optimized`），
`aPNTsPriceUSD` = `2e16` = **$0.02**，`owner()` = `0x51Ac6949…`（**与能无限增发的是同一把钥匙**；
sp 的 `7e79a3a7` 把新工厂的 owner 转给 Safe）。

于是 @repo:sp 建议「按 $0.02 重算，把绝对值放大到对上 $100/$1000」。**这条做不到**：

```
aPNTs 全部流通盘 = 140,000 × $0.02 = $2,800

若照 USDC 档位的美元值折算成 aPNTs：
  conservative  5,000 /   50,000 /   250,000   ← daily 超总供应量
  standard     25,000 /  250,000 /   500,000   ← tier2 起全部超总供应量
  trader      100,000 /1,000,000 / 2,500,000   ← 全部超总供应量
```

**每一档都超过总供应量。** 一个总值 $2,800 的积分承载不了 USDC 那套美元门槛。
（现有 aPNTs 数字与 USDC 行**数位完全相同**——100/1000/5000、500/5000/10000、2000/20000/50000——
显然是照 USDC 的形状抄来的，所以它们长得像美元，其实不是。）

~~现有数字放回供应量看（占比 0.1%…35.7%）~~ —— **这张占比表作废，是我算错的**：分母用了旧代币的
140,000，而 @repo:sp 早在交付地址时就说过供应量不承接。**新代币 `totalSupply` 从 0 开始**
（`deployxPNTsToken` 里没有 mint —— 此条为 sp 转述，其仓库代码，本仓无可验落点）。
所以任何「占总供应量 X%」的说法在铸币计划确定前都没有分母。上面「每一档都超过 140,000」的推演
同样只适用于**旧**代币，不能直接搬到新代币上。

**但 (A) 仍然是关死的，而且理由更硬 —— 靠的是价格上界，与供应量无关。**

`APNTS_PRICE_MAX = 100 ether` / `MIN = 0.001 ether`（2.3.0 工厂上的 `public constant`；
本仓之前 getter 全 revert 是因为查的是**线上 2.1.0 工厂**，它早于 P0-12 —— 方向对、合约错）。
$100 是发行价 $0.02 的 **5,000×**，按单次 +30% 走完约 **33 步**（`ln(5000)/ln(1.3) ≈ 32.5`）。
整段带宽 `MIN→MAX` 是另一个跨度：100,000×，需要约 **44 步**（`ln(100000)/ln(1.3) ≈ 43.9`）。
⚠️ 这两个数别挂错——本文先前把「32–33 步」挂在 100,000× 上，会把最坏情况所需的 owner 交易数少算三分之一。
于是固定的代币数量在带宽两端是这样：

| tier1 = N aPNTs | @ $0.02 | @ $100（可达最坏值） |
|---|---|---|
| 1 | $0.02 | **$100** |
| 100（现值） | $2 | **$10,000** |
| 5,000 | $100 | **$500,000** |

- 按发行价定档 ⇒ 价格走到 MAX 时 guard **宽 5,000 倍**，而 tier1/tier2 **永远调不回来**；
- 按最坏价定档 ⇒ conservative tier-1 只能是 **1 个 aPNTs**，即该账户终身禁止转出超过 $0.02 的量。

⇒ **(A) 不是「难」，是不可实现**，且这与铸多少币无关。**本仓据此关闭 (A)，倾向 (B)。**

### ✅ 档位已定（Jason，2026-09-01）——锚点 $30，其余八格由现有模板推出

**Jason 定的是一个数:`conservative` 档 tier1 = $30 的 aPNTs = `30 / 0.02` = **1,500 aPNTs`。**
其余八格**不是新设计的**,是由本仓既有模板的两条比例直接推出——这两条在
`configs/token-presets.json` 现有的 USDC / USDT / WETH / WBTC 上核对过——**12 格中 11 格成立，
有一个例外，见下表脚注**:

| 比例 | 值 | 出处 |
|---|---|---|
| profile **内** tier1:tier2:daily | conservative `1:10:50` · standard `1:10:20` · trader `1:10:25` | 12 格中 **11 格**成立；唯一例外 **`WETH.trader` = `1:5:25`**（`2/10/50`，按形状应为 `2/20/50`） |
| profile **间** tier1 阶梯 | conservative : standard : trader = **`1 : 5 : 20`** | 四个 token **4/4 全部一致**（USDC 100/500/2000、WETH 0.1/0.5/2、WBTC 0.01/0.05/0.2、USDT 同 USDC） |

> **关于那个例外**：aPNTs 的 trader 档跟的是其余三个 token 的 `1:10:25`，所以**它不影响本节任何一个
> aPNTs 数字**。`WETH.trader` 是既有笔误还是有意为之**未定**——把 tier2 从 10 改到 20 是**放宽**，
> 而 10 ETH 在美元上也说得通（≈$30k，同档 USDC 是 $20k），所以本仓**不动它**，留给 Jason 定。
> （本文早先一版写成"四个 token 全部一致"，是错的：这个例外是本仓自己先发现、并已报给 Jason 的，
> 却没有写进这句话——拿到了事实没接到用得上它的地方，与本文别处记录的是同一类错。）

于是（`decimals` 18）:

| profile | tier1 / tier2 / daily (aPNTs) | = USD @ $0.02 | 对比同档 USDC |
|---|---|---|---|
| conservative | 1,500 / 15,000 / 75,000 | $30 / $300 / $1,500 | 严 3.3× |
| standard | 7,500 / 75,000 / 150,000 | $150 / $1,500 / $3,000 | 严 3.3× |
| trader | 30,000 / 300,000 / 750,000 | $600 / $6,000 / $15,000 | 严 3.3× |

三档**一致地**比同档 USDC 严 3.3×（= $100/$30），说明模板形状被完整保留、只有锚点下移，
这正是「不另起一套」的检验:如果三档的倍率各不相同,就说明我在某处偷偷引入了新判断。

> ⚠️ **CI 绿 ≠ 这些数字被验证过。** `token-presets.json` 与 `check-token-presets.mjs` 里那张
> `EXPECTED` 是**同一个 commit 一起改的**，所以门禁通过只证明**两份拷贝彼此一致**，
> 不证明这九个值是对的。真正承重的是上面那套比例推导，以及 Jason 定的那个锚点。
> 门禁能挡的是**此后**任何一边被单独改动（负对照：只回滚 `EXPECTED` → `EXIT=1`）。
> 这些值会烘进不可变 guard，**别把「绿过」当成担保**。

⚠️ **档位是否够用,取决于「典型账户余额」,不是总供应量**（@repo:sp 更正,已接受）:
`dailyLimit` 管的是**单个账户**一天的支出,所以决定它咬不咬得住的是**那个账户的余额**,
和盘子多大无关——持有 1,000 aPNTs 的人,无论总量多少都碰不到 75,000 的日限。
（本文早先按总供应量算「形同虚设」的那段是错的分母,已删。这与本文上面关闭方案 (A) 时犯的
是同一类错:对着错误的量做推理。）

于是这套档位的含义,按余额读:

| 典型余额 | tier1 = 1,500 占比 | tier2 = 15,000 | daily = 75,000 |
|---|---|---|---|
| 15,000 aPNTs（$300） | 10% —— 小额单签 | ≈ 整个钱包 | 4.8× 够不到 |
| **2,780 aPNTs（$56）** | **54% —— 半个钱包单签** | 5.4× 够不到 | 27× 够不到 |
| 1,000 aPNTs（$20） | 150% —— 全钱包单签 | 够不到 | 够不到 |

⇒ **$30 锚点隐含了「典型成员余额 ≈ 15,000 aPNTs（$300）」这个前提**:那时 tier1 是钱包的
10%、tier2 覆盖整个钱包,正是分层想要的形状。**余额越小,固定绝对值覆盖的比例越大 ⇒ 越松**,
而 tier1/tier2 **永远调不回来**——和 (A) 被关死的理由同构,危险方向是余额偏小。

📌 **Sepolia 上有四个 aPNTs，生态分裂在三个上，而本仓接的是最旧的那个**（2026-09-01 上链核实，
起因是 sp 报 15,539 而本仓只读到 2,780——两边各读了不同的代币）：

| 地址 | version | totalSupply | 余额 @ `0xb5600060e6de5E11D3636731964218E53caadf0E` | 谁在接 |
|---|---|---|---|---|
| `0x696A73701b104c6cCBbAadDD2216788ea08EaB89` | **3.4.0** | 12,734,618 | **15,539** | **SDK `config.sepolia.json` · SP 当前 `deployments/config.sepolia.json` · DVT x402** ← 生态现役 |
| `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` | 3.4.0 | 22,630 | 1,328 | DVT relay 白名单 `targetToken_apnts` |
| `0xDf669834F04988BcEE0E3B6013B6b867Bd38778d` | **3.0.0-unlimited** | 378,709 | 2,780 | **本仓**（`token-presets.json` + `test-gasless-complete-e2e.ts:58`）· SP 已过期的 `config.sepolia-2-10.json`(2026-01-24) |
| `0x5Cfc992fD095D047c41A03E80f6e760899450Ae3` | **3.5.0** | 0 | — | 尚无人接（本文 P5b 刚验收） |

⇒ 三条结论：
1. **本仓 Sepolia 接的是 3.0.0-unlimited，落后生态一个版本**，且与 SP 一份 2026-01 的过期配置一致——
   说明这个地址是当初抄下来后再没跟过。**这是本仓的待办**，但要和 3.5.0 迁移一起做，不是单独换成 3.4.0。
2. **sp 的 15,539 与本仓的 2,780 都是真的**，只是各自读了不同代币。争的不是数字是标的。
3. ⚠️ **DVT 自己内部也是分裂的**：同一份 `sdk-dvt-config.testnet.json` 里
   relay 白名单用 `0x9e66B457…`、x402 用 `0x696A7370…`。已知会 @repo:dvt。

⚠️ **本仓在 Sepolia 测试所依据的代币，正是本仓在主网上拒绝引用的那一个形状**（@repo:sp 指出，
本仓用当初 B1 的同一套正反对照复核）：

```
0xDf669834…  version() = "XPNTs-3.0.0-unlimited"
             communityOwner() = 0xb5600060…（Jason EOA）  code = 0 字节
  模拟 mint 5,000,000（供应量的 13×）  从该 EOA → 成功(0x)
  同一调用从随机地址              → revert 0x8e4a23d6 …dead
对照：刚验收的 3.5.0 其 communityOwner 是 Safe，code = 171 字节
```

即 **P5 里的 B1 在本仓的 Sepolia 接线上同样成立**。测试网上「owner 能无限增发」本身不是安全问题
（那正是发测试币要用的能力，owner 就是 Jason），但它意味着两件事：
① 本仓测试与定档所依据的代币**落后生态一个版本、且无人共用**；
② 从它上面读到的余额，是**部署者随手铸的测试浮量**，不携带任何成员行为信息。

**对档位的意义（含 @repo:sp 的进一步收紧，本仓接受）**：真正该参照的是**将来实际接线的那个代币
上的成员余额**。而现在——

> **Sepolia 上根本不存在「典型成员余额」这个观测值。** 15,539 与 2,780 都是**部署者的测试浮量**，
> 分别在两个不同代币上，相差 5.6×；两者都不属于任何成员。本仓读到的
> CC-31 Safe 与两个 e2e 账户在该代币上余额均为 **0**。

⇒ **$30 锚点隐含的「典型余额 ≈ 15,000 aPNTs」这个前提，目前没有任何链上数据支持——正反皆无。**
它是一个**假设**，不是一个测量值。本文把它显式写出来，正是为了它不成立时有人能发现；
不要把上表任何一行当成已观测到的事实。

📌 **本仓待办（不阻塞主网）**：Sepolia 接线从 `0xDf669834…`（3.0.0-unlimited）迁走。
**目标是 3.5.0 `0x5Cfc992f…`，不是先跳到生态现役的 3.4.0**——3.5.0 已由本仓验收（owner 是 Safe），
中间再跳一版只会多一次迁移。前置是它有供应量可发（见 C）。

**这是给铸币计划的实质输入,不是阻塞项**:铸多少决定成员典型余额落在上表哪一行。

**所以要 Jason 定的其实是一个问题，不是两个（这点是 sp 提出的，我同意）**：
**新代币铸多少、铸给谁（目标供应量）** —— 它在 A/B 之上：
- (B) 没有目标供应量就没有分母，档位无从设起；
- (A) 已被上面的价格上界关闭，与供应量无关。

在铸币计划确定之前不要烘焙 aPNTs 配置 —— 反正 P5 的 B1/B2 也还没解除，不阻塞任何事。

> **来源标注（2026-09-01 更新）**：`APNTS_PRICE_MIN/MAX` 与「新代币从 0 开始」原为转述，
> **现已由本仓在 Sepolia 上独立读取证实**（见下节），不再是转述。上表的换算与 5,000× / 33 步是本仓自算。

**对本仓 tier 分档的影响**：`decimals` 已确认为 **18**（`xPNTsToken` 从不覆写 `decimals()`，继承 OZ 默认，
3.0.0/3.5.0 皆然），所以 27 个限额**无需再缩放**。但**目前没有可依据的 supply cap**——要有人从 Safe 调
`setIssuanceCap`，而那个数字还没人决定。如果我们要让 100/1000/5000 这类绝对值代表供应量的稳定比例，
**这个治理决定是本仓的前置条件**，且它现在卡在治理而非 sp。

**状态更新（2026-09-01，@repo:sp 回复）**：sp 已接受上述路径，**B1 + B2 合并到一次重新部署**（PR #399），
且发现比 clone 更深一层——`xPNTsFactory.implementation` 是 `immutable`，现网 2.1.0 工厂**只可能**产出
3.0.0-unlimited clone，所以**必须先发新工厂**。其 OP 主网 dry-run 已跑通：工厂
`xPNTsFactory-2.3.0-clone-optimized`、代币 `XPNTs-3.5.0`、`communityOwner` = CC-31 Safe
`0x51eDf11f…`（负对照：删掉 transfer 那行，同一 dry-run 报 owner 没落到 Safe）。目前卡在他们
`.env.optimism` 的 OP RPC 为空（原有两把 Alchemy key 泄露后已清除），恢复后一次 broadcast 即可。

⚠️ **上表那个地址 `0x0B41C780…` 不要接线**——新部署会产生**新地址**，sp 落地后会推给我们。
两条后续约束：
- **新代币不承接旧的 140,000 供应量。**本仓无需迁移，理由见下条。
- **新代币在 OP 主网上「已正确持有，但尚未接 gas」**（原文写的「设上限」已被 sp 自己更正，见上）：新工厂刻意以 `SUPERPAYMASTER = address(0)`
  部署，而 OP 主网仍跑 `SuperPaymaster-3.2.2` / `Registry-3.0.2`（pre-P0-3）。要等 OP 主网升到 V5 后由 Safe
  调 `setSuperPaymasterAddress` + `addAutoApprovedSpender`。**即：即便地址到手，OP 主网 aPNTs gasless 仍不可用**，
  这是主网 alpha 的独立前提，不要和 P5「填地址」混为一谈。

**本仓在旧代币上无余额（已验，2026-09-01）**：`balanceOf` on `0x0B41C780…` → Jason EOA
`0xb5600060…` = **0**，CC-31 Safe `0x51eDf11f…` = **0**；本仓在 OP 主网**没有任何部署**（仅本文档为计划）。
正对照：同一查询对 aPNTs owner EOA 返回 35,000e18、`totalSupply` 返回 140,000e18，所以 0 是真值不是查询失败。
⇒ **旧代币供应量不承接一事不阻塞本仓，无需为我们做迁移。**

### P5b. Sepolia 3.5.0 已交付并由本仓独立验收（2026-09-01）

Jason 调整了顺序:**先 Sepolia,OP 主网暂缓**。@repo:sp 已在 Sepolia 部署 `XPNTs-3.5.0`。
下列每一行都是**本仓自己 `cast call` 读的**,不是采信对方的部署日志或验证脚本
（理由见上节交接验收:验证器与被验对象出自同一次改动）:

```
aPNTs   0x5Cfc992fD095D047c41A03E80f6e760899450Ae3   (Sepolia)
factory 0xfd16CaA468992701D17a1603c8bEFE0613550da3

A1  communityOwner()   0x51eDf11f… = CC-31 Safe   且 code = 171 字节 ✅
A2  factory owner()    0x51eDf11f… = 同一 Safe                      ✅
A3  decimals()         18                                            ✅ → 27 个限额无需重算
    totalSupply()      0
    version()          XPNTs-3.5.0   ·  FACTORY() 与上面工厂一致（同工厂血统）
    factory version()  xPNTsFactory-2.3.0-clone-optimized
    APNTS_PRICE_MIN/MAX  1e15 ($0.001) / 1e20 ($100)   ·  aPNTsPriceUSD 2e16 ($0.02)
```

负对照:旧代币的 EOA owner `0x51Ac6949…` 在同一查询下是 **0 字节**——所以 171 是真读数,
不是「对什么地址都返回 171」。**A1 的判据是代码长度,不是地址串**这一点在此得到验证。

**`APNTS_PRICE_MAX = $100` 至此由本仓亲自读到**,上一节关闭方案 (A) 的论证不再依赖任何转述。

⚠️ **`configs/token-presets.json` 的 Sepolia aPNTs 仍刻意指向旧代币 `0xDf669834…`**,原因:
新代币 `totalSupply == 0`,拿它付不了 gas,而 `scripts/test-gasless-complete-e2e.ts:58` 用的是旧地址。
换过去要等铸币计划（C）落定,和 P5 是同一个纪律。

**已做彩排**（不入库,仅验证门禁行为）:把预设临时指向新代币跑
`--chain 11155111 --require-verified` → `EXIT=0`;同一地址但限额留成 6 位形状 → `EXIT=1`。
即主网地址到手时,**填对会过、填错会拦**,已经验证过而不是假设。

> @repo:sp 另报两条,支持本仓「自己验」的立场:① 他们为修「模拟里断言」而新加的验证器**犯了同一类错**
> ——在自己的 `require` 之前就读 `APNTS_PRICE_MIN/MAX`,指向旧 2.1.0 工厂时死在裸 `EvmError` 上、
> 把「不是 3.5.0」这条信息吞掉;② Codex 发现验证器会对一个「在 tx2→tx3 间隙被部署者 EOA **改动过**」
> 的代币报 OK(自铸、加白名单)——**owner 最终落到 Safe,不说明路上发生了什么**。
> 现已加断言 fresh-clone 状态(supply 0、无额外自动批准 spender、无自授权、限额为 initialize 默认),
> 上面那行 `totalSupply() == 0` 实际证的就是这个。

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
| 2026-09-01 | P5 记录 @repo:sp 交付的 aPNTs 地址并说明三条阻塞（B1 EOA 无限增发 / B2 clone 地址将变 / B3 预设 6 位小数 vs 链上 18 位，已修）；新增 aggregator 轮换 → tier-2/3 fail-closed 的运营窗口条目；新增 `scripts/check-token-presets.mjs`；记录 sp 重新部署路径（PR #399）+ 本仓旧代币零余额 + 新代币暂未接 gas（CC-46） |
