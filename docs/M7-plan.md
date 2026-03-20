# M7 Design & Planning Document — AirAccount v0.16.0

**Target**: Ecosystem compatibility, future-proofing, and enterprise readiness
**Philosophy**: M7 is NOT a core-feature milestone. Every item here is "better to have" — it makes AirAccount easier to integrate, auditable, and positioned for the broader EVM ecosystem. None of it changes the security model or signature tiers from M6.

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
| M7.8 | Post-Quantum Signature Interface (placeholder) | Future | Low | EVM precompile (2028+) | algId 0x10 reserved; interface only |
| M7.9 | ERC-165 / ERC-1271 Full Compliance Audit | Compat | Low | — | Verify all interface IDs are correct |
| M7.10 | AirAccountDelegate ArrayLengthMismatch Error | Quality | Trivial | — | Replace require() with custom error in executeBatch |

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

## M7 Non-Goals

These are explicitly OUT of M7 scope:

| Item | Reason |
|------|--------|
| Frontend wallet UI | Separate project; AirAccount is contract layer only |
| ERC-4337 v0.7 migration | v0.6 EntryPoint is stable; v0.7 migration is a breaking change requiring full re-audit |
| MushroomDAO governance | Community/DAO scope, not contract scope |
| Social graph / HyperCapital on-chain | Research phase, not implementation ready |

---

## Release Criteria for M7

- [ ] M6.1 + M6.2 implemented and tested (prerequisite — must be in M6)
- [ ] M7.6 audit complete with no unresolved Critical/High findings
- [ ] M7.7 bug bounty live on Immunefi
- [ ] M7.2 ERC-7579 full compliance: `installModule` + `executeFromExecutor` with tests
- [ ] M7.3 proxy factory deployed on mainnet + all target L2s (M7.5)
- [ ] All tests passing: target 450+ tests
- [ ] `docs/audit-report-v1.md` published

---

## Timeline Estimate

| Phase | Items | Notes |
|-------|-------|-------|
| M6 completion | M6.1, M6.2 | Prerequisite for audit |
| M7 prep | M7.10, M7.9, M7.8 | Low-effort items, can batch with M6 |
| M7 core | M7.2, M7.3, M7.4 | 4–6 weeks implementation |
| Audit | M7.6 | 2–4 weeks depending on firm |
| Launch | M7.5, M7.7 | Post-audit deployment + bug bounty |
| Long-term | M7.1, M7.8 | DVT-dependent; no hard deadline |
