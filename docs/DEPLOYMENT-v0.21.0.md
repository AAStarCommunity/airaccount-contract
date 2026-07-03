# Deployment — v0.21.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-06-29
**Deployer:** `0xb5600060e6de5E11D3636731964218E53caadf0E`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Script:** `scripts/deploy-v0.21.0.ts` (`pnpm tsx scripts/deploy-v0.21.0.ts`)

> Adds **WebAuthn-native cumulative algIds** (PR #148): `ALG_CUMULATIVE_T2_WA` (0x09) and
> `ALG_CUMULATIVE_T3_WA` (0x0a). These use the browser WebAuthn ceremony
> (`sha256(authenticatorData || sha256(clientDataJSON))`) for the P-256 layer instead of
> raw P-256. Existing algIds 0x01–0x08 are unchanged. ACCOUNT_VERSION = "0.21.0".

> **Impl constructor gas note:** WebAuthn functions (+2,455 bytes in Base) add ~490k gas
> to the ctor that deploys AirAccountExtension inline. Gas limit set to **15M** (was 10M
> for v0.20.x). Actual gas used: 10,023,442.

## Redeployed contracts

| Contract | Address | Notes |
|---|---|---|
| **AAStarAirAccountV7** (impl) | [`0x55fcEdC0902f192e4118E682b4f58582eaE78A73`](https://sepolia.etherscan.io/address/0x55fcEdC0902f192e4118E682b4f58582eaE78A73) | + 0x09/0x0a, ACCOUNT_VERSION="0.21.0" |
| **AirAccountExtension** (auto-deployed by impl ctor) | [`0x8928E1b549a81303105E2CB15713FE2718e11bb5`](https://sepolia.etherscan.io/address/0x8928E1b549a81303105E2CB15713FE2718e11bb5) | |
| **AAStarAirAccountFactoryV7** | [`0x3891c6543af966B11F772448228c7eC1906EF382`](https://sepolia.etherscan.io/address/0x3891c6543af966B11F772448228c7eC1906EF382) | algIds array 8→10 |
| **AgentRegistry** | [`0x6C598985B2f5deDFad0F34951147C4b1D37ea582`](https://sepolia.etherscan.io/address/0x6C598985B2f5deDFad0F34951147C4b1D37ea582) | fresh (bindFactory is set-once) |

## Reused from v0.20.3 (unchanged bytecode)

| Contract | Address |
|---|---|
| AAStarBLSAlgorithm (algId 0x01) | [`0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174`](https://sepolia.etherscan.io/address/0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174) |
| AAStarBLSAggregator | [`0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609`](https://sepolia.etherscan.io/address/0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609) |
| AAStarValidator (router) | [`0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11`](https://sepolia.etherscan.io/address/0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11) |
| SessionKeyValidator (algId 0x08) | [`0x6810CfB7c72D16e044a17694fAa8076e517264D0`](https://sepolia.etherscan.io/address/0x6810CfB7c72D16e044a17694fAa8076e517264D0) |
| ForceExitModule | [`0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc`](https://sepolia.etherscan.io/address/0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc) |
| AirAccountDelegate | [`0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0`](https://sepolia.etherscan.io/address/0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0) |
| CalldataParserRegistry | [`0x7dEea4544446826601014bD94d0F6432A67496F5`](https://sepolia.etherscan.io/address/0x7dEea4544446826601014bD94d0F6432A67496F5) |

## Wiring

| Step | Result |
|---|---|
| `agentRegistry.bindFactory(factory)` | sent on deploy |
| `factory.setAgentRegistry(agentRegistry)` | sent on deploy |

## algId whitelist (10 algIds)

| algId | Name | Tier | New in v0.21.0 |
|---|---|---|---|
| 0x01 | ALG_BLS | — | |
| 0x02 | ALG_ECDSA | 1 | |
| 0x03 | ALG_P256 | 1 | |
| 0x04 | ALG_CUMULATIVE_T2 | 2 | |
| 0x05 | ALG_CUMULATIVE_T3 | 3 | |
| 0x06 | ALG_COMBINED_T1 | 1 | |
| 0x07 | ALG_WEIGHTED | — | |
| 0x08 | ALG_SESSION_KEY | — | |
| **0x09** | **ALG_CUMULATIVE_T2_WA** | **2** | **✓** |
| **0x0a** | **ALG_CUMULATIVE_T3_WA** | **3** | **✓** |

## E2E verification

See `docs/e2e-results-v0.21.0.md`. All 14 tests PASS on Sepolia.
Script: `pnpm tsx scripts/e2e-v0.21.0.ts`

## env keys (`.env.sepolia`)

```
AIRACCOUNT_V0210_IMPL=0x55fcEdC0902f192e4118E682b4f58582eaE78A73
AIRACCOUNT_V0210_EXTENSION=0x8928E1b549a81303105E2CB15713FE2718e11bb5
AIRACCOUNT_V0210_FACTORY=0x3891c6543af966B11F772448228c7eC1906EF382
AIRACCOUNT_V0210_AGENT_REGISTRY=0x6C598985B2f5deDFad0F34951147C4b1D37ea582
AIRACCOUNT_V0210_BLS_ALGORITHM=0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174
AIRACCOUNT_V0210_BLS_AGGREGATOR=0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609
AIRACCOUNT_V0210_VALIDATOR_ROUTER=0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11
AIRACCOUNT_V0210_SESSION_KEY_VALIDATOR=0x6810CfB7c72D16e044a17694fAa8076e517264D0
AIRACCOUNT_V0210_FORCE_EXIT_MODULE=0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc
AIRACCOUNT_V0210_DELEGATE=0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0
AIRACCOUNT_V0210_PARSER_REGISTRY=0x7dEea4544446826601014bD94d0F6432A67496F5
```
