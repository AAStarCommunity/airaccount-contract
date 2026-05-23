# Agent Account Architecture — AirAccount

> 综合分析文档：问题分析 · 行业调研 · 架构决策 · 创建路径 · 开发计划
> 最后更新：2026-05-22 | 对应里程碑：M7（助理型）/ M8（自主型）

---

## 1. 核心问题：Agent 如何获得签名密钥？

AI agent 是代码，无法使用指纹/Face ID，无法走 AirAccount KMS 的 WebAuthn 路径（KMS 生产流程要求 P256 passkey 认证）。

jhf：可以单独为Agent提供KMS服务，但要附属于某个人类的passkey（需要修改KMS代码），类似于路径1，助理Agent。

> **答复（2026-05-22）：** 正确。KMS 已有 ECDSA key 管理能力，扩展方向是：为 Agent 生成独立 ECDSA keypair，该 keypair 在 KMS 中绑定到人类 passkey 的授权范围——即"人类用 passkey 授权创建 Agent key，Agent 用 API Key 调用 KMS 签名"。这在 KMS 侧需要新增一个非 WebAuthn 的签名端点（`/kms/sign-agent`），验证方式改为 API Key + Agent ID 白名单而非 WebAuthn。参见 `docs/agent-assistant-flow.md` Step 1。

**Session Key 模式解决了这个问题**，关键在于把授权和执行分开：

```
授权阶段（需要人类指纹）:
  人类用 Touch ID → grantAgentSession(agentEOA, cfg) → 走 KMS + WebAuthn 路径

执行阶段（agent 不需要指纹）:
  agent 用 EOA 私钥签名 UserOp（algId 0x08）
  → 不经过 WebAuthn，私钥存 KMS TEE，通过 API Key 调用签名
```

jhf:你这个方案有个问题，就是agent他的私钥存哪里？换句话，他他必须使用KMS，KMS就是保存私钥的。

> **答复（2026-05-22）：** jhf 说得对，私钥必须有安全存储方案，不能裸放进程内存。三个选项：
> 1. **KMS TEE（推荐）**：Agent EOA 私钥存入 KMS 的 TEE，通过 API Key 调用 `/kms/sign-agent` 端点签名。私钥永不离开安全环境，即使 agent 进程被攻击也无法提取私钥。这是正式生产的推荐方案，但需要 KMS 侧新增非 WebAuthn 签名端点。
> 2. **进程内随机 key（session-only 模式）**：每次会话生成 `crypto.randomBytes(32)` 作为临时私钥，仅存在于内存中，进程退出即销毁。安全性分析见第 2 节。
> 3. **HSM/Secure Enclave**：企业级部署可用 AWS CloudHSM、Azure Dedicated HSM 等，与方案1类似但更去中心化。
> 当前 M8 设计选择方案1（KMS TEE），需 KMS 团队实现 `/kms/sign-agent` 端点。这是 M8 唯一尚未完成的基础设施依赖。

Agent 密钥生成：一次 `crypto.randomBytes(32)` 即可（或调用 KMS），无需任何生物特征。

---

## 2. Session Key 与 T2/T3 分级的关系

Session Key（algId 0x08）在 GlobalGuard 和 TierGuardHook 中均被映射为 **Tier 1**：

```solidity
// AAStarGlobalGuard._algTier() 和 TierGuardHook._algTier()
if (algId == ALG_SESSION_KEY) return 1;  // SESSION_KEY = Tier 1
```

行为含义：
- **Tier 1 限额内**：session key 直接通过，不触发 guardian co-sign（T2/T3 的联署要求被绕过）
- **超过 Tier 1 限额**：GlobalGuard 直接 revert（不升级到 T2，是直接拒绝）
- **spendCap**（AgentSessionKeyValidator 字段）：叠加在 Tier 1 日限额之上，是会话级的进一步约束

jhf：你这句话逻辑有问题吧，说可以绕过了T2T3，实际上他并没有达达T2T3的限额是吧？你把它控制在T1内部了。T一额度的内部了。那当然他到达不了T2T3的限额，他也就触发不了顶联合签名的这种要求，我认为他不是绕过呀，他只是没有触达（被你控制在T1内了）。

> **答复（2026-05-22）：** jhf 完全正确，表述修正。Session Key **不是绕过** T2/T3，而是被设计成始终在 Tier 1 范围内运行——GlobalGuard 硬限制 Session Key 最高只能达到 Tier 1 限额，自然永远不会触发 Tier 2/3 的联署要求。这不是安全漏洞，是正确的设计：授权时人类已经用指纹确认了操作范围，范围内的执行不需要再次联署。原文"Tier 1 硬顶限额为第二道保护"的表述更准确。

结论：Session Key 被**限制在 Tier 1 范围内**，不会触达 T2/T3。这是正确设计——授权时人类已经用指纹确认，授权范围内不需要再次联署。

---

## 3. M7 已实现：助理型 Agent（Session Key）

### 3.1 AgentSessionKeyValidator 约束体系（algId 0x08）

