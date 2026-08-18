# Deployment — v0.31.0 (Sepolia)

**Network:** Sepolia · **Date:** 2026-08-17 · **Blocks:** 11508815–11508825
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` · **EntryPoint:** v0.7
**Script:** `scripts/deploy-v0.31.0.ts` · **Enroll E2E:** `scripts/e2e-v0.31.0-enroll.ts` (6/6) · **Compiler:** 0.8.33, 200 runs, Cancun, via-IR

> **v0.31.0 = CC-102 weighted-governance hardening + CC-98 committee BLS.** Fresh non-upgradable stack,
> parallel to v0.29.0 (the v0.29.0 stack + validator `0x539B` stay live for old accounts). Accumulates
> **CC-102** (addGuardian ECDSA+P256 timelock twins, F-W6/8/9/11) + **CC-98** (committee BLS: accountId
> injection + `committeeActive` mode-gating + `requiredQuorum` mirror + `enrollInCommitteeValidator`).
> `ACCOUNT_VERSION` / `FACTORY_VERSION` `0.31.0`. **Committee mode ships OFF** (validator
> `committeeActive=false`) → accounts run LEGACY whole-set (2-of-3 over dvt's 3 nodes) until dvt flips.

## Deployed addresses (v0.31.0) — 7/7 Etherscan-verified

| 组件 | 地址 | 来源 / verified |
|---|---|---|
| **WebAuthnLib** (external library) | `0x9D95655CFE32b9EAe13CeCdFDCFffb6aa67cC7e7` | 新 · ✅ |
| **CommitteeBLSLib** (NEW external library, CC-98) | `0x002A050aeC1A3376DcCEf57397709D4A9Cd30F96` | 新 · ✅ |
| **Impl** (`AAStarAirAccountV7`, both libs linked) | `0x4873b7C1c07BE1b52d6583A64F5E902e593BDdad` | 新 · ✅ (`--libraries` ×2) |
| **Extension** (`AirAccountExtension`, WebAuthnLib-linked) | `0x79b90Ed6CB97ec48cfDA86399752C58Bbc59D90a` | 新 · ✅ (`--libraries` WebAuthnLib only) |
| **Factory** (`AAStarAirAccountFactoryV7`) | `0x25C1E9F9120a406581f93bA82f7Cfd6805512791` | 新 · ✅ |
| **Validator Router** (`AAStarValidator`) | `0xA15127e8601e77De7C655bf04ca75cccD8C968f0` | 新 · ✅ (0x01→committee, 0x08→session) |
| **AgentRegistry** | `0x37fc74EaeC81fEdD92876c8713405118Ebc0306e` | 新 · ✅ |
| **Committee Validator** (algId 0x01, CC-98, dvt #237) | `0x1A8Db639b5d8Bd5742edB083656EDD56f416cd64` | dvt 仓管 (3 节点, committeeActive=false) |
| SessionKeyValidator (0x08, reused v0.29.0) | `0x6b044fB27B4763Fd30D02e41EDF2c62af4Aa946f` | 复用 (prior) |
| ForceExitModule (reused v0.29.0) | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` | 复用 (prior) |
| Delegate (reused v0.29.0) | `0xd2735E54C5f5f2BF523b8a9ddd0E183624c3f2c0` | 复用 (prior) |
| CalldataParserRegistry (reused v0.29.0) | `0x7dEea4544446826601014bD94d0F6432A67496F5` | 复用 (prior) |

> **Canonical stack = 12 组件**: 7 新部署 + 1 dvt validator + 4 复用 v0.29.0。SDK canonical 升级请用整组。

## What's new vs v0.29.0

- **CommitteeBLSLib is a NEW external library** (CC-98, EIP-170 headroom). Like WebAuthnLib, the **impl**
  carries a `__$…$__` link reference for it. The deploy script (`linkBytecode`, fail-closed) deploys
  **WebAuthnLib + CommitteeBLSLib FIRST** and splices both addresses into the impl bytecode before deploy.
  **DEPLOY REQUIREMENT: never send raw `bytecode.object` — it ships a broken account.**
