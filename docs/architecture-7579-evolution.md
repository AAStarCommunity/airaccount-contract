# AirAccount Architecture: ERC-7579 Integration & Stage Evolution

**Document date**: 2026-03-21
**Version**: AirAccount v0.15.0 (M6) → M7 target
**Author**: Architecture Discussion

---

## 核心命题

两条并行演进主线：
1. **ERC-7579 融合**：将 AirAccount 的自定义系统映射到 ERC-7579 模块框架
2. **Stage 0 → 1 → 2 演进**：满足 WalletBeat 的渐进式路线

---

## Diagram 1: ERC-7579 标准模块分类（纯参考）

四种模块类型 + 账户核心的标准关系：

```mermaid
flowchart TD
    EP["EntryPoint v0.7\n(ERC-4337)"]
    BND["Bundler"]

    BND -->|打包 UserOp| EP

    subgraph CORE["ERC-7579 Account Core"]
        VUO["validateUserOp(userOp, hash)\n→ 委托给 Validator 模块"]
        EXE["execute(ModeCode, calldata)\n→ 触发 Hook 前后钩子"]
        EFE["executeFromExecutor(mode, data)\n← 被 Executor 模块调用"]
        INS["installModule / uninstallModule\n+ isModuleInstalled"]
    end

    EP -->|1 验证阶段| VUO
    EP -->|2 执行阶段| EXE

    subgraph V["① Validator 模块 (Type 1)"]
        V1["validateUserOp()\nisValidSignatureWithSender()"]
    end

    subgraph E["② Executor 模块 (Type 2)"]
        E1["onInstall / onUninstall\n主动调用 executeFromExecutor"]
    end

    subgraph F["③ Fallback 模块 (Type 3)"]
        F1["fallback()\n按 selector 路由未知函数"]
    end

    subgraph H["④ Hook 模块 (Type 4)"]
        H1["preCheck(sender, value, calldata)\n→ hookData\n\n[execution]\n\npostCheck(hookData)"]
    end

    VUO -->|委托验签| V1
    EXE -->|wrap每次执行| H1
    EFE -->|executor主动触发| E1
    EXE -->|未知selector| F1

    subgraph REG["ERC-7484 模块注册表 (可选)"]
        MR["attestation: bytecodeHash → auditors\n安装前检查模块安全性"]
    end

    INS -.->|安装前验证| MR
```

**ERC-7579 刻意留白的内容**（给实现者自定义空间）：
- 社会恢复机制
- 花费限制 / 速率限制
- 签名算法选择逻辑
- 业务策略 / 准入规则
- Paymaster 费用委托

---

## Diagram 2: 理想钱包完整系统架构

包含前端 SDK、后端服务、合约层的全系统视图：

