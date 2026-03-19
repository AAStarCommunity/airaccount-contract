# AGENTS.md — AirAccount Smart Contract Project

This file provides essential context for AI coding agents working on the AirAccount smart contract repository.

---

## Project Overview

**AirAccount** is a non-upgradable ERC-4337 smart wallet designed for mobile-first crypto payments. It provides tiered security based on transaction value, social recovery via guardians, and gasless transactions via paymasters.

### Key Design Principles

- **Non-upgradable**: No proxy patterns (UUPS, etc.). New features require new contract versions.
- **Privacy-first**: Supports shielded pools and One-Account-Per-DApp (OAPD) isolation.
- **Tiered verification**: Small amounts use single-factor auth; larger amounts require multi-sig.
- **Global guards**: Immutable spending limits enforced at the contract level.
- **Social recovery**: 2-of-3 guardians can recover accounts via timelocked process.

---

## Technology Stack

| Component | Technology |
|-----------|------------|
| Language | Solidity ^0.8.33 |
| Build Tool | Foundry (forge) |
| Package Manager | pnpm |
| Testing | Foundry + Forge Std |
| Scripting | TypeScript (tsx), Viem |
| Cryptography | BLS12-381 (EIP-2537), P256 (EIP-7212), ECDSA |

> **Note:** All TypeScript scripts **must use viem only**. Ethers.js is not allowed in new code. The project is viem-only for all blockchain interactions.

### Compiler Configuration (foundry.toml)

```toml
solc_version = "0.8.33"
evm_version = "cancun"
via_ir = true
optimizer = true
optimizer_runs = 1_000
```

---

## Project Structure

```
├── src/                          # Main source contracts
│   ├── core/                     # Core account logic
│   │   ├── AAStarAirAccountV7.sol          # Main ERC-4337 account (EntryPoint v0.7)
│   │   ├── AAStarAirAccountBase.sol        # Base contract with validation/execution logic
│   │   ├── AAStarAirAccountFactoryV7.sol   # CREATE2 factory for account deployment
│   │   └── AAStarGlobalGuard.sol           # Spending limit guard (immutable)
│   ├── validators/               # Signature validation modules
│   │   ├── AAStarValidator.sol             # Algorithm router for external validators
│   │   └── AAStarBLSAlgorithm.sol          # BLS12-381 signature verification
│   ├── aggregator/               # ERC-4337 aggregator for batch operations
│   │   └── AAStarBLSAggregator.sol         # Batch BLS signature verification
│   └── interfaces/               # Contract interfaces
│       ├── IAAStarValidator.sol
│       └── IAAStarAlgorithm.sol
├── test/                         # Foundry test files (16 test suites)
├── script/                       # Deployment scripts
│   ├── DeployFullSystem.s.sol    # Full system deployment
│   └── DeployAirAccountV7.s.sol  # Account-only deployment
├── scripts/                      # TypeScript utility scripts (25+ scripts)
│   ├── deploy-m5.ts              # M5 milestone deployment
│   ├── test-e2e-*.ts             # E2E test scripts
│   └── onboard-*.ts              # User onboarding flows
├── lib/                          # Git submodules (17 dependencies)
│   ├── account-abstraction/      # ERC-4337 EntryPoint
│   ├── openzeppelin-contracts/   # OpenZeppelin libraries
│   ├── forge-std/                # Foundry standard library
│   ├── SuperPaymaster/           # Gasless transaction paymaster
│   └── ... (see .gitmodules for full list)
├── configs/                      # Configuration files
│   └── token-presets.json        # Per-chain token limit profiles
└── docs/                         # Documentation (27 markdown files)
```

---

## Build & Test Commands

### Build
```bash
forge build                    # Compile all contracts
forge build --sizes           # Check contract sizes
```

### Test
```bash
forge test                     # Run all tests
forge test -vvv               # Run with verbose output
forge test --gas-report       # Run with gas report
forge test --match-test <name> # Run specific test
forge test --match-path <file> # Run specific test file
```

### Coverage
```bash
forge coverage                # Generate coverage report
```

### Scripts
```bash
# Unit tests (wrapper script)
./test-unit.sh
./test-unit.sh -v             # Verbose
./test-unit.sh -m <testName>  # Match specific test

# E2E tests (requires .env.sepolia)
./test-e2e-bls.sh             # BLS signature E2E
./test-e2e-ecdsa.sh           # ECDSA signature E2E
```

---

## Deployment Commands

