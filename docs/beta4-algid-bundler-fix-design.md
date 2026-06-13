# v0.17.2-beta.4 — algId / bundler-compatibility fix (design spec)

**Branch**: `fix/algid-bundler-validation-beta4`
**Reviewed by**: Opus (web research + adversarial) + Codex (adversarial) — both SOUND-WITH-CHANGES, converged.

## Problem

AirAccount passed the validated `algId` from `validateUserOp` to `execute` via EIP-1153 transient storage. Pimlico's `eth_estimateUserOperationGas` simulates validation and execution in SEPARATE `eth_call`s; transient storage is cleared between them, so `execute` saw `algId=0` and the guard reverted `AlgorithmNotApproved(0)`. Result: guard-enabled accounts cannot be used through a standard bundler. Cross-phase transient storage is a recognized anti-pattern (Trail of Bits, "Six mistakes in ERC-4337 smart accounts" #3).

## Industry standard (sources)

- **ZeroDev Kernel v3** (ERC-7579 permissions): policy enforced in validation over account-namespaced storage. "Which signature" = the permissionId/validator; nothing is smuggled to execution.
- **Alchemy Modular Account v2** (ERC-6900): spending-limit exec hooks tied to a validation function; per-account state; routes through `executeUserOp` when execution needs op context.
- **ERC-4337 v0.7 `IAccountExecute.executeUserOp(userOp, userOpHash)`**: EntryPoint passes the FULL userOp (incl. signature) into execution when `callData` begins with the `executeUserOp` selector (`EntryPoint.sol:249-251`). Execution can re-derive everything from the signature — no cross-phase state.

## Solution (locked)

### Non-negotiable core
1. **Whitelist single source of truth = the ACCOUNT.** Move `approvedAlgorithms` to account storage (slot 24). **Delete it from `AAStarGlobalGuard`.** No mirror → no desync. `approveAlgorithm` mutates only the account (monotonic add).
2. **`validateUserOp` is the authoritative gate.** After signature validation resolves `algId` (readable from same-call transient), enforce: whitelist (`approvedAlgorithms[guardAlgId]`) + per-op ETH tier (`requiredTier(value)` vs `_algTier(resolvedAlgId)`), reading only account storage (ERC-7562 legal). Fail → `SIG_VALIDATION_FAILED`. Runs in BOTH estimation and real handleOps.
3. **Guard → pure accounting.** `recordSpend(value)` (ETH daily limit) and `recordTokenSpend(token, amount, algId)` (token tier math + token daily limit). No whitelist. algId is a pure input to the token-tier calc.
4. **No `algId==0` skip.** Eliminated entirely by executeUserOp (algId always derivable from the signature in calldata).

### Execution path (executeUserOp)
- SDK sets `userOp.callData = executeUserOp.selector ++ <inner execute/executeBatch calldata>`.
- EntryPoint routes to `executeUserOp(userOp, userOpHash)` (onlyEntryPoint). Execution **re-derives algId from `userOp.signature`** (prefix byte; 65-byte → ECDSA; weighted 0x07 → re-accumulate weight to resolve tier; session 0x08 → slice key from bytes). Then runs cumulative ETH-tier + token-tier (fail-closed, algId always present) and `recordSpend`/`recordTokenSpend`, then performs the inner call(s).
- **Owner-direct path** (`execute`/`executeBatch`, `msg.sender == owner`): unchanged, `algId = ALG_ECDSA`.
- Cross-phase transient algId queue (`_consumeValidatedAlgId` etc. across phases) is removed; the in-call transient stores used within `validateUserOp` itself stay (same-call reads are valid).

### EIP-170 budget
- Account currently 21,862 / 24,576 (2,714 free). Cleanup recovers bytecode: remove vestigial `getCurrentAlgId`/`getCurrentSessionKey` (consumer `TierGuardHook` was deleted in beta.1), trim cross-phase queue, drop guard-whitelist branches. `test/Eip170Size.t.sol` gates the result. Fallback: host validation-gate / executeUserOp heavy logic in `AirAccountExtension` (8,330 / 24,576) via diamond-lite delegatecall.

## Attack surface closed
- Mirror desync (eliminated: one source of truth).
- estimation-vs-execution tier divergence (eliminated: executeUserOp gives identical algId in both).
- Whitelist bypass (authoritative in validation, runs in estimation + real).

## Tests required
- Unit: validateUserOp returns 1 for non-whitelisted algId (valid sig).
- Unit: approveAlgorithm only mutates account; no guard/account desync path exists.
- Unit: split-simulation reproducer — validate in one call, execute in another (transient cleared) → no `AlgorithmNotApproved(0)`.
- Unit: high ETH value + Tier-1 sig fails in validation (per-op tier).
- Unit: configured ERC20 transfer above Tier-1 behaves identically in split-estimation and real handleOps (no estimate-pass/onchain-fail gap).
- Unit: executeBatch cumulative ETH + token tier still catches threshold breach across calls.
- Unit: EIP-170 size test passes.
- E2E: Pimlico `eth_estimateUserOperationGas` succeeds for approved algId, rejects non-approved / under-tier before submission.
- E2E: real handleOps == split estimation across ECDSA / P256 / weighted / session-key / guarded-ERC20.
- E2E regression: Phase 08-12 all pass.
