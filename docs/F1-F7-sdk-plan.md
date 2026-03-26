# F1-F7 SDK Implementation Plan
# AirAccount M7 → aastar-sdk Upgrade

**Created**: 2026-03-25
**Scope**: F1-F7 frontend/SDK items from M7-TODO.md
**Target repo**: `AAStarCommunity/aastar-sdk` (local: `projects/aastar-sdk`)

---

## Architecture Decisions (4 questions answered)

| Question | Decision |
|----------|---------|
| Q1: SDK repo | Already exists — `AAStarCommunity/aastar-sdk`, pnpm monorepo v0.16.23, 16 packages. No new repo needed. |
| Q2: UI framework | Not needed. SDK is pure TypeScript/Node.js. F6/F7 = helper functions, not React components. |
| Q3: Bundler | Pimlico already in use (`YAAAServerClient.bundlerRpcUrl`). No self-hosting needed. |
| Q4: X402Paymaster.sol | Not needed. `packages/x402/` already has complete `X402Client` using `SuperPaymaster` via `x402Actions(superPaymasterAddress)`. |

---

## The Real Gap

`packages/airaccount/` is currently `YAAAClient` / `YAAAServerClient`, referencing YetAnotherAA old contracts.
**AirAccount M7 ABIs are not in the SDK at all** — `packages/core/src/abis/` has BLSValidator/SuperPaymaster but no `AAStarAirAccountV7`.

**F1-F7 = upgrading `packages/airaccount/` from YAAA to M7.**

---

## Step 1 — Sync M7 ABIs (prerequisite for everything)

Copy from contract repo `out/` to `packages/core/src/abis/`:

- `AAStarAirAccountV7.json`
- `AAStarAirAccountFactoryV7.json`
- `AirAccountCompositeValidator.json`
- `TierGuardHook.json`
- `AgentSessionKeyValidator.json`
- `ForceExitModule.json`

Implement as `scripts/sync-abis.ts` — reads from `airaccount-contract/out/` and copies to `packages/core/src/abis/`.

---

## Step 2 — F1: Hardware Signers (new)

```
packages/airaccount/src/auth/hardware/   ← new
    ledger.ts    # @ledgerhq/hw-app-eth → algId=0x02/0x03
    yubikey.ts   # navigator.credentials.get() → P256 (algId=0x03)
    index.ts
```

Reuse existing `packages/airaccount/src/auth/passkey/` WebAuthn logic to avoid duplication.

---

## Step 3 — F4: EIP-1193 + EIP-6963 (packages/dapp already exists)

```
packages/dapp/src/
    eip1193.ts   # eth_sendTransaction → M7 UserOp conversion
    eip6963.ts   # @mipd/store broadcast for DApp auto-discovery
```

---

## Step 4 — F2 + F3: Helios + ENS (packages/core new utils)

```
packages/core/src/transports/helios.ts   # @a16z/helios → viem custom transport
packages/core/src/utils/ens.ts           # viem/ens forward + reverse lookup
```

---

## Step 5 — F5: x402 + M7 Session Key (extend packages/x402)

`packages/x402/` is already complete. Only change needed: extend `X402ClientConfig` to accept an `AgentSessionKeyValidator` session key account as signer, replacing the current `walletClient`.

```typescript
// Current
walletClient: WalletClient;

// Extended
signer: WalletClient | SessionKeyAccount;
```

No new contract needed — SuperPaymaster already handles on-chain settlement.

---

## Step 6 — F6 + F7: Guard State Helpers + OAPD (packages/airaccount utils)

```
packages/airaccount/src/core/guard/
    daily-limit.ts   # getTodaySpent(), getDailyLimit(), getCurrentTier()
    oapd.ts          # getOapdAddress(owner, dappId, factory)
                     # salt = keccak256(owner ‖ dappId)
```

---

## Dependency Graph

```
Step 1 (ABI sync)
    ↓
Step 2 (F1 hardware)   Step 3 (F4 EIP-1193)   Step 4 (F2/F3)
                             ↓
                        Step 5 (F5 x402 + session key)
                             ↓
                        Step 6 (F6/F7 guard helpers)
```

---

## F1-F7 Mapping

| ID | Feature | Target file | Priority | Notes |
|----|---------|-------------|----------|-------|
| F1 | Hardware wallet SDK | `airaccount/src/auth/hardware/` | High | Ledger + YubiKey; reuse passkey WebAuthn |
| F2 | Helios light client | `core/src/transports/helios.ts` | Medium | Optional trusted RPC toggle |
| F3 | ENS resolution | `core/src/utils/ens.ts` | Medium | Auto-resolve `*.eth` in `to:` field |
| F4 | EIP-1193 + EIP-6963 | `dapp/src/eip1193.ts`, `eip6963.ts` | High | DApp compatibility layer |
| F5 | x402 payment | `x402/` extend signer | Medium | Session key as payment signer |
| F6 | Daily limit UI helpers | `airaccount/src/core/guard/daily-limit.ts` | Low | Read guard state |
| F7 | OAPD address derivation | `airaccount/src/core/guard/oapd.ts` | Low | Per-DApp address isolation |
