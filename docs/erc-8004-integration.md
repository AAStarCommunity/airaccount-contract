# AirAccount × ERC-8004 "Trustless Agents" — Integration & Compliance Reference

**Version**: v0.17.1
**Last updated**: 2026-05-29
**Audience**: AirAccount / SuperPaymaster / `@aastar/sdk` developers and integrators.
**Purpose**: document how AirAccount integrates the three official ERC-8004 registries, record a spec-compliance audit (verified against the EIP on 2026-05-29), and give a reading list + integration guidance for future work.

---

## 0. TL;DR

- **ERC-8004 is a Draft EIP** (not Final). It defines three registries: **Identity**, **Reputation**, **Validation**.
- AirAccount integrates ERC-8004 entirely through the **`AirAccountExtension`** facet (diamond-lite: the account routes these cold functions via `fallback`+`delegatecall`).
- **Identity + Reputation: production-usable today** and **we use them**. Our interface signatures match the official EIP **verbatim** (verified 2026-05-29).
- **Validation: NOT wired.** We carry only the address constant + interface stub; **no contract path calls it.** Mainnet deployment is pending and the TEE/attestation flow is still under working-group discussion. Treat it as **reserved/optional** — do not make it a hard dependency of any payment/risk path.
- We use a **subset** of each registry's capabilities (the core happy path). Unused capabilities are catalogued in §4 with recommendations.

---

## 1. The three registries & spec status

