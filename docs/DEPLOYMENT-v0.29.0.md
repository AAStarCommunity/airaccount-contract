# Deployment — v0.29.0 (Sepolia)

**Network:** Sepolia · **Date:** 2026-07-17 · **Blocks:** 11290425–11290434
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` · **EntryPoint:** v0.7
**Script:** `scripts/deploy-v0.29.0.ts` · **E2E:** `scripts/e2e-v0.29.0.ts` (31/31) · **Compiler:** 0.8.33, 200 runs, Cancun, via-IR

> **v0.29.0 = security hardening + WebAuthnLib externalization + native-ETH tiers.** Fresh non-upgradable
> stack. Accumulates #161 · #149 · #191 · #135 · #194 (H1/H2 + M2/M1/H3/H4) · #178. `ACCOUNT_VERSION` /
> `FACTORY_VERSION` `0.29.0`. Beta (external audit #29 dropped — free Codex pre-audit done instead).

## Deployed addresses (v0.29.0) — 6/6 Etherscan-verified

| 合约 | 地址 | verified |
|---|---|---|
| **WebAuthnLib** (#149 external library) | `0x5a4D38D417c4539bbCe7790FF4F5Be3888F2afE1` | ✅ |
| **Factory** (`AAStarAirAccountFactoryV7`) | `0x65C30aCA6305c16b69E0262C5c1b57A77E57EE4A` | ✅ |
| **Impl** (`AAStarAirAccountV7`, WebAuthnLib-linked) | `0xa7300eb5182f560FC7bEd5E99Fd9395084a15952` | ✅ (`--libraries`) |
| **Extension** (`AirAccountExtension`, WebAuthnLib-linked) | `0x00731f1c2f58e9ABDb50A5d01B0c288040355617` | ✅ (`--libraries`) |
| **Validator Router** (`AAStarValidator`) | `0x0D4D69BE6dEC7F74A804ceFa7733674ba11A8c23` | ✅ |
| **AgentRegistry** | `0x2AbCEF739C4592aF9f3395a8A2F79F1ba51E0003` | ✅ |
| DVT BLS Validator (algId 0x01, CC-10, DVT 仓) | `0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC` | (DVT 仓管) |
| SessionKeyValidator (0x08, reused v0.28.0) | `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` | ✅ (prior) |
| ForceExit / Delegate / ParserRegistry (reused) | `0x3fDe…` / `0xd273…` / `0x7dEe…` | (prior) |

## What's new vs v0.28.0

- **WebAuthnLib is a NEW external library** (#149). The impl + extension carry a link reference; the deploy
  script (`linkBytecode`, fail-closed) deploys WebAuthnLib FIRST and splices its address into the impl
  bytecode before deploy. **DEPLOY REQUIREMENT: never send raw `bytecode.object` — it ships a broken account.**
  Verified with `forge verify-contract … --libraries src/utils/WebAuthnLib.sol:WebAuthnLib:0x5a4D38…`.
- **#194 security fixes** (H1 withdrawDepositTo guard · H2 recovery P256 clear · M2 setP256Key bootstrap-only
  · M1 session owner-epoch · H3 Uniswap exactInput decode · H4 Railgun multi-element + guard fail-closed).
- **#161 native-ETH tiers in InitConfig** (breaking ABI — the tuple grows by `tier1Limit`/`tier2Limit`; SDKs
  must append them, 0/0 preserves prior behavior).

## Verification / E2E

- `scripts/e2e-v0.29.0.ts` **31/31** — T30 (bytecode-identity) is now **link-aware** (replaces the local
  WebAuthnLib placeholder with the deployed address before comparing) → confirms the deployed impl is
  byte-identical to the locally-compiled + linked artifact. T22–T25 exercise `isValidOwnerAuth` through the
  linked WebAuthnLib on-chain.
- All 6 fresh contracts verify at 200 runs against current `main` (no version pin — v0.29.0 IS main). Impl/
  extension pass `--libraries`.

## Downstream (notify)

| 依赖方 | 换什么 |
|---|---|
| @repo:sdk | canonical Sepolia: Factory `0x65C3…` / Router `0x0D4D…` / Impl `0xa730…`. **Breaking:** InitConfig +`tier1Limit`/`tier2Limit` (#161). |
| @repo:dvt / @repo:kms | new Extension (isValidOwnerAuth host) `0x00731f…`; DVT validator `0x539B` unchanged. Old v0.28.0 e2e_account still usable; re-mint via cc22 for a v0.29.0 account. |

> Old v0.28.0 stack stays on-chain (non-upgradable), existing accounts unaffected; v0.29.0 for new accounts.
