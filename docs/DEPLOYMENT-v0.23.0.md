# Deployment — v0.23.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-07-01 · **Blocks:** 11178704–11178708
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
>
> Branch rebased onto `main` (PR #158) before deploy, so this factory retains the
> `getConfigHash` / `hashCreateAccount` relay-mode helper views.

## Core addresses

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0xc5095E3B3b248007ef69E09F81F75612fBE629ce`](https://sepolia.etherscan.io/address/0xc5095E3B3b248007ef69E09F81F75612fBE629ce) |
| AAStarAirAccountV7 (impl) | [`0xc8D9803ebde03706926181b540220C5E58306Ef8`](https://sepolia.etherscan.io/address/0xc8D9803ebde03706926181b540220C5E58306Ef8) |
| AirAccountExtension (facet) | [`0x3Cb68b0c573608b4f9FF4b51ab33DB88ac495b17`](https://sepolia.etherscan.io/address/0x3Cb68b0c573608b4f9FF4b51ab33DB88ac495b17) |
| AgentRegistry | [`0xF21F9F50d72e2cb0D196AE92CF17F4A79d9b29a1`](https://sepolia.etherscan.io/address/0xF21F9F50d72e2cb0D196AE92CF17F4A79d9b29a1) |

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
| factory | [`0x38d7913a…67c0b`](https://sepolia.etherscan.io/tx/0x38d7913acf27f1f3b997213b0ff8b73833c430dbe0bce0e72e7d8e179b167c0b) | 3,080,376 |
| agentRegistry | [`0x33a637f2…c9d392`](https://sepolia.etherscan.io/tx/0x33a637f2c7927425151636c41395ee9b0040f3b82702b42a5a11cd7fabc9d392) | 808,200 |
| bindFactory | [`0xa9a69735…718a6d`](https://sepolia.etherscan.io/tx/0xa9a69735f1ad922f73badd91fa87d85c0e99c21150d5bf74a07b5d20e1718a6d) | 48,000 |
| setAgentRegistry | [`0x237701b7…4330f1a`](https://sepolia.etherscan.io/tx/0x237701b76c990693c1edc15ac0b2584d30131331f618b5daece6fd3514330f1a) | 47,839 |

(impl deployed in block 11178704.)

## On-chain verification

- `impl.ACCOUNT_VERSION()` → `"0.23.0"` ✓
- `impl.validatorRouter()` → `0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11` ✓
- `factory.FACTORY_VERSION()` → `"0.23.0"` ✓
- `factory.getConfigHash(...)` returns a hash (PR #158 relay-mode views present) ✓

## On-chain E2E — isValidOwnerAuth (`scripts/e2e-isvalidownerauth-v0.23.0.ts`)

Test account `0xDF8b5aEc09b3EfF9942d3A698BfCA5F0aa665513` (salt 230001, direct mode),
createAccount tx [`0xfda38d54…df89f0`](https://sepolia.etherscan.io/tx/0xfda38d543d0ab48ac4c379b9702172755c4b57f40cf54475a51cd23c0fdf89f0).

| Case | ownerAuth | Result |
|---|---|---|
| owner ECDSA `personal_sign` | `0x01 ‖ sig` | `0xa0cf00cf` (magic) ✓ |
| wrong signer | `0x01 ‖ sig(stranger)` | `0xffffffff` ✓ |
| unknown tag | `0x03 ‖ …` | `0xffffffff` ✓ |
| empty | `0x` | `0xffffffff` ✓ |

**4/4 pass.** WebAuthn branch (tag `0x02`) covered by 17 unit tests + fail-closed fuzz (10k runs);
exercised on-chain with a real device passkey in the three-repo SDK integration E2E (aastar-sdk#261).
