# AirAccount — Known Issues & Accepted Risks

**Version**: v0.16.0 (M7 release candidate)
**Last Updated**: 2026-03-21
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

**Severity**: High if misconfigured (configuration risk, not a code bug)
**Affected Contract**: `AAStarAirAccountBase.sol` / `AAStarAirAccountV7.sol`
**Category**: Access control configuration

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
- A sliding window implementation (tracking call timestamps in a ring buffer) would eliminate this, but would cost significantly more gas per call. This optimization is deferred to a future milestone.
- The `spendCap` limit provides an independent, cumulative bound that the velocity window cannot bypass.

### Auditor Note

Auditors should confirm that the velocity limit enforces at most `velocityLimit` calls in a single window (not across windows). The cross-window 2x effect is accepted. Any path that allows more than `velocityLimit` calls within a single `velocityWindow` period would be a bug.

---

## KI-5 — Best-Effort onInstall() During Factory Pre-Installation

**Severity**: Low (documentation risk)
**Affected Contract**: `AAStarAirAccountFactoryV7.sol`
**Category**: Module initialization

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

## KI-7 — P256 Precompile Availability on Non-OP-Stack Chains

**Severity**: Medium (deployment configuration risk)
**Affected Contracts**: All contracts using P256 (ALG_P256 0x03) via `AAStarValidator.sol`
**Category**: Cross-chain deployment

### Description

AirAccount's P256 (WebAuthn) signature verification uses the EIP-7212 precompile at address `0x0000000000000000000000000000000000000100`. This precompile is only natively available on:

- OP Mainnet (since the Fjord upgrade)
- Base (Fjord)
- Other OP Stack chains with Fjord

On **Ethereum mainnet** and non-OP-Stack L2s (e.g., Arbitrum One, zkSync Era), the precompile does not exist. AirAccount falls back to a Solidity software implementation of P256 verification, which costs approximately **330,000 gas** per verification (vs. ~3,450 gas for the precompile).

### Risk

On Ethereum mainnet, using P256 (WebAuthn) as a tier factor makes `validateUserOp` prohibitively expensive (~350k+ gas). Users deploying on mainnet who rely on WebAuthn for Tier 2/Tier 3 authentication will face unexpected gas costs and may hit bundler gas limits.

Additionally, the software P256 verifier is a separate contract dependency. Its security must be evaluated independently.

### Mitigation

- Primary deployment targets are OP Stack L2s (Base, OP Mainnet) where the precompile is available.
- Deployment documentation explicitly warns against using P256 tier factors on Ethereum mainnet.
- Alternative: Use ECDSA + BLS cumulative tier (`ALG_CUMULATIVE_T2`) as the high-security path on non-OP chains. P256 is reserved for OP Stack deployments.
- The factory deployment script checks `block.chainid` and emits a `P256PrecompileWarning` if deploying to a chain without known precompile support.

### Auditor Note

Auditors should verify that the fallback P256 verifier is correctly integrated and that a precompile call failure does not silently validate a bad signature.

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

## Summary Table

| ID | Issue | Severity | Category | Fixable? |
|----|-------|----------|----------|----------|
| KI-1 | EIP-7702 private key permanence | Medium | Protocol limitation | No |
| KI-2 | Guardian self-dealing after trust | Medium | Trust model | No (social) |
| KI-3 | Low threshold enables single-key module install | High if misconfigured | Configuration | Partially (default is safe) |
| KI-4 | Velocity window reset timing (2x calls possible) | Low | Rate limiting | Deferred |
| KI-5 | Best-effort onInstall() swallows revert | Low | Module init | Planned improvement |
| KI-6 | No timelock on module install | Low | Module management | Planned improvement |
| KI-7 | P256 precompile only on OP Stack chains | Medium | Deployment | Deployment-specific |
| KI-8 | Weighted signature bitmap malleability | Informational | By design | N/A |