```mermaid
flowchart TD
    subgraph DEVICES["用户设备层"]
        HW["硬件钱包\nLedger / Trezor / GridPlus\nP256 / ECDSA 签名"]
        PK["Passkey / WebAuthn\n手机 Secure Enclave / YubiKey\nP256 签名"]
        EOA["EOA 密钥\nMetaMask / 助记词\nECDSA 签名"]
    end

    subgraph SDK["前端 SDK 层 (TypeScript / viem)"]
        ASDK["AirAccount SDK\nuserOp 构造 + 签名路由\nEIP-1193 Provider 包装\nEIP-6963 多钱包发现"]
        HC["Helios 轻客户端\n@a16z/helios\n无信任 RPC 验证"]
        ENS["ENS 解析\nviem getEnsAddress\n+ normalize()"]
        RSDK["Railgun SDK\n@railgun-community/wallet\nshield / unshield 操作"]
        X402["x402 支付客户端\n@x402/core\nEIP-3009 离线签名"]
    end

    subgraph BACKEND["后端服务层"]
        BND["Bundler\nPimlico / Alchemy / Stackup\n打包 UserOp → EntryPoint"]
        PMGR["Paymaster 服务\nSuperPaymaster\n代付 Gas"]
        IDX["链上索引\nThe Graph / Ponder\n事件监听 + 状态查询"]
        DVT["DVT 网络 (M7.1 未来)\n遗嘱执行验证\nWillExecutor 预言机"]
        KMS["KMS (密钥托管)\nkms.aastar.io TEE\n可选: 托管私钥"]
    end

    subgraph CONTRACTS["合约层 (ERC-4337 + ERC-7579)"]
        EP["EntryPoint v0.7\n0x0000...71727De22E5E9d8BAf0edAc6f37da032"]
        FAC["Factory\nEIP-1167 Clone\nCREATE2 确定性地址"]

        subgraph ACC["AirAccount Core (ERC-7579 兼容)"]
            VUO2["validateUserOp()\n路由到 Validator 模块"]
            EXE2["execute() / executeBatch()\n触发 Hook 链"]
            EFE2["executeFromExecutor()\n← Executor 模块入口"]
            INS2["installModule()\nguardian 2-of-3 授权 + timelock"]
        end

        subgraph VMODS["Validator 模块 (Type 1)"]
            VM1["ECDSAValidator\nalgId=0x02"]
            VM2["P256Validator\nalgId=0x03"]
            VM3["BLSValidator\nalgId=0x01"]
            VM4["SessionKeyValidator\nalgId=0x08"]
            VM5["WeightedValidator\nalgId=0x07\n★ AirAccount 自定义"]
            VM6["CumulativeValidator\nalgId=0x04/0x05\n★ AirAccount 自定义"]
        end

        subgraph EMODS["Executor 模块 (Type 2)"]
            EM1["GuardianRecoveryExecutor\n2-of-3 guardian 社会恢复"]
            EM2["WillExecutor (M7.1)\n遗嘱资产转移\n★ AirAccount 自定义"]
            EM3["AgentSessionExecutor (M7.14)\n多层 Agent 委托\n★ AirAccount 自定义"]
        end

        subgraph HMODS["Hook 模块 (Type 4)"]
            HK1["TierGuardHook\nT1/T2/T3 层级控制\n读 TSTORE algId\n★ AirAccount 自定义"]
            HK2["DailyLimitHook\n日限额强制\n★ AirAccount 自定义"]
            HK3["TokenLimitHook\nERC-20 额度限制\n★ AirAccount 自定义"]
        end

        subgraph SHARED["共享服务 (AirAccount 专有)"]
            GRD["AAStarGlobalGuard\n不可变花费守卫\n与 Hook 模块协同"]
            CPR["CalldataParserRegistry\nRailgun / Uniswap 解析\ntoken 金额提取"]
        end

        subgraph BRIDGE["EIP-7702 桥接 (★ AirAccount 专有)"]
            DEL["AirAccountDelegate\nEOA 临时升级为 AA\nguardian rescue 机制"]
        end
    end

    DEVICES --> SDK
    SDK --> BACKEND
    SDK --> EP
    BACKEND --> EP
    EP --> ACC
    FAC --> ACC
    ACC --> VMODS
    ACC --> EMODS
    ACC --> HMODS
    HMODS --> GRD
    HMODS --> CPR
```

---

## Diagram 3: AirAccount 当前架构 → ERC-7579 映射关系

展示当前组件如何对应到 ERC-7579 模块类型，以及什么是 AirAccount 独有扩展：

