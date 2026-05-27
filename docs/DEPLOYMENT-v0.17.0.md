# AirAccount Deployment Guide — v0.17.1 (2026)

> **Current release: tag `v0.17.1`** (diamond-lite EIP-170 fix + HIGH-3 content-keying + agent default-install + full ABI). Supersedes `v0.17.0` / `freeze/m9-v0.17.0` (commit `b8b9a7c`).
> The **deployable contract set is identical** to v0.17.0 — the v0.17.1 changes are internal to the account (the account now routes its cold ERC-8004/weight functions to `AirAccountExtension` via `fallback`+`delegatecall`, deployed inside the Factory constructor alongside the impl). No new top-level contract to deploy.
> This doc is the canonical, versioned record of **what gets deployed, in what order, how it is wired, and how to run it** on each chain. Keep one of these per release.

---

## 1. Target chains

| Chain | chainId | Key source | RPC |
|---|---|---|---|
| Sepolia | 11155111 | env `PRIVATE_KEY` (`.env.sepolia`) | `SEPOLIA_RPC_URL2` (URL1/Alchemy key `Bx4QRW1` is dead — use URL2/URL3) |
| OP Sepolia | 11155420 | env `PRIVATE_KEY` | `OP_SEPOLIA_RPC_URL` |
| OP Mainnet | 10 | **encrypted keystore** (`cast wallet`, password-prompted, manual) | `OP_MAINNET_RPC_URL` |

EntryPoint v0.7 is the **canonical** `0x0000000071727De22E5E9d8BAf0edAc6f37da032` on every chain.

---

## 2. What gets deployed (full set)

Single shared script: `script/DeployAirAccountV017.s.sol`. Deploys 14 contracts + the implementation (deployed inside the Factory constructor).

| # | Contract | Type | Why deployed | Ctor args |
|---|---|---|---|---|
| 1 | `AAStarBLSAlgorithm` | singleton | BLS aggregate verification (Tier 2/3 DVT co-sign) | none |
| 2 | `AAStarValidator` (router) | singleton | algId → algorithm routing; account's `validator` | none |
| 3 | `AAStarBLSAggregator` | singleton | ERC-4337 IAggregator for batched BLS UserOps | `(blsAlgorithm)` |
| 4 | `AirAccountCompositeValidator` | singleton | ERC-7579 validator (weighted/cumulative) — **Factory default validator** | none |
| 5 | `AgentSessionKeyValidator` | singleton | agent session keys (velocity + callTarget/selector scope) | none |
| 6 | `SessionKeyValidator` | singleton | session keys | none |
| 7 | `TierGuardHook` | singleton | ERC-7579 hook (tier + session-scope) — **Factory default hook** | none |
| 8 | `ForceExitModule` | singleton | L2 force-exit executor module | none |
| 9 | `AgentRegistry` | singleton | agent wallet↔identity; **SuperPaymaster `setAgentRegistries` target** | none |
| 10 | `AirAccountDelegate` | singleton | EIP-7702 EOA onboarding path | none |
| 11 | `CalldataParserRegistry` | singleton | DeFi calldata parser routing (opt-in) | none |
| 12 | `RailgunParser` | singleton | Railgun calldata parser | none |
| 13 | `UniswapV3Parser` | singleton | Uniswap V3 calldata parser | none |
| 14 | `AAStarAirAccountFactoryV7` | singleton | account factory (CREATE2/EIP-1167 clones) | `(entryPoint, communityGuardian, tokens[], configs[], composite#4, tierHook#7)` |
| — | `AAStarAirAccountV7` (impl) | per-factory | account logic; clones point here | deployed by Factory ctor |

### NOT deployed (intentionally)
- **AAStarGlobalGuard** — deployed *per account* by the Factory on `createAccount*`. Not a singleton.
- **ERC-8004 Identity/Reputation/Validation registries** — **external**, already deployed by the ERC-8004 team at deterministic CREATE2 addresses; referenced via `src/config/ERC8004Addresses.sol`. We never redeploy these.
- **EntryPoint v0.7** — canonical, immutable, already on every chain.

> No contract in the set is skipped. Parsers (11–13) are deployed even though they are opt-in (an account only uses them after `setParserRegistry`), because they are cheap, argless singletons and shipping them now avoids a second deploy when DeFi parsing is enabled.

---

## 3. Deploy order + wiring

The script performs these in one broadcast:

