# AirAccount Smart Contract

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
A privacy-first, non-upgradable ERC-4337 smart wallet for mobile crypto payments. Tiered security based on transaction value, social recovery via guardians, gasless transactions via paymasters, and hardware-bound passkey (P256/WebAuthn) authentication.

## Status: v0.18 — 2026-06-14

Latest: **v0.18** — security-hardening + gas + #45 release. All work-streams WS-A/B/C/D/E/F/G merged to `main`, plus the **#45 CRITICAL** BLS↔userOpHash binding and the factory EIP-3860 initcode fix. Full stack redeployed + wired on Sepolia (the account is non-upgradable, so a new factory + implementation is mandatory). Forge test **799/0/0** under cancun, plus **22** `#45` BLS-binding tests under `--evm-version prague`. On-chain E2E phases 13-16 all green. See [`docs/deployment-v0.18.md`](docs/deployment-v0.18.md) + [`docs/issue45-fix1-yaa-changes.md`](docs/issue45-fix1-yaa-changes.md). Prior: [`v0.17.2-beta.4`](https://github.com/AAStarCommunity/airaccount-contract/releases) — bundler-compat algId fix.

### What shipped in v0.18

| WS | PR | What |
|----|----|------|
| WS-A | #99 | Guardian-signed hash hardening — module-management nonce + version epoch in the signed domain (#75/#84). Defeats stale-signature replay across installs. |
| WS-B | #98 | ForceExit TOCTOU — re-verify approvers are still guardians at `executeForceExit`; loud `_readGuardians` (#70/#77). |
| WS-C | #101 | Session-key cap (50/account) + sliding-window velocity limiter (#83/#57). |
| WS-D | #102 | Optional module-install timelock — owner+2-guardian bypass, proposal bound to auth config, immutable `executeAfter`, cap + expiry (#58/KI-6). |
| WS-E | #107 | Gas optimizations (#82/#81/#80/#79) **+ factory EIP-3860 fix** — implementation injected as ctor arg 1, factory initcode 49,134 → 13,324 bytes. |
| WS-F | #103/#108 | E2E completeness + v0.18 on-chain scaffolds (phases 13-16); strict revert-selector assertions; phase-16 `validateUserOp` `msg.sender` fix (#90). |
| WS-G | #100 | P256 low-S malleability guard (#78) + ERC-1271 EIP-712 NatSpec + constructor error tests (#76/#74). |
| WS-A2 | #105 | **#45 CRITICAL** — BLS algorithm recomputes the message point on-chain from `userOpHash` (RFC 9380 `hash_to_curve`); removes caller-supplied `messagePoint`/`mpSig` from every BLS payload. Single-op **and** batch-aggregator paths both bound to `userOpHash`. Aggregator is a single Safe-owned (`Ownable2Step`) protocol value; set-once validator. |
| CI | #106 | Dedicated `bls-binding-prague` job — runs the #45 crypto tests under EIP-2537 (Prague). |

> ⚠️ **#45 Fix 2 (DVT node authorization) is out of scope for v0.18** and tracked for `YetAnotherAA-Validator`. Fix 1 (this release) stops *replay* of old BLS approvals; it does NOT stop a *freshly forged* unauthorized DVT approval. The BLS/DVT tier is only a fully sound security factor once Fix 2 ships. See [`docs/issue45-fix1-yaa-changes.md`](docs/issue45-fix1-yaa-changes.md).

### Core features since v0.17.1

Combined `v0.17.2-beta.1` + `v0.17.2-beta.2`:

- **Session-key system unified** — deleted `AgentSessionKeyValidator` + `AirAccountCompositeValidator` + `TierGuardHook` (-7.8 KB combined bytecode). Single enhanced `SessionKeyValidator` at validator router algId `0x08` supports both classic single-target sessions and richer agent-grade controls (velocity, `callTargets[]`, `selectorAllowlist[]`, P256 passkey variant). Backward-compat shims removed.
- **8 rounds of Codex adversarial review + David human review** on PR #61 + PR #68. All Critical / High / Medium findings fixed:
  - BLS infinity-point bypass (per-UserOp + final aggregate checks)
  - Aggregator unbound-to-userOps fix (recompute from `userOps[i].signature`)
  - Weighted-sig token tier mismatch (pass resolved algId to `_checkTokenGuard`)
  - 7702 delegate ERC20 inline check (raw `transfer`/`approve` selectors)
  - ForceExit stale-guardian check (v0.17.2-beta.2)
  - AgentRegistry factory-provenance whitelist (H-2)
  - `bindFactory` deployer-only access control
  - 5-arg shim confused-deputy bypass closed
