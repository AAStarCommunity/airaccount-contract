# M7 Design & Planning Document — AirAccount v0.16.0

**Target**: Ecosystem compatibility, privacy support, and enterprise readiness
**Philosophy**: M7 is NOT a core-feature milestone. Focus: (1) prove interop with privacy protocols (Railgun/Kohaku), (2) standard compliance testing, (3) L2 readiness. Items moved to M6: M7.8 (PQ placeholder), M7.9 (ERC-165 audit), M7.10 (already done), M7.4 (chainId helper). None of M7 changes the core security model from M6.

---

## M7 Feature Roadmap

| # | Feature | Category | Difficulty | Depends on | Notes |
|---|---------|----------|-----------|-----------|-------|
| M7.1 | Will Execution (WillExecutor.sol) | Core | Hard | DVT off-chain | Moved from M6.5; useless without DVT scanner |
| M7.2 | Full ERC-7579 Module Compliance | Compatibility | Medium | — | installModule, uninstallModule, executeFromExecutor |
| M7.3 | EIP-1167 Minimal Proxy Factory | Gas / Size | Medium | — | Permanent fix for EIP-170 factory size pressure |
| M7.4 | ERC-7828 / ERC-7831 Chain-Specific Address | Interop | Low | — | Chain-qualified address encoding |
| M7.5 | L2 Deployment + Force-Exit Mechanism | Interop | Medium | — | Base, Arbitrum, OP Stack; canonical bridge force-exit |
| M7.6 | Professional Security Audit | Security | — | M6 complete | Immunefi or Code4rena + public report |
| M7.7 | Bug Bounty Program (Immunefi) | Security | Low | M7.6 | Live program after audit |
| M7.8 | ~~Post-Quantum Signature Interface (placeholder)~~ | — | **Moved to M6** | — | algId 0x10 reserved; 2-line comment |
| M7.9 | ~~ERC-165 / ERC-1271 Full Compliance Audit~~ | — | **Moved to M6** | — | Review pass, no code change |
| M7.10 | ~~AirAccountDelegate ArrayLengthMismatch~~ | — | **Already done** | — | executeBatch already has custom error |
| M7.11 | **Railgun Privacy Pool Integration** | Privacy | Medium | — | RailgunParser + CalldataParserRegistry; prove deposit/withdraw works with guard |
| M7.12 | **Kohaku Relay Compatibility** | Privacy | Low | M7.11 | Kohaku is a relay layer over Railgun; validate transaction format compatibility |
| M7.13 | **ERC-5564 Stealth Address Support** | Privacy | Medium | — | `announceForStealth()` + stealth address derivation helper |

---

## Feature Details

### M7.1 — Will Execution (moved from M6.5)

**What**: `WillExecutor.sol` — a validator module that releases assets to beneficiaries after a DVT-verified "owner is dead" proof.

**Why moved**: The contract is ~50 lines. The hard part is the off-chain DVT scanner that periodically checks on-chain signals (last active timestamp, oracle proof, multi-guardian attestation). Shipping the contract without the scanner creates a permanently unusable feature.

**Design sketch**:
```
DVT Scanner (off-chain)
  → polls N data sources (last tx, oracle, guardian attestation)
  → when threshold reached: submits willProof to WillExecutor
WillExecutor.sol
  → verifyWillProof(bytes proof) — calls PolicyRegistry (DVT verifier)
  → if valid and timelock elapsed: transfer assets to beneficiaries[]
  → guardian override: 2-of-3 can cancel within timelock window
```

**Dependencies**: PolicyRegistry contract (DVT verifier, planned in M7 or separate repo), off-chain DVT scanner daemon.

---

### M7.2 — Full ERC-7579 Module Compliance

**Current state**: M6 implements a "minimum compatibility shim" — `accountId`, `supportsModule`, `isModuleInstalled`, `isValidSignature`, `supportsInterface`. This passes the ERC-7579 reader interface but does not implement the write interface.

**Missing**:
- `installModule(uint256 moduleTypeId, address module, bytes calldata initData)`
- `uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)`
- `executeFromExecutor(ModeCode mode, bytes calldata executionCalldata)` for executor modules
- Guardian gate + timelock on `installModule` (prevent attacker from installing malicious module)

**Why M7**: Full module compliance enables the kernel/ZeroDev plugin ecosystem. Without it, AirAccount is self-contained but not extensible. This is a significant architectural addition and should be its own audit scope.

---

### M7.3 — EIP-1167 Minimal Proxy Factory

**Problem**: `AAStarAirAccountFactoryV7` bytecode grew to 24,966B (EIP-170 limit: 24,576B). Fixing with `optimizer_runs=200` bought 1.3KB margin, but the factory will exceed the limit again as features are added.

**Solution**: Refactor factory to use EIP-1167 minimal proxy (clone) pattern:
- Deploy one implementation contract (no size limit applies — only runtime code matters)
- Factory becomes a ~300B clone deployer — will never approach EIP-170

**Tradeoff**: Proxied accounts have one extra `DELEGATECALL` per call (~700 gas). Acceptable given AirAccount's main cost is precompile-based validation.

**Note**: This is incompatible with the current "non-upgradable" philosophy only if the implementation address is mutable. Use an immutable implementation pointer: users know exactly which implementation their account delegates to at creation time.

---

### M7.4 — ERC-7828 / ERC-7831 Chain-Specific Address Resolution

**What**: ERC-7828 defines a chain-qualified address format (`address@chainId`). ERC-7831 defines resolver contracts for cross-chain address lookup.

**Why**: As AirAccount deploys on multiple L2s with CREATE2, the same salt produces the same address — but users need a canonical way to reference "my account on Base vs my account on Arbitrum."

**Implementation**: Add `chainId()` helper + ERC-7831 resolver registration in factory. Low effort, high ecosystem value.

---

### M7.5 — L2 Deployment + Force-Exit Mechanism

**Targets**: Base, Arbitrum One, OP Stack chains, zkSync Era.

**Key concern**: L2 sequencer censorship. If a sequencer goes down or censors a user's transactions, the user must be able to exit to L1.

