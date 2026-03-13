# AirAccount 逻辑合理性与安全评审报告

Date: 2026-03-10  
Reviewer: Codex (AI-assisted)  
Scope: 核心合约、验证器/聚合器、工厂与 Guard；以及 docs 中架构/安全相关文档

## Executive Summary
整体架构方向清晰（不可升级、分层验证、Guard 单调安全、社交恢复），但存在若干逻辑/治理与安全性缺口。  
**总体风险评级：中高（MEDIUM-HIGH）**。其中 2 个问题属于高风险逻辑缺陷，建议在主网前修复。

## Docs Reviewed
- docs/product_and_architecture_design.md
- docs/airaccount-unified-architecture.md
- docs/security-review.md
- docs/guard-tier-integration-plan.md
- docs/validator-upgrade-pq-analysis.md
- docs/social-recovery-guide.md
- 相关测试与报告类文档（milestone/test/gasless/gas analysis 等）

## Findings

### CRITICAL-1: `_lastValidatedAlgId` 全局状态导致同一账户多 UserOp 时可绕过分层校验
**Evidence**:  
`src/core/AAStarAirAccountBase.sol:70-73`、`311-358`、`650-675`  

**问题**: `_lastValidatedAlgId` 是账户级别的单值状态。EntryPoint 在同一交易里会先批量 `validateUserOp`，再批量执行 `execute/executeBatch`。如果同一账户在一个 bundle 里提交了多个 UserOp，`_lastValidatedAlgId` 会被最后一次验证覆盖，导致前面的 UserOp 在执行时使用了错误的 algId，从而通过更高 tier 的校验。  

**影响**:  
可以出现“低级别签名的高价值操作被高 tier algId 掩护执行”的情况。即便需要用户签名两笔交易，这也会导致安全模型失真，且在多入口/多 bundler 组包时引入不可预测风险。  

**建议**:
1. 移除 `_lastValidatedAlgId` 这种“跨 UserOp 的全局缓存”。  
2. 在 `userOp.callData` 中显式携带 `algId`/`requiredTier`，并在 `validateUserOp` 中验证其与签名一致；执行时只相信 calldata 的参数。  
3. 或引入“单次执行绑定”的校验模式（例如在 `validateUserOp` 内缓存 `lastValidatedHash`，并在执行入口传入并校验 `userOpHash`）。  

---

### HIGH-1: BLS 节点注册无权限控制，削弱“外部共识节点”安全性
**Evidence**:  
`src/validators/AAStarBLSAlgorithm.sol:360-372`  

**问题**: `registerPublicKey` 任何人可调用，无白名单/治理。BLS 作为 Tier3/高风险交易的“外部签名因子”，其安全前提是“节点集受治理约束”。当前实现允许任意注册新节点，攻击者在拿到 owner/passkey 之后可自行注册节点并完成 BLS 验证，从而实际绕过外部共识的安全门槛。  

**影响**:  
使 BLS 退化为“自签节点”，破坏分层/多方安全模型。  

**建议**:
1. 将 `registerPublicKey` 与 `batchRegisterPublicKeys` 设为 `onlyOwner` 或治理多签控制。  
2. 若要“允许公开注册”，至少引入登记凭证（例如签名/DAO 签批）或延迟生效机制。  

---

### HIGH-2: Validator 治理与文档不一致，`registerAlgorithm` 可绕过 timelock
**Evidence**:  
`src/validators/AAStarValidator.sol:84-94`、`98-128`  

**问题**: 文档要求“算法注册必须走 timelock”，但合约保留了立即生效的 `registerAlgorithm`。一旦 owner key 被盗或治理失误，攻击者可立即注册恶意算法。  

**影响**:  
治理安全承诺被绕开，变更不可控。  

**建议**:
1. 生产环境移除 `registerAlgorithm` 或强制其也走 timelock。  
2. 将 owner 设为 timelock 合约或多签治理地址，并锁死立即注册路径。  

---

