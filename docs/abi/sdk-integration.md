# AirAccount — SDK Integration Guide

For `@aastar/sdk` integrators. The **canonical, working reference for every flow below is the
matching e2e script** in [`scripts/e2e-v0172/`](../../scripts/e2e-v0172/) — those are real
transactions on Sepolia (45/45 passing as of v0.17.2-beta.3; re-run against beta.4). They show
exact encoding, signing, and submission. This doc points you at the right script and calls out
the **v0.17.2-beta.4 gotchas** that will silently break an integration if missed.

- ABI to consume: **[`abi/AAStarAirAccountV7.full.json`](../../abi/AAStarAirAccountV7.full.json)**
  (the merged diamond-lite ABI — includes `executeUserOp`, `approvedAlgorithms`, and all
  fallback-routed agent/weighted functions). The bare `out/AAStarAirAccountV7.sol` ABI is
  **insufficient** for the routed surface.
- Web3 lib: **viem** (repo standard).
- Per-function detail: [`reference.md`](./reference.md); selectors: [`selectors.md`](./selectors.md).

---

## 1. Create an account

**Canonical:** [`08-multi-account-types.ts`](../../scripts/e2e-v0172/08-multi-account-types.ts),
[`09` EX.1](../../scripts/e2e-v0172/09-execute-transactions.ts) for `createAccountWithDefaults`.