```mermaid
flowchart LR
    subgraph NOW["当前 AirAccount (M6)"]
        A1["AAStarValidator\n(外部合约)"]
        A2["AAStarGlobalGuard\n(外部合约)"]
        A3["SessionKeyValidator\n(外部合约)"]
        A4["GuardianRecovery\n(内嵌在 Base)"]
        A5["T1/T2/T3 Tier\n(内嵌在 execute)"]
        A6["Weighted / Cumulative\n(内嵌在 Validator)"]
        A7["AirAccountDelegate\n(EIP-7702)"]
        A8["CalldataParserRegistry"]
    end

    subgraph MAP["ERC-7579 映射目标 (M7)"]
        B1["✅ Validator Module (Type 1)\nECDSA / P256 / BLS\n分拆为独立模块"]
        B2["✅ Hook Module (Type 4)\nTierGuardHook + DailyLimitHook\n读 TSTORE algId 决定 tier"]
        B3["✅ Validator Module (Type 1)\nSessionKeyValidator\n已接近 7579 格式"]
        B4["✅ Executor Module (Type 2)\nGuardianRecoveryExecutor\n2-of-3 + timelock"]
        B5["⭐ 超出 7579 标准范围\nalg 选择驱动的 tier 策略\nalgId → TSTORE → Hook 读取"]
        B6["⭐ 超出 7579 标准范围\n加权/累积多签\n可包装为 Validator 模块"]
        B7["⭐ ERC-7579 外\nEIP-7702 专属机制\n独立维护"]
        B8["⭐ AirAccount 专有\nHook 模块的依赖服务\n不纳入 7579 模块体系"]
    end

    A1 --> B1
    A2 --> B2
    A3 --> B3
    A4 --> B4
    A5 --> B5
    A6 --> B6
    A7 --> B7
    A8 --> B8

    style B5 fill:#fff3cd,stroke:#ffc107
    style B6 fill:#fff3cd,stroke:#ffc107
    style B7 fill:#f8d7da,stroke:#dc3545
    style B8 fill:#f8d7da,stroke:#dc3545
    style B1 fill:#d4edda,stroke:#28a745
    style B2 fill:#d4edda,stroke:#28a745
    style B3 fill:#d4edda,stroke:#28a745
    style B4 fill:#d4edda,stroke:#28a745
```

**图例**：
- 🟢 绿色 = 通用逻辑，完整映射到标准 ERC-7579 模块接口
- 🟡 黄色 = AirAccount 特有业务逻辑，位于 7579 框架内的自定义空间（接口仍是标准 IValidator/IHook/IExecutor）
- 🔴 红色 = AirAccount 专有特性，7579 框架外，独立维护

---

## Diagram 4: T1/T2/T3 Tier 信号流 — algId 如何穿越验证→执行边界

这是 AirAccount 最独特的架构挑战：algId 在验证阶段产生，但 tier 决策在执行阶段需要。

```mermaid
sequenceDiagram
    participant EP as EntryPoint
    participant ACC as AirAccount Core
    participant VM as Validator 模块
    participant TS as EIP-1153 Transient Storage
    participant HK as TierGuardHook
    participant GRD as AAStarGlobalGuard

    Note over EP,GRD: 验证阶段 (Phase 1)
    EP->>ACC: validateUserOp(userOp, hash)
    ACC->>ACC: 从 nonce 或 signature 提取 algId
    ACC->>VM: 委托: vm.validateUserOp(userOp, hash)
    VM->>VM: 验签 (ECDSA / P256 / BLS / Session)
    VM->>TS: TSTORE(ALGID_SLOT, algId)
    Note right of TS: algId 存入瞬态存储\n本 tx 内有效，tx后清除
    VM-->>ACC: 返回 validationData (0=valid)
    ACC-->>EP: 返回 validationData

    Note over EP,GRD: 执行阶段 (Phase 2)
    EP->>ACC: execute(ModeCode, calldata)
    ACC->>HK: preCheck(sender, value, calldata)
    HK->>TS: TLOAD(ALGID_SLOT) → algId
    HK->>HK: 根据 algId 判断 tier<br/>T1: algId=0x02 (ECDSA) value≤$100<br/>T2: algId=0x04 (P256+BLS) value≤$1000<br/>T3: algId=0x05 (P256+BLS+Guardian) any value
    HK->>GRD: checkTransaction(dest, value, algId)
    GRD-->>HK: 通过 / revert TierViolation
    HK-->>ACC: hookData (记录 tier 决策)
    ACC->>ACC: 执行实际调用 (call target)
    ACC->>HK: postCheck(hookData)
    HK->>HK: 验证执行后状态一致性
    HK-->>ACC: ok
```

**关键设计**：
- `ALGID_SLOT = keccak256(abi.encode(account, "algId"))` — 账户隔离，防止跨账户读取
- `TSTORE` / `TLOAD` (EIP-1153, Cancun 已支持) — 零持久存储开销，tx 后自动清除
- Hook 是 ERC-7579 标准接口，只是读取了 AirAccount 自己写入的 transient slot

---

## Diagram 5: AirAccount 架构演进路线

从 M6 现状到 Stage 2 的分阶段演进：

