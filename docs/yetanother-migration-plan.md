# YetAnotherAA-Validator Migration Plan

## 目标

将 [YetAnotherAA-Validator](https://github.com/fanhousanbu/YetAnotherAA-Validator) 作为子模块集成进 airaccount-contract，先在 Sepolia 完成部署和基础测试，再部署到 Optimism 主网，最终与主分支融合。

**只部署 V7 版本**（EntryPoint v0.7：`0x0000000071727De22E5E9d8BAf0edAc6f37da032`）

---

## 合约架构

| 合约 | 说明 |
|------|------|
| `AAStarValidator.sol` | BLS 签名验证合约，所有版本共用；使用 EIP-2537 预编译（G1Add `0x0B`、Pairing `0x0F`） |
| `AAStarAccountFactoryV7.sol` | EntryPoint v0.7 工厂合约，CREATE2 确定性部署，输出 `AASTAR_ACCOUNT_FACTORY_ADDRESS` |
| `AAStarAccountV7.sol` | 账户实现合约，通过 ERC1967Proxy 代理模式部署 |
| `AAStarAccountBase.sol` | 抽象基类，包含三重签名验证逻辑 |

### 三重签名安全模型

```
UserOp.signature =
  [nodeIdsLength (32 bytes)]
  [nodeIds... (32 bytes each)]
  [BLS signature - G2 point (256 bytes)]
  [messagePoint - G2 point (256 bytes)]
  [ECDSA signature from signer (65 bytes)]
  [messagePoint ECDSA signature from signer (65 bytes)]
```

验证流程：
1. ECDSA 验证 `userOpHash`（账户 owner 签名）
2. ECDSA 验证 `messagePoint`（账户 owner 签名）
3. BLS 通过 `AAStarValidator` 验证 `messagePoint`（多节点聚合签名）

---

## 关键产出变量

- `VALIDATOR_CONTRACT_ADDRESS` — 一个 validator 实例可被所有账户版本共享
- `AASTAR_ACCOUNT_FACTORY_ADDRESS` — 工厂合约地址，用于创建用户 AA 账户
- `AASTAR_ACCOUNT_IMPLEMENTATION_ADDRESS` — 账户实现合约地址（代理目标）

---

## 阶段一：Sepolia 部署

### 配置

- **RPC**: `https://eth-sepolia.g.alchemy.com/v2/9bwo2HaiHpUXnDS-rohIK`
- **部署私钥**: `.env.sepolia` 中的 `PRIVATE_KEY`（Jason EOA: `0xb5600060e6de5E11D3636731964218E53caadf0E`）
- **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- **Etherscan API Key**: `.env.sepolia` 中的 `ETHERSCAN_API_KEY`

### 步骤

```bash
cd lib/YetAnotherAA-Validator/contracts

# 1. 安装依赖
forge install

# 2. 编译合约
forge build

# 3. 本地测试通过
forge test -vvv

# 4. 部署到 Sepolia（含合约验证）
forge script script/DeployAAStarV7.s.sol:DeployAAStarV7System \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/9bwo2HaiHpUXnDS-rohIK \
  --private-key 0x1b9c251d318c3c8576b96beddfdc4ec2ffbff762d70325787bde31559db83a21 \
  --broadcast \
  --verify \
  --etherscan-api-key MZD22FX482CHDAN2NIVP5Q6V6B4Y3WFKSS
```

### 预期输出

```
VALIDATOR_CONTRACT_ADDRESS=    0x...
AASTAR_ACCOUNT_FACTORY_ADDRESS= 0x...
AASTAR_ACCOUNT_IMPLEMENTATION_ADDRESS= 0x...
ENTRY_POINT_ADDRESS= 0x0000000071727De22E5E9d8BAf0edAc6f37da032
```

---

## 阶段二：Sepolia 基础测试

```bash
# 设置变量
export SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/9bwo2HaiHpUXnDS-rohIK
export FACTORY=<AASTAR_ACCOUNT_FACTORY_ADDRESS>
export VALIDATOR=<VALIDATOR_CONTRACT_ADDRESS>
export CREATOR=0xb5600060e6de5E11D3636731964218E53caadf0E
export SIGNER=0xb5600060e6de5E11D3636731964218E53caadf0E

# 测试 1: 预计算账户地址（counterfactual）
cast call $FACTORY \
  "getAddress(address,address,address,bool,uint256)(address)" \
  $CREATOR $SIGNER $VALIDATOR true 0 \
  --rpc-url $SEPOLIA_RPC

# 测试 2: 创建账户
cast send $FACTORY \
  "createAccount(address,address,address,bool,uint256)" \
  $CREATOR $SIGNER $VALIDATOR true 0 \
  --private-key 0x1b9c251d318c3c8576b96beddfdc4ec2ffbff762d70325787bde31559db83a21 \
  --rpc-url $SEPOLIA_RPC

# 测试 3: 查询已注册节点数
cast call $VALIDATOR \
  "getRegisteredNodeCount()(uint256)" \
  --rpc-url $SEPOLIA_RPC

# 测试 4: 注册 BLS 公钥（用 REGISTER_KEYS=true 重跑部署脚本）
EXISTING_VALIDATOR=$VALIDATOR REGISTER_KEYS=true \
forge script script/DeployAAStarV7.s.sol:DeployAAStarV7System \
  --rpc-url $SEPOLIA_RPC \
  --private-key 0x1b9c251d318c3c8576b96beddfdc4ec2ffbff762d70325787bde31559db83a21 \
  --broadcast
```

---

## 阶段三：Optimism 主网部署

### 配置

- **RPC**: `https://opt-mainnet.g.alchemy.com/v2/4Cp8njSeL62sQANuWObBv`
- **部署账户**: `cast wallet`，账户名 `optimism-deployer`（需手动输入密码）
- **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`（与 Sepolia 相同）

### 步骤

```bash
cd lib/YetAnotherAA-Validator/contracts

# 获取 deployer 地址（用于 --sender 参数）
cast wallet address --account optimism-deployer

# 部署到 Optimism 主网
forge script script/DeployAAStarV7.s.sol:DeployAAStarV7System \
  --rpc-url https://opt-mainnet.g.alchemy.com/v2/4Cp8njSeL62sQANuWObBv \
  --account optimism-deployer \
  --sender <DEPLOYER_ADDRESS> \
  --broadcast \
  --verify \
  --etherscan-api-key MZD22FX482CHDAN2NIVP5Q6V6B4Y3WFKSS
```

> 执行时需手动输入 keystore 密码。

---

## 阶段四：与主分支融合策略

1. **AAStarValidator** 作为独立 validator 模块，实现 `kernel` 的 `IValidator` 接口
2. **AAStarAccountBase** 的三重签名逻辑扩展到 `simple-team-account` 的签名方案
3. 工厂合约保持独立，不与其他子模块耦合
4. 将部署地址同步到 `.env.sepolia` 和 `.env.optimism`

### 需要新增的环境变量

```bash
# Sepolia
VALIDATOR_CONTRACT_ADDRESS=0x...
AASTAR_ACCOUNT_FACTORY_ADDRESS=0x...

# Optimism
VALIDATOR_CONTRACT_ADDRESS_OPTIMISM=0x...
AASTAR_ACCOUNT_FACTORY_ADDRESS_OPTIMISM=0x...
```

---

## Sepolia 已部署地址（2026-03-09）

| 变量 | 地址 |
|------|------|
| `VALIDATOR_CONTRACT_ADDRESS` | `0xF780Cc3FB161F8df8C076f86E89CE8B685985395` |
| `AASTAR_ACCOUNT_FACTORY_ADDRESS` | `0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31` |
| `AASTAR_ACCOUNT_IMPLEMENTATION_ADDRESS` | `0xab7d9A8Ab9e835c5C7D82829E32C10868558E0F8` |
| `ENTRY_POINT_V7` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

> **注意**：Alchemy 对 EIP-7702 委托账户有单次广播限制，需要通过公共 RPC（如 sepolia.drpc.org）或分次部署绕过。

## 进度跟踪

- [x] 阶段一：子模块添加
- [x] 阶段一：Foundry 依赖安装 & 编译（59/59 tests pass）
- [x] 阶段一：本地测试通过
- [x] 阶段一：Sepolia 部署完成
- [x] 阶段二：Sepolia 基础测试通过
- [ ] 阶段三：Optimism 主网部署完成
- [ ] 阶段四：主分支融合

---

*最后更新：2026-03-09*