| 约束维度 | 字段 | 说明 | 行业对比 |
|---------|------|------|---------|
| 过期时间 | `expiry` (uint48) | session 自动失效 | 标准 |
| 调用目标白名单 | `callTargets[]` | 空=全允许，非空=只允许指定合约 | 标准 |
| 函数选择器白名单 | `selectorAllowlist[]` | 比 callTargets 更细粒度 | 领先 |
| 消费上限（累计）| `spendCap` (uint256) | 本会话累计消费上限 | 标准 |
| **调用频率（速率）** | `velocityLimit`/`velocityWindow` | 交叉相乘比较防绕过 | **领先，ZeroDev 无此特性** |
| **子委托** | `delegateSession()` | 子配置不能超父配置 | **独有** |
| 即时撤销 | `revoked` bool | 一笔 tx 即刻生效 | 标准 |

### 3.2 完整交互流程

```
Step 1: Agent EOA key 生成（KMS TEE 存储 或 进程内随机，见第1节）
Step 2: 人类用指纹签名 grantAgentSession(agentEOA, {expiry, velocityLimit, spendCap, callTargets, ...})
Step 3: agent 发 UserOp：signature = [0x08 | ECDSA(agentPrivKey, userOpHash)]
Step 4: AgentSessionKeyValidator.validateUserOp() 校验 expiry/revoked/velocity/spendCap/callTargets
Step 5: 操作在人类账户内执行，GlobalGuard Tier 1 日限额为第二道保护
Step 6: 到期或 revokeAgentSession() → 下一个 UserOp 即失效
```

jhf：agent 生成 EOA key = crypto.randomBytes(32)，存入运行时，嗯，我认为这是一个可行或者可选的思路，就是生成Aent生成一个临时的私钥，然后被授权。或如果这种方式的话，我觉得是有可能是安全的。换句话说，它只存在于对话期间对但带来另外一个问题，就是它使用不同的账户地址，它应该有一个确定性的东西，比如说Aent的ENSA的ID等等的。但它使用的账户呢是这个这个实时生成的。然后仅存在于它进程中啊不可被外部访问，但是代码要安全，而且即便呃误迁或者泄露或者这种情况下呢，我们有安全机。制来保证，比如它有上下限，他只能花这么多钱，那只能交互这些合约，就限制它的这种即便发生泄露或者是安全事件也是可控的。你觉得这个思路可以吗？换句话说，我们的私钥是每一次呃绘画就生成不同的私钥。呃，但如何保证这个私钥是安全被使用的呢？我希望你除了在我们这K机制之外呢，在在思考有没有其他的方式。比如说在进程中的私钥，我认为它是明文，它是裸体的。如果呃其他进程访问它或怎么样的。那是不是就造成泄漏了呢？所以这个问题你你再思考一下。呃，给一个全面的分析之后，看看我们这个思路和方向可不可行？但是 cryrypto random bit这个函数我认为它不是真正的随机，我是不是要引入硬件随机？

> **答复（2026-05-22）：** 这个问题很关键，以下是完整分析：
>
> **关于 crypto.randomBytes 是否真随机：**
> Node.js 的 `crypto.randomBytes()` 调用操作系统的 CSPRNG（密码学安全的伪随机数生成器）：
> - Linux/macOS：调用 `/dev/urandom`，底层使用 ChaCha20 算法，从内核熵池取种子
> - 内核熵池的种子来自：硬件中断时序、网络包到达时序、磁盘访问时序等真实随机事件
> - 结论：`crypto.randomBytes()` **已经是密码学安全的随机数**，不是伪随机，不可预测
> - 关于硬件随机（HWRNG/RDRAND）：Intel RDRAND 指令提供硬件随机数，可以作为额外熵源，但在高安全场景之外没有必要——OS的CSPRNG已足够。KMS 本身会使用 HSM 硬件随机数，所以如果通过 KMS 生成 key，硬件随机已自动包含。
>
> **关于进程内明文私钥的安全性分析：**
>
> | 威胁 | 进程内 randomBytes | KMS TEE |
> |-----|----------------|---------|
> | 内存读取（同用户进程）| ❌ 可被读取 | ✅ 不可读 |
> | 内存读取（root/OS 级）| ❌ 可被读取 | ✅ TEE 隔离 |
> | 进程 crash dump | ❌ 私钥会出现在 dump 中 | ✅ 不暴露 |
> | 代码漏洞（如序列化漏洞）| ❌ 可能泄露 | ✅ 不暴露 |
> | 泄露后损失上限 | ✅ session expiry + spendCap + callTargets 限制 | ✅ + 私钥本身不暴露 |
>
> **结论与建议：**
> 1. **进程内随机 key（session-only）可以接受，但有条件**：
>    - 适合：短期会话（数小时内），低价值操作（低 spendCap）
>    - 必须：session 有严格 expiry，并设置 callTargets 白名单
>    - 即便私钥泄露，攻击者能做的也只是在 session 有效期内、在白名单合约内、在 spendCap 内操作——损失上限可控
>    - 不适合：长期运行的 autonomous agent，高价值资产管理
> 2. **KMS TEE 是生产级推荐方案**：私钥永远在 TEE 内，任何访问都必须经过 KMS 鉴权，即便服务器被 root 攻击也无法提取私钥
> 3. **关于确定性问题**：进程内随机 key 每次会话不同，这是 Session Key 设计的一部分——Session Key 不是身份，是授权凭据。Agent 的身份由 ERC-8004 agentId（NFT）或 AgentRegistry 注册的 agentWallet 地址表示，不依赖于 session key

