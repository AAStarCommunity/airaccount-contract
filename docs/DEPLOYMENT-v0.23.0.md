# Deployment — v0.23.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-07-01 · **Blocks:** 11178605–11178609
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Community guardian:** `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`
**Script:** `scripts/deploy-v0.23.0.ts` (`pnpm tsx scripts/deploy-v0.23.0.ts`)

> **isValidOwnerAuth** (issue #159, PR #160).
> Adds `isValidOwnerAuth(bytes32 userOpHash, bytes calldata ownerAuth) view returns (bytes4)`
> — an ERC-1271-style owner-authorization single source of truth the DVT
> (YetAnotherAA-Validator#140) and any relayer `eth_call`, so owner authorization
> (ECDSA `personal_sign` **or** owner WebAuthn passkey) is never re-implemented
> off-chain and cannot drift from the contract. Hosted in `AirAccountExtension`
> (main account had only 222 B EIP-170 headroom), reached via the account's
> fallback → delegatecall. Magic `0xa0cf00cf`; fail-closed. No factory/account
> API change vs v0.22.0.

## Core addresses

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0x61B573D785dFd6DECAc7BB8a67F862E2B7a3792e`](https://sepolia.etherscan.io/address/0x61B573D785dFd6DECAc7BB8a67F862E2B7a3792e) |
| AAStarAirAccountV7 (impl) | [`0xB54C490Ac28e4367BE5605Ca28Ff1Ea9736eB1fd`](https://sepolia.etherscan.io/address/0xB54C490Ac28e4367BE5605Ca28Ff1Ea9736eB1fd) |
| AirAccountExtension (facet) | [`0x9af60b5F19Ed099f9c709B74EADe0b65aBf7993C`](https://sepolia.etherscan.io/address/0x9af60b5F19Ed099f9c709B74EADe0b65aBf7993C) |
| AgentRegistry | [`0x99edDdEbeA2032781790ea47F3911C1ba0F43b2D`](https://sepolia.etherscan.io/address/0x99edDdEbeA2032781790ea47F3911C1ba0F43b2D) |

## Reused v0.22.0 singletons (unchanged bytecode)

| Contract | Address |
|---|---|
| BLS Algorithm | `0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174` |
| Validator Router | `0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11` |
| BLS Aggregator | `0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609` |
| SessionKeyValidator | `0x6810CfB7c72D16e044a17694fAa8076e517264D0` |
| ForceExitModule | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` |
| Delegate | `0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0` |
| ParserRegistry | `0x7dEea4544446826601014bD94d0F6432A67496F5` |

## Deployment transactions

| Step | Tx | Gas |
|---|---|---|
| impl | [`0x1b69ca46…eeacb4`](https://sepolia.etherscan.io/tx/0x1b69ca460516e6fb89f85dc3b88761f48f3b0659e5f070b0a0a8c5749eeeacb4) | 10,369,599 |
| factory | [`0x54b23750…5b4d81`](https://sepolia.etherscan.io/tx/0x54b237501dbd311c2c0ae1804b37a4b72e177d8d6e0eb09d74081783535b4d81) | 3,038,556 |
| agentRegistry | [`0x5bef9a52…f9ba68`](https://sepolia.etherscan.io/tx/0x5bef9a52773a6471b44df99dc587bcba241304cd6188fb665146d6685fb9ba68) | 808,200 |
| bindFactory | [`0xc5475e1f…d697d26`](https://sepolia.etherscan.io/tx/0xc5475e1f29814bf3c85288fbf62039dcfa3f12dfdc0ca3adc42071b46d697d26) | 48,000 |
| setAgentRegistry | [`0xe16e5b30…4b295a6`](https://sepolia.etherscan.io/tx/0xe16e5b30e1c33e2068c1d299aa6faafdcbbd7314ef2af38c259f106c44b295a6) | 47,839 |

## On-chain verification

- `impl.ACCOUNT_VERSION()` → `"0.23.0"` ✓
- `impl.validatorRouter()` → `0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11` ✓

## On-chain E2E — isValidOwnerAuth (`scripts/e2e-isvalidownerauth-v0.23.0.ts`)

Test account `0x04332bdb1Bdfb6a51DafE85388121AB09D89afD1` (salt 230001, direct mode),
createAccount tx [`0x01310de0…a07ecb`](https://sepolia.etherscan.io/tx/0x01310de0ebb34dc30014d32f6118f473820f1f2fd67bed8526d6aa2078a07ecb).

| Case | ownerAuth | Result |
|---|---|---|
| owner ECDSA `personal_sign` | `0x01 ‖ sig` | `0xa0cf00cf` (magic) ✓ |
| wrong signer | `0x01 ‖ sig(stranger)` | `0xffffffff` ✓ |
| unknown tag | `0x03 ‖ …` | `0xffffffff` ✓ |
| empty | `0x` | `0xffffffff` ✓ |

**4/4 pass.** WebAuthn branch (tag `0x02`) covered by 17 unit tests + fail-closed fuzz (10k runs);
exercised on-chain with a real device passkey in the three-repo SDK integration E2E (aastar-sdk#261).
