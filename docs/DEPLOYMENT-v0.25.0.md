# Deployment — v0.25.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-07-05 · **Blocks:** 11206373–11206377
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Script:** `scripts/deploy-v0.25.0.ts`

> **CRITICAL-1 — validation/execution tier desync fix** (PR #169). Only `AAStarAirAccountBase` changed
> (M1 raw-65 fallback removed + `_deriveStoredAlgId` single-source routing + revert-free router). So this
> deploy **reuses the entire v0.24.0 validator stack** (router + SessionKeyValidator + BLS + aggregator +
> ForceExit + Delegate + ParserRegistry) and ships only a new impl + factory (+ auto Extension) +
> AgentRegistry. Existing accounts (old impl) are unaffected — non-upgradable.

## New addresses (v0.25.0)

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0x2979C772D8465418D3456960Cd15bB20b50E774e`](https://sepolia.etherscan.io/address/0x2979C772D8465418D3456960Cd15bB20b50E774e) |
| AAStarAirAccountV7 (impl) | [`0xC00D61Ca22C6F2A46818609EED77Ca048eAb00BC`](https://sepolia.etherscan.io/address/0xC00D61Ca22C6F2A46818609EED77Ca048eAb00BC) |
| AirAccountExtension | [`0xD63ec5f2F7F9220446139a712a87d55288Eb3068`](https://sepolia.etherscan.io/address/0xD63ec5f2F7F9220446139a712a87d55288Eb3068) |
| AgentRegistry | [`0xD4f0E34bB459E9173FcBBf0157b5F41d81670390`](https://sepolia.etherscan.io/address/0xD4f0E34bB459E9173FcBBf0157b5F41d81670390) |

## Reused v0.24.0 validator stack (unchanged bytecode)

| Contract | Address |
|---|---|
| AAStarValidator (router) | `0x10fAfB964a6bb88552a588Ed652257EE4E90Eb87` |
| SessionKeyValidator | `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` |
| BLS Algorithm | `0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174` |
| BLS Aggregator | `0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609` |
| ForceExitModule | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` |
| Delegate | `0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0` |
| ParserRegistry | `0x7dEea4544446826601014bD94d0F6432A67496F5` |

## Deployment transactions

| Step | Tx | Gas |
|---|---|---|
| impl | [`0x…`](https://sepolia.etherscan.io/address/0xC00D61Ca22C6F2A46818609EED77Ca048eAb00BC) (block 11206373) | 10,405,117 |
| factory | [`0x4ad2474b…a1c327`](https://sepolia.etherscan.io/tx/0x4ad2474be9c39d5b26d188c93d55645a12d17f73f082e01d7674c778ada1c327) | 3,087,032 |
| agentRegistry | [`0x138a7f04…30c2835`](https://sepolia.etherscan.io/tx/0x138a7f04ec973a53ff6e80c843bcbc4424ea12a851bfb89befd6c8f1030c2835) | 808,200 |
| bindFactory | [`0x0d599429…662a0bac`](https://sepolia.etherscan.io/tx/0x0d5994292cb6d0cb5c3bb4f89ca6b7dfa0a7bbce45f2d93804fcf2a8662a0bac) | 48,000 |
| setAgentRegistry | [`0xcfc4a09b…16de0054`](https://sepolia.etherscan.io/tx/0xcfc4a09b82385d6519050a65e55c5d7f5849f748b9dde724b1bcc00b16de0054) | 47,839 |

## On-chain verification

- `impl.ACCOUNT_VERSION()` / `factory.FACTORY_VERSION()` → `"0.25.0"` ✓
- `impl.validatorRouter()` → `0x10fAfB…` (reused v0.24.0 router) ✓

## On-chain E2E — `scripts/e2e-v0.25.0.ts` (30/30 PASS)

Accounts: Account1 `0x5a6AF496302A1858e875b8B923345bE208508a58`,
Account2 (P256) `0xD4389c3c9e268bF01b7d8b3E3A30B8b619b26F2e`.

- T1–T27: version / validatorRouter auto-wire / passkey / CREATE2 divergence / all 10 algIds /
  `isValidOwnerAuth` / factory relay-mode views.
- T28–T29: guardian-aware address (fix c) + router 0x08 wiring (fix d) still hold on the reused stack.
- **T30 (CRITICAL-1):** the deployed impl runtime bytecode (immutables masked) **equals the locally
  compiled, fixed artifact** — i.e. the on-chain code is exactly the build the 895 unit tests ran
  against, including `test_rawECDSA_firstByte0x09/0x0a_rejected`. Since `validateUserOp` cannot be
  called as the EntryPoint on a live network, this bytecode identity is the strongest available on-chain
  proof that the tier desync is closed on-chain.

Unit tests: **895 pass** (cancun + prague). EIP-170: impl 24,408 B (168 B headroom).

## SDK coordination

Removing the M1 raw-65 fallback breaks the SDK Tier-1 tiering path
(`aastar-sdk bls-signature-service.ts generateTieredSignature(tier=1)` emits raw 65-byte) —
tracked in **aastar-sdk#273** (prepend `0x02`). Ledger/KMS paths already emit `0x02` and are unaffected.
