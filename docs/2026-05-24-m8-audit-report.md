# AirAccount M8 安全审计报告

**日期**: 2026-05-24  
**范围**: M8 合并代码（PR #36/#38/#39/#41）+ 全量合约层  
**审计方**: Claude Code 本地模型 + Codex 深度扫描（双重来源）  
**测试基准**: 755 unit tests pass

---

## Executive Summary

AirAccount M8 代码库设计严谨，覆盖 ERC-4337、ERC-7579、社交恢复、会话密钥、加权多签、Agent Economy 等高级功能。主要安全机制（重入保护、守卫单调性、guardian 门控模块安装、跨账户 session key 检查）均已实施。

本次审计发现 **2 High**、**7 Medium**、**5 Low** 问题，及多处性能与冗余问题。最紧迫风险：

1. **IdentityRegistry 未禁用 ERC-721 approve/setApprovalForAll**（H-2，3行修复）
2. **AgentSessionKeyValidator.spendCap 从未被链上执行**（H-1，架构级）
3. **AirAccountDelegate 无重入保护**（M-6，5行修复）

---

## High 发现

### H-1: AgentSessionKeyValidator.spendCap 从未被链上调用执行

- **位置**: `src/validators/AgentSessionKeyValidator.sol:302`
- **问题**: `recordSpend()` 是唯一更新 `sessionStates[account][sessionKey].totalSpent` 的函数，但在整个执行路径（`execute()` → `_enforceGuard()`、`executeFromExecutor()`、`TierGuardHook.preCheck()`）中**从未被调用**。`enforceSessionScope()` 只检查 `callTargets` 和 `selectorAllowlist`，不检查 `spendCap`。
- **影响**: 配置了 `spendCap` 的 agent session 可以无限花费代币，完全绕过 per-session 累计花费上限。给用户虚假的安全感——配置存在但永不执行。
- **修改建议（方案A — 立即修复）**: 在 NatSpec 和文档中明确标注 spendCap 为"off-chain 约束（仅 bundler/DVT 节点执行）"，移除误导性注释"Max cumulative spend this session"改为"Advisory spend cap — enforced off-chain only"。
- **修改建议（方案B — 完整修复）**: 在 `TierGuardHook.preCheck()` 中，当 `algId == ALG_SESSION_KEY` 且 session 有 `spendCap > 0` 时，解析 ETH value 后调用 `AgentSessionKeyValidator(accountAgentValidator[msg.sender]).recordSpend(msg.sender, sessionKey, value)`，并在 `enforceSessionScope` 内检查 `totalSpent + amount <= spendCap`。

---

### H-2: IdentityRegistry 未禁用 ERC-721 approve 和 setApprovalForAll

- **位置**: `src/registries/IdentityRegistry.sol:23-73`
- **问题**: `IdentityRegistry` 继承 OZ `ERC721` 并声明"Non-transferable by design"，override 了 `transferFrom` 和 `safeTransferFrom` 使其 revert，但**未 override `approve()` 和 `setApprovalForAll()`**。任何人可调用 `approve(attacker, agentId)` 将审批权转给攻击者。链下系统（Explorer、DeFi 协议）会将攻击者视为有处置权的地址。
- **影响**: Agent identity NFT 的非转让保证在链下被破坏，影响所有依赖 `getApproved` / `isApprovedForAll` 的集成方。
- **修改建议**（立即可修，3行）:

```solidity
function approve(address, uint256) public pure override {
    revert TransferNotAllowed();
}
function setApprovalForAll(address, bool) public pure override {
    revert TransferNotAllowed();
}
```

---

## Medium 发现

### M-1: ForceExitModule.proposeForceExit 无初始化检查

- **位置**: `src/core/ForceExitModule.sol:128-142`
- **问题**: `proposeForceExit()` 以 `msg.sender` 作为 account key，但未检查 `_initialized[msg.sender]`。任何未安装此模块的 EOA 或合约均可创建无法被真实账户执行的"僵尸提案"，污染链上状态。
- **修改建议**: 函数起始处添加 `if (!_initialized[msg.sender]) revert NotInstalled();`

---

### M-2: AgentSessionKeyValidator.validateUserOp 在验证阶段硬 revert（违反 ERC-4337）

- **位置**: `src/validators/AgentSessionKeyValidator.sol:263-264`
- **问题**: 当 `callCount >= velocityLimit` 时执行 `revert VelocityLimitExceeded(...)` 而非 `return 1`。ERC-4337 规范要求验证阶段不允许 revert；某些 bundler 实现会将 revert 的 UserOp 标记为"无效"，不退款 gas，并可能将账户加入黑名单。
- **修改建议**: 将 `revert VelocityLimitExceeded(...)` 改为 `return 1;`（SIG_VALIDATION_FAILED）

---

### M-3: algId 双重推送导致 bundle 内后续 UserOp 消耗错误的 algId