jhf：这个机制要引入链游实时游戏的场景测试，确认sessionkey符合实际场景...

> **答复（2026-05-22）：** 已新建独立文档 `docs/agent-gaming-scenarios.md`，包含链游典型场景分析、Session Key 适配性评估、以及行业方案对比。

### 3.3 已知待修复（Issue #32 → PR #36 已修复）

`callTargets` 和 `selectorAllowlist` 在 `validateUserOp()` 时校验，但在 `execute()` 时没有二次校验。

jhf：你check下，这个修复了么？

> **答复（2026-05-22）：** 已修复，PR #36（`feat/m8-p2-session-scope-enforce`）完成了该 issue：
> - `AgentSessionKeyValidator.enforceSessionScope()` 新增对 `revoked` 和 `expiry` 的检查
> - `TierGuardHook.preCheck()` 在 `algId == ALG_SESSION_KEY` 时调用 `enforceSessionScope()`，在 execute() 路径上二次校验 callTargets 和 selectorAllowlist
> - `_parseExecuteCalldata()` 正确跟随 ABI offset pointer，防止固定偏移绕过攻击
> - PR #36 已通过 Codex review（第二轮），仍有 MEDIUM-1（non-0x01 tag）和 MEDIUM-2（onInstall 哨兵问题）待处理

---

## 4. 行业调研：两条主路线

### 4.1 委托型 Agent（Session Key）

代表项目：ZeroDev Kernel, Safe + Modules, AirAccount M7, MetaMask Delegation Toolkit (ERC-7715/ERC-7710)

jhf：这个你能介绍一下吗？比如说委托型的，就这个他们都是使用的s key机制吗？他们使用使用过程是怎么使用的，能大概讲一下。对，比如说作为一个用户来说，如何委托一个agent。

> **答复（2026-05-22）：** 各主要协议的委托型 Agent 实现方式：
>
> **ZeroDev Kernel（Session Key）：**
> - 用户调用 `setSessionKey(sessionKey, validUntil, validAfter, permissions)`
> - `permissions` = `{target, functionSelector, valueLimit}` 数组
> - Agent 用 session key 签名 UserOp，Kernel 的 `SessionKeyValidator` 在 validateUserOp 时检查权限
> - 与 AirAccount 的区别：ZeroDev 没有 velocityLimit（频率限制），我们是领先特性
>
> **Safe + Modules（Session Key / Passkey Delegation）：**
> - Safe 7579 Adapter 让 Safe 支持 ERC-7579 模块
> - `SessionKeyPlugin` 模块管理 session key 的权限，包括 allowedFunctions、allowedContracts
> - 用户通过 Safe 多签批准 session key，agent 直接签名
>
> **MetaMask Delegation Toolkit（ERC-7715 + ERC-7710）：**
> - `wallet_grantPermissions` RPC 方法让用户授权 dApp/Agent 特定操作
> - `Delegator` 合约存储权限，`Caveats`（限制条件）链式组合
> - 用户体验：浏览器扩展弹窗显示"允许 AI 助手每天最多操作 50 USDC"，用户确认即完成委托
> - 与 AirAccount 的区别：MetaMask 的权限在 `Delegator` 合约存储，我们在 `AgentSessionKeyValidator` 存储；MetaMask 需要 MetaMask 钱包，我们是账户抽象层面的实现
>
> **用户委托 agent 的典型 UX（以 AirAccount M7 为例）：**
> ```
> 1. App 显示："授权 DeFi 助手 7 天内在 Uniswap 每天最多操作 30 USDC"
> 2. 用户指纹确认
> 3. 链上调用 grantAgentSession(agentEOA, {expiry, spendCap, callTargets})
> 4. Agent 立即可以在授权范围内执行，无需再次交互
> ```

### 4.2 自主型 Agent（独立账户）

代表项目：Coinbase AgentKit（CDP Wallet，2026-05 已有 69,000 活跃 agent）

jhf：这个自主体现在哪里呢？就比如说CDPwall，那自主的话等于给他钱，的自己去赚钱吗？账户内的所有的资产，所有的行为我们都不设限制，对不对？

