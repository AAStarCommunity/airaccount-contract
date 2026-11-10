# EIP-8141 行动计划 —— AirAccount 跟随以太坊持续演进

> 日期: 2026-11-10 | 状态: 提案，待 Jason 拍板 §2 的三个决策项
> 背景分析: [`eip-8141-analysis.md`](eip-8141-analysis.md)
> 取代: [`eip-8130-upgrade-plan.md`](eip-8130-upgrade-plan.md) 中的 Verifier 适配层方案（8130 已不是主线）

## 0. 前提与目标

- **前提**：EIP-8141 是 Draft，`requires` 13 个 EIP，是否进 Hegota 未定。合入主干 + 升级以**年**计。
- **目标**（Jason，2026-11-10）：在 8141 落地之前，改造当前合约，**把可能变化的部分抽象出来**，不影响现有能力和 feature；
  变化发生时，只调整/替换被抽象的部分。做不到的，列出来讨论。
- **不做什么**：不为 Draft 提前重写账户；不引入代理/UUPS；不动已部署账户（它们在 ERC-4337 上照常运行）。

---

## 1. 改进方案（核心：抽象"会变的部分"）

### 1.1 切分原则

把账户逻辑按"协议会不会吸收"切三层：

```
┌──────────────────────────────────────────────────────────────┐
│ 协议会吸收（薄、可替换）                                        │
│   签名验证 · 签名者身份 · 批处理原子性 · 支付授权 · 验证→执行传递  │
├──────────────────────────────────────────────────────────────┤
│ 接缝（本计划要建的 5 条 seam）                                   │
│   S1 SignerSet  S2 效果守卫  S3 委员会根镜像  S4 TxContext  S5 支付外置 │
├──────────────────────────────────────────────────────────────┤
│ 协议永远不做（厚、稳定）                                          │
│   金额分层 · 累计限额 · 社会恢复 · guardian timelock · 委员会名额   │
└──────────────────────────────────────────────────────────────┘
```

判断一段代码属于哪层的方法：问"8141 落地后，这段代码还需要存在吗？"
需要 → 下层（Policy）；不需要 → 上层；"需要但实现方式变了" → 它就是接缝。

### 1.2 五条接缝

每条接缝给出：今天的实现（4337 下即可落地）、8141 后的替换件、以及"不变量"（两种实现都必须满足的性质，作为测试基线）。

#### S1 —— SignerSet：把"谁签了"和"签够了没"切开

**今天**：`_validateSignature` 一个函数里既验曲线又决定 algId → tier。

**改造**：引入内部结构 `SignerSet`：

```solidity
struct SignerSet {
    bool  owner;          // owner ECDSA 或 owner passkey 之一已证明
    bool  ownerPasskey;   // 细分：passkey（COMBINED_T1 需要两者同时）
    uint8 committeeCount; // 已证明的委员会成员数（DVT）
    uint8 guardianMask;   // 已证明的 guardian 位图
    bytes32 sessionId;    // 会话密钥标识（0 = 非会话）
}
```

- "谁签了"：`_resolveSigners(hash, sig) → SignerSet`。今天由现有各 `_validate*` 产出；8141 下由 `SIGPARAM` 产出。
- "签够了没"：`_policyTier(SignerSet) → tier`，`_policyAllows(SignerSet, op)`。**只消费 SignerSet，不碰签名字节。**
- `AlgTierLib.algTier(algId)` 退化为 `_policyTier` 的一个兼容包装（algId → SignerSet 的固定映射），现有 algId 语义一字不变。

**8141 后**：新增 `_resolveSignersFromFrameTx()`：遍历 `TXPARAM_SIG_COUNT`，对每个 `SIGPARAM resolved_signer` 查自身存储的角色表（owner / committee / guardian），填 SignerSet。Policy 层零改动。

