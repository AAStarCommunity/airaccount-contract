# AirAccount ABI Documentation

Authoritative, auto-updatable documentation of every callable surface of the AirAccount
contracts (a non-upgradable ERC-4337 v0.7 smart account, currently **v0.17.2-beta.4**), for
upstream consumers: the [`@aastar/sdk`](https://github.com/AAStarCommunity/aastar-sdk) team,
integrators, and debuggers.

## What's here

| File | Kind | Purpose |
|---|---|---|
| [`reference.md`](./reference.md) | **generated** | Per-contract reference: every external/public function — signature, 4-byte selector, params, returns, `@notice`/`@dev`, state mutability, access control. Plus events (topic0) and custom errors. |
| [`selectors.md`](./selectors.md) | **generated** | Flat global index: every function selector, error selector, and event topic across all `src/` contracts — for decoding raw calldata / revert data / logs. |
| [`capabilities.md`](./capabilities.md) | hand-written | Capability-grouped map: each capability → the functions that implement it → the e2e script that demonstrates it → what it lets a user do. |
| [`sdk-integration.md`](./sdk-integration.md) | hand-written | Key call flows for SDK integrators (create account, UserOp via bundler, session keys, recovery, modules) + the v0.17.2-beta.4 gotchas. |

> **Generated vs hand-written.** `reference.md` and `selectors.md` carry a `GENERATED FILE`
> marker at the top and must **never** be hand-edited — they are rebuilt from the compiled
> ABIs. `capabilities.md` and `sdk-integration.md` are curated and are safe to edit.

## How the generated docs are produced

```
forge build            →  out/<Name>.sol/<Name>.json   (ABI + methodIdentifiers + NatSpec)
                                     │
scripts/gen-abi-docs.mjs ────────────┘ →  docs/abi/reference.md
                                          docs/abi/selectors.md
```

The generator (`scripts/gen-abi-docs.mjs`) reads, for each contract whose source lives under
`src/`:

- **`artifact.abi`** — function / event / error fragments,
- **`artifact.methodIdentifiers`** — solc's authoritative signature → 4-byte selector map
  (selectors are also independently recomputed with `viem` and cross-checked; a mismatch
  aborts the build),
- **`artifact.metadata.output.userdoc` / `devdoc`** — NatSpec `@notice` / `@dev` / `@param`
  / `@return`,
- **the Solidity source header** — best-effort scrape of access modifiers
  (`onlyOwner`, `onlyEntryPoint`, `onlyOwnerOrEntryPoint`, `onlyGuardian`, `nonReentrant`, …).

It is **idempotent**: the output is a pure function of `out/` + `src/` with no timestamps, so
re-running on an unchanged build yields byte-identical files.

## Regenerate

```bash
forge build            # refresh out/ if contracts changed
pnpm gen:abi-docs       # writes docs/abi/reference.md + docs/abi/selectors.md
```

## CI / drift check

```bash
pnpm gen:abi-docs:check    # exits 1 if the committed generated docs are stale
```

Wire `pnpm gen:abi-docs:check` into CI (after `forge build`) so the docs can never drift from
the ABI. It is the doc analogue of the existing `node scripts/build-full-abi.mjs --check`
guard for `abi/AAStarAirAccountV7.full.json`.

## The merged "full" account ABI

`AAStarAirAccountV7` is a **diamond-lite** account: its cold functions (ERC-8004 agent +
weighted-signature governance) are routed to the singleton `AirAccountExtension` via
`fallback` + `delegatecall`, so they execute on-chain but are **not** in the
`AAStarAirAccountV7` compiler ABI. The SDK must therefore consume the merged artifact
[`abi/AAStarAirAccountV7.full.json`](../../abi/AAStarAirAccountV7.full.json), produced by
`node scripts/build-full-abi.mjs` (separate from this doc generator). `reference.md`
documents the routed surface under both `AAStarAirAccountV7` (native) and `IAirAccountAgent`
(the fallback-routed interface).