> **答复（2026-05-22）：** CDP Wallet 的"自主"体现在以下几点：
> 1. **独立资产持有**：Agent 拥有独立的钱包地址，可以接收付款（如 x402 协议收费）、持有 ERC-20 代币、收取 DeFi 收益——这些资产归 agent 自己，不借用人类账户
> 2. **自主支出**：Agent 可以主动向外支付，不需要人类每次授权（类似公司给员工开一个独立的公务账户）
> 3. **Coinbase 的约束**：CDP Wallet 并非完全无限制——钱包有 Coinbase 的后台风控，出现异常交易会被拦截。并非"所有行为不设限制"
> 4. **AirAccount 自主型的约束**：我们的设计更保守，自主 Agent AirAccount 依然有 `dailyLimit` 全局日限额 + `GlobalGuard`，超出日限额的操作会 revert。人类通过 guardian 机制保持对账户的最终控制权（social recovery）。这是"有护栏的自主"，不是"完全自主"

### 4.3 核心权衡

| 维度 | Session Key（委托型）| 独立账户（自主型）|
|------|---|---|
| 密钥来源 | agent EOA（KMS TEE 或进程内随机）| agent 独立 Smart Wallet |
| 资产归属 | 操作人类账户资产 | agent 持有自有资产 |
| 权限边界 | 链上硬编码：金额/目标/频率/时间 | GlobalGuard 日限额 + tier |
| 撤销速度 | 即时（一笔 tx）| 慢（guardian 恢复，48h）|
| 自主支付 x402 | 消费人类账户余额 | 独立余额，原生支持 |
| 适合场景 | 助理型：代用户执行有限操作 | 自主型：独立商业模式 |

jhf：呃，关于叉402自自动支付这个嗯，就是第一种类型的A的账户。首先我们有没有有了之后，我们进行这个X402的测试名，就比如说我授权了一个agent。然后他他可以调用我账户内的余额，他访问一个网站的时候，这个网站说叉402需要付费，他就自动的从我的账户扣除了可能需要付的小额费用。我说的对不对。我希望我们的账户第一种类型的把它完整的产品化之后要进行这个测试。当然还有其他的这个表格里边的一些，比如说嗯这个这个权限编界的测试啊，撤销呀，包括一些其他的完整的端到端的测试。

> **答复（2026-05-22）：** 理解正确。流程：
> ```
> 助理型 agent 访问支持 x402 的 API →
> API 返回 HTTP 402 + payment info（金额、目标地址）→
> Agent 构造 UserOp（sender=humanAirAccount, calldata=transfer(paymentAddr, amount)）→
> 签名用 session key（algId=0x08）→
> AgentSessionKeyValidator 校验：paymentAddr 在 callTargets 内 + amount 在 spendCap 内 →
> 执行，从人类账户扣款
> ```
> 
> 需要列为产品化测试项（M8 后）：
> - [ ] x402 支付端到端测试（助理型 agent）
> - [ ] callTargets 白名单功能测试（精确限制到目标合约）
> - [ ] velocityLimit 频率限制测试
> - [ ] spendCap 累计上限测试
> - [ ] 即时撤销（revokeAgentSession）测试
> - [ ] session 自动过期测试

---

## 5. 架构决策（最终方案）

### 决策 A：助理型 Agent → Session Key（M7 已实现）

无需新账户，agent 获得受限的人类账户操作权。适合 DeFi 自动化、定投、通知响应等场景。

jhf: 但我记得我们讨论之后，我们是实现的，但是agent如何保存私钥，其实我们还没有实现嘛。嗯，包括是KMS保存，还是在进程内持有，这个我们还没确定或者我开始是想KMS保留。现在我又倾向于支持，如果足够安全的话，我支持进程内随机数生成。但这个随机数最好是从硬件随机数获得，这样不好预测对嗯，硬件的话可以调用KMS的这个硬件随机数生成KMS本身是支持这个的。

> **答复（2026-05-22）：** 当前状态确认：
> - **合约层（M7）**：AgentSessionKeyValidator 已完整实现，validateUserOp 校验、enforceSessionScope 执行路径校验（M8 PR #36 补全）均完成
> - **KMS 层（待实现）**：非 WebAuthn 签名端点尚未实现，这是 M8 唯一的基础设施缺口
> - **推荐方案**：优先实现 KMS TEE 路径（`/kms/sign-agent` + API Key 鉴权）；在 KMS 端点可用前，进程内随机 key 可作为开发/测试环境临时方案
> - **关于硬件随机数**：推荐方式是通过 KMS 的 HSM 生成 key（KMS 本身已使用 HWRNG），而不是在应用层调用 RDRAND。应用层的 `crypto.randomBytes()` 已经足够安全（见第1节答复），额外引入 HWRNG 对安全性提升有限但增加了依赖复杂度。

### 决策 B：自主型 Agent → 人类用 passkey 创建专用 AirAccount（M8 实现）

**不造新的 AgentAccount 合约类型**，使用标准 AirAccount，新增工厂函数简化创建流程。

**核心理由**：
- 最小代码改动（~30 行新工厂函数）
- Agent 获得完整 AirAccount 特性：GlobalGuard、social recovery、ERC-7579 模块
- 人类用现有 passkey 创建，UX 与创建自己的账户一致
- ERC-8004 自然对接：人类持有 agentId NFT，agent account = execution wallet
- Guardian 简化：人类账户自动成为 guardian1，只需 1 个外部签名