- **ForceExit stale-guardian fix (v0.17.2-beta.2)** — `approveForceExit` rejects signatures from rotated-out guardians (`SignerNoLongerGuardian`). One contract redeployed; other 10 keep beta.1 addresses.
- **Phase 08-12 E2E verified (2026-06-11~12)** — 45 new on-chain tests covering multi-account creation, execute variants, session keys, guardian recovery + modules, ERC-4337 UserOp via Pimlico bundler. Full suite: **79/79 PASS**, 100% non-deferred ABI coverage.
- **Sepolia deploy + Etherscan verify (11/11)** + complete deploy runbook

### Key docs

1. [CHANGELOG.md](CHANGELOG.md) — release-by-release feature evolution
2. [docs/deployment-v0.18.md](docs/deployment-v0.18.md) — **v0.18** Sepolia deploy record (addresses, wiring, decisions, E2E)
3. [docs/issue45-fix1-yaa-changes.md](docs/issue45-fix1-yaa-changes.md) — **#45** BLS↔userOpHash binding: new wire formats + SDK/DVT changes
4. [docs/abi/reference.md](docs/abi/reference.md) · [docs/abi/selectors.md](docs/abi/selectors.md) · [docs/abi/capabilities.md](docs/abi/capabilities.md) — generated ABI reference (`pnpm gen:abi-docs`)
5. [docs/DEPLOYMENT-v0.17.2-beta.1.md](docs/DEPLOYMENT-v0.17.2-beta.1.md) — full Sepolia deploy runbook
3. [docs/DEPLOYMENT-v0.17.2-beta.2.md](docs/DEPLOYMENT-v0.17.2-beta.2.md) — beta.2 delta release (ForceExitModule only)
4. [docs/contracts-inventory-v0.17.2-beta.1.md](docs/contracts-inventory-v0.17.2-beta.1.md) — 11 contracts × 4 wirings × algorithm-ID matrix
5. [docs/security-review-v0.17.2-beta.1.md](docs/security-review-v0.17.2-beta.1.md) — Codex rounds 5-8 (pre-release gate)
6. [docs/abi-coverage-v0.17.2-beta.1.md](docs/abi-coverage-v0.17.2-beta.1.md) — 80+ external functions: U (unit) / E (E2E) / deferred classification
7. [docs/e2e-results-v0.17.2-beta.3.md](docs/e2e-results-v0.17.2-beta.3.md) — Phase 08-12 on-chain result log (45 tests, all PASS)
8. [docs/tx-analysis-v0.17.2-beta.3.md](docs/tx-analysis-v0.17.2-beta.3.md) — TX categories ↔ AirAccount feature mapping + Codex TX verification
9. [docs/pimlico-bundler-compatibility.md](docs/pimlico-bundler-compatibility.md) — bundler split-simulation deep-dive (algId / prefund)
10. [docs/e2e-v0172-beta3-pitfalls-and-results.md](docs/e2e-v0172-beta3-pitfalls-and-results.md) — Phase 08-12 pitfalls and lessons learned
11. [docs/forceexit-design-notes.md](docs/forceexit-design-notes.md) — ForceExit subsystem design + accepted residual risks
12. [docs/known-issues.md](docs/known-issues.md) — KI-1..KI-15 accepted limitations + auditor notes
13. [GitHub issue #67 v0.18 roadmap](https://github.com/AAStarCommunity/airaccount-contract/issues/67) — what's planned next

> ⚠️ **Integrators / SDK**: the account is *diamond-lite* — the agent + weight-governance functions execute via fallback and are **absent from the raw `out/AAStarAirAccountV7.sol` ABI**. Use the merged **[`abi/AAStarAirAccountV7.full.json`](abi/AAStarAirAccountV7.full.json)** (run `scripts/build-full-abi.mjs`) to encode them. See [`docs/2026-05-26-diamond-lite-migration-impact.md`](docs/2026-05-26-diamond-lite-migration-impact.md).

> ⚠️ **Not for mainnet yet**: this is a beta tag. Mainnet requires paid security audit + bug bounty + KMS/SuperPaymaster/SDK production-ready. See [DEPLOYMENT-v0.17.2-beta.1.md](docs/DEPLOYMENT-v0.17.2-beta.1.md) §1-3 for the full mainnet checklist.

---

## ⭐ 8 Core Capabilities — what AirAccount gives you

| # | Capability | What you can do |
|---|------------|------------------|
| 1 | **WebAuthn / Passkey login** | Fingerprint/face/PIN = account. No password/seed. P-256 verified onchain via EIP-7212 |
| 2 | **Tiered multisig** | Single WebAuthn (<$100) → dual-factor (<$1K) → multi-sig (>$1K). Onchain $-gated |
| 3 | **Session Key + Agent** | One `SessionKeyValidator` for both classic and agent modes: velocity / callTargets / selectorAllowlist / P256 passkey. Agent never holds owner rights |
| 4 | **ERC-8004 Agent economy** | Official Identity / Reputation / Validation registries + factory-provenance whitelist |
| 5 | **Social Recovery (3-2-48h)** | 3 guardians, 2-of-3 threshold, 48h timelock. cancelRecovery is 2-of-3 vote (NOT owner) |
| 6 | **ForceExit emergency drain** | L2→L1 bridge withdrawal (Optimism / Arbitrum). beta.2 stale-guardian hardened |
| 7 | **EIP-7702 EOA upgrade** | `AirAccountDelegate` makes an existing EOA an AirAccount via one type-4 tx |
| 8 | **ERC-4337 v0.7 + ERC-7579 modular** | Standard paymaster, modular validator/executor/hook. SuperPaymaster plug-and-play |

Bytecode-budget detail: see "**Diamond-lite**" note in the warning above. SDK consumers use the merged `abi/AAStarAirAccountV7.full.json` and see zero behavioural difference.

---

## 🛠 Integrate in 5 steps

```typescript
import { AirAccount, SuperPaymaster } from '@aastar/sdk';

// 1. Create account (WebAuthn → P-256 keys in TEE)
const account = await AirAccount.create({ provider: 'webauthn', chain: 'sepolia' });

// 2. Send gasless tx (pay gas in community xPNTs, not ETH)
const tx = await SuperPaymaster.sendGasless({
  account, to: contractAddress, data: callData, paymentToken: 'xPNTs',
});

// 3. Grant a velocity-rate-limited session key to a dApp
await account.installModule({
  type: 'session-key',
  policy: {
    duration: 3600,
    callTargets: [dapp],
    selectorAllowlist: ['0xa9059cbb'],
    velocity: { window: 3600, max: parseEther('0.1') },
  },
});

// 4. Set 3 social-recovery guardians
await account.setGuardians([guardianA, guardianB, guardianC]);

// 5. (Optional) Install ForceExit for L2→L1 emergency drain
await account.installModule({
  type: 'force-exit',
  destinationL1: ownerEOA,
  amount: parseEther('0.5'),
});
```

ABIs + Sepolia addresses sync to `@aastar/core@0.18.x` via the SDK `feat/v0.18-contracts` branch. Use **pnpm**, **viem** (project conventions).

---

## 🌐 Ecosystem stack — testnet today, Cos72 tomorrow

```
Cos72 (v0.19 PoC target — MushroomDAO community OS)
  ↓ email register → community identity → gasless governance / tasks
SuperPaymaster v5.3.3-beta.2 (Sepolia testnet — gasless w/ community tokens)
  ↓ ERC-4337 standard paymaster
AirAccount v0.18 (this release)                   ◄── you are here
  ↓ TEE-signed userOps
KMS v0.18.x (production — kms.aastar.io)
```

All four layers ERC-4337 v0.7 standard, plug-in compatible.

| Layer | State |
|-------|-------|
| KMS | ✅ Production (`kms.aastar.io`), TEE-attested |
| AirAccount (this release) | ✅ Sepolia v0.18, full stack redeployed + wired |
| SuperPaymaster | ✅ Sepolia Testnet Live (v5.3.3-beta.2, security-hardened beta) — mainnet pending external audit |
| AAStar SDK | ✅ v0.18 sync in flight (SDK `feat/v0.18-contracts`) |
| Cos72 | ⏳ v0.19 PoC target |

**Announcement copy for socials** (Twitter / Discord / Blog): see [`docs/announcements/`](docs/announcements/) — three ready-to-publish formats.

---

## Quick Start

```bash
forge build
forge test --summary          # 799 tests (cancun)
# #45 BLS↔userOpHash binding tests need EIP-2537 (Prague):
forge test --evm-version prague --match-contract "HashToG2GoldenTest|BLSReplayBindingTest|AAStarBLSAggregatorTest" -vv  # 22 tests

# v0.18 on-chain E2E (Sepolia) — phases 13-16 (WS-A/B/C/G)
pnpm tsx scripts/e2e-v0172/13-ws-a-module-nonce.ts          # Phase 13: module-nonce replay defence
pnpm tsx scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts      # Phase 14: ForceExit approver TOCTOU
pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts  # Phase 15: session-key cap + velocity
pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts            # Phase 16: P256 low-S guard
```

---

## Contracts (v0.18)

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
| `SessionKeyValidator` | Unified session key validator (algId `0x08`): classic single-target sessions + agent-grade controls (velocity, `callTargets[]`, `selectorAllowlist[]`, P256 passkey). Replaced `AgentSessionKeyValidator` + `AirAccountCompositeValidator` in v0.17.2-beta.1 | singleton |

**Signature algorithms (algId):** ECDSA `0x02`, P256/WebAuthn `0x03`, Cumulative T2 (P256+BLS) `0x04`, Cumulative T3 (P256+BLS+Guardian) `0x05`, Combined T1 (P256∧ECDSA) `0x06`, Weighted multi-sig `0x07`, Session Key `0x08`, BLS triple `0x01`.

### Hooks / executor modules (ERC-7579)
| Contract | Role | Deploy |
|---|---|---|
| `ForceExitModule` | Guardian-gated L2→L1 force exit (OP Stack / Arbitrum); beta.2 stale-guardian hardened | singleton |

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

> Deployment order, wiring, and run commands: see [`docs/DEPLOYMENT-v0.17.2-beta.1.md`](docs/DEPLOYMENT-v0.17.2-beta.1.md).

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
| **v0.17.2-beta.3** — Security hardening, diamond-lite, Phase 08-12 E2E | ✅ | `0xfc6234bbd6283610659211347c6309904be86b0a` | 723 |
| **v0.17.2-beta.4** — Bundler-compat algId (executeUserOp + account whitelist) | ✅ | `0x3a9127a5f0b4ca734d54629d0c3ad9f52739c071` | 731 |
| **v0.18** — WS-A..G security/gas + #45 BLS↔userOpHash binding + EIP-3860 factory fix | ✅ | `0xB14a870e4f63CA21a7EB753588CC4eBFb429E163` | **799** (+22 prague) |

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

## Deployed Contracts (Sepolia) — v0.18

v0.18 is a **full stack redeploy** (10 contracts + 6 wiring txs). Because the account is non-upgradable, the
WS-A..G + #45 + EIP-3860 changes require a fresh factory + implementation; beta.4 addresses are superseded.
Full runbook, wiring, decisions, and E2E results: [`docs/deployment-v0.18.md`](docs/deployment-v0.18.md).

| Contract | Address |
|----------|---------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (canonical) |
| Factory | `0xB14a870e4f63CA21a7EB753588CC4eBFb429E163` |
| Implementation | `0x1Bc1119e3Ce4B6D158a6eadb31A06FdcE51992cF` |
| Extension | `0xB1B3acd47DB89806F8431da3452769f1243b4d56` |
| BLSAlgorithm | `0x2869EEb04218ca666c6373c0DC5aCDa04F00adFA` |
| BLSAggregator | `0x9AD55930B77C002dF884F4dac846D2077CDA7C8b` |
| ValidatorRouter | `0xe785AF830aD33F3E550FfdC0fEB81D42507DA39D` |
| SessionKeyValidator | `0x82f16163D0fb9c4dd7507b9999B79527a795291C` |
| ForceExitModule | `0x0F6960526acf4cF9123e0aBc82d7a59fA0B6C934` |
| AirAccountDelegate (EIP-7702) | `0x70A8E31c425Ef3F23a2F9E05C48Bd998Aa29085b` |
| AgentRegistry | `0x118eD73f22e41cb69282c78b216426D2d98A3935` |
| CalldataParserRegistry | `0x5dEE2c5279eFfC7c7FE711233bE42726EE0d4166` |

> **v0.18 factory ctor changed (#82 EIP-3860 fix):** `AAStarAirAccountFactoryV7(implementation, entryPoint, community, validators[], algorithms[])` — the implementation is now **injected as ctor arg 1** instead of deployed inside the factory constructor (initcode 49,134 → 13,324 bytes). Deploy scripts + SDK must pass a pre-deployed implementation. **`setAggregator` and `addStake` are OFF on this testnet deploy** (single-op BLS binding everywhere; batch path is Safe-only opt-in on mainnet).

ABI: use [`abi/AAStarAirAccountV7.full.json`](abi/AAStarAirAccountV7.full.json) (includes diamond-lite `AirAccountExtension` selectors). Generated reference: [`docs/abi/reference.md`](docs/abi/reference.md) · [`docs/abi/selectors.md`](docs/abi/selectors.md) · [`docs/abi/capabilities.md`](docs/abi/capabilities.md) (regenerate with `pnpm gen:abi-docs`).

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

## Deploy to Sepolia (v0.18)

v0.18 is already deployed on Sepolia — see **Deployed Contracts** table above and the full runbook in
[`docs/deployment-v0.18.md`](docs/deployment-v0.18.md). To deploy a fresh stack:

```bash
# Requires .env.sepolia with PRIVATE_KEY_ANNI, SEPOLIA_RPC_URL*, BLS_TEST_* node keys.
# TS+viem is the supported path — forge script fails on macOS (Socket operation on non-socket).
pnpm tsx scripts/deploy-v0.18.ts
# → deploys 10 contracts + 6 wiring txs; prints AIRACCOUNT_V018_* to append to .env.sepolia
# → factory ctor injects a pre-deployed implementation (arg 1) — #82 EIP-3860 fix
```

## Deploy to OP Mainnet

```bash
# Requires .env.op-mainnet with DEPLOYER_ACCOUNT (cast wallet)
forge script script/DeployFactoryV7.s.sol --rpc-url $OP_MAINNET_RPC_URL \
  --account optimism-deployer --broadcast --verify -vvv
```

---

## Integration Tests (v0.18 — Sepolia)

v0.18 added on-chain phases 13-16 (WS-A/B/C/G); the beta.3 phases 08-12 still apply for the execute / session / bundler surface.

```bash
# v0.18 phases (WS-A/B/C/G) — see docs/deployment-v0.18.md for per-test results
pnpm tsx scripts/e2e-v0172/13-ws-a-module-nonce.ts          # 8 tests  — module-nonce replay
pnpm tsx scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts      # 7 tests  — ForceExit TOCTOU
pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts  # 4 tests (+1 opt-in SKIP) — session cap/velocity
pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts            # 6 tests  — P256 low-S guard

# beta.3 phases (Phase 09 must run alone — Jason wallet nonce conflict with Phase 11)
pnpm tsx scripts/e2e-v0172/08-multi-account-types.ts      # 8 tests — account variants
pnpm tsx scripts/e2e-v0172/09-execute-transactions.ts     # 10 tests — execute (run standalone)
pnpm tsx scripts/e2e-v0172/10-session-key-txns.ts         # 11 tests — session keys
pnpm tsx scripts/e2e-v0172/11-guardian-recovery-module.ts # 12 tests — guardian + module install/uninstall
pnpm tsx scripts/e2e-v0172/12-userop-bundler.ts           # 4 tests  — ERC-4337 UserOp via Pimlico
```

---

## Build & Test

```bash
forge build                          # compile
forge test                           # 799 unit tests (cancun)
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