```mermaid
flowchart TD
    subgraph M6["M6 现状 (2026-03-21)"]
        M6A["✅ ERC-4337 v0.7 完整实现\n✅ T1/T2/T3 内嵌 execute()\n✅ AAStarGlobalGuard 外部守卫\n✅ SessionKeyValidator\n✅ ERC-7579 shim (只读接口)\n✅ EIP-7702 桥接\n✅ CalldataParserRegistry\n✅ Stage 0 通过 (GPL-3.0 公开)"]
    end

    subgraph M7A["M7 Phase A: 7579 模块化重构"]
        direction TB
        P1["M7.2: installModule + executeFromExecutor\nguardian 2-of-3 gate + timelock\nTierGuardHook (algId via TSTORE)"]
        P2["M7.4: ERC-7828 chainId helper\nM7.3: EIP-1167 factory (已完成)"]
        P3["M7.11: RailgunParser\n前端 Railgun SDK 集成"]
    end

    subgraph M7B["M7 Phase B: 安全 + 生态"]
        direction TB
        Q1["M7.6: 专业外部审计\nCodeHawks / Code4rena\n★ Stage 1 解锁条件"]
        Q2["M7.7: Immunefi Bug Bounty\n$50k 初始资金\n★ Stage 2 条件之一"]
        Q3["M7.14: Agent Session Key Module\n速度限制 + callTarget 白名单"]
    end

    subgraph M7C["M7 Phase C: L2 + 隐私"]
        direction TB
        R1["M7.5: L2 部署 (Base/Arbitrum/OP)\n+ 强制提款 force-exit\n★ Stage 2 S2-4 达成"]
        R2["M7.12/M7.13: Kohaku + ERC-5564\n隐私功能增强"]
        R3["M7.16: ERC-8004 Agent Identity\nM7.15: x402 支付协议"]
    end

    subgraph STAGE1["Stage 1 解锁 (目标 M7 完成后)"]
        S1["✅ S1-1 专业审计 (M7.6)\n✅ S1-4 私密转账 (M7.11)\n🆗 S1-2 HW钱包 (前端 SDK)\n🆗 S1-3 Helios (前端)\n🆗 S1-5 账户迁移 (已有)\n🆗 S1-8 ENS (前端)\n🆗 S1-9 EIP-1193 (前端)"]
    end

    subgraph STAGE2["Stage 2 解锁 (M7 完成 + 前端 App)"]
        S2["✅ S2-1 Bug Bounty (M7.7)\n✅ S2-3 OAPD 多地址防关联\n✅ S2-4 L2 force-exit (M7.5)\n✅ S2-8 ERC-7828 (M7.4)\n✅ S2-9 ERC-4337 (已有)\n✅ S2-10 批量交易 (已有)\n🆗 S2-7 手续费UI (前端)"]
    end

    M6 --> M7A
    M6 --> M7B
    M7A --> M7C
    M7B --> STAGE1
    M7A --> STAGE1
    M7C --> STAGE2
    STAGE1 --> STAGE2
```

---

## Diagram 6: ERC-7579 下 AirAccount 目标架构全景

M7 完成后的理想架构，展示所有模块的位置和关系：