### Local/Anvil
```bash
anvil                          # Start local testnet
forge script script/DeployFullSystem.s.sol --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY --broadcast -vvvv
```

### Sepolia Testnet
```bash
# Via Foundry script
forge script script/DeployFullSystem.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vvvv

# Via TypeScript (M5 with token presets)
npx tsx scripts/deploy-m5.ts
```

---

## Code Style Guidelines

### Formatting
- 4-space indentation
- Braces on same line (K&R style)
- Maximum line length: 120 characters

### Naming Conventions
```solidity
// Interfaces prefixed with I
interface IAAStarValidator { }

// Private/internal functions prefixed with _
function _validateSignature(...) internal { }

// Constants: UPPER_SNAKE_CASE
uint256 internal constant ALG_BLS = 0x01;
address private constant G1ADD_PRECOMPILE = address(0x0b);

// Events: PascalCase with indexed params for addresses
event AccountCreated(address indexed account, address indexed owner, uint256 salt);

// Custom errors: PascalCase with descriptive names
error NotEntryPoint();
error GuardianDidNotAccept(address guardian);
```

### Import Style
```solidity
// Use named imports only
import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// No global imports
// Bad: import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
```

### Error Handling
```solidity
// Prefer custom errors with if-revert pattern
event GasOptimizationExample();
error InsufficientTier(uint8 required, uint8 provided);

function checkTier(uint8 provided) internal view {
    uint8 required = getRequiredTier(msg.value);
    if (provided < required) revert InsufficientTier(required, provided);
}
```

### Gas Optimizations
```solidity
// Use immutable for constructor-set values
address public immutable entryPoint;

// Use transient storage (EIP-1153) for reentrancy guards and cross-function data
modifier nonReentrant() {
    assembly {
        if tload(0) { revert(0, 0) }
        tstore(0, 1)
    }
    _;
    assembly { tstore(0, 0) }
}

// Pack storage variables
address private _guardian0;      // slot 0: 20 bytes
uint8 private _guardianCount;    // slot 0: 1 byte (packed with above)
address private _guardian1;      // slot 1
address private _guardian2;      // slot 2
```

---

## Testing Strategy

### Test Organization
- **Unit tests**: `test/AAStar*.t.sol` - Individual contract testing
- **Scenario tests**: `test/M5ScenarioTests.t.sol` - Business scenario validation
- **E2E tests**: `scripts/test-e2e-*.ts` - End-to-end Sepolia testing

### Running Tests
```bash
# All tests
forge test

# Specific test suite
forge test --match-path test/AAStarAirAccountV7.t.sol -vvv

# Specific test function
forge test --match-test test_validateUserOp_validSignature -vvv

# With gas report
forge test --gas-report

# Gas profiling for optimization
forge test --match-test test_execute --gas-report
```

### Test Structure Pattern
```solidity
contract AAStarAirAccountV7Test is Test {
    AAStarAirAccountV7 public account;
    MockEntryPoint public mockEntryPoint;
    Vm.Wallet public ownerWallet;

    function setUp() public {
        ownerWallet = vm.createWallet("owner");
        mockEntryPoint = new MockEntryPoint();
        account = new AAStarAirAccountV7(address(mockEntryPoint), ownerWallet.addr, _emptyConfig());
        vm.deal(address(account), 10 ether);
    }

    function test_validScenario() public {
        // Arrange
        address recipient = makeAddr("recipient");
        
        // Act
        vm.prank(address(mockEntryPoint));
        account.execute(recipient, 1 ether, "");
        
        // Assert
        assertEq(recipient.balance, 1 ether);
    }
}
```

---

## Algorithm IDs (algId)

Signatures are routed by their first byte (algId):

| algId | Name | Description | Tier |
|-------|------|-------------|------|
| 0x01 | ALG_BLS | BLS triple signature (legacy) | 3 |
| 0x02 | ALG_ECDSA | Standard ECDSA (owner key) | 1 |
| 0x03 | ALG_P256 | P256 WebAuthn passkey | 1 |
| 0x04 | ALG_CUMULATIVE_T2 | P256 + BLS dual-factor | 2 |
| 0x05 | ALG_CUMULATIVE_T3 | P256 + BLS + Guardian ECDSA | 3 |
| 0x06 | ALG_COMBINED_T1 | P256 AND ECDSA (zero-trust) | 1 |

---

## Security Considerations

