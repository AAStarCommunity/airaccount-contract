# E2E Results — v0.23.0 (Sepolia, 2026-07-01)

## Scope

v0.23.0 adds `isValidOwnerAuth` (issue #159), a fallback-routed owner-authorization view in
`AirAccountExtension`. The account/tier/recovery/module/session/BLS behavioral logic is
**byte-identical to v0.22.0** (impl unchanged except the added Extension view); its regression is
inherited from v0.22.0's E2E. This run covers the deployment layer (version, validatorRouter
auto-wire, passkey birth injection, CREATE2 address divergence, the full algId whitelist), the new
`isValidOwnerAuth` view, and confirms the PR #158 relay-mode factory views survived the rebase.

> Since v0.22.0 changed the factory API (`createAccount` 3→8 params, `getAddress` 3→5) and thereby
> retired the legacy `scripts/e2e-v0172/08..16` behavioral harness (pinned to the old API), the
> canonical on-chain gate for v0.22.0+ is the `e2e-vX.Y.Z.ts` deployment harness. This run extends
> that with the v0.23.0 additions (T22–T27).

Script: `scripts/e2e-v0.23.0.ts` + `scripts/e2e-isvalidownerauth-v0.23.0.ts`. Fees `baseFee*2 + 2gwei`.

## Deployment under test

| Contract | Address |
|---|---|
| AAStarAirAccountFactoryV7 | `0xc5095E3B3b248007ef69E09F81F75612fBE629ce` |
| AAStarAirAccountV7 (impl) | `0xc8D9803ebde03706926181b540220C5E58306Ef8` |
| AirAccountExtension | `0x3Cb68b0c573608b4f9FF4b51ab33DB88ac495b17` |
| AgentRegistry | `0xF21F9F50d72e2cb0D196AE92CF17F4A79d9b29a1` |

