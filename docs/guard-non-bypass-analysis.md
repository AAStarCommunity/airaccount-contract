# Guard Non-Bypass Analysis (CC-99 需求2)

**Claim (Onion §4.7):** every path that moves native ETH or ERC-20 value out of an AirAccount routes
through the account's guard (`_enforceGuard` → `AAStarGlobalGuard.recordSpend` for native; `_checkTokenGuard`
for tokens). The tiered cumulative-metering ("anti-splitting") mechanism therefore cannot be bypassed.

This replaces the paper's earlier **manual 4-line enumeration** — which the `withdrawDepositTo` (H1) and
`executeFromExecutor` cases historically slipped past — with an **exhaustive static enumeration of every
value-send primitive** plus a **dynamic Foundry invariant**.

## 1. Static exhaustiveness — every native ETH-send site

Enumerated by grepping the account for **all** native-value-send primitives (`call{value:}`, `.transfer`,
`.send`, `EntryPoint.withdrawTo`) — not by listing entrypoints (which is what missed H1). Every site:

| Site | Send primitive | Reached from | Guard |
|---|---|---|---|
| `AAStarAirAccountBase.sol:1856` | `target.call{value}` (inside `_call`) | `execute` (:1372), `executeBatch` (:1413), `executeUserOp`→execute | ✅ `_enforceGuard` |
| `AAStarAirAccountV7.sol:393` | `target.call{value}` | `executeFromExecutor` (:390) — the ERC-7579 executor path; `ForceExitModule` routes here | ✅ `_enforceGuard` (:390) |
| `AAStarAirAccountBase.sol:1843` | `IEntryPoint.withdrawTo` | `withdrawDepositTo` (:1835) — **the H1 path** | ✅ `_enforceGuard` (:1842) |
| `AAStarAirAccountBase.sol:1850` | `payable(entryPoint).call{value: missingAccountFunds}` | `_payPrefund` (ERC-4337 validation prefund) | ⚠️ **intentional exclusion** |

**The `:1850` exclusion is correct, and is exactly why "prove exhaustive" beats "list entrypoints":** it is
the mandatory ERC-4337 gas prefund to the EntryPoint — not a user-directed transfer. Its amount is
`missingAccountFunds` (set by the EntryPoint, bounded by the op's own gas), the recipient is fixed to the
EntryPoint, and it is not a spending path the tier/daily limits are meant to govern. A guard on it would be
meaningless (the account must prefund to run at all). A naive "any `call{value}` is a bypass" check would
false-positive here; the enumeration correctly classifies it.

**Result:** the low-level ETH-send primitive `_call` is reachable from **only** `execute`/`executeBatch`
(and `executeUserOp`, which routes to `execute`); the only other native sends are the guarded
`executeFromExecutor`/`withdrawDepositTo` and the excluded prefund. **No unguarded user-value path exists.**

## 2. Token (ERC-20) value

Token moves (`transfer`/`transferFrom`/`approve` selectors in `func`) are metered by `_checkTokenGuard`,
shared by `_enforceGuard` and `executeFromExecutor` (`AAStarAirAccountBase.sol:~1713`). Same entrypoints,
same guard.

## 3. Dynamic proof — Foundry invariant (`test/GuardMeteringInvariant.t.sol`)

A handler drives the **real** flow (`validateUserOp` stores the tier algId in transient storage, then
`execute`/`executeBatch`/`withdrawDepositTo` in the same frame — 0 reverts on the value-moving calls means
ETH actually moves, not a vacuous all-revert "test"). Invariants over 256 runs / 128,000 calls:

- `invariant_guardMetersAllOutflow`: `guard.todaySpent() >= receiver.balance` — the guard accounted for at
  least every wei that left the account. A bypass (value out with no `recordSpend`) would make the
  receiver's balance exceed `todaySpent` → FAIL.
- `invariant_meteredEqualsSent`: `guard.todaySpent() == intended sent` — exact, no silent loss/gain.

Coverage: `execute`, `executeBatch`, `withdrawDepositTo` (the H1 path). `executeUserOp` shares `execute`'s
`_call`; `executeFromExecutor`/`ForceExitModule` share the guarded V7:393 site (covered statically in §1).
Both invariants hold.

## 4. Reusable for the Weighted-signature paper

The same guard choke points apply to the weighted-signature path (algId 0x07 resolves to a concrete tier
before `_enforceGuard`), so this analysis + invariant transfer directly.
