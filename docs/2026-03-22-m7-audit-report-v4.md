2026-03-22 M7 复审报告（变动后审计）

**范围**
仅检测到脚本层变动：`scripts/test-force-exit-e2e.ts` 与新增 `scripts/deploy-m7-r3.ts`。合约代码未发现变更。

**结论摘要**
新增 1 个 Medium、1 个 Low、1 个 Info。合约层安全结论与上一版报告一致；若预期有修复，请确认合约改动已提交。

**变动摘要**
- ForceExit E2E：每次运行使用新盐并强制部署新模块与新账户，减少历史状态污染。
- 新增 M7 r3 部署脚本：部署 CompositeValidator + Factory + 账户，含测试性默认参数。

**新增发现**

**MEDIUM — 部署脚本默认使用公开测试私钥，易误用到生产**
影响：`deploy-m7-r3.ts` 在未配置环境变量时回退到公开测试私钥（bob/jack），若误用于生产网络，会导致 guardians 可被第三方直接控制。  
证据：`GUARDIAN1_KEY` / `GUARDIAN2_KEY` 有默认值。`scripts/deploy-m7-r3.ts:41-42`  
建议：删除默认私钥回退，缺失即退出；或强制校验与链环境（仅允许本地/测试链）。

**LOW — E2E 盐值基于秒级时间戳，可能在并发/同秒运行时碰撞**
影响：并发运行或短时间重复运行时可能复用同一 salt，仍会命中历史状态导致测试非确定。  
证据：`TEST_SALT` 采用 `Date.now()/1000` 取模。`scripts/test-force-exit-e2e.ts:72-74`  
建议：改为 `timestamp + random` 或允许 `FORCE_EXIT_TEST_SALT` 环境变量覆盖。

**INFO — 部署脚本将 dailyLimit/minDailyLimit 设为 0**
影响：若产品约束要求日限额默认大于 0，该配置会偏离设计意图；若合约允许 0，则需要在部署层强制显式确认。  
证据：`initConfig.dailyLimit = 0`，`minDailyLimit = 0`。`scripts/deploy-m7-r3.ts:132-136`  
建议：根据设计要求添加断言或在脚本参数中显式传入。

**沿用未修复问题**
合约层未检测到变更，本次不重复列举。请参考上一版审计报告：`docs/2026-03-22-m7-audit-report-v3.md`。

**测试**
未执行单元测试与 E2E。
