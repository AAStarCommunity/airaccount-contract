# AirAccount v0.17.2-beta.3 — Deployment Record

**Status**: DEPLOYED on Sepolia (complete)  
**Date**: 2026-06-12  
**Network**: Sepolia (chainId 11155111)  
**Deployer**: `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` (Anni)

---

## What Changed vs beta.2

| Change | Impact |
|--------|--------|
| `AAStarValidator` — M3 governance timelock (`proposeAlgorithm` + 7-day timelock + `executeProposal`) | **New router address** — existing accounts must call `setValidator(newRouter)` to use new SessionKeyValidator |
| `AAStarAirAccountV7` — `ACCOUNT_VERSION = "0.17.2"` | New implementation address |
| `AAStarAirAccountFactoryV7` — custom errors + `FACTORY_VERSION` | New factory address |
| `ForceExitModule` — `IncompatibleAccount` + assembly `_countBits` + `MODULE_VERSION` | New module address |
| `SessionKeyValidator` — `MODULE_VERSION` | New validator address |
| `AAStarAirAccountBase` — assembly `_popcount` (via impl) | Covered by new impl |
| `AAStarGlobalGuard` — constructor custom error (deployed per-account) | New accounts get updated guard; existing accounts unaffected |

**Router is now finalized**: `AAStarValidator.finalizeSetup()` was called after registration. Future algorithm changes require `proposeAlgorithm` → 7-day timelock → `executeProposal`.

**AgentRegistry re-deployed**: `bindFactory` is set-once per registry instance. A new AgentRegistry is deployed for every release that ships a new Factory. The beta.3 AgentRegistry is fully wired: `bindFactory(factory)` + `factory.setAgentRegistry(registry)` both called.

---

## Sepolia Contract Addresses

### Newly Deployed (beta.3)

| Contract | Address | TX | Gas |
|---|---|---|---|
| **AAStarValidator (router)** | `0x3c2b06f50300912794f29de031b33dd37bb8d6c6` | [tx](https://sepolia.etherscan.io/tx/0x3ef5ddf6eab1ee48ab79b84d926c6ebee53ff614b1c6000a6d28f41abb697230) | 508,016 |
| **ForceExitModule** | `0xdb396ca2dc279f9bcb95fa3d8275f77c9f0c8702` | [tx](https://sepolia.etherscan.io/tx/0x1d8b7a275b8fd9850ecc50fe3ae0ac891a2ad69578262f03deed6dd4700dc119) | 1,199,803 |
| **SessionKeyValidator** | `0x655ca2e9a2d1178f7fbcea1856560d1e0c657ebf` | [tx](https://sepolia.etherscan.io/tx/0x9e6324827cd1aa7e7b17a6a70fe9b2eb08a7588fcfac22b4580d0041799368de) | 2,274,029 |
| **AAStarAirAccountFactoryV7** | `0xfc6234bbd6283610659211347c6309904be86b0a` | [tx](https://sepolia.etherscan.io/tx/0xf713c41b4981b82200dac5747ed33ccf181ce9043ac7c8eb77bad261388d406c) | 9,340,279 |
| **AAStarAirAccountV7 (impl)** | `0xe33EeCF21AAC2B776b49A4dd52BA8b7e683dE9C3` | (deployed by factory) | — |
| **AirAccountExtension** | `0xB3c7312bA52dF306DE1cBa781B91f3AfA7e86F99` | (deployed by impl) | — |
| **AgentRegistry** | `0x9e8f576cad8a8f949181fd10d9ad1c49a7b0bc17` | [tx](https://sepolia.etherscan.io/tx/0x31b74f1e6060426efb4f3fc57a88ce8b535aaa204115b981f4cd8801a0e4dc15) | 808,200 |

### Wiring TXs

| Action | TX |
|---|---|
| `router.registerAlgorithm(0x01, BLS)` | [tx](https://sepolia.etherscan.io/tx/0x2f5eb902872a6ab847171a49044ac206262dae272c90517b176d5c36d3384d28) |
| `router.registerAlgorithm(0x08, SessionKeyValidator)` | [tx](https://sepolia.etherscan.io/tx/0x9a4d090bc1781e76e2fd175f3f2765a0e0c6e81009a4621e8786bf3881dffc3e) |
| `router.finalizeSetup()` | [tx](https://sepolia.etherscan.io/tx/0x42e5f747f5610b54fbb1797639d9e9e38b1d8d421f656ed9a7a73de925e1064b) |
| `agentRegistry.bindFactory(factory)` | [tx](https://sepolia.etherscan.io/tx/0xb040a3ddf179c701427de2b2689f132936e9d5c6dc8a8b085be5c4f6a5952794) |
| `factory.setAgentRegistry(agentRegistry)` | [tx](https://sepolia.etherscan.io/tx/0xe65930629f9fc782afb33cb1a913f5e8f0d859c4800f850462ff247baece465c) |

### Unchanged from beta.2

| Contract | Address |
|---|---|
| AAStarBLSAlgorithm | `0xB82127182A855B82eED05e47536FcE568b626457` |
| AAStarBLSAggregator | `0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1` |
| AirAccountDelegate (EIP-7702) | `0x8603AAF6C3f07fdae810B323c95a198D796EC52E` |
| CalldataParserRegistry | `0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F` |
| ~~AgentRegistry (beta.2, deprecated)~~ | ~~`0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB`~~ |

### Algorithm Registry (new router)

| algId | Contract | Address |
|---|---|---|
| `0x01` | AAStarBLSAlgorithm | `0xB82127182A855B82eED05e47536FcE568b626457` |
| `0x08` | SessionKeyValidator | `0x655ca2e9a2d1178f7fbcea1856560d1e0c657ebf` |

> **Deprecated (do not use)**  
> OLD router (beta.1/beta.2): `0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F`  
> ForceExitModule beta.2: `0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9`  
> ForceExitModule beta.1: `0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9`

---

## SDK Update Required

After this deployment, update in `@aastar/core`:

1. **Contract addresses for Sepolia** — use table above
2. **`abi/AAStarAirAccountV7.full.json`** — 64 functions (already updated in this repo)
3. **Factory custom error selectors** — replace string-based error matching with typed selectors
4. **Router address** — all accounts must point to new router `0x3c2b06f50300912794f29de031b33dd37bb8d6c6`

SDK tracking issue: [AAStarCommunity/aastar-sdk#48](https://github.com/AAStarCommunity/aastar-sdk/issues/48)

---

## Migration Guide for Existing Users

**Validator router has changed.** Existing accounts deployed on beta.1 or beta.2 that use BLS or session-key signing must call:

```solidity
account.setValidator(0x3c2b06f50300912794f29de031b33dd37bb8d6c6);
```

This is a one-time owner call. ECDSA signing (owner key) continues to work without migration.

**No action required** for accounts that only use ECDSA signing.

The old factory and old module addresses remain on-chain but are considered deprecated for new deployments.

---

## Deployment Script

```bash
pnpm tsx scripts/deploy-v0172-beta3.ts
```

See `scripts/deploy-v0172-beta3.ts` for the full deployment and wiring logic.
