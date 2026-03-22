2026-03-22 合约审计报告（M7 里程碑复核）

**范围**
ERC‑7579 模块系统（AAStarAirAccountV7 installModule/executeFromExecutor/nonce‑key routing）、TierGuardHook、ForceExitModule、AirAccountCompositeValidator、AgentSessionKeyValidator、以及相关设计文档一致性。

**方法**
静态审查代码与文档一致性，聚焦安全边界、功能闭环、极端/异常路径与性能‑gas 权衡。

**结论摘要**
发现 2 个 High、2 个 Medium、1 个 Low。测试未执行，本报告不验证测试结果。

**发现**

**HIGH — CompositeValidator 实际仅做 ERC‑1271 校验，破坏多签/加权安全模型**
影响：当使用 nonce‑key routing 到 `AirAccountCompositeValidator` 时，algId=0x04/0x05/0x07 的签名会被当作普通 ECDSA 处理，无法保证累计/加权签名的安全性。攻击者若持有 owner ECDSA，可用“伪装成高阶 algId 的 ECDSA 签名”绕过 Tier2/3。  
证据：  
CompositeValidator 直接调用账户 `isValidSignature`（仅验证 owner ECDSA），并未走账户 `_validateSignature`。`src/validators/AirAccountCompositeValidator.sol:45-73`  
账户 `isValidSignature` 仅做 ECDSA recover。`src/core/AAStarAirAccountV7.sol:104-112`  
建议：CompositeValidator 应调用账户的专用校验入口（例如新增 `validateUserOpSignature` 或 `validateSignature` 视图函数），或将对应算法逻辑内联到模块；绝不能依赖 ERC‑1271。

**HIGH — nonce‑key 路由未写入 algId 队列，执行阶段 Guard 无法正确判定**
影响：使用 validator 模块时，`validateUserOp` 不会写入 transient algId/weight/session 信息；执行阶段 `_consumeValidatedAlgId()` 读取到 0，导致 Guard 校验失败或逻辑失真，模块路径在有 Guard 时不可用。  
证据：  
validator module 路由分支不调用 `_storeValidatedAlgId`。`src/core/AAStarAirAccountV7.sol:126-148`  
执行阶段仍依赖 `_consumeValidatedAlgId()`。`src/core/AAStarAirAccountBase.sol:1001-1033`  
建议：模块验证成功后必须写入 algId（及权重/Session Key 标识）；可在账户侧解析 `userOp.signature[0]` 写入，或定义模块回调接口传回 algId。

**MEDIUM — installModule 未调用 onInstall/onUninstall，模块无法初始化**
影响：`initData` 仅用于 guardian 签名，模块初始化数据被忽略；TierGuardHook/ForceExitModule/AgentSessionKeyValidator 等依赖 onInstall 的模块在安装后仍未初始化，功能不闭环。  
证据：  
installModule 仅记录 mapping 并 emit 事件，没有调用 `module.onInstall(initData)`。`src/core/AAStarAirAccountV7.sol:156-204`  
模块实现依赖 onInstall 写入状态（例如 `ForceExitModule.onInstall`、`TierGuardHook.onInstall`）。`src/core/ForceExitModule.sol:92-111`, `src/core/TierGuardHook.sol:35-55`  
建议：拆分 guardian 签名与模块 initData（例如前 N*65 bytes 为 sig，剩余传入 onInstall），并在 uninstall 调用 onUninstall。

**MEDIUM — installModule 安全门槛与 M7 设计不一致**
影响：默认阈值为 70（仅 1 名 guardian 签名），无 timelock；与设计文档“2‑of‑3 + timelock”不符。结合 `executeFromExecutor` 只做 daily‑limit，可能削弱 Tier 安全模型。  
证据：  
阈值逻辑与默认值：`_installModuleThreshold==0 ? 70 : _installModuleThreshold`。`src/core/AAStarAirAccountV7.sol:170-173`  
设计文档要求 2‑of‑3 + timelock。`docs/M7-plan.md:975-1035`  
建议：按设计落地 2‑of‑3 + timelock；若确需阈值模式，需在文档明确威胁模型与适用场景。

**LOW — TierGuardHook 依赖 getCurrentAlgId，但账户未提供该接口**
影响：hook 回退为 ALG_ECDSA，且不识别 ALG_WEIGHTED；若未来切换为 hook‑only guard，会出现 tier 低估或 weighted 交易被误拦截。  
证据：  
TierGuardHook 通过 `getCurrentAlgId()` 静态调用获取 algId，失败则回退 ALG_ECDSA。`src/core/TierGuardHook.sol:111-128`  
当前账户未实现 `getCurrentAlgId()`。  
建议：在账户实现 `getCurrentAlgId()`（从 transient storage 读取），并补齐 ALG_WEIGHTED 映射。

**性能 / Gas 观察（非问题）**
模块化带来额外外部调用与签名验证成本；但 EIP‑1167 复用实现、nonce‑key routing 与模块分层，有利于长期可维护与功能隔离。需要在 E2E 中量化 `executeFromExecutor` 与 hook 路径的 gas 开销。

**测试**
未执行单元测试与 E2E。