**Force-exit design**:
- For OP Stack: use native `L2ToL1MessagePasser` with delayed withdrawal
- For Arbitrum: use `ArbSys.sendTxToL1`
- AirAccount guardian threshold required to initiate force-exit (prevents single-sig theft via L1)

**Deployment**: Same CREATE2 salt → same address on all chains. Factory must be deployed at identical address (use `create2` with deterministic deployer like `0x4e59b44847b379578588920cA78FbF26c0B4956C`).

---

### M7.6 — Professional Security Audit

**Scope**: Full M6 codebase — AAStarAirAccountBase, AAStarAirAccountFactoryV7, SessionKeyValidator, AirAccountDelegate, CalldataParserRegistry, UniswapV3Parser.

**Options**:
- **Code4rena** competitive audit (~$50K–$150K prize pool, 1–2 week window)
- **Immunefi private audit** (fixed-price, faster turnaround)
- **Spearbit / Cantina** (premium, slower)

**Prerequisite**: M6 feature-complete, all tests passing, internal security review docs finalized.

**Output**: Public audit report in `docs/audit-report-v1.md`.

---

### M7.7 — Bug Bounty Program (Immunefi)

**Launch after**: M7.6 audit complete and findings resolved.

**Proposed severity/reward tiers**:
| Severity | Examples | Reward |
|----------|----------|--------|
| Critical | Drain any account, bypass guardian threshold | $50,000 |
| High | Bypass tier validation, forced recovery | $10,000 |
| Medium | Gas griefing, DoS on guardian operations | $2,000 |
| Low | Information disclosure, incorrect events | $500 |

**Scope exclusions**: Known accepted risks (EIP-7702 private key permanence, guardian self-dealing after trust is established).

---

### M7.11 — Railgun Privacy Pool Integration

**What**: Railgun uses shielded ERC-20 pools. Users "shield" tokens (deposit into Railgun) and later "unshield" (withdraw). From AirAccount's perspective, a deposit to Railgun is a token transfer to the Railgun proxy contract with a specific selector.

**Interop requirements**:
1. `RailgunParser` — `ICalldataParser` implementation that parses Railgun deposit calldata to extract `(tokenIn, amountIn)` for guard tier enforcement
2. `CalldataParserRegistry.registerParser(railgunProxy, RailgunParser)` — one-time setup
3. Guard tier applies normally: large Railgun deposits require Tier 3 (guardian co-sign)

**What we need to test (just needs to run)**:
- Deploy RailgunParser, register in registry
- Submit a mock Railgun deposit UserOp, verify guard enforces the token amount
- Withdraw direction: unshield returns tokens to AirAccount address — no parser needed

**Why M7 not M6**: Railgun proxy address and calldata format must be verified against current mainnet deployment. No contract code dependency, just parser implementation.

### M7.12 — Kohaku Relay Compatibility

**What**: Kohaku is a transaction relay/middleware layer built on top of Railgun. It submits Railgun transactions on behalf of users with an off-chain relay fee.

**Interop**: Kohaku relays already-signed Railgun transactions. Since the final transaction still calls the Railgun proxy, `RailgunParser` (M7.11) handles guard enforcement automatically. Kohaku-specific work:
- Verify Kohaku relay format doesn't break AirAccount's UserOp structure
- Test: Kohaku-relayed withdrawal flows through AirAccount without guard bypass

**Effort**: Low — mostly integration testing once M7.11 is done.

### M7.13 — ERC-5564 Stealth Address Support

**What**: ERC-5564 defines a protocol for stealth addresses: sender derives a one-time address from recipient's public key, sends assets there, publishes an announcement. Recipient scans announcements to find funds.

**Contract integration**:
- `AirAccountDelegate.announceForStealth(address stealth, bytes ephemeralKey, bytes metadata)` — publishes announcement via `IERC5564Announcer`
- Stealth address derivation is off-chain; contract just needs to call the announcer
- Receiving on stealth addresses: just a regular ETH/token receive (no special handling needed)

**Effort**: Low — ~50 lines. The main work is the off-chain TypeScript SDK for stealth address generation.

### M7.8 — Post-Quantum Signature Interface (Placeholder)

**Status**: Blocked by EVM precompile availability. NIST standardized ML-KEM (Kyber) and ML-DSA (Dilithium) in 2024. EVM precompiles likely 2027–2029 per EIP discussion.

**Action now**: Reserve `algId = 0x10` in the algorithm registry. Add interface comment:
```solidity
// algId 0x10: Reserved for post-quantum signature scheme (ML-DSA/Dilithium).
// Requires EVM precompile (EIP-TBD). Implementation deferred until precompile availability.
```

No implementation. Just the reservation prevents future algId collision.

---

### M7.9 — ERC-165 / ERC-1271 Full Compliance Audit

**What**: Verify all `supportsInterface` return values match the correct EIP-165 interface IDs. Common source of subtle bugs when upgrading dependencies.

**Tools**: `cast interface` + manual cross-check against EIP-165 registry.

**Low risk, low effort**: One review pass + test coverage.

---

### M7.10 — AirAccountDelegate: ArrayLengthMismatch Custom Error

**Current code** (`src/core/AirAccountDelegate.sol`):
```solidity
require(targets.length == values.length && values.length == calldatas.length, "length mismatch");
```

**Fix**:
```solidity
error ArrayLengthMismatch();
if (targets.length != values.length || values.length != calldatas.length) revert ArrayLengthMismatch();
```

Trivial cleanup. Already noted in M6 security review (I-2).

---

---

## M7 Agentic Economy Features

These features position AirAccount as the native wallet layer for AI agents and the emerging agentic economy. Research basis: EIP-8004 (deployed Jan 2026), x402 HTTP payment protocol (Coinbase, Feb 2026), ERC-7715/7710 delegation standards.

**Design principle**: AirAccount owner retains custody. Agents receive *scoped, revocable session keys* — not independent wallets. This matches the "user-owned account + agent delegation" pattern recommended across all major agent frameworks (LangChain, AutoGPT, Eliza, etc.).

---

### M7.14 — Agent Session Key Module (ERC-7579 Validator)