- **位置**: `src/core/AAStarAirAccountV7.sol:111-113` + `145-153`
- **问题**: 通过 `AirAccountCompositeValidator` 路由时：`validateCompositeSignature()` 内部调用 `_storeValidatedAlgId(algId)`（第1次推送），之后 `validateUserOp` 第153行再次推送（第2次）。两个条目留在 transient FIFO 中，下一个同 bundle 的 UserOp `execute()` 读到上一个 UserOp 的残余 algId，导致 tier 验证错误。
- **修改建议**: 在 `validateUserOp` 的 CompositeValidator 路径中，先检查 writeIdx 是否已被 `validateCompositeSignature` 增加，若已增加则跳过第二次推送；或在 `validateCompositeSignature` 中改用 flag 而非直接推送。

---

### M-4: setTierLimits 允许 tier1 > tier2（当 tier2=0 时）导致账户功能瘫痪

- **位置**: `src/core/AAStarAirAccountBase.sol:403-407`
- **问题**: 验证逻辑 `if (_tier1 > _tier2 && _tier2 > 0) revert InvalidTierConfig()`，当 `_tier2 == 0` 时校验被跳过。可设置 `tier1=10 ETH, tier2=0`，导致超过 tier1 的交易要求 Tier 3 但 tier3 条件不可达，账户大额交易被永久锁死。
- **修改建议**:
```solidity
if (_tier2 > 0 && _tier1 > _tier2) revert InvalidTierConfig();
if (_tier1 > 0 && _tier2 == 0) revert InvalidTierConfig(); // tier2 为0无意义
```

---

### M-5: 社交恢复 newOwner 可以是现有 guardian

- **位置**: `src/core/AAStarAirAccountBase.sol:1360-1374`
- **问题**: `proposeRecovery(_newOwner)` 只检查 `_newOwner != owner`，不检查 `_newOwner` 是否已是 guardian。恢复完成后，该地址同时拥有 owner 权限和 guardian 投票权，破坏 `owner != guardian` invariant，可以单人实质控制 2-of-3 多签。
- **修改建议**:
```solidity
function proposeRecovery(address _newOwner) external {
    if (_newOwner == address(0) || _newOwner == owner) revert InvalidNewOwner();
    for (uint8 i = 0; i < _guardianCount; i++) {
        if (_getGuardian(i) == _newOwner) revert InvalidNewOwner();
    }
    ...
}
```

---

### M-6: AirAccountDelegate.execute/executeBatch 缺少重入保护

- **位置**: `src/core/AirAccountDelegate.sol:237-278`
- **问题**: EIP-7702 delegate 合约的 `execute()` 和 `executeBatch()` 均无 `nonReentrant` 修饰符（对比 `AAStarAirAccountV7` 已有）。外部合约回调可重入 `execute()`，绕过 ETH 每日限额的单次 `checkTransaction` 保护。
- **修改建议**: 添加轻量 transient nonReentrant（使用 transient slot 101，不与 Base 的 slot 100 algId 冲突）:
```solidity
modifier nonReentrantDelegate() {
    assembly {
        if tload(101) { mstore(0, 0xab143c06) revert(0x1c, 4) }
        tstore(101, 1)
    }
    _;
    assembly { tstore(101, 0) }
}
```

---

### M-7: setTierLimits/setValidator/setP256Key 无单调性保护，单签可升级攻击面

- **位置**: `src/core/AAStarAirAccountBase.sol:378-406`
- **问题**: `setTierLimits` 可自由增大 tier1Limit，等效于将 ECDSA 单签额度提升到任意数字。攻击者获取 ECDSA key 后：① 增大 tier1Limit，② 立即转走资金，全程只需 ECDSA 单签，绕过 tier 机制。
- **修改建议**: 对 `setTierLimits` 增加单调性约束（只允许降低），或要求 guardian 共签。`setValidator` 建议增加 7 天 timelock。

---

## Low 发现

### L-1: SessionKeyValidator._validateP256Session 使用 sha256，与 _validateP256 不一致

- **位置**: `src/validators/SessionKeyValidator.sol:333` vs `src/core/AAStarAirAccountBase.sol:602`
- **问题**: P256 session 验证对 userOpHash 先做 `sha256` 再传 EIP-7212 precompile；而 Base 的 `_validateP256` 直接传原始 keccak256 hash。两条路径对同一 P256 key 产生的签名格式不兼容。
- **修改建议**: 统一选择一种哈希策略（推荐对 userOpHash 做 sha256 以对齐 WebAuthn 标准），并更新文档明确说明。

---

### L-2: uninstallModule 当 guardianCount=0 时无需任何签名即可卸载

- **位置**: `src/core/AAStarAirAccountV7.sol:276`
- **问题**: `sigsRequired = _guardianCount < 2 ? _guardianCount : 2`，当 `_guardianCount == 0` 时 sigsRequired=0，任何 owner 可无签名卸载任意模块。初始账户无 guardian 时此路径完全开放。
- **修改建议**: 文档警告所有账户至少配置 1 个 guardian；或强制 `sigsRequired = max(1, min(_guardianCount, 2))`。

---

### L-3: NatSpec 与代码不符 — createAgentAccount 注释声明 agentKey 为 owner