jhf: 那第一种账户呃，决策A或者路径一，我们依然要给这个agent注册erRC8004啊，这个你check一下，我们做了吗？

> **答复（2026-05-22）：** 现状 check：
> - **`setAgentWallet(agentId, agentWallet, registryAddr, sig)`**：调用 `AgentRegistry.registerAgent(agentWallet, sig)` ✅
> - **`IdentityRegistry.register(agentURI)`（ERC-8004 NFT 铸造）**：当前代码**没有**调用，未实现 ❌
> - **结论**：我们目前只实现了 AgentRegistry 注册（SuperPaymaster 赞助所需），但未实现完整的 ERC-8004 NFT 铸造（`IdentityRegistry.register`）
> - **意义**：ERC-8004 NFT 是身份凭证（人类持有 NFT 代表"我拥有这个 agent"）。如果不铸造 NFT，身份层面是不完整的。
> - **建议**：将 ERC-8004 注册（`IdentityRegistry.register(agentURI)`）作为 M8 的可选步骤补充实现，或作为 M9 规划。当前不影响合约安全性和 gas 赞助功能。

jhf: 另外我们支持ERC-7579 模块？这个体现在哪里？是技术标准，我们支持，但是我们实际上没做我有点忘记了，我们的模块都可以7579标准嘛。其他人的汽油气酒模块可以安装到我们的wallet上面？

> **答复（2026-05-22）：** AirAccount M7 完整实现了 ERC-7579 模块接口：
> - `installModule(typeId, module, guardianSig)` ✅
> - `uninstallModule(typeId, module, data)` ✅
> - `isModuleInstalled(typeId, module)` ✅
> - `supportsModule(typeId)` ✅ — 支持 type 1（Validator）、2（Executor）、3（Hook）
>
> **自己的模块（均为 ERC-7579 标准实现）：**
> - `AgentSessionKeyValidator`：type 1 Validator
> - `TierGuardHook`：type 3 Hook
> - `ForceExitModule`：type 2 Executor
> - `AirAccountCompositeValidator`：type 1 Validator
>
> **外部模块兼容性：** 理论上任何实现 `IERC7579Module` 接口的合约都可以安装，但有两个限制：
> 1. 安装需要 guardian 联署（防止恶意模块安装），不像某些协议那样 owner 单签即可
> 2. 我们的 `_activeHook` 只支持一个 Hook 同时激活（ERC-7579 规范允许单 hook）
>
> 所以从规范层面：外部 ERC-7579 兼容模块可以安装；从实践层面：安装门槛高（guardian 联署），适合受信任的模块。

### 决策 C：精简 AgentAccount 合约（未来可选，非当前优先项）

若未来需要去掉 guardian 恢复、内置 velocity 限制的精简合约，可基于现有合约派生 `AgentAccount.sol`。当前不实现。

---

## 6. Agent Account 所有创建路径

### 路径 1：助理型 Session Key（M7，当前可用）

```
适用：agent 代替人类执行有限操作，不需要独立持有资产

人类账户（已有）
  ↓ 人类用 Touch ID 签名
  grantAgentSession(agentEOA, {expiry, velocityLimit, spendCap, callTargets})
  ↓
AgentSessionKeyValidator 存储 session 配置
  ↓
Agent 用 EOA key 直接签名发 UserOp（algId 0x08）
  ↓ 私钥存储：KMS TEE（推荐）或进程内随机（开发环境）
在人类账户内受限执行，Tier 1 硬顶 + spendCap + callTargets 约束

无需新账户部署，即时生效，即时可撤销
```

### 路径 2：自主型 Agent AirAccount（M8，新增工厂函数）

```
适用：agent 需要独立持有资产，有独立商业模式

Step 1: 为 agent 生成 EOA key（KMS TEE 生成，API Key 授权签名）
Step 2: 人类 AirAccount 调用（指纹签名 UserOp）：
  factory.createAgentAccount(agentKey, agentId, guardian2, g2Sig, deadline, agentDailyLimit)
  ↓
  salt = keccak256("AASTAR_AGENT_V1" || agentKey || humanAccount || agentId)  — 确定性地址
  guardian1 = msg.sender（humanAirAccount）   — 自动设置，无需额外签名
  guardian2 = 传入参数                        — 需要 1 个签名（含 deadline 防重放）
  guardian3 = defaultCommunityGuardian       — 自动注入
  ↓
Agent AirAccount 部署完毕：
  owner: agentKey（agent 用此 key 签名 UserOp，algId=0x02）
  guardians: [humanAirAccount, guardian2, community]（2-of-3 恢复）
  dailyLimit: agentDailyLimit

所需签名数：1 个新签名（guardian2），相比 createAccountWithDefaults 减少 1 个
人类账户是 guardian → 可通过社会恢复找回 agent 账户
```