**What**: Extend `SessionKeyValidator` with agent-specific constraints:
- `velocityLimit`: max N calls per time window (prevents runaway agents)
- `callTargetAllowlist`: agent can only call pre-approved contracts (prompt injection defense)
- `tokenSpendCap`: per-session token spend limit (in addition to global tier limits)
- `permissionId`: maps to ERC-7715 `wallet_grantPermissions` for wallet interop

**Why**: Current session keys grant time-limited ECDSA signing with no per-call constraints. An agent compromised by prompt injection can drain allowance in one block. Per-session caps + allowlists add a second line of defense.

**Interface sketch**:
```solidity
struct AgentSessionConfig {
    address sessionKey;       // Agent's EOA
    uint48  expiry;           // Unix timestamp
    uint16  velocityLimit;    // Max calls per window
    uint32  velocityWindow;   // Window in seconds
    address[] callTargets;    // Allowlisted contracts (empty = all)
    address spendToken;       // ERC-20 address (address(0) = ETH)
    uint256 spendCap;         // Max cumulative spend for this session
    bytes4  requiredSelector; // Optional: restrict to one function
}

function grantAgentSession(address account, AgentSessionConfig calldata cfg) external;
```

**Maps to**: ERC-7715 `wallet_grantPermissions`, ERC-7710 Delegation.

**Effort**: Medium — extends SessionKeyValidator (~150 lines). New storage slot per session key per account.

---

### M7.15 — x402 Native Payment Support

**What**: First-class support for the HTTP 402 payment protocol (Coinbase, Feb 2026). Enables AirAccount to pay AI API endpoints, autonomous agent services, and content APIs without manual approval.

**Background**: x402 uses EIP-3009 `transferWithAuthorization` for USDC. A client calls an HTTP endpoint → receives `402 Payment Required` with payment details → signs a USDC transfer authorization → retries with `X-PAYMENT` header. No on-chain transaction per call; settlement is deferred to a facilitator.

**Contract integration**:
1. **`x402Signer` helper** — TypeScript SDK integration: `@x402/core` + `@x402/express`. AirAccount session key signs EIP-3009 authorization off-chain. No new contract needed for basic x402.
2. **`X402Paymaster.sol`** (optional) — Paymaster that covers gas by accepting x402 payment proofs. Paymasters already have a hook point; x402 verification happens in `validatePaymasterUserOp`.
3. **`setX402Budget(address token, uint256 dailyBudget)` on account** — owner sets per-token daily budget for autonomous x402 spending. Guard enforces limit.

**SDK integration**:
```typescript
// Agent pays x402 endpoint using AirAccount session key
import { createX402Client } from "@x402/core";
const client = createX402Client({
  signer: sessionKeyAccount,   // viem LocalAccount
  token: USDC_SEPOLIA,
  maxAmount: parseUnits("1", 6), // $1 cap
});
const response = await client.fetch("https://api.example.com/v1/chat");
```

**Effort**: Low for SDK integration (no new contract). Medium for optional `X402Paymaster`.

---

### M7.16 — ERC-8004 Agent Identity Integration

**What**: ERC-8004 "Trustless Agents" defines three on-chain registries for AI agents:
- **Identity Registry** (ERC-721 NFT): each agent gets a unique ID with metadata (description, capabilities, version)
- **Reputation Registry**: on-chain feedback scoring — callers rate agents after interactions
- **Validation Registry**: pluggable verifiers for agent behavior proofs

**Deployed on Sepolia**: `0x8004A818BFB912233c491871b3d84c89A494BD9e` (Identity Registry, Jan 29, 2026).

**AirAccount integration**:
1. **`setAgentWallet(uint256 agentId, address wallet)`** — owner links an ERC-8004 agent NFT to a session key address. Creates a verified binding: "agent #42 uses this session key for account 0xABC".
2. **Factory extension**: `createAccountForAgent(agentId, cfg)` — deploy AirAccount with ERC-8004 identity pre-registered. Session key = agent wallet.
3. **Reputation hook** (optional): after each agent-signed execute(), emit event for reputation indexers.

**Interface sketch**:
```solidity
interface IERC8004IdentityRegistry {
    function registerAgent(address wallet, bytes calldata metadata) external returns (uint256 agentId);
    function getAgentWallet(uint256 agentId) external view returns (address);
}

// In AAStarAirAccountBase:
function setAgentWallet(uint256 agentId, address agentWallet, address erc8004Registry) external onlyOwner;
```

**Effort**: Low (~50 lines). Mainly storage + event. Registry calls are view/write to existing deployed contract.

---

### M7.17 — Multi-Agent Orchestration (Hierarchical Delegation)

**What**: AirAccount owner grants a *primary agent* (orchestrator) a session key. The orchestrator sub-delegates scoped permissions to *sub-agents* (tools). Matches the architecture of LangChain, AutoGPT, Eliza, and OpenAI Swarm.

**Design**:
```
Owner (AirAccount)
  └─ Orchestrator session key (full-scope, expiry T)
       ├─ Sub-agent A session key (callTarget: DEX only, spendCap: $100, expiry T/2)
       └─ Sub-agent B session key (callTarget: NFT marketplace only, no spend, expiry T/2)
```

**Contract mechanism**: Extend `SessionKeyValidator` so a session key holder can issue sub-session-keys with equal or narrower scope (cannot escalate beyond their own grants). The chain of delegation is verifiable on-chain.

**EIP alignment**: ERC-7710 Delegation (draft). AirAccount session keys become ERC-7710 delegation receipts.

**Effort**: Medium-Hard. Requires recursive scope validation in SessionKeyValidator. New `delegateSession(address subKey, AgentSessionConfig calldata subCfg)` function callable only by an existing valid session key holder.

---

### M7.18 — Prompt Injection Defense (Execution-Layer Allowlist)

**What**: Protect against prompt injection attacks where a malicious response tricks an agent into calling unintended contracts. Defense at execution layer: session key's `callTargetAllowlist` (from M7.14) is enforced on-chain, even if the agent's reasoning layer is compromised.

**Additional measures**:
1. **Selector allowlist per callTarget**: agent can only call specific functions on approved contracts (e.g., `transfer(address,uint256)` on USDC, nothing else).
2. **Value cap**: agent cannot transfer native ETH above a per-call cap (default: 0 if not explicitly set).
3. **Revert on unknown selector**: if calldata selector is not in allowlist, revert with `AgentCallForbidden(target, selector)` — agent cannot accidentally call `selfdestruct` or admin functions.

