# AirAccount — Known Issues & Accepted Risks

**Version**: v0.28.0-beta (CC-27 BLS registry rename + version bump; carries forward all KI-1..15 trade-offs unchanged)
**Last Updated**: 2026-07-13
**Status**: pre-release beta — external security audit (#29) pending before GA tag
**Note**: KI entries below were authored at v0.17.2-beta.1. The described design trade-offs are **still in force** in v0.28.0 (no behavior change since the diamond-lite split; CC-27 was a pure rename). Line-number references may drift; the risk statements remain authoritative. KI-14 (calldata parsers disabled) applies to this beta — see the release note in `CHANGELOG.md`.
**Purpose**: This document explicitly declares known limitations and accepted risks in AirAccount's design. It exists so that security auditors and users can make an informed decision. Items listed here are **intentional design trade-offs**, not bugs. Auditors should NOT file findings for these items unless they identify a new exploit path that makes the described risk worse than documented.

---

## KI-1 — EIP-7702 Private Key Permanence

**Severity**: Medium (design limitation, not a bug)
**Affected Contract**: `AirAccountDelegate.sol`
**Category**: Key management

### Description

When a user delegates their EOA to `AirAccountDelegate` via EIP-7702, the EOA's original private key does **not** become inactive. EIP-7702 installs a delegation pointer at the EOA address but does not disable direct private-key signing. Any party holding the original private key can still:

- Sign and broadcast transactions directly from the EOA
- Override the `AirAccountDelegate` execution logic with a raw EOA transaction
- Redeploy a different EIP-7702 delegation by signing a new authorization tuple

AirAccount has no mechanism to cryptographically revoke a private key. The delegation can be changed (another EIP-7702 authorization), but the key itself cannot be invalidated on-chain.

### Risk

If the EOA private key is compromised, the attacker has the same authority as the original owner and can bypass the social recovery and tiered signature protection that `AirAccountDelegate` provides.

### Mitigation

- Use hardware wallets (Ledger, Trezor, YubiHSM) for EOAs that will be delegated. The private key never leaves secure hardware, making compromise practically infeasible.
- Treat EIP-7702 delegation as an enhancement layer, not a security upgrade. Users with high-value accounts should migrate to a native AirAccount (not EOA-delegated) where no single key exists.
- Document user-facing: "EIP-7702 delegation does not protect you if your private key is stolen. Use hardware wallets only."

### Auditor Note

This is a fundamental EIP-7702 protocol property, not a contract bug. No contract change can fix this.

---

## KI-2 — Guardian Self-Dealing After Trust Is Established

**Severity**: Medium (trust assumption, not a bug)
**Affected Contract**: `AAStarAirAccountBase.sol` — `initiateRecovery` / `approveRecovery` / `finalizeRecovery`
**Category**: Social trust model

### Description

Once a user designates an address as a guardian, that address is trusted by the contract. If the owner designates three colluding parties as guardians (e.g., three keys controlled by one adversary), those guardians can:

1. Call `initiateRecovery` to propose a new owner address controlled by the attacker
2. Call `approveRecovery` from two guardian addresses to meet the 2-of-3 threshold
3. Wait 2 days for the timelock to expire
4. Call `finalizeRecovery` to complete the takeover

The contract enforces the timelock and threshold — it does not and cannot enforce that the three guardian addresses are genuinely independent parties.

### Risk

The security of social recovery is entirely dependent on the quality of the guardian set. A single person controlling 2 of 3 guardian private keys can take over an account in 2 days.

### Mitigation

- Use **diverse guardian types**: recommended configuration is a hardware wallet key + a family member's mobile wallet + a trusted community multisig (Safe).
- Never designate guardians who know each other or who could be pressured together.
- Consider adding a guardian key held by a time-locked smart contract (e.g., a Safe with a 7-day voting period), making rapid collusion impossible.
- The 2-day timelock is the last line of defense: the owner can call `cancelRecovery` (requires 2 guardian sigs as of the current design) within the window if they detect an unauthorized recovery.

### Auditor Note

The `cancelRecovery` function requires **2-of-3 guardian signatures** (NOT an owner-only call). This is by design: if the owner's key is already compromised, an attacker holding the owner key could otherwise cancel a legitimate guardian-initiated recovery. Auditors should verify this design is correctly implemented and that the owner key alone cannot cancel recovery.

---

## KI-3 — Low installModuleThreshold Allows Single-Key Module Install

**Severity**: ~~High if misconfigured~~ → **not currently reachable** (see v0.17.1 update)
**Affected Contract**: `AAStarAirAccountBase.sol` / `AAStarAirAccountV7.sol`
**Category**: Access control configuration

> **Update (v0.17.1):** there is **no `setInstallModuleThreshold` setter in the current code** — `_installModuleThreshold` (slot 7) is never written and always reads back as 0, which the install path resolves to the hardcoded default **70** (`installModule` line ~262). So the "user lowers the threshold below the owner's weight" scenario described below **cannot happen today**; the threshold is effectively immutable at 70. This entry is retained as a forward-looking constraint: **if** a configurable setter is ever added, it must enforce a lower bound (e.g. `>= 60`). The storage slot is not removed because doing so would shift the diamond-lite layout.

### Description

The `installModuleThreshold` is a configurable per-account value (range 0–100) that determines what weighted signature score is required to install or uninstall ERC-7579 modules. The **default is 70**, which requires the owner key plus at least 1 guardian (guardian weight = 30 in default config), making single-key module install impossible.

However, a user can call `setInstallModuleThreshold(40)`, reducing the threshold to the owner's ECDSA weight alone. If a user sets `installModuleThreshold = 40`, a compromised owner ECDSA key can install an arbitrary validator module, potentially creating a backdoor for fund exfiltration.

### Risk

If `installModuleThreshold` is set to 40 (or any value ≤ owner's weight), one compromised ECDSA key can install a malicious executor module that bypasses all spending limits and tier checks.

### Mitigation

- **Default threshold is 70 and should not be changed in production.** This is enforced as the recommended default in factory deployment.
- The contract should (and does) emit a `ModuleThresholdChanged` event to alert monitoring tools.
- Consider adding a lower bound check: the contract could enforce `installModuleThreshold >= 60` or similar. This is a future improvement; for now, it is a documented configuration risk.
- Frontend and SDK integrations should warn users if they attempt to set a threshold below 60.

### Auditor Note

Auditors should verify that the factory deploys accounts with `installModuleThreshold = 70` and that no factory code path results in threshold < 60 by default.

---

## KI-4 — Session Key Velocity Window Reset Timing

**Severity**: Low (by-design behavior)
**Affected Contract**: `AgentSessionKeyValidator.sol`
**Category**: Rate limiting
**Tracking**: [issue #57](https://github.com/AAStarCommunity/airaccount-contract/issues/57)

> **Correction (v0.17.1):** the original mitigation below referenced a `spendCap` field as an independent cumulative bound. `AgentSessionConfig` **no longer has a `spendCap` field** — the velocity window is the only rate bound today. Whether to (re)introduce a cumulative cap is part of #57.

### Description

`AgentSessionKeyValidator` enforces a velocity limit of `N` calls per `velocityWindow` seconds. The window is implemented as a start-timestamp reset: when the first call of a new window arrives (i.e., `block.timestamp >= windowStart + velocityWindow`), the `callCount` resets to 1 and `windowStart = block.timestamp`.

An adversary who can time their calls precisely can exploit this to make `2 * velocityLimit - 1` calls in a period shorter than `2 * velocityWindow`:
1. Make `velocityLimit` calls clustered at the end of window W1
2. Make `velocityLimit` calls clustered at the start of window W2 (immediately after W1 expires)

The total elapsed time is just over `velocityWindow`, but the attacker made `2 * velocityLimit - 1` calls.

### Risk

An AI agent with a velocity limit of 10 calls/hour could make 19 calls in slightly over 1 hour by straddling the window boundary. This is a standard sliding-window vs. fixed-window trade-off. The impact is bounded: the attacker cannot make more than `2 * velocityLimit - 1` calls in any period of length `velocityWindow`.

### Mitigation

- For high-security agent sessions, set `velocityLimit` conservatively (e.g., half the intended peak rate) to account for the 2x boundary effect.
- A sliding window implementation (tracking call timestamps in a ring buffer) would eliminate this, but would cost significantly more gas per call. This optimization is deferred (tracked in #57).
- ~~The `spendCap` limit provides an independent, cumulative bound that the velocity window cannot bypass.~~ (No `spendCap` field exists in the current `AgentSessionConfig`; velocity is the only bound.)

### Auditor Note

Auditors should confirm that the velocity limit enforces at most `velocityLimit` calls in a single window (not across windows). The cross-window 2x effect is accepted. Any path that allows more than `velocityLimit` calls within a single `velocityWindow` period would be a bug.

---

## KI-5 — Best-Effort onInstall() During Factory Pre-Installation — ✅ RESOLVED (v0.17.1)

**Severity**: ~~Low~~ → **Resolved**
**Affected Contract**: `AAStarAirAccountFactoryV7.sol` / `AAStarAirAccountV7.sol`
**Category**: Module initialization

> **Resolved (v0.17.1, MEDIUM-1 / #21):** the best-effort `try/catch` no longer exists. Both module-install paths now **hard-revert** if `onInstall()` fails: `installModule` (line ~304, `if (!_ok) revert ModuleInstallCallbackFailed(...)`) and the factory agent default-install in `initializeAgentAccount` (line ~81, same revert). A module can no longer be marked installed while uninitialized. The description below is retained for history only.

### Description

When the factory creates a new account and pre-installs default modules (e.g., `AgentSessionKeyValidator`), it calls `account.installModule(moduleTypeId, module, initData)` wrapped in a `try/catch`. If the module's `onInstall()` reverts (e.g., due to missing configuration or incompatible initData), the `catch` block silently swallows the error and continues.

Result: the module is **recorded as installed** in the account's installed-modules bitmap, but `onInstall()` was never successfully called. The module may be in an uninitialized or inconsistent state.

### Risk

A module that relies on `onInstall()` for initialization (e.g., setting up access control state) would be registered as installed but non-functional. If the module is later invoked (e.g., by `executeFromExecutor`), it may revert, behave incorrectly, or in worst case exhibit unexpected behavior due to zero/unset storage.

The risk is low because: (a) pre-installed modules are audited and trusted, (b) the factory is tested end-to-end, (c) the account owner can `uninstallModule` and reinstall manually if needed.

### Mitigation

- Pre-installed modules in the factory are reviewed to ensure their `onInstall()` cannot fail with the provided `initData`.
- A future improvement is to remove the `try/catch` and let factory creation revert if pre-install fails (making the failure visible).
- Users and integrators should verify module state post-deployment using `isModuleInstalled()` and module-specific state queries.

### Auditor Note

Auditors should check whether any pre-installed module's `onInstall()` contains logic that can fail silently in a way that creates a security hole (e.g., access control state that defaults to open/permissive when uninitialized).

---

## KI-6 — No Timelock on Module Install at Default Threshold (70)

**Severity**: Low (accepted design trade-off)
**Affected Contract**: `AAStarAirAccountV7.sol`
**Category**: Module management
**Tracking**: [issue #58](https://github.com/AAStarCommunity/airaccount-contract/issues/58)

### Description

At the default `installModuleThreshold = 70`, a module can be installed with owner (weight 40) + 1 guardian (weight 30) in a **single UserOp**. There is no multi-block timelock between the install proposal and execution. This means:

- If an attacker compromises both an owner key and one guardian key simultaneously, they can install a malicious module in a single transaction.
- There is no grace period during which the account owner (or other guardians) could detect and cancel the install.

### Risk

Dual-key compromise (owner + 1 guardian) with no timelock allows instant malicious module installation. This is a degraded security scenario (requires 2 key compromises), but it lacks the 2-day defense-in-depth that the social recovery flow provides.

### Mitigation

- For accounts with the highest security requirements (e.g., treasury accounts), set `installModuleThreshold = 100` (requires all 3 guardians + owner). This is not the default because it makes ordinary module management inconvenient.
- Consider implementing an optional `moduleInstallTimelock` (e.g., 24 hours) as a per-account configuration option. This is a planned future improvement.
- Monitor for `ModuleInstalled` events on-chain using a monitoring service (Tenderly, OpenZeppelin Defender) and set up alerts.

### Auditor Note

The absence of a module-install timelock is a deliberate UX trade-off. Auditors should focus on whether the threshold check itself is correctly implemented and cannot be bypassed.

---

## KI-7 — P256 Precompile Required (Deployment-Blocking on Non-OP-Stack Chains)

**Severity**: Medium (deployment configuration constraint)
**Affected Contracts**: `AAStarAirAccountBase` `_validateP256` (algId `0x03`), `SessionKeyValidator` P256 session path (148-byte sigs)
**Category**: Cross-chain deployment

> **Correction 2026-05-30**: prior wording stated AirAccount "falls back to a Solidity software implementation" of P256 verification on chains without the EIP-7212 precompile. That is **not true** in the current code. The contract calls the precompile at `0x100` via `staticcall` and **fails fast** (returns SIG_VALIDATION_FAILED) when the precompile is absent — there is no software fallback. Deployment on a chain without EIP-7212 means P256 (and any cumulative/combined algId that requires P256) is **unusable on that chain**, not "expensive". Treat KI-7 as a deployment-blocking constraint for any chain that lacks the precompile.

### Description

P256 (WebAuthn) signature verification uses the EIP-7212 precompile at address `0x0000000000000000000000000000000000000100`. Natively available on:

- OP Mainnet, Base, and other OP Stack chains with Fjord active
- Optimism Sepolia, Base Sepolia (Fjord testnets)

On **Ethereum mainnet** and non-OP-Stack L2s (Arbitrum One, zkSync Era, etc.) the precompile does **not** exist. `_validateP256` returns `1` (SIG_VALIDATION_FAILED) when the precompile staticcall fails; no software fallback is attempted.

### Risk

Deploying on a chain without EIP-7212 means:

- **Any UserOp using `ALG_P256` (0x03), `ALG_CUMULATIVE_T2` (0x04), `ALG_CUMULATIVE_T3` (0x05), or `ALG_COMBINED_T1` (0x06)** fails validation — these algorithms all internally call `_validateP256`.
- `ALG_BLS` (0x01) and `ALG_ECDSA` (0x02) work fine — no precompile dependency.
- Session keys: ECDSA session (105-byte format) works; P256 session (148-byte format) fails.

This is by design — using the precompile keeps gas low (~3,450 vs ~330k for any pure-Solidity P256), and a chain without EIP-7212 should not be a primary AirAccount target.

### Mitigation

- Primary deployment targets are OP Stack L2s where EIP-7212 is active.
- For non-OP-Stack chains, restrict accounts to ECDSA + BLS algorithm subset; do not advertise P256 session keys or passkey-based tiers.
- Deployment guide explicitly lists supported chains; deploying to unlisted chains requires re-evaluating P256 support.

### Auditor Note

Verify that on a chain without the precompile, P256-dependent UserOps cleanly return SIG_VALIDATION_FAILED (rather than silently accepting bad signatures or reverting unexpectedly). Specifically check `AAStarAirAccountBase._validateP256` and `SessionKeyValidator._validateP256Session` both check `!success || result.length < 32 || decoded != 1` before returning `0`.

---

## KI-8 — Weighted Signature Bitmap Malleability

**Severity**: Informational (by-design behavior)
**Affected Contract**: `AirAccountCompositeValidator.sol` (ALG_WEIGHTED, algId 0x07)
**Category**: Signature malleability

### Description

The `ALG_WEIGHTED` signature format (algId 0x07) includes a 1-byte `sourceBitmap` as part of the signature itself. The bitmap specifies which signing sources (P256, ECDSA, BLS, guardian0, guardian1, guardian2) are included. Multiple different bitmaps can produce a valid signature for the same UserOp as long as the accumulated weight meets the threshold.

For example, if `passkeyWeight=3, ecdsaWeight=3, tier1Threshold=3`:
- Bitmap `0x01` (P256 only) → weight 3 → valid
- Bitmap `0x02` (ECDSA only) → weight 3 → valid
- Bitmap `0x03` (P256 + ECDSA) → weight 6 → valid

All three are valid signatures for the same UserOp. This means AirAccount signatures are **not unique per transaction** — multiple valid signatures exist.

### Risk

Signature malleability does not enable replay attacks (UserOp nonce prevents replay). However:
- Signature non-uniqueness may break assumptions in systems that use the signature bytes as a unique identifier.
- A relayer could substitute one valid signature for another on a pending transaction (bitmap manipulation without breaking validity). This is generally harmless but should be documented.
- Auditors should verify that no code path uses `keccak256(signature)` as a unique operation identifier.

### Mitigation

- Signature malleability is documented and expected.
- The ERC-4337 nonce provides replay protection regardless of signature malleability.
- Downstream systems must use the UserOp hash (not signature bytes) as the canonical operation identifier.

### Auditor Note

Auditors should confirm: (1) no bypass exists where a lower-weight bitmap is crafted to appear as a higher-weight bitmap, (2) the accumulated weight cannot overflow, and (3) each signer slot in the bitmap is validated against the appropriate key (i.e., bit 0 cannot use a guardian key in the P256 slot).

---

## KI-9 — Session Key Scope Enforced at Execution Phase, Not Validation Phase

**Severity**: Medium (ERC-4337 design constraint, not a bug)
**Affected Contract**: `AAStarAirAccountBase.sol` (lines ~1089–1119), `AgentSessionKeyValidator.sol`
**Category**: ERC-4337 architecture constraint

### Description

`AgentSessionKeyValidator.validateUserOp()` is a stateless validation function: it verifies the session key signature and checks policy bounds (velocity, expiry) but **cannot** inspect the calldata of the `execute()` call that will run later. The `contractScope` (target address allowlist) and `selectorScope` (function selector allowlist) are checked inside `AAStarAirAccountBase._executeSessionKeyCall()` during the execution phase, not during `validateUserOp`.

This means:

- A UserOp signed by a valid session key always passes validation, even if the `callTarget` or `callSelector` is outside the session's declared scope.
- The scope enforcement fires later (execution phase), causing the transaction to **revert after gas is consumed**, rather than being rejected by the bundler pre-flight.
- There is no way under ERC-4337's stateless validation model to read call target/selector during `validateUserOp` without a storage read (which bundlers disallow during simulation).

### Risk

A malicious bundler or attacker who gains a session key cannot bypass scope enforcement — the execution-phase check will revert. However:
- Gas is still consumed on out-of-scope calls (no bundler-level early rejection).
- The user experience is degraded: bundler simulation may show "valid" for an out-of-scope call, which then reverts on-chain.
- If a future ERC-4337 version allows calldata inspection in `validateUserOp`, the enforcement should be moved there.

### Mitigation

- This is a fundamental ERC-4337 architectural constraint (stateless validation rule), not a contract bug. The scope check cannot be moved to the validation phase without violating bundler policy.
- Execution-phase enforcement is correct and complete — out-of-scope calls always revert.
- Future improvement: ERC-4337 v0.8 / native AA models may allow richer validation context; scope enforcement can be updated then.

### Auditor Note

Auditors should confirm that `_executeSessionKeyCall()` correctly enforces `contractScope` and `selectorScope` for every execution path. The validation-phase gap is accepted and documented here.

---

## KI-10 — ForceExit Proposal Invalidated by Guardian Set Change — 🟡 SUPERSEDED by v0.17.2-beta.2 design change

**Severity**: ~~Low~~ → **Resolved**
**Affected Contract**: `ForceExitModule.sol` — `proposeForceExit` / `approveForceExit` / `executeForceExit`
**Category**: Guardian management / social recovery consistency

> **Superseded by v0.17.2-beta.2 (2026-06-02 — David PR #68 review LOW-1 fix):** The earlier "Resolved" claim — that snapshotting guardians at propose time means `updateGuardians()` **cannot** invalidate in-progress approvals — was a **DESIGN STANCE** ("continuity wins") that the v0.17.2-beta.2 LOW-3 fix **reverses** ("freshness wins"). See [`forceexit-design-notes.md`](forceexit-design-notes.md) §5 for the new policy.
>
> Current truth as of beta.2:
> - The guardian snapshot is still stored in `ExitProposal.guardians` at propose time (KI-10's premise).
> - But `approveForceExit()` now additionally checks the signer is in the account's **current** guardian set — a guardian rotated out via `removeGuardian` + `addGuardian` between propose and approve will revert `SignerNoLongerGuardian`.
> - Effect: guardian rotation CAN invalidate in-progress approvals. KI-10's "Resolved" wording is obsolete; the underlying design has shifted.
>
> Issue #59 (filed against pre-snapshot text) remains closed because the snapshot mechanism itself is in place — it's the implication that was overturned, not the data structure.

### Description

When a `proposeForceExit()` is recorded, the proposal stores the `proposer` address but does **not** snapshot the guardian set at proposal time. If the account owner subsequently calls `updateGuardians()` to change the guardian set between the proposal and execution, the new guardian set governs `approveForceExit` and `executeForceExit`. Any guardian signatures collected under the old set become invalid — their addresses are no longer recognized as guardians.

This means:

1. Alice proposes a force exit. Guardians G1, G2, G3 are set.
2. Owner (possibly compromised) calls `updateGuardians()` replacing G1, G2, G3 with G4, G5, G6.
3. G1 and G2 attempt to `approveForceExit` → revert `NotGuardian`.
4. The force exit is effectively blocked unless G4/G5/G6 cooperate.

### Risk

A compromised owner key could delay or block an in-progress force exit by rotating the guardian set after proposal. This is a **guardian-override attack**: the owner key provides a last-resort escape hatch to block forced withdrawal.

The risk is partially mitigated by the `installModuleThreshold` requirement: changing guardians (via module reinstall) requires owner + 1 guardian. However, `updateGuardians()` is an owner-only call in the current implementation.

### Mitigation

- **Security-first design choice**: the current behavior is intentional. Blocking an in-progress force exit is only possible if the owner key cooperates with a guardian change, which implies the owner is not fully compromised (or is actively trying to stop an unauthorized recovery).
- Future improvement: snapshot the guardian set at proposal time (store a `bytes32 guardianSetHash`), and validate approvals against the snapshotted set rather than the current set. This would prevent guardian rotation from invalidating an in-progress proposal.
- Alternatively: add a `guardianVersion` counter; `approveForceExit` must match the `guardianVersion` at proposal time.
- Users who detect a guardian-rotation attack during an active force exit should re-propose with the new guardians.

### Auditor Note

Auditors should verify that `updateGuardians()` cannot be called during an active force exit proposal without requiring threshold signatures. If `updateGuardians` can be called with only an owner key while a proposal is active, this represents a meaningful degradation of the force exit security guarantee.

---

## KI-11 — Validated-State Transient Queue Re-use Within Identical Calldata (HIGH-3 residual)

**Severity**: Low (not profitably exploitable)
**Affected Contract**: `AAStarAirAccountBase.sol` — `_setCallDataKey` / `_store*` / `_consume*` validation queue
**Category**: ERC-4337 validation/execution split
**Tracking**: [issue #52](https://github.com/AAStarCommunity/airaccount-contract/issues/52)

### Description

The account passes validated state (algId, session key, weight) from the `validateUserOp` phase to the `execute` phase through EIP-1153 transient storage. In v0.17.1 the queue was hardened to be **content-keyed** by `keccak256(callData)` (HIGH-3 fix), and reads are non-destructive, so a nested or replayed frame can no longer pop a value validated for a *different* callData.

The residual edge (Codex 2026-05-30 review escalated this to HIGH; AAStar classified it as LOW after reviewing the attack economics — see authoritative analysis below):

**Mechanism.** Within one bundle, two UserOps with **byte-identical callData but different nonces** share the same transient slot, so a lower-tier UserOp can read the algId written by a higher-tier UserOp for the same callData. Identical to the inline `AUDIT NOTE — HIGH-3 residual` block above `_setCallDataKey` in `AAStarAirAccountBase.sol`.

**Why this is LOW, not HIGH:**

- Identical callData ⇒ identical `(dest, value, func)`. The attacker cannot redirect funds, change amount, or change function — they can only **duplicate** an operation the victim already authorized.
- Attacker gains **zero value**: the recipient is the victim's chosen recipient, not the attacker.
- Customer impact at worst: a griefing double-execution of a transfer the customer was already going to make. **No theft. No privilege escalation beyond what the high-tier UserOp the customer is submitting already grants.**
- Required conditions are very narrow:
  1. Attacker already holds owner-ECDSA (itself the most catastrophic compromise — at which point Tier-1 attacks are far cheaper / more flexible);
  2. A legitimate high-tier UserOp for that exact callData exists in mempool;
  3. Bundle ordering puts the attacker's lower-tier UserOp after the legitimate higher-tier one in the same bundle.

### Risk

No fund-redirection or privilege-escalation path. An attacker cannot manufacture a higher-tier authorization they do not already possess, and cannot change where funds go while keeping callData byte-identical.

### Mitigation

- Current content-keying already blocks the cross-callData confusion that made the original HIGH-3 a real finding.
- Long-term hardening tracked in #52: route the validated-state handoff through `executeUserOp` so the queue is strictly single-consume per UserOp `(sender, nonce, callData)`, removing the residual re-read entirely.

### Auditor Note

If a reviewer finds a callData shape where re-reading validated state yields authority the signer did **not** already have for that exact callData, that would exceed the documented residual and should be filed as a new finding. Specifically: any path where (a) the attacker does not need to hold the higher-tier sig for callData X, OR (b) the duplicated execution can be redirected to attacker-controlled address.

---

## KI-12 — Leaked Testnet Key in Historical Records

**Severity**: Low (testnet-only, operational)
**Affected**: deployment scripts / docs referencing `0xb5600060e6de5E11D3636731964218E53caadf0E`
**Category**: Operational key hygiene

### Description

The testnet owner/bundler key `0xb5600060e6de5E11D3636731964218E53caadf0E` appearing in historical deployment records and `docs/contract-registry.md §3.3` has been **leaked**. It is a Sepolia testnet key with no mainnet authority and no production funds.

### Mitigation

- Treat this key as burned: **rotate** before any further deployment or E2E run; never fund it beyond throwaway testnet gas.
- Do not reuse this address for any v0.17.1 release deployment.

### Auditor Note

No on-chain contract change is implicated. This is an operational note so that the address is never mistaken for a live, trusted operator key.

---

## KI-13 — ForceExit Constrained by Tier-1 Daily Limit (v0.17.2)

**Severity**: Low (operational, no security loss — break-glass works but is rate-limited)
**Affected Contract**: `ForceExitModule.sol` — `executeForceExit`
**Category**: Emergency withdrawal UX
**Tracking**: v0.18 issue (TBD) — add bypass path

> **Identified by Codex P1-#7 on 2026-05-30 and INFO-2-confirmed on round 5 (2026-05-31). v0.17.2 documents this as a known limitation rather than rewriting the V7 surface; v0.18 will add a dedicated guard-bypass entrypoint for guardian-approved force exits.**

### Description

v0.17.2's M-2 fix routes `ForceExitModule.executeForceExit(account)` through `account.executeFromExecutor(...)`, which internally runs the same `_enforceGuard(value, ALG_ECDSA, ...)` as any normal executor call. That guard enforces the account's **Tier-1 daily ETH limit**.

Net effect: a force-exit can only move at most `dailyLimit - todaySpent` wei in a single transaction. If the daily limit is small relative to account balance — or an attacker proactively burns the daily limit through legitimate low-amount UserOps to keep `todaySpent ≈ dailyLimit` — force-exit is throttled to the next day.

### Risk

- Funds are **not at risk** — the value still goes to the guardian-approved L1 target.
- The "break-glass emergency exit" UX is degraded into a "rate-limited exit". Across days the full balance can still be withdrawn (re-propose with a fresh value each day).
- A motivated attacker who already controls the owner key can keep `todaySpent` saturated, but they can also drain at Tier-1 rate directly, so this attack vector adds no real harm beyond what owner-key compromise already enables.

### Mitigation (v0.17.2 — operational)

- Set `dailyLimit` ≥ the maximum value the user might ever need to force-exit in a single day. Documentation guidance: account holders should configure daily limit at or above their target evacuation amount.
- Multi-day force-exit: re-call `proposeForceExit` with smaller per-tx values across consecutive days until the account is drained.
- Don't conflate this with a security failure — guardian consent is still required, and the exit eventually completes.

### Long-term Fix (v0.18+)

Add a dedicated function on V7, e.g. `executeFromForceExit(address target, uint256 value, bytes data) external` that:

1. Verifies `msg.sender` is the registered `ForceExitModule` address (set once at deploy time, e.g. via a new immutable on V7 or a set-once setter on factory + V7 lookup).
2. **Skips** `_enforceGuard` — the 2-of-3 guardian approval already in `ForceExitModule.executeForceExit` is the authority, so daily-limit re-enforcement is redundant.
3. Performs `target.call{value: value}(data)` directly.

Estimated bytecode cost on V7: ~200 B (fits the v0.17.2 EIP-170 headroom of ~3 KB).

### Auditor Note

Auditors should confirm that:
- `ForceExitModule.executeForceExit` correctly requires ≥ `APPROVAL_THRESHOLD` (2-of-3) approvals before invoking `executeFromExecutor`.
- The proposal data (target / value / data) signed by guardians cannot be tampered with between approval and execution (guardian snapshot + proposal-hash binding).
- No existing executor path allows bypassing `_enforceGuard` for arbitrary value — only the guardian-gated `ForceExitModule` path will gain bypass in v0.18, and only for its specific bridge-precompile target.
- Codex round 5 INFO-2 explicitly confirmed: "This is not a vulnerability; it confirms the documented KI-13 concern is implemented as 'emergency exit is constrained by Tier-1 executor guard' rather than 'guard bypass for emergency drain.'"

---

## KI-14 — Calldata parsers disabled in v0.17.2-beta.1 (Codex round 5 HIGH-4 / HIGH-5)

**Severity**: was HIGH (fail-open token tier bypass) → mitigated by **disabling parser deployment** in beta.1
**Affected Contracts**: `src/parsers/RailgunParser.sol`, `src/parsers/UniswapV3Parser.sol`
**Category**: DeFi protocol-aware token guard

### Description

Codex round 5 found two real fail-open + misdecoding issues:

- **HIGH-4 (Uniswap)**: `UniswapV3Parser` misdecodes `exactInput`'s outer tuple offset (reads `amount` from the wrong field, derives `token` from the recipient instead of the path). Selectors `exactOutputSingle`, `exactOutput`, `multicall` return `(address(0), 0)` and the account's parser path fails open. Result: Tier-1 signer can swap > Tier-1 configured-token amounts.
- **HIGH-5 (Railgun)**: `RailgunParser` reads only ONE fixed-offset item even though Railgun calldata can contain a multi-item array. Multi-item shield/transact calldata undercounts the tier-checked amount to the first item.

### Mitigation (effective in beta.1)

- `script/DeployV0172Beta.s.sol` **does NOT deploy** `RailgunParser` / `UniswapV3Parser`. `CalldataParserRegistry` is still deployed (cheap stub for future opt-in).
- No account should call `setParserRegistry(parserRegistry)` AND register parsers on the registry until the parsers are rewritten.
- Without the parser path active, the account's ERC20 native check (`transfer` / `approve` selectors) is the only token-amount guard; Uniswap-style multicalls flow through unchecked.

### Risk while disabled

Accounts that DON'T opt into parsers are unaffected. Accounts on v0.17.1 that historically opted into parsers should call `setParserRegistry(address(0))` before upgrading to v0.17.2 contracts.

### Plan for beta.2 / final

Rewrite both parsers with:
- Proper ABI decoding (not fixed-offset reads)
- Multi-item Railgun array support — sum all spends per token
- Uniswap: handle `exactInput`'s wrapping tuple correctly; add `exactOutputSingle` / `exactOutput` / `multicall`; **fail closed** on unsupported selectors instead of returning `(0, 0)`

Re-enable in `DeployV0172Beta.s.sol` once Codex re-reviews.

---

## KI-15 — EIP-7702 delegate has minimal token guard (no DeFi parser)

**Severity**: Low (acknowledged limitation; partial mitigation of round 5 MEDIUM-1)
**Affected Contract**: `AirAccountDelegate.sol`
**Category**: 7702 delegated execution

### Description

v0.17.2-beta.1 round 5 MEDIUM-1 fix added ERC20 `transfer` / `approve` selector parsing to `AirAccountDelegate.execute` / `executeBatch` (closing the bypass where `execute(token, 0, transferCalldata)` skipped token tier check entirely). The delegate intentionally does NOT carry a parser registry — DeFi calldata (Uniswap multicall, Curve swaps, etc.) is NOT parsed and flows through with no ERC20 tier check on the delegated path.

### Risk

A 7702-delegated EOA used for DeFi protocol calls bypasses the token tier+daily check at the delegate boundary. Native AirAccount (non-7702) accounts have the parser path and are unaffected.

### Mitigation

- Document on the 7702 onboarding flow that "delegated execution covers ETH + ERC20 raw transfer/approve, not DeFi-protocol calldata".
- High-value users should use a native AirAccount instead of EIP-7702 delegation when DeFi interaction is expected.
- Future (v0.18+): extend the delegate with a minimal parser-registry pointer.

### Auditor Note

This is a delegate-specific limitation, NOT a regression. v0.17.1 had a strictly worse state (no ERC20 check on delegate at all). KI-1 documents the broader EIP-7702 raw-key bypass risk; this is the narrower in-contract DeFi-parser gap.

---

## Summary Table

| ID | Issue | Severity | Category | Fixable? |
|----|-------|----------|----------|----------|
| KI-1 | EIP-7702 private key permanence | Medium | Protocol limitation | No |
| KI-2 | Guardian self-dealing after trust | Medium | Trust model | No (social) |
| KI-3 | Low threshold enables single-key module install | ~~High~~ → not reachable | Configuration | **N/A — no setter; threshold fixed at 70** |
| KI-4 | Velocity window reset timing (2x calls possible) | Low | Rate limiting | Deferred (#57) |
| KI-5 | Best-effort onInstall() swallows revert | ~~Low~~ | Module init | ✅ **Resolved (#21, hard-revert)** |
| KI-6 | No timelock on module install | Low | Module management | Deferred (#58) |
| KI-7 | P256 precompile only on OP Stack chains | Medium | Deployment | Deployment-specific |
| KI-8 | Weighted signature bitmap malleability | Informational | By design | N/A |
| KI-9 | Session key scope checked in execution phase only | Medium | ERC-4337 constraint | No (protocol limit) |
| KI-10 | ForceExit proposal invalidated by guardian rotation | ~~Low~~ → reinstated | Design decision **reversed in beta.2** | 🟡 **Superseded** — beta.2 makes rotation INVALIDATE approvals (LOW-3 stale-guardian fix); see forceexit-design-notes.md |
| KI-11 | Validated-state transient re-read within identical calldata (HIGH-3 residual) | Low | Validation/execution split | Planned (#52) |
| KI-12 | Leaked testnet key in historical records | Low | Operational | Rotate key |
| KI-13 | ForceExit constrained by Tier-1 daily limit | Low | Operational UX | Deferred to v0.18 (dedicated bypass path) |
| KI-14 | Calldata parsers disabled in beta.1 (HIGH-4/5) | was HIGH, mitigated | Parser correctness | Planned beta.2 (rewrite parsers) |
| KI-15 | 7702 delegate has minimal token guard (no DeFi parser) | Low | 7702 ergonomics | Planned v0.18+ |