1. Deploy `AAStarBLSAlgorithm` (#1).
2. Deploy `AAStarValidator` (#2) → **`router.registerAlgorithm(0x01, blsAlgorithm)`** (wire BLS into the router).
3. Deploy `AAStarBLSAggregator(blsAlgorithm)` (#3).
4. Deploy #4–#13 (independent singletons).
5. Deploy `AAStarAirAccountFactoryV7(EntryPoint, communityGuardian, [], [], compositeValidator, tierGuardHook)` (#14) → constructor deploys the V7 implementation.

### Post-deploy wiring / initialization (not in the script — per integrator)
- **Account-level** (done by SDK / owner per account at/after `createAccount`): `setValidator(router)`, `setAggregator(blsAggregator)`, `setP256Key(x, y)` (passkey), `setParserRegistry(parserRegistry)` (if DeFi parsing wanted).
- **Per-chain ERC20 token limits**: `factory` is deployed with empty default token configs (chain-portable). Add per-chain stablecoin limits after deploy via the guard config path, or pass them in a chain-specific Factory deploy.
- **SuperPaymaster** (SP repo side): `setAgentRegistries(<AgentRegistry address from #9>, ...)` then run E2E G2.
- **Parser registry** (optional): `parserRegistry.setParser(protocolAddr, parser)` per chain.

### External dependency addresses (referenced, not deployed)
- EntryPoint v0.7: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (all chains)
- ERC-8004 (per `src/config/ERC8004Addresses.sol`):
  - Identity: mainnet `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` / testnet `0x8004A818BFB912233c491871b3d84c89A494BD9e`
  - Reputation: mainnet `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` / testnet `0x8004B663056A597Dffe9eCcC1965A193B7388713`
  - Validation: mainnet `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58` / testnet `0x8004Cb1BF31DAf7788923b405b754f57acEB4272`

---

## 4. How to run

> Foundry profile: `via_ir = true`, `optimizer_runs = 1` (EIP-170 headroom), solc 0.8.33, EVM cancun.
> The script uses `vm.startBroadcast()` with **no argument**, so the signing key comes from the forge CLI — same script for testnet (env key) and mainnet (keystore).

### Testnet — env private key (Sepolia / OP Sepolia)
```bash
set -a; . ./.env.sepolia; set +a   # loads PRIVATE_KEY, SEPOLIA_RPC_URL2, COMMUNITY_GUARDIAN_ADDRESS

# Sepolia
forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
  --rpc-url "$SEPOLIA_RPC_URL2" --private-key "$PRIVATE_KEY" --broadcast -vvvv \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"

# OP Sepolia
forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
  --rpc-url "$OP_SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast -vvvv
```

### Mainnet — encrypted keystore (OP Mainnet), manual password
```bash
# one-time: import the deployer key into an encrypted keystore
cast wallet import op-deployer --interactive

# deploy (prompts for the keystore password — manual, interactive)
forge script script/DeployAirAccountV017.s.sol:DeployAirAccountV017 \
  --rpc-url "$OP_MAINNET_RPC_URL" --account op-deployer --broadcast -vvvv \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

`COMMUNITY_GUARDIAN_ADDRESS` (env) is read by the script for the Factory's default 3rd guardian. Set it per chain before a production deploy.

### ⚠️ Known environment issue (macOS + proxy)
On the current dev macOS box, `forge script` fork-setup/broadcast fails with `Connection reset by peer (os error 54)` for **every** RPC (Alchemy URL2/URL3, public RPC, proxy on/off) — `cast` single calls work, but forge's larger fork-init connection is reset. Workarounds, in order of preference:
1. Run the **same forge script on Linux / CI** (GitHub Actions) where the network is unrestricted.
2. Resolve the local network (disable the interfering proxy/VPN/DPI for forge's traffic).
3. Fall back to the viem/TypeScript deploy scripts (`scripts/deploy-*.ts`), which use multi-RPC retry and are proven to work on this box (not forge, but produces the same deployment).

The deploy script's **logic is validated** via `forge script ... --sender <addr>` simulation (full summary printed) — only the network broadcast is blocked locally.

---

## 5. After deploy — record + propagate

1. **Record addresses** here (append a per-chain table below) and into `.env.<network>`.
2. **SuperPaymaster**: hand the `AgentRegistry` address to the SP team → they `setAgentRegistries(addr)` + run E2E G2.
3. **SDK sync** (`@aastar/sdk`, separate repo — the `lib/aastar-sdk` submodule was removed; the SDK consumes the contract's published ABIs directly, there is **no submodule pointer to bump**):
   - Export ABIs from `out/<Contract>.sol/<Contract>.json` (`.abi`) → commit to the SDK repo (`abis/`).
   - **For the account, use the merged `abi/AAStarAirAccountV7.full.json`** (run `node scripts/build-full-abi.mjs`), NOT the raw `out/AAStarAirAccountV7.sol` ABI. The account is diamond-lite: agent (ERC-8004) + weight-governance functions execute via fallback→delegatecall to `AirAccountExtension` and are absent from the raw account ABI; the full ABI merges them back so the SDK can encode them.
   - Update the SDK address config (`config.<network>.json`) with the deployed addresses.
   - Bump the SDK version in the SDK repo + open its PR (e.g. SDK PR #29). Nothing to commit back here.
4. **E2E**: run the relevant `scripts/test-e2e-*.ts` against the new addresses.

### Deployed addresses — Sepolia (chainId 11155111)
_(fill in after a successful broadcast)_

| Contract | Address |
|---|---|
| BLS Algorithm | `0x…` |
| Validator Router | `0x…` |
| BLS Aggregator | `0x…` |
| Composite Validator | `0x…` |
| AgentSession Validator | `0x…` |
| SessionKey Validator | `0x…` |
| TierGuard Hook | `0x…` |
| ForceExit Module | `0x…` |
| **Agent Registry** | `0x…` |
| AirAccount Delegate | `0x…` |
| Parser Registry | `0x…` |
| Railgun Parser | `0x…` |
| UniswapV3 Parser | `0x…` |
| Factory V7 | `0x…` |
| Implementation (V7) | `0x…` |

### Deployed addresses — OP Sepolia (11155420) / OP Mainnet (10)
_(add tables as deployed)_