**Why this matters**: Prompt injection is currently the #1 attack vector on AI agents with wallet access (Wiz Research, 2026). The contract layer is the last line of defense after reasoning-layer mitigations.

**Effort**: Low — extends M7.14 AgentSessionConfig with `bytes4[] selectorAllowlist` per callTarget. Enforcement is a few extra lines in session key validation.

---

## Agentic Economy Research Summary (2026-03-20)

### EIP-8004 Status
- Deployed on Sepolia: `0x8004A818BFB912233c491871b3d84c89A494BD9e`
- Three registries: Identity (ERC-721), Reputation (feedback), Validation (pluggable verifiers)
- Philosophy: agents as first-class on-chain citizens with verifiable identity and reputation

### x402 Protocol Status
- GitHub: `coinbase/x402` (Feb 2026)
- Production-ready for USDC on Base; Sepolia support available
- EIP-3009 `transferWithAuthorization` — off-chain signature, no per-call gas
- TypeScript SDK: `@x402/core`, `@x402/express`, `@x402/next`
- ERC-4337 integration: agent session key signs EIP-3009 authorization inside UserOp

### Agentic Framework Landscape (Top Picks for AirAccount Integration)

| Framework | Wallet Support | Notes |
|-----------|---------------|-------|
| **ElizaOS** | Plugin-based, EVM plugins exist | Most active Web3-native agent framework |
| **LangChain** | `langchain-community` EVM tools | Widest ecosystem; Python + JS |
| **Coinbase AgentKit** | Native USDC/Base/x402 | Best x402 integration; wallet = MPC |
| **AutoGPT** | Forge plugin system | Less Web3-focused |
| **OpenAI Swarm** | No native wallet | Research framework, lightweight |

**Key insight**: All frameworks use the same pattern — agent has a wallet address + signs transactions. AirAccount fits naturally as the wallet with added tier/guard protection. The missing piece is a standard SDK adapter: `airaccount-agentkit` TypeScript package wrapping viem + session key management.

### Recommended M7 Agentic Stack
```
AirAccount (custody)
  └─ AgentSessionKey Module (M7.14) ← per-agent scoped permissions
       └─ x402 Signer (M7.15) ← automatic micropayment signing
            └─ ERC-8004 Identity (M7.16) ← verifiable agent identity
```

This stack enables: agent pays API → API charges USDC → agent identity is verifiable → all spend is capped by owner-set limits.

---

## M7 Non-Goals

These are explicitly OUT of M7 scope:

| Item | Reason |
|------|--------|
| Frontend wallet UI | Separate project; AirAccount is contract layer only |
| ERC-4337 v0.7 migration | v0.6 EntryPoint is stable; v0.7 migration is a breaking change requiring full re-audit |
| MushroomDAO governance | Community/DAO scope, not contract scope |
| Social graph / HyperCapital on-chain | Research phase, not implementation ready |
| Full x402 facilitator | Server-side component; out of scope for contract layer |
| On-chain AI inference | Requires dedicated compute layer (EigenLayer AVS or similar) |

---

## Release Criteria for M7

- [ ] M6.1 + M6.2 implemented and tested (prerequisite — must be in M6)
- [ ] M7.6 audit complete with no unresolved Critical/High findings
- [ ] M7.7 bug bounty live on Immunefi
- [ ] M7.2 ERC-7579 full compliance: `installModule` + `executeFromExecutor` with tests
- [ ] M7.3 proxy factory deployed on mainnet + all target L2s (M7.5)
- [ ] M7.14 Agent Session Key Module: `grantAgentSession` + velocity/allowlist enforcement with tests
- [ ] M7.15 x402 TypeScript SDK integration: session key signs EIP-3009 off-chain
- [ ] M7.16 ERC-8004 `setAgentWallet` binding: verified agent → session key linkage
- [ ] All tests passing: target 500+ tests
- [ ] `docs/audit-report-v1.md` published

---

## Timeline Estimate

| Phase | Items | Notes |
|-------|-------|-------|
| M6 completion | M6.1, M6.2 | Prerequisite for audit |
| M7 prep | M7.10, M7.9, M7.8 | Low-effort items, can batch with M6 |
| M7 core | M7.2, M7.3, M7.4 | 4–6 weeks implementation |
| M7 agentic | M7.14, M7.15, M7.16 | 3–4 weeks; M7.14 first (foundation) |
| M7 advanced | M7.17, M7.18 | Optional; adds 2–3 weeks |
| Audit | M7.6 | 2–4 weeks depending on firm |
| Launch | M7.5, M7.7 | Post-audit deployment + bug bounty |
| Long-term | M7.1, M7.8, M7.11–M7.13 | DVT-dependent or privacy-dependent |

---

## WalletBeat Stage 0 / Stage 1 / Stage 2 — Full Feature Table & M7 TODO Integration

**Assessment date**: 2026-03-21 | **Baseline**: AirAccount v0.15.0 (M6)

WalletBeat rates **end-to-end wallet applications**. AirAccount is the **smart contract layer** — most Stage 1/2 criteria are CLIENT (frontend) responsibilities. The tables below mark each criterion's responsibility layer and current contract-layer status.

### Stage 0 — Source Code Publicly Visible

| Standard | AirAccount Status | Notes |
|----------|-------------------|-------|
| Source code publicly visible | ✅ PASS | GPL-3.0, GitHub public |

**Stage 0: ACHIEVED.**

---

### Stage 1 — 9 Criteria

