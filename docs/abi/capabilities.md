# AirAccount — Capability Map

A capability-grouped view of the AirAccount ABI. Each capability lists the functions that
implement it, the **end-to-end script** that exercises it on a live network (real working
call/encode/sign/submit examples), and a one-line "what it lets a user do".

- Full per-function detail (params, returns, NatSpec, selectors, access): [`reference.md`](./reference.md).
- Flat selector lookup: [`selectors.md`](./selectors.md).
- Integration flows + beta.4 gotchas: [`sdk-integration.md`](./sdk-integration.md).
- E2E scripts live in [`scripts/e2e-v0172/`](../../scripts/e2e-v0172/); run with `pnpm tsx scripts/e2e-v0172/<file>`.

Contract legend: **V7** = `AAStarAirAccountV7`, **Base** = `AAStarAirAccountBase` (the account's
shared base; most account-instance functions resolve here), **Factory** =
`AAStarAirAccountFactoryV7`, **Ext** = `AirAccountExtension` (fallback-routed cold functions),
**Guard** = `AAStarGlobalGuard`, **SKV** = `SessionKeyValidator`, **Delegate** =
`AirAccountDelegate` (EIP-7702).

---

## 1. Account creation

**E2E:** [`08-multi-account-types.ts`](../../scripts/e2e-v0172/08-multi-account-types.ts)

| Function | Contract | What it lets a user do |
|---|---|---|
| `createAccount(owner, salt, InitConfig)` | Factory | Minimal create: owner + optional guard. `dailyLimit=0` ⇒ **no guard deployed** (bundler/agent-friendly). |
| `createAccountWithDefaults(owner, salt, g1, sig1, g2, sig2, dailyLimit)` | Factory | Full create in one tx: 3 guardians (g1, g2 + community) pre-sign acceptance, per-account `AAStarGlobalGuard` + daily limit deployed. |
| `createAgentAccount(owner, salt, agentWallet, ...)` | Factory | Agent account: auto-installs `SessionKeyValidator` (algId `0x08`), binds `AgentRegistry`, factory-provenance whitelist. |
| `getAddress(owner, salt, InitConfig)` | Factory | Predict the CREATE2 address before deploying (counterfactual). |
| `getAgentAddress(...)` | Factory | Predict an agent account's address. |

Accounts are EIP-1167 clones of an immutable implementation — **non-upgradable** by design.

---

## 2. Execute / batch (owner-direct)

**E2E:** [`09-execute-transactions.ts`](../../scripts/e2e-v0172/09-execute-transactions.ts)

| Function | Contract | What it lets a user do |
|---|---|---|
| `execute(to, value, data)` | Base | Single call by owner (ECDSA) or EntryPoint; runs the guard accounting chain. |
| `executeBatch(to[], value[], data[])` | Base | Batch calls; each call independently hits the guard (no cross-call cumulation). |
| `addDeposit()` (payable) | Base | Pre-fund the account's EntryPoint deposit (prerequisite for self-paying UserOps). |
| `getDeposit()` | Base | Read the account's EntryPoint deposit balance. |
| `withdrawDepositTo(to, amount)` | Base | Withdraw part of the EntryPoint deposit (owner only). |

Access: `execute`/`executeBatch` are `onlyOwnerOrEntryPoint`. Non-owner direct call reverts
`NotOwnerOrEntryPoint`; `value > dailyLimit` reverts at the guard (both proven in `09`).

---

## 3. ERC-4337 UserOp via bundler (`executeUserOp` wrapper)

**E2E:** [`12-userop-bundler.ts`](../../scripts/e2e-v0172/12-userop-bundler.ts) (Pimlico, self-paying + gasless)