jhf：嗯，针对你这个路径2，我有两个疑问。第一个就是agent生成的EOA的这个private key，你是用random byte生成，它这个私钥存在哪里，你能告诉我它是如何保证安全的，能告诉我么？另外你这个私钥是如何签交易的对你既然自己保留私钥，那外部的交易，你怎么签署，对你是明文保存，还是你自己维护的KMS？解释一下。。第二个就是你这个ge定有两个，那它的恢复机制是怎么样的？为什么两个呀？那换句话说，必须两个A两个ge定都签才能恢复，是这意思吗？这是怎么设计的？

> **答复（2026-05-22）：**
>
> **私钥安全：** 自主型 Agent 的 EOA key 使用 KMS TEE 存储（详细分析见第1节答复）。签名流程：Agent 运行时通过 API Key 调用 KMS 的 `/kms/sign-agent` 端点，KMS 在 TEE 内签名后返回签名结果，私钥永不离开 TEE。
>
> **Guardian 数量和恢复机制：** 是 3 个 guardian（不是 2 个），恢复阈值是 **2-of-3**，任意两个 guardian 同意即可恢复（不需要三个全部同意）：
> - `guardian1` = humanAirAccount 合约地址（工厂自动注入，人类用指纹控制）
> - `guardian2` = 调用方传入（人类的备用设备、亲友账户，或人类自己的 passkey 地址）
> - `guardian3` = defaultCommunityGuardian（工厂自动注入，社区 Safe 多签）
>
> 恢复场景举例：若 agentKey 被盗，人类用 humanAirAccount 发起 `proposeRecovery`（1票），再由 guardian2 或 community 再投 1 票，48h timelock 后执行恢复，更换 agentKey。
>
> 为什么设计成 3 guardian：这是继承了标准 AirAccount 的 2-of-3 社会恢复机制。保证即便其中一个 guardian 不可用，另外两个也能完成恢复。

### 路径 3：手动 OAPD（高级用法，当前可用）

```
使用现有 createAccountWithDefaults，人工推导 salt：
  salt = keccak256(abi.encodePacked(humanOwner, dappId))
  factory.createAccountWithDefaults(agentKey, derivedSalt, g1, g1Sig, g2, g2Sig, limit)

需要 2 个外部签名，无工厂层的"agent"语义，地址可预测
适合：熟悉底层的开发者，需要完全控制 guardian 配置
```

jhf: 你这就是用OAPD这个方式啊，从这个主钱包派生不同的钱包吧，这不就OAPD的核心思路嘛，然后这跟agent也没有直接的关联，就是给他生成个账户，对不对？我们现在OAPD跟比如说核心的A账户有什么区别？它的创建过程，你给我看代码给我解释一下，忘记了。

> **答复（2026-05-22）：** 对，路径3本质是 OAPD，与 agent 没有直接关联，只是"给任意用途创建一个独立账户"。
>
> **OAPD（One Account Per DApp）核心思路：** 对每个应用/场景用不同的 salt 部署独立账户，账户地址不同 → 不同 DApp 看不到用户的全局行为，保护隐私。
>
> **创建过程（代码）：**
> ```solidity
> // AAStarAirAccountFactoryV7.createAccountWithDefaults()
> // salt 由用户自己计算（例如 keccak256(humanOwner, dappId)）
> bytes32 acceptHash = keccak256(abi.encodePacked(
>     "ACCEPT_GUARDIAN", block.chainid, address(this), owner, salt
> )).toEthSignedMessageHash();
> // 验证 guardian1Sig 和 guardian2Sig
> // 部署 clone，初始化 owner + 3 guardians（g1, g2, community）
> ```
> 
> **与核心 AirAccount 的区别：** 没有区别——路径3创建的就是一个标准 AirAccount，只是创建时 `owner` 是一个 EOA（而非 passkey），salt 由调用方自定义。没有 `AgentAccountCreated` 事件，工厂不知道这是"agent 账户"。
>
> **与路径2的区别：** 路径2的 `createAgentAccount()` 多了：
> - `msg.sender` 自动成为 guardian1（无需签名）
> - 专属 salt 命名空间（防前运行）
> - `AgentAccountCreated` 事件（链上可追溯）
> - `deadline` 参数（签名防重放）

### 创建路径对比

| | 路径 1（Session Key）| 路径 2（Agent AirAccount）| 路径 3（手动 OAPD）|
|---|---|---|---|
| 部署新账户 | ❌ | ✅ | ✅ |
| Guardian 签名数 | 0（人类自己授权）| 1 | 2 |
| Agent 独立持有资产 | ❌ | ✅ | ✅ |
| 即时撤销 | ✅ | ❌（48h）| ❌（48h）|
| 标准化程度 | ✅ 新函数 | ✅ 新函数 | ⚠️ 手动 |
| 适合场景 | 助理型 | 自主型 | 开发者 |

jhf: Guardian 签名数,你这个给我解释一下，我没看懂为什么s key是0，这个agent aircount就是一路径三不用解释了，它本身就是至少两个前面加一个社区的公共guardian。额外有一个问题，就是我们社区多签作为公共的gar定，那创建这个账户的时候，这个 Guard定需不需要社区多签去做一个签名啊，我们现在的过程是怎么样的？这个默认gar定是怎么实现签名的？你看代码给我解释一下。