| # | Criterion | Layer | Contract Status | M7 Action |
|---|-----------|-------|-----------------|-----------|
| S1-1 | Security Audit (last 12 months) | Contract | ⚠️ PARTIAL — internal only | **M7.6: External audit (blocking)** |
| S1-2 | Hardware Wallet Support (≥3) | CLIENT | 🆗 P256 on-chain | Frontend: Ledger/Trezor/GridPlus SDK |
| S1-3 | Chain Verification (L1 light client) | CLIENT | 🆗 | Frontend: Helios integration |
| S1-4 | Private Transfers (by default) | Contract | ❌ FAIL | M7.11: Railgun parser + SDK |
| S1-5 | Account Portability | Contract | ✅ PASS | — |
| S1-6 | Support Own Node | CLIENT | 🆗 | Frontend: RPC config UI |
| S1-7 | FOSS License | Contract | ✅ PASS | — |
| S1-8 | Address Resolution (ENS) | CLIENT | 🆗 | Frontend: viem ENS + normalize() |
| S1-9 | Browser Integration (EIP-1193) | CLIENT | 🆗 | Frontend: EIP-1193 provider + EIP-6963 |

**Contract-layer Stage 1 blocker: M7.6 (external audit). S1-4 private transfers is a hard contract blocker deferred to M7.11.**

---

### Stage 2 — 10 Criteria

| # | Criterion | Layer | Contract Status | M7 Action |
|---|-----------|-------|-----------------|-----------|
| S2-1 | Bug Bounty Program | Contract | ❌ FAIL | **M7.7: Immunefi (after M7.6)** |
| S2-2 | Address Privacy | Contract | ⚠️ PARTIAL — OAPD reduces correlation | M7.11 improves further |
| S2-3 | Multi-Address Correlation Prevention | Contract | ✅ PASS | OAPD: salt=keccak256(owner+dappId) |
| S2-4 | TX Inclusion (L2→L1 force-exit) | Contract | ❌ N/A — L1 only | **M7.5: L2 deployment + force-exit** |
| S2-5 | Chain Configurability | CLIENT | 🆗 | Frontend: RPC config |
| S2-6 | Funding Transparency | Project | ❔ UNKNOWN | Add FUNDING.md to repo |
| S2-7 | Fee Transparency | CLIENT | ⚠️ PARTIAL — data available | Frontend: daily limit UI |
| S2-8 | Chain Address Resolution (ERC-7828/7831) | Contract | ❌ FAIL | **M7.4: ERC-7828 helper** |
| S2-9 | Account Abstraction (ERC-4337) | Contract | ✅ PASS+ | Exceeds requirement |
| S2-10 | Transaction Batching | Contract | ✅ PASS | executeBatch implemented |

---

### WalletBeat TODO — Integrated into M7

#### Stage 1 TODOs (contract layer)
- [ ] **M7.6** — Commission professional security audit (CodeHawks/Code4rena, ~$15–30k prize pool). **Stage 1 gating blocker.**
- [ ] **M7.11** — Railgun privacy pool integration (RailgunParser + CalldataParserRegistry). Partial S1-4 coverage.
- [ ] Frontend companion: P256 hardware wallet SDK (Ledger/Trezor/GridPlus) — see HW Wallet Integration Guide below.
- [ ] Frontend companion: Helios light client integration — see Helios Integration Guide below.
- [ ] Frontend companion: ENS address resolution via viem `getEnsAddress` + `normalize()`.
- [ ] Frontend companion: EIP-1193 provider wrapper + EIP-6963 multi-wallet discovery.

#### Stage 2 TODOs (contract layer)
- [ ] **M7.7** — Immunefi bug bounty program (after M7.6 audit complete). ~$50k initial funding.
- [ ] **M7.5** — L2 deployment (Base, Arbitrum, OP Stack) + canonical bridge force-exit. S2-4.
- [ ] **M7.4** — ERC-7828 chainId helper + ERC-7831 resolver. S2-8.
- [ ] **FUNDING.md** — Add funding transparency document. Low-effort, S2-6.

#### Stage 2 TODOs (frontend companion)
- [ ] Daily limit UI: show `guard.todaySpent()`, `getDeposit()`, gas sponsorship status (S2-7).
- [ ] Per-DApp address UI using OAPD salt derivation (S2-2 improvement).
- [ ] ERC-5792 `wallet_sendCalls` wrapping `executeBatch` (S2-10 UI layer).

---

## Professional Audit Pricing & Open-Source Discount Guide

### Pricing Reference (2026)

| Auditor | Price Range | Open-Source / Public Goods | Timeline |
|---------|-------------|---------------------------|----------|
| **CodeHawks (Cyfrin)** | $5k–30k prize pool | ✅ Public goods track + subsidized community audits | 1–2 weeks |
| **Code4rena** | $20k–50k prize pool | ✅ Low-budget public goods accepted | 1–2 weeks |
| **Sherlock** | $15k–40k | ❌ Commercial pricing | 2–3 weeks |
| **Trail of Bits** | $500–1500/h (min $50k) | ❌ | 4–8 weeks |
| **OpenZeppelin** | $50k–100k+ | ❌ | 4–8 weeks |
| **Spearbit/Cantina** | $100k+ | ❌ | 6–12 weeks |

### Recommendation for AirAccount (Public Goods / Academic)

AirAccount is GPL-3.0 open source, academic research (CMU PhD), no commercial profit. Best path:

1. **Primary**: Apply to **CodeHawks** (codehawks.com) as a public goods project. Contact Cyfrin directly — Patrick Collins is known to offer reduced-cost competitive audits for academic/open-source work. Target $15–20k prize pool.
2. **Alternative**: **Code4rena** with $20k prize pool — the competitive format maximizes coverage for the budget.
3. **Timing**: After M6 feature-complete (M7.6 scope = M6 codebase). Audit scope: `AAStarAirAccountBase`, `AAStarAirAccountFactoryV7`, `SessionKeyValidator`, `AirAccountDelegate`, `CalldataParserRegistry`, `UniswapV3Parser`, `AAStarGlobalGuard`.

---

## Frontend Integration Guide: Hardware Wallet SDK

### Overview

AirAccount's on-chain P-256, ECDSA, BLS validators provide the cryptographic primitives. Hardware wallet integration is a **frontend SDK responsibility** that maps device signing to AirAccount's UserOperation signature format.

### Key Packages

```bash
# Hardware communication
pnpm add @ledgerhq/device-management-kit @ledgerhq/hw-app-eth @ledgerhq/hw-transport-webhid

# Trezor
pnpm add @trezor/connect-web

# GridPlus Lattice
pnpm add gridplus-sdk

# Cryptography
pnpm add @noble/curves webauthn-p256

# ERC-4337 utilities
pnpm add viem permissionless wagmi @wagmi/connectors
```

