2026-03-22 M7 复审报告（Fix 后再次审计）

**范围**
AAStarAirAccountV7（ERC‑7579 模块管理与 nonce‑key 路由）、AAStarAirAccountBase（hook/guard 交互）、TierGuardHook、AgentSessionKeyValidator、ForceExitModule。

**结论摘要**
发现 2 个 High、2 个 Medium、1 个 Low。测试未执行，本报告不验证测试结果。

**已确认修复**
- CompositeValidator 已改为回调 `validateCompositeSignature`，不再走 ERC‑1271。  
- executeFromExecutor 现调用 token guard（`_checkTokenGuard`），避免 token 侧绕过。  
- SessionKey scope 由“静默跳过”改为 fail‑closed。  
- AgentSessionKey 增加 `callTargets` 长度上限。

**发现**

**HIGH — validator 模块路径写入 algId 不安全（失败/无前缀都会污染队列）**
影响：在 validator 路由下，无论校验成功与否都会写入 `sig[0]` 作为 algId；  
对于不带 algId 前缀的 65‑byte ECDSA（如 AgentSessionKeyValidator），algId 变成随机值，Guard 可能误判；  
若校验失败仍写入，会导致同一批次后续 UserOp 读取错误 algId。  
证据：  
`_storeValidatedAlgId(uint8(userOp.signature[0]))` 未判断 validationData。`src/core/AAStarAirAccountV7.sol:130-145`  
AgentSessionKeyValidator 仅解析 65‑byte ECDSA，无 algId 前缀。`src/validators/AgentSessionKeyValidator.sol:212-215`  
建议：仅在 `validationData==0` 且格式明确时写入；或改为模块返回 algId；或强制所有模块签名带 algId 前缀。

**HIGH — installModule 未传 initData + best‑effort onInstall 会导致 hook 失效并绕过 ETH 日限额**
影响：hook 安装后 `_activeHook` 被设置，`_enforceGuard` 跳过 `guard.checkTransaction`，  
但 hook 未初始化（onInstall 未收到 initData 或失败被忽略）会直接返回，导致 ETH daily limit 失效。  
证据：  
installModule 只调用 `_callLifecycle`，不传 initData。`src/core/AAStarAirAccountV7.sol:181-210`  
`_callLifecycle` 忽略返回并始终传空 data。`src/core/AAStarAirAccountV7.sol:156-165`  
TierGuardHook 未初始化时 `accountGuard==0` 直接返回。`src/core/TierGuardHook.sol:40-47,67-99`  
hook 激活时 `_enforceGuard` 跳过 `guard.checkTransaction`。`src/core/AAStarAirAccountBase.sol:1068-1081`  
建议：拆分 guardian 签名与 initData；调用 `onInstall(initData)` 且失败即回滚安装。

**MEDIUM — installModule 签名未绑定 initData，配置可被替换**
影响：guardian 签名只绑定 moduleTypeId+module，未绑定 initData；  
即便后续接入 initData，也可复用签名安装不同配置（如不同 guard/tier），造成配置替换风险。  
证据：  
签名域：`"INSTALL_MODULE" || chainId || account || moduleTypeId || module`。`src/core/AAStarAirAccountV7.sol:198-203`  
建议：在签名哈希中加入 `keccak256(initData)` 或强制模块内校验配置一致性。

**MEDIUM — AgentSessionKey 子委托未限制 selectorAllowlist（可扩大 scope）**
影响：子委托未校验 selectorAllowlist 是否为父集；  
父 session 限定 selector 时，子 session 可将 selectorAllowlist 置空从而扩大权限。  
证据：  
delegateSession 仅校验 expiry/spend/velocity/callTargets，未涉及 selectorAllowlist。`src/validators/AgentSessionKeyValidator.sol:140-185`  
建议：selectorAllowlist 需做与 callTargets 相同的“子集约束”。

**LOW — TierGuardHook 依赖 getCurrentAlgId，但账户未提供**
影响：hook 回退 ALG_ECDSA，Tier2/3 交易会被误拦截；ALG_WEIGHTED 也未映射。  
证据：  
`getCurrentAlgId()` 回退逻辑与 ALG_WEIGHTED 缺失。`src/core/TierGuardHook.sol:111-128`  
建议：账户补充 getCurrentAlgId（读取 transient queue），hook 映射 ALG_WEIGHTED。

**测试**
未执行单元测试与 E2E。
