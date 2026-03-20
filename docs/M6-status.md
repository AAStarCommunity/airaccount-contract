# M6 Feature Status — AirAccount v0.15.0

**Last updated**: 2026-03-20
**Branch**: merge-m6-to-main
**Tests**: 434 pass, 0 fail
**E2E**: 5/5 pass on Sepolia (2026-03-20)

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
| **M6.5 Will Execution** | Hard | DVT off-chain | WillExecutor.sol + DVT scanner infrastructure → moved to M7 |
| M6.3 Frontend Weight Config UI | — | M6.1 | Frontend scope, not contract |

## Newly Completed ✅

| Feature | algId | Tests | Notes |
|---------|-------|-------|-------|
| M6.1 Weight-Based Multi-Signature | 0x07 | 39 unit + 3 E2E | WeightConfig, bitmap-driven, 434 total tests |
| M6.2 Guardian Consent for Weight Changes | — | 13 unit + 1 E2E | WeightChangeProposal, 2-of-3 + 2-day timelock |

### Sepolia E2E Results (2026-03-20)

- **Account**: `0xfab5b2cf392c862b455dcfafac5a414d459b6dcc` (deployed via Arachnid CREATE2, salt=701)
- **Deploy tx**: `0xfd802feb2c67057790160ff094ca1b1b2ad7e4e346e1ff0479727066f23666ab` (gas: 5,492,508)

| Test | Description | Result | Gas |
|------|-------------|--------|-----|
| A | ALG_WEIGHTED P256+ECDSA (bitmap=0x03, weight=4≥tier2) | PASS | 168,731 |
| B | ALG_WEIGHTED ECDSA-only (weight=2 < tier1=3) | PASS (reverted) | — |
| C | ALG_WEIGHTED P256-only (weight=2 < tier1=3) | PASS (reverted) | — |
| D | Standard ECDSA 0x02 backward compat | PASS | 115,073 |
| E | M6.2 governance: propose → approve → timelock blocked → cancel | PASS | — |

**Known issue**: `AAStarAirAccountFactoryV7` exceeds EIP-170 (runtime: 30,172B > 24,576B limit). Filed as `factory-eip170-overflow`. Account deployed directly via Arachnid CREATE2 for E2E testing. Fix in M7: externalize init code via SSTORE2 or proxy/clone pattern.

**M6.7 Post-Quantum**: Blocked by EVM precompile availability (2028+), deferred indefinitely.

---

## Decision: What Stays in M6 vs What Moves to M7?

| Feature | Decision | Rationale |
|---------|----------|-----------|
| M6.1 Weighted Signature | **Stay in M6** | Core signing feature, fully specced in M6-design.md |
| M6.2 Guardian Consent | **Stay in M6** | Required security wrapper for M6.1 |
| M6.5 Will Execution | **Move to M7** | DVT off-chain infrastructure not ready; contract easy but useless without DVT |
| M6.3 Frontend UI | **Out of scope** | Frontend project, not contract |
