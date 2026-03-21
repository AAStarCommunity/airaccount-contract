# AirAccount Smart Contract — Audit Scope (M7.2)

**Version**: v0.16.0 (M7 release candidate)
**Audit Platform**: CodeHawks / Cyfrin competitive audit
**Audit Window**: TBD (target: Q3 2026)
**Repository**: https://github.com/AAStarCommunity/airaccount-contract
**Contact**: Jason Jiao — CMU PhD student, AAStar open source

---

## Overview

AirAccount is a **privacy-first, non-upgradable, multi-signature ERC-4337 smart wallet** designed to improve blockchain UX for mainstream users. Key design goals:

- **Non-upgradable**: No proxy patterns (UUPS or Transparent). New features require deploying a new account version and migrating assets. Users have cryptographic proof that the code they audited is the code running forever.
- **Tiered security**: Transaction amounts determine the required signature tier. Tier 1 (≤$100) requires single WebAuthn/ECDSA. Tier 2 ($100–$1,000) requires dual-factor (P256 + ECDSA). Tier 3 (>$1,000 or high-risk operations like module install) requires multi-sig consensus including guardians.
- **Immutable global guards**: Spending limits are hardcoded in a separate `AAStarGlobalGuard` contract that is set once at account creation and cannot be changed afterward. Even an attacker holding all private keys cannot bypass the guard.
- **Social recovery**: Up to 3 guardian addresses can recover the owner key via a 2-of-3 vote with a 2-day timelock, protecting against single point of failure.
- **ERC-7579 module system**: Validators, executors, and hooks can be installed post-deployment with guardian threshold approval (default: 70/100 weight), enabling ecosystem extensibility without changing core code.
- **Privacy support**: Integration with Railgun shielded pools and Kohaku relay via a `CalldataParserRegistry` that exposes token amounts to the guard enforcement layer.
- **EIP-7702 delegation**: `AirAccountDelegate.sol` enables existing EOA wallets to delegate to AirAccount logic without migrating assets.

The codebase is built from scratch (not forked from any existing wallet). It implements ERC-4337 v0.7 (`PackedUserOperation`), ERC-7579, ERC-5564 stealth address announcement, ERC-7828 chain-qualified address encoding, and EIP-7702 delegation.

---

## In-Scope Contracts

All contracts are under `src/`. The compiler setting for all in-scope contracts is **Solidity 0.8.33, optimizer 10,000 runs, via-IR enabled, EVM target: Cancun**.

