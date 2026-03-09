# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository is the smart contract layer for **AirAccount** - a privacy-first, non-upgradable, multi-signature ERC-4337 smart wallet. Rather than building from scratch, it integrates three reference implementations as git submodules in `lib/`:

- **`lib/simple-team-account`** (Stackup) — Team/multisig account with WebAuthn (P-256), ECDSA, and BLS signature support. Hardhat-based.
- **`lib/light-account`** (Alchemy) — Lightweight single/multi-owner ERC-4337 account with namespaced storage. Foundry-based.
- **`lib/kernel`** (ZeroDev) — Modular ERC-7579 account with plugin validators, executors, and hooks. Foundry + Hardhat.

## Build & Test Commands

### simple-team-account (Hardhat)
```bash
cd lib/simple-team-account
yarn install
yarn compile
yarn test                  # Full test suite
yarn test-dev              # Run on local dev network
yarn lint                  # Solidity + JS linting
yarn lint-fix              # Auto-fix lint issues
yarn gas-calc              # Gas usage analysis
yarn deploy --network <name>   # Deploy (networks: sepolia, base, mainnet, etc.)
yarn verify --network <name>   # Etherscan verification
```

### light-account (Foundry)
```bash
cd lib/light-account
forge build
forge test -vvv
forge script script/Deploy_LightAccountFactory.s.sol \
    --wallet-options --sender <ADDR> --rpc-url <RPC> \
    -vvvv --broadcast --verify
slither .                  # Static analysis
```

### kernel (Foundry primary, Hardhat for compilation)
```bash
cd lib/kernel
forge build
forge test
forge test --match-test <testFunctionName>
forge test --match-path test/Kernel.t.sol
forge test -vv
FOUNDRY_PROFILE=optimized forge test
yarn compile               # Hardhat compilation only
```

## Architecture

### Key Design Decisions
- **Non-upgradable**: No proxy patterns (no UUPS). New features require new contract versions + asset migration by users.
- **Tiered verification**: Amounts under $100 use single WebAuthn; $100–$1000 use dual-factor; above $1000 require multi-sig consensus.
- **Global guards**: Hardcoded spending limits at the contract level, immutable and uncircumventable even with all signatures.
- **Privacy**: Supports Railgun/Kohaku shielded pools and One-Account-Per-DApp (OAPD) isolation model.

### simple-team-account Contracts
- `contracts/core/EntryPoint.sol` — ERC-4337 entry point
- `contracts/samples/SimpleTeamAccount.sol` — Main team account with 4 signature types (Owner+WebAuthn, Member+WebAuthn+ECDSA, ECDSA-only, tiered role-based)
- `contracts/samples/SimpleTeamAccountFactory.sol` — CREATE2 deterministic factory
- `contracts/samples/VerifyingPaymaster.sol` / `TokenPaymaster.sol` — Gas sponsorship

```solidity
struct Signer {
    bytes32 pubKeySlt1;  // P-256 x-coord or padded EOA address
    bytes32 pubKeySlt2;  // P-256 y-coord or 0
    Access level;        // Outsider / Member / Owner
}
```

### light-account Contracts
- `src/LightAccount.sol` — Single-owner account with namespaced storage slots
- `src/MultiOwnerLightAccount.sol` — Multi-owner variant with `updateOwners()`
- Factories use Solady's `LibClone.createDeterministicERC1967`

### kernel Contracts
- `src/Kernel.sol` — Core modular account (ERC-4337 + ERC-7579)
- `src/core/ValidationManager.sol`, `ExecutorManager.sol`, `HookManager.sol`, `SelectorManager.sol`
- `src/validator/ECDSAValidator.sol`, `WeightedECDSAValidator.sol`, `MultiChainValidator.sol`
- Module interfaces: `IValidator`, `IExecutor`, `IHook`, `IFallback`, `IPolicy`, `ISigner`

## Compiler Settings

| Submodule | Solidity | EVM | Via-IR | Optimizer Runs |
|-----------|----------|-----|--------|----------------|
| simple-team-account | 0.8.23 | default | yes | 1,000,000 |
| light-account | 0.8.28 | Cancun | yes | 10,000,000 |
| kernel | 0.8.0+ | Prague | deploy only | 200 (default) |

## Code Style (kernel conventions, apply broadly)

- 4-space indentation, braces on same line
- Named imports: `import {Contract} from "./path.sol";`
- Interfaces prefixed with `I` (e.g. `IValidator`)
- Private/internal functions prefixed with `_`
- Constants: `ALL_CAPS_WITH_UNDERSCORES`
- Custom errors with if-revert pattern: `if (condition) revert ErrorName();`
- Immutable variables preferred for gas optimization

## Environment Setup

Copy `.env.example` to `.env` in `lib/simple-team-account/` and fill in RPC URLs and private keys before deploying.

Supported networks for simple-team-account: `dev`, `localgeth`, `mainnet`, `base`, `avalanche`, `sepolia`, `baseSepolia`, `avalancheFuji`.
