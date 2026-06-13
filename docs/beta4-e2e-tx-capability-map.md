# v0.17.2-beta.4 — On-chain TX → Capability → User Value (Sepolia, verified)

Every transaction below was verified on-chain via Etherscan (chainid 11155111), block window 11049314+ (2026-06-13). `status`: ✅ = success (0x1); 🔁 REVERT = an **intended** on-chain revert (the test asserts rejection — proving a guard works). 45/45 E2E assertions passed (Phase 08-12).

> **Precision note (after adversarial review by Opus):** capability/value claims below are scoped to *what the cited tx actually demonstrates on-chain*. Where a capability is real in the code but **not exercised by a listed tx**, it is marked and collected in the "Not yet E2E-exercised on-chain" footnote — to avoid implying the 45 assertions proved more than they did.

## Deployment (the beta.4 contracts themselves)

| # | TX | What it proves | User value |
|---|----|----|----|
| D1 | `0xef5be2e8fcf0cec29897c6db8409b549963fd9bc9b3edf7d0df8d6dd9891059a` ✅ | Factory (+Impl+Extension) deployed | The bundler-compatible account version exists on-chain |
| D2 | `0x235319392ceb1caf7c3b07f21303758af032ad33b5c59265c2bf4a35eeed6c24` ✅ | AirAccountDelegate (EIP-7702) **deployed** | An existing EOA *can* become an AirAccount (the delegate→initialize→transact flow itself is not E2E-exercised here — see footnote) |
| D3 | `0xa2ea09089b55e06400267d3b3b03cd22ce5d14518a0460f7986bbd9d835a233a` ✅ | AgentRegistry deployed | Agent accounts can be registry-verified for sponsorship |
| D4 | `0xad386e3c810b88881a45c61252cb1c9c8b67e08e07d74f957198dfbac156fa2c` ✅ | agentRegistry.bindFactory | Only this factory's accounts count as valid agents |
| D5 | `0x1cb6f532fa9802fcaed4c70b87d12c1e133acfcc9af64ca73bee253fa281e7d4` ✅ | factory.setAgentRegistry | Factory wired to the registry |

## Account creation

