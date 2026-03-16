# EIP-8130 / Native AA Upgrade Plan

> Status: Deferred — activate when Hegota fork EIP selection is confirmed (watch Q3 2026)
> Depends on: `docs/eip-8130-analysis.md` (background), EIP-8130 or EIP-8141 adoption

---

## 架构对齐现状

### 已对齐（零成本）

| AirAccount V7 | EIP-8130 对应 | 说明 |
|--------------|--------------|------|
| `algId` 签名路由 | verifier type 分发 | 设计理念完全一致 |
| `AAStarValidator` 可扩展算法注册 | Custom verifier 无许可部署 | 结构天然对齐 |
| CREATE2 确定性账户地址 | `effective_salt = keccak256(user_salt \|\| owners_commitment)` | 相同模式 |
| ERC-4337 2D Nonce | `nonce_key + nonce_sequence` | 原生对齐 |

### 部分对齐（需扩展）

| AirAccount V7 | EIP-8130 对应 | 差距 |
|--------------|--------------|------|
| 分层验证（Tier 1/2/3 金额阈值） | Owner scope 权限位 | Scope 是类型权限，非金额分级。分层验证需保留在合约层 |
| 社交恢复（guardian + 2天 timelock） | DELEGATE verifier + Account Lock | EIP-8130 无内置 threshold，guardian 逻辑需合约层保留 |

### 不覆盖（AirAccount 独有）

| AirAccount 特性 | 说明 |
|----------------|------|
| `AAStarGlobalGuard` 每日消费限额 | EIP-8130 Account Lock 是二元开关，非金额限制 |
| BLS 聚合器 (`AAStarBLSAggregator`) | EIP-8130 Custom verifier 支持，但无聚合层 |
| 单调配置强制 (monotonic guard config) | 协议层无对应 |

---

## 迁移步骤（激活后执行）

### Phase 1 — 适配层（不破坏现有合约，1-2周）

#### Step 1.1: Verifier 适配合约

将现有 `IAAStarAlgorithm` 包装为 EIP-8130 `IVerifier`，无需修改算法合约本身：

```solidity
// src/adapters/AirAccountVerifierAdapter.sol
interface IVerifier {
    function verify(bytes32 hash, bytes calldata data)
        external view returns (bytes32 ownerId);
}

contract AirAccountVerifierAdapter is IVerifier {
    IAAStarAlgorithm public immutable algorithm;
    uint8 public immutable algId;

    constructor(address _algorithm, uint8 _algId) {
        algorithm = IAAStarAlgorithm(_algorithm);
        algId = _algId;
    }

    function verify(bytes32 hash, bytes calldata data)
        external view returns (bytes32 ownerId)
    {
        // IAAStarAlgorithm.validate returns 0 on success, non-zero on failure
        uint256 result = algorithm.validate(hash, data);
        if (result != 0) return bytes32(0); // invalid

        // Extract ownerId from signature data based on algId
        return _extractOwnerId(data);
    }

    function _extractOwnerId(bytes calldata data) internal view returns (bytes32) {
        if (algId == 0x02) {
            // ECDSA: ownerId = bytes32(bytes20(recoveredAddress))
            address recovered = _ecrecoverFromData(data);
            return bytes32(bytes20(recovered));
        } else if (algId == 0x03 || algId == 0x05) {
            // P256 / P256+ECDSA: ownerId = keccak256(pubX || pubY)
            (bytes32 pubX, bytes32 pubY) = _extractP256PubKey(data);
            return keccak256(abi.encodePacked(pubX, pubY));
        } else if (algId == 0x01) {
            // BLS: ownerId = keccak256(nodeIds)
            return keccak256(data[:64]);
        }
        return bytes32(0);
    }
}
```

**部署**: 为每个已注册 algId 部署一个 adapter 实例，注册到 EIP-8130 Account Config Contract。

#### Step 1.2: ownerId 存储扩展

将 `owner` 从 `address`（20 bytes）扩展为 `bytes32`：

```solidity
// Before (AAStarAirAccountBase.sol)
address public owner;

// After
bytes32 public ownerId;        // keccak256 of pubkey or padded address
address public ownerVerifier;  // EIP-8130 verifier contract address
```

影响范围：
- `initialize()` — 计算 ownerId 而非直接存 address
- `_validateOwner()` — 对比 ownerId 而非 address
- `transferOwnership()` — 接受 `(bytes32 newOwnerId, address newVerifier)`
- E2E scripts — 更新 ownerId 计算逻辑

