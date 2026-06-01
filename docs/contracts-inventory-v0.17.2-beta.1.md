# AirAccount v0.17.2-beta.1 — Contracts Deployment Inventory

> Companion to `docs/DEPLOYMENT-v0.17.1.md`. This file enumerates **every** concrete contract that must be deployed for `v0.17.2-beta.1`, gives its constructor signature, its dependencies, and the post-deploy wiring steps.
>
> **Diff vs `v0.17.1`** is called out per row: the v0.17.2-beta.1 release **removes** three previously-deployed singletons (`AirAccountCompositeValidator`, `TierGuardHook`, `AgentSessionKeyValidator`) and adds **no new singleton** — the unified `SessionKeyValidator` (algId `0x08`) absorbs all session-key features. Net: 14 deployed singletons in v0.17.1 → **11** in v0.17.2-beta.1 (impl V7 still auto-deployed inside the factory constructor, `AirAccountExtension` still auto-deployed inside the V7 implementation constructor; `AAStarGlobalGuard` still per-account).
>
> Source of truth for algorithm IDs: `src/core/AAStarAirAccountBase.sol` constants (`ALG_BLS=0x01`, `ALG_ECDSA=0x02`, `ALG_P256=0x03`, `ALG_CUMULATIVE_T2=0x04`, `ALG_CUMULATIVE_T3=0x05`, `ALG_COMBINED_T1=0x06`, `ALG_WEIGHTED=0x07`, `ALG_SESSION_KEY=0x08`).

---

## 1. External dependencies (NOT deployed by us)

These must already exist on the target chain. The deploy script does not deploy or attempt to verify them — it only references their addresses.

| # | Dependency | Address | Notes |
|---|---|---|---|
| E1 | EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Canonical, immutable, identical on every chain. Read via env `ENTRY_POINT_07` (defaults to canonical). |
| E2 | EIP-7212 P256 precompile | `0x0000000000000000000000000000000000000100` | Hard-wired in `SessionKeyValidator` (`P256_VERIFIER`) and in `AAStarAirAccountBase`. Must be enabled on the target chain (Sepolia ✅, OP-Sepolia ✅, OP-Mainnet ✅ at the time of writing). Read via env `P256_VERIFIER` for sanity-logging only — not constructor-passed. |
| E3 | ERC-8004 Identity Registry | mainnet `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` / testnet `0x8004A818BFB912233c491871b3d84c89A494BD9e` | Hard-coded inside `src/config/ERC8004Addresses.sol`. Not constructor-passed. |
| E4 | ERC-8004 Reputation Registry | mainnet `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` / testnet `0x8004B663056A597Dffe9eCcC1965A193B7388713` | As above. |
| E5 | ERC-8004 Validation Registry | mainnet `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58` / testnet `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` | As above. |

---

## 2. Concrete contracts that need deployment (v0.17.2-beta.1 full set)

11 singletons + 1 auto-deployed implementation inside the factory constructor + 1 auto-deployed `AirAccountExtension` inside the V7 implementation constructor.