> **答复（2026-05-22）：**
>
> **Guardian 签名数说明：**
> - 路径1（Session Key）= 0 个 guardian 签名：不部署新账户，只是在人类已有账户内调用 `grantAgentSession()`。这个函数只需要账户 owner（人类）签名（通过 UserOp），不需要 guardian 签名。guardian 是账户恢复用的，日常操作不需要。
> - 路径2（Agent AirAccount）= 1 个签名：guardian1 = humanAirAccount（自动，无需签名），guardian2 = 需要签名，guardian3 = 社区（自动，无需签名）。所以共 1 个额外签名。
> - 路径3（OAPD）= 2 个签名：guardian1 和 guardian2 各需要签一次 acceptHash。
>
> **社区 Guardian 不需要签名，原因如下（代码证据）：**
> ```solidity
> // AAStarAirAccountFactoryV7._buildDefaultConfig()
> return AAStarAirAccountBase.InitConfig({
>     guardians: [guardian1, guardian2, defaultCommunityGuardian],  // 直接注入地址
>     ...
> });
> ```
> 工厂在 constructor 时已经确定了 `defaultCommunityGuardian` 地址。账户创建时直接把该地址写入 guardian 配置，**不验证任何签名**。工厂本身就是信任锚——工厂部署者（AAStar 团队）已经在链下确认了这个社区 Safe 地址，合约层面直接信任。
>
> 换句话说：社区 guardian 的"同意"发生在工厂部署时（AAStar 团队与社区 Safe 达成协议），而不是每次账户创建时重新确认。

---

## 7. ERC-8004 集成

ERC-8004 是身份注册层，叠加在账户结构之上：

```
人类调 IdentityRegistry.register(agentURI) → ownerOf(agentId) = 人类（谁注册谁持有）
人类调 AirAccount.setAgentWallet(agentId, agentAccountAddr, agentRegistryAddr, sig)
  → AgentRegistry.registerAgent(agentAccountAddr, sig)
  → agentWalletOwner[agentAccountAddr] = humanAirAccount

SuperPaymaster 查询:
  AgentRegistry.isRegisteredAgent(agentAccountAddr) → true → 赞助 gas
```

jhf: 嗯，我确认一下，作为一个agent，它首先在我们的agent registry呃去做注册。那因为这个注册是双向的，就是呃谁拥有这个agent，agent的主人是谁，这两个都会被记录下来，对吧？然后呢，ERC8004这个事情，我要你确认一下，我们究竟在agt注册的时候做没做。换句话说，我希望我们是符合完整的ERC8004标准。换句话说，这些该注册的，我们都要注册的。这个事情你帮我check一下，是不是我相关的注册代码把这个都完成了。？

> **答复（2026-05-22）：**
>
> **AgentRegistry 双向注册确认：** ✅ 已实现
> - `agentWalletOwner[agentWallet] = msg.sender`（谁的agent）
> - `ownerAgents[msg.sender][]`（拥有哪些agents）
> - `getHumanOwner(agentWallet)`、`getAgents(humanOwner)` 双向查询均可
>
> **ERC-8004 完整性 check：** ❌ 未完整实现
>
> 完整 ERC-8004 路径应该是：
> 1. `IdentityRegistry.register(agentMetadataURI)` → 铸造 agentId NFT → `ownerOf(agentId) = humanAirAccount` ← **当前未实现**
> 2. `AirAccount.setAgentWallet(agentId, agentWallet, registryAddr, sig)` → 调 `AgentRegistry.registerAgent()` ← **已实现**
>
> 当前只做了步骤2，没有步骤1。`setAgentWallet` 函数参数 `agentId` 传入了但没有实际链上验证（没有调用 IdentityRegistry 去验证该 agentId 确实属于调用者）。
>
> **影响范围：** 不影响 SuperPaymaster gas 赞助功能（只看 AgentRegistry）；影响的是 ERC-8004 标准合规性和 agent 身份的 NFT 证明。
>
> **建议：** 将完整 ERC-8004 集成（部署并集成 IdentityRegistry 合约）列为 M8 可选项或 M9 计划。

**为何不直接用 ERC-8004**：NFT 归属于人类，不在 agent 执行钱包上。ERC-8004 没有反向查询（executionWallet → registered?）。需要 AgentRegistry 维护反向映射。

---

## 8. M8 开发计划（三个并行 PR，合并为 r12 部署）

### PR 状态（2026-05-22）

| PR | 分支 | 状态 | 测试数 | Codex 判决 |
|----|------|------|--------|-----------|
| #34 | feat/m8-p1-agent-registry | 被 #38 取代 | — | — |
| #38 | fix/issue-37-agent-registry | OPEN，待合并 | 713 | REQUEST_CHANGES（HIGH-1/2 剩余）|
| #36 | feat/m8-p2-session-scope-enforce | OPEN，待合并 | 690 | REQUEST_CHANGES（MEDIUM-1/2 剩余）|
| #35 | feat/m8-p3-agent-account | OPEN，待合并 | 718 | REQUEST_CHANGES（MEDIUM-3 剩余）|