**不变量**：对任意签名输入，`_policyTier(_resolveSigners(...))` 与今天 `AlgTierLib.algTier(_deriveStoredAlgId(...))` 结果相同（差分测试，覆盖全部 algId × 长度边界）。

#### S2 —— 守卫从"调用路径内"改为"begin / commit 效果结算"

**今天**：`_enforceGuard` 在每次 `_call` 前解析 calldata（`_checkTokenGuard` + parser registry）。

**改造**：

```solidity
function _guardBegin() internal returns (GuardSnapshot memory);   // ETH + 已配置 token 的余额快照
function _guardCommit(GuardSnapshot memory, uint8 tier) internal;  // 差额 → 累计日额 / 分层检查，超限 revert
```

- `execute / executeBatch`：循环前 `_guardBegin()`，循环后 `_guardCommit()`。现有 per-call `_enforceGuard` **保留**（混合模式），
  因为 `approve() / permit()` 不改余额，效果守卫度量不到——这是 S2 的已知残余，见 §2 D3。
- `_guardCommit` 用差额记账替代 parser 对 transfer 类操作的解析；parser 只负责 approve 类。
- 跨 token 枚举只覆盖 `tokenConfigs` 里已配置的 token（守卫本来就是 opt-in per token），gas 上界 = 配置数 × 2 次 `balanceOf`。

**8141 后**：`_guardBegin / _guardCommit` 变成两个 DEFAULT 帧的入口（`snapshot()` / `settle()`），与 SENDER 帧组成一个原子批；
VERIFY 用 `FRAMEPARAM` 校验帧形状（首帧 snapshot、末帧 settle、中间全部带 atomic flag）后才 `APPROVE`。

**不变量**：对 `guard-non-bypass-analysis.md` 枚举的全部原生送出原语，`_guardCommit` 的差额 ≥ parser 解析出的金额（效果守卫不会少算）；
`GuardMeteringInvariant.t.sol` 的 128k-call invariant 在混合模式下继续通过。

#### S3 —— 委员会证明无状态化：根镜像进账户存储

**今天**：验证期读验证器的 `committeeActive() / requiredQuorum()` / epoch pin / 节点注册表（第三方存储）。

**改造**：

- 账户新增 `committeeRoot`（bytes32）+ `committeeQuorum`（uint8）+ `committeeEpoch`，由 owner 或 DVT 签名的 `refreshCommittee()` 写入（执行期，SSTORE 自身存储）。
- 验证期只读自身存储：节点提供 `(nodeKey, Merkle proof)`，账户验 proof 对 `committeeRoot`，数够 `committeeQuorum` 即过。
- 新 algId `0x0b`（名字待定，例如 `ALG_COMMITTEE_ECDSA`）：`[k 个 (nodeAddr, ECDSA sig, Merkle proof)]`，协议/预编译验 ECDSA，账户验 proof。
  **BLS 路径（0x01/0x04/0x05/0x09/0x0a）保留不删**（router 只增原则），新账户默认白名单换成 0x0b。
- **实测（2026-11-10，forge 原型，foundry 1.7.1）**：账户端 `verify()` = k × [ecrecover + depth-7 Merkle proof 对自身存储的 root]，叶子 `keccak(accountId, epoch, signer)`：
  k=2 → **29,277 gas**（620 B payload）；k=3 → 38,886；k=5 → 58,191；k=10 → 107,443。
  BLS 路径的同一组件 ~527k（CC-95）。预期 tier2 总量 ≈ 102k（tier-1 基线）+ ~30k + calldata ≈ **~140k，对比今天 629k**。原型见 issue #294。

**8141 后**：k 个节点签名直接放进 `signatures[]`（SECP256K1 条目），账户从 `SIGPARAM` 读 `resolved_signer`，验 proof 对 `committeeRoot`。`refreshCommittee` 走 SENDER 帧。

