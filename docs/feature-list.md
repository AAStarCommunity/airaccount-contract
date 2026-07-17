# AirAccount Feature List — M1 to M7

Complete feature reference by milestone. Each feature includes its characteristics, user value, and whether the user needs to actively trigger it or it works passively in the background.

**Active** = user must explicitly trigger or configure  
**Passive** = works automatically as a safety/infrastructure layer

---

## M1 — ERC-4337 ECDSA 基础账户

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **ERC-4337 UserOperation** | 兼容标准 EntryPoint，Bundler 转发，无需用户持有 ETH 发交易 | Gasless 体验，邮箱即账户，无助记词 | 被动 |
| **ECDSA 签名验证**（algId 0x02） | 65 字节标准 secp256k1，向后兼容以太坊生态 | 现有以太坊钱包可直接使用，无迁移成本 | 被动 |
| **CREATE2 确定性部署** | 同一 owner + salt → 同一地址，多链一致 | 账户地址可提前预测，跨链身份统一 | 被动 |
| **不可升级设计** | 无代理模式，无 UUPS，逻辑固化在合约里 | 无管理员后门，合约不会被偷偷修改 | 被动 |

---

## M2 — BLS 三重聚合签名

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **BLS 三重签名**（algId 0x01） | ECDSA×2 + BLS 聚合一次验证，链上单次 pairing | 大额交易多方联防，不被单点攻击 | 主动（大额触发） |
| **Gas 节省 50%** | vs YetAA 参考实现：523k → 259k gas | 高频大额操作成本减半 | 被动 |
| **BLS 聚合器合约** | `AAStarBLSAggregator`，多 UserOp 共享一次 pairing | 多用户打包时进一步节省 gas | 被动 |
| **algId 路由体系** | 签名首字节即路由标识，零歧义分发给对应验证器 | 未来扩展新算法不改主合约 | 被动 |

---

## M3 — 安全加固 & Gas 优化

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **Gas 再降 51%** | M2 259k → M3 127k，Solc 0.8.33 + Cancun EVM | 同等安全性下交易费用减半 | 被动 |
| **签名绑定哈希** | 签名覆盖 calldata hash，防签名重放与替换 | 无法用旧签名发起新攻击 | 被动 |
| **Transient storage** | EIP-1153 传递 algId 跨调用栈，无持久化 gas 成本 | 更低 gas，无状态污染 | 被动 |

---

## M4 — 分级累积签名 + 社会恢复

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **Tier 1**（algId 0x02/0x03） | 单因素：ECDSA 或 P256 WebAuthn | < $100 交易，指纹一点即过 | 主动（日常路径） |
| **Tier 2**（algId 0x04） | P256 + BLS DVT 共签 | $100–$1000，双设备确认，防单点被盗 | 主动（触发门槛） |
| **Tier 3**（algId 0x05） | P256 + BLS + Guardian ECDSA 三重 | > $1000，多方联防，极高安全 | 主动（大额必须） |
| **社会恢复** | 3 个 guardian（亲友/设备/社区），2-of-3 投票，48h timelock | 手机丢失后可恢复账户，任意两方即可 | 主动（紧急场景） |
| **cancelRecovery 保护** | 取消恢复需 2-of-3 guardian 投票，owner 无法单独取消 | 私钥被盗后攻击者无法阻止正常恢复 | 被动 |

---

## M5 — ERC20 守卫 + 治理 + 零信任 T1

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **GlobalGuard ETH 限额** | 合约底层硬编码每日 ETH 消费上限，任何签名组合不可绕过 | 即使私钥被盗，每日损失有上限 | 被动 |
| **ERC20 token 独立限额** | 每个 token 配置 Tier1/Tier2/每日限额 | 稳定币、DeFi token 分开设防 | 主动（用户配置） |
| **CalldataParser** | Railgun、Uniswap V3 calldata 解析，提取实际转账 token 和金额 | DeFi 操作也被守卫覆盖，不只是普通转账 | 被动 |
| **单调安全配置** | 每日限额只能降低不能提高，算法只能增加不能删除 | 不存在"通过提高限额绕过守卫"的攻击面 | 被动 |
| **Guardian accept 机制** | Guardian 需主动签名接受才生效 | 不会在不知情的情况下背负他人账户恢复责任 | 主动（guardian 确认） |
| **零信任 T1**（algId 0x06） | P256 AND ECDSA 同时验证，Tier1 下双因素同时出具 | 高价值小额操作（如授权签名）也可强制双因素 | 主动（手动开启） |

