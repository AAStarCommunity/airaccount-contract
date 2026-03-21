2026-03-21 合约审计报告（M6 完成版复核）

**范围**
AAStarAirAccountFactoryV7（EIP‑1167 clone 版本）、AAStarAirAccountV7、AAStarAirAccountBase（ALG_WEIGHTED/Session Key/Parser）、SessionKeyValidator、AAStarGlobalGuard、核心 M6 文档。

**方法**
静态审查代码与文档一致性，关注 M6 新增功能的安全边界、逻辑闭环与 gas/性能权衡。

**结论摘要**
发现 1 个 High、1 个 Medium、2 个 Low。测试未执行，本报告不验证测试结果。

**发现**

**HIGH — 克隆工厂地址不再绑定配置，存在“预先部署 + 恶意 guardian”接管风险**
影响：地址仅由 `owner + salt` 决定，任何人可先为目标 owner 创建账户并设置自己为 guardians。随后可发起社交恢复并在 timelock 后改 owner，导致接管。  
证据：  
`createAccount` 使用 `Clones.predictDeterministicAddress(implementation, keccak256(owner,salt))`，且未要求 owner 签名或授权。`src/core/AAStarAirAccountFactoryV7.sol:81-108`  
`getAddress` 明确忽略 config（地址与配置无关）。`src/core/AAStarAirAccountFactoryV7.sol:110-118`  
建议：绑定创建授权或地址到配置。可选方案：  
1) 要求 owner 对 `owner+salt+configHash` 进行签名授权；  
2) 将 `configHash` 合入 salt（或采用 createAccountWithDefaults 时包含 guardians/dailyLimit 的 hash）；  
3) 或限制 `createAccount` 仅 owner 可调用（会牺牲“代部署”能力）。

**MEDIUM — ALG_WEIGHTED 的阈值未强制单调，存在配置导致 Tier 失真风险**
影响：`tier3Threshold`/`tier2Threshold`/`tier1Threshold` 未强制单调递增。若阈值配置不当（如 tier3 ≤ tier1），低权重签名可能被解析为 Tier3，从而放大权限边界。  
证据：  
`setWeightConfig` 仅校验“单源权重 < tier1Threshold”，未校验阈值顺序或最小可达性。`src/core/AAStarAirAccountBase.sol:1370-1393`  
`_resolveWeightedAlgId` 以阈值从高到低映射 Tier。`src/core/AAStarAirAccountBase.sol:1458-1465`  
建议：增加阈值单调与可达性校验，例如 `tier1 < tier2 < tier3`，并确保存在至少一组权重组合能达到各 tier。

**LOW — ALG_WEIGHTED 与 Guard 白名单语义易混淆**
影响：执行阶段会把 ALG_WEIGHTED 解析为 `ALG_ECDSA / ALG_CUMULATIVE_T2 / ALG_CUMULATIVE_T3`，Guard 实际校验的是解析后的 algId。若外部配置只批准 `0x07` 而未批准底层 algId，交易会被 Guard 拒绝。  
证据：  
执行前将 `ALG_WEIGHTED` 解析为具体 algId。`src/core/AAStarAirAccountBase.sol:980-1015`  
工厂默认把 `0x07` 加入 approvedAlgIds。`src/core/AAStarAirAccountFactoryV7.sol:198-208`  
建议：文档明确“必须批准解析后的 algId”，或在 guard/工厂层自动补全批准底层 algId，避免误配置。

**LOW — 文档中的 algId 标号与实现不一致**
影响：会误导 SDK/前端或审计对算法路由的判断。  
证据：  
`docs/airaccount-comprehensive-analysis.md` 将 ALG_WEIGHTED 写为 `0x03`，将 ALG_P256 写为 `0x04`。`docs/airaccount-comprehensive-analysis.md:30-34,52`  
建议：统一修正文档，保持与合约常量一致（ALG_P256=0x03，ALG_WEIGHTED=0x07）。

**性能 / Gas 观察（非问题）**
EIP‑1167 克隆工厂显著降低账户 runtime size，解决 EIP‑170 上限风险；Session Key 作用域校验与 parser try/catch 增加少量执行期 gas，但换取了更强的安全闭环与可用性。

**测试**
未执行单元测试与 E2E。
