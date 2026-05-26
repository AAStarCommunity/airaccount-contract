# ADR: 用自定义精简 Diamond（fallback-extension）解决 EIP-170 超限

- 日期: 2026-05-26
- 状态: Accepted（实施中）
- 分支: `fix/eip170-deploy-ready` → 目标 tag `v0.17.1`

## 背景与问题

`AAStarAirAccountV7` 运行时字节码超过 EIP-170 的 24,576 B 上限（runs=1 时 27,666 B，
runs=300 时约 27,975 B），导致**无法部署到真实链**（Foundry 测试 EVM 不强制该限制，
所以测试能过、部署会被拒）。已加 canary 测试 `test/Eip170Size.t.sol` 防回归。

### 为什么这次超了这么多

不是某一处突然爆，而是账户一直贴着天花板，M8/M9 把它压过线：

| 版本 | 账户 size | 距 24,576 上限 |
|---|---|---|
| M7 (v0.16.0，上次部署) | ~20,900 | 仅剩 ~3,676 余量 |
| v0.17.0 (现在) | ~27,666 (runs=1) | 超 ~3,090 |

M8+M9 增量约 6,766 B：M8 agent ERC-8004 能力（mint/bind/submit/query + setAgentWallet）
≈ 2,011 B + 官方 3 个 ERC-8004 接口调用编码 + chain-id 地址表内联 + M9 安全修复
（modifyTierLimitsWithGuardians、executor tier 强制、ERC-1271 等）。

## 已排除的方案

- **降 optimizer_runs**: runs=1 仍 27,666 > 上限，且伤运行时 gas。用户要求 runs≥300。已弃。
- **代码级去重/内联/去 modifier**: via-IR + optimizer 已自动去重，手工只净省 ~360 B。不够。
- **external library + delegatecall**: 对 string/动态参数函数无效——账户作为调用方必须把
  参数 ABI 编码进 delegatecall 的 calldata，这段"打包代码"留在账户里。`submitAgentReputation`
  有 4 个 string 参数，实测 ERC8004Lib 仅净省 126 B（2,011 B 主体），SigValidationLib 因
  helper 重复仅 338 B。效率 ~6-10%。已弃。
- **ERC-7579 模块**: 用户明确否决——安装模块是 UX 负担。
- **完整 EIP-2535 Diamond**: 可行但更重（selector 表 + diamondCut 治理、所有路径 +gas、
  审计/工具成本高），且默认带可升级能力与 non-upgradable 哲学冲突。作为后备。

## 决策：自定义精简 Diamond（diamond-lite / fallback-extension）

账户保留内核（壳 + 路由），把弱关联的冷能力搬到一个**单例 extension 合约**，账户用
`fallback` 把这些 selector 的**原始 calldata 原样 `delegatecall`** 给 extension。

这本质就是 EIP-2535 Diamond 的精简版：写死一个 fallback 指向固定 extension、不可增删、
无 diamondCut —— 更轻、且符合 non-upgradable。

### 为什么 fallback 转发高效，而 library 不行

fallback 转发时，**调用方（SDK/EntryPoint）已经把参数编码进 calldata**；账户 fallback 只是
`calldatacopy` + `delegatecall` 原样转发，账户**自己一个字节都不重新打包**。所以 string 参数
多也无所谓，函数整体搬走、账户净省接近全部（不像 library 留打包代码只省 ~6-10%）。

### 切割边界（业务内聚）

| 核心钱包域（留内核） | 外移域（搬 extension） |
|---|---|
| 签名验证(`_validate*`)、execute、社交恢复、日限额/guard | ERC-8004 身份/声誉/钱包绑定、agent 相关 |
| 每笔交易都走、安全攸关、热路径 | 极少调用、admin/onboarding 性质 |

- 第一刀: agent（ERC-8004 mint/bind/submit/query + setAgentWallet + onERC721Received）。
- 若不够: 再切 weight 治理（setWeightConfig/proposeWeightChange/executeWeightChange）等冷的
  **外部**函数。**尽量不动社交恢复**（与资产安全强相关，留内核更稳妥）。
- 注意: 签名验证器是 `internal` 函数（validateUserOp 内部分派，不走 selector），**fallback 搬不了**，
  只能留内联——而它正是热路径，本就该留内核。

## 关键保证：零能力损失、零耦合断裂

delegatecall 让 extension 代码**跑在账户自己的上下文**：
- `msg.sender`、`address(this)` 仍是账户本身
- `storage` 仍是账户同一批 slot（owner、agent 状态、guard 配置都在）
- `onlyOwner` / `nonReentrant` / `emit` / 读 validator / 调 `execute` 全部照常

所以 agent "用账户能力"的耦合一个不断，对外 ABI 不变、用户行为零变化。
（这正是它优于"普通外部合约调用"之处——后者会把 msg.sender 变成中间合约、storage 分家，
那才会断耦合丢能力。）

## 代价（已知、可控）

1. **storage 布局纪律**: extension 必须与账户共享同一存储布局（继承同一存储基类），写错会撞 slot。
2. **少量 helper 重复**: agent 用到的 `internal` 小工具会编进 extension 一份；但 extension 有独立
   24KB 预算，不占账户空间；账户侧只被 agent 用的 helper 可删。
3. **冷路径 +gas**: agent/外移函数每次多一次 delegatecall+SLOAD（~2,600 gas）；热路径零影响。
4. **多一个合约地址**: extension 是**单例**（全网部署一次，写死 immutable 地址），不增加每个用户开户
   成本，运维上与已有 validator/guard/router 同量级。
5. **审计面**: 略增（多一个合约 + delegatecall 路由）。

## 实施路径

1. 建 `AgentExtension`（共享存储布局）+ 账户 fallback 路由。
2. `forge build --sizes` 实测账户净省，对比 24,576。
3. 不够则补 weight 治理那组冷函数再测。
4. 全量回归（788+ 测试）+ canary 转绿 → commit。
5. 达标且回归通过 → 确认后 tag v0.17.1。

## 实测结果（2026-05-26）

| 阶段 | AAStarAirAccountV7 runtime | 距 24,576 |
|---|---|---|
| 重构前 (runs=300) | 27,975 | 超 3,399 |
| 移出 agent | 25,418 | 超 842 |
| 再移出 weight 治理 | **21,722** | **余 2,854 ✓** |

- 共减少 **6,253 B**，optimizer_runs 保持 300。
- 新增 `AirAccountExtension`（agent + weight 冷函数）runtime 8,330 B，远低于上限。
- `forge inspect storageLayout` 对比重构前后：**逐槽完全一致**（slots 0–23 未变），已部署账户无需迁移。
- 全量回归 **791/791 通过**（agent/weight 经 fallback→delegatecall→extension 路径验证），EIP-170 canary 4/4 转绿。
- 切割边界最终为 agent + weight 治理；**社交恢复保留在内核**（符合诉求）。
- 实现要点：account 构造函数内 `new AirAccountExtension()`（创建码，不计入 EIP-170 运行时），immutable 存地址；`new AAStarAirAccountV7()` 仍无参，44 处测试与工厂调用零改动；类型化调用经 `IAirAccountAgent` 接口。
