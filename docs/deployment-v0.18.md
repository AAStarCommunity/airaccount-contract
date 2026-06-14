# Deployment — v0.18 (Sepolia)

**Date**: 2026-06-14
**Base**: v0.17.2-beta.4 (full stack redeploy — non-upgradable account, so a new factory + implementation is mandatory)
**Scope**: full 10-contract redeploy + 6 wiring transactions. All WS-A/B/C/D/E/F/G branches plus the #45 CRITICAL BLS↔userOpHash binding and the factory EIP-3860 fix are live.
**Deployer (PRIVATE_KEY_ANNI)**: `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
**Community**: `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`
**Owner of AAStarBLSAlgorithm + AAStarValidator**: deployer EOA (no Safe on testnet — see Mainnet-GA TODO).

Addresses are also recorded in `.env.sepolia` as `AIRACCOUNT_V018_*`.

## Sepolia addresses (v0.18)

| Contract | Address |
|----------|---------|
| EntryPoint v0.7 | [`0x0000000071727De22E5E9d8BAf0edAc6f37da032`](https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032) (canonical) |
| Factory (`AAStarAirAccountFactoryV7`) | [`0xB14a870e4f63CA21a7EB753588CC4eBFb429E163`](https://sepolia.etherscan.io/address/0xB14a870e4f63CA21a7EB753588CC4eBFb429E163) |
| Implementation (`AAStarAirAccountV7`) | [`0x1Bc1119e3Ce4B6D158a6eadb31A06FdcE51992cF`](https://sepolia.etherscan.io/address/0x1Bc1119e3Ce4B6D158a6eadb31A06FdcE51992cF) |
| Extension (`AirAccountExtension`) | [`0xB1B3acd47DB89806F8431da3452769f1243b4d56`](https://sepolia.etherscan.io/address/0xB1B3acd47DB89806F8431da3452769f1243b4d56) |
| BLSAlgorithm (`AAStarBLSAlgorithm`) | [`0x2869EEb04218ca666c6373c0DC5aCDa04F00adFA`](https://sepolia.etherscan.io/address/0x2869EEb04218ca666c6373c0DC5aCDa04F00adFA) |
| BLSAggregator (`AAStarBLSAggregator`) | [`0x9AD55930B77C002dF884F4dac846D2077CDA7C8b`](https://sepolia.etherscan.io/address/0x9AD55930B77C002dF884F4dac846D2077CDA7C8b) |
| ValidatorRouter (`AAStarValidator`) | [`0xe785AF830aD33F3E550FfdC0fEB81D42507DA39D`](https://sepolia.etherscan.io/address/0xe785AF830aD33F3E550FfdC0fEB81D42507DA39D) |
| SessionKeyValidator | [`0x82f16163D0fb9c4dd7507b9999B79527a795291C`](https://sepolia.etherscan.io/address/0x82f16163D0fb9c4dd7507b9999B79527a795291C) |
| ForceExitModule | [`0x0F6960526acf4cF9123e0aBc82d7a59fA0B6C934`](https://sepolia.etherscan.io/address/0x0F6960526acf4cF9123e0aBc82d7a59fA0B6C934) |
| AirAccountDelegate (EIP-7702) | [`0x70A8E31c425Ef3F23a2F9E05C48Bd998Aa29085b`](https://sepolia.etherscan.io/address/0x70A8E31c425Ef3F23a2F9E05C48Bd998Aa29085b) |
| AgentRegistry | [`0x118eD73f22e41cb69282c78b216426D2d98A3935`](https://sepolia.etherscan.io/address/0x118eD73f22e41cb69282c78b216426D2d98A3935) |
| CalldataParserRegistry | [`0x5dEE2c5279eFfC7c7FE711233bE42726EE0d4166`](https://sepolia.etherscan.io/address/0x5dEE2c5279eFfC7c7FE711233bE42726EE0d4166) |

## Deploy method

```bash
# Requires .env.sepolia with PRIVATE_KEY_ANNI, SEPOLIA_RPC_URL*, BLS_TEST_* node keys
pnpm tsx scripts/deploy-v0.18.ts
```

Deployment is done with **TypeScript + viem**, not `forge script`. On macOS `forge script` / `forge create`
fail with `Internal transport error: Socket operation on non-socket`; the viem path is the supported one
(`cast send` and raw `curl` RPC also work, but the full deploy is scripted in TS). Project convention: **pnpm**, **viem** — never npm / ethers.

### Factory constructor (NEW in v0.18 — #82 EIP-3860 fix)

`AAStarAirAccountFactoryV7(implementation, entryPoint, community, validators[], algorithms[])` —
the **implementation is now injected as constructor arg 1** instead of being deployed by the factory
in its own constructor. This shrinks the factory initcode from 49,134 → 13,324 bytes, well under the
EIP-3860 initcode cap. SDKs and deploy scripts MUST pass a pre-deployed implementation address.

## Wiring (6 transactions, all on-chain)

| # | Call | Purpose |
|---|------|---------|
| 1 | `router.registerAlgorithm(0x01, blsAlgorithm)` | BLS triple-sig path |
| 2 | `router.registerAlgorithm(0x08, sessionKeyValidator)` | unified session-key validator |
| 3 | `agentRegistry.bindFactory(factory)` | factory-provenance whitelist (set-once, deployer-only) |
| 4 | `factory.setAgentRegistry(agentRegistry)` | agent-account default install target |
| 5 | `blsAlgorithm.registerPublicKey(node1)` | DVT BLS node #1 public key |
| 6 | `blsAlgorithm.registerPublicKey(node2)` | DVT BLS node #2 public key |

## Deploy decisions (testnet)

- **owner = deployer EOA** — no Gnosis Safe on testnet. `AAStarBLSAlgorithm` + `AAStarValidator` are
  EOA-owned for now; both use two-step ownership (`Ownable2Step`) so the mainnet handover to the
  protocol Safe is fat-finger-safe.
- **`setAggregator` SKIPPED** — `AAStarBLSAlgorithm.aggregator() == address(0)` at deploy, so BLS runs
  inline single-op binding everywhere. The batch path is opt-in (`DEPLOY_SET_AGGREGATOR=1`) and is
  Safe-only on mainnet. The aggregator is a single protocol-level value on `AAStarBLSAlgorithm`, not a
  per-account field (see [`docs/issue45-fix1-yaa-changes.md`](issue45-fix1-yaa-changes.md) §"Aggregator selection").
- **`addStake` SKIPPED** — set `DEPLOY_ADD_STAKE_ETH=<n>` to stake on the EntryPoint. Not required for
  the testnet single-op path.

## E2E results (on-chain, against live v0.18 — 2026-06-14)

Phases 13–16 (WS-A/B/C/G) all green on-chain. Per-test TX hashes are appended to
[`docs/e2e-results-v0.17.2-beta.3.md`](e2e-results-v0.17.2-beta.3.md); coverage matrix in
[`docs/e2e-coverage-matrix.md`](e2e-coverage-matrix.md).

| Phase | Suite | Result |
|-------|-------|--------|
| 13 | `13-ws-a-module-nonce` — module-management-nonce replay defence (#75) | 8/8 PASS (stale sig0 → exact `NotGuardian()`) |
| 14 | `14-ws-b-forceexit-toctou` — ForceExit approver TOCTOU (#70) | 7/7 PASS (rotated-out approver → exact `ApproverNoLongerGuardian()`) |
| 15 | `15-ws-c-sessionkey-cap-velocity` — session-key cap + velocity (#83/#57) | 4/4 PASS + 1 opt-in SKIP (51-key cap = `RUN_FULL_CAP_TEST=1`, 50+ txs) |
| 16 | `16-ws-g-p256-low-s` — P256 low-S guard (#78) | 6/6 PASS (2 precompile + 4 account: low-S → validationData 0; high-S `(r, n-s)` → 1 rejected by the account guard, precompile itself accepts both) |

```bash
pnpm tsx scripts/e2e-v0172/13-ws-a-module-nonce.ts
pnpm tsx scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts
pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts
pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts
```

## Test status

- **799** forge tests pass under `evm_version = cancun` (repo default).
- **22** additional `#45` BLS↔userOpHash binding tests pass under `--evm-version prague`
  (`HashToG2GoldenTest | BLSReplayBindingTest | AAStarBLSAggregatorTest`) — these exercise the
  EIP-2537 precompiles (G2ADD `0x0d`, MAP_FP2_TO_G2 `0x11`) that don't exist under cancun, so they
  self-skip there and run in the dedicated CI `bls-binding-prague` job.

