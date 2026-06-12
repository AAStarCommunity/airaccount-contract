# AirAccount v0.17.2-beta.3 — Deployment Record

**Status**: PENDING — fill in after Sepolia redeployment  
**Date**: TBD  
**Network**: Sepolia (chainId 11155111)  
**Deployer**: TBD

---

## What Changed vs beta.2

| Change | Impact |
|--------|--------|
| `AAStarAirAccountV7` — `ACCOUNT_VERSION = "0.17.2"` | New implementation address |
| `AAStarAirAccountFactoryV7` — custom errors + `FACTORY_VERSION` | New factory address |
| `ForceExitModule` — `IncompatibleAccount` + assembly `_countBits` + `MODULE_VERSION` | New module address |
| `SessionKeyValidator` — `MODULE_VERSION` | New validator address |
| `AAStarAirAccountBase` — assembly `_popcount` (via impl) | Covered by new impl |
| `AAStarGlobalGuard` — constructor custom error (deployed per-account) | New accounts get updated guard; existing accounts unaffected |

**No behavioral changes** — existing accounts on beta.2 do NOT need migration.

---

## Sepolia Contract Addresses

| Contract | Address | Notes |
|---|---|---|
| **AAStarAirAccountV7 (impl)** | `TBD` | New deploy — ACCOUNT_VERSION |
| **AAStarAirAccountFactoryV7** | `TBD` | New deploy — FACTORY_VERSION + custom errors |
| **ForceExitModule** | `TBD` | New deploy — MODULE_VERSION + IncompatibleAccount |
| **SessionKeyValidator** | `TBD` | New deploy — MODULE_VERSION |
| AAStarValidator (router) | `0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F` | unchanged |
| BLSAlgorithm | `0xc2096E8D04beb3C337bb388F5352710d62De0287` | unchanged |
| AirAccountDelegate (7702) | (see beta.1 record) | unchanged |
| CompositeValidator | `0x7442631286f7a93487ccf9bebae28d37c88574c6` | unchanged |
| TierGuardHook | `0xea1d2eaa73b7e6757303b29968ded26868be20b8` | unchanged |
| WeightedECDSAValidator | (see beta.1 record) | unchanged |

> **Deprecated (do not use)**  
> ForceExitModule beta.2: `0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9`  
> ForceExitModule beta.1: `0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9`

---

## Deployment Commands

```bash
# 1. Build + verify locally
forge build
forge test --summary  # must be 679+/0/0

# 2. Deploy (adjust salt as needed)
npx tsx scripts/deploy-beta3.ts --network sepolia

# 3. Verify on Etherscan
forge verify-contract <IMPL_ADDR> src/core/AAStarAirAccountV7.sol:AAStarAirAccountV7 \
  --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY

# 4. Register SessionKeyValidator at algId 0x08 (if not already)
cast send $VALIDATOR_ROUTER "registerAlgorithm(uint8,address)" 0x08 $SESSION_KEY_VALIDATOR \
  --rpc-url $SEPOLIA_RPC --private-key $DEPLOYER_PK

# 5. Run E2E suite against new addresses
npx tsx scripts/e2e-v0172/run-all.ts --network sepolia
```

---

## SDK Update Required

After redeployment, update in `@aastar/core`:
1. `abi/AAStarAirAccountV7.full.json` — 64 functions (already updated in this repo)
2. Contract addresses for Sepolia (fill in table above, then sync to SDK)
3. Factory custom error selectors (replace string-based error matching)

SDK tracking issue: TBD (see SDK repo)

---

## Migration Guide for Existing Users

**No action required.** Existing accounts deployed on beta.2 factory continue to work normally. The old factory and old ForceExitModule addresses remain on-chain but are considered deprecated.

Users who have installed `ForceExitModule` from beta.2 can optionally reinstall from the beta.3 address to get the `IncompatibleAccount` protection. This is optional and only relevant if they plan to use ForceExit.