- **CC-98 committee BLS** — account reads `committeeActive()` to pick signature framing and mirrors the
  validator's `k >= requiredQuorum()` floor, injecting `accountId = address(this)` (B2 invariant, the
  submitter never supplies accountId). Legacy framing is byte-identical to pre-CC-98 when
  `committeeActive()==false`. One-time `enrollInCommitteeValidator()` (owner tx, after mount / before flip).
- **CC-102 weighted-governance hardening** — asymmetric `addGuardian` timelock with ECDSA+P256 twins
  (F-W6/8/9/11); no ABI break to signing paths.

## Verification recipe (`forge verify-contract`, 200 runs)

- **Impl** — `--constructor-args $(cast abi-encode "constructor(address)" 0xA15127e8601e77De7C655bf04ca75cccD8C968f0)`
  **and BOTH** `--libraries src/utils/WebAuthnLib.sol:WebAuthnLib:0x9D95655CFE32b9EAe13CeCdFDCFffb6aa67cC7e7`
  `--libraries src/utils/CommitteeBLSLib.sol:CommitteeBLSLib:0x002A050aeC1A3376DcCEf57397709D4A9Cd30F96`.
- **Extension** — `--libraries src/utils/WebAuthnLib.sol:WebAuthnLib:0x9D9565…` **only** (extension bytecode
  does not carry the CommitteeBLSLib link).
- **Factory** — needs `--rpc-url` for `--guess-constructor-args`.
- **Libs / Router / AgentRegistry** — no constructor args.

## Enroll E2E

- `scripts/e2e-v0.31.0-enroll.ts` **6/6** — test account `0xf249d5708cC3e1Dff42F5B36935FF270BeC403A0`
  created + enrolled (`enrolledAccount=true`, `committeeActive=false`, legacy whole-set path live).
- **Committee forward tier-2/3 E2E is NOT yet run** — gated on dvt's two-step flip (below) + SDK per-signer
  wire (CC-103 / PR #319, delivered). `v0.31.0` tag is held until that forward E2E passes on a
  non-upgradable stack.

## Migration interlock (committee mode ON)

Committee ships OFF. To turn it on (CC-104, Option B):

1. Account created + `enrollInCommitteeValidator()` called (**done** for the test account). Enrolling AFTER
   the flip on an un-enrolled account would brick it — enroll first.
2. dvt does **both**: `setEpochLength(N≠0)` **and** `snapshotEpoch()` to pin `setRoot[e-1]`.
   `setEpochLength` alone makes `committeeActive()==true` but leaves `requiredQuorum()` at the fail-closed
   sentinel (`type(uint256).max`) → the account rejects every committee signature. Both steps are required.
3. dvt starts the keeper (#238, `--watch`).

> First-round committee forward E2E runs at **N=3** (degenerate whole-set 2-of-3) — there is **no
> account-side N0 gate**; the account only reads `committeeActive()` + `requiredQuorum()`. Sampling
> (`m_e < N`, floor 30) only engages at N>30 and is a GA concern, not an activation gate.

## Downstream (notify)

| 依赖方 | 换什么 |
|---|---|
| @repo:sdk | canonical Sepolia 全 12 组件(上表)。per-signer committee wire = CC-103 / PR #319. Committee framing 必须来自 `committeeActive()`,不能从 payload 形状猜。 |
| @repo:dvt | committee validator `0x1A8Db639` (algId 0x01). 翻转两步(setEpochLength + snapshotEpoch)+ keeper,见 CC-104。 |
| @repo:kms | 签名代码零改动(BLS preimage=`bytes(userOpHash)`,DST `…_POP_` 三方一致);#210/#211 已合主干。 |

> Old v0.29.0 stack + validator `0x539B` stay on-chain (non-upgradable), existing accounts unaffected;
> v0.31.0 for new accounts.
