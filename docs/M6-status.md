# M6 Feature Status — AirAccount v0.15.0

**Last updated**: 2026-03-20
**Branch**: M6
**Tests**: 393 pass, 0 fail

---

## Completed ✅

| Feature | algId | Tests | Notes |
|---------|-------|-------|-------|
| M6.4 Session Key (time-limited authorization) | 0x08 | 21 unit + 1 E2E | SessionKeyValidator.sol |
| M6.6a OAPD (One Account Per DApp) | — | 6 E2E | TypeScript only, no contract change |
| M6.6b Pluggable Calldata Parser | — | 20+3 unit | CalldataParserRegistry + UniswapV3Parser |
| ERC-7579 minimum compatibility shim | — | 10 unit | accountId, supportsModule, isModuleInstalled, isValidSignature, supportsInterface |
| EIP-7702 AirAccountDelegate | — | 38 unit | AirAccountDelegate.sol, vm.etch simulation |
| M6 Decision Document | — | — | docs/M6-decision.md |
| WalletBeat Assessment | — | — | docs/walletbeat-assessment.md |
| M6 Security Review | — | — | docs/M6-security-review.md |
| Factory bytecode size fix (optimizer_runs=200) | — | — | Was 24,966B (over EIP-170); now 23,238B |

---

## Remaining in M6 ❌

| Feature | Difficulty | Depends on | Notes |
|---------|-----------|-----------|-------|
| **M6.1 Weight-Based Multi-Signature (algId 0x07)** | Medium | — | WeightConfig struct, _validateWeightedSignature, transient weight slot |
| **M6.2 Guardian Consent for Weight Changes** | Medium | M6.1 | WeightChangeProposal, 2-of-3 timelock same as recovery |
| **M6.5 Will Execution** | Hard | DVT off-chain | WillExecutor.sol + DVT scanner infrastructure |
| M6.3 Frontend Weight Config UI | — | M6.1 | Frontend scope, not contract |

**M6.7 Post-Quantum**: Blocked by EVM precompile availability (2028+), deferred indefinitely.

---

## Decision: What Stays in M6 vs What Moves to M7?

| Feature | Decision | Rationale |
|---------|----------|-----------|
| M6.1 Weighted Signature | **Stay in M6** | Core signing feature, fully specced in M6-design.md |
| M6.2 Guardian Consent | **Stay in M6** | Required security wrapper for M6.1 |
| M6.5 Will Execution | **Move to M7** | DVT off-chain infrastructure not ready; contract easy but useless without DVT |
| M6.3 Frontend UI | **Out of scope** | Frontend project, not contract |
