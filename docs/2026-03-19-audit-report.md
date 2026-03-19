2026-03-19 合约审计报告（M5 修订后）

**范围**
- 合约：`AAStarAirAccountBase.sol`、`AAStarGlobalGuard.sol`、`AAStarAirAccountFactoryV7.sol`、`AAStarAirAccountV7.sol`
- 关键脚本：部署/ E2E 脚本中涉及 Factory 构造函数的部分
- 设计一致性：guardian 接受签名的签名格式相关文档

**方法**
- 静态审查代码与脚本
- 设计文档与实现的一致性比对

**结论摘要**
- 未发现新的 Critical/High 级别合约漏洞。
- 发现 2 个 Medium（主要是脚本与文档一致性风险）与 1 个 Low（默认 token 配置输入约束不足）。
- 未执行测试，本报告不验证测试结果。

**发现**

**MEDIUM — 旧脚本仍使用旧 Factory 构造函数**
影响：当前 Factory 构造函数已是 4‑arg，旧脚本仍使用 1~2 个参数编码，实际部署会失败或产生不可用工厂地址，导致 E2E/部署流程失真。  
证据：  
- `scripts/test-e2e-ecdsa.ts:313-318` 仍仅编码 `ENTRYPOINT`  
- `scripts/deploy-m4.ts:80-85` 仍传入 2 个参数  
- `scripts/deploy-m3.ts:74-81` 仍传入 2 个参数  
建议：更新所有脚本到 4‑arg 构造函数，或在脚本中强制退出并提示使用新部署脚本。

**MEDIUM — Guardian 接受签名格式的文档未同步**
影响：合约已升级为 `("ACCEPT_GUARDIAN", chainId, factory, owner, salt)` 域分隔格式，但多处文档仍引用旧格式，会误导 SDK/前端/运维生成错误签名，导致创建失败。  
证据：  
- `docs/contracts_vs_design_comparison.md:64`  
- `CHANGELOG.md:167`  
- `docs/M5-plan.md:269-272`  
- `AGENTS.md:387`  
建议：统一更新所有文档/指南中的接受签名格式与示例。

**LOW — 默认 token 配置缺少地址合法性/去重校验**
影响：Factory 构造函数仅校验 tier/daily 关系，未校验 token 地址为非零、无重复。若误传 `address(0)` 或重复地址，可能导致 guard 配置语义异常或误覆盖。  
证据：`src/core/AAStarAirAccountFactoryV7.sol:38-49`  
建议：在构造函数中加入 `token != address(0)` 与重复地址检查。

**已观察到的改进（非发现）**
- ALG_BLS messagePoint 已绑定 `userOpHash`
- Token guard tier 映射已与账户模型对齐
- CombinedT1 ECDSA 加入 EIP‑2 low‑s 检查