```mermaid
flowchart TD
    subgraph OUTER["ERC-4337 基础设施"]
        EP2["EntryPoint v0.7"]
        BND2["Bundler (Pimlico)"]
        PM2["Paymaster (SuperPaymaster)"]
    end

    BND2 --> EP2
    PM2 --> EP2

    subgraph ACCOUNT["AirAccount Core (ERC-7579 兼容)"]
        direction TB

        VR["validateUserOp(userOp, hash)\n1. 从 nonce 提取 validatorId\n2. 检查 installedModules[validator][TYPE_1]\n3. 委托 validator.validateUserOp()"]

        EX2["execute(ModeCode, calldata) / executeBatch()\n1. preCheck() 所有 Hooks\n2. 解码 ModeCode 执行\n3. postCheck() 所有 Hooks (逆序)"]

        EFE3["executeFromExecutor(mode, data)\n1. 检查 installedModules[caller][TYPE_2]\n2. guard.checkExecutorTransaction() 日限额\n3. 执行目标调用"]

        INS3["installModule(typeId, module, data)\n默认: owner(40)+1 guardian(30)≥70 + 48h timelock\n可配置: threshold=40/70/100 (创建时设定)"]
    end

    EP2 -->|验证| VR
    EP2 -->|执行| EX2

    subgraph VCHAIN["Validator 模块链 (Type 1)"]
        direction LR
        VC1["ECDSA\nalgId=0x02\nsecp256k1"]
        VC2["P256\nalgId=0x03\nWebAuthn"]
        VC3["BLS\nalgId=0x01\n聚合签名"]
        VC4["SessionKey\nalgId=0x08\n时限委托"]
        VC5["AirAccountCompositeValidator ⭐\nalgId=0x04/0x05/0x07\nWeighted + Cumulative 合并\n内部按 algId 路由"]
    end

    VR --> VCHAIN

    subgraph HCHAIN["Hook 模块链 (Type 4) — 每次 execute 触发"]
        direction TB
        HC1["TierGuardHook ⭐\npreCheck: TLOAD algId\n→ 决定 T1/T2/T3\n→ call guard.checkTransaction()"]
        HC2["DailyLimitHook ⭐\npreCheck: 检查日限额\n→ guard.checkAndAccumulate()"]
        HC3["TokenLimitHook ⭐\npreCheck: parse calldata\n→ registry.parse() → 检查 token 额度"]
    end

    EX2 --> HCHAIN

    subgraph ECHAIN["Executor 模块 (Type 2) — 主动调用"]
        EC1["GuardianRecoveryExecutor\n2-of-3 + 48h timelock\n社会恢复"]
        EC2["WillExecutor ⭐ (M7.1)\nDVT oracle → 资产转移\n遗嘱执行"]
        EC3["AgentSessionExecutor ⭐ (M7.14)\n速率限制 + target 白名单\nAI Agent 委托"]
    end

    EFE3 <--> ECHAIN

    subgraph SHARED2["共享基础设施 (AirAccount 专有 ⭐)"]
        GRD2["AAStarGlobalGuard\n不可变花费守卫\n每账户唯一实例"]
        CPR2["CalldataParserRegistry\nRailgun / Uniswap / 通用解析"]
        TSTORE2["EIP-1153 Transient Storage\nalgId 跨阶段传递\nValidator写 → Hook读"]
    end

    HCHAIN --> GRD2
    HCHAIN --> CPR2
    VR -.->|TSTORE algId| TSTORE2
    HCHAIN -.->|TLOAD algId| TSTORE2

    subgraph EXT["ERC-7579 外 / AirAccount 专有 ⭐⭐"]
        DEL2["AirAccountDelegate\nEIP-7702 EOA桥接\nguardian rescue"]
        FAC2["Factory (EIP-1167 Clone)\nCREATE2 确定性地址\nOAPD salt 策略"]
        OAPD["OAPD 机制\nsalt=keccak256(owner+dappId)\n跨DApp地址隔离"]
    end
```

---

## AirAccount T1/T2/T3 在 ERC-7579 中的定级

| AirAccount 特性 | 7579 位置 | 定级 |
|----------------|-----------|------|
| ECDSA / P256 / BLS 验签 | Validator Module (Type 1) | ✅ **标准模块** — 完全符合 |
| SessionKeyValidator | Validator Module (Type 1) | ✅ **标准模块** — 几乎无需改动 |
| T1/T2/T3 Tier 策略 | Hook Module (Type 4) + TSTORE | 🟡 **7579 框架内自定义** — Hook 是标准接口，tier 逻辑是自定义 |
| 日限额守卫 (AAStarGlobalGuard) | Hook Module (Type 4) | 🟡 **7579 框架内自定义** — 标准 Hook 接口实现花费策略 |
| 加权签名 (Weighted) | Validator Module (Type 1) | 🟡 **7579 框架内自定义** — Validator 模块可实现任意验签逻辑 |
| 累积签名 (Cumulative T2/T3) | Validator Module (Type 1) | 🟡 **7579 框架内自定义** — 多签聚合验证器 |
| 社会恢复 (Guardian 2-of-3) | Executor Module (Type 2) | 🟡 **7579 框架内自定义** — 标准 Executor 接口 |
| algId → tier 信号传递 | Transient Storage (EIP-1153) | 🟡 **7579 框架内自定义** — 利用 Cancun 瞬态存储 |
| EIP-7702 EOA 桥接 | 无对应模块类型 | 🔴 **7579 框架外** — AirAccount 独有，独立维护 |
| OAPD 多DApp地址隔离 | Factory 层（非模块） | 🔴 **7579 框架外** — 部署策略，7579 无此概念 |
| CalldataParserRegistry | Hook 的依赖服务 | 🔴 **7579 框架外** — AirAccount 基础设施，不是模块 |
| WillExecutor (DVT遗嘱) | Executor Module (Type 2) | 🟡 **7579 框架内自定义** — 标准 Executor 接口，业务逻辑是自定义 |

