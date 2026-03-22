2026-03-22 M7 深度审计报告（安全 / 性能 / 边界测试）

**范围**
AAStarAirAccountV7（M7 ERC‑7579 模块管理与 nonce‑key 路由）、AAStarAirAccountBase（hook/guard 交互与 token guard）、TierGuardHook、ForceExitModule、AgentSessionKeyValidator。

**方法**
静态审查代码与文档一致性，针对高危路径、极端边缘场景、gas/性能权衡进行复核。

**结论摘要**
发现 2 个 High、2 个 Medium、1 个 Low。测试未执行，本报告不验证测试结果。

**发现**

**HIGH — validator 模块路径写入 algId 不安全（格式/失败均未校验）**
影响：`validateUserOp` 在 validator 模块路径中无条件将 `userOp.signature[0]` 写入 algId 队列。  
若 validator 使用“无 algId 前缀”的 65‑byte ECDSA（如 AgentSessionKeyValidator），则 algId 为随机值，可能导致 Guard 误判或绕过；若验证失败仍写入，会污染队列，影响同交易中后续 UserOp 的执行。  
证据：  
`_storeValidatedAlgId(uint8(userOp.signature[0]))` 未校验 signature 格式与 validationData。`src/core/AAStarAirAccountV7.sol:130-145`  
AgentSessionKeyValidator 仅解析 65‑byte ECDSA，无 algId 前缀。`src/validators/AgentSessionKeyValidator.sol:200-203`  
建议：仅在 `validationData == 0` 且 algId 格式明确时写入；或让 validator 模块返回 algId（例如 `validateUserOp` 返回 `(validationData, algId)`），或统一要求 validator 模块签名带 algId 前缀。

**HIGH — 模块生命周期回调不传 initData 且忽略失败**
影响：installModule 使用 best‑effort `onInstall` 且不传 initData；依赖初始化数据的模块（TierGuardHook/ForceExitModule）会在“已安装”状态下保持未初始化，安全策略可能形同虚设。  
证据：  
`_callLifecycle` 仅传空数据并忽略返回值。`src/core/AAStarAirAccountV7.sol:156-165`  
installModule 仅调用 `_callLifecycle`，未传入 `initData`。`src/core/AAStarAirAccountV7.sol:181-210`  
TierGuardHook/ForceExitModule 的 `onInstall` 需要初始化参数。`src/core/TierGuardHook.sol:40-47`, `src/core/ForceExitModule.sol:97-103`  
建议：将 `initData` 与 guardian 签名拆分，传入 `onInstall(initData)` 并在失败时回滚安装。

**MEDIUM — installModule 安全门槛弱且不可配置**
影响：默认阈值固定为 70（1 个 guardian），无 timelock 且没有 setter。与 M7 设计“2‑of‑3 + timelock”不一致，降低模块安装安全门槛。  
证据：  
阈值固定为 `(_installModuleThreshold == 0 ? 70 : _installModuleThreshold)`，且无 setter。`src/core/AAStarAirAccountV7.sol:195-196`  
建议：实现可配置阈值（需 guardian 2‑of‑3 + timelock 变更），或直接按设计强制 2‑of‑3 + timelock。

**MEDIUM — TierGuardHook 依赖 getCurrentAlgId（账户未提供）且不识别 ALG_WEIGHTED**
影响：hook 在取不到 algId 时回退 ALG_ECDSA，weighted 或高阶签名可能被低估；若未来使用 hook‑only guard，tier 约束会失真。  
证据：  
hook 通过 `getCurrentAlgId()` 获取 algId，失败回退 ECDSA。`src/core/TierGuardHook.sol:111-121`  
hook `_algTier` 未覆盖 ALG_WEIGHTED(0x07)。`src/core/TierGuardHook.sol:124-128`  
建议：账户侧补充 `getCurrentAlgId()` 读取 transient queue，并在 hook 中加入 ALG_WEIGHTED 处理。

**LOW — AgentSessionKeyValidator 仅强制速率限制，其他约束未接入执行路径**
影响：callTarget/selector/spendCap 仅提供辅助函数，但账户执行路径未调用，导致约束不生效。  
证据：  
`enforceSessionScope`/`recordSpend` 需要账户显式调用。`src/validators/AgentSessionKeyValidator.sol:228-271`  
建议：在账户执行路径中接入 scope/spend 校验，或明确标注为 M7.14‑M7.18 待办。

**建议补充的边界测试**
1) validator 模块路径：签名不含 algId 前缀时 guard 行为是否一致。  
2) validator 模块失败时的队列污染：同一交易内多 UserOp 的顺序与执行结果。  
3) installModule 传入 initData 后模块是否正确初始化（TierGuardHook/ForceExitModule）。  
4) hook‑only guard 模式下 TierGuardHook 的 tier 判断与 weighted 签名兼容性。  
5) AgentSessionKey：scope/spendCap 是否被强制；速率窗口跨边界的计数正确性。

**测试**
未执行单元测试与 E2E。