| Function | Contract | What it lets a user do |
|---|---|---|
| `validateUserOp(userOp, userOpHash, missingFunds)` | V7 | EntryPoint-only signature validation + whitelist + per-op tier gate. |
| `executeUserOp(userOp, userOpHash)` | V7 (`onlyEntryPoint`) | EntryPoint execution entry; re-derives algId in-frame, then self-`delegatecall`s the inner `execute`/`executeBatch`. **The bundler-compatible execution path** (see beta.4 gotcha #1). |

A bundler submits `eth_sendUserOperation`; `from` = bundler EOA, `to` = EntryPoint v0.7, gas
paid from the account's EntryPoint deposit (or a paymaster). For **guard-enabled** accounts the
SDK must wrap callData with the `executeUserOp` selector — see
[`sdk-integration.md`](./sdk-integration.md#3-userop-via-bundler).

---

## 4. Session keys (algId `0x08`)

**E2E:** [`10-session-key-txns.ts`](../../scripts/e2e-v0172/10-session-key-txns.ts)

| Function | Contract | What it lets a user do |
|---|---|---|
| `grantSessionDirect(account, sessionKey, policy)` | SKV | Owner directly grants a scoped ECDSA session (expiry + callTargets + selector allowlist + velocity). |
| `grantSession(account, sessionKey, policy, ownerSig)` | SKV | DApp flow: user signs the grant client-side, DApp submits (user sends no tx). |
| `grantP256SessionDirect(account, x, y, policy)` | SKV | WebAuthn passkey session: the session key is a P-256 pubkey (hardware-bound, fingerprint-authorised). |
| `revokeSession(account, sessionKey)` / `revokeP256Session(account, x, y)` | SKV | Revoke a session (nonce-based — historical grant sigs become invalid immediately). |
| `isSessionActive(account, sessionKey)` / `isP256SessionActive(account, x, y)` | SKV | Check a session's status. |

Lets a DApp/agent act for the user inside a cage (callTargets + selectorAllowlist + velocity)
without per-action user signatures, and without being able to escape that scope.

---

## 5. Guardian / social recovery

**E2E:** [`11-guardian-recovery-module.ts`](../../scripts/e2e-v0172/11-guardian-recovery-module.ts) (GR.2–GR.8)

| Function | Contract | What it lets a user do |
|---|---|---|
| `proposeRecovery(newOwner)` | Base | A guardian proposes a new owner; starts the 48h timelock, writes `activeRecovery`. |
| `approveRecovery()` | Base | Another guardian approves (sets its bit in `approvalBitmap`); 2/3 reaches threshold. |
| `cancelRecovery()` | Base | Guardians vote to cancel — needs **2/3 guardians, not the owner** (defends against a leaked owner key cancelling a legit recovery). |
| `activeRecovery()` | Base/Ext | Read the pending recovery (newOwner, timestamps, bitmap). |
| `addGuardian(...)` / `getGuardians()` / `guardianCount()` | Base | Manage / read the guardian set. |
| `clearStaleRecovery()` | Base | Clear an expired/stale recovery (needed before re-proposing on salt-fixed test accounts). |

Guardian signatures use **domain separation** per operation to prevent cross-operation replay.

---

## 6. ERC-7579 modules

**E2E:** [`11-guardian-recovery-module.ts`](../../scripts/e2e-v0172/11-guardian-recovery-module.ts) (GR.9–GR.12, installs `ForceExitModule`)

| Function | Contract | What it lets a user do |
|---|---|---|
| `installModule(typeId, module, initData)` | Base | Install a module; owner initiates + a guardian signs `initData` as authorisation. |
| `uninstallModule(typeId, module, deInitData)` | Base | Uninstall; `deInitData` = `sig1 ‖ sig2` (`min(guardianCount, 2)` guardian sigs). |
| `isModuleInstalled(typeId, module, ctx)` | Base | Check install status. |

Module type IDs follow ERC-7579 (1=validator, 2=executor, 4=hook). `ForceExitModule`
(executor, type 2) adds censorship-resistant L2→L1 force-exit:
`proposeForceExit`/`approveForceExit`/`executeForceExit`/`cancelForceExit`.

---

## 7. Agent economy / ERC-8004

**E2E:** [`08-multi-account-types.ts`](../../scripts/e2e-v0172/08-multi-account-types.ts) (AC.6–AC.8) for agent-account creation + registry.

| Function | Contract | What it lets a user do |
|---|---|---|
| `registerAgent(account, data)` / `revokeAgent(account)` | AgentRegistry | Register/revoke an agent account (ERC-721-style ownership of agent identities). |
| `isValidAccount(account)` / `getHumanOwner(account)` / `getAgentByIndex(owner, i)` | AgentRegistry | Resolve agent ↔ human-owner relationships. |
| `mintAgentIdentity(...)` / `setAgentWallet(...)` / `bindERC8004AgentWallet(...)` | Ext | Mint + bind an ERC-8004 on-chain agent identity to the account (fallback-routed). |
| `submitAgentReputation(...)` / `queryAgentReputation(...)` | Ext | Write/read ERC-8004 reputation (fallback-routed). |

These cold functions live on `AirAccountExtension` and are reached via the account's
`fallback` — encode them with `abi/AAStarAirAccountV7.full.json`, not the bare V7 ABI.

---

## 8. Guard / spending limits

**E2E:** exercised implicitly by `09` (dailyLimit revert) and the guard-enabled paths.

| Function | Contract | What it lets a user do |
|---|---|---|
| `recordSpend(value)` | Guard | Account-called: record ETH spend against the daily limit (ETH path no longer carries algId). |
| `recordTokenSpend(token, amount, algId)` | Guard | Record ERC-20 spend; keeps `algId` for per-token tier math. |
| `guardApproveAlgorithm(algId)` | Base | Owner whitelists an algId on the **account** (slot 24) — single source of truth. |
| `approvedAlgorithms(algId)` | Base/Ext | Read whether an algId is whitelisted (moved from guard → account in beta.4). |
| `todaySpent()` / `dailyLimit()` | Guard | Read daily accounting. |

The guard does **policy accounting only** — it never verifies signatures. Tiered limits:
<$100 single WebAuthn, $100–$1000 dual-factor, >$1000 multi-sig (`AlgTierLib`).

---

## 9. EIP-7702 delegate

**E2E:** see repo-root `scripts/test-7702-delegate-e2e.ts` / `test-7702-stealth-e2e.ts`.

| Function | Contract | What it lets a user do |
|---|---|---|
| `initialize(owner, ownerData, guard, guardData, dailyLimit)` | Delegate | Initialise an EOA that has delegated to `AirAccountDelegate` (ECDSA-only, constant algId, bundler-compatible). |
| `execute` / `executeBatch` | Delegate | Same execution surface for a 7702 EOA. |
| `initiateRescue/approveRescue/executeRescue/cancelRescue` | Delegate | Guardian-gated rescue flow for the delegated EOA. |
| `announceForStealth(...)` | Delegate | Emit an ERC-5564 stealth announcement. |

Lets a plain EOA opt into AirAccount features in-place without migrating assets to a new
contract account.

---

## 10. Validators & algorithms (router + BLS)

| Function | Contract | What it lets a user do |
|---|---|---|
| `registerAlgorithm(algId, impl)` / `proposeAlgorithm` + `executeProposal` | AAStarValidator | Register a signature algorithm (direct pre-setup; 7-day timelock after `finalizeSetup`). |
| `getAlgorithm(algId)` / `algorithms(algId)` | AAStarValidator | Resolve an algId → algorithm contract. |
| `validateSignatures(ops[], sig)` / `aggregateSignatures(ops[])` / `validateUserOpSignature(op)` | AAStarBLSAggregator | ERC-4337 `IAggregator`: batch many UserOps into a single BLS pairing check. |
| `verify(...)` (per algorithm) | AAStarBLSAlgorithm | The actual signature verification routed to by the validator (algId-dispatched). |

algId convention: first byte of the signature selects the algorithm (e.g. `0x08` =
session key). `AlgTierLib` maps algId → verification tier for the guard.