**不变量**：`committeeRoot` 过期（epoch 落后超过 N）时 tier-2/3 fail-closed（与 CC-116 的 committee-off fail-closed 同形）；
accountId 注入（CC-98 B2）在 Merkle 叶子里保留（叶子 = `keccak(account, epoch, nodeKey)`），提交方仍不能自选委员会。

**跨仓依赖**：dvt（节点输出 ECDSA 单签 + proof；sortition 不变）、kms（签名路径）、sdk（0x0b 编码）。见 §2 D2。

#### S4 —— TxContext：交易上下文的读取方式

**今天**：从 `PackedUserOperation` 读 `callData / nonce / signature`，`userOpHash` 由 EntryPoint 给。

**改造**：内部库 `TxContextLib`，统一出口：`sigHash()`、`opValue(i)`、`opTarget(i)`、`opCount()`。4337 实现从 `userOp.callData` 解 `execute/executeBatch`。
`_validationTierOk` 改用它，并顺带补上 batch 的逐项 value 检查（今天刻意跳过，因为没有统一读法）。

**8141 后**：实现换成 `TXPARAM(0x08)` / `FRAMEPARAM(i, value)` / `TXPARAM(0x09)`。调用方零改动。

**不变量**：4337 实现下 `opValue(i)` 之和 == `executeBatch` 实际转出的 ETH 之和（现有 Beta4 bundler 测试覆盖）。

#### S5 —— 支付/赞助保持外置；SuperRelay 定位为私有通道

**今天**：已经外置（SuperPaymaster 合约 + SuperRelay bundler）。账户不感知付款方。

**改造**：无代码改动。文档层：在 `PRODUCTION_READINESS.md` 与 sp/relay 的 INTERFACES 中写明"8141 下 SuperPaymaster 是非 canonical 付款方，
公共 mempool 同时只允许 1 笔在途（规范常量），**SuperRelay 是必需的私有通道，不是过渡件**"。

**8141 后**：SuperPaymaster 的 `validatePaymasterUserOp` 对应一个 VERIFY 帧 + `APPROVE_PAYMENT`，`postOp` 对应原子批末尾的 DEFAULT 帧。由 sp 仓库承担。

### 1.3 抽象之后，8141 落地时要换的东西（清单）

| 接缝 | 换掉 | 不动 |
|---|---|---|
| S1 | `_resolveSigners` 的实现（SIGPARAM 版） | Policy、tier 表、guardian/weight 逻辑 |
| S2 | begin/commit 的触发方式（DEFAULT 帧） | 差额记账、累计日额、单调配置 |
| S3 | 节点签名的容器（signatures[]） | committeeRoot / proof / quorum / fail-closed |
| S4 | TxContextLib 实现 | 全部调用方 |
| S5 | sp 仓库 | 账户 |

加上一个**新入口**：VERIFY 帧处理函数（读 TxContext → S1 → Policy → S2 形状校验 → `APPROVE`）。这是唯一"新增"而非"替换"的部分，也是 §2 D1 的根源。

---

## 2. 抽象解决不了、需要拍板的三件事