> ⚠️ **Do NOT use `@ledgerhq/connect-kit`** — was compromised with a crypto drainer. Use `@ledgerhq/device-management-kit` instead.

### Device Support Matrix

| Device | ECDSA | P-256/WebAuthn | Notes |
|--------|-------|----------------|-------|
| Ledger Nano X/S+ | ✅ | ✅ via FIDO2 mode | Requires firmware update for WebAuthn |
| Trezor Model T/Safe | ✅ | ❌ (in progress) | P-256 planned; use ECDSA for now |
| GridPlus Lattice1 | ✅ | ❌ | Best for Paymaster operators, not end-users |
| YubiKey (FIDO2) | — | ✅ | WebAuthn only; maps directly to AirAccount P-256 |

### Ledger + viem Integration Pattern

```typescript
import TransportWebHID from '@ledgerhq/hw-transport-webhid';
import Eth from '@ledgerhq/hw-app-eth';
import { getUserOpHash } from 'permissionless';

const transport = await TransportWebHID.create();
const eth = new Eth(transport);
const { address } = await eth.getAddress("m/44'/60'/0'/0/0");

// Sign UserOp hash with Ledger
const userOpHash = getUserOpHash(userOp, entryPointAddress, chainId);
const { signature } = await eth.signPersonalMessage(
  "m/44'/60'/0'/0/0",
  userOpHash.slice(2)
);
userOp.signature = signature;
```

### WebAuthn / YubiKey → On-Chain P-256

```typescript
// Registration: get P-256 public key from hardware key
const credential = await navigator.credentials.create({
  publicKey: {
    challenge: crypto.getRandomValues(new Uint8Array(32)),
    rp: { name: 'AirAccount', id: 'airaccount.io' },
    user: { id: new Uint8Array([1]), name: 'user', displayName: 'User' },
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }], // ES256 = P-256
  },
});
// Extract x, y coordinates → store in AirAccount as P-256 public key

// Signing: sign UserOp hash with hardware key
const assertion = await navigator.credentials.get({
  publicKey: {
    challenge: userOpHash,       // keccak256 of UserOp
    allowCredentials: [{ type: 'public-key', id: credentialId }],
    userVerification: 'required',
  },
});
// Extract (r, s) from assertion.response.signature → AirAccount signature
```

### On-Chain P-256 Verifier

Use **daimo-eth/p256-verifier** (audited, ~330k gas):

```bash
forge install daimo-eth/p256-verifier
```

```solidity
import { WebAuthn } from "p256-verifier/src/WebAuthn.sol";
// Already integrated in AirAccount's _validateP256()
```

### EIP-6963 Multi-Wallet Discovery

```bash
pnpm add @mipd/store
```

```typescript
import { MIPD } from '@mipd/store';
const providerStore = MIPD.createStore();
// Auto-discovers Ledger, Trezor, MetaMask extensions via EIP-6963
providerStore.subscribe(providers => renderWalletButtons(providers));
window.dispatchEvent(new Event('eip6963:requestProvider'));
```

### Recommended Open-Source References

| Project | URL | What to Learn |
|---------|-----|---------------|
| **passkeys-4337/smart-wallet** | https://github.com/passkeys-4337/smart-wallet | P-256 WebAuthn + ERC-4337 full flow |
| **ZeroDev Kernel signers** | https://github.com/zerodevapp/zerodev-signer-examples | Modular HW wallet signer interface |
| **Candide AbstractionKit** | https://github.com/candidelabs/abstractionkit | Safe-based account + passkey plugin |
| **Coinbase Smart Wallet** | https://github.com/coinbase/smart-wallet | Consumer UX + Ledger support |

### Gas Reference

| Sig Type | Gas per validateUserOp |
|----------|----------------------|
| ECDSA (secp256k1) | ~3,000 gas (ecrecover precompile) |
| P-256 (daimo verifier) | ~330,000 gas |
| P-256 (EIP-7212 precompile, future) | ~3,450 gas |

> EIP-7212 (P-256 precompile) is live on Base, zkSync. On mainnet/Sepolia, use daimo verifier fallback.

---

## Frontend Integration Guide: Helios Light Client

### What is Helios

Helios (github.com/a16z/helios) is a trustless Ethereum light client in Rust + WASM. It converts any untrusted centralized RPC into a cryptographically verified RPC by checking against Beacon Chain consensus. Syncs in ~2 seconds.

**Supported networks**: Ethereum mainnet, Sepolia, Holesky, Base, OP Stack, Linea.

### Installation

```bash
pnpm add @a16z/helios viem
```

### Basic Integration with viem

```typescript
import { createHeliosProvider } from '@a16z/helios';
import { createPublicClient, custom } from 'viem';
import { mainnet } from 'viem/chains';

const heliosProvider = await createHeliosProvider({
  executionRpc: 'https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY',
  consensusRpc: 'https://www.lightclientdata.org', // Default (run by a16z, free)
  network: 'mainnet',
  checkpoint: '0x85e6151a246e8fdba36db27a0c7678a575346272fe978c9281e13a8b26cdfa68',
}, 'ethereum');

await heliosProvider.waitSynced(); // ~2 seconds

const client = createPublicClient({
  chain: mainnet,
  transport: custom(heliosProvider),
});
```

### Production Pattern: Helios + Fallback

```typescript
export async function createVerifiedClient(network = 'mainnet') {
  const executionRpc = `https://eth-${network}.g.alchemy.com/v2/${ALCHEMY_KEY}`;
  try {
    const helios = await createHeliosProvider({
      executionRpc,
      consensusRpc: 'https://www.lightclientdata.org',
      network,
      checkpoint: CHECKPOINTS[network],
    }, 'ethereum');
    // Timeout after 3s — don't block app startup
    await Promise.race([helios.waitSynced(), new Promise((_, r) => setTimeout(r, 3000))]);
    return { client: createPublicClient({ chain, transport: custom(helios) }), trustless: true };
  } catch {
    // Graceful fallback to standard RPC
    return { client: createPublicClient({ chain, transport: http(executionRpc) }), trustless: false };
  }
}
```

### Consensus RPC Options (Free)

| Endpoint | Provider | Notes |
|----------|---------|-------|
| `https://www.lightclientdata.org` | a16z (default) | Reliable, no auth required |
| Beaconcha.in API | Beaconchain | Free tier |
| dRPC Beacon RPC | dRPC | Free, multiple regions |
| Your own Nimbus/Lodestar | Self-hosted | Best for production |

