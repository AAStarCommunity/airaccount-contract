# Deployment — v0.20.0 (Sepolia)

**Network:** Sepolia (chainId 11155111) · **Date:** 2026-06-20 · **Blocks:** 11098656–11098665
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**EntryPoint:** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)
**Community guardian:** `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`
**Script:** `scripts/deploy-v0.20.ts` (`pnpm tsx scripts/deploy-v0.20.ts`; dry-run `DEPLOY_DRY_CHECK=1`)

> First on-chain deployment carrying the **P-256 / WebAuthn guardian** logic (#119). Earlier
> addresses (v0.18/v0.19) do NOT contain P-256 support — integrators must use the v0.20 addresses below.

## Core addresses

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0x99C9300d52EDD9f4B7135DEd1811fBa6FFa1DDC6`](https://sepolia.etherscan.io/address/0x99C9300d52EDD9f4B7135DEd1811fBa6FFa1DDC6) |
| **AAStarAirAccountV7** (implementation) | [`0xd51db7eB20FF99c8588281CBe1785681Bb17D473`](https://sepolia.etherscan.io/address/0xd51db7eB20FF99c8588281CBe1785681Bb17D473) |
| **AirAccountExtension** (auto-deployed by impl ctor) | [`0x5529f50811814E0a4966cFC21200DCeF9C3FCb5B`](https://sepolia.etherscan.io/address/0x5529f50811814E0a4966cFC21200DCeF9C3FCb5B) |
| AAStarValidator (router) | [`0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11`](https://sepolia.etherscan.io/address/0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11) |
| SessionKeyValidator (algId 0x08) | [`0x6810CfB7c72D16e044a17694fAa8076e517264D0`](https://sepolia.etherscan.io/address/0x6810CfB7c72D16e044a17694fAa8076e517264D0) |
| AAStarBLSAlgorithm (algId 0x01) | [`0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174`](https://sepolia.etherscan.io/address/0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174) |
| AAStarBLSAggregator | [`0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609`](https://sepolia.etherscan.io/address/0x35775df9a4f4dB42Ea0C46118a12dDd0cEc70609) |
| ForceExitModule | [`0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc`](https://sepolia.etherscan.io/address/0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc) |
| AirAccountDelegate | [`0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0`](https://sepolia.etherscan.io/address/0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0) |
| CalldataParserRegistry | [`0x7dEea4544446826601014bD94d0F6432A67496F5`](https://sepolia.etherscan.io/address/0x7dEea4544446826601014bD94d0F6432A67496F5) |
| AgentRegistry | [`0xbcE1163817EEBA2E07d39424427B10937bF1D121`](https://sepolia.etherscan.io/address/0xbcE1163817EEBA2E07d39424427B10937bF1D121) |

## Wiring transactions

| Step | Tx |
|---|---|
| `router.registerAlgorithm(0x01, blsAlgorithm)` | [`0xd7d1c782…`](https://sepolia.etherscan.io/tx/0xd7d1c78265a0f4be865e1faedaaade349855ad3c6ba1aae4cb46f8d5972e1d3a) |
| `router.registerAlgorithm(0x08, sessionKeyValidator)` | [`0xe9350d15…`](https://sepolia.etherscan.io/tx/0xe9350d151dda346c6222da1209a68f5bf46cf8e2193416afd616c53a2d2ff15d) |
| `agentRegistry.bindFactory(factory)` | [`0x5f2b0871…`](https://sepolia.etherscan.io/tx/0x5f2b08710cd5cec5095498a980b9b45902811d0aaf38b72522d4f7fe301b414a) |
| `factory.setAgentRegistry(agentRegistry)` | [`0x3209b643…`](https://sepolia.etherscan.io/tx/0x3209b643384ebe1f1b242c6e377c2c89cf17365820f992f31ecc998e4b4bc64c) |
| `blsAlgorithm.registerPublicKey(Node1)` | [`0xa820ffe3…`](https://sepolia.etherscan.io/tx/0xa820ffe37be4c1c67a1998468cb77f9c38a0cc133d0a94a1bc99399b4bb99c2f) |
| `blsAlgorithm.registerPublicKey(Node2)` | [`0x8c2c9db2…`](https://sepolia.etherscan.io/tx/0x8c2c9db2efba126cd3efe32b594a9be925fee7437d60293aae41550f541a65b0) |

Key creation txs: impl [`0xab08a765…`](https://sepolia.etherscan.io/tx/0xab08a7651bcdd4d87760edee59b016dd6ac0bcdd4b3169561adaa825ff6eb617) (gas 9,469,710),
factory [`0x081124d9…`](https://sepolia.etherscan.io/tx/0x081124d9cee8c67f8275d6b0fc70290db4d8f242ed4fb9f983959fa598c2d9f2) (gas 2,782,039).

## Notes
- Owner of `AAStarBLSAlgorithm` + `AAStarValidator` = deployer EOA (no Safe on testnet).
- Optional steps skipped: `setAggregator` (set `DEPLOY_SET_AGGREGATOR=1`), `addStake` (set `DEPLOY_ADD_STAKE_ETH=<n>`).
- Etherscan source verification: see `## Verification` once run (`forge verify-contract`).
- Mainnet GA TODO: two-step `transferOwnership(blsAlgorithm)` to the protocol Safe after key registration.
