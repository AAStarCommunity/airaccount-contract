# AirAccount Smart Contract

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
A privacy-first, non-upgradable ERC-4337 smart wallet for mobile crypto payments. Tiered security based on transaction value, social recovery via guardians, gasless transactions via paymasters, and hardware-bound passkey (P256/WebAuthn) authentication.

> ## Status: v0.17.1 (current)
>
> Current line: tag [`v0.17.1`](https://github.com/AAStarCommunity/airaccount-contract/releases/tag/v0.17.1). It builds on the **M8** (ERC-8004 official integration + autonomous agent accounts) and **M9** (security hardening: factory front-run, ERC-1271, BLS/tier checks, ERC-7579 hook typeId, executor Tier-1 ceiling) work tagged at `v0.17.0`, and adds:
> - **EIP-170 diamond-lite fix**: `AAStarAirAccountV7` was over the 24,576-byte runtime limit (undeployable on real chains). The cold functions (ERC-8004 agent + weighted-signature config governance) moved into a singleton **`AirAccountExtension`**, reached via `fallback`+`delegatecall` (zero capability loss; storage layout byte-identical, verified). Account runtime: 27,975 → **21,872 B**.
> - **HIGH-3 fix**: the transient validation queue is now content-keyed (`keccak256(callData)`), revert-safe across a same-account bundle.
> - **Agent default-install (hybrid)**: agent accounts (`createAgentAccount`) default-install `AgentSessionKeyValidator`; regular accounts opt-in.
>
> Full test suite green (**798 tests**); deployed on Sepolia + OP Sepolia.
>
> ⚠️ **Integrators / SDK**: the account is now *diamond-lite* — the agent + weight-governance functions execute via fallback and are **absent from the raw `out/AAStarAirAccountV7.sol` ABI**. Use the merged **[`abi/AAStarAirAccountV7.full.json`](abi/AAStarAirAccountV7.full.json)** (run `scripts/build-full-abi.mjs`) to encode them. See [`docs/2026-05-26-diamond-lite-migration-impact.md`](docs/2026-05-26-diamond-lite-migration-impact.md).

---

## Quick Start

```bash
forge build
forge test --summary          # 622 tests
pnpm tsx scripts/test-m7-e2e.ts          # M7 full E2E (Sepolia)
pnpm tsx scripts/test-force-exit-e2e.ts  # M7.5 ForceExit E2E (OP Sepolia)
pnpm tsx scripts/test-railgun-parser-e2e.ts  # M7.11 Railgun E2E (Sepolia)
```

---

## Contracts (v0.17.1 — full list)

What AirAccount ships and what each contract does. **Deploy** column: `singleton` = deployed once per chain (shared); `per-account` = created on demand; `per-factory` = created by the Factory; `external` = not ours, referenced at a known address.

### Core
| Contract | Role | Deploy |
|---|---|---|
| `AAStarAirAccountV7` | Non-upgradable ERC-4337 v0.7 account: algId signature routing, tiered verification, social recovery, ERC-7579 module surface, IERC721Receiver. **Diamond-lite**: routes agent (ERC-8004) + weight-governance selectors to `AirAccountExtension` via `fallback`+`delegatecall` | per-factory (impl; users are clones) |
| `AAStarAirAccountBase` | Shared account logic inherited by V7 (signature validation, tiers, recovery, guard enforcement, fallback routing) | abstract (not deployed) |
| `AirAccountExtension` | **Diamond-lite facet** (v0.17.1): ERC-8004 agent (identity/reputation/wallet binding) + weighted-signature config governance. Reached via the account's `fallback`+`delegatecall` — runs in the account's storage context; split out to keep the account under EIP-170 | singleton (per impl) |
| `AAStarAgentStorageLayout` | Shared storage prefix (slots 0–23) inherited by both `AAStarAirAccountBase` and `AirAccountExtension` so delegatecall slots align | abstract (not deployed) |
| `AAStarAirAccountFactoryV7` | CREATE2 / EIP-1167 clone factory; config-bound salt (front-run safe); `createAccountWithDefaults` / `createAgentAccount` (agent accounts default-install `AgentSessionKeyValidator` once `setAgentSessionKeyValidator` is configured — deployer-only, set-once) | singleton |
| `AAStarGlobalGuard` | Immutable per-account spending guard: daily limits, ERC20 token limits, algorithm whitelist (monotonic tighten-only) | per-account |
| `AirAccountDelegate` | EIP-7702 path: turn an existing EOA into an AirAccount (guardian rescue, daily limit) | singleton |

### Validators / signature algorithms
| Contract | Role | Deploy |
|---|---|---|
| `AAStarValidator` | Algorithm router: algId → algorithm address | singleton |
| `AAStarBLSAlgorithm` | BLS aggregate signature verification (DVT co-sign) | singleton |
| `AAStarBLSAggregator` | ERC-4337 IAggregator for batched BLS UserOps | singleton |
| `AirAccountCompositeValidator` | ERC-7579 validator: weighted / cumulative composite signatures (Factory default validator) | singleton |
| `SessionKeyValidator` | Time-limited scoped session keys (algId 0x08) | singleton |
| `AgentSessionKeyValidator` | Agent session keys: velocity limit + callTarget/selector allowlist (prompt-injection defense) | singleton |

**Signature algorithms (algId):** ECDSA `0x02`, P256/WebAuthn `0x03`, Cumulative T2 (P256+BLS) `0x04`, Cumulative T3 (P256+BLS+Guardian) `0x05`, Combined T1 (P256∧ECDSA) `0x06`, Weighted multi-sig `0x07`, Session Key `0x08`, BLS triple `0x01`.

### Hooks / executor modules (ERC-7579)
| Contract | Role | Deploy |
|---|---|---|
| `TierGuardHook` | ERC-7579 hook (type 4): tier + session-scope enforcement on execute (Factory default hook) | singleton |
| `ForceExitModule` | Guardian-gated L2→L1 force exit (OP Stack / Arbitrum) | singleton |

### Registries
| Contract | Role | Deploy |
|---|---|---|
| `AgentRegistry` | Maps agent execution wallet ↔ identity; SuperPaymaster `setAgentRegistries` target | singleton |

### DeFi calldata parsers (opt-in via `setParserRegistry`)
| Contract | Role | Deploy |
|---|---|---|
| `CalldataParserRegistry` | Routes a target contract → its parser | singleton |
| `UniswapV3Parser` / `RailgunParser` | Decode swap/shield calldata so the guard sees real token/amount | singleton |

### External dependencies (referenced, not deployed by us)
| Contract | Address | Notes |
|---|---|---|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | canonical, all chains |
| ERC-8004 Identity / Reputation / Validation | see `src/config/ERC8004Addresses.sol` | official "Trustless Agents" registries, deterministic CREATE2 |

> Deployment order, wiring, and run commands: see [`docs/DEPLOYMENT-v0.17.1.md`](docs/DEPLOYMENT-v0.17.1.md).

---

## Milestone Status

| Milestone | Status | Factory (Sepolia) | Tests |
|-----------|--------|-------------------|-------|
| M1 — ECDSA | ✅ | `0x26Af93f34d6e3c3f08208d1e95811CE7FAcD7E7f` | — |
| M2 — BLS Triple-Sig | ✅ | `0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04` | — |
| M3 — Security Hardening | ✅ | `0xce4231da69015273819b6aab78d840d62cf206c1` | — |
| M4 — Cumulative Sigs + Social Recovery | ✅ | `0x914db0a849f55e68a726c72fd02b7114b1176d88` | — |
| M5 — ERC20 Guard + Guardian Accept | ✅ | `0xd72a236d84be6c388a8bc7deb64afd54704ae385` | 298 |
| M6 — Session Key + Weighted MultiSig + EIP-7702 | ✅ | `0x34282bef82e14af3cc61fecaa60eab91d3a82d46` | 446 |
| M7 — ERC-7579 + Agent Economy + WalletBeat + L2 ForceExit + Railgun | ✅ | `0x9D0735E3096C02eC63356F21d6ef79586280289f` | 622 |

---

## WalletBeat Stage Assessment (M7 — 2026-03-22)

WalletBeat evaluates wallets across Stage 0, 1, 2. AirAccount is a **smart contract account layer** — criteria marked 🆗 CLIENT are frontend/SDK responsibilities, not contract blockers.

| Stage | # | Criterion | Contract Status | Notes |
|-------|---|-----------|-----------------|-------|
| **0** | — | Source code publicly visible | ✅ PASS | GitHub: AAStarCommunity/airaccount-contract (GPL-3.0) |
| **1** | 1 | Security audit (last 12 months) | ⚠️ PARTIAL | Internal AI audit; paid external audit (Code4rena) planned pre-mainnet |
| **1** | 2 | Hardware wallet support (≥3 makers) | 🆗 CLIENT | P256/WebAuthn at contract layer; Ledger/Trezor SDK is frontend work |
| **1** | 3 | Chain verification (L1 light client) | 🆗 CLIENT | Frontend RPC provider choice (Helios integration is client work) |
| **1** | 4 | Private transfers (by default) | ⚠️ PARTIAL | Railgun calldata parser (M7.11) + OAPD address isolation; not shielded by default |
| **1** | 5 | Account portability | ✅ PASS | Social recovery (2-of-3 guardian), no platform lock-in, CREATE2 versioned migration |
| **1** | 6 | Own node support (custom RPC) | 🆗 CLIENT | Frontend/SDK responsibility |
| **1** | 7 | Free and open source (GPL-3.0) | ✅ PASS | All contracts, tests, scripts open source |
| **1** | 8 | Address resolution (ENS) | 🆗 CLIENT | No ENS at contract layer; frontend handles human-readable names |
| **1** | 9 | Browser integration (EIP-1193) | 🆗 CLIENT | Provider API is frontend/SDK responsibility |
| **2** | 1 | Bug bounty program | ❌ TODO | Framework designed (M7.7); no live Immunefi program yet |
| **2** | 2 | Address privacy | ⚠️ PARTIAL | OAPD reduces cross-DApp correlation; tx amounts remain visible on-chain |
| **2** | 3 | Multi-address correlation prevention | ✅ PASS | OAPD: deterministic per-DApp accounts via CREATE2 salt — different addresses per app |
| **2** | 4 | Transaction inclusion (L2→L1 force-exit) | ✅ PASS (M7.5) | ForceExitModule: guardian 2-of-3 gated OP Stack + Arbitrum withdrawal; E2E verified OP Sepolia |
| **2** | 5 | Chain configurability | 🆗 CLIENT | Multi-chain deployed (Sepolia, OP Sepolia); chain selection is frontend work |
| **2** | 6 | Funding transparency | ❔ UNKNOWN | AAStarCommunity DAO governance in progress |
| **2** | 7 | Fee transparency | ⚠️ PARTIAL | Gas costs verifiable on-chain; bundler/paymaster fees are off-chain |
| **2** | 8 | Chain-specific address (ERC-7828) | ✅ PASS (M7.4) | `getChainQualifiedAddress()` + `getAddressWithChainId()` in factory |
| **2** | 9 | Account abstraction (ERC-4337) | ✅ EXCEEDS | Full ERC-4337 + ERC-7579 modules + 7+ signature algorithms (ECDSA/BLS/P256/Weighted/Session/Agent) |
| **2** | 10 | Transaction batching | ✅ PASS | `executeBatch()` with per-call guard enforcement |

**Current position**: Stage 0 ✅ achieved. Stage 1 blocked by: (a) paid external security audit, (b) private-by-default transfers. Stage 2 blocked by: (a) live bug bounty, (b) items above are mostly frontend scope. See [docs/walletbeat-assessment.md](docs/walletbeat-assessment.md) for full analysis.

---

## Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| M5 Factory (current live) | `0xd72a236d84be6c388a8bc7deb64afd54704ae385` |
| M6 E2E Account (salt=701) | `0xfab5b2cf392c862b455dcfafac5a414d459b6dcc` |

---

## Documentation

### Feature Reference

| Document | Description |
|----------|-------------|
| [docs/feature-list.md](docs/feature-list.md) | **Complete feature list M1–M7** — per-milestone tables with characteristics, user value, and active/passive classification |

### Architecture & Design

| Document | Description |
|----------|-------------|
| [docs/airaccount-unified-architecture.md](docs/airaccount-unified-architecture.md) | Full system architecture — ERC-4337 flow, contract interactions, guard model |
| [docs/architecture-7579-evolution.md](docs/architecture-7579-evolution.md) | **NEW** — ERC-7579 module taxonomy, AirAccount→7579 mapping, algId signal flow, evolution roadmap (Mermaid diagrams) |
| [docs/product_and_architecture_design.md](docs/product_and_architecture_design.md) | Product vision, UX goals, tiered security model |
| [docs/contract-registry.md](docs/contract-registry.md) | Contract inventory — sizes, interfaces, test coverage mapping |
| [docs/M6-design.md](docs/M6-design.md) | M6 technical design — weighted signatures, session keys, EIP-7702 delegate |
| [docs/M6-decision.md](docs/M6-decision.md) | M6 scope decisions — what stays vs moves to M7 |

### Milestone Plans & Status

| Document | Description |
|----------|-------------|
| [docs/M6-status.md](docs/M6-status.md) | M6 feature completion table, Sepolia E2E results, known issues |
| [docs/M6-plan.md](docs/M6-plan.md) | M6 feature spec — session keys, weighted multi-sig, OAPD, EIP-7702 |
| [docs/M7-plan.md](docs/M7-plan.md) | M7 roadmap — ERC-7579 modules, agent economy (x402, ERC-8004), WalletBeat Stage 1/2 integration, frontend SDK guides, audit pricing |
| [docs/M7-TODO.md](docs/M7-TODO.md) | **NEW** — M7 developer TODO: 26 items across contract/frontend layers, execution order, WalletBeat stage mapping |
| [docs/M5-plan.md](docs/M5-plan.md) | M5 feature spec — ERC20 guard, guardian acceptance, zero-trust T1 |
| [docs/M4-plan.md](docs/M4-plan.md) | M4 feature spec — cumulative signatures, tiered verification, social recovery |
| [docs/audit-scope.md](docs/audit-scope.md) | C12 audit scope document for CodeHawks — in-scope contracts, interfaces, deployment scripts |
| [docs/known-issues.md](docs/known-issues.md) | Accepted risks and known limitations (EIP-7702 permanence, guardian self-dealing) |
| [docs/multichain-deployment.md](docs/multichain-deployment.md) | Multi-chain deployment addresses — Base, Arbitrum, OP Stack |

### Analysis & Reports (2026-03-20)

| Document | Description |
|----------|-------------|
| [docs/airaccount-comprehensive-analysis.md](docs/airaccount-comprehensive-analysis.md) | **NEW** — M1–M7 feature table, gas evolution charts, security industry comparison (vs Safe/ZeroDev/Coinbase/Argent), competitive analysis, gap analysis, multi-chain roadmap |
| [docs/2026-03-20-audit-report.md](docs/2026-03-20-audit-report.md) | Security audit report 2026-03-20 — HIGH/MEDIUM findings + fixes |
| [docs/M6-security-review.md](docs/M6-security-review.md) | M6 internal security review — session key scoping, replay protection, guardian domain separation |
| [docs/walletbeat-assessment.md](docs/walletbeat-assessment.md) | WalletBeat Stage 0/1/2 assessment — contract layer status, Stage 1 blockers (audit + private transfers), Stage 2 items |

### Deployment & Operations

| Document | Description |
|----------|-------------|
| [docs/acceptance-guide.md](docs/acceptance-guide.md) | E2E acceptance testing guide — Sepolia scripts, multi-chain deploy (OP Mainnet, Base), step-by-step commands |
| [docs/m5-deployment-record.md](docs/m5-deployment-record.md) | M5 Sepolia deployment record — tx hashes, gas costs, E2E verification |
| [docs/contract-registry.md](docs/contract-registry.md) | All deployed addresses across M1–M6 milestones |

### Gas & Performance

| Document | Description |
|----------|-------------|
| [docs/gas-analysis.md](docs/gas-analysis.md) | Gas benchmarks by milestone — M1 through M6, comparison vs industry (Light Account, Kernel v3, Safe) |
| [docs/gas-optimization-plan.md](docs/gas-optimization-plan.md) | Gas optimization strategies — storage packing, optimizer runs, EIP-170 compliance |

### Research & Background

| Document | Description |
|----------|-------------|
| [docs/M4.5-weighted-signature-research.md](docs/M4.5-weighted-signature-research.md) | Weighted signature design research — threshold schemes, bitmap encoding |
| [docs/eip-8130-upgrade-plan.md](docs/eip-8130-upgrade-plan.md) | EIP-8130 upgrade path analysis — non-upgradable migration strategy |
| [docs/validator-upgrade-pq-analysis.md](docs/validator-upgrade-pq-analysis.md) | Post-quantum validator analysis — CRYSTALS-Dilithium, EVM precompile timeline |

---

## Deploy to Sepolia (M6 r3)

```bash
# Requires ../SuperPaymaster/.env.sepolia with PRIVATE_KEY
chmod +x deploy-factory.sh
./deploy-factory.sh sepolia
# → prints AIRACCOUNT_FACTORY=<addr> and AIRACCOUNT_IMPL=<addr>
# → add AIRACCOUNT_M6_R3_FACTORY=<addr> to .env.sepolia
```

## Deploy to OP Mainnet

```bash
# Requires ../SuperPaymaster/.env.op-mainnet with DEPLOYER_ACCOUNT=optimism-deployer (cast wallet)
./deploy-factory.sh op-mainnet
# → runs: forge script script/DeployFactoryM6.s.sol --account optimism-deployer
# After deploy:
pnpm tsx scripts/test-op-e2e.ts
```

---

## Integration Tests (after M6 factory deploy)

```bash
# Sepolia — full E2E weighted signatures + session keys
pnpm tsx scripts/test-m6-weighted-e2e.ts
pnpm tsx scripts/test-session-key-e2e.ts

# OP Mainnet
pnpm tsx scripts/test-op-e2e.ts
```

---

## Build & Test

```bash
forge build                          # compile
forge test                           # 622 unit tests
forge test --match-path test/SessionKeyValidator.t.sol -v   # specific suite
forge test --summary                 # per-suite breakdown
```

---

## Security

- **No upgradability** — no proxy patterns; new features require new contract + user migration
- **Immutable guards** — spending limits can only be tightened, never loosened
- **Guardian-threshold recovery** — 2-of-3 required; private key alone cannot bypass
- **Session key revocation** — nonce-based, prior grant signatures invalidated on revoke
- **EIP-7212 P256** — hardware-bound passkey authentication, available on OP Mainnet (Fjord)
- **Audit reports** — see `docs/2026-03-*-audit-report.md`

---

## License

This project is licensed under the [Apache License, Version 2.0](LICENSE).  
Copyright 2024-present MushroomDAO Contributors.  
See [NOTICE](./NOTICE) · [TRADEMARK.md](./TRADEMARK.md) · [LICENSE-zh.md](./LICENSE-zh.md) · [TRADEMARK-zh.md](./TRADEMARK-zh.md) for details.