### Checkpoints

Get from beaconcha.in (mainnet) or sepolia.beaconcha.in (Sepolia). Checkpoints older than 2 weeks are unsafe — cache and refresh weekly.

### ERC-4337 Consideration

Helios is **execution-layer only** — it does NOT support bundler methods (`eth_sendUserOperation`, `eth_getUserOperationByHash`). Use a hybrid approach:

```typescript
// Trustless reads via Helios
const balance = await heliosClient.getBalance({ address });

// Bundler calls via traditional RPC (acceptable — bundler is not in trust model)
const userOpHash = await bundlerClient.sendUserOperation(userOp);
```

### Open-Source References

| Project | URL |
|---------|-----|
| a16z/helios | https://github.com/a16z/helios |
| Helios npm | https://www.npmjs.com/package/@a16z/helios |
| Setup guide (Chainstack) | https://chainstack.com/helios-client/ |

### Deployment Checklist

- [ ] Add `HELIOS_CHECKPOINT` env var, refresh weekly via CI job
- [ ] Implement fallback to HTTP RPC when Helios fails (see pattern above)
- [ ] Show "trustless" / "unverified" indicator in wallet UI
- [ ] Use Helios for balance/state reads; traditional RPC for bundler calls
- [ ] Test on Sepolia before mainnet deployment

---

## Frontend Integration Guide: ENS Address Resolution

### viem Built-in ENS (Recommended)

```typescript
import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { normalize } from 'viem/ens';

const client = createPublicClient({ chain: mainnet, transport: http() });

// Before calling execute(dest, ...) in AirAccount:
async function resolveRecipient(input: string): Promise<`0x${string}`> {
  if (input.endsWith('.eth') || input.includes('.')) {
    const resolved = await client.getEnsAddress({ name: normalize(input) });
    if (!resolved) throw new Error(`ENS name ${input} not found`);
    return resolved;
  }
  return input as `0x${string}`; // Already a raw address
}
```

**Always call `normalize()` before `getEnsAddress()`** to prevent forbidden characters.

### L2 Cross-Chain ENS (CCIP-Read / EIP-3668)

For names managed on L2 (e.g., `alice.linea.eth`), viem handles CCIP-Read automatically when you pass `gatewayUrls`:

```typescript
const address = await client.getEnsAddress({
  name: normalize('alice.linea.eth'),
  gatewayUrls: ['https://ccip.ens.eth'],
  universalResolverAddress: '0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e',
});
```

### Reference Implementations

| Project | URL |
|---------|-----|
| Rainbow Wallet | https://github.com/rainbow-me/rainbow |
| Frame Wallet | https://github.com/floating/frame |
| ENS CCIP-Read docs | https://docs.ens.domains/resolvers/ccip-read/ |

---

## Frontend Integration Guide: EIP-1193 Browser Provider + EIP-6963

### AirAccount as EIP-1193 Provider

To make AirAccount discoverable by DApps (MetaMask-compatible), wrap it as an EIP-1193 provider:

```typescript
// Core: eth_sendTransaction → UserOp conversion
const createAirAccountProvider = (airAccount, bundler, publicRpc) => ({
  request: async ({ method, params }) => {
    switch (method) {
      case 'eth_requestAccounts':
      case 'eth_accounts':
        return [airAccount.address];

      case 'eth_sendTransaction': {
        const tx = params[0];
        // Build + sign + submit UserOp
        const userOp = await buildUserOp(airAccount, tx);
        const opHash = await bundler.sendUserOperation(userOp, ENTRY_POINT);
        // Return tx hash after UserOp is included
        const receipt = await bundler.waitForUserOperationReceipt({ hash: opHash });
        return receipt.receipt.transactionHash;
      }

      case 'personal_sign':
        return airAccount.signMessage(params[0]);

      case 'eth_signTypedData_v4':
        return airAccount.signTypedData(JSON.parse(params[1]));

      default:
        // Forward read-only calls to public RPC
        return publicRpc.request({ method, params });
    }
  },
});
```

### EIP-6963 Wallet Announcement

```typescript
// AirAccount wallet extension announces itself to DApps
const info = {
  uuid: crypto.randomUUID(),
  name: 'AirAccount',
  icon: 'data:image/svg+xml,...', // wallet icon data URL
  rdns: 'io.airaccount',
};
window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
  detail: Object.freeze({ info, provider: airAccountProvider }),
}));
window.addEventListener('eip6963:requestProvider', () =>
  window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
    detail: Object.freeze({ info, provider: airAccountProvider }),
  }))
);
```

### wagmi Integration

```typescript
import { createConfig } from 'wagmi';
import { custom } from 'viem';

const config = createConfig({
  connectors: [
    // Auto-discovers AirAccount via EIP-6963
  ],
  client: createWalletClient({ transport: custom(airAccountProvider) }),
});
```

### Reference Implementations

| Project | URL |
|---------|-----|
| Coinbase Wallet SDK (EIP-1193 + EIP-6963) | https://github.com/coinbase/coinbase-wallet-sdk |
| MIPD (EIP-6963 discovery) | https://github.com/wevm/mipd |
| Frame Wallet (EIP-1193 provider) | https://github.com/floating/frame |
| WalletConnect EIP-6963 reference | https://github.com/WalletConnect/EIP6963 |

---

## Frontend Integration Guide: Private Transfers (Railgun / Kohaku SDK)

### Does Railgun SDK cover S1-4 Private Transfers?

**Yes** — `@railgun-community/wallet` SDK enables shielded token pools from any ERC-4337 account. Kohaku (Ethereum Foundation framework) uses Railgun as its privacy protocol layer, so integrating Railgun covers both.

### Key Packages

```bash
pnpm add @railgun-community/wallet @railgun-community/shared-models @railgun-community/engine
```