### 剩余 HIGH 问题（阻塞合并）

**HIGH-1**（AgentRegistry 注册者无校验）：任何 EOA 可注册 → 获得 SuperPaymaster 赞助。修复方案待讨论：工厂 allowlist vs 接口检查。

**HIGH-2**（ECDSA 证明与 AirAccount agent wallet 不兼容）：`createAgentAccount()` 创建的 agent 账户是智能合约，无法用 ECDSA 证明自身地址，导致该类 agent 无法在 AgentRegistry 注册。修复方向：ERC-1271 fallback 或工厂直接注册路径。

### 原有 PR 1-3 描述（开发参考，已在各 PR 中实现）

[以下为原始开发规划，实际实现以各 PR 代码为准]

### PR 1：feat/m8-p1-agent-registry（Issue #31）→ 已由 PR #38 取代

**目标**：修复 agent 身份注册静默失败，启用 SuperPaymaster 的 agent gas 赞助功能。

**实际实现与规划的主要差异：**
- `registerAgent()` 升级为需要 ECDSA 签名证明（HIGH fix）
- 新增 O(1) swap-and-pop 删除（MEDIUM gas fix）
- 新增 `getAgentsPage()` 分页查询
- `setAgentWallet` 第4个参数 `agentWalletSig` 传透给 `registerAgent()`

---

### PR 2：feat/m8-p2-session-scope-enforce（Issue #32）

**目标**：在 `execute()` 路径上强制校验 Session Key 的 `callTargets` 和 `selectorAllowlist`。

**已实现**：
- `TierGuardHook.preCheck()` 在 `algId == ALG_SESSION_KEY` 时调用 `AgentSessionKeyValidator.enforceSessionScope()`
- `_parseExecuteCalldata()` 正确跟随 ABI offset pointer（防固定偏移绕过）
- `enforceSessionScope()` 新增 `revoked` 和 `expiry` 检查
- `onInstall` idempotency（`AlreadyInstalled` guard）
- `executeBatch` 在 session key + hook 组合下 revert（临时限制）

---

### PR 3：feat/m8-p3-agent-account（Issue #33）

**目标**：新增 `createAgentAccount()` 工厂函数，让人类用 passkey 为 agent 创建专用 AirAccount。

**已实现**：
```solidity
function createAgentAccount(
    address agentKey,
    bytes32 agentId,
    address guardian2,
    bytes calldata guardian2Sig,
    uint48 deadline,        // NEW: 签名有效期防重放
    uint256 dailyLimit
) external returns (address account)
```

**与原规划的主要差异：**
- `agentId` 类型改为 `bytes32`（支持 ERC-8004 tokenId 和 UUID）
- 新增 `deadline` 参数
- salt 命名空间改为 `keccak256("AASTAR_AGENT_V1", agentKey, humanOwner, agentId)`（防跨命名空间前运行）
- guardian uniqueness 检查增加 `!= defaultCommunityGuardian`
- `AgentAccountCreated` 事件增加 `guardian2` 和 `dailyLimit` 字段

---

## 9. 三 PR 依赖关系与部署顺序

```
PR #38 (AgentRegistry)        ─┐
PR #36 (Session Scope)         ├─→ 三个 PR 均可独立开发，无代码依赖
PR #35 (Agent AirAccount)     ─┘

合并条件：
  所有 Codex HIGH 问题修复后才可合并

r12 部署内容（三个 PR 合并后）：
  - 新合约：AgentRegistry.sol
  - 修改合约：AAStarAirAccountBase.sol（setAgentWallet + AgentWalletSet 事件）
  - 修改合约：AgentSessionKeyValidator.sol（enforceSessionScope + revoked/expiry 检查）
  - 修改合约：TierGuardHook.sol（preCheck session scope + onInstall idempotency）
  - 修改合约：AAStarAirAccountFactoryV7.sol（createAgentAccount + deadline）

链上配置（r12 部署后，非合约升级）：
  SuperPaymaster.setAgentRegistries(agentRegistryAddr, reputationRegistryAddr)
```

---

## 10. 每个 PR 的流程要求

1. 在对应 feature 分支开发
2. 完整单元测试 + 回归测试（`forge test --summary` 全绿）
3. 调用 Codex 进行代码 review（Tier 1），直到无问题
4. 提交 PR，PR 描述包含：变更说明、测试覆盖、影响范围
5. PR review 通过后合并至 main

---

*最后更新：2026-05-22*
*关联 Issues：#31 #32 #33 #37 | 参考：[AgentSessionKeyValidator](../src/validators/AgentSessionKeyValidator.sol) · [TierGuardHook](../src/core/TierGuardHook.sol) · [AAStarAirAccountFactoryV7](../src/core/AAStarAirAccountFactoryV7.sol) · [AgentRegistry](../src/registries/AgentRegistry.sol)*
