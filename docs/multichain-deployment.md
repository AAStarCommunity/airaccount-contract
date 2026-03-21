# AirAccount Multi-Chain Deployment

> Generated: 2026-03-21T09:29:29.058Z
> Deployer: Uses `PRIVATE_KEY` from env.

## Deployed Addresses

| Chain | ChainId | CompositeValidator | TierGuardHook | ForceExitModule | Factory | Status |
|-------|---------|-------------------|---------------|-----------------|---------|--------|
| sepolia | 11155111 | `0xcb1c326418d1fd5f4091eedc3c44c74432e028b2` | `0x796130093ae0ddbef9b28d41bb58ab5a77160483` | `0xb888bd8029551d3cdf93e34273626c65c48a5c35` | `0xa734c99cb16c207650da151b0086e11186608804` | ✅ |
| base-sepolia | 84532 | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | ⏭️ skipped |
| op-sepolia | 11155420 | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` | ⏭️ skipped |

## Contract Roles

| Contract | Module Type | Purpose |
|----------|-------------|---------|
| AirAccountCompositeValidator | Validator (type 1) | Weighted/cumulative signature validation |
| TierGuardHook | Hook (type 3) | Tier-based spending limit enforcement |
| ForceExitModule | Executor (type 2) | L2→L1 forced withdrawal with 2-of-3 guardian protection |
| AAStarAirAccountV7 | Implementation | Shared implementation for EIP-1167 clones |
| AAStarAirAccountFactoryV7 | Factory | Deterministic clone factory with default modules |

## Notes

- All contracts deployed via [Arachnid CREATE2 factory](https://github.com/Arachnid/deterministic-deployment-proxy) for deterministic addresses.
- Addresses may differ across chains due to `chainId` in the salt derivation.
- ForceExitModule supports OP Stack (L2_TYPE=1) and Arbitrum (L2_TYPE=2) exit paths.
- EntryPoint: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (ERC-4337 v0.7)