Test accounts:
- Account1 (no P256): `0x64e24EAD126A4Ae26b09035Ea8ee19D71f545afa`
- Account2 (P256 set): `0x4dd209dA536e611E57f87e9904f0588B7549f207` — createAccount tx [`0x3bc49481…440e77`](https://sepolia.etherscan.io/tx/0x3bc4948164ab84dcb765245e4fc059af93f4a0617a5e5235820afdd8d2440e77) (gas 573,013)
- isValidOwnerAuth harness account: `0xDF8b5aEc09b3EfF9942d3A698BfCA5F0aa665513` — createAccount tx [`0xfda38d54…df89f0`](https://sepolia.etherscan.io/tx/0xfda38d543d0ab48ac4c379b9702172755c4b57f40cf54475a51cd23c0fdf89f0)

## Results — `e2e-v0.23.0.ts` (27/27 PASS)

| # | Scenario | Status |
|---|---|---|
| T1 | `impl.ACCOUNT_VERSION()` == "0.23.0" | ✅ |
| T2 | `impl.validatorRouter()` == VALIDATOR_ROUTER (baked-in immutable) | ✅ |
| T3 | createAccount (no P256, direct mode) → account deployed | ✅ |
| T4 | clone `ACCOUNT_VERSION` == "0.23.0" | ✅ |
| T5 | `accountId()` == "airaccount.v7@0.23.0" | ✅ |
| T6 | `account.validator()` == VALIDATOR_ROUTER (auto-wired at birth) | ✅ |
| T7 | `p256KeyX()` == 0 when no key passed | ✅ |
| T8 | createAccount (with P256 key) → account deployed | ✅ |
| T9 | `account2.p256KeyX()` == TEST_PX (set at birth) | ✅ |
| T10 | `account2.p256KeyY()` == TEST_PY (set at birth) | ✅ |
| T11 | different P256 keys → different CREATE2 addresses (anti-front-run) | ✅ |
| T12–T21 | algId whitelist: 0x09,0x0a,0x04,0x05,0x02,0x01,0x03,0x06,0x07,0x08 all approved | ✅ (10/10) |
| **T22** | **`isValidOwnerAuth`: owner ECDSA personal_sign → `0xa0cf00cf`** | ✅ |
| **T23** | **`isValidOwnerAuth`: wrong signer → `0xffffffff`** | ✅ |
| **T24** | **`isValidOwnerAuth`: unknown tag → `0xffffffff`** | ✅ |
| **T25** | **`isValidOwnerAuth`: empty ownerAuth → `0xffffffff`** | ✅ |
| **T26** | **`factory.getConfigHash(...)` present (PR #158) → non-zero hash** | ✅ |
| **T27** | **`factory.hashCreateAccount(...)` present (PR #158) → non-zero digest** | ✅ |

## Results — `e2e-isvalidownerauth-v0.23.0.ts` (4/4 PASS)

Dedicated direct-mode account `0xDF8b5aEc…` (salt 230001):

| Case | ownerAuth | Result |
|---|---|---|
| owner ECDSA `personal_sign` | `0x01 ‖ sig` | `0xa0cf00cf` ✅ |
| wrong signer | `0x01 ‖ sig(stranger)` | `0xffffffff` ✅ |
| unknown tag | `0x03 ‖ …` | `0xffffffff` ✅ |
| empty | `0x` | `0xffffffff` ✅ |

## Deployment transactions (from `deploy-v0.23.0.ts`)

| Step | Tx | Gas |
|---|---|---|
| factory | [`0x38d7913a…67c0b`](https://sepolia.etherscan.io/tx/0x38d7913acf27f1f3b997213b0ff8b73833c430dbe0bce0e72e7d8e179b167c0b) | 3,080,376 |
| agentRegistry | [`0x33a637f2…c9d392`](https://sepolia.etherscan.io/tx/0x33a637f2c7927425151636c41395ee9b0040f3b82702b42a5a11cd7fabc9d392) | 808,200 |
| bindFactory | [`0xa9a69735…718a6d`](https://sepolia.etherscan.io/tx/0xa9a69735f1ad922f73badd91fa87d85c0e99c21150d5bf74a07b5d20e1718a6d) | 48,000 |
| setAgentRegistry | [`0x237701b7…4330f1a`](https://sepolia.etherscan.io/tx/0x237701b76c990693c1edc15ac0b2584d30131331f618b5daece6fd3514330f1a) | 47,839 |

Impl deployed in block 11178704. On-chain `ACCOUNT_VERSION` / `FACTORY_VERSION` = "0.23.0".

## Unit tests (inherited coverage)

Full suite **884 pass** on **both** cancun and prague (0 failed). Includes M-series tier / recovery /
module / session-key / cumulative-signature behavioral tests + `test/IsValidOwnerAuth.t.sol` (17,
incl. 3 fail-closed fuzz @10k runs).

## Codex challenge — VERDICT: PASS

Adversarial per-tx verification via `/codex:rescue` (Codex session `019f1ceb-8e86-7e60-b117-ff069fdd4a18`).

**Verification split** (honest, per established workaround): the live Sepolia receipts + post-state
were pulled by this session via **viem against the real RPC** (`e2e-evidence.json`); Codex's sandbox
blocks outbound RPC, so Codex performed **evidence-consistency + independent-selector** verification
on that data (it does NOT rubber-stamp — it re-derived the magic value itself).

| Item | Codex verdict |
|---|---|
| `factory_deploy` `0x38d7913a…` | REAL ✅ (status=success, to=null, contractAddress==factory, gas 3,080,376) + FEATURE-MET ✅ |
| `createAccount_P256` `0x3bc49481…` | REAL ✅ (status=success, to==factory, gas 573,013) + FEATURE-MET ✅ (account2.p256KeyX==TEST_PX) |
| `createAccount_ownerAuthAcct` `0xfda38d54…` | REAL ✅ (status=success, to==factory) + FEATURE-MET ✅ |
| `impl.ACCOUNT_VERSION` == "0.23.0" | holds ✅ |
| `account1.accountId` == "airaccount.v7@0.23.0" | holds ✅ |
| `isValidOwnerAuth(owner sig)` == `0xa0cf00cf` | magic-on-valid holds ✅ |
| `isValidOwnerAuth(empty)` == `0xffffffff` | fail-on-invalid holds ✅ |
| Magic sanity | Codex independently computed `cast sig "isValidOwnerAuth(bytes32,bytes)"` == `0xa0cf00cf`, and confirmed it is **not** ERC-1271's `0x1626ba7e` ✅ |

**No inconsistencies found** (addresses, `to`, `contractAddress`, gas, version, P256 key, ownerAuth
return values all self-consistent). Codex-noted limitation: it could not decode live event logs
(RPC blocked in its sandbox); the RPC reads were done by this session via viem.

**Overall: PASS — REAL + FEATURE-MET for every tx; negatives fail-closed correctly.**
