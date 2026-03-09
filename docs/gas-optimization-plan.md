# AAStarValidator Gas 优化方案

> 关联文档：[统一架构设计](./airaccount-unified-architecture.md) | [Validator 升级与 PQ 迁移分析](./validator-upgrade-pq-analysis.md)

## 现状分析

### 实测数据（Sepolia，2026-03-09）

**Tx**: [0x2d9e84...](https://sepolia.etherscan.io/tx/0x2d9e841d46d8090e065943b88a46c2c9be0a09ccd5ec3ff99b336ae2cb8bd173)

### 全链路 Gas 拆解（debug_traceTransaction 精确数据）

数据来源：`cast rpc debug_traceTransaction` callTracer

```
EntryPoint.handleOps()                                    523,306 gas (100%)
├─ EntryPoint 框架（调度、验证、会计）                         68,688 gas (13.1%)
├─ validateUserOp 全流程                                   437,894 gas (83.7%)
│  ├─ ERC1967 Proxy DELEGATECALL 开销                       5,075 gas  (1.0%)
│  ├─ SELF-CALL try/catch 开销                              5,822 gas  (1.1%)
│  ├─ ECDSA ecrecover × 2（预编译 0x01）                      6,000 gas  (1.1%)
│  └─ AAStarValidator.verifyAggregateSignature()          407,730 gas (77.9%) ← 瓶颈
│     ├─ G1Add 预编译（0x0B，聚合 2 公钥）                       375 gas  (0.1%)
│     ├─ Pairing 预编译（0x0F，k=2 配对）                   102,900 gas (19.7%)
│     └─ Validator EVM 开销                               304,455 gas (58.2%) ← 真正的问题
├─ execute（0.001 ETH 转账）                                 16,669 gas  (3.2%)
└─ Bundler gas 退款                                             55 gas  (0.0%)
```

### 407,730 gas 的 Validator 调用到底贵在哪？

| 组件 | Gas | 占 Validator 比 | 可优化？ | 说明 |
|------|-----|-----------------|---------|------|
| **Pairing 预编译** | 102,900 | 25.2% | **不可压缩** | EIP-2537 硬编码价格 `32600×k + 37700`，k=2 |
| **Solidity 逐字节拷贝** | ~150,000 | 36.8% | **可大幅优化** | `_buildPairingDataFromComponents` 用 `for` 循环逐字节拷贝 768B，`_negateG1Point` 逐字节拷贝 128B + 逐字节检查 128B。**总计 ~1024 次循环迭代，每次 ~100-150 gas**（含 Solidity 数组边界检查） |
| **Storage 冷读取** | ~25,200 | 6.2% | **可优化** | 2 个 128B 公钥 = 12× SLOAD（每次 2,100 gas 冷访问）：每个公钥跨 4 个 storage slot + 1 个 length slot + 1 个 isRegistered |
| **ABI 编解码** | ~10,000 | 2.5% | 部分可优化 | 772B calldata 解析 + `bytes32[]`、`bytes` 解码 |
| **Event 日志** | ~5,000 | 1.2% | **可消除** | `SignatureValidated` emit（改用 view 函数可省掉） |
| **其他 EVM** | ~114,255 | 28.0% | 部分可优化 | 内存扩展、keccak256、require 检查、函数调度、memory 分配 |
| **G1Add 预编译** | 375 | 0.1% | 不可压缩 | 预编译固定价格 |

> **关键发现**：Pairing 预编译本身只占 Validator gas 的 25.2%。真正的瓶颈是 **Solidity EVM 开销（304,455 gas = 74.7%）**，其中逐字节内存拷贝和 cold SLOAD 占大头。这意味着即使不做批量验证，单纯优化合约代码就能省下 ~200k gas。

### 核心问题

1. **Validator EVM 开销（304k）是 Pairing 预编译（103k）的 3 倍** — 合约实现效率极低
2. **每笔 UserOp 独立做一次完整 pairing** — 无法分摊固定开销
3. **外部 CALL 链过深**：EntryPoint → Proxy → DELEGATECALL → SELF-CALL → Validator CALL — 每层都有开销

---

## 优化目标

| 指标 | 当前 | 目标 |
|------|------|------|
| 单笔 UserOp 验证 gas | 523,306 | ≤ 150,000（批量摊薄后） |
| BLS 验证 gas | 403,485 | ≤ 50,000（批量摊薄后） |

---

## 方案一：ERC-4337 IAggregator 批量验证（核心方案，最高优先级）

### 原理

ERC-4337 EntryPoint v0.7 原生支持 `handleAggregatedOps`，专为 BLS 设计：

```
当前（每笔独立验证）:
  UserOp₁ → pairing(102,900) + overhead
  UserOp₂ → pairing(102,900) + overhead
  UserOp₃ → pairing(102,900) + overhead
  Total BLS = 3 × 403,485 = 1,210,455 gas

IAggregator（批量验证）:
  UserOp₁₂₃ → 1 次 pairing(102,900) + 3×G1Add(500) + overhead
  Total BLS ≈ 130,000 gas  →  per UserOp ≈ 43,333 gas
```

### 实现

需实现 ERC-4337 的 `IAggregator` 接口：

```solidity
interface IAggregator {
    /// 验证单个 UserOp 的签名格式（不做 pairing，只做基础检查）
    function validateUserOpSignature(
        PackedUserOperation calldata userOp
    ) external view returns (bytes memory sigForAggregation);

    /// 链下：聚合 N 个 UserOp 的签名为 1 个
    function aggregateSignatures(
        PackedUserOperation[] calldata userOps
    ) external view returns (bytes memory aggregatedSig);

    /// 链上：用 1 次 pairing 验证 N 个 UserOp
    function validateSignatures(
        PackedUserOperation[] calldata userOps,
        bytes calldata signature
    ) external view;
}
```

### Gas 估算（批量 3 笔 UserOp）

| 操作 | Gas | 说明 |
|------|-----|------|
| 1× Pairing 预编译 | 102,900 | 只做一次，N 笔共享 |
| N× G1Add（公钥聚合） | 1,500 | 3 个 UserOp，每个 2 nodes |
| N× Storage 读取 | 12,600 | 3 × 2 × 2,100 |
| 内存操作 + 其他 | ~20,000 | 用 assembly 优化后 |
| **BLS 总计** | **~137,000** | — |
| **摊薄到每笔 UserOp** | **~45,667** | 比当前 403,485 降低 **88.7%** |

**加上 ECDSA + EntryPoint + execute 等固有开销（~120k），每笔 UserOp 总计约 165,000 gas。**

### 当前方案 vs 方案一对比（批量 3 笔 UserOp）

| 对比维度 | 当前方案（逐笔验证） | 方案一（IAggregator 批量验证） | 变化 |
|----------|---------------------|-------------------------------|------|
| **Pairing 预编译调用次数** | 3 次（每笔 1 次） | **1 次**（N 笔共享） | -66.7% |
| **Pairing 总 Gas** | 308,700（3 × 102,900） | **102,900** | -66.7% |
| **G1Add 总 Gas** | 1,500（3 × 500） | 1,500（相同） | 0% |
| **Storage 读取总 Gas** | 12,600（3 × 2 × 2,100） | 12,600（相同） | 0% |
| **EVM 内存/计算开销** | ~450,000（3 × ~150,000） | **~20,000**（assembly 优化 + 共享） | -95.6% |
| **事件日志** | ~15,000（3 × ~5,000） | 0（view 函数，无 emit） | -100% |
| **ECDSA 验证** | 36,000（3 × 2 × 6,000） | 36,000（仍需逐笔） | 0% |
| **EntryPoint 框架** | 60,000（3 × ~20,000） | ~25,000（handleAggregatedOps 共享更多框架逻辑） | -58.3% |
| **execute 内部调用** | 90,000（3 × ~30,000） | 90,000（仍需逐笔执行） | 0% |
| | | | |
| **BLS 验证总 Gas（3 笔合计）** | **1,210,455** | **~137,000** | **-88.7%** |
| **3 笔 UserOp 完整总 Gas** | **1,569,918** | **~424,000** | **-73.0%** |
| **摊薄到每笔 UserOp** | **523,306** | **~141,333** | **-73.0%** |
| | | | |
| **L1 Mainnet 成本（30 gwei）** | ~$47 / 3笔 | ~$12.7 / 3笔 | **-$34.3** |
| **Optimism 成本（0.01 gwei）** | ~$0.016 / 3笔 | ~$0.004 / 3笔 | — |

> **关键洞察**：当前方案每笔 UserOp 要花 ~150,000 gas 在 Solidity 逐字节内存拷贝上（构建 768 字节 pairing 数据），这甚至超过了 pairing 预编译本身（102,900）。方案一通过 assembly 优化 + 批量共享，将这部分从 3 × 150k = 450k 压缩到 20k，是最大的单项收益。

### 落地要求

1. 新合约 `AAStarBLSAggregator.sol`（实现 `IAggregator`）
2. Bundler 端支持收集 BLS UserOps 并调用 `handleAggregatedOps`
3. AA 账户的 `validateUserOp` 返回 `aggregator` 地址（而非自行验证）
4. 最低批量要求：≥3 笔 UserOp 才触发批量路径

### 批量数量 vs Gas 摊薄

| 批量数 | BLS 总 Gas | 每笔摊薄 | 每笔总计（含其他） | 相比当前节省 |
|--------|-----------|---------|------------------|------------|
| 1 | 137,000 | 137,000 | 257,000 | 51% |
| 3 | 143,000 | 47,667 | 167,667 | **68%** |
| 5 | 149,000 | 29,800 | 149,800 | **71%** |
| 10 | 161,000 | 16,100 | 136,100 | **74%** |
| 20 | 185,000 | 9,250 | 129,250 | **75%** |

> 3 笔即可将 gas 压到 ~167k，满足 "十几万" 目标。

---

## 方案二：合约层字节码优化（中优先级）

即使不做批量验证，也可以从合约内部省下 ~150k gas。

### 2.1 用 assembly 替代逐字节内存拷贝

**当前问题**：`_buildPairingDataFromComponents` 用 Solidity `for` 循环逐字节拷贝 768 字节。

```solidity
// 当前代码 — 每字节一次 MSTORE8，768 次循环
for (uint256 i = 0; i < G1_POINT_LENGTH; i++) {
    pairingData[i] = GENERATOR_POINT[i];
}
```

**优化后**：用 `mstore` 一次拷贝 32 字节。

```solidity
// 优化 — 24 次 mstore 替代 768 次 MSTORE8
assembly {
    let src := add(GENERATOR_POINT, 0x20)
    let dst := add(pairingData, 0x20)
    for { let i := 0 } lt(i, 128) { i := add(i, 32) } {
        mstore(add(dst, i), mload(add(src, i)))
    }
    // ... signature and messagePoint similar
}
```

**预估节省**：~80,000–120,000 gas（约占当前 BLS 验证的 20-30%）

### 2.2 用 `validateAggregateSignature`（view）替代 `verifyAggregateSignature`（state-changing）

**当前问题**：`AAStarAccountBase._parseAndValidateAAStarSignature` 调用 `verifyAggregateSignature`，它 emit 事件。

```solidity
// 当前 — 消耗额外 ~5,000 gas 用于日志
return aaStarValidator.verifyAggregateSignature(nodeIds, blsSignature, messagePoint);
```

**优化后**：

```solidity
// 改用 view 函数，不 emit 事件
return aaStarValidator.validateAggregateSignature(nodeIds, blsSignature, messagePoint);
```

**前提**：`_parseAndValidateAAStarSignature` 也需改为 `view`。当前它是 `external` 非 view（因为调用了 state-changing 的 `verifyAggregateSignature`）。

**预估节省**：~5,000–8,000 gas

### 2.3 缓存聚合公钥

**当前问题**：每次验证都从 storage 读取 N 个公钥，然后做 G1Add 聚合。

**优化**：节点集合变化时预计算并缓存聚合公钥。

```solidity
// 新增 storage
bytes public cachedAggregatedKey;
bytes32 public cachedKeySetHash; // keccak256(sorted nodeIds)

function getCachedAggregatedKey(bytes32[] calldata nodeIds) internal view returns (bytes memory) {
    bytes32 setHash = keccak256(abi.encodePacked(nodeIds));
    if (setHash == cachedKeySetHash) {
        return cachedAggregatedKey; // 1× SLOAD，省掉 N× SLOAD + (N-1)× G1Add
    }
    // fallback: 逐个读取并聚合
    ...
}
```

**预估节省**：(N-1)×500 + N×2,100 = 2 nodes 时省 ~2,600；10 nodes 时省 ~25,500

### 方案二综合效果

| 优化项 | 节省 Gas |
|--------|---------|
| Assembly 内存拷贝 | ~100,000 |
| view 替代 verify | ~6,000 |
| 缓存聚合公钥（2 nodes） | ~2,600 |
| **合计** | **~108,600** |
| **优化后单笔 UserOp 总计** | **~415,000** |

> 单独用方案二，523k → ~415k，仍无法达到 "十几万" 目标。必须与方案一结合。

---

## 方案三：L2 部署策略（已规划）

### Optimism 上的 Gas 成本

Optimism 的 gas 结构：

| 成本组成 | L1 (Sepolia/Mainnet) | Optimism |
|----------|---------------------|----------|
| Execution gas price | 1-30 gwei | 0.001-0.01 gwei |
| 523k gas 的 USD 成本 | $5-15 (主网) | **$0.005-0.05** |
| 523k gas 的 ETH 成本 | 0.000523-0.0157 ETH | **0.000000523 ETH** |

> 在 Optimism 上，即使不做任何优化，523k gas 的实际成本也只有 L1 的 1/100 ~ 1/1000。

### 但仍需优化的原因

1. Optimism 的 calldata/blob 费用仍然与 L1 相关
2. 738 字节的签名数据在 L1 data posting 中仍然贵
3. 批量验证可以同时减少 calldata（共享 BLS 聚合签名）

---

## 方案四：签名结构精简（低优先级）

### 当前签名 738 字节（2 nodes）

```
[nodeCount: 32][nodeIds: 64][blsSig: 256][messagePoint: 256][aaSig: 65][mpSig: 65]
= 738 bytes
```

### 优化方向

| 优化 | 节省 | 说明 |
|------|------|------|
| nodeCount 用 uint8 | 31 bytes | 节点数 ≤ 255 |
| nodeIds 用 uint16 索引 | 60 bytes（2 nodes） | 替代 bytes32，链上维护 index→nodeId 映射 |
| 去掉 messagePointSignature | 65 bytes | 如果 BLS 验证本身已覆盖 messagePoint 绑定 |
| **合计** | **~156 bytes** | 738 → 582 bytes |

> calldata 每非零字节 16 gas，每零字节 4 gas。节省 156 字节 ≈ 节省 ~2,000 gas（影响不大，但在 L2 上 calldata 占比更高）。

---

## 综合推荐路线

### Phase 1：合约层优化（2 周内）

目标：单笔 523k → ~415k

1. Assembly 替代 byte-by-byte 内存拷贝
2. `validateAggregateSignature`（view）替代 `verifyAggregateSignature`
3. 缓存聚合公钥
4. 部署到 Sepolia 测试验证

### Phase 2：IAggregator 批量验证（4-6 周）

目标：批量 3+ 笔时每笔 ≤ 150k

1. 实现 `AAStarBLSAggregator` 合约（`IAggregator` 接口）
2. 修改 `AAStarAccountV7.validateUserOp` 返回 aggregator 地址
3. Bundler 端集成（或使用 Pimlico/Candide 支持 aggregated ops 的 bundler）
4. E2E 测试：3 笔批量 UserOp

### Phase 3：Optimism 主网部署

目标：USD 成本 < $0.01/tx

1. Phase 1+2 优化后的合约部署到 Optimism
2. 实测 gas 和 USD 成本

---

## 风险评估

| 风险 | 影响 | 缓解 |
|------|------|------|
| IAggregator 要求 bundler 支持 aggregated ops | 高 | 已有 bundler（如 Stackup）支持，或自建 bundler |
| EIP-2537 pairing 预编译成本是固定的，无法进一步压缩 | 中 | 批量摊薄是唯一办法 |
| 缓存聚合公钥增加 storage 复杂度 | 低 | 增量式更新，不影响现有逻辑 |
| Optimism 上 EIP-2537 预编译可用性 | 中 | 需确认 OP Stack 是否已支持 EIP-2537 |

---

## 结论

**单独的合约优化（方案二）只能将 523k 降到 ~415k，远不够。要达到 "十几万" 的目标，必须走 ERC-4337 IAggregator 批量验证（方案一）。**

批量 3 笔 UserOp 即可将每笔 gas 压到 ~167k（含 execute 等固有开销），批量 5 笔可压到 ~150k。

优先级排序：**方案一 > 方案五（集成重构）> 方案二 > 方案三 > 方案四**

---

## 方案五：将 YetAnotherAA 合约纳入 AirAccount 整体架构（架构级方案）

### 背景

当前 YetAnotherAA 的 `AAStarValidator`、`AAStarAccountV7`、`AAStarAccountFactoryV7` 是独立的合约体系。AirAccount 的整体架构设计（见 `docs/product_and_architecture_design.md`）是一个 **非升级、分层验证的 slim ERC-7579 账户**，参考了 4 个子模块（light-account、simple-team-account、kernel、YetAnotherAA）。

YetAnotherAA 当前的问题不只是 gas，还有**架构割裂**：

```
当前：独立体系，每个模块自成一套
  light-account    → 自己的账户 + 工厂
  simple-team-account → 自己的账户 + 工厂
  kernel           → 自己的账户 + 工厂 + 验证器插件体系
  YetAnotherAA     → 自己的账户 + 工厂 + BLS 验证器

目标：统一体系
  AirAccount（自研账户）
  └─ 插件化验证器
     ├─ P-256 Validator（WebAuthn passkey）
     ├─ K1 Validator（ECDSA EOA）
     ├─ BLS Validator（来自 YetAnotherAA，重写优化）
     └─ Future: PQ Validator
```

### 集成方案

#### 5.1 BLS Validator 作为独立验证器插件

**不用 YetAnotherAA 的账户和工厂**，只提取 BLS 验证核心逻辑，重写为 AirAccount 的验证器插件。

```solidity
// 新合约：src/validators/BLSValidator.sol
// 实现 AirAccount 的 IValidator 接口（参考 kernel 的 IValidator 或自定义）
contract BLSValidator is IValidator {
    // 从 AAStarValidator 提取的核心逻辑，但：
    // 1. 用 assembly 重写所有内存操作
    // 2. 缓存聚合公钥
    // 3. 实现 IAggregator 接口

    function validateSignature(
        bytes32 userOpHash,
        bytes calldata signature
    ) external view returns (uint256 validationData);
}
```

**优势**：
- 消除外部 CALL 开销（Validator 内联到账户合约中，省 ~10k gas）
- 不再需要 `AAStarAccountV7` 的 try/catch + SELF-CALL 模式（省 ~6k gas）
- 可以直接集成 IAggregator 批量验证

#### 5.2 统一工厂合约

**不用 `AAStarAccountFactoryV7`**，用 AirAccount 自己的工厂，支持创建时选择验证器组合。

```solidity
// 新合约：src/AirAccountFactory.sol
contract AirAccountFactory {
    function createAccount(
        address owner,
        ValidatorConfig[] calldata validators, // 可配置多个验证器
        uint256 salt
    ) external returns (address account);
}

// ValidatorConfig 示例
struct ValidatorConfig {
    address validator;     // BLSValidator / P256Validator / K1Validator
    bytes initData;        // 验证器初始化数据（如 BLS nodeIds、P256 pubkey）
    uint256 threshold;     // 该验证器对应的金额阈值
}
```

#### 5.3 分层验证 + BLS 的融合

根据 `product_and_architecture_design.md` 的分层模型：

```
交易金额
    │
    ├─ Tier 1 (<$100)  → WebAuthn P-256 单签    ~30k gas
    │
    ├─ Tier 2 ($100-$1k) → P-256 + ECDSA 双因子  ~50k gas
    │
    └─ Tier 3 (>$1k)   → BLS 多节点聚合签名      ~150k gas (批量优化后)
                          + ECDSA 绑定签名
```

BLS 验证只在高价值交易（Tier 3）触发，大部分日常交易走便宜的 P-256/ECDSA 路径。这样**平均 gas 成本远低于 150k**。

#### 5.4 Gas 对比：集成重构 vs 当前架构

| 维度 | 当前 YetAnotherAA | 集成后 AirAccount |
|------|-------------------|------------------|
| **调用链深度** | EntryPoint → Proxy → DELEGATECALL → SELF-CALL → Validator CALL (5 层) | EntryPoint → Account → inline validator (3 层) |
| **CALL 开销** | ~17k (5,075 proxy + 5,822 self-call + ~6k external call) | ~5k (仅 proxy) |
| **BLS 验证** | 407,730 (未优化合约) | ~130,000 (assembly + 缓存 + view) |
| **ECDSA × 2** | 6,000 | 6,000（不变） |
| **Tier 1 交易** | 不支持（全走 BLS） | ~30,000（P-256 passkey） |
| **Tier 3 交易（单笔）** | 523,306 | ~200,000 |
| **Tier 3 交易（3笔批量）** | 1,569,918 | ~450,000（每笔 ~150k） |

#### 5.5 从 YetAnotherAA 提取的核心资产

| 提取 | 不提取 | 说明 |
|------|--------|------|
| BLS pairing 验证逻辑 | AAStarAccountV6/V7/V8 | 用 AirAccount 自己的账户合约 |
| G1 点聚合 + 取反 | AAStarAccountFactoryV6/V7/V8 | 用 AirAccount 统一工厂 |
| 公钥注册管理 | AAStarAccountBase | 三重签名逻辑重新设计，融入分层模型 |
| 签名格式解析 | NestJS Signer Service（保持独立） | BLS 签名服务继续作为独立微服务 |
| 节点管理（注册/撤销/批量） | — | 直接复用，改为 assembly 优化版本 |

#### 5.6 实施路线

```
Phase A（2 周）：提取 + 重写 BLS 验证核心
  ├─ 新建 src/validators/BLSValidator.sol
  ├─ Assembly 重写 _buildPairingData、_negateG1Point
  ├─ 缓存聚合公钥机制
  ├─ 单元测试（目标：单次验证 < 200k gas）
  └─ 部署到 Sepolia 对比测试

Phase B（3 周）：IAggregator + 统一工厂
  ├─ 新建 src/aggregator/BLSAggregator.sol（IAggregator 接口）
  ├─ 新建 src/AirAccountFactory.sol
  ├─ 批量验证 E2E 测试（目标：3笔批量每笔 < 150k）
  └─ Bundler 集成测试

Phase C（2 周）：分层验证集成
  ├─ P256Validator + K1Validator 实现
  ├─ GlobalGuard 金额路由
  ├─ 多验证器 E2E 测试
  └─ Optimism 部署
```

### 建议

**YetAnotherAA 的 BLS 验证逻辑是有价值的**，但它的账户和工厂体系不适合直接用于 AirAccount。推荐的路径是：

1. **保留 `lib/YetAnotherAA-Validator` 子模块作为参考**（不修改）
2. **在项目根目录新建 `src/` 目录**，创建 AirAccount 自己的合约体系
3. **从 `AAStarValidator.sol` 提取 BLS 核心逻辑**，用 assembly 重写，作为 `BLSValidator` 插件
4. **NestJS Signer Service 保持独立**，通过 API 提供 BLS 签名聚合
5. **统一工厂**，支持创建时配置验证器组合和分层阈值

这样 YetAnotherAA 的核心价值（BLS 验证 + 节点管理）被保留，但融入了 AirAccount 的分层安全模型，同时通过合约重写实现 gas 优化。

---

*基于链上实测数据 (Tx: 0x2d9e84...，Sepolia Block 10412972) + debug_traceTransaction callTracer，2026-03-09*