| # | Contract | File | New vs v0.17.1 | Constructor signature | Constructor args (meaning) | CREATE2? |
|---|---|---|---|---|---|---|
| 1 | `AAStarBLSAlgorithm` | `src/validators/AAStarBLSAlgorithm.sol` | reused (identical) | `constructor()` | none | no |
| 2 | `AAStarValidator` (router) | `src/validators/AAStarValidator.sol` | reused (identical) | `constructor()` | none. `owner = msg.sender` set inline. | no |
| 3 | `AAStarBLSAggregator` | `src/aggregator/AAStarBLSAggregator.sol` | reused (identical) | `constructor(address _blsAlgorithm)` | `_blsAlgorithm` — address of #1; the aggregator queries it to verify aggregated BLS sigs. | no |
| 4 | `SessionKeyValidator` | `src/validators/SessionKeyValidator.sol` | **changed (unified — replaces deleted `AgentSessionKeyValidator` + features merged in)** | `constructor()` (default) | none. Stateless besides per-account session mappings. | no |
| 5 | `ForceExitModule` | `src/core/ForceExitModule.sol` | reused (logic patched M-2; same deployment shape) | `constructor()` (default) | none. | no |
| 6 | `AirAccountDelegate` | `src/core/AirAccountDelegate.sol` | reused (identical) | implicit (default — no explicit constructor). | none. EOA calls `initialize()` after EIP-7702 delegation. | no |
| 7 | `CalldataParserRegistry` | `src/core/CalldataParserRegistry.sol` | reused (identical) | `constructor()` | none. `owner = msg.sender`. | no |
| 8 | `RailgunParser` | `src/parsers/RailgunParser.sol` | reused (identical) | implicit default | none. | no |
| 9 | `UniswapV3Parser` | `src/parsers/UniswapV3Parser.sol` | reused (identical) | implicit default | none. | no |
| 10 | `AAStarAirAccountFactoryV7` | `src/core/AAStarAirAccountFactoryV7.sol` | **changed (constructor signature SAME; internals dropped `defaultValidatorModule`/`defaultHookModule`/`agentSessionKeyValidator` machinery — M-1/M-3)** | `constructor(address _entryPoint, address _communityGuardian, address[] memory defaultTokens, AAStarGlobalGuard.TokenConfig[] memory defaultConfigs)` | `_entryPoint`=E1; `_communityGuardian`=Safe multisig (env `COMMUNITY_GUARDIAN_ADDRESS`); `defaultTokens`/`defaultConfigs`=per-chain ERC-20 token spending limits (deploy script passes empty arrays — chain-portable; chain-specific configs are pushed via a follow-up `setAgentRegistry`-style governance txn or via per-chain script). Inside the constructor: `implementation = new AAStarAirAccountV7()` (auto). | no |
| 11 | `AgentRegistry` | `src/registries/AgentRegistry.sol` | **changed (constructor now takes NO args; factory bound post-deploy via `bindFactory` — H-2 round 2)** | `constructor()` | none. `deployer = msg.sender` is set inline; factory is bound post-deploy. | no |
| — | `AAStarAirAccountV7` (impl) | `src/core/AAStarAirAccountV7.sol` | reused (logic patched: `accountId()`→`airaccount.v7@0.17.2`; L-1 cursor check; inlined scope+velocity calls) | `constructor()` (default — inherited from `AAStarAirAccountBase`) | none (but its constructor itself `new`s an `AirAccountExtension`). | auto, inside factory ctor |
| — | `AirAccountExtension` | `src/core/AirAccountExtension.sol` | reused (identical) | default | none. | auto, inside V7 impl ctor |
| — | `AAStarGlobalGuard` | `src/core/AAStarGlobalGuard.sol` | reused (identical) | `constructor(address _account, uint256 _dailyLimit, uint8[] memory _approvedAlgIds, uint256 _minDailyLimit, address[] memory _initialTokens, AAStarGlobalGuard.TokenConfig[] memory _initialTokenConfigs)` | bound to a single account; deployed by factory per `createAccount*` call. NOT deployed by the release script. | per-account |

### Deleted in v0.17.2 (do NOT redeploy)
- `src/validators/AirAccountCompositeValidator.sol` — deleted.
- `src/validators/AgentSessionKeyValidator.sol` — deleted; features absorbed into `SessionKeyValidator`.
- `src/core/TierGuardHook.sol` — deleted.

---

## 3. Dependencies (deploy DAG)