- **位置**: `src/core/AAStarAirAccountFactoryV7.sol:227`
- **问题**: 注释声明"agentKey ... Becomes the account owner"，但实际代码将 `msg.sender`（humanOwner）设为 owner。
- **修改建议**: 将注释改为"agentKey ... The agent's execution key (NOT the owner; msg.sender is set as owner)"。

---

### L-4: grantAgentSession 无初始化检查，允许任意地址设置 session

- **位置**: `src/validators/AgentSessionKeyValidator.sol:128`
- **问题**: `grantAgentSession()` 不检查 `_initialized[msg.sender]`，任何 EOA 或合约均可设置 agentSessions，浪费存储并造成状态污染。
- **修改建议**: 起始处添加 `if (!_initialized[msg.sender]) revert CallerNotSessionKey();`

---

### L-5: ALG_ECDSA 常量值文档注释错误（Codex 发现）

- **位置**: `src/core/AAStarAirAccountBase.sol`（algId 常量定义处）
- **问题**: ALG_ECDSA 文档注释中标注为 `0x02`，但实际值应为 `0x01`（按 AAStarValidator algId 路由表）。不影响运行时行为，但会误导审计员和集成方。
- **修改建议**: 修正常量注释为 `0x01`。

---

## 性能优化建议

1. **`AAStarAirAccountBase.sol:1098-1127`** — `_enforceGuard` 中通过 `guard` 状态变量发起的3次外部调用，每次均为 WARM SLOAD。建议统一缓存为 `AAStarGlobalGuard guardCached = guard` 后通过局部变量调用，节省 ~200 gas。

2. **`AAStarAirAccountBase.sol:1455`** — `_popcount` 使用逐位循环，但 bitmap 最大只需 3 位。建议内联展开：`return uint256(x & 1) + uint256((x >> 1) & 1) + uint256((x >> 2) & 1)`（节省 ~50 gas）。

3. **`AAStarGlobalGuard.sol:130-145`** — `checkTransaction` 无 value 时仍读取 `dailySpent[today]`（SLOAD）可提前 short-circuit：`if (value == 0) return;` 在函数起始处。

4. **`AgentSessionKeyValidator.sol:325-346`** — `_containsAddress` 和 `_containsSelector` 线性扫描，建议改为 `mapping` 存储以实现 O(1) 查找（代价是存储增加）。

5. **`AAStarAirAccountBase.sol:904-912`** — `_validateCumulativeTier3` 中建议将 BLS 验证（成功率高）移至 guardian ECDSA 验证之前，减少成功路径平均 gas。

---

## 代码冗余清单

1. **`AgentRegistry.sol:80-109`** — `deregisterAgent` 和 `revokeAgent` 代码完全相同。提取为私有 `_deregister(address)` 内部函数。

2. **`AAStarGlobalGuard.sol:273-281` + `AAStarAirAccountBase.sol:964-974`** — `_algTier` 逻辑重复，注释标注"Must stay in sync"。建议提取为共享库。

3. **`AgentSessionKeyValidator.sol:341-354`** — `_isSubsetAddresses` 和 `_isSubsetSelectors` 逻辑完全相同，仅类型不同。

4. **`AAStarAirAccountBase.sol:1272-1292`** — `_checkTokenGuard` 三层 try/catch 嵌套冗长，可提取内层为私有函数。

5. **`AAStarAirAccountV7.sol:69`** — `SEL_ON_INSTALL` / `SEL_ON_UNINSTALL` 常量定义后仅用于 `_callLifecycle`，可直接内联。

---

## 修复优先级总结

### 立即可修（≤10行修改，不需要架构讨论）

| ID | 问题 | 修改量 | 风险等级 |
|----|------|--------|---------|
| H-2 | IdentityRegistry 未禁用 approve/setApprovalForAll | +6行 | High |
| M-1 | ForceExitModule proposeForceExit 无初始化检查 | +1行 | Medium |
| M-2 | AgentSessionKeyValidator validateUserOp 用 revert 代替 return 1 | 1行改动 | Medium |
| M-4 | setTierLimits tier2=0 时校验被跳过 | 1行改动 | Medium |
| M-5 | proposeRecovery newOwner 可以是现有 guardian | +4行 | Medium |
| M-6 | AirAccountDelegate 无重入保护 | +8行 modifier | Medium |
| L-3 | createAgentAccount NatSpec 注释错误 | 注释改动 | Low |
| L-4 | grantAgentSession 无初始化检查 | +1行 | Low |
| L-5 | ALG_ECDSA 注释值错误 | 注释改动 | Low |

### 需要架构讨论（影响核心设计）

| ID | 问题 | 推荐处理 |
|----|------|---------|
| H-1 | spendCap 从未被链上执行 | 方案A：文档降级为 off-chain；方案B：TierGuardHook 中添加执行路径 |
| M-3 | algId 双重推送（Composite路径） | 添加 writeIdx 变化检测，跳过重复推送 |
| M-7 | setTierLimits 无单调性保护 | 添加只降不升约束，或 guardian 共签 |
| L-2 | 0 guardian 时无签名可卸载模块 | 添加最低 guardian 要求文档/代码 |

---

*报告生成: Claude Code (claude-sonnet-4-6) + Codex 双重审计，2026-05-24*