---

## M6 — Session Key + 加权多签 + EIP-7702

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **Session Key**（algId 0x08） | 时限性临时密钥，过期自动失效，限额独立 | DApp 授权后免反复确认，类似"登录态" | 主动（用户授权） |
| **Weighted MultiSig**（algId 0x07） | 每个签名源（P256/BLS/guardian）配置权重，阈值可定制 | 灵活的多签策略，2 个 guardian 可等于 1 个 owner | 主动（用户配置） |
| **弱化变更 timelock** | 降低安全强度（权重减少）需 2-of-3 guardian + 48h 等待 | 攻击者拿到私钥也无法立刻降低防护 | 被动 |
| **EIP-7702 AirAccountDelegate** | EOA 可通过 Type 4 交易临时委托给 AirAccount 逻辑 | 无需部署合约即享受部分 AA 功能，迁移门槛极低 | 主动（EOA 主动委托） |
| **ForceExitModule** | 2-of-3 guardian 授权后可强制转出全部资产 | 极端情况（合约 bug）也有逃生通道 | 主动（紧急使用） |

---

## M7 — ERC-7579 模块 + Agent Economy + 隐私标准

| Feature | 特征 | 用户价值 | 主动/被动 |
|---------|------|---------|---------|
| **ERC-7579 模块系统** | 支持 Validator(1)/Executor(2)/Hook(3) 三类模块，guardian 授权安装/卸载 | 账户可按需安装功能插件，不改主合约 | 主动（用户安装） |
| **加权多签（0x07, `_validateWeightedSignature`）** | 内联在 `AAStarAirAccountBase` 的加权多签验证；v0.17.2-beta.1 起独立的 `AirAccountCompositeValidator` 已删除、逻辑内联（与 0x08 SessionKeyValidator 无关） | 更复杂的签名策略无需外挂模块 | 主动 |
| **TierGuardHook** | ERC-7579 Hook，每次执行前强制 tier 检查 | 模块路径下的交易同样受 tier 守卫保护 | 被动 |
| **Agent 会话密钥（统一 `SessionKeyValidator`, algId `0x08`）** | 过期时间 + 消费上限 + 调用速率（velocity）限制。v0.17.2-beta.1 起独立的 `AgentSessionKeyValidator` 已删除并入 `SessionKeyValidator`，经 `grantSession`/`grantSessionDirect` 授权 | 授权 AI Agent 操作账户，限额可控，随时撤销 | 主动（用户授权） |
| **delegateSession 子委托** | Agent 可向子 Agent 委托，子配置不可超过父配置（速率用 cross-multiply 比较） | Agent 可安全再授权，不会超出原始授权范围 | 被动（自动校验） |
| **ERC-5564 Stealth Address** | 发送方发布一次性隐匿收款地址公告，接收方链下扫描 | 隐匿收款，无法从链上追踪资金归属 | 主动（用户发起） |
| **ERC-7828 链限定地址** | `keccak256(addr \|\| chainId)`，同地址跨链有不同标识 | 防止跨链重放和地址混淆攻击 | 被动 |

---

## 尚未实现 / 规划中

| Feature | 说明 | 预计里程碑 |
|---------|------|---------|
| **Railgun 隐私池接入** | `RailgunParser` 合约已实现（能解析 calldata），但实际接入 shielded pool 存取款流程尚未完成 | M8+ |
| **OAPD 子账户隔离** | 每 DApp 一个隔离账户的完整产品流程，合约层已预留接口，SDK/产品层待实现 | M8+ |
| **抗量子签名**（algId 0x10） | 接口和 algId 已预留（ML-DSA/Dilithium），验证合约待开发 | M8+ |
| **EIP-8130 Native AA 兼容** | 等 Hegota fork EIP 确认后执行 | 2026 Q3 |

---

*Last updated: 2026-05-21*  
*Source: M1–M7 contract layer — `src/core/`, `src/validators/`, `src/aggregator/`*
