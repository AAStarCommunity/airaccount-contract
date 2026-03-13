# AirAccount Core Contracts Security Audit Report

**Date:** 2026-03-11
**Auditor:** Antigravity 
**Scope:** `src/core/`, `src/validators/`, `src/aggregator/`, `src/interfaces/`

## 1. 概述 (Overview)
本次全面审计针对 AirAccount 智能合约层的核心控制逻辑、分层验证路由（Tiered Routing）、签名验证机制、全局护卫（Global Guard）以及社会恢复（Social Recovery）等模块进行了深入分析。

总体而言，架构设计非常精妙，使用了最新的 EIP-1153 (`tstore`/`tload`) 优化 `algId` 传递，并彻底贯彻了无 Proxy 的不可升级设计，显著降低了管理员特权风险。然而，在以太坊价值转移的判断逻辑中发现了严重的漏洞，需在上线前紧急修复。

## 2. 严重漏洞 (Critical Vulnerabilities)

### 2.1 [High] ERC20 代币转移完全绕过分层阈值与每日限额 (ERC20 Token Drain)
**出处**：`AAStarAirAccountBase.sol` 
**描述**：
目前 `_enforceGuard(value, algId)` 和 `AAStarGlobalGuard.checkTransaction(value, algId)` 仅检查 `msg.value` (原生 ETH 的转移量)。当执行 ERC20 代币转账如 USDC 时，由于是对代币合约发起的调用，`execute(tokenAddress, 0, transferData)` 传入的 `value` 为 `0`。
这意味着：
1. `requiredTier(0)` 计算得出需要 Tier 1 权限。
2. `guard.checkTransaction(0, algId)` 由于 `value = 0` 不耗费 `dailySpent`，不会触发拦截。
**影响**：
如果用户的单因子密钥（如 Tier 1 的 WebAuthn 或 ECDSA）被盗，攻击者可以轻易提取账户上的**所有** ERC20 资产，完全绕过 Tier 2/3 的高级签名要求以及硬编码的每日美元限额。
**修复建议**：
如果要对 ERC20 进行限额或分级验证，必须在合约中解析 `execute` 的 `data` 载荷（识别 `transfer` 或 `transferFrom` 的 `amount`），并结合预言机（Oracle）价格转换为美元统一核算。若架构设计不允许在底座引入预言机，则必须明确告知用户 Guard 仅保护原生 ETH，将 ERC20 限额判断抽离到 Executor 插件模块进行处理。

### 2.2 [Medium] 通过 Batch Execution 绕过单笔交易的分层限制 (Tier Limit Bypass via Batch)
**出处**：`AAStarAirAccountBase.sol` -> `executeBatch`
**描述**：
在 `executeBatch` 中，限额校验是通过 `for` 循环针对每次内部调用独立进行的：
```solidity
for (uint256 i = 0; i < dest.length; i++) {
    _enforceGuard(value[i], algId);
    _call(dest[i], value[i], func[i]);
}
```
**影响**：
即便 `tier1Limit` 设定为 0.1 ETH，只要攻击者构建包含 10 次 0.1 ETH 转账的 `executeBatch` 请求，他们仅凭 Tier 1 签名即可在单笔 UserOp 中转移 1.0 ETH，直到达到 `GlobalGuard` 的全局总限额。这削弱了分层防护（Tier Thresholds）对异常高额流出的单笔保护力度。
**修复建议**：
在 `executeBatch` 中引入一个 `uint256 totalValue`，累加计算整个 Batch 的 ETH 转移总计金额，将总额传入 `_enforceGuard()` 以决定所需的最高 Tier。

## 3. 架构建议与信息 (Informational & Architecture)

### 3.1 架构设计与实际代码的不一致 (Architecture vs Implementation Mismatch)
根据 `airaccount-unified-architecture.md` 文档：
> `Acct->>Guard: checkTransaction(value, algId, tier)` 是在 `validateUserOp` 中调用的。
> `uint256 txValue = _extractTransactionValue(userOp.callData);` 负责提取价值。
但在实际代码中，拦截被推迟到了执行阶段（`execute` / `executeBatch`），而且底座代码中缺乏了预解析 `callData` 获取总体价值 `txValue` 的函数。
**影响**：在执行期被防线拦截会使得不符合限额规则的 UserOp 依然在网络中上链产生 Revert，导致验证失败的用户依然需要支付 Gas 给 Bundler (执行损失)。
**建议**：若要实现卓越的用户/Bundler 体验，应将明显的红线拦截检查提前至 `validateUserOp` 阶段，但这要求完整解析 `callData`（这很可能就是原文档提到的 `_extractTransactionValue` 的意义所在）。建议补充实现相关的 `_extractTransactionValue` 解析逻辑。

### 3.2 密码学聚合与 BLS 实现 (Cryptography & Precompiles)
智能合约中使用了汇编级别的 EIP-2537 (`0x0b`, `0x0f`, `0x0e`) 预编译调用，高度优化了 Gas 开销并且避免了无谓的内存复制。且 BLS Aggregator 中利用了 `e(G, sum) * e(-aggPK, msgPt) == 1` 进行双 Pairing 校验，数学上严谨，实现了预期的 Gas 优化。

### 3.3 社会验证与恢复机制 (Social Recovery Robustness)
`proposeRecovery`, `approveRecovery` 结合 `RECOVERY_THRESHOLD = 2` 和双位图跟踪（Approval & Cancellation）能有效杜绝恢复动作的重放和恶意取消。恢复请求 `2 days` 的 Timelock 设定也给用户阻断恶意盗取提供了充足时间。审查结果认为该部分逻辑十分稳健。

## 4. 结论 (Conclusion)
核心智能合约库引入了前沿的账户抽象优化和彻底的无 Proxy 化设计，在密码学调用和 EIP-1153 (`TSTORE`) 状态传输优化上表现卓越。但在全局业务风控状态机上缺乏完整的价值提取管道，必须重新设计以补全对非原生资产（ERC20 等）的价值追踪，以及 Batch 调用时的累计价值判定。在修复提到的重要漏洞前，钱包系统容易面临跨资产耗竭的安全风险（Drainage Risk）。
