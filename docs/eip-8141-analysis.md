# EIP-7701 → EIP-8141 与 AirAccount 的对齐分析

> 作者: AirAccount Team | 日期: 2026-11-10
> 状态: 调研分析 | EIP-7701: Withdrawn (Superseded by EIP-8141) | EIP-8141: Draft (Created 2026-01-29)
> 姊妹文档: [`eip-8130-analysis.md`](eip-8130-analysis.md)（2026-03，Coinbase 的 Account Configuration 方案）
> 行动计划: [`eip-8141-action-plan.md`](eip-8141-action-plan.md)
>
> 规范事实均按 2026-11-10 的 <https://eips.ethereum.org/EIPS/eip-8141> 原文核对；
> 标注"（推断）"的是本文的判断，不是规范原文。

---

## 0. 一句话结论

EIP-8141 把 **签名验证、支付授权、批处理/原子性** 三件事从合约层收进协议层，
把 **"谁签了"** 变成协议给出的事实（`SIGPARAM resolved_signer`）。
它**不会**收走 **"签够了没"**：金额分层、累计限额、社会恢复、委员会名额——这些是 AirAccount 的核心，
协议永远不做。

AirAccount 今天的代码把两件事揉在一起（`_validateSignature` 既验曲线又定 tier）。
跟随以太坊演进的正确动作不是"为 8141 重写"，而是**把"谁签了"和"签够了没"切开**：
前者薄且可替换，后者厚且稳定。切开之后，8141 落地只替换前者；不落地，后者照样受益。

---

## 1. 规范校准（原文 vs 常见转述）

| 常见转述 | 规范原文（2026-11-10） | 对 AirAccount 的意义 |
|---|---|---|
| 非标准 Paymaster "有数量限制" | `MAX_PENDING_TXS_USING_NON_CANONICAL_PAYMASTER = 1`：非 canonical 付款方在公共 mempool **同时只能有 1 笔**在途 | 带积分/信用逻辑的付款方（SuperPaymaster）在公共 mempool 中等于不可用 |
| sig hash "避免攻击者修改未签名的帧" | sig hash = `keccak(0x06 ‖ rlp(tx))`，只把空 `msg` 条目的签名字节替换为长度；**不省略任何帧数据** | 签名方签的是完整帧列表 |
| 没提 | `FRAMEPARAM / FRAMEDATALOAD / FRAMEDATACOPY` 带 `frameIndex` 操作数，可读**任意帧**的 mode/target/value/data（越界 halt；只有 status/gas_used 对当前及之后的帧 halt） | VERIFY 帧里的账户代码可以检查后面所有 SENDER 帧的金额与目标 |
| 没提 | 验证前缀规则穿透整个调用树："SLOAD can be used only to access `tx.sender` storage, **including when reached transitively via CALL\*/DELEGATECALL**"。质押/信誉"removes … entirely"，**无替代豁免**（可读他人代码，不可读他人存储） | 验证期读 router / DVT 验证器 / SessionKeyValidator 的存储 → 公共 mempool 拒绝 |
| 没提 | `MAX_VERIFY_GAS = 100_000` 是**整个验证前缀的 `limits.execution` 之和 + 签名内在成本**；`MAX_VERIFY_STATE_GAS = 500_000` 同理 | >100k 的验证逻辑进不了公共 mempool |
| 签名方案三种 | `[scheme, signer, msg, signature]`：`msg` 可为显式 32 字节摘要，协议对 `msg` 验曲线（SECP256K1 2,800 / P256 6,700 / ARBITRARY 100 gas）；`SIGPARAM` 暴露 `resolved_signer`、`msg` | WebAuthn 的接口形态：协议验曲线，账户只验 `msg == sha256(authenticatorData ‖ sha256(clientDataJSON))` 且 challenge == sighash |
| Default code | 无代码且无 7702 指示符的地址：VERIFY 帧要求 SECP256K1 条目 `resolved_signer == target` 且 `msg` 为空，然后 `APPROVE(allowed_scope)`；SENDER/DEFAULT 视为空代码 | 裸 EOA 不委托即可被赞助、批处理 |
| `tx.origin` 语义变化 | `ORIGIN` 返回当前帧的 caller：DEFAULT/VERIFY 为 `ENTRY_POINT`，SENDER 为 `tx.sender` | `src/` 不用 `tx.origin`，无影响 |
| 原子批 | `ATOMIC_BATCH_FLAG = 0x4`；批 = 连续带标志的帧 `[i, j]`（i..j-1 带标志，j 不带，**j 属于该批**）；不得含 VERIFY；失败回滚到批首，已执行帧日志丢弃 | 可构造 `[SENDER…✓][DEFAULT settle]`：settle revert → 整批回滚 |
| 7702 | payload 无 `authorization_list`；已委托代码按 7702 语义执行 | `AirAccountDelegate` 仍可执行，但 default code 压缩了它的价值 |

