# Deployment — v0.28.0 (Sepolia)

**Network:** Sepolia · **Date:** 2026-07-13 · **Blocks:** 11262068–11262076
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` · **EntryPoint:** v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`)
**Script:** `scripts/deploy-v0.28.0.ts` · **Compiler:** 0.8.33, optimizer 200 runs, EVM Cancun, via-IR

> **v0.28.0 = CC-27 BLS registry rename + version bump.** Pure source-level release over v0.27.0:
> (1) `AAStarBLSAlgorithm` → `AAStarBLSKeyRegistry` (airaccount's own retired 0xAF525A path — NOT in
> this stack, which mounts the DVT validator `0x539B…` at algId 0x01), and (2) `ACCOUNT_VERSION` /
> `FACTORY_VERSION` `0.27.0` → `0.28.0`. **No behavior change.** Because the account stack is
> non-upgradable + the router is set-once, a fresh stack is required for the version constant to take
> effect. This is a **beta** deployment (external audit #29 pending before any GA/mainnet).

---

## Deployed addresses (v0.28.0)

| 合约 | 地址 | Etherscan verified |
|---|---|---|
| **Factory** (`AAStarAirAccountFactoryV7`) | `0x778ab75636F1350c31930078208eFB02E9765ed3` | ✅ |
| **Impl** (`AAStarAirAccountV7`) | `0xcCD6DfbaeE8c4249D2F9825781ece2cb5a456d97` | ✅ |
| **Extension** (`AirAccountExtension`, isValidOwnerAuth 宿主) | `0x7499968EC5a162b783b5816CbEC339008F132CAC` | ✅ |
| **Validator Router** (`AAStarValidator`) | `0xA6bdfD17C178b43B464736408e0Fe03D5a7684eB` | ✅ |
| **AgentRegistry** | `0xB683dECf86C327Cc033Ac2d18d45a4D30DFdE947` | ✅ |
| DVT BLS Validator (algId 0x01, CC-10, DVT 仓权威) | `0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC` | (DVT 仓管) |
| SessionKeyValidator (algId 0x08, reused v0.27.0) | `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` | ✅ (prior) |
| ForceExitModule (reused) | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` | ✅ (prior) |
| Delegate (reused) | `0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0` | prior |
| ParserRegistry (reused) | `0x7dEea4544446826601014bD94d0F6432A67496F5` | ✅ (prior) |

**On-chain checks (passed at deploy):** router `0x01`=DVT / `0x08`=session + finalized · impl
`validatorRouter`==new router · impl `ACCOUNT_VERSION`=="0.28.0" · agentRegistry bindFactory +
factory setAgentRegistry wired.

---

## What's deployed vs reused

- **Fresh (v0.28.0):** router, impl, extension, factory, AgentRegistry — new because the router is
  set-once + finalized and the impl bakes in the router (same rule as v0.24.0/v0.27.0).
- **Reused from v0.27.0:** SessionKeyValidator, ForceExitModule, Delegate, ParserRegistry, DVT validator.
- **KI-14 (parsers disabled):** ParserRegistry is reused but no default DeFi parser is wired — token
  tier caps are NOT enforced on swap-style calldata. Documented, accepted beta trade-off. See
  `docs/known-issues.md` KI-14 and the `CHANGELOG.md` v0.28.0 note.

## Verification method (all 5 fresh contracts, one pass)

Because v0.28.0 IS current `main`, all fresh contracts verify at 200 runs against current source with
**no version pinning** (unlike v0.27.0's reused-module drift). Command:

```bash
forge verify-contract <addr> <ContractName> --chain 11155111 \
  --etherscan-api-key <key> --compiler-version 0.8.33 \
  --num-of-optimizations 200 --evm-version cancun --via-ir --watch [--constructor-args <abi-encoded>]
```

Constructor args: impl = `constructor(address router)`; factory =
`constructor(address impl, address entrypoint, address community, address[], (uint256,uint256,uint256)[])`
with empty guardian/tier arrays; router / agentRegistry / extension take none.

---

## Downstream (notify after this deploy)

| 依赖方 | 换什么 |
|---|---|
| **@repo:sdk** | canonical Sepolia 地址：factory `0x778a…`, router `0xA6bd…`, impl `0xcCD6…`（CC-18 两阶段：ABI 先行、地址后切） |
| **@repo:dvt / @repo:kms** | 新 Extension `0x7499…`（isValidOwnerAuth 宿主）；旧 v0.27.0 `0xEcE8…` 上的 e2e_account 仍可用，需要新版账户时按 cc22 脚本用新 factory 重 mint |

> 旧 v0.27.0 栈仍在链上、非可升级，现有账户不受影响；v0.28.0 仅新账户使用。