**结论**：AirAccount 的核心创新（T1/T2/T3 tier、weighted/cumulative 签名、OAPD、EIP-7702）都是在 ERC-7579 的合法自定义空间内，或独立于 7579 体系之外。**没有一个特性需要违反 7579 标准**，只是 7579 刻意留空、由实现者填充的部分。

---

## 架构演进行动计划

### Phase A：7579 写接口（M7.2，~3周）

```
当前 (M6)                          目标 (M7.2)
─────────────────────────         ─────────────────────────
AAStarAirAccountBase               AAStarAirAccountBase
  execute()                          validateUserOp() → 路由到 Validator 模块
    → _enforceGuard()                execute() → preCheck Hooks → call → postCheck
  validateUserOp()                   executeFromExecutor() → checkExecutorTx()
    → AAStarValidator (外部)         installModule() (guardian gate + timelock)

AAStarGlobalGuard (外部合约)       TierGuardHook (ERC-7579 Hook 模块)
  checkTransaction(algId)            preCheck() 读 TSTORE algId → 调用 Guard

AAStarValidator (外部合约)         ECDSAValidator / P256Validator (独立模块)
  大型 if-else 算法分发               各自独立 + TSTORE 写入 algId
```

**关键决策**：`AAStarGlobalGuard` 保留为独立合约（已部署、不可升级），但通过 `TierGuardHook` 模块来调用它。这样：
- Guard 的不可变性保留（安全保证）
- AirAccount 对外符合 7579 Hook 接口
- 现有已部署账户不受影响（向后兼容）

### Phase B：审计 + 生态（M7.6 + M7.7，外部依赖）

- 提交代码给 CodeHawks 竞争性审计（$15–20k 奖池）
- 审计范围包含 7579 新增的 installModule + executeFromExecutor 路径
- 审计通过后上线 Immunefi bug bounty

### Phase C：L2 + 生态扩展（M7.5 + M7.11–M7.16）

- 同一 CREATE2 salt → 跨链相同地址（Base / Arbitrum / OP）
- RailgunParser 注册 → 私密转账合规 guard
- Agent Session Key Module → AI Agent 经济基础设施

---

## 快速参考：ERC-7579 关键接口

```solidity
// 账户必须实现
interface IERC7579Account {
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external payable returns (bytes[] memory returnData);
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external payable;
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external payable;
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external view returns (bool);
    function accountId() external view returns (string memory);
    function supportsExecutionMode(bytes32 encodedMode) external view returns (bool);
    function supportsModule(uint256 moduleTypeId) external view returns (bool);
}

// Validator 模块
interface IERC7579Validator {
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external returns (uint256 validationData);
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external view returns (bytes4 magicValue);
}

// Hook 模块
interface IERC7579Hook {
    function preCheck(address msgSender, uint256 value, bytes calldata msgData)
        external returns (bytes memory hookData);
    function postCheck(bytes calldata hookData) external;
}

// 所有模块基类
interface IERC7579Module {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function isModuleType(uint256 typeID) external view returns (bool);
}

// ModeCode 模块类型常量
uint256 constant MODULE_TYPE_VALIDATOR = 1;
uint256 constant MODULE_TYPE_EXECUTOR  = 2;
uint256 constant MODULE_TYPE_FALLBACK  = 3;
uint256 constant MODULE_TYPE_HOOK      = 4;

// ModeCode callType 常量
bytes1 constant CALLTYPE_SINGLE      = 0x00;
bytes1 constant CALLTYPE_BATCH       = 0x01;
bytes1 constant CALLTYPE_STATICCALL  = 0xFE;
bytes1 constant CALLTYPE_DELEGATECALL = 0xFF;
```