其余常量：`FRAME_TX_TYPE = 0x06`，`MAX_FRAMES = 64`，`FRAME_TX_INTRINSIC_COST = 12000`，`FRAME_TX_PER_FRAME_COST = 475`。
`APPROVE` 作用域：`PAYMENT 0x1 / EXECUTION 0x2 / EXECUTION_AND_PAYMENT 0x3`；执行批准要求 `resolved_target == tx.sender`；
支付批准递增 sender nonce、设 `payer`、收取 `max_cost`。

---

## 2. 把 8141 投到 AirAccount 上：三类能力

对照 `src/core/AAStarAirAccountBase.sol`、`AAStarAirAccountV7.sol`、`AAStarGlobalGuard.sol`、`src/utils/CommitteeBLSLib.sol`：

### A. 协议会原生化的（我们今天做得很厚）

| 我们的实现 | 8141 对应 |
|---|---|
| `_validateSignature` algId 分派（`AAStarAirAccountBase.sol:660`）、内联 ecrecover、`WebAuthnLib`、Solady P256 | `signatures[]` 协议验证 + `SIGPARAM` |
| `_validateTripleSignature`（`:1107`）、`_blsAlgMode`（`:997`）、`CommitteeBLSLib.verifyAgg` | `signatures[]` 多条目 = 协议级多签容器 |
| `executeBatch`（`:1492`） | atomic batch |
| ERC-4337 paymaster `validatePaymasterUserOp / postOp` | `APPROVE_PAYMENT` + DEFAULT 后处理帧 |
| transient 队列传 algId/weight/sessionKey（`ALG_ID_SLOT_BASE`、`_setCallDataKey :1720`、`_deriveStoredAlgId :830`、`_populateExecAlg :782`） | 不需要：VERIFY 与 SENDER 在同一笔交易、同一 transient 上下文顺序执行 |

最后一行值得单独说：**CRITICAL-1、HIGH-1、HIGH-3、KI-11 这一整类"验证与执行脱节"漏洞，根源是 4337 把验证和执行拆成两次独立调用且 bundler 分开模拟。**
8141 的 VERIFY 还能跨帧读 `value`，tier 判定可以完整放进验证期（今天 `_validationTierOk` `AAStarAirAccountV7.sol:325` 刻意跳过 batch，就是因为验证期读不到累计值）。
这类 bug 在 8141 模型下结构性消失——它们是我们过去五个版本交的"4337 架构税"。

### B. 协议永远不会做的（我们的差异化，必须留在合约层）

- 金额分层 `requiredTier`（`:1449`）、`AlgTierLib`
- 全局守卫：累计日额、按 token 分层、单调只降（`AAStarGlobalGuard`）
- 社会恢复、guardian timelock、ForceExit、weight 弱化提案
- DVT 委员会 sortition + 每账户注入 accountId（CC-98）

与 `eip-8130-analysis.md` §4 的结论一致：协议层给"谁能授权、谁付钱"，不给"多大金额需要多强授权"。

### C. 与 8141 直接不符的三处（"张力" = 我们和它不一致、原样迁移会出问题的地方）

#### 张力 1 —— SENDER 帧绕过 `execute()`，守卫不在执行路径上

8141 的 SENDER 帧是协议以 `caller = tx.sender` **直接**调用 target，账户自身代码不参与执行。
而我们所有守卫——`_enforceGuard`（`:1598`）→ `recordSpend`、`_checkTokenGuard`（`:1782`）、session scope/velocity、hook `preCheck`——
都挂在 `execute / executeBatch` 里。原样迁移 = 守卫归零。

**可以用技术方案解决**，两条路：

