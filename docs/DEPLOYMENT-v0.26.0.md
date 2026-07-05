# Deployment — v0.26.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-07-05 · **Blocks:** 11206809–11206813
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Script:** `scripts/deploy-v0.26.0.ts`

> **HIGH-1 — ERC-7579 nonce-key module-route tier binding** (PR #173). The nonce-key validator-module
> route now caps to Tier-1 (rejects session 0x08, weighted 0x07, and any algId with `_algTier > 1`),
> plus a stale-weight defense-in-depth guard in `_populateExecAlg`. Only `AAStarAirAccountV7` +
> `AAStarAirAccountBase` changed → **reuses the entire v0.25.0 validator stack**; only impl + factory
> (+ auto Extension) + AgentRegistry redeployed. Non-breaking; existing accounts unaffected.

## New addresses (v0.26.0)

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0x2039a9f81e961497237237c37aD5dBEf57C24F24`](https://sepolia.etherscan.io/address/0x2039a9f81e961497237237c37aD5dBEf57C24F24) |
| AAStarAirAccountV7 (impl) | [`0xdDA2037B07AB41BBDf88C5A2Dc136f710981f549`](https://sepolia.etherscan.io/address/0xdDA2037B07AB41BBDf88C5A2Dc136f710981f549) |
| AirAccountExtension | [`0x1CC9Ff3DEfDCf65d0347c9aacDfBA872BCf9d6B8`](https://sepolia.etherscan.io/address/0x1CC9Ff3DEfDCf65d0347c9aacDfBA872BCf9d6B8) |
| AgentRegistry | [`0x2933b81A29859e29457F29043058B1351B531AA8`](https://sepolia.etherscan.io/address/0x2933b81A29859e29457F29043058B1351B531AA8) |
| Router (reused v0.24.0/v0.25.0) | `0x10fAfB964a6bb88552a588Ed652257EE4E90Eb87` |
| SessionKeyValidator (reused) | `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` |

## On-chain verification
- `impl.ACCOUNT_VERSION()` / `factory.FACTORY_VERSION()` → `"0.26.0"` ✓
- `impl.validatorRouter()` → `0x10fAfB…` (reused stack) ✓

## Verification
- Unit: **900 pass** (cancun + prague), incl. 5 module-route tier guards (Tier-2/3/BLS/weighted rejected,
  Tier-1 succeeds). EIP-170: impl **24,494 B (82 B headroom)**.
- **On-chain E2E 30/30** (views) + **4/4 real UserOp** via Pimlico (0x02 included `0x498fa643…`; raw-65
  rejected AA24 — v0.25.0 fix still holds, no regression).
- **Bytecode identity:** deployed impl runtime (immutable-masked) `keccak256` =
  `0x27dbc14f2d7a9a240e411da559a6ebf5ce5071eed0107a527ad03d04fced7123`, matching the locally-compiled
  fixed artifact — the on-chain code IS the build that passed the 900 tests. Since the HIGH-1 exploit
  needs a guardian-installed module + nonce-key routing (impractical to stage live), this bytecode
  identity + the 5 unit guards is the on-chain proof the module-route tier cap ships.
- **Codex:** the fix was adversarially verified TWICE on PR #173 — round 1 confirmed the 0x07 stale-weight
  gap (fixed in-branch), round 2 returned **No Confirmed Issues, correct and complete**.

## HIGH-1 fix summary
The nonce-key module route stamped the tier from the attacker-controlled `sig[0]`; a Tier-1 module key
could claim `sig[0]==0x0a` and spend at Tier-3. Now capped to Tier-1: `session (0x08) || weighted (0x07)
|| _algTier(algId) > 1` are rejected. `_populateExecAlg` also clears any stale callData-keyed weight on a
failed weighted re-accumulation. Closes #171.