## Mainnet-GA TODO

- [ ] **Stake the BLS singletons** on the EntryPoint (ERC-7562 requires staked entities to read
      account storage during validation). Note: `addStake` stakes the *caller* EOA, not the contract —
      the BLS singletons currently have no self-stake path, so this needs a contract `addStake` fn or an
      alternative approach.
- [ ] **`transferOwnership` → protocol Gnosis Safe** (two-step `Ownable2Step`: `transferOwnership` then
      `acceptOwnership` from the Safe) for `AAStarBLSAlgorithm` and `AAStarValidator`, after node-key
      registration is complete.
- [ ] **`setAggregator`** to the deployed `AAStarBLSAggregator` to enable the batch BLS path (Safe-only).
- [ ] Paid external security audit + live bug bounty before any mainnet deployment.

## Related docs

- [`docs/issue45-fix1-yaa-changes.md`](issue45-fix1-yaa-changes.md) — #45 BLS↔userOpHash binding: new wire formats + required SDK/DVT changes.
- [`docs/abi/reference.md`](abi/reference.md) · [`docs/abi/selectors.md`](abi/selectors.md) · [`docs/abi/capabilities.md`](abi/capabilities.md) — generated ABI reference (regenerate with `pnpm gen:abi-docs`).
- [`abi/AAStarAirAccountV7.full.json`](../abi/AAStarAirAccountV7.full.json) — merged diamond-lite ABI for SDK encoding.
</content>
</invoke>