- (a) 保守：VERIFY 用 `FRAMEPARAM` 检查所有 SENDER 帧 `target == address(this)`，强制经 `execute()`。放弃原生批处理红利。
- (b) **效果型守卫**（推荐）：帧形状 `[VERIFY][DEFAULT snapshot ✓][SENDER … ✓][DEFAULT settle]`，
  settle 在原子批末尾比较 ETH 与已配置 token 的余额差额并记账，超限 revert → 整批回滚。
  VERIFY 拒绝任何不含 snapshot/settle 的帧形状（跨帧可读，所以能做到）。
  这比今天的 calldata 解析（`CalldataParser`、KI-14 禁用、#194 under-meter、`UnparseableGuardedCall`）根本上更稳：
  度量的是**效果**而不是**意图**。残余：`approve()/permit()` 不改余额，仍需 calldata 识别——混合模式。

(b) 今天在 4337 的 `executeBatch` 里就能实现（循环前后快照），8141 来了只是把"开头/结尾"换成两个 DEFAULT 帧。

#### 张力 2 —— Tier-2/3 的 BLS DVT 验证进不了 8141 公共 mempool，而且是双重出局

- **gas**：Sepolia 实测 tier1 = 101,948 / tier2 = 629,363 / tier3 = 637,037 gasUsed（CC-95，n=10）；
  tier1→2 的 ~527k ≈ 外部 `validate()` 整段。按 [`2026-08-16-tier-bls-gas-optimization-analysis.md`](2026-08-16-tier-bls-gas-optimization-analysis.md) 的实测分解：
  pairing ~103k（EIP-2537 定价 37,700 + 32,600×2，**20%**）+ hash-to-curve ~66k（**13%**：expand_message + 2×MAP_FP2_TO_G2 预编译 + G2ADD）
  = 加密原语下限 **~154k**；其余 **~345k（67%）是验证器实现开销**（点解码、子群检查、每节点 128 B 注册公钥 SLOAD ≈ 8.4k、G1 聚合、calldata 解析、stake 检查）。
  ⚠️ 本文初稿写成"几乎全是 hash-to-curve"，是错的——该文档已明确指出那是未测量的推断。
  对 8141 的结论不变：**仅 pairing 一项（103k）就超过 100k 前缀上限**，实现再优化也进不了公共 mempool。
- **存储**：`_blsAlgMode` 读 `committeeActive()`、`verifyAgg` 读 `requiredQuorum()`、验证器内部读 epoch pin / 节点注册表、`validator.getAlgorithm`——
  全是 `tx.sender` 以外的存储，无质押豁免。

**结论不是"优化 BLS"，而是换容器。** 8141 的 `signatures[]` 本身就是协议验证的多签容器：
3 节点 2-of-3 = 2 条 SECP256K1 条目，协议验证 2 × 2,800 gas；账户 VERIFY 只需读 `SIGPARAM resolved_signer`，
对照**自身存储**里的委员会名单 / epoch root，数够 k 个即过。
BLS"一次 pairing 换 N 次验证"的收益要在签名者数量大时才兑现：ECDSA 路径实测斜率 ≈ 9.8k gas/签名者（含 310 B calldata + Merkle 证明），
BLS 即使实现做到极致也有 ~154k 固定下限 + 每节点公钥读取 ~2–10k，**交叉点约 20–50 个签名者**；以今天 ~470k 的实现则永不交叉。
sortition 把"节点池 N"和"签名者数 k"解耦（CC-98 已如此），k 不随 N 增长、证明深度只按 log2(N) 增长，所以 k ≤ 10 的委员会用 ECDSA，
BLS 留给 k 大的场景（SuperPaymaster slash、全集签名）——且若保留 BLS，签名者集合应改用**注册表 + 位图**（N=1000 → 125 B）而不是现在每签名者 512 B 的 Merkle 证明，否则 BLS 的"签名大小恒定"优势根本没有兑现。

#### 张力 3 —— SuperPaymaster 的商业模式与公共 mempool 不兼容

canonical paymaster = runtime code 完全匹配；积分、信用额度、债务逻辑不可能装进 canonical 字节码；非 canonical 又被限到 1 笔在途。

### 张力 2/3 对合约"意味着什么"——直白版

**不是"交易执行不了"。** 要分清两件事：