### MEDIUM-1: Tier 与 Guard 只基于 `value`（ETH），无法覆盖 ERC20/DeFi 价值转移
**Evidence**:  
`src/core/AAStarAirAccountBase.sol:603-675`  

**问题**: 当前 `requiredTier(value)` 与 guard 检查仅基于 `msg.value`。对于 ERC20 转账、授权、DeFi 操作（`value=0`），将始终落入 Tier1，从而规避 tier/guard 的安全门槛。  

**影响**:  
实际高价值资产转移可在低级别签名下完成，安全目标与产品文档不匹配。  

**建议**:
1. 采用“模块化执行”：仅允许通过特定模块执行 token transfer/DeFi，并在模块内做额度/白名单限制。  
2. 若要按价值分层，需引入价格预言机或离线签名约束。  

---

### MEDIUM-2: `setTierLimits` 无校验，可能引入反直觉配置
**Evidence**:  
`src/core/AAStarAirAccountBase.sol:256-259`  

**问题**: 未检查 `_tier1 <= _tier2`。若配置错误会导致 tier 判定异常，降低安全门槛。  

**建议**: 在 setter 中加入约束（例如 `require(_tier1 <= _tier2)`）。  

---

### MEDIUM-3: 默认创建不校验 guardian 非零，可能导致恢复不可用
**Evidence**:  
`src/core/AAStarAirAccountFactoryV7.sol:80-138`  

**问题**: `createAccountWithDefaults` 不验证 `guardian1/guardian2`，如果传入 `address(0)`，将只剩 1 个 guardian，恢复阈值 2/3 无法达成。  

**建议**: 对 guardian1/2 做非零校验，并防止重复或等于 owner。  

---

### LOW-1: 预编译依赖的链兼容性风险（P256 / BLS）
**Evidence**:  
`src/core/AAStarAirAccountBase.sol:42-43`、`src/validators/AAStarBLSAlgorithm.sol`  

**问题**: P256 依赖 EIP-7212，BLS 依赖 EIP-2537。若部署在不支持预编译的链上，相关验签会失败。  

**建议**: 文档明确支持链，或引入软件 fallback。  

---

### LOW-2: messagePoint 签名未绑定 userOpHash（可复用）
**Evidence**:  
`src/core/AAStarAirAccountBase.sol:437-440`、`497-503`、`571-577`  

**问题**: messagePointSignature 仅对 messagePoint 进行签名，没有绑定 `userOpHash`。若 owner 的 messagePoint 签名泄露，可能被复用在其他交易中（仍需 P256/BLS）。  

**建议**: 将 `userOpHash` 绑定进 messagePoint 签名：`keccak256(abi.encodePacked(userOpHash, messagePoint))`。  

## 产品与架构合理性评审（结论）
**强项**:
- 不可升级与 Guard 单调安全符合“去管理员风险”的核心原则。  
- 分层验证与社交恢复的用户体验设计合理，且文档较完整。  
- 把 P256/ECDSA 内联，BLS 通过路由器外置，简化核心合约复杂度。  

**主要缺口**:
- Tier/Guard 只覆盖 ETH `value`，与文档中的“USD/资产价值分层”目标存在差距。  
- Validator 治理与文档不一致（timelock 可绕过）。  
- BLS 节点注册权限未受控，导致“外部共识因子”失效。  

## 测试覆盖与验证缺口
- 未见“同一账户多 UserOp 同 bundle”导致 `_lastValidatedAlgId` 失配的测试。  
- 未见针对 `value=0` 的 ERC20/DeFi 调用的 tier/guard 行为测试。  
- 未见治理 timelock 约束测试与节点注册权限测试。  

## 总体建议
1. 修复 `_lastValidatedAlgId` 设计，确保每个 UserOp 的 tier 绑定一致且不可串扰。  
2. 收紧 BLS 节点注册权限，与文档治理流程对齐。  
3. 统一治理策略：移除 `registerAlgorithm` 立即注册路径。  
4. 明确资产价值分层策略（模块化执行/预言机/白名单）。  