| # | TX | Capability | User value |
|---|----|----|----|
| A1 | `0xd11fe2add2af09ee632572cc001c3d1a433cb96d1198bba49924db040eb41da7` ✅ | `createAccount` (minimal) | A self-custodial ERC-4337 account. The root **owner is an ECDSA/EOA key** (a TEE-managed key in the AirAccount product — the seedless UX is an off-chain property, not enforced by this contract). P256/passkey is supported as a *guardian* or *session key*, not as the root owner. |
| A2 | `0x7f8811666bc2ec52f0949e5e145ce73156b67de42e91086208f1bf579f5752e5` ✅ | `createAccountWithDefaults` (guard + 3 guardians + daily limit, one tx) | Self-custody **with** social recovery + on-chain ETH/configured-token limits out of the box. (3rd guardian is the factory's immutable community guardian; the user supplies 2.) |
| A3 | `0x6f5e2d898392b5ca9c3e0e889f008d699bc22754e874381a1ae0014abc2fda7f` ✅ | `createAgentAccount` (+ registry binding) | A registry-verified account for an AI agent that SuperPaymaster can sponsor. The agent key carries **no authority until `grantAgentSession()`** is called post-creation. |

## Spending & execution

| # | TX | Capability | User value |
|---|----|----|----|
| E1 | `0x4ae439288451cc39ea3aae5dd427e32a1809636e29af6eb1cc2ead051b1fd865` ✅ | `execute` (ETH transfer) | Move funds; the guard meters **native-ETH value** and **configured-ERC20 transfer/approve** on each spend |
| E2 | `0x1d7d0d9e02df444251c21eccba0da1c3ef1fe60e02e85292df18291e8c7f3385` ✅ | `executeBatch` | One signature → many actions atomically (approve+swap, etc.) |
| E3 | `0x6f534943a1eebcdf12860a697e279cd55ace7931ac697413662b0ed2837c56a2` ✅ | `addDeposit` | Account pre-funds its own gas at the EntryPoint (account abstraction) |
| E4 | `0x6a419e76cac8251becaf092632d9c580735090654216f09128346f1ec324201f` ✅ | `withdrawDepositTo` | Owner reclaims unused gas deposit |
| E5 | `0x6c0a60cd0140f3ccbf405e24e32e03b0cf2cc1fd1aac61674a2b1490b8d5941e` 🔁 REVERT | over-`dailyLimit` `execute` rejected on-chain | A stolen owner key **cannot exceed the per-day ETH limit in a single day** and cannot raise the limit (only lower it, to a 10% floor). **Caveat:** the cap is per-day (not absolute), and unconfigured ERC-20s + arbitrary DeFi calldata are **not** metered (KI-15) — not a blanket "uncircumventable" guard. |
| E6 | `0x20784ab859a450d4f342810bc9d50b3917b3e9fea96ad4535c3886305d6280b7` 🔁 REVERT | non-owner `execute` rejected (`NotOwnerOrEntryPoint`) | Only the owner / EntryPoint can move funds |

## Session keys (grant / revoke shown; *use*-time enforcement not exercised — see footnote)

| # | TX | Capability | User value |
|---|----|----|----|
| S1 | `0x6d9e21f9b91ab2b70dd8755b0188a48107f1e6cd7e72806d6252e2f80e37f377` ✅ | `grantSession` (ECDSA) — scope/velocity configured at grant | Lets a dApp/agent act inside a configured box (callTargets/selector/velocity). NB: scope/velocity *enforcement at use* is not exercised by a listed tx. |
| S2 | `0x2ddb58b4aebc1589ee2acb7a8e796501994e3685cab8ba10597b8ee86edd538f` ✅ | `grantP256SessionDirect` — stores a P256 session **record** | Demonstrates a P256 session record can be stored/revoked. The test used a non-curve point; **no P256/WebAuthn signature is verified on-chain** in these txs (no biometric/passkey-signing path is invoked here). |
| S3 | `0x5940f067f6fae71f80e8530483984a02f1ad02103a55bb7a454c1bd4527da69d` ✅ | `revokeSession` | Owner kills a delegated key anytime |
| S4 | `0x5c1fb5d2998e47bb2827f28dd5618f5cf72740341a42e11165959728da5faba9` ✅ | `revokeP256Session` | Same for P256 session records |

## Social recovery (2-of-3 guardians)

| # | TX | Capability | User value |
|---|----|----|----|
| R1 | `0xc653684b3ac55d0c8517d2e2a345fa4fa42efcf71131ed56f5b8767f35114cee` ✅ | `proposeRecovery` (any guardian) | Guardian starts recovery of a lost account |
| R2 | `0xd40ceba7601096f8f3f43eaada7d5e837be9c93d513a519eef5fb549bc3d59aa` ✅ | `approveRecovery` reaches the **2/3 approval threshold** | The threshold for recovery is met without the original key. (Owner change via `executeRecovery` after a 2-day timelock is **not** exercised — this run cancels instead.) |
| R3 | `0xcaca72b8ac29c6c52994159f85368120c7577de08d5fe02e1bd60a88289f23df` ✅ + `0xd6b16063a55feb543fdef89fd9282a0502ac07b57a208d3bce6ff5d4332f5078` ✅ | `cancelRecovery` (2 guardian votes) | Guardians can abort a recovery. Code requires a *guardian* (owner is rejected via `NotGuardian`) — that owner-rejection is a **code property**; no listed tx shows the owner being rejected. |

## ERC-7579 modules

| # | TX | Capability | User value |
|---|----|----|----|
| M1 | `0x6a6055d4111c4123486250705c3fb08b3b1c18ff37eefb1f908e0e09ee7932c0` ✅ | `installModule` (ForceExit, guardian-consented) | Extend the account (e.g. L2→L1 force-exit) safely |
| M2 | `0xf3add68d92f2dc20c931f187ec9a10e671737aece78ce8332b2fb9987f866003` ✅ | `uninstallModule` (2× guardian sig) | Remove a module only with guardian consent |

## ⭐ The beta.4 headline — guard-enabled account through a standard bundler

| # | TX | Capability | User value |
|---|----|----|----|
| **B1** | `0x48934dee021a7401d6196646dd07f023b3b18cd9a11aa110f4871971e3c74faf` ✅ | Self-paying UserOp on a **GUARD-ENABLED** account via the Pimlico bundler (from = bundler EOA `0x43370351c9a297bf8377ca1e46576401a9ac4bba`, to = EntryPoint, userOpHash `0xfd476168ed8a23728ab2931eb36844e5abfd990ee1b4d2bc8c0558443528c260`, block 11049352). Proves the **algId/whitelist validation gate + `executeUserOp` routing survive the bundler's split simulation** — the exact pre-beta.4 failure (`AlgorithmNotApproved(0)`). | **This was IMPOSSIBLE before beta.4.** A guard-protected account now transacts through any standard ERC-4337 bundler. NB: the cited tx moves **0 ETH**, so the daily-limit *accounting* through the bundler is not exercised here (covered by unit tests); and this tx is **self-paying** — gasless/paymaster sponsorship uses the same wrapped-callData path but is not separately tx-cited (the E2E gasless step was skipped: no sponsorship policy on the API key). |

---

## Not yet E2E-exercised on-chain (real in code, not proven by a listed tx)
1. **Session-key use** — scope/selector/velocity *enforcement at use* (only grant/revoke shown).
2. **P256/passkey signing** — a P256 session record is stored (fake point); no P256 signature is verified.
3. **Completed social recovery** — `executeRecovery` → owner change after the timelock (only the 2/3 approval threshold is reached, then cancelled).
4. **Owner rejected from `cancelRecovery`** — the "guardian-only" guarantee (a code property via `NotGuardian`).
5. **Guard enforcement through a bundler** — B1's bundler tx moves 0 ETH; over-limit rejection through a bundler is unit-tested, not in this E2E.
6. **EIP-7702 delegate flow** — `AirAccountDelegate` is deployed (D2) but the delegate→initialize→transact path is not E2E-exercised.

**Verification method:** Etherscan V2 API, per-account `txlist` + EntryPoint `UserOperationEvent` logs for the bundled op. Capability/value claims adversarially reviewed by Opus (overstatements corrected; "uncircumventable", "passkey owner", "biometrics", and "gasless" claims removed or qualified).