ERC-8004 ("Trustless Agents") is **Standards-Track: ERC, status Draft** (https://eips.ethereum.org/EIPS/eip-8004). All three registries are upgradeable and deployed at deterministic CREATE2 addresses (SAFE Singleton Factory), one shared address per network family.

| Registry | Role | Production readiness |
|---|---|---|
| **IdentityRegistry** | Agent identity as an ERC-721 NFT (`agentId`); binds one execution `agentWallet`; `agentURI`/`tokenURI` points to the agent registration file. | Live on mainnet + testnets; usable now (EIP still Draft). |
| **ReputationRegistry** | Clients submit signed fixed-point `giveFeedback`; `getSummary` aggregates trust signals. | Live on mainnet + testnets; usable now (EIP still Draft). |
| **ValidationRegistry** | Third-party validators (stake-secured re-execution / zkML / **TEE oracles**) post `validationRequest` → `validationResponse` records. | **Mainnet-pending; testnet-only.** Interfaces explicitly subject to change with the TEE community. **Do not treat as a production dependency.** |

---

## 2. Official addresses (from `src/config/ERC8004Addresses.sol`)

Same address across each network family (CREATE2). The library reverts `UnsupportedChain` for unknown chains rather than silently returning a wrong address.

| Registry | Mainnet (1, 10, 137, 8453, 42161, …) | Testnet (11155111, 11155420, 84532, …) |
|---|---|---|
| Identity | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| Reputation | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| Validation | `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58` | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` |

> The Sepolia Validation address has real `ValidationRequest` / `ValidationResponse` transactions but low volume — it is a testnet verification path while the TEE attestation flow is finalized.

---

## 3. How AirAccount integrates each registry

All integration lives in **`src/core/AirAccountExtension.sol`** and is reached from the account through `fallback`→`delegatecall` (diamond-lite). Every write pins the registry argument to the official per-chain address via `_requireOfficialIdentityRegistry` / `_requireOfficialReputationRegistry`, and is `onlyOwner` + `nonReentrant`.

| Our function (account-facing) | ERC-8004 call | Registry | Source |
|---|---|---|---|
| `mintAgentIdentity(identityRegistry, agentURI)` | `register(string agentURI) → agentId` | Identity | `AirAccountExtension.sol:136` |
| `bindERC8004AgentWallet(identityRegistry, agentId, agentWallet, deadline, signature)` | `setAgentWallet(agentId, newWallet, deadline, signature)` | Identity | `AirAccountExtension.sol:150` |
| `submitAgentReputation(reputationRegistry, agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash)` | `giveFeedback(...)` | Reputation | `AirAccountExtension.sol:167` |
| `queryAgentReputation(reputationRegistry, agentId, clientAddresses, tag1, tag2)` | `getSummary(...) → (count, value, decimals)` | Reputation | `AirAccountExtension.sol:182` |
| — (none) | — | Validation | **not integrated** |

### 3.5 ⚠️ Two different "agent wallet" bindings — do not confuse them

There are **two** functions with similar names that bind an agent wallet, to **different** registries:

| Function | Writes to | Purpose |
|---|---|---|
| `setAgentWallet(agentId, agentWallet, agentRegistry, agentWalletSig)` (`AirAccountExtension.sol:104`) | **our own `AgentRegistry`** (`src/registries/AgentRegistry.sol`), via `registerAgent(address,bytes)` | SuperPaymaster-facing wallet→owner map. Gated so **only AirAccount contracts** may register (HIGH-1); requires the wallet's consent sig with **ECDSA or ERC-1271** (HIGH-2). |
| `bindERC8004AgentWallet(identityRegistry, agentId, agentWallet, deadline, signature)` (`AirAccountExtension.sol:150`) | **official ERC-8004 `IdentityRegistry`** | Standard ERC-8004 `setAgentWallet` — binds the wallet to the on-chain agent NFT. |

> Naming note: our `setAgentWallet` shares its name with the *official* `IdentityRegistry.setAgentWallet` but is a **different** call (different target, different params, different purpose). This has caused reviewer confusion. Integrators: read the param list — our `setAgentWallet` takes an `agentRegistry` address (our registry); the ERC-8004 one is reached via `bindERC8004AgentWallet`. A future rename of our function (e.g. `registerAgentInPaymasterRegistry`) is worth considering but is a post-release code change.

> **What "binding a wallet" actually does — ERC-8004 provides NO wallet.** Both bindings are *directory writes*, not wallet provisioning. `setAgentWallet(agentId, newWallet, deadline, signature)` simply **stores an address you supply** (the agent's AirAccount or EOA) into the registry, keyed by the `agentId` NFT. The registry never generates, custodies, or hands out a wallet/key — it records a public, verifiable `agentId → wallet` entry, gated by an EIP-712 consent signature **from that wallet** (proving the wallet holder agreed). Anyone can read it back with `getAgentWallet(agentId)`. Mental model: it is an "identity directory / name registry," not a wallet service — you register your own address and sign for it; the directory issues nothing.

---

## 4. Compliance audit (verified against EIP-8004, 2026-05-29)

### 4.1 Interface signatures — ✅ 100% standard

Our three interface files (`IERC8004IdentityRegistry`, `IERC8004ReputationRegistry`, `IERC8004ValidationRegistry`) were checked function-by-function against the official EIP-8004 Draft. **Every signature we declare matches the spec verbatim** (name, parameter types, return tuple). Calls are therefore selector-compatible with the deployed official registries. Spot-checked: `register(string)`, `setAgentWallet(uint256,address,uint256,bytes)`, `giveFeedback(uint256,int128,uint8,string,string,string,string,bytes32)`, `getSummary(uint256,address[],string,string)`, `validationRequest(address,uint256,string,bytes32)`, `validationResponse(bytes32,uint8,string,bytes32,string)` — all exact.

### 4.2 Capabilities used vs available

**IdentityRegistry**

| Capability | Used? | Note |
|---|---|---|
| `register(string)` | ✅ | via `mintAgentIdentity` |
| `setAgentWallet` | ✅ | via `bindERC8004AgentWallet` |
| `register()` / `register(uri, metadata[])` | ❌ | only the single-URI overload is used |
| `getAgentWallet` (read) | ❌ | integrators currently resolve via our `AgentRegistry` instead |
| `unsetAgentWallet` | ❌ | no wallet-rotation/revocation path exposed |
| `setAgentURI` / `getMetadata` / `setMetadata` | ❌ | no agent-card metadata management |
| `isAuthorizedOrOwner` | ❌ | — |

**ReputationRegistry**

| Capability | Used? | Note |
|---|---|---|
| `giveFeedback` | ✅ | via `submitAgentReputation` |
| `getSummary` | ✅ | via `queryAgentReputation` |
| `appendResponse` | ❌ | agent cannot respond to feedback on-chain |
| `revokeFeedback` | ❌ | — |
| `readFeedback` / `readAllFeedback` / `getClients` / `getLastIndex` / `getResponseCount` | ❌ | only the aggregate summary read is wired |

**ValidationRegistry** — ❌ **entirely unused** (`validationRequest` / `validationResponse` / `getValidationStatus` / `getSummary` / `getAgentValidations` / `getValidatorRequests`).

### 4.3 Verdict & recommendations

- **Standard-compliant: yes.** Interfaces match the spec exactly; the happy-path (register identity → bind wallet → submit/query reputation) is correctly wired and security-hardened (official-registry pinning, owner-only, nonReentrant, consent sigs).
- **All key capabilities used: no — by design.** We implement the core path, not the full surface. Gaps worth considering for a future milestone:
  - **`getAgentWallet` (read)** — let SP/integrators resolve `agentId → wallet` from the canonical ERC-8004 source (today we only expose our own `AgentRegistry` map). Low effort, high value.
  - **`unsetAgentWallet`** — wallet rotation / compromise response. Security-relevant.
  - **`appendResponse`** — let an agent rebut negative feedback (reputation fairness).
  - **`setMetadata` / `setAgentURI`** — richer, updatable agent cards.
  - **ValidationRegistry** — see §5.
- None of these gaps are release-blocking for v0.17.1; file as follow-up issues if/when the agent product needs them.

---

## 5. ValidationRegistry — reserved for DVT/TEE, not wired

We deliberately do **not** depend on the ValidationRegistry:

- Mainnet deployment is pending; only a low-volume testnet reference deployment exists.
- The spec states the registry is still under active development with the TEE community (stake-secured re-execution, zkML verifiers, TEE oracles) and the interface may change.

It maps naturally onto AAStar's roadmap (KMS/TEE attestation, the DVT-based **PolicyRegistry**, the "Am I Dead?" verification system) — a validator publishing attestations about an agent is exactly what this registry is for. **Recommendation:** keep the address constant + interface stub (zero deploy cost — we never deploy ERC-8004), but build any future consumer as an **optional adapter** (e.g. SP reading `getValidationStatus()` / listening to `ValidationResponse`), never as a hard dependency of a payment or risk-control path. Re-evaluate once the EIP's Validation/TEE flow stabilizes.

---

## 6. SuperPaymaster integration guidance

- **Production logic should depend only on Identity + Reputation.** This is the correct, conservative posture while the EIP is Draft and Validation is mainnet-pending.
- Resolve agent ↔ wallet through either (a) our `AgentRegistry` (wallet→owner, already SP-facing) or (b) the official `IdentityRegistry.getAgentWallet` once we expose it — keep these two consistent.
- Treat reputation (`getSummary`) as an **advisory** trust signal, not a hard gate, until feedback volume is meaningful.
- Wire ValidationRegistry only behind a feature flag / optional adapter when the TEE flow finalizes.

---

## 7. Reference resources (reading priority)

1. **Official EIP / spec** — https://eips.ethereum.org/EIPS/eip-8004 — minimal interfaces for all three registries, agent registration JSON, feedback file structure, validation request/response. *Status: Draft.*
2. **Reference contracts repo** — https://github.com/erc-8004/erc-8004-contracts — closest-to-official contracts/ABI/Hardhat tests; README lists deployment addresses + Quickstart. (README warns the Validation Registry is still being updated with the TEE community.)
3. **QuickNode ERC-8004 Explorer** — https://erc-8004.quicknode.com/docs/contracts — addresses, ABIs, TS/viem examples for reading chain data, registering an agent, submitting feedback, becoming a validator. Notes Validation reference deployment is testnet-only.
4. **Pinata Quickstart** — https://docs.pinata.cloud/tools/erc-8004/quickstart — agent metadata / IPFS pinning + minimal register flow (`npx @pinata/erc8004-wizard`).
5. **Oasis ROFL + ERC-8004** — https://docs.oasis.io/build/use-cases/trustless-agent — best reference for the Validation/TEE/hardware-attestation path: ROFL agent auto-registration, requesting validation, a validator agent watching `ValidationRequest` and posting `ValidationResponse`.
6. **Community SDK / demos** (treat as community references, not the final spec):
   - `tetratorus/erc-8004-js` — TypeScript SDK, examples configure the Sepolia addresses directly.
   - `vistara-apps/erc-8004-example` — multi-agent demo across all three registries.

---

## 8. What the `@aastar/sdk` should expose

So SDK consumers use *our* interface correctly:

- **Account agent functions** are fallback-routed — bind to the merged **`abi/AAStarAirAccountV7.full.json`**, not the raw account ABI (see `sdk-abi-mapping.md`). The relevant selectors: `mintAgentIdentity`, `bindERC8004AgentWallet`, `submitAgentReputation`, `queryAgentReputation`, plus our `setAgentWallet` (→ AgentRegistry).
- **Make the Identity/Reputation registry addresses chain-derived** (mirror `ERC8004Addresses` — mainnet vs testnet families); never hard-code a single address.
- **Surface the §3.5 distinction** in the SDK API (e.g. `bindOfficialIdentityWallet()` vs `registerAgentForPaymaster()`) so app developers don't conflate the two bindings.
- **Do not expose Validation** as a first-class flow yet; if at all, behind an explicit "experimental" namespace.