---

## 架构决策确认版 (2026-03-21 Review)

以下三图是经过充分讨论后的确认版架构，作为 M7.2 实现依据。

---

### 确认图A：模块全景 — 出厂预装 vs 可选安装

```mermaid
flowchart TD
    subgraph FACTORY["Factory.initialize() — 出厂预装，零用户感知"]
        direction LR
        subgraph V["Validator 模块 (Type 1) — 全部 7579 标准接口"]
            V1["ECDSAValidator\nalgId=0x02"]
            V2["P256Validator\nalgId=0x03"]
            V3["BLSValidator\nalgId=0x01"]
            V4["SessionKeyValidator\nalgId=0x08"]
            V5["AirAccountCompositeValidator ⭐\nalgId=0x04/0x05/0x07\n内部按algId路由\nWeighted + Cumulative"]
        end
        subgraph H["Hook 模块 (Type 4) — 全部 7579 标准接口"]
            H1["TierGuardHook ⭐\npreCheck: TLOAD algId\n→ T1/T2/T3 决策\n→ guard.checkTransaction()"]
            H2["DailyLimitHook ⭐\n日限额强制"]
            H3["TokenLimitHook ⭐\n→ CalldataParserRegistry\nERC-20 额度"]
        end
        subgraph E["Executor 模块 (Type 2)"]
            E1["GuardianRecoveryExecutor ⭐\n2-of-3 社会恢复"]
        end
    end

    subgraph OPTIONAL["可选安装 — owner+1guardian≥70 + 48h (默认门槛，可配置)"]
        O1["WillExecutor ⭐ (M7.1)"]
        O2["AgentSessionExecutor ⭐ (M7.14)"]
        O3["RailgunExecutor (M7.11)"]
        O4["第三方 7579 模块 (Rhinestone生态)"]
    end

    subgraph UNINSTALL["卸载门槛 — guardian 2-of-3 + 48h"]
        U1["TierGuardHook / DailyLimitHook\n⚠️ require: '卸载后账户失去花费限制'"]
        U2["AirAccountCompositeValidator\n⚠️ require: '卸载后T2/T3失效，大额交易将被block'"]
        U3["其他 Validator 模块\n⚠️ 对应签名方式失效"]
    end

    FACTORY --> OPTIONAL
    FACTORY --> UNINSTALL

    style V5 fill:#fff3cd,stroke:#ffc107
    style H1 fill:#fff3cd,stroke:#ffc107
    style H2 fill:#fff3cd,stroke:#ffc107
    style H3 fill:#fff3cd,stroke:#ffc107
    style U1 fill:#f8d7da,stroke:#dc3545
    style U2 fill:#f8d7da,stroke:#dc3545
```

> ⭐ = AirAccount 特有业务逻辑，接口符合 7579 标准（IValidator / IHook / IExecutor）

---

### 确认图B：UserOp 执行全链路 — algId 信号流

```mermaid
sequenceDiagram
    participant USER as 用户/设备
    participant BND as Bundler
    participant EP as EntryPoint
    participant ACC as AirAccount Core
    participant VM as Validator 模块
    participant TS as TSTORE (EIP-1153)
    participant HK as TierGuardHook
    participant GRD as AAStarGlobalGuard

    USER->>BND: UserOp\nnonce高位=validatorId (选哪个模块)\nsignature首字节=algId (模块内走哪条路)

    rect rgb(220, 240, 255)
        Note over EP,TS: 验证阶段
        EP->>ACC: validateUserOp(userOp, hash)
        ACC->>ACC: nonce >> 64 = validatorId
        ACC->>ACC: 检查 installedModules[validatorId][TYPE_1]
        ACC->>VM: validator.validateUserOp(userOp, hash)
        VM->>VM: 从 signature[0] 读 algId，执行对应验签
        VM->>TS: TSTORE(keccak256(account,"algId"), algId)
        VM-->>ACC: 0 = valid
        ACC-->>EP: validationData
    end

    rect rgb(220, 255, 220)
        Note over EP,GRD: 执行阶段
        EP->>ACC: execute(ModeCode, calldata)
        ACC->>HK: preCheck(sender, value, calldata)
        HK->>TS: TLOAD → algId
        HK->>HK: T1: algId=0x02, value≤$100\nT2: algId=0x04, value≤$1000\nT3: algId=0x05/0x07, any
        HK->>GRD: checkTransaction(dest, value, algId)
        GRD-->>HK: ✅ / ❌ TierViolation
        HK-->>ACC: hookData
        ACC->>ACC: 执行 target call
        ACC->>HK: postCheck(hookData)
    end
```