| Contract | Path | LOC | Purpose | Core Security Invariants |
|----------|------|-----|---------|--------------------------|
| `AAStarAirAccountBase` | `src/core/AAStarAirAccountBase.sol` | 1,573 | Core account logic: guardian storage (packed), algId routing, signature validation dispatch, social recovery, ERC-20 guard, weight-config governance | Guardian threshold, algId bitmap integrity, tiered enforcement, recovery timelock |
| `AAStarAirAccountV7` | `src/core/AAStarAirAccountV7.sol` | 339 | ERC-4337 `validateUserOp` + ERC-7579 module interface (`installModule`, `executeFromExecutor`) | Module install requires guardian threshold; executeFromExecutor only from installed executor |
| `AAStarAirAccountFactoryV7` | `src/core/AAStarAirAccountFactoryV7.sol` | 323 | EIP-1167 minimal-proxy clone factory; guardian acceptance during account creation; default token config injection | Front-running resistance via CREATE2 + guardian pre-acceptance; factory cannot override owner |
| `AAStarGlobalGuard` | `src/core/AAStarGlobalGuard.sol` | 282 | Immutable spending limits: daily ETH cap, per-tx ERC-20 limit, tier enforcement per amount bracket | `account` field immutable post-deploy; limits can only decrease never increase; guard bypasses revert |
| `AAStarValidator` | `src/validators/AAStarValidator.sol` | 164 | External algorithm router: dispatches to BLS, P256, ECDSA, Weighted, SessionKey validators by `algId` byte | algId routing integrity; no fallback to weaker algorithm |
| `SessionKeyValidator` | `src/validators/SessionKeyValidator.sol` | 404 | Time-limited session key validator: grant/revoke per-account session keys with expiry; ERC-7579 Validator module | Session isolation between accounts; expiry strictly enforced; revocation immediate |
| `AirAccountDelegate` | `src/core/AirAccountDelegate.sol` | 540 | EIP-7702 EOA delegation: enables existing EOAs to use AirAccount validation logic; ERC-5564 stealth announcements; `executeBatch` with `ArrayLengthMismatch` guard | Delegation does not give delegate contract custody of EOA key; stealth announcement non-custodial |
| `TierGuardHook` | `src/core/TierGuardHook.sol` | 137 | ERC-7579 Hook module wrapping tier/guard enforcement; called pre-execution by account | Hook reads algId from transient storage set by validator; cannot be bypassed after install |
| `AirAccountCompositeValidator` | `src/validators/AirAccountCompositeValidator.sol` | 92 | ERC-7579 Validator for weighted/cumulative multi-sig (`ALG_WEIGHTED 0x07`): bitmap-driven source accumulation with configurable per-source weights and tier thresholds | Bitmap malleability (by design); weight accumulation cannot overflow; threshold enforcement |
| `AgentSessionKeyValidator` | `src/validators/AgentSessionKeyValidator.sol` | 285 | AI agent session key validator (M7.14): velocity limiting, call-target allowlist, selector restrictions, cumulative spend cap; `delegateSession` for sub-agent key chains | Velocity window reset timing; spend cap not bypassable via re-grant; sub-agent inherits parent constraints |
| `CalldataParserRegistry` | `src/core/CalldataParserRegistry.sol` | 74 | Registry mapping target contracts to `ICalldataParser` implementations for guard token-amount extraction | Parser registration is write-once per target; malicious parser cannot elevate amount |
| `RailgunParser` | `src/parsers/RailgunParser.sol` | 119 | `ICalldataParser` for Railgun V3 privacy pool deposit calldata decoding | Parses `tokenIn` and `amountIn` correctly; no reverting parser that blocks user operations |
| `UniswapV3Parser` | `src/parsers/UniswapV3Parser.sol` | 124 | `ICalldataParser` for Uniswap V3 `exactInputSingle`/`exactInput` calldata decoding | Correctly extracts `amountIn`; handles multi-hop path encoding |

**Total in-scope LOC**: ~4,456 lines (Solidity)

---

## Out-of-Scope

The following are explicitly **not in scope** for this audit:

- `lib/YetAnotherAA-Validator/` — upstream submodule, separately audited
- `lib/simple-team-account/` — Stackup reference implementation
- `lib/light-account/` — Alchemy reference implementation
- `lib/kernel/` — ZeroDev kernel reference implementation
- `test/` — all test files
- `scripts/` — all deployment and E2E test scripts
- `src/aggregator/` — BLS aggregator (separate audit scope)
- Third-party library code: OpenZeppelin, account-abstraction interfaces

---

## Security Invariants (Key Properties to Verify)

Auditors should prioritize verifying that the following invariants hold under all conditions, including adversarial input:

1. **Guardian threshold for recovery**: No single key can complete a social recovery. `initiateRecovery` requires `newOwner` proposal; `finalizeRecovery` requires the timelock to expire AND at least 2 guardian approvals. Guardian set cannot be modified without the current owner.

2. **Daily spending limit is one-directional**: `AAStarGlobalGuard` daily ETH limit and per-tx ERC-20 limits can only be **reduced** (or kept equal) after initial deployment. Any call attempting to increase a limit reverts. Even with all guardian and owner signatures, limits cannot be raised.

3. **Guard.account is immutable**: The `account` field in `AAStarGlobalGuard` is set in the constructor and cannot be updated. A guard deployed for account A cannot be transferred to account B to bypass its limits.

4. **Session keys are strictly scoped**: A session key granted for account A cannot validate UserOps for account B. Expiry is checked against `block.timestamp` with no rounding. Revoked sessions immediately fail all subsequent validation.