**注意**: 这是 breaking change，需要新合约版本（V8）+ 资产迁移脚本。

---

### Phase 2 — 社交恢复对齐（2-3周）

#### Step 2.1: Guardian 注册为 DELEGATE verifier

```solidity
// 当前: guardianAddresses[3] 直接存储 EOA 地址
// 目标: guardian 注册为 EIP-8130 DELEGATE verifier + CONFIG scope

struct Guardian {
    bytes32 ownerId;       // bytes32(bytes20(guardianAddress)) for EOA
    address verifier;      // K1 verifier for EOA, or custom
    uint8 scope;           // 0x08 = CONFIG scope only
}
```

#### Step 2.2: Recovery timelock 映射到 Account Lock

```
AirAccount 当前流程:
  proposeRecovery() → 48h timelock → executeRecovery()

EIP-8130 对齐流程:
  guardian calls applyConfigChange() → Account Lock activated
  → requestUnlock() with new owner → wait unlock_delay → unlock()
```

Threshold 逻辑（2-of-3）封装为自定义 verifier：

```solidity
contract ThresholdGuardianVerifier is IVerifier {
    uint8 public threshold;    // 2
    bytes32[] public guardianIds;

    function verify(bytes32 hash, bytes calldata data)
        external view returns (bytes32 ownerId)
    {
        // Parse multi-sig data: [[sig1, guardianId1], [sig2, guardianId2]]
        // Verify threshold-of-n guardian signatures
        // Return bytes32(0) if threshold not met
    }
}
```

---

### Phase 3 — 原生 AA 交易支持（依赖链升级，节点侧）

当 Hegota 上线后，账户可通过 `AA_TX_TYPE` 直接提交交易，无需 ERC-4337 Bundler：

```
AA_TX_TYPE || rlp([
    ...,
    calls: [[{to: target, data: calldata}]],
    payer: superPaymasterAddress,    // gasless 仍然可用
    sender_auth: verifier_type || ownerId_proof,
    payer_auth: paymaster_sig
])
```

**SuperPaymaster 影响**: payer 字段直接指向 SuperPaymaster，无需 paymasterAndData 72字节格式。需更新 Paymaster 接口。

**BLS 聚合**: EIP-8130 Custom verifier 可实现聚合，但需要 bundler 层面支持（与 F68 相同问题）。

---

## 不需要迁移的部分

| 特性 | 原因 |
|------|------|
| `AAStarGlobalGuard` 消费限额 | 协议层不覆盖，继续在合约层强制 |
| 分层验证 Tier 1/2/3 | 协议层 scope 是类型权限，金额分级是 AirAccount 差异化，保留 |
| 单调配置 (monotonic) | AirAccount 独有安全设计，无协议对应 |
| ERC-4337 兼容 | ERC-1271 回退路径确保迁移期内 UserOp 仍可用 |

---

## 触发条件与时间线

```
现在 (2026-03)     Q3 2026            Q4 2026 / 2027 H1
     │                │                      │
     │  观察期        │  决策点              │  执行期
     │  - 跟踪 Hegota │  - EIP 选型确定      │  - Phase 1: 适配层
     │  - 关注 8141   │  - 激活本 plan       │  - Phase 2: 社交恢复
     │  - 保持兼容    │  - 开始 Phase 1 设计  │  - Phase 3: 原生 AA TX
     │                │                      │
```

**观察期行动（零成本）**:
- 保持 `IAAStarAlgorithm` 接口稳定，不引入破坏性变更
- 新合约版本保留 CREATE2 + 确定性地址模式
- 跟踪 Ethereum Hegota upgrade EIP 选型公告

**激活触发器**（任一条件满足）:
1. Hegota 测试网上线且 EIP-8130 or EIP-8141 被确认采纳
2. 主要 wallet（MetaMask/Coinbase）宣布原生 AA 迁移路线图
3. EntryPoint v0.8 宣布 deprecation 时间表

---

## 参考

- `docs/eip-8130-analysis.md` — 完整架构对齐分析
- `docs/TODO.md` — `[M7+] EIP-8130 / Native AA compatibility layer`
- `src/core/AAStarAirAccountBase.sol` — 主要受影响合约
- `src/validators/AAStarValidator.sol` — verifier 注册逻辑
- [EIP-8130](https://eips.ethereum.org/EIPS/eip-8130) — Account Abstraction by Account Configuration
- [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) — Frame Transaction (竞争方案，采纳概率更高)