### What AirAccount Needs (Contract Layer — M7.11)

```solidity
// RailgunParser.sol — ICalldataParser implementation
// Parses Railgun multicall() calldata to extract (tokenIn, amountIn)
// so AAStarGlobalGuard can enforce tier limits on shielding operations

contract RailgunParser is ICalldataParser {
    function parseCalldata(address, bytes calldata data)
        external pure returns (address token, uint256 amount) {
        // Decode RelayAdapt.multicall(Transaction[] calls) calldata
        // Extract token + amount from first Transaction's tokenType/tokenAddress/amount fields
    }
}
```

Register once at factory deploy:
```typescript
registry.registerParser(RAILGUN_RELAY_ADAPT_ADDRESS, railgunParserAddress);
```

### Frontend Shielding Flow

```typescript
import { RailgunWallet } from '@railgun-community/wallet';

// 1. Initialize Railgun wallet
const railgunWallet = await RailgunWallet.create(db, provider);

// 2. Shield tokens into private pool (from AirAccount)
const shieldTx = await railgunWallet.populateShield(
  tokenAddress, amount, railgunRecipientAddress
);

// 3. Submit as AirAccount UserOp (guard checks tier via RailgunParser)
const userOp = await buildUserOpForExecute(
  airAccountAddress, shieldTx.to, shieldTx.value, shieldTx.data
);
await bundler.sendUserOperation(userOp, ENTRY_POINT);
```

### Reference Implementation

| Project | URL | Notes |
|---------|-----|-------|
| Railway Wallet | https://github.com/Railway-Wallet/Railway-Wallet | Production Railgun wallet, fully open source |
| Railgun SDK | https://github.com/Railgun-Community/wallet | Core SDK |
| Kohaku | https://github.com/ethereum/kohaku | EF privacy framework (wraps Railgun) |
| Railgun Docs | https://docs.railgun.org/developer-guide | 9-phase init guide |

---

## ERC-7579 + `_enforceGuard` Integration Design

### Are the Two Guards Duplicates?

**No.** They are orthogonal:

| Check | What it does | When triggered |
|-------|-------------|----------------|
| Module auth check | "Is caller an installed executor module?" | At `executeFromExecutor` entry |
| `_enforceGuard` | Daily spend limit + tier level enforcement | At execution dispatch |

One is identity/authentication, the other is spending policy. They never overlap.

### Gas Cost Analysis

| Path | Gas Breakdown | Total |
|------|--------------|-------|
| Normal `execute()` | EntryPoint 35k + sig verify 5–50k + guard 3–8k | ~43–93k |
| `executeFromExecutor` + guard | Module auth SLOAD 100–2100 + guard 3–8k | ~3–10k |
| **Net difference** | executeFromExecutor saves 30–50k gas vs execute() | **Still cheaper** |

Adding `_enforceGuard` to `executeFromExecutor` costs ~3,000–8,000 gas but saves 30,000+ gas vs a standard UserOp. The guard does not cause a "gas spike" — it's a net saving.

### Elegant Integration: "Daily Limit Only" for Executor Calls

The key design insight: `installModule` requires **guardian 2-of-3 approval + timelock**. That IS the tier-3 authorization. Once a module is trusted-and-installed, its calls only need spending limit enforcement, not tier re-checking.

**`algId = 0x00` = EXECUTOR_MODE** — signals guard to skip tier check, enforce daily limit only:

```solidity
// In AAStarAirAccountBase.sol
function executeFromExecutor(ModeCode mode, bytes calldata executionCalldata)
    external
    nonReentrant
    returns (bytes[] memory returnData)
{
    // 1. Auth: caller must be an installed ERC-7579 executor module
    if (!_installedModules[msg.sender][MODULE_TYPE_EXECUTOR]) {
        revert NotInstalledExecutor();
    }

    // 2. Decode execution based on ModeCode callType
    (CallType callType,) = mode.decodeMode();
    if (callType == CALLTYPE_SINGLE) {
        (address target, uint256 value, bytes calldata callData) =
            executionCalldata.decodeSingle();

        // 3. Guard: daily limit only (algId=0x00 = executor mode, skip tier)
        // installModule already required guardian 2-of-3 — that is the tier auth.
        // This avoids duplicate tier checking without sacrificing spend protection.
        if (address(guard) != address(0)) {
            guard.checkTransaction(target, value, 0x00);
        }

        returnData = new bytes[](1);
        returnData[0] = _call(target, value, callData);
    }
    // CALLTYPE_BATCH: iterate, same pattern
}
```

**In `AAStarGlobalGuard.checkTransaction`**, handle `algId=0x00`:

```solidity
function checkTransaction(address dest, uint256 value, uint8 algId) external {
    require(msg.sender == account, "Not account");

    if (algId == 0x00) {
        // Executor mode: daily ETH limit only, no tier check
        // Module was guardian-approved at installModule time
        _checkAndAccumulateDailySpend(value);
        return;
    }

    // Normal tiered path (T1/T2/T3 based on algId)
    _checkTier(dest, value, algId);
    _checkAndAccumulateDailySpend(value);
}
```

### installModule Security Gate

`installModule` must require guardian 2-of-3 to prevent an attacker from installing a malicious executor that drains the account via the daily-limit-only path:

```solidity
function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
    external
{
    // Guardian threshold: same as social recovery (2-of-3, with timelock)
    _requireGuardianApproval();  // or: require(msg.sender == address(this)) from guardian-signed UserOp

    require(module != address(0), "ModuleZero");
    require(moduleTypeId <= MODULE_TYPE_FALLBACK, "UnknownModuleType");

    _installedModules[module][moduleTypeId] = true;
    emit ModuleInstalled(moduleTypeId, module);

    IModule(module).onInstall(initData);
}
```

### Summary: Zero Duplication, No Gas Spike

```
installModule (guardian-gated, one-time) → tier authorization
executeFromExecutor → daily limit enforcement (via guard, algId=0x00)
execute() (via UserOp) → full tier + daily limit (via guard, algId=resolved)
```

Each path runs exactly one guard check, with the appropriate scope. The ERC-7579 module system does not compromise AirAccount's tier security model; it delegates tier authorization to the `installModule` gating step.

