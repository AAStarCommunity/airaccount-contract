# Deployment — v0.22.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-06-30 · **Blocks:** 11172946–11172953
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Community guardian:** `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`
**Script:** `scripts/deploy-v0.22.0.ts` (`pnpm tsx scripts/deploy-v0.22.0.ts`)

> **Factory Passkey Bootstrap** (issue #155, PR #156).
> Impl now takes `validatorRouter` as constructor arg — all clones auto-wire
> `validator` at birth. `createAccount` accepts `ownerP256X/Y` at birth;
> clone salt and KMS sig domain include the full P256 key (anti-front-run +
> anti-relay-key-swap). Security fix: KMS sig domain uses `_getConfigHash(config)`
> covering the full InitConfig, not just `approvedAlgIds`.

## Core addresses

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0x0eb0E7a61d5D9e03bc3578f8C1b0d9f40cc0a5B9`](https://sepolia.etherscan.io/address/0x0eb0E7a61d5D9e03bc3578f8C1b0d9f40cc0a5B9) |
| **AAStarAirAccountV7** (implementation) | [`0x1cE314101E218D28bb6c6D16d6C259A4a1E67578`](https://sepolia.etherscan.io/address/0x1cE314101E218D28bb6c6D16d6C259A4a1E67578) |
| **AirAccountExtension** (auto-deployed by impl ctor) | [`0xF736C229fE6f0cb9C864A4298E2755b7a0A19691`](https://sepolia.etherscan.io/address/0xF736C229fE6f0cb9C864A4298E2755b7a0A19691) |
| AgentRegistry | [`0x19d89A661F41c353c119d90F76BB7151E03F0D91`](https://sepolia.etherscan.io/address/0x19d89A661F41c353c119d90F76BB7151E03F0D91) |
| AAStarValidator (router, reused) | [`0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11`](https://sepolia.etherscan.io/address/0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11) |
| SessionKeyValidator (algId 0x08, reused) | [`0x6810CfB7c72D16e044a17694fAa8076e517264D0`](https://sepolia.etherscan.io/address/0x6810CfB7c72D16e044a17694fAa8076e517264D0) |
| AAStarBLSAlgorithm (algId 0x01, reused) | [`0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174`](https://sepolia.etherscan.io/address/0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174) |
| AAStarBLSAggregator (reused) | [`0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609`](https://sepolia.etherscan.io/address/0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609) |
| ForceExitModule (reused) | [`0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc`](https://sepolia.etherscan.io/address/0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc) |
| AirAccountDelegate (reused) | [`0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0`](https://sepolia.etherscan.io/address/0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0) |
| CalldataParserRegistry (reused) | [`0x7dEea4544446826601014bD94d0F6432A67496F5`](https://sepolia.etherscan.io/address/0x7dEea4544446826601014bD94d0F6432A67496F5) |

## Deploy transactions

| Step | Tx | Gas |
|---|---|---|
| impl deploy | [`0xd1fe6b7d…`](https://sepolia.etherscan.io/tx/0xd1fe6b7d71df2502781f91987e110e5f41eb504bb834f5e47e5fc3a600fc7d3b) | 10,111,232 |
| factory deploy | [`0xb1f3e3fc…`](https://sepolia.etherscan.io/tx/0xb1f3e3fc6bac418de85735b0b5febc0011594202e79ba71113e44b08e0b06f1c) | 3,038,556 |
| agentRegistry deploy | [`0x51aa86b0…`](https://sepolia.etherscan.io/tx/0x51aa86b004594720eb6f9d41bae312193e7b036fbd278d29e6ba3aaa25266d95) | 808,200 |
| `agentRegistry.bindFactory(factory)` | [`0x4cb2c393…`](https://sepolia.etherscan.io/tx/0x4cb2c3931ca5e1010273f0e59514fee28341e991d71e638e0fe8960c2669c570) | 48,000 |
| `factory.setAgentRegistry(agentRegistry)` | [`0xa18608dd…`](https://sepolia.etherscan.io/tx/0xa18608dd4bd8bdd68815c799211fd52ff08343f4617e85457c87ecd9c5fb1e54) | 47,839 |

## E2E results (21/21 passed)

Script: `pnpm tsx scripts/e2e-v0.22.0.ts`

| # | Test | Result |
|---|---|---|
| T1 | ACCOUNT_VERSION on impl == "0.22.0" | PASS |
| T2 | impl.validatorRouter() == VALIDATOR_ROUTER | PASS |
| T3 | createAccount (no P256 key, direct mode) | PASS — gas 532,171 |
| T4 | clone ACCOUNT_VERSION == "0.22.0" | PASS |
| T5 | accountId == "airaccount.v7@0.22.0" | PASS |
| T6 | account.validator() == VALIDATOR_ROUTER (P1 auto-wire) | PASS |
| T7 | account.p256KeyX() == 0 when no key passed | PASS |
| T8 | createAccount (with P256 key PX/PY) | PASS — gas 572,739 |
| T9 | account2.p256KeyX() == PX (set at birth) | PASS |
| T10 | account2.p256KeyY() == PY (set at birth) | PASS |
| T11 | diff P256 → diff CREATE2 addr (anti-front-run) | PASS |
| T12 | algId 0x09 ALG_CUMULATIVE_T2_WA approved | PASS |
| T13 | algId 0x0a ALG_CUMULATIVE_T3_WA approved | PASS |
| T14 | algId 0x04 ALG_CUMULATIVE_T2 approved | PASS |
| T15 | algId 0x05 ALG_CUMULATIVE_T3 approved | PASS |
| T16 | algId 0x02 ALG_ECDSA approved | PASS |
| T17 | algId 0x01 ALG_BLS approved | PASS |
| T18 | algId 0x03 ALG_P256 approved | PASS |
| T19 | algId 0x06 ALG_COMBINED_T1 approved | PASS |
| T20 | algId 0x07 ALG_WEIGHTED approved | PASS |
| T21 | algId 0x08 ALG_SESSION_KEY approved | PASS |

E2E accounts (Sepolia):
- Account1 (no P256): [`0xfe5BA41Af822B34466de0a994DF085C2e372fBEd`](https://sepolia.etherscan.io/address/0xfe5BA41Af822B34466de0a994DF085C2e372fBEd)
- Account2 (P256 set): [`0xa29d8cf81bc03EAf2D0a15257C0097B25a70eF28`](https://sepolia.etherscan.io/address/0xa29d8cf81bc03EAf2D0a15257C0097B25a70eF28)
