# Deployment — v0.24.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-07-03 · **Blocks:** 11194923–11194932
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Community guardian:** `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`
**Script:** `scripts/deploy-v0.24.0.ts`

> **Security-hardening batch** (PRs #162–#167). Five fixes from a global security-architecture review,
> each adversarially verified via Codex. See `CHANGELOG.md` v0.24.0 and
> `docs/security/SECURITY_HARDENING_v0.23.0.md`.
>
> **NEW validator stack.** Fix d changed `SessionKeyValidator`, which the account resolves via
> `router.getAlgorithm(0x08)`. The `AAStarValidator` router is set-once per algId, so a NEW router +
> NEW SessionKeyValidator were deployed (0x01 → reused BLS algorithm, 0x08 → new session validator,
> then `finalizeSetup`), and the new router is baked into the new impl. Existing accounts (old
> impl/router) are unaffected — non-upgradable, only new accounts get the fixes.

## Core addresses

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0xD00bFa573B42C9cB046877032742e7961e986631`](https://sepolia.etherscan.io/address/0xD00bFa573B42C9cB046877032742e7961e986631) |
| AAStarAirAccountV7 (impl) | [`0xcdDA9180Ee728aaA926895d360ae0D0ed8D38718`](https://sepolia.etherscan.io/address/0xcdDA9180Ee728aaA926895d360ae0D0ed8D38718) |
| AirAccountExtension | [`0x80ab91cdb986042E941a5FC3D1769c538918f9c6`](https://sepolia.etherscan.io/address/0x80ab91cdb986042E941a5FC3D1769c538918f9c6) |
| **AAStarValidator (router, NEW)** | [`0x10fAfB964a6bb88552a588Ed652257EE4E90Eb87`](https://sepolia.etherscan.io/address/0x10fAfB964a6bb88552a588Ed652257EE4E90Eb87) |
| **SessionKeyValidator (NEW — fix d)** | [`0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f`](https://sepolia.etherscan.io/address/0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f) |
| AgentRegistry | [`0x8D7243D20A3F09e0b73653895Dd93881eeE4b2c0`](https://sepolia.etherscan.io/address/0x8D7243D20A3F09e0b73653895Dd93881eeE4b2c0) |

## Reused v0.23.0 singletons (unchanged bytecode)

| Contract | Address |
|---|---|
| BLS Algorithm | `0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174` |
| BLS Aggregator | `0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609` |
| ForceExitModule | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` |
| Delegate | `0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0` |
| ParserRegistry | `0x7dEea4544446826601014bD94d0F6432A67496F5` |

## Router setup (verified on-chain)

- `router.getAlgorithm(0x01)` → `0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174` (reused BLS) ✓
- `router.getAlgorithm(0x08)` → `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` (new SessionKeyValidator) ✓
- `router.setupComplete` → `true` (finalized — 0x08 can no longer be swapped) ✓
- `impl.validatorRouter()` → the new router ✓

## Deployment transactions

| Step | Tx | Gas |
|---|---|---|
| SessionKeyValidator | (block 11194923; a prior 2.5M-gas attempt OOG-reverted → gas raised to 4M, retry succeeded) | 2,504,038 |
| router | [`0x0fc89106…7ff46e`](https://sepolia.etherscan.io/tx/0x0fc89106ad7b5014684141efc92135d03933d8ede609855152f697eb267ff46e) | 508,016 |
| register 0x01 | [`0x1f97f73e…5b9d33`](https://sepolia.etherscan.io/tx/0x1f97f73e55833cc7408a3234e06ed2765cf92545ddbaaf8d185c41625f5b9d33) | 47,930 |
| register 0x08 | [`0xac977255…5396f2`](https://sepolia.etherscan.io/tx/0xac977255a08b76c7a57006537b4c87a6658ed9b19f19ed550852a6214f5396f2) | 47,930 |
| finalizeSetup | [`0xdbe39385…0a110f`](https://sepolia.etherscan.io/tx/0xdbe393851fd1349d65d3acd189cd9af6ddf4b8d3a74f9a4332ec2a36e00a110f) | 27,059 |
| impl | [`0xe78c3dda…b664f0`](https://sepolia.etherscan.io/tx/0xe78c3ddacfd2b5622a4aa6d2f579cb2bda1130124e0002e7de4f20e98cb664f0) | 10,412,700 |
| factory | [`0x91d6c9c7…4a02cfc`](https://sepolia.etherscan.io/tx/0x91d6c9c7a08036b120520bf05c8712af49cbdf9902bdbd8ab69cd8c764a02cfc) | 3,087,044 |
| agentRegistry | [`0xb22622df…19bde4`](https://sepolia.etherscan.io/tx/0xb22622df67bb1e3c74932a2e77c755fd18a873691605e2c7359dbc9d1e19bde4) | 808,200 |
| bindFactory | [`0xee738d00…026398`](https://sepolia.etherscan.io/tx/0xee738d006616fe73d9ce89746396d21b9fac98f461810715d378292091026398) | 48,000 |
| setAgentRegistry | [`0x8ada9bb8…040a30`](https://sepolia.etherscan.io/tx/0x8ada9bb803115e9ebc0c44d778e442647f0b50f01c197352f01b290f79040a30) | 47,839 |

## On-chain verification

- `impl.ACCOUNT_VERSION()` / `factory.FACTORY_VERSION()` → `"0.24.0"` ✓

## On-chain E2E — `scripts/e2e-v0.24.0.ts` (29/29 PASS)

Accounts: Account1 (no P256) `0xCa161Fa020548dB4f113E3B0C45137753C24eDA4`,
Account2 (P256) `0x368B027323aBD7A1Fd8bf206894A8cc9cae731e5`.

- T1–T21: version / validatorRouter auto-wire / passkey birth injection / CREATE2 divergence / all 10 algIds.
- T22–T25: `isValidOwnerAuth` (owner ECDSA → magic; wrong-signer/unknown-tag/empty → fail).
- T26–T27: factory `getConfigHash` / `hashCreateAccount` present.
- **T28 (fix c):** `getAddressWithDefaults` with different guardians → different address ✓.
- **T29 (fix d):** `account.validator` == new router, `router[0x08]` == new SessionKeyValidator ✓.

Unit tests: **893 pass** (cancun + prague). EIP-170: impl 24,443 B (133 B headroom).