### Critical Invariants
1. **Guard immutability**: Guard is deployed atomically with account; cannot be removed.
2. **Monotonic config**: Daily limits can only decrease; algorithms can only be added.
3. **Recovery timelock**: 2-day minimum delay before recovery execution.
4. **Guardian threshold**: 2-of-3 required for recovery; same threshold for cancellation.

### Deployment Requirements
- **EIP-7212**: P256 precompile must be available on target chain (major L2s + mainnet).
- **EIP-2537**: BLS precompiles required for BLS signature verification.
- **EntryPoint v0.7**: Canonical address `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.

### Precompile Addresses
```solidity
address internal constant P256_VERIFIER = address(0x100);      // EIP-7212
address private constant G1ADD_PRECOMPILE = address(0x0b);     // EIP-2537
address private constant G2ADD_PRECOMPILE = address(0x0e);     // EIP-2537
address private constant PAIRING_PRECOMPILE = address(0x0f);   // EIP-2537
```

---

## Environment Setup

### Required Environment Variables
```bash
# Core
PRIVATE_KEY=0x...                    # Deployer private key (with 0x prefix)
SEPOLIA_RPC_URL=https://...          # Sepolia RPC endpoint

# E2E Testing
AA_ACCOUNT_ADDRESS=0x...             # Test account address
SUPER_PAYMASTER_ADDRESS=0x...        # Paymaster for gasless txs
OPERATOR_ADDRESS=0x...               # Bundler operator address
APNTS_TOKEN_ADDRESS=0x...            # aPNTs token for gas payment

# BLS Testing (M2)
BLS_TEST_NODE_ID_1=0x...             # BLS node ID
BLS_TEST_PRIVATE_KEY_1=0x...         # BLS node private key
```

### Setup
```bash
# Copy example environment
cp .env.example .env

# Edit with your values
vim .env

# For Sepolia-specific config
cp .env.example .env.sepolia
```

---

## Dependencies

Key git submodules in `lib/`:

| Submodule | Purpose |
|-----------|---------|
| `account-abstraction` | ERC-4337 EntryPoint interfaces |
| `openzeppelin-contracts` | Standard libraries (ECDSA, Create2) |
| `forge-std` | Foundry testing utilities |
| `SuperPaymaster` | Gasless transaction paymaster |
| `aastar-sdk` | TypeScript SDK for integration |
| `kohaku/kohaku-extension` | Privacy/shielded pool support |

### Updating Submodules
```bash
git submodule update --init --recursive
```

---

## Common Tasks

### Adding a New Algorithm
1. Implement `IAAStarAlgorithm` interface
2. Deploy algorithm contract
3. Register via `AAStarValidator.registerAlgorithm(algId, address)`
4. Add algId to account's approved algorithms via guard
5. Update `_algTier()` mapping in both account and guard

### Adding Token Support
```solidity
// Token config must satisfy: daily >= tier2 >= tier1
guard.guardAddTokenConfig(
    tokenAddress,
    AAStarGlobalGuard.TokenConfig({
        tier1Limit: 100 * 10**18,    // Tier 1 max
        tier2Limit: 1000 * 10**18,   // Tier 2 max
        dailyLimit: 5000 * 10**18    // Daily cap
    })
);
```

### Creating a New Account
```solidity
// Via factory with defaults (2 personal guardians + community guardian)
factory.createAccountWithDefaults(
    owner,
    salt,
    guardian1,      // Backup key/passkey
    guardian1Sig,   // EIP-191 signature of keccak256("ACCEPT_GUARDIAN", chainId, factory, owner, salt)
    guardian2,      // Trusted person
    guardian2Sig,
    dailyLimit      // User's chosen daily limit (wei)
);
```

---

## Resources

- **ERC-4337**: https://eips.ethereum.org/EIPS/eip-4337
- **ERC-2537** (BLS precompiles): https://eips.ethereum.org/EIPS/eip-2537
- **ERC-7212** (P256 precompile): https://eips.ethereum.org/EIPS/eip-7212
- **Foundry Book**: https://book.getfoundry.sh/
- **EntryPoint v0.7**: https://github.com/eth-infinitism/account-abstraction

---

## Version History

See `CHANGELOG.md` for detailed release notes.

- **v0.14.0** (M5): Complete with ERC20 guard, guardian acceptance, zero-trust Tier 1
- **v0.13.x** (M4): Social recovery, cumulative algorithms
- **v0.12.x** (M3): Global guard with daily limits
- **v0.11.x** (M2): BLS signatures, DVT co-sign
- **v0.10.x** (M1): Basic ERC-4337 account with ECDSA
