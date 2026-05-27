# Diamond-lite 迁移影响评估：Agent + Weight 治理外移对合约 / Gas / 调用路径 / SDK 的全部影响

- 日期：2026-05-26
- 关联：[ADR: diamond-lite](./2026-05-26-adr-eip170-diamond-lite-extension.md)
- 分支：`fix/eip170-deploy-ready`（目标 `v0.17.1`）
- 受众：合约 + SDK 维护者
- 一句话：为了让账户运行时回到 EIP-170 的 24,576 B 以内，把**两组冷的外部函数**（ERC-8004 agent + weighted-signature 配置治理）从账户搬到单例 `AirAccountExtension`，账户用 `fallback + delegatecall` 路由。**链上行为、存储、权限、事件、错误全部不变**；唯一对外影响是：这些函数不在账户自动 ABI 里，SDK/工具需改用合并后的完整 ABI。

---

## 0. 先厘清："副作用"到底指什么

把不同 ABI 合并成一个文件**不是副作用，是补救措施**。真正的副作用是 diamond/fallback 模式的固有特征：

> **被外移的函数从 `AAStarAirAccountV7` 编译器自动生成的 ABI 中消失了。**

它们链上完全可调用（calldata/selector 不变），但任何"以账户标准 ABI 为唯一真相源"的工具都看不到也编码不出它们。表现：

- **Etherscan**：验证后的账户合约页 Read/Write 标签**不显示** `mintAgentIdentity` / `setWeightConfig` 等（因为它们不在账户 ABI 里）。用户无法在 Etherscan UI 直接点用。
- **类型绑定**：TypeChain / wagmi codegen / ethers typed-contract 从账户 ABI 生成的绑定**缺这些方法**。
- **SDK**：用原始 `out/AAStarAirAccountV7.json` 的 `.abi` 实例化合约，`contract.mintAgentIdentity(...)` 会报"方法不存在"。
- **监控/索引**：以账户 ABI 解码 input/method 的工具会把这些调用识别为"未知方法"（但仍能按 selector 匹配）。

补救：发布合并 ABI `abi/AAStarAirAccountV7.full.json`（账户原生 ABI + 10 个 fallback 路由函数），让上述工具消费它即可恢复。

---

## 1. 两组迁移的边界（哪些动了，哪些没动）

| 维度 | Agent（M8/M9） | Weight 治理（M6.1/M6.2） |
|---|---|---|
| 外移到 extension 的函数 | `setAgentWallet`、`mintAgentIdentity`、`bindERC8004AgentWallet`、`submitAgentReputation`、`queryAgentReputation`（5 个） | `setWeightConfig`、`proposeWeightChange`、`approveWeightChange`、`executeWeightChange`、`cancelWeightChange`（5 个） |
| **留在账户内核（未动）** | `onERC721Received`（接收身份 NFT 用，留 V7） | **`_validateWeightedSignature`、`_resolveWeightedAlgId`（逐笔签名校验，热路径，留 base）** |
| 触碰的存储槽 | 仅 `owner`(slot 1) | `owner`(1) + guardians(12–14) + `activeRecovery`(18) + `weightConfig`(22) + `pendingWeightChange`(23) |
| 调用者 | owner（query 为公开 view） | owner（set/propose/cancel）、guardian（approve/cancel）、任何人（execute，过 timelock 后） |
| 调用频率 | 低（onboarding / 反馈） | 低（一次性配置 / 罕见的削弱治理流程） |

**关键区分（务必理解）**：weighted 签名有两层——
- **配置治理**（`setWeightConfig` 等）：罕见、管理性 → **已外移**。
- **签名校验**（`_validateWeightedSignature` + `_resolveWeightedAlgId`）：**每一笔 weighted UserOp 都跑** → **留在账户内核内联，零改动、零额外 gas**。

所以"weight 相关"被外移的只是低频治理，高频验证完全没动。

---

## 2. 调用频率 & 调用模式：之前 vs 现在

### 2.1 频率

全部 10 个外移函数都是**低频 / 管理性**，**没有一个在 per-UserOp 热路径上**：

- agent：建身份、绑钱包、提交/查询声誉——onboarding 与偶发反馈。
- weight 治理：`setWeightConfig` 通常账户生命周期里设 1 次；削弱配置才走 propose→approve(2/3 guardian)→timelock(2 天)→execute，极罕见。

逐笔交易真正高频的是 `validateUserOp` / `execute` / dailyLimit / ECDSA·P256·BLS·**weighted 验证**——这些**全部留在内核**。

### 2.2 调用模式（链上路径）

**之前（内联）**：
```
EOA/SDK → account.mintAgentIdentity(calldata) → 账户内直接执行
```

**现在（diamond-lite）**：
```
EOA/SDK → account.<同样的 selector + calldata>
        → 账户无此函数 → fallback()
        → delegatecall(agentExtension, msg.data)   // 原样转发，不重新编码
        → extension.mintAgentIdentity 在【账户的存储上下文】执行
        → 返回
```

- **calldata/selector 完全相同** → 任何按 selector 编码的调用方（所有编码器都是）透明可用。
- `delegatecall` 使 `msg.sender`、`address(this)`、storage、events、reverts 全部等同内联——`onlyOwner`、guardian 校验、`nonReentrant`（共享 transient slot 0）、事件 topic、错误 selector 一律不变。
- 调用方**仍然只跟账户地址打交道**，不需要知道 extension 地址（路由是账户内部的事）。

---

## 3. 各维度变动汇总（相比迁移前合约）