1. **ERC-4337 不会被 8141 关掉。** EntryPoint 是普通合约，bundler 照常 `handleOps`（用 type-2 或 frame tx 提交都行）。
   现有账户在 8141 上线后一字不改也照常跑，只是拿不到原生红利（公共 mempool、协议级签名验证、更低 gas）。
2. **"进不了公共 mempool"只影响"用 8141 原生交易类型、且走公共广播"这一条路。** 走私有通道（SuperRelay 直连 builder）完全可以。
   Tier-2/3 本来就要经过 DVT 的 relay，SuperPaymaster 本来就经 SuperRelay。

所以张力 2/3 的实际后果是：**SuperRelay 从"可选 bundler"变成"必需的私有通道"**——这要写进架构定位，不能再当过渡件。
Tier-1（owner ECDSA / passkey，只读自身存储，<100k）在未来版本可以进公共 mempool。

---

## 3. 其他发现

- **PQ 对齐缺口在"撤销"不在"新增"。** router 只增注册 + 账户 `approvedAlgorithms` 只增 + `validatorRouter` immutable 注入，已做到"地址不变、新增算法"（与 8141 的 PQ off-ramp 目标一致）。
  但没有任何路径禁用旧算法——量子时代 ECDSA 永远在白名单里。
  [`validator-upgrade-pq-analysis.md`](validator-upgrade-pq-analysis.md) 四阶段里有 `blockAlgorithm`，代码里没有。
- **文档漂移**：同一文档 §七把 0x04/0x05 留给 ML-DSA/FALCON，而代码 0x04/0x05 已是 CUMULATIVE_T2/T3，注释改为 0x10 留给 PQ（`AAStarAirAccountBase.sol:57`）。
- **7702 Delegate 的价值主张被 default code 压缩**：裸 EOA 不委托即可获得赞助与批处理，Delegate 剩下 guard + guardian rescue，KI-1（私钥永久有效）不变。
  小发现：`AirAccountDelegate.validateUserOp` 用 `ECDSA.recover`（畸形签名会 revert），主账户已改 `tryRecover`（M-C 修复）；验证期 revert 违反 ERC-7562，两者不一致。
- **自调用边界要重划**：8141 下 SENDER 帧自调用 `execute()` 的 `msg.sender == address(this)`；`onlyOwnerOrEntryPoint` 会拒绝，
  而 v0.24.0 为防自调用提权加的 `SelfCallForbidden` 与之方向相反。（推断：需要"仅在本账户自己的 frame tx 内、且 ORIGIN == ENTRY_POINT"这一类上下文判定来放行。）
- **今天的 ERC-7562 合规状况待确认**：`_blsAlgMode`、`verifyAgg`、`SessionKeyValidator.validate()` 都在验证期读第三方存储。
  仓库里没有记录现在 Pimlico / 主网 bundler 是靠什么放行的（验证器质押？测试网宽松？）。如果靠测试网宽松，主网会先于 8141 出问题。

---

## 4. 与 EIP-8130 分析的关系

`eip-8130-analysis.md`（2026-03）当时判断"8141 被采纳的可能性显著高于 8130"，并提出 verifier 适配层。
本文把那份"对齐表"推进了一步：8130 的 verifier 分离思想在 8141 里以 `signatures[] + SIGPARAM` 的形式出现，
而"分层 / 守卫 / 恢复必须留在合约层"的结论两份文档一致。8130 文档中的 `AirAccountVerifierAdapter` 不再需要，
取而代之的是行动计划里的 S1（SignerSet 与 Policy 分离）。

---

## 5. 参考

- EIP-8141 Frame Transaction: <https://eips.ethereum.org/EIPS/eip-8141>（requires 1559, 2718, 2780, 3529, 3607, 4844, 7594, 7702, 7708, 7778, 7825, 7976, 8037）
- EIP-7701（Withdrawn, superseded by 8141）: <https://eips.ethereum.org/EIPS/eip-7701>
- Ethereum Magicians 讨论: <https://ethereum-magicians.org/t/eip-8141-frame-transaction/27617>
- 本仓库: `eip-8130-analysis.md`、`eip-8130-upgrade-plan.md`、`validator-upgrade-pq-analysis.md`、`guard-non-bypass-analysis.md`、`2026-08-16-tier-bls-gas-optimization-analysis.md`