5. **Module installation requires guardian threshold**: `installModule` and `uninstallModule` verify a weighted signature with the configured `installModuleThreshold` (default 70/100, requiring owner + at least 1 guardian). An attacker who compromises only the owner ECDSA key cannot install a malicious module.

6. **executeFromExecutor is executor-gated**: The ERC-7579 `executeFromExecutor` entrypoint can only be called by an address registered as an executor module (`moduleTypeId = 2`). Direct external calls revert.

7. **algId routing is exhaustive and non-fallback**: `AAStarValidator` routes to the correct algorithm handler for every valid `algId`. There is no catch-all path that falls through to a weaker algorithm. An invalid `algId` reverts with `InvalidAlgId`.

8. **Packed guardian storage integrity**: Guardians are stored in a packed 32-byte slot. Guardian address extraction and threshold checking must be consistent across `validateUserOp`, `initiateRecovery`, `approveRecovery`, `cancelRecovery`, and `finalizeRecovery`. A maliciously crafted signature that manipulates bit positions in the packed slot must not be accepted.

9. **BLS payload slice boundary**: `_validateCumulativeTier2/Tier3` must pass `blsPayload[32:]` (skipping the `nodeIdsLength` prefix) to the BLS algorithm. Passing `blsPayload[0:]` would include garbage data and produce incorrect validation — the invariant is that the BLS algorithm never receives a `nodeIdsLength` prefix byte.

10. **EIP-7702 delegation does not transfer custody**: `AirAccountDelegate` executes code on behalf of the EOA via EIP-7702. The delegate contract does not hold funds. The EOA's private key remains the ultimate authority. The delegate cannot revoke or override the EOA private key.

11. **Factory cannot front-run account creation**: Factory uses CREATE2 with `keccak256(owner ++ guardians ++ salt)` as the create2 salt. An attacker who observes a pending `createAccount` transaction cannot deploy a different account at the same address because the salt is deterministically bound to the owner/guardian set provided.

12. **Weight accumulation cannot overflow or be double-counted**: In `ALG_WEIGHTED` (algId 0x07), the bitmap controls which sources contribute weight. Each bit is consumed exactly once. Setting the same bit twice in a crafted bitmap should not allow double-counting. Weight values are `uint8` and accumulation must not overflow a `uint16` accumulator.

13. **Velocity window cannot be gamed**: `AgentSessionKeyValidator` velocity limiting uses a sliding window. If the window has expired at call time, a new window starts — but this means an attacker who knows the window boundary can always place exactly `velocityLimit` calls by splitting them across window boundaries. This is documented as an accepted risk; auditors should confirm the window logic does not allow **more than** `velocityLimit` calls within any single window.

14. **No guardian self-promotion**: A guardian cannot call `initiateRecovery` to replace the current owner with themselves. `initiateRecovery` is gated to be callable by guardians only for proposing a new owner address, and `finalizeRecovery` requires the 2-day timelock to expire. Auditors should verify the guardian cannot bypass the timelock by proposing and immediately finalizing.

15. **Stealth announcement is non-custodial**: `AirAccountDelegate.announceForStealth` emits an `ERC5564Announcement` event but does not transfer or lock any funds. The announcement metadata must not be usable to derive the recipient's stealth private key.

---

## Known Attack Vectors to Focus On

The following vectors are of particular interest and have been partially analyzed in internal reviews. Auditors should investigate them rigorously:

| Vector | Location | Description |
|--------|----------|-------------|
| **Guardian manipulation** | `AAStarAirAccountBase.sol` | Can a guardian call sequence bypass the 2/3 threshold or the 2-day timelock? Can a single guardian initiate + finalize recovery? |
| **Factory front-running** | `AAStarAirAccountFactoryV7.sol` | Can an observer front-run `createAccount` to deploy a malicious contract at the predicted address? |
| **algId bitmap malleability** | `AirAccountCompositeValidator.sol` | All valid bitmaps for a given accumulated weight are accepted (by design). Auditors should verify no reordering produces a weight above what the provided keys can actually sign, enabling threshold bypass. |
| **Session key replay across nonce resets** | `SessionKeyValidator.sol` | ERC-4337 nonce can be manipulated via `key` parameter (192-bit namespace). Can a session key signature valid for nonce `(key=0, seq=5)` be replayed at `(key=1, seq=5)`? |
| **EIP-7702 private key persistence** | `AirAccountDelegate.sol` | The EOA private key remains active even after EIP-7702 delegation. AirAccount cannot revoke it. A compromised EOA hardware wallet cannot be "rotated away" without asset migration. |
| **Cross-chain address confusion** | `AAStarAirAccountV7.sol` + `AAStarAirAccountFactoryV7.sol` | Same CREATE2 salt on different chains produces the same address. ERC-7828 chain-qualified addresses mitigate UI confusion, but auditors should verify the `chainId` is included in all signature domain separators. |
| **Module install race** | `AAStarAirAccountV7.sol` | If two `installModule` UserOps are submitted simultaneously (parallel nonce keys), can both succeed and install duplicate modules, leading to inconsistent state? |
| **Parser registry griefing** | `CalldataParserRegistry.sol` | Can a registered parser revert or return garbage amounts to grief guard enforcement? Does this allow DoS on specific target contracts? |
| **Pre-install revert swallowing** | `AAStarAirAccountFactoryV7.sol` | Factory pre-installs modules for newly created accounts with a try/catch that ignores `onInstall()` revert. Is the module recorded as installed even if initialization failed, and what are the downstream consequences? |

---

## Test Coverage Summary

Current test suite: **614 tests** (as of M6 completion). Run with:

```bash
forge test --summary
```

Coverage report:

```bash
forge coverage
```

Test files are located in `test/`. Key test suites:

- `test/AirAccountBase.t.sol` — core account logic (guardian operations, signature validation, spending limits)
- `test/AirAccountFactory.t.sol` — factory creation, guardian pre-acceptance, front-running resistance
- `test/GlobalGuard.t.sol` — spending limit enforcement, tier assignment
- `test/SessionKeyValidator.t.sol` — session grant/revoke/expiry, cross-account isolation
- `test/AgentSessionKeyValidator.t.sol` — velocity limiting, allowlist enforcement
- `test/WeightedSig.t.sol` — bitmap accumulation, threshold resolution
- `test/TierGuardHook.t.sol` — ERC-7579 hook pre/post check
- `test/AirAccountDelegate.t.sol` — EIP-7702 delegation, stealth announcement

---

## Deployment Information

| Parameter | Value |
|-----------|-------|
| EntryPoint (ERC-4337 v0.7) | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| M5 Factory (Sepolia, r5) | `0xd72a236d84be6c388a8bc7deb64afd54704ae385` |
| M6 Factory (Sepolia) | `0x34282bef82e14af3cc61fecaa60eab91d3a82d46` |
| M7 Factory (Sepolia) | Set via `AIRACCOUNT_M7_FACTORY` in `.env.sepolia` after deployment |
| Solidity Version | `0.8.33` |
| Optimizer Runs | `10,000` |
| EVM Version | `Cancun` |
| via-IR | `true` |
| Network (testing) | Sepolia (`chainId: 11155111`) |

---

## How to Run Tests

```bash
# Build all contracts
forge build

# Run full test suite
forge test --summary

# Run specific suite
forge test --match-path test/AirAccountBase.t.sol -vvv

# Coverage report
forge coverage

# Gas snapshot
forge snapshot
```

---

## Internal Security Reviews

The following internal security review documents are available in `docs/`:

- `docs/2026-03-21-audit-report.md` — latest comprehensive internal audit (M6)
- `docs/security-review.md` — methodology and invariant checklist
- `docs/M6-security-review.md` — M6-specific security analysis
- `docs/known-issues.md` — accepted risks and mitigations (see companion document)

---

## Audit Contact

- **Lead Developer**: Jason Jiao (CMU PhD student, AAStar open source)
- **GitHub**: https://github.com/AAStarCommunity/airaccount-contract
- **Organization**: https://github.com/AAStarCommunity
- **Questions**: Open a GitHub issue tagged `[audit]` or contact via GitHub Discussions