DAG depth = 3. The only edges that constrain order are:
- `AAStarBLSAggregator (#3)` → needs `AAStarBLSAlgorithm (#1)` address.
- Router wiring `registerAlgorithm(0x01, …)` (#2) → needs `AAStarBLSAlgorithm (#1)`.
- Router wiring `registerAlgorithm(0x08, …)` (#2) → needs `SessionKeyValidator (#4)`.
- `AgentRegistry.bindFactory(factory)` → needs `AAStarAirAccountFactoryV7 (#10)`.
- `factory.setAgentRegistry(agentRegistry)` → needs `AgentRegistry (#11)`.
- The factory↔registry circular dependency is broken by deploying the **factory first** (its constructor needs neither registry nor session-key validator) and the **registry second** (its constructor needs no factory address — `bindFactory` is called as a separate post-deploy step).

### Numbered deployment order (linear DAG)

1. Deploy `AAStarBLSAlgorithm` (#1).
2. Deploy `AAStarValidator` (#2) — router.
3. **Wire**: `router.registerAlgorithm(0x01, blsAlgorithm)`.
4. Deploy `AAStarBLSAggregator(blsAlgorithm)` (#3).
5. Deploy `SessionKeyValidator` (#4).
6. **Wire**: `router.registerAlgorithm(0x08, sessionKeyValidator)`.
7. Deploy `ForceExitModule` (#5).
8. Deploy `AirAccountDelegate` (#6).
9. Deploy `CalldataParserRegistry` (#7).
10. Deploy `RailgunParser` (#8).
11. Deploy `UniswapV3Parser` (#9).
12. Deploy `AAStarAirAccountFactoryV7(EntryPoint, communityGuardian, [], [])` (#10) — its constructor auto-deploys `AAStarAirAccountV7` impl, which auto-deploys `AirAccountExtension`.
13. Deploy `AgentRegistry` (#11).
14. **Wire**: `agentRegistry.bindFactory(factory)`.
15. **Wire**: `factory.setAgentRegistry(agentRegistry)`.

### Post-deploy wiring count
**4** wiring transactions (#3, #6, #14, #15) — all of which are performed by the deploy script's `wireAll()` step. No CREATE2/`setupComplete`/governance call is done in this script (these are decisions for the deployer post-broadcast).

### Wiring NOT performed by the script (deferred to operators)
- `router.finalizeSetup()` — locks direct `registerAlgorithm`. Decision: leave **unlocked** for beta-1 so additional algorithms (e.g. EIP-7702 specific) can be added without timelock during the beta cycle. Operator runs this once before the final v0.17.2 GA tag.
- Per-chain ERC-20 token default configs for the factory — passed as empty arrays in the script; if a chain wants stablecoin defaults baked into `createAccountWithDefaults`, the factory must be redeployed on that chain with non-empty `defaultTokens`/`defaultConfigs`. Out of scope for this release script.
- `parserRegistry.setParser(...)` — opt-in by account; not done at deploy time.
- SuperPaymaster `setAgentRegistries(<AgentRegistry>)` — handed off out-of-band to the SP team.
- Account-level: `setValidator(router)`, `setAggregator(blsAggregator)`, `setP256Key(x,y)`, `setParserRegistry(parserRegistry)` — per-account at/after `createAccount*` by the SDK.

---

## 4. Algorithm ID registry — what is + is not registered in the router

| algId | Name | Implementation location | Registered in router? |
|---|---|---|---|
| `0x01` | BLS | `AAStarBLSAlgorithm.sol` (separate contract) | **yes, by script** (`router.registerAlgorithm(0x01, blsAlgorithm)`) |
| `0x02` | ECDSA | inlined in `AAStarAirAccountBase._validateSignature` | no — handled inline |
| `0x03` | P256 | inlined in `AAStarAirAccountBase._validateSignature` (via EIP-7212 precompile at E2) | no — handled inline |
| `0x04` | Cumulative T2 (P256 + BLS) | inlined in base | no — handled inline (BLS portion routes through `AAStarValidator` for the algorithm contract) |
| `0x05` | Cumulative T3 (P256 + BLS + Guardian) | inlined in base | no — handled inline |
| `0x06` | Combined T1 (P256 + ECDSA zero-trust) | inlined in base | no — handled inline |
| `0x07` | Weighted (resolves to 0x02/0x04/0x05 at runtime) | inlined in base | no — handled inline |
| `0x08` | SessionKey | `SessionKeyValidator.sol` (separate contract) | **yes, by script** (`router.registerAlgorithm(0x08, sessionKeyValidator)`) |

> The script registers **only** `0x01` and `0x08`. Algorithms `0x02`–`0x07` need no router entry because `AAStarAirAccountBase._validateSignature` handles them inline before falling through to `validator.validateSignature(...)`. The `factory._buildDefaultConfig` whitelist still includes all 8 algIds (`0x01`…`0x08`) — this lives in the account's `approvedAlgIds`, separate from the router. **Tier boundary** values (per-tier USD spend thresholds) are part of `AAStarGlobalGuard.TokenConfig` and are configured per account, not per router — the script does not set any tier boundary.

---

## 5. Constructor argument resolution from env

| Env var | Consumer | Default if unset |
|---|---|---|
| `DEPLOYER_KEY` (or signer source) | `vm.startBroadcast()` | required — fails the broadcast otherwise |
| `ENTRY_POINT_07` | `factory` ctor arg `_entryPoint` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (canonical) |
| `P256_VERIFIER` | sanity-log only | `0x0000000000000000000000000000000000000100` |
| `COMMUNITY_GUARDIAN_ADDRESS` | `factory` ctor arg `_communityGuardian` | `address(0)` (with a `WARN` log line) |

---

## 6. Verification checklist after deploy

(operator-facing — script auto-emits the values via `console2.log("Deployed <Name>: <addr>")`)

- [ ] `router.algorithms(0x01) == blsAlgorithm`
- [ ] `router.algorithms(0x08) == sessionKeyValidator`
- [ ] `factory.implementation() == <V7 impl>` (set in factory constructor)
- [ ] `factory.agentRegistry() == agentRegistry`
- [ ] `agentRegistry.factory() == factory`
- [ ] `agentRegistry.deployer() == <broadcaster>`
- [ ] `AAStarAirAccountV7(factory.implementation()).agentExtension() != address(0)` (the AirAccountExtension singleton)
- [ ] EntryPoint v0.7 has code at `0x0000000071727De22E5E9d8BAf0edAc6f37da032` on the target chain.
- [ ] EIP-7212 P256 precompile responds at `0x100` (call `staticcall(0x100, …)` with a known test vector).
