2026-03-20 合约审计报告（M6 开发阶段复核）

**范围**
AAStarAirAccountBase、AAStarGlobalGuard、AAStarValidator、SessionKeyValidator、CalldataParserRegistry、UniswapV3Parser 及相关 M6 文档一致性。

**方法**
静态审查代码与文档的一致性，聚焦 M6 新增能力（Session Key、Calldata Parser）及其安全边界。

**结论摘要**
发现 1 个 High、1 个 Medium、2 个 Low。测试未执行，本报告不验证测试结果。

**发现**

**HIGH — Session Key 未绑定到当前账户，存在跨账户授权风险**
影响：任意已授权的 sessionKey 可以对任意开启 `algId=0x08` 的账户签发 UserOp，只要签名的 userOpHash 来自目标账户即可。因为验证逻辑只检查 “某账户 A 是否存在该 sessionKey”，但未要求该账户 A 与正在验证的账户一致，导致跨账户滥用。  
证据：  
SessionKeyValidator 仅从签名中取 `account` 并检查 `sessions[account][sessionKey]`，未与当前账户绑定。`src/validators/SessionKeyValidator.sol:81-102`  
AAStarAirAccountBase 对未知 algId 直接转发到 validator，没有对 0x08 做账户绑定检查。`src/core/AAStarAirAccountBase.sol:374-431`  
建议：在账户侧对 `algId=0x08` 做硬绑定（例如强制 `signature[1:21] == address(this)`），或将 `account` 纳入被签名哈希（如 `keccak256("SESSION", account, userOpHash)`），并更新验证逻辑与 E2E。

**MEDIUM — Session Key 的 contractScope / selectorScope 未被链上强制**
影响：文档和设计明确宣称 Session Key 可限制到特定合约与函数，但目前链上验证未使用 scope 字段，sessionKey 实际上对任意合约/函数生效（仅受 guard 的 tier/limit 约束）。这会显著扩大 sessionKey 被滥用的范围，尤其在 dApp 侧期望“最小权限”的情况下。  
证据：  
Session 结构体包含 scope 字段，但 `validate()` 未做任何 scope 校验。`src/validators/SessionKeyValidator.sol:46-103`  
文档宣称 scope 限制生效。`docs/contract-registry.md:127-128,187`  
建议：在账户执行路径中读取 sessionKey 并对 `dest` / `selector` 做强制检查，或在验证阶段通过可验证的结构化签名将 scope 绑定到 UserOp（需要调整签名格式与验证接口）。

**LOW — Parser 失败不一定“优雅降级”，存在误配置 DoS 风险**
影响：文档宣称 parser 失败会回退到 ERC20 解析，但当前实现对 parser 调用未做 try/catch，若 parser revert，整个执行会 revert，导致该 dest 无法使用。  
证据：  
`_enforceGuard` 直接调用 `parseTokenTransfer`，无 try/catch。`src/core/AAStarAirAccountBase.sol:860-869`  
文档声明“parser fails gracefully”。`docs/contract-registry.md:188`  
建议：在调用 parser 时增加 try/catch，revert 时回退到 ERC20 解析；或在注册时强制 parser 不可 revert 并增加测试覆盖。

**LOW — Session Key 过期上限“30 天”仅为注释**
影响：注释承诺最大 30 天有效期，但 `_checkExpiry` 未强制上限，导致实际行为与文档不一致。  
证据：  
`grantSession` 注释包含“max 30 days”，但 `_checkExpiry` 仅校验 `expiry > now`。`src/validators/SessionKeyValidator.sol:111-222`  
建议：若 30 天为强约束，加入上限校验；否则同步修正文档。

**已确认的正向进展（非发现）**
ALG_BLS messagePoint 已绑定 userOpHash；`_algTier` 映射与 guard 对齐；默认 token 配置在工厂构造函数中已做合法性校验。

**测试**
未执行单元测试与 E2E。