| 维度 | 变动 | 说明 |
|---|---|---|
| **账户运行时大小** | 27,975 → **21,722 B**（−6,253） | 回到 EIP-170 限内，余 2,854 B；optimizer_runs 仍 300 |
| **存储布局** | **逐槽完全一致**（slots 0–23） | `forge inspect storageLayout` 重构前后 diff 为空；已部署测试网账户无需迁移 |
| **热路径 gas**（validateUserOp/execute/dailyLimit/各种签名验证含 weighted 验证） | **0 变化** | 全部留内联 |
| **外移函数 gas** | **每次 +~2,600–2,900 gas** | 一次冷地址访问的 `delegatecall`（EIP-2929 cold ≈2,600）+ calldatacopy/returndatacopy（数百）。extension 地址是 immutable，读取 0 gas（烤进运行时码） |
| **账户创建 gas** | **不变** | clone（EIP-1167）仍只是最小代理 + initialize；extension 不随每个 clone 重新部署 |
| **部署** | 每个 implementation 构造时 `new AirAccountExtension()` 一次 | 工厂部署 1 个 impl → 1 个 extension（单例）。所有 clone 通过 impl 运行时里的 immutable 解析到同一个 extension |
| **调用路径** | 外移函数多一跳 fallback→delegatecall | selector/calldata 不变，链上透明 |
| **对外接口（ABI 行为）** | 账户自动 ABI 少了 10 个函数 | 见 §0 副作用 + §4 SDK |
| **事件 / 错误** | **不变** | 同签名 → 同 topic0 / 同 selector；账户仍声明这些 error/event（解码不受影响） |
| **权限模型** | **不变** | onlyOwner / guardian 多签 / timelock 完全保留 |
| **能力** | **零损失** | 功能与迁移前逐一等价（791/791 测试 + Codex 4 轮 approve 验证） |
| **审计面** | 略增 | 多一个 extension 合约 + 一条 catch-all fallback delegatecall（仅指向自有可信单例） |

### 性能小结
- 用户日常转账 / gasless 交易 / 限额检查 / 各类签名验证：**性能与 gas 与之前完全一致**。
- 只有"建 agent 身份 / 提交声誉 / 改 weight 配置"这类罕见管理操作每次多约 2,600 gas，可忽略。

---

## 4. 对 SDK 的具体影响与需要做的调整

### 4.1 影响本质
账户地址不变、调用方式不变、selector 不变——**唯一变化是"账户的 ABI 现在不完整"**。SDK 只要换成完整 ABI 即可，调用代码无需改写。

### 4.2 ABI：用合并后的完整版
- 合约仓产出 **`abi/AAStarAirAccountV7.full.json`** = 账户原生 ABI + 10 个 fallback 路由函数（agent + weight 治理）。
- 生成 / 校验：`node scripts/build-full-abi.mjs`（`--check` 进 CI，校验每个路由 selector 都在、且与账户原生 selector 无碰撞）。
- **SDK 必须用这个 full ABI 实例化账户合约**，而不是 `out/AAStarAirAccountV7.sol/AAStarAirAccountV7.json` 的 `.abi`。

### 4.3 使用方式（不变，仅换 ABI）
```ts
// viem —— 地址仍是账户地址，abi 换成 full
import fullAbi from "@aastar/abis/AAStarAirAccountV7.full.json";
const account = getContract({ address: accountAddress, abi: fullAbi.abi, client });
await account.write.mintAgentIdentity([identityRegistry, agentURI]);   // 走账户 fallback，透明
await account.write.setWeightConfig([weightConfig]);                   // 同上
```
```ts
// ethers v6
const account = new Contract(accountAddress, fullAbi.abi, signer);
await account.setAgentWallet(agentId, agentWallet, agentRegistry, sig);
```
- **不要**单独实例化 extension，也**不要**用 extension 地址；调用始终发往账户地址。
- 事件监听 / revert 解码：用 full ABI（或原账户 ABI，因为 error/event 仍在账户 ABI 中声明），topic0 与 selector 不变，无需改。

### 4.4 SDK 需要做的清单
1. **替换账户 ABI** 为 `AAStarAirAccountV7.full.json`（agent + weight 治理函数恢复可编码）。
2. **重生成类型绑定**（TypeChain / wagmi / viem codegen）自 full ABI。
3. **Gas 估算**：这些函数 `eth_estimateGas` 会自动多算约 2,600 gas，无需手动调；若有硬编码的 gas 上限，给 agent/weight 治理调用留出余量。
4. **文档**：在集成文档注明账户是 diamond-lite，agent/weight 治理走 fallback，必须用 full ABI；Etherscan 上这些函数不在账户页（属预期）。
5. **地址配置**：无需新增 extension 地址（SDK 不直接调它）；如需展示，可记录但非必需。
6. **回归**：跑一遍 agent onboarding + weighted 配置的端到端，确认换 ABI 后调用通。

### 4.5 不需要做的事
- 不需要改任何调用签名 / 参数。
- 不需要改地址解析（账户地址不变）。
- 不需要处理 extension 的 ABI（其表面已并入 full ABI）。

---

## 5. 验证状态
- 全量回归 **791/791 通过**（agent/weight 经 fallback→delegatecall→extension 真实路径验证）。
- EIP-170 canary 4/4 绿（账户/工厂/Delegate/extension 全 <24,576）。
- 存储布局逐槽一致。
- Codex 严格 review 4 轮 → **approve**（无安全/存储/重入/权限回归）。

---

## 6. 给 SDK 维护者的 TL;DR
账户升级为 diamond-lite：agent + weight 治理函数改走 fallback。**你唯一要做的是把账户 ABI 换成 `abi/AAStarAirAccountV7.full.json` 并重生成类型绑定**。调用方式、地址、selector、事件、错误全不变；这些函数每次多约 2,600 gas（罕见管理操作，可忽略）；逐笔交易性能零影响。