- `getAddress(owner, salt, InitConfig)` → predict the address (counterfactual deploy).
- `createAccount(owner, salt, InitConfig)` → minimal; **`dailyLimit = 0` deploys no guard**
  (recommended for bundler/agent accounts — see gotcha #1).
- `createAccountWithDefaults(owner, salt, g1, sig1, g2, sig2, dailyLimit)` → full account with
  3 guardians + per-account guard in one tx. Guardians sign an **acceptance signature offline**
  first (`sig1`, `sig2`) — see script for the domain-separated payload.

---

## 2. Sign + submit a transaction (owner-direct)

**Canonical:** [`09-execute-transactions.ts`](../../scripts/e2e-v0172/09-execute-transactions.ts).

Owner EOA calls `account.execute(to, value, data)` (or `executeBatch`). Owner pays gas
directly; the guard checks daily/token limits and the algId whitelist. This path uses
`ALG_ECDSA` and is unchanged in beta.4.

---

## 3. UserOp via bundler

**Canonical:** [`12-userop-bundler.ts`](../../scripts/e2e-v0172/12-userop-bundler.ts) — Pimlico,
self-paying (UO.3) and gasless/paymaster-sponsored (UO.4).

Flow: `pimlico_getUserOperationGasPrice` (oracle, never a fixed value) →
`eth_estimateUserOperationGas` → `EntryPoint.getUserOpHash(packedUserOp)` (use the **packed**
format: `accountGasLimits` + `gasFees` as `bytes32`) → sign `userOpHash` →
`eth_sendUserOperation` → poll `eth_getUserOperationReceipt`.

### Gotcha #1 — `executeUserOp` callData wrapping (BREAKING for guard accounts via bundler)

For a **guard-enabled** account going through a bundler, set:

```
userOp.callData = executeUserOp.selector ‖ <execute|executeBatch calldata>
```

instead of the bare `execute(...)` calldata. EntryPoint v0.7 routes wrapped callData to
`executeUserOp` (`0x8dd7712f`, `onlyEntryPoint`), which re-derives the algId **in the execution
frame** and self-`delegatecall`s the inner call. Wrapping works universally, so the SDK can wrap
for all accounts. Owner-direct (non-bundler) `execute()` must **not** be wrapped.

*Why:* the algId travels validate→execute via EIP-1153 transient storage. Bundlers (Pimlico)
simulate `validateUserOp` and `execute` in **separate `eth_call`s**, between which transient
storage is cleared → the old path saw `algId = 0` and the guard reverted. `executeUserOp` keeps
algId within one frame. The `12` script sidesteps it by deploying with `dailyLimit = 0` (no
guard); for a guarded account you **must** wrap.

Only `execute` / `executeBatch` may be wrapped — any other inner selector reverts
`UnsupportedInnerSelector` (closes a tier-bypass).

### Gotcha #2 — ECDSA signature format

For the bundler/back-compat path, sign with a **raw 65-byte ECDSA sig over `userOpHash`, no
prefix** (`sig.length == 65` ⇒ account takes the `ALG_ECDSA` path). When signing the digest
directly, the contract's `_validateECDSA` applies the EIP-191 prefix internally, so use
`signMessage({ raw: userOpHash })` semantics as shown in the scripts. A 66-byte sig with a
`0x08` prefix selects the session-key path.

---

## 4. Grant a session key

**Canonical:** [`10-session-key-txns.ts`](../../scripts/e2e-v0172/10-session-key-txns.ts).

- Owner-direct: `grantSessionDirect(account, sessionKey, policy)`.
- DApp flow: `grantSession(account, sessionKey, policy, ownerSig)` — user signs the grant
  client-side, DApp submits.
- Passkey: `grantP256SessionDirect(account, x, y, policy)`.
- Revoke: `revokeSession` / `revokeP256Session`; check with `isSessionActive` /
  `isP256SessionActive`.

`policy` = `(expiry, callTarget, selector, allowAllTargets, ..., velocityCap, velocityWindow,
callTargets[], selectorAllowlist[])` — see the struct in `reference.md` /
`SessionKeyValidator`. **Gotcha:** `velocityWindow = 0` is rejected; the velocity rate uses
cross-multiplication (no division), so set both cap and window deliberately.

---

## 5. Propose / approve recovery

**Canonical:** [`11-guardian-recovery-module.ts`](../../scripts/e2e-v0172/11-guardian-recovery-module.ts) GR.2–GR.8.

`proposeRecovery(newOwner)` (a guardian) → `approveRecovery()` (other guardians, 2/3 threshold,
72h timelock). **`cancelRecovery()` needs 2/3 guardian votes, not the owner** — owner calling it
reverts `NotGuardian` (`0xef6d0f02`). On salt-fixed/test accounts, call `clearStaleRecovery()`
before re-proposing (stale `activeRecovery` accumulates across runs). Error selectors:
`0x6e5510ce` `RecoveryAlreadyActive`, `0xaa40cfc6` `RecoveryTimelockNotExpired`.

---

## 6. Install / uninstall a module

**Canonical:** [`11-guardian-recovery-module.ts`](../../scripts/e2e-v0172/11-guardian-recovery-module.ts) GR.9–GR.12.

`installModule(typeId, module, initData)` — owner initiates, a guardian signs `initData` as
authorisation (`onInstall` hard-reverts on failure). `uninstallModule(typeId, module,
deInitData)` where **`deInitData = sig1 ‖ sig2`** (130 bytes, `min(guardianCount, 2)` guardian
sigs). Type IDs: 1=validator, 2=executor, 4=hook (ERC-7579). A module can be installed under
multiple typeIds; lifecycle is skipped for the already-installed typeIds.

---

## 7. Guard / whitelist (beta.4 changes)

- **Whitelist now lives on the account, not the guard:** read `account.approvedAlgorithms(algId)`
  (was `guard.approvedAlgorithms`); write via `account.guardApproveAlgorithm(algId)` (signature
  unchanged, owner-gated, monotonic add).
- **Guard ABI changed:** `checkTransaction` / `checkTokenTransaction` / `approveAlgorithm` /
  `approvedAlgorithms` were **removed**; `recordSpend(value)` / `recordTokenSpend(token, amount,
  algId)` were added. SDK code that called the guard directly must update — most SDKs go through
  the account and are unaffected.
- **Existing beta.3 accounts are not retrofittable** (non-upgradable clones). To use the
  bundler-compatible path, create a beta.4 account and migrate assets.

---

## Quick reference: key selectors

| Function | Selector | Contract |
|---|---|---|
| `execute(address,uint256,bytes)` | `0xb61d27f6` | account |
| `executeBatch(address[],uint256[],bytes[])` | `0x47e1da2a` | account |
| `executeUserOp((...),bytes32)` | `0x8dd7712f` | account (bundler wrap) |
| `validateUserOp((...),bytes32,uint256)` | `0x19822f7c` | account |
| `createAccountWithDefaults(...)` | `0xdd8d1e3a` | factory |
| `grantSession(...)` | `0x3881ca82` | SessionKeyValidator |
| `proposeRecovery(address)` | `0x7ee76082` | account |
| `installModule(uint256,address,bytes)` | `0x9517e29f` | account |

For the complete list, see [`selectors.md`](./selectors.md) (regenerated by `pnpm gen:abi-docs`).