> 2026-11-10 Jason：D1 → D1-a（存量留在 4337）；D2 → 批准，跨仓以 issue 协调：
> dvt [YetAnotherAA-Validator#397](https://github.com/AAStarCommunity/YetAnotherAA-Validator/issues/397) ·
> kms [AirAccount#215](https://github.com/AAStarCommunity/AirAccount/issues/215) ·
> sdk [aastar-sdk#432](https://github.com/AAStarCommunity/aastar-sdk/issues/432) ·
> sp [SuperPaymaster#616](https://github.com/AAStarCommunity/SuperPaymaster/issues/616)；
> 本仓库 tracking [#294](https://github.com/AAStarCommunity/airaccount-contract/issues/294)。D3 见下。

#### D1 —— 已部署账户拿不到 8141 入口

账户不可升级。VERIFY 入口是新 ABI，无法后加到已部署账户。两个选项：

- **D1-a 接受存量留在 4337**（推荐）：已部署账户永远走 EntryPoint，功能完整，只是没有原生红利；新账户版本带双入口。
  符合项目"新功能 = 新版本 + 用户迁移资产"的既定原则。
- **D1-b 现在埋可替换入口**：账户 fallback 把未知 selector 委托给一个可（timelock）替换的 "FrameAdapter"。
  本质是局部可升级，**违反不可升级原则**，且这个 adapter 本身就是最高权限（它能 `APPROVE`）。不推荐，但列出。

#### D2 —— S3（BLS → ECDSA k-of-n）是跨仓改动

dvt 节点要输出 ECDSA 单签 + Merkle proof（sortition 逻辑不变），kms 签名路径、sdk 编码都要跟。
airaccount 侧可以先把 0x0b 的账户端做完并用 mock 节点测试，但主网价值取决于 dvt 排期。
需要决定：是否作为 dvt 的下一个里程碑（CC 任务），还是 airaccount 先行、dvt 后补。

#### D3 —— 效果守卫覆盖不了 `approve / permit`

余额差额度量不到授权。混合模式（效果守卫管 transfer 类，parser 管 approve 类）是唯一方案，
意味着 KI-14（parser 禁用）不能靠 S2 完全关闭，parser 仍要维护一个最小集合（ERC-20 `approve`、`permit`、Permit2）。
需要确认接受这个残余。

---

## 3. 分阶段计划

### Phase A —— 现在就做（v0.34 – v0.36，与 8141 是否落地无关，在 4337 下即是净收益）

| # | 任务 | 接缝 | 价值 | 依赖 |
|---|---|---|---|---|
| A1 | **已查明（2026-11-10）**：所有走 Pimlico 的 E2E（`e2e-v0.25.0…v0.28.0-bundler.ts`）只发过 Tier-1 owner-ECDSA op；tier-2/3 与 session-key 脚本全部用 `EntryPoint.handleOps` 直发——**它们从未经过公共 bundler**。ERC-7562：账户验证期只能读自身存储（STO-010）和关联存储（STO-021，`keccak(sender‖x)+n`）；非关联存储只在 op 含**已质押 paymaster/factory** 时可只读（STO-033）。router `algorithms[algId]`、委员会验证器的 `committeeActive()/requiredQuorum()`/epoch pin/节点表都是非关联 → **自付 gas 的 tier-2/3 与 session-key op 会被 7562 严格的公共 bundler 拒绝；有质押 paymaster 赞助时才放行**。剩余动作：写进 `known-issues.md`；加 Pimlico session-key 探针作为回归测试；确认 SuperPaymaster 质押状态（sp#616） | S3 前置 | 业务含义：今天 tier-2/3 只能靠我们自己的 relay 或质押的 SP，不是"任何 bundler 都能发" | 无 |
| A2 | S1：SignerSet / Policy 切分 + 差分测试 | S1 | 消灭 val/exec 脱节类 bug 的温床；为 8141 入口铺路 | 无 |
| A3 | S2：`_guardBegin / _guardCommit` 混合模式 + 与 parser 并跑对比 | S2 | 回答 KI-14 / #194；对齐 atomic batch | 无 |
| A4 | S3 账户端：`committeeRoot` 镜像 + 0x0b k-of-n ECDSA algId（mock 节点测试） | S3 | tier2 gas 629k → ~110k；验证期不读第三方存储 | D2 |
| A5 | S4：`TxContextLib` + `_validationTierOk` 覆盖 batch | S4 | 验证期 tier 检查完整化 | 无 |
| A6 | 算法撤销 `revokeAlgorithm(algId)`：owner 提案 + guardian 2-of-3 + timelock | PQ | 唯一缺的 PQ 退出路径；非升级账户必须赶上下个版本 | 无 |
| A7 | 小修：`AirAccountDelegate.validateUserOp` 改 `tryRecover`；PQ 文档 algId 表与代码对齐；S5 文档定位 | — | 一致性 | 无 |

排序理由：A1 是风险排查，最便宜；A2 是其它接缝的基础；A3/A4 各自独立、收益最大；A6 是 PQ 对齐里唯一的真缺口。

### Phase B —— 8141 进入 Review / Last Call 后

| # | 任务 |
|---|---|
| B1 | 账户 v1.0 "双入口"：保留 `validateUserOp`，新增 VERIFY 帧处理（S1 SIGPARAM 实现 + S2 帧形状校验 + S4 TXPARAM 实现）。SENDER 自调用的 `msg.sender == address(this)` 放行规则与 `SelfCallForbidden` 重新划界 |
| B2 | Passkey 走 `P256 + msg`：`WebAuthnLib` 退化为结构校验（`msg == sha256(authenticatorData ‖ sha256(clientDataJSON))`，challenge == sighash） |
| B3 | S3 节点签名迁入 `signatures[]`（与 dvt 联调） |
| B4 | sp/relay：SuperPaymaster 的 VERIFY + `APPROVE_PAYMENT` 帧实现；SuperRelay 私有通道正式化 |

### Phase C —— Hegota 确认 / 主网激活

| # | 任务 |
|---|---|
| C1 | 在 Sepolia（或 devnet）端到端：frame tx 走公共 mempool 的 Tier-1、走 SuperRelay 的 Tier-2/3 + 赞助 |
| C2 | 存量账户迁移指引（D1-a） |
| C3 | 重新测 `MAX_VERIFY_GAS` 下各 tier 的实际前缀 gas，更新 tier 文档 |

---

## 4. 跟踪信号（任一变化即重评本计划）

- EIP-8141 状态：Draft → Review → Last Call → Final
- Hegota 的 EIP 清单是否包含 8141（及其 requires：8037 双维 gas、7778、7825、7976）
- `MAX_VERIFY_GAS`（100k）：若上调到 ≥ 700k，张力 2 的 gas 结论要重算（存储规则结论不变）
- `MAX_PENDING_TXS_USING_NON_CANONICAL_PAYMASTER`（1）：若放宽，张力 3 重评
- canonical paymaster 的参考实现：若其形态是"通用 ERC-20 收费 + 可配置存储"，SuperPaymaster 的扣 xPNTs 部分或可套用

---

## 5. 验收标准

- 每条接缝落地时，§1.2 的"不变量"各有一个 forge 测试，且现有全量测试（940+）不减。
- A2 完成后：任意 algId 的 tier 由 `_policyTier(SignerSet)` 单点决定；`AlgTierLib` 只剩兼容映射。
- A3 完成后：`GuardOverheadGas.t.sol` 记录混合模式的开销；parser 与效果守卫的对比报告入 `docs/`。
- A4 完成后：Sepolia 实测 0x0b tier2 gasUsed，与 629k 基线对比入 CSV。
- A6 完成后：撤销 ECDSA 后 passkey 账户仍可操作的 E2E。

---

## 6. 任务拆分（建议开 issue 的粒度）

1. `A1` chore(7562): audit validation-phase foreign storage reads + document bundler acceptance basis
2. `A2` refactor(validation): SignerSet / Policy split with differential tests (no behavior change)
3. `A3` feat(guard): balance-delta guard begin/commit in execute/executeBatch (hybrid with parsers)
4. `A4` feat(committee): committeeRoot mirror + algId 0x0b k-of-n ECDSA committee (account side, mock nodes)
5. `A5` refactor(validation): TxContextLib + batch-aware `_validationTierOk`
6. `A6` feat(governance): revokeAlgorithm with guardian consensus + timelock
7. `A7` fix(delegate): tryRecover in AirAccountDelegate.validateUserOp; docs: PQ algId table sync; S5 positioning
8. 跨仓：CC 任务给 dvt（ECDSA 单签 + proof 输出）、sp（S5 定位）、sdk/kms（0x0b 编码）——在 D2 拍板后创建
