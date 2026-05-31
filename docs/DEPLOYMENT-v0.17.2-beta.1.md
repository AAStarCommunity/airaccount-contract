# AirAccount Deployment Guide — v0.17.2-beta.1 (2026)

> **Current release: tag `v0.17.2-beta.1`** (session-key unification + Codex 4-round adversarial review + David human review). Supersedes `v0.17.1`.
> This is a **pre-release beta** intended for testnet smoke + security audit handoff. Do NOT promote to `v0.17.2` final until smoke E2E passes on at least one testnet and the audit window has closed.
> This doc is the canonical, versioned record of **what gets deployed, in what order, how it is wired, and how to run it** on each chain. Keep one of these per release.

---

## 1. Version & Scope

### What changed vs `v0.17.1`

- **Session-key unification**: a single `SessionKeyValidator` replaces three previously-separate contracts:
  - `AgentSessionKeyValidator`
  - `AirAccountCompositeValidator` (the previous default factory validator)
  - `TierGuardHook` (the previous default factory hook)
  Both agent-session and human-session flows now go through one validator with one storage layout.
- **`grantSessionDirect` access tightened (Codex round 3 + 4)**: only the owner EOA (`msg.sender == owner`) can call `grantSessionDirect` on the validator. The previous off-chain-signature path is preserved via `grantSession(account, sessionKey, cfg, ownerSig)` for indirect/sponsored grants. The 5-arg shim (`grantSessionDirect(account, ...)` with an `account` parameter) is **removed** — only the owner-direct variant remains.
- **`AgentRegistry.bindFactory` is deployer-only (Codex round 3)**: the registry constructor records `msg.sender` as the deployer; only that address can call `bindFactory`. Once bound, the binding is immutable.
- **`AgentRegistry._markAccountValid` loud-fail (Codex round 3)**: if the factory cannot mark a newly-created account as valid (e.g. wrong factory bound), the call now **reverts** rather than silently no-oping. `createAccount` becomes atomic — either the account is registered or the deploy reverts.
- **`_ownerOf` reverts `NotAirAccount` (David PR #61 LOW #3)**: when called with an address that is not an AirAccount clone, `_ownerOf` reverts with a typed error instead of returning `address(0)` — eliminates a class of false-positive `owner == address(0)` checks.
- **ABI bundle regenerated**: `abi/AAStarAirAccountV7.full.json` (diamond-lite merge) re-run against the unified validator set. SDKs must consume the new bundle.
- **663 tests passing** (`forge test`).
- **Audit posture**: 4 rounds of Codex adversarial review + 1 round of David @fanhousanbu human review on PR #61. Findings tracked in `docs/security-review-v0.17.2-beta.1.md` (sibling agent).

### What did NOT change

- EntryPoint v0.7 target address.
- AirAccount V7 storage layout (the unification only re-points the **default** validator; existing accounts retain their on-account validator pointer).
- Diamond-lite split (`AirAccountExtension` as fallback target). EIP-170 headroom is preserved.
- Compiler: solc `0.8.33` / EVM Cancun / via-IR / optimizer 10000 runs.

---

## 2. Pre-flight Checklist

Run top-to-bottom before broadcasting. Code is frozen; everything here is execution + verification.

- [ ] **Branch + tip**: working tree is on `release/v0.17.2-beta.1` at tip `bd64457` or later.
- [ ] **Code frozen**: tag `v0.17.2-beta.1` exists; CI green on the merge commit.
- [ ] **Tests pass locally**: `forge test` — expect **663 passing**.
- [ ] **Compiler verified** (check `foundry.toml`): solc `0.8.33`, EVM `cancun`, `via_ir = true`, `optimizer_runs = 10000`.
- [ ] **RPC endpoints healthy**: `cast block-number --rpc-url $SEPOLIA_RPC_URL` returns a recent block. Repeat for each target network.
- [ ] **Deployer EOA funded**: `cast balance <deployer> --rpc-url $RPC` shows > 0.5 ETH on each target network.
- [ ] **Env vars set** in `.env.sepolia` and `.env.localhost`:
  - `PRIVATE_KEY` (testnet) or keystore alias (mainnet)
  - `SEPOLIA_RPC_URL` / `OP_SEPOLIA_RPC_URL` / `LOCALHOST_RPC_URL`
  - `COMMUNITY_GUARDIAN_ADDRESS`
  - `ETHERSCAN_API_KEY`
- [ ] **Leaked key rotated**: confirm `0xb5600060e6de5E11D3636731964218E53caadf0E` (the previously-leaked testnet key) is **not** the deployer. Use a fresh key. (memory note KI-12)
- [ ] **Sibling docs present** (produced by parallel agents — required before broadcast):
  - [ ] `docs/security-review-v0.17.2-beta.1.md`
  - [ ] `docs/contracts-inventory-v0.17.2-beta.1.md`
  - [ ] `script/DeployV0172Beta.s.sol`
- [ ] **ABI bundle rebuilt**: `node scripts/build-full-abi.mjs --check` exits 0. SDK PR is staged with the new `abi/AAStarAirAccountV7.full.json`.

---

## 3. External Address Dependencies

| Address | Sepolia | Localhost (Anvil) |
|---|---|---|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (canonical) | Deploy fresh, or fork-mainnet to inherit canonical |
| P256_VERIFIER (EIP-7212 precompile) | `0x0000000000000000000000000000000000000100` (precompile) | Deploy a P256 verifier contract; precompile is **not** available on stock Anvil |
| Community Guardian | TBD — set at deploy time via `COMMUNITY_GUARDIAN_ADDRESS` | TBD |
| ERC-8004 Identity (testnet) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | Deploy locally or skip |
| ERC-8004 Reputation (testnet) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | Deploy locally or skip |
| ERC-8004 Validation (testnet) | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` | Deploy locally or skip |

> Mainnet ERC-8004 addresses (when promoting to mainnet): see `src/config/ERC8004Addresses.sol`.

---

## 4. Deployment Order

Single broadcast via `script/DeployV0172Beta.s.sol` (Foundry; verified to compile + dry-run on Anvil). Full DAG depth = 3. **11 singleton contracts** deployed + **2 auto-deployed by the factory's constructor** (`AAStarAirAccountV7` impl, `AirAccountExtension`) + **4 wiring transactions**:

1. Deploy `AAStarBLSAlgorithm` — no deps.
2. Deploy `AAStarValidator` (router) — no deps.
3. **Wire**: `router.registerAlgorithm(0x01, blsAlgorithm)`.
4. Deploy `AAStarBLSAggregator(blsAlgorithm)` — depends on #1.
5. Deploy `SessionKeyValidator` — no deps; replaces `AgentSessionKeyValidator` + `AirAccountCompositeValidator` + `TierGuardHook` from v0.17.1.
6. **Wire**: `router.registerAlgorithm(0x08, sessionKeyValidator)`.
7. Deploy `ForceExitModule` — no deps.
8. Deploy `AirAccountDelegate` — no deps (EIP-7702 delegation target).
9. Deploy `CalldataParserRegistry` — no deps.
10. Deploy `RailgunParser` — no deps.
11. Deploy `UniswapV3Parser` — no deps.
12. Deploy `AAStarAirAccountFactoryV7(EntryPoint, communityGuardian, [], [])` — its constructor auto-deploys the `AAStarAirAccountV7` impl, which in turn auto-deploys `AirAccountExtension`.
13. Deploy `AgentRegistry()` — no constructor args; `msg.sender` is captured as the immutable `deployer`.
14. **Wire**: `agentRegistry.bindFactory(factory)` — **deployer-only**, **set-once**, immutable.
15. **Wire**: `factory.setAgentRegistry(agentRegistry)`.

**Algorithm IDs — what the script registers and what is inlined:**

| algId | Name | Where | Registered by script? |
|---|---|---|---|
| `0x01` | BLS | `AAStarBLSAlgorithm.sol` | **yes** (step 3) |
| `0x02` | ECDSA | inlined in `AAStarAirAccountBase._validateSignature` | no — handled inline |
| `0x03` | P256 | inlined in base (via EIP-7212 precompile at 0x100) | no — handled inline |
| `0x04` | Cumulative T2 (P256 + BLS) | inlined in base | no |
| `0x05` | Cumulative T3 (P256 + BLS + Guardian) | inlined in base | no |
| `0x06` | Combined T1 (P256 + ECDSA zero-trust) | inlined in base | no |
| `0x07` | Weighted (resolves to 0x02/0x04/0x05 at runtime) | inlined in base | no |
| `0x08` | SessionKey | `SessionKeyValidator.sol` | **yes** (step 6) |

`factory._buildDefaultConfig` whitelists all 8 algIds (`0x01`…`0x08`) — this is per-account `approvedAlgIds`, separate from the router.

**Wiring NOT performed by the script (deferred to operator):**

- `router.finalizeSetup()` — locks direct `registerAlgorithm`. **Decision: left UNLOCKED for beta.1** so additional algorithms can be added during the beta cycle without timelock. **MUST be called once before the final v0.17.2 GA tag.**
- Per-chain ERC-20 token default configs for the factory — `defaultTokens`/`defaultConfigs` passed empty in this script; if a chain wants stablecoin defaults baked into `createAccountWithDefaults`, factory must be redeployed on that chain with non-empty arrays.
- `parserRegistry.setParser(parser, selector)` — opt-in by account, not done at deploy.
- SuperPaymaster `setAgentRegistries(<AgentRegistry>)` — handed off out-of-band to SP team.
- Account-level wiring (done per account by SDK / owner at/after `createAccount`): `setValidator(router)`, `setAggregator(blsAggregator)`, `setP256Key(x, y)`, `setParserRegistry(parserRegistry)`.

> See `docs/contracts-inventory-v0.17.2-beta.1.md` for the same content cross-referenced + constructor argument resolution table.

---

## 5. Post-deploy Wiring

> 📋 **Full wiring sequence in `docs/contracts-inventory-v0.17.2-beta.1.md` (sibling agent)**. Critical sequence summarized here:

- **`agentRegistry.bindFactory(factory)`**: ONLY callable by the **deployer EOA** (the address that deployed `AgentRegistry`). Reverts `NotDeployer` from any other caller. Once bound, the binding is **immutable** — there is no `rebindFactory`. If you bind the wrong factory you must redeploy `AgentRegistry`.
- **`agentRegistry._markAccountValid(account)`**: invoked internally by the factory during `createAccount*`. ONLY callable by the **bound factory** (`msg.sender == boundFactory`). If the factory is not bound or wrong factory calls it, the registry **reverts** (Codex round 3 hardening — was previously silent no-op). `createAccount` therefore becomes atomic: either the account is created and registered, or the whole tx reverts.
- **Account-level wiring** (done by SDK / owner per account at/after `createAccount`): `setValidator(router)`, `setAggregator(blsAggregator)`, `setP256Key(x, y)` (passkey), `setParserRegistry(parserRegistry)` (if DeFi parsing wanted).
- **SuperPaymaster handoff** (SP repo side): hand the `AgentRegistry` address to the SP team → they call `setAgentRegistries(addr)` and run E2E G2.

---

## 6. Post-deploy Smoke Test (E2E)

Run against the deployed addresses. All must pass before promoting `-beta.1` to `v0.17.2` final.

- [ ] **Account deploy**: call `factory.createAccountWithDefaults(owner, salt, g1, g1Sig, g2, g2Sig, dailyLimit)` and confirm `code.length > 0` at the predicted CREATE2 address.
- [ ] **Session grant via owner sig** (`grantSession`): owner signs the session config off-chain; submit through `SessionKeyValidator.grantSession(account, sessionKey, cfg, ownerSig)`. Expect success.
- [ ] **Session grant via owner-direct** (`grantSessionDirect`): owner EOA directly calls `SessionKeyValidator.grantSessionDirect(sessionKey, cfg)` (no `account` arg — 5-arg shim removed). Expect success. From a non-owner EOA expect a revert (`NotOwner` or equivalent).
- [ ] **Session UserOp**: build a UserOp signed by the granted session key; submit to EntryPoint; expect `validateUserOp` returns 0 and the op executes.
- [ ] **Session revoke (kill-switch)**: from the **session key itself**, call `revokeSession` through `account.execute`. Confirm the next session UserOp reverts. (Kill-switch is retained as a Codex round 3 design decision.)
- [ ] **AgentRegistry — H-2 fix**: deploy an account via `Clones.clone(impl)` directly (NOT through the factory). Try to call `agentRegistry.registerAgent(...)` from that account. Expect revert `CallerNotAirAccount` (or the equivalent typed error).
- [ ] **AgentRegistry — bindFactory owner-only**: from a non-deployer EOA call `agentRegistry.bindFactory(<any addr>)`. Expect revert `NotDeployer`.
- [ ] **`_ownerOf` typed revert (David LOW #3)**: call `factory._ownerOf(0xdead...)` (or wherever `_ownerOf` is exposed) with a non-AirAccount address. Expect revert `NotAirAccount` — NOT `address(0)`.
- [ ] **Test scripts (where applicable)**: run any of the existing `scripts/test-e2e-*.ts` adapted to the new addresses (`test-m7-e2e.ts`, `test-v0171-diamond-e2e.ts` retargeted).

---

## 7. Etherscan Verification

### Forge auto-verify (preferred)

```bash
forge script script/DeployV0172Beta.s.sol \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvvv
```

### Manual fallback (per contract)

```bash
forge verify-contract <ADDRESS> src/path/Contract.sol:ContractName \
  --chain sepolia \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version 0.8.33 \
  --num-of-optimizations 10000 \
  --evm-version cancun \
  --via-ir
```

> If a contract has constructor args, append `--constructor-args $(cast abi-encode "constructor(...)" arg1 arg2 ...)`.

---

## 8. Deployed Address Record

_(fill in after a successful broadcast — TBD until deploy)_

| Contract | Sepolia | Localhost | Verified |
|---|---|---|---|
| SessionKeyValidator | TBD | TBD | ⬜ |
| AAStarBLSAlgorithm | TBD | TBD | ⬜ |
| AAStarValidator (router) | TBD | TBD | ⬜ |
| AgentRegistry | TBD | TBD | ⬜ |
| AirAccountV7 (impl) | TBD | TBD | ⬜ |
| AirAccountExtension | TBD | TBD | ⬜ |
| AAStarAirAccountFactoryV7 | TBD | TBD | ⬜ |
| CalldataParserRegistry | TBD | TBD | ⬜ |
| ForceExitModule | TBD | TBD | ⬜ |

> Update `.env.<network>` with these addresses after broadcast.

---

## 9. Rollback / Recovery

- **`bindFactory` mis-bound** (wrong factory bound, or deployer key compromised before bind): there is **no rebind path**. Redeploy `AgentRegistry` + `AAStarAirAccountFactoryV7` together, then bind. Update SDK + SuperPaymaster with the new registry address.
- **`_markAccountValid` reverts during `createAccount`**: this is now a **loud failure** (Codex round 3 fix — previously silent). The whole `createAccount` tx reverts atomically. Investigate why the registry isn't authorized for this factory (most likely cause: factory was upgraded but `bindFactory` was never called, or the factory address passed to the user differs from the bound factory).
- **Smoke E2E fails**: do NOT promote `-beta.1` to `v0.17.2` final. Tag a fresh `v0.17.2-beta.2` with the fix and rerun the full pre-flight + smoke flow.
- **Audit finds a HIGH issue after deploy but before promotion**: same as above — patch, tag `-beta.2`, redeploy, rerun smoke. `-beta.1` addresses become abandoned.

---

## 10. Security Review Reference

- **Sibling doc**: `docs/security-review-v0.17.2-beta.1.md` (produced by parallel agent; required reading before audit handoff).
- **Codex adversarial review history**: 4 rounds against PR #61 and PR #62. Round-by-round findings and remediations are summarized in the sibling security-review doc.
- **David @fanhousanbu human review**: PR #61 review comment [`#issuecomment-4582943083`](https://github.com/AAStarCommunity/airaccount-contract/pull/61#issuecomment-4582943083). Items addressed in this release:
  - LOW #3: `_ownerOf` reverts `NotAirAccount` for non-AirAccount addresses.
  - 5-arg `grantSessionDirect` shim removed.
- **Audit posture**: `-beta.1` is the **handoff** point for external audit. Do NOT promote to `v0.17.2` final until audit window closes with no new HIGH findings.