---

### 确认图C：权限矩阵

```mermaid
flowchart LR
    subgraph OPS["操作"]
        A1["日常交易\nexecute()"]
        A2["Session Key 使用"]
        A3["安装新模块\ninstallModule()"]
        A4["卸载模块\nuninstallModule()"]
        A5["社会恢复\n更换 owner"]
        A6["出厂预装\ninitialize()"]
        A7["修改 installThreshold"]
    end

    subgraph SIGS["所需签名"]
        S1["owner 单签\nweight=40"]
        S2["owner(40) + 1guardian(30) ≥70\n+ 48h timelock\n默认门槛，可配置为 40 或 100"]
        S3["guardian 2-of-3\n+ 48h timelock"]
        S4["session key\n时限+范围限定"]
        S5["factory 部署时内置\n零用户感知"]
    end

    A1 --> S1
    A2 --> S4
    A3 --> S2
    A4 --> S3
    A5 --> S3
    A6 --> S5
    A7 --> S3

    style S2 fill:#d4edda,stroke:#28a745
    style S3 fill:#fff3cd,stroke:#ffc107
    style S1 fill:#cce5ff,stroke:#004085
```

---

### 确认决策表

| 决策点 | 结论 | 依据 |
|--------|------|------|
| algId 跨阶段传递 | nonce高位选validator + TSTORE传algId（两者配合，非替代） | TSTORE ~200gas，零持久存储，Cancun已支持 |
| Validator 拆分 | ECDSA/P256/BLS/Session 独立 + Weighted+Cumulative 合并为 AirAccountCompositeValidator | 拆分粒度合理，CompositeValidator 内部按algId路由不违反7579 |
| CompositeValidator 卸载 | 允许（guardian 2-of-3），合约内 require 提示后果 | safe-fail：卸载后大额tx被block，不产生安全漏洞 |
| installModule 门槛 | 默认 owner+1guardian≥70 + 48h，可在创建时配置为 40/70/100 | 主流（Kernel/Nexus）单签即可；AirAccount 加一道人工防线；普通用户永不触碰 |
| uninstallModule 门槛 | guardian 2-of-3 + 48h（与社会恢复同等重量） | 卸载安全模块的风险高于安装 |
| TierGuardHook 安全性 | 不可被 owner 单签卸载，guardian 2-of-3 才能卸载 | 日限额是最后安全底线 |
| ★ 标注含义澄清 | 所有模块均符合 7579 接口标准；⭐ 仅表示"AirAccount 特有业务逻辑" | 7579 只规定接口，不限制内部逻辑 |

---

## 参考资料

- [ERC-7579 官方规范](https://eips.ethereum.org/EIPS/eip-7579)
- [Rhinestone ModuleKit](https://github.com/rhinestonewtf/modulekit)
- [Rhinestone Core Modules](https://github.com/rhinestonewtf/core-modules)
- [ZeroDev Kernel v3](https://github.com/zerodevapp/kernel)
- [Biconomy Nexus](https://github.com/bcnmy/nexus)
- [ERC-7579 参考实现](https://github.com/erc7579/erc7579-implementation)
- [ERC-7484 模块注册表](https://eips.ethereum.org/EIPS/eip-7484)
- [EIP-1153 瞬态存储](https://eips.ethereum.org/EIPS/eip-1153)
