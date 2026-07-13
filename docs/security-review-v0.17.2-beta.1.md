## Methodology

Reviewed release tip `bd64457` in `/Users/jason/Dev/aastar/airaccount-contract` with source-only inspection. Primary files reviewed deeply: `src/validators/AAStarValidator.sol`, `src/validators/AAStarBLSAlgorithm.sol`, `src/aggregator/AAStarBLSAggregator.sol`, `src/core/ForceExitModule.sol`, `src/core/AirAccountDelegate.sol`, `src/core/AirAccountExtension.sol`, `src/core/CalldataParserRegistry.sol`, `src/parsers/RailgunParser.sol`, `src/parsers/UniswapV3Parser.sol`, `src/config/ERC8004Addresses.sol`, and `src/core/AAStarGlobalGuard.sol`. Cross-contract call sites reviewed for exploitability: `src/core/AAStarAirAccountBase.sol`, `src/core/AAStarAirAccountV7.sol`, `src/core/AAStarAgentStorageLayout.sol`, and parser/BLS-related tests and release docs where needed.

Attack angles covered: external access control on every scoped external function; account-validator-aggregator-guard invariants; BLS aggregation, point/infinity handling, stale key revocation, and replay/binding; emergency ForceExit daily-limit behavior; EIP-7702 delegated execution tier checks; diamond-lite storage/transient slot sharing; parser try/catch fail-open behavior; ERC-8004 address pinning; token config and algorithm tier matrix coherence; reentrancy around account execution, executor execution, parser callbacks, and extension fallback.

Deliberately not re-reviewed deeply per instruction: `SessionKeyValidator`, `AgentRegistry`, factory account-creation internals, and the base `validateUserOp` flow except where needed for cross-contract invariants with the scoped contracts.

## Critical Findings

No Critical findings.

## High Findings

**[HIGH-1] Revoked or updated BLS keys remain valid through cached aggregate keys**
- File: src/validators/AAStarBLSAlgorithm.sol:156
- Attack scenario: An attacker compromises a registered BLS node key, then calls `cacheAggregatedKey([nodeId])` while the node is still registered. After the operator rotates or revokes that node through `updatePublicKey()` or `revokePublicKey()`, validation still returns the cached old aggregate key before checking `isRegistered`. The attacker can keep signing with the revoked old key and pass future BLS validations for cached node sets.
- Severity rationale: BLS key revocation is a core incident-response control. The current cache order makes revocation ineffective for any cached set, preserving a compromised signing factor indefinitely.
- Fix: Before returning a cached key, verify every `nodeId` is still registered and include a per-node key version in the cache key. Increment that version on update/revoke, or remove caching entirely until invalidation can be made sound. Relevant lines: cache-first return at src/validators/AAStarBLSAlgorithm.sol:156, public cache writes at src/validators/AAStarBLSAlgorithm.sol:176, key update without cache invalidation at src/validators/AAStarBLSAlgorithm.sol:374, and revoke without cache invalidation at src/validators/AAStarBLSAlgorithm.sol:384.

**[HIGH-2] Zero/infinity BLS signature and message point can bypass the BLS co-signing factor**
- File: src/validators/AAStarBLSAlgorithm.sol:102
- Attack scenario: An attacker with only the account owner ECDSA key creates a Tier-3 legacy BLS signature payload where `blsSignature` is the G2 point at infinity and `messagePoint` is also infinity, then signs `userOpHash` and the zero `messagePoint` with the owner key. The account-side owner checks pass, and the BLS algorithm performs only the pairing equation. Pairings involving infinity evaluate to the identity, so the BLS factor can be satisfied without any BLS node signature if the precompile accepts valid infinity encodings.
- Severity rationale: The design relies on BLS as an independent high-tier factor. Accepting identity points collapses that factor for legacy `ALG_BLS` Tier-3 transactions after owner-key compromise, which is exactly the threat tiered verification is meant to limit.
- Fix: Reject infinity/zero encodings for `signature`, `messagePoint`, and aggregated public keys before pairing. Validate registered public keys at registration/update for correct curve, subgroup, and non-infinity membership. Relevant code slices the signature and message point without nonzero checks at src/validators/AAStarBLSAlgorithm.sol:102 and performs the pairing check directly at src/validators/AAStarBLSAlgorithm.sol:324.

**[HIGH-3] Aggregator validation is not bound to the submitted UserOps**
- File: src/aggregator/AAStarBLSAggregator.sol:117
- Attack scenario: In aggregator mode, account validation checks owner signatures and then returns the aggregator address before verifying the BLS signature. The aggregator's per-UserOp hook only checks signature format, and `validateSignatures()` verifies the caller-supplied aggregate signature without recomputing or comparing it against the BLS signatures and message points embedded in `userOps`. A malicious bundler can include one valid aggregate for unrelated data while batching UserOps whose embedded BLS payloads were never included in the aggregate, bypassing the BLS factor for those UserOps.
- Severity rationale: ERC-4337 aggregators must make the aggregate signature attest to the exact UserOps in the batch. This breaks that binding and turns batch BLS verification into a reusable proof unrelated to part or all of the batch.
- Fix: In `validateSignatures()`, parse every `userOps[i].signature`, enforce identical node sets, G2-add each embedded BLS signature and message point, and verify that recomputed aggregate. Either ignore the supplied aggregate and recompute from `userOps`, or require byte-for-byte equality with the recomputed aggregate before pairing. Relevant account deferral is at src/core/AAStarAirAccountBase.sol:746, format-only per-op validation is at src/aggregator/AAStarBLSAggregator.sol:59, and batch validation ignores `userOps` contents at src/aggregator/AAStarBLSAggregator.sol:117.

**[HIGH-4] Uniswap parser fail-open paths bypass token tier checks**
- File: src/parsers/UniswapV3Parser.sol:103
- Attack scenario: A Tier-1 signer submits a real Uniswap V3 `exactInput((bytes,address,uint256,uint256,uint256))` call spending configured USDC above Tier 1. Because this function has a dynamic tuple, real calldata includes a top-level tuple offset; the parser reads `amount` from the deadline word and derives `token` from the recipient word instead of the path. The guard then checks an unconfigured bogus token or zero and does not enforce the USDC tier. Separately, `exactOutputSingle`, `exactOutput`, `multicall`, and other router selectors return `(address(0), 0)`, and the account catches parser failure/zero returns and proceeds.
- Severity rationale: The parser exists specifically to prevent `value=0` DeFi calls from bypassing token limits. Misdecoding one supported selector and failing open for common swap selectors allows large configured-token spends with Tier-1 authorization.
- Fix: Decode with the real SwapRouter ABI, including the single tuple wrapper for `exactInput`. Add `exactOutputSingle`, `exactOutput`, and `multicall` parsing or make registered parsers fail closed for unsupported selectors. The fail-open account path is at src/core/AAStarAirAccountBase.sol:1268, and the parser only handles two selectors at src/parsers/UniswapV3Parser.sol:56.

**[HIGH-5] Railgun parser only reads one fixed-offset item and can undercount shield/transact amounts**
- File: src/parsers/RailgunParser.sol:112
- Attack scenario: A Tier-1 signer submits Railgun calldata containing multiple shield requests or transactions. The parser assumes the "single-request" fixed offsets documented in the comments and returns only one `(token, amount)` pair. The attacker makes the first parsed item small enough for Tier 1 and places a larger same-token or different configured-token movement in later array elements. The guard records only the first amount while Railgun processes the full calldata.
- Severity rationale: This is a direct token-limit bypass in the privacy-pool path. The account's parser integration fails open on `(address(0), 0)` or parser revert, so malformed or multi-item calldata is not blocked by default.
- Fix: ABI-decode the Railgun arrays, require a supported exact shape, sum all spends per token, and fail closed when more than one configured token is present unless the guard can check multiple token/amount pairs. Relevant single-item assumptions are documented at src/parsers/RailgunParser.sol:41 and src/parsers/RailgunParser.sol:52, fixed-offset parsing occurs at src/parsers/RailgunParser.sol:112 and src/parsers/RailgunParser.sol:123, and the account fail-open path is at src/core/AAStarAirAccountBase.sol:1268.

## Medium Findings

**[MEDIUM-1] EIP-7702 delegate execution enforces ETH daily limits but no ERC20 token limits**
- File: src/core/AirAccountDelegate.sol:237
- Attack scenario: A delegated EOA uses `execute(token, 0, transfer(...))` or `execute(router, 0, swapCalldata)` to move ERC20 assets. The delegate only calls `AAStarGlobalGuard.checkTransaction(value, algId)`, which enforces ETH value and algorithm approval, not ERC20 transfer parsing or `checkTokenTransaction()`. Any ERC20 balance at the delegated EOA can move without AirAccount token tier/daily enforcement.
- Severity rationale: EIP-7702 already has the documented raw-key bypass risk, but this is an in-contract gap on the delegated execution path itself. Users can reasonably expect delegated `execute` to get the same token guard semantics as native AirAccount execution.
- Fix: Add ERC20 and parser-registry enforcement equivalent to `AAStarAirAccountBase._checkTokenGuard`, or document the 7702 delegate as ETH-only for guard purposes. The delegate guard call is at src/core/AirAccountDelegate.sol:246, and batch execution repeats the same ETH-only check at src/core/AirAccountDelegate.sol:272.

**[MEDIUM-2] Weighted signatures cannot satisfy configured token tier checks**
- File: src/core/AAStarAirAccountBase.sol:958
- Attack scenario: An account approves `ALG_WEIGHTED` and validates a weighted signature that resolves to Tier 2 or Tier 3. During token guard enforcement, the account intentionally passes the pre-resolution `guardAlgId` (`0x07`) into `checkTokenTransaction()`. The guard's `_algTier()` maps `0x07` to zero, so any configured-token spend requiring Tier 1+ reverts even though the weighted signature reached the intended tier.
- Severity rationale: This is not a theft path, but it breaks an advertised authorization mode for guarded token operations and can make configured DeFi/token flows unusable under weighted signatures.
- Fix: Split guard whitelist identity from tier identity. Pass the original algId to `checkTransaction()` for whitelist purposes, but pass the resolved algId to `checkTokenTransaction()`, or change the guard API to accept both. Relevant pre-resolution preservation is at src/core/AAStarAirAccountBase.sol:958, token guard forwarding is at src/core/AAStarAirAccountBase.sol:1098, and the guard maps weighted to zero at src/core/AAStarGlobalGuard.sol:275.

## Low Findings

**[LOW-1] BLS node sets allow duplicate node IDs**
- File: src/validators/AAStarBLSAlgorithm.sol:96
- Attack scenario: A caller supplies `[nodeA, nodeA, nodeA]` as the node set. The algorithm aggregates the same registered public key repeatedly and verifies against the corresponding repeated signature aggregation. Any off-chain or UI policy that treats `nodeIds.length` as a signer-count signal can be fooled into displaying a multi-node approval that actually came from one key.
- Severity rationale: The current contracts do not enforce a minimum unique-node threshold, so this is mostly a policy/accounting weakness unless consumers rely on node count. It becomes more serious if future releases use `nodeIds.length` for threshold semantics.
- Fix: Require sorted strictly increasing node IDs, reject duplicates, and expose "unique signer count" semantics explicitly. Parsing accepts arbitrary IDs at src/validators/AAStarBLSAlgorithm.sol:96 and aggregation does not deduplicate at src/validators/AAStarBLSAlgorithm.sol:165.

**[LOW-2] BLS public key registration is length-only**
- File: src/validators/AAStarBLSAlgorithm.sol:362
- Attack scenario: The BLS owner accidentally registers an invalid, wrong-subgroup, or infinity G1 public key. Later validation for node sets containing that key either reverts in precompiles, validates degenerate cases, or becomes dependent on precompile edge behavior rather than explicit contract invariants.
- Severity rationale: Only the BLS owner can register or update keys, so this is an operator-hardening issue rather than an external attacker path. It does increase blast radius of key-management mistakes.
- Fix: Validate public keys during `registerPublicKey()`, `batchRegisterPublicKeys()`, and `updatePublicKey()` using an explicit G1 validation routine and reject infinity. Current checks only enforce length at src/validators/AAStarBLSAlgorithm.sol:362, src/validators/AAStarBLSAlgorithm.sol:374, and src/validators/AAStarBLSAlgorithm.sol:403.

**[LOW-3] ForceExit proposals have no expiry**
- File: src/core/ForceExitModule.sol:130
- Attack scenario: An account proposes a force exit and one guardian approves. The proposal remains pending forever until cancellation or execution. If the owner key is lost and a second guardian later approves stale parameters, anyone can execute the old exit after an arbitrary delay.
- Severity rationale: Two guardian approvals are still required, and the owner/account can cancel while available, so this is mainly stale-intent risk. Emergency flows should minimize old authorizations that remain live indefinitely.
- Fix: Add an expiry window to `ExitProposal`, include it in `_proposalHash()`, and require `block.timestamp <= proposedAt + expiry` in `approveForceExit()` and `executeForceExit()`. Proposal creation is at src/core/ForceExitModule.sol:130, approval has no expiry check at src/core/ForceExitModule.sol:155, and execution has no expiry check at src/core/ForceExitModule.sol:190.

## Informational

**[INFO-1] Validator direct registration is owner-only but intentionally unlocked for beta**
- File: src/validators/AAStarValidator.sol:93
- Attack scenario: An external attacker cannot call `registerAlgorithm()` unless they control the router owner. During beta, however, the owner can add new algorithm IDs immediately because `setupComplete` is false until `finalizeSetup()` is called.
- Severity rationale: This matches the beta deployment note, but it leaves algorithm governance at hot-owner speed rather than seven-day timelock speed.
- Fix: Call `finalizeSetup()` before GA, transfer router ownership to the intended Safe before account onboarding, and monitor `AlgorithmRegistered`. Direct registration is controlled at src/validators/AAStarValidator.sol:93 and closed by src/validators/AAStarValidator.sol:105.

**[INFO-2] ForceExit Tier-1 daily-limit behavior matches the current code**
- File: src/core/ForceExitModule.sol:238
- Attack scenario: A guardian-approved force exit attempts to withdraw more ETH than the account's executor Tier-1/daily allowance. The module routes through `account.executeFromExecutor(bytes32,bytes)`, and the account enforces `_enforceGuard(..., ALG_ECDSA, ...)` before calling the bridge.
- Severity rationale: This is not a vulnerability; it confirms the documented KI-13 concern is implemented as "emergency exit is constrained by Tier-1 executor guard" rather than "guard bypass for emergency drain."
- Fix: If product requirements expect full-balance emergency exit, introduce an explicit higher-tier guardian-exit path with clear limits. Current bridge routing is at src/core/ForceExitModule.sol:238 and executor guard enforcement is at src/core/AAStarAirAccountV7.sol:359.

**[INFO-3] Diamond-lite extension storage layout is intentionally shared and no collision was found in reviewed functions**
- File: src/core/AirAccountExtension.sol:22
- Attack scenario: A fallback call delegatecalls into the extension. The extension inherits `AAStarAgentStorageLayout`, so touched persistent slots match the account layout. The extension's transient reentrancy guard uses slot 0, matching the account guard across the delegatecall boundary.
- Severity rationale: No collision was found in the reviewed extension functions. This remains a maintenance-sensitive invariant because any future storage field insertion before the shared layout would corrupt account state.
- Fix: Keep `AAStarAgentStorageLayout` first in both inheritance lists and gate future layout edits on storage-layout diff checks. Shared layout starts at src/core/AAStarAgentStorageLayout.sol:52, extension inheritance is at src/core/AirAccountExtension.sol:22, and shared transient slot use is at src/core/AirAccountExtension.sol:63.

**[INFO-4] ERC-8004 registry addresses are hard-coded and cannot be forged via user input**
- File: src/config/ERC8004Addresses.sol:19
- Attack scenario: An owner supplies a malicious identity or reputation registry to extension functions. The extension compares the supplied address to the chain-specific hard-coded official address and reverts on mismatch.
- Severity rationale: This is the intended immutable-address model. The residual risk is stale or incorrect constants on future ERC-8004 deployments, not caller forgery.
- Fix: Keep release checklists tied to upstream ERC-8004 address changes and document unsupported chains. Mainnet constants are at src/config/ERC8004Addresses.sol:19, testnet constants at src/config/ERC8004Addresses.sol:25, and extension enforcement at src/core/AirAccountExtension.sol:121.

**[INFO-5] GlobalGuard token configs are add-only and tier limits are immutable after add**
- File: src/core/AAStarGlobalGuard.sol:225
- Attack scenario: An external attacker attempts to loosen a configured token's tier/daily limits. Calls are restricted to the bound account, existing token configs cannot be replaced, and token daily limits can only decrease.
- Severity rationale: This invariant held in reviewed code. The main operational risk is that unconfigured tokens intentionally pass through with no limits.
- Fix: No immediate code fix for the monotonic invariant. Consider a future strict mode for unconfigured tokens if product expectations change. Add-only token config is at src/core/AAStarGlobalGuard.sol:225, daily-limit decrease-only logic at src/core/AAStarGlobalGuard.sol:237, and unconfigured-token pass-through at src/core/AAStarGlobalGuard.sol:181.

**Overall verdict: BLOCKED — must fix Critical/High before tag**

---

## Round 6 Verification

**Commit**: d4122a2 | **Date**: 2026-05-30 | **Reviewer**: Codex automated pass

### HIGH Findings

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| HIGH-1 | BLS cache invalidation | VERIFIED-CLOSED ✅ | `cachedAggKeys` is removed; storage now has only `registeredKeys`/`isRegistered`/`registeredNodes` at `src/validators/AAStarBLSAlgorithm.sol:13`. Removal rationale is documented at `src/validators/AAStarBLSAlgorithm.sol:22`; `cacheAggregatedKey()` always reverts `CacheDeprecated` at `src/validators/AAStarBLSAlgorithm.sol:195`; `_aggregateNodeKeys()` recomputes from registered storage at `src/validators/AAStarBLSAlgorithm.sol:176`; `aggregateKeys()` recomputes on-demand at `src/validators/AAStarBLSAlgorithm.sol:490`. No stale aggregate return path remains. |
| HIGH-2 | BLS infinity bypass | NOT-CLOSED ❌ | Standalone checks exist for signature/message point at `src/validators/AAStarBLSAlgorithm.sol:118`, `src/validators/AAStarBLSAlgorithm.sol:137`, and `src/validators/AAStarBLSAlgorithm.sol:151`; G1/G2 helpers exist at `src/validators/AAStarBLSAlgorithm.sol:208` and `src/validators/AAStarBLSAlgorithm.sol:226`; register/update reject infinity at `src/validators/AAStarBLSAlgorithm.sol:403`, `src/validators/AAStarBLSAlgorithm.sol:415`, and `src/validators/AAStarBLSAlgorithm.sol:451`. However `validate()` returns `1` instead of throwing `BLSPointAtInfinity` at `src/validators/AAStarBLSAlgorithm.sol:118`, aggregator recompute throws `AggregatedSignatureInvalid` instead at `src/aggregator/AAStarBLSAggregator.sol:147`, and `_extractBLSData()` does not reject each UserOp's BLS signature/message point before `_g2Add` at `src/aggregator/AAStarBLSAggregator.sol:190`, so an infinity UserOp can be hidden in a multi-op aggregate with another valid same-node UserOp. Aggregated public key infinity is also not checked after `aggregateKeys()` at `src/aggregator/AAStarBLSAggregator.sol:152` or after `_aggregateNodeKeys()` at `src/validators/AAStarBLSAlgorithm.sol:164`. Explicit curve/subgroup checks are still not present beyond relying on EIP-2537 precompile failure. |
| HIGH-3 | Aggregator unbound | VERIFIED-CLOSED ✅ | `validateSignatures(userOps, signature)` ignores the caller-supplied `signature` parameter at `src/aggregator/AAStarBLSAggregator.sol:122`; it recomputes from `userOps[0].signature` at `src/aggregator/AAStarBLSAggregator.sol:128`, rebuilds aggregate sig/message via `_g2Add` at `src/aggregator/AAStarBLSAggregator.sol:143`, enforces same node set at `src/aggregator/AAStarBLSAggregator.sol:136`, and verifies the recomputed aggregate at `src/aggregator/AAStarBLSAggregator.sol:158`. `_verifyPairing` now takes memory bytes and uses MCOPY at `src/aggregator/AAStarBLSAggregator.sol:283`. Malicious supplied aggregate substitution is closed; HIGH-2 residual infinity handling remains separate. |
| HIGH-4 | RailgunParser fail-open | VERIFIED-CLOSED ✅ | Beta deploy script does not deploy the parser: deployment lines are commented at `script/DeployV0172Beta.s.sol:163` and `_d.railgunParser` is set to `address(0)` at `script/DeployV0172Beta.s.sol:167`. No default wiring is performed in `wireAll()` at `script/DeployV0172Beta.s.sol:219`. KI-14 accurately states this at `docs/known-issues.md:452`. Opt-in remains possible through account `setParserRegistry()` at `src/core/AAStarAirAccountBase.sol:348` plus registry `registerParser()` at `src/core/CalldataParserRegistry.sol:50`; note the actual function is `registerParser`, not `setParser`. |
| HIGH-5 | UniswapV3Parser fail-open | VERIFIED-CLOSED ✅ | Beta deploy script does not deploy the parser: deployment lines are commented at `script/DeployV0172Beta.s.sol:163` and `_d.uniswapV3Parser` is set to `address(0)` at `script/DeployV0172Beta.s.sol:168`. Console output reports both parsers skipped at `script/DeployV0172Beta.s.sol:169`. KI-14 correctly describes parser-disable risk and mitigation at `docs/known-issues.md:437`. |

### MEDIUM Findings

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| MEDIUM-1 | 7702 delegate ERC20 | VERIFIED-CLOSED ✅ | Delegate defines raw ERC20 selectors at `src/core/AirAccountDelegate.sol:233`; `execute()` calls `checkTransaction` and `_checkTokenGuard` at `src/core/AirAccountDelegate.sol:257`; `executeBatch()` does the same per call at `src/core/AirAccountDelegate.sol:284`. `_checkTokenGuard` requires `data.length >= 68` at `src/core/AirAccountDelegate.sol:300`, checks `transfer`/`approve` at `src/core/AirAccountDelegate.sol:302`, and decodes amount from `data[36:68]` at `src/core/AirAccountDelegate.sol:303`. Non-ERC20/DeFi delegate calls still have no parser coverage; this is documented as KI-15 at `docs/known-issues.md:479`. |
| MEDIUM-2 | Weighted-sig token tier | VERIFIED-CLOSED ✅ | `execute()`/`executeBatch()` preserve pre-resolution `guardAlgId` at `src/core/AAStarAirAccountBase.sol:958` and `src/core/AAStarAirAccountBase.sol:986`, then resolve weighted algId at `src/core/AAStarAirAccountBase.sol:960` and `src/core/AAStarAirAccountBase.sol:988`. Guard whitelist still receives `guardAlgId` at `src/core/AAStarAirAccountBase.sol:1093`; token guard now receives resolved `algId` at `src/core/AAStarAirAccountBase.sol:1104`. `_resolveWeightedAlgId()` maps weight to tier representative algIds at `src/core/AAStarAirAccountBase.sol:1497`, so weighted Tier 2/3 token tier checks can succeed. |

### New Findings (Regressions / New Attack Surface)

HIGH: residual HIGH-2 aggregator path remains exploitable for multi-op batches because per-UserOp infinity BLS signature/message points are not rejected before aggregation (`src/aggregator/AAStarBLSAggregator.sol:190`, `src/aggregator/AAStarBLSAggregator.sol:143`). No material new gas-griefing issue identified from cache removal; aggregation is on-demand and bounded by submitted node count, but gas cost increases versus cached sets.

### Test Coverage Gaps

ADD-TEST: HIGH-2 — no `BLSPointAtInfinity` assertion found under `test/`; source checks need tests for standalone validate, register/update, aggregate public key infinity, and aggregator per-UserOp infinity.

ADD-TEST: HIGH-4/HIGH-5 — no deploy-script integrity test found proving `DeployV0172Beta` leaves parser addresses zero.

ADD-TEST: MEDIUM-1 — `test/AirAccountDelegate.t.sol:318` covers generic `executeBatch`, but no delegate ERC20 selector/token-tier test was found.

ADD-TEST: MEDIUM-2 — `test/WeightedSignature.t.sol:416` covers weighted ETH tier resolution, but no configured-token weighted path test was found.

Covered: HIGH-1 has `CacheDeprecated` assertions at `test/AAStarBLSAlgorithm_M3.t.sol:61`; HIGH-3 has caller-supplied aggregate ignored coverage starting at `test/AAStarBLSAggregator.t.sol:153`, though it is mostly malformed-input coverage.

### Round 6 Verdict

**Overall verdict: BLOCKED — must fix HIGH-2 aggregator per-UserOp infinity / aggregate-public-key infinity before tag**

## Round 7 Verification

| Finding | Round 6 | Round 7 | Notes |
|---------|---------|---------|-------|
| HIGH-1 BLS cache invalidation | VERIFIED-CLOSED | VERIFIED-CLOSED | Still closed: `cachedAggKeys` storage is absent from the storage block, leaving `registeredKeys` / `isRegistered` / `registeredNodes` at `src/validators/AAStarBLSAlgorithm.sol:13`; `cacheAggregatedKey()` always reverts `CacheDeprecated` at `src/validators/AAStarBLSAlgorithm.sol:195`; `aggregateKeys()` recomputes from registered storage at `src/validators/AAStarBLSAlgorithm.sol:490`. |
| HIGH-2 BLS infinity bypass, single-path and aggregator residual | BLOCKED | VERIFIED-CLOSED | Standalone BLS validation still rejects G2 infinity by returning failure at `src/validators/AAStarBLSAlgorithm.sol:118` and `src/validators/AAStarBLSAlgorithm.sol:119`, aggregate API paths revert at `src/validators/AAStarBLSAlgorithm.sol:137`, `src/validators/AAStarBLSAlgorithm.sol:138`, `src/validators/AAStarBLSAlgorithm.sol:151`, and `src/validators/AAStarBLSAlgorithm.sol:152`, and G1 infinity public keys are rejected at `src/validators/AAStarBLSAlgorithm.sol:403`, `src/validators/AAStarBLSAlgorithm.sol:415`, and `src/validators/AAStarBLSAlgorithm.sol:451`. The Round 6 residual is now closed: `userOps[0]` checks both `aggSig` and `aggMsgPt` at `src/aggregator/AAStarBLSAggregator.sol:140` and `src/aggregator/AAStarBLSAggregator.sol:141`; each looped `userOps[i>=1]` checks both `blsSig` and `msgPt` before `_g2Add` at `src/aggregator/AAStarBLSAggregator.sol:155` and `src/aggregator/AAStarBLSAggregator.sol:156`; empty batches revert before indexing at `src/aggregator/AAStarBLSAggregator.sol:126`; single-UserOp batches still hit the `userOps[0]` checks and the final aggregate checks at `src/aggregator/AAStarBLSAggregator.sol:140` and `src/aggregator/AAStarBLSAggregator.sol:164`. |
| ADD-TEST HIGH-2 infinity-input tests | ADD-TEST | VERIFIED-CLOSED | Three selector-specific tests exist: loop-side infinity `blsSig` at `test/AAStarBLSAggregator.t.sol:203`, loop-side infinity `msgPt` at `test/AAStarBLSAggregator.t.sol:216`, and `userOps[0]` infinity at `test/AAStarBLSAggregator.t.sol:228`; all expect `AAStarBLSAggregator.AggregatedSignatureInvalid.selector` at `test/AAStarBLSAggregator.t.sol:212`, `test/AAStarBLSAggregator.t.sol:224`, and `test/AAStarBLSAggregator.t.sol:235`. `_buildTripleSig()` constructs the 706-byte post-prefix body documented at `test/AAStarBLSAggregator.t.sol:256`, uses all-zero 256-byte G2 points when toggled at `test/AAStarBLSAggregator.t.sol:261` and `test/AAStarBLSAggregator.t.sol:262`, and prefixes `0x01` in the tests at `test/AAStarBLSAggregator.t.sol:209`, `test/AAStarBLSAggregator.t.sol:210`, `test/AAStarBLSAggregator.t.sol:221`, `test/AAStarBLSAggregator.t.sol:222`, and `test/AAStarBLSAggregator.t.sol:233`. |
| HIGH-3 aggregator binding to submitted UserOps | VERIFIED-CLOSED | VERIFIED-CLOSED | Still closed: the external `signature` argument remains ignored at `src/aggregator/AAStarBLSAggregator.sol:122`; the aggregate is recomputed from `userOps[0].signature` at `src/aggregator/AAStarBLSAggregator.sol:128`; looped UserOps are extracted and node-set checked at `src/aggregator/AAStarBLSAggregator.sol:143`; the recomputed aggregate is what reaches pairing at `src/aggregator/AAStarBLSAggregator.sol:173`. |
| HIGH-4 / HIGH-5 parser fail-open | VERIFIED-CLOSED | VERIFIED-CLOSED | Still closed for beta.1 default deployment: `DeployV0172Beta` documents parser disablement at `script/DeployV0172Beta.s.sol:159`, sets both parser addresses to zero at `script/DeployV0172Beta.s.sol:167` and `script/DeployV0172Beta.s.sol:168`, and the known-issues mitigation records no default parser deployment at `docs/known-issues.md:452`. |
| MEDIUM-1 delegate ERC20 guard source fix | VERIFIED-CLOSED | VERIFIED-CLOSED | Source remains closed: delegate `execute()` calls both `checkTransaction` and `_checkTokenGuard` at `src/core/AirAccountDelegate.sol:257`; `executeBatch()` does the same per call at `src/core/AirAccountDelegate.sol:284`; `_checkTokenGuard()` only parses `transfer` / `approve` selectors and forwards amount to `checkTokenTransaction` at `src/core/AirAccountDelegate.sol:299`; unconfigured tokens intentionally pass in the guard at `src/core/AAStarGlobalGuard.sol:181`. |
| ADD-TEST MEDIUM-1 delegate ERC20 tests | ADD-TEST | NEEDS-ACTION | Four tests exist at `test/AirAccountDelegate.t.sol:325`, `test/AirAccountDelegate.t.sol:338`, `test/AirAccountDelegate.t.sol:360`, and `test/AirAccountDelegate.t.sol:381`, but two revert assertions use bare `vm.expectRevert()` at `test/AirAccountDelegate.t.sol:356` and `test/AirAccountDelegate.t.sol:377`, and the non-ERC20 skip test uses an unconfigured target at `test/AirAccountDelegate.t.sol:384`, which would still pass if the unconfigured-token guard path ran because unconfigured tokens return true at `src/core/AAStarGlobalGuard.sol:181`. |
| MEDIUM-2 weighted-sig token tier | VERIFIED-CLOSED | VERIFIED-CLOSED | Still closed: `execute()` preserves `guardAlgId` and resolves weighted tier at `src/core/AAStarAirAccountBase.sol:957`; `executeBatch()` does the same at `src/core/AAStarAirAccountBase.sol:985`; the guard whitelist receives pre-resolution `guardAlgId` at `src/core/AAStarAirAccountBase.sol:1093`, while token tier checks receive resolved `algId` at `src/core/AAStarAirAccountBase.sol:1104`; `_resolveWeightedAlgId()` maps weight to tier representative algIds at `src/core/AAStarAirAccountBase.sol:1497`. |
| New attack surface from per-UserOp checks | N/A | VERIFIED-CLOSED | No new bypass found. Infinity inputs now cause deterministic cheap reverts before `G2Add` on both the first UserOp and looped UserOps at `src/aggregator/AAStarBLSAggregator.sol:140` and `src/aggregator/AAStarBLSAggregator.sol:155`; valid non-infinity single-UserOp flow continues past the initial checks to `aggregateKeys()` and pairing at `src/aggregator/AAStarBLSAggregator.sol:168` and `src/aggregator/AAStarBLSAggregator.sol:173`. |

### Test Quality Assessment

test_validateSignatures_perUserOpInfinityBlsSig_reverts | SOUND | Uses two well-formed prefixed signatures at `test/AAStarBLSAggregator.t.sol:209` and `test/AAStarBLSAggregator.t.sol:210`, then expects `AggregatedSignatureInvalid.selector` at `test/AAStarBLSAggregator.t.sol:212`; the revert occurs before `_g2Add` because the loop-side `blsSig` is checked at `src/aggregator/AAStarBLSAggregator.sol:155`.
test_validateSignatures_perUserOpInfinityMsgPt_reverts | SOUND | Uses matching node sets and an infinity loop-side `msgPt` at `test/AAStarBLSAggregator.t.sol:217` and `test/AAStarBLSAggregator.t.sol:218`, then expects `AggregatedSignatureInvalid.selector` at `test/AAStarBLSAggregator.t.sol:224`; the checked path is before `_g2Add` at `src/aggregator/AAStarBLSAggregator.sol:156`.
test_validateSignatures_userOpZeroInfinityBlsSig_reverts | SOUND | Covers `userOps[0]` with an infinity `blsSig` at `test/AAStarBLSAggregator.t.sol:230` and selector-specific revert at `test/AAStarBLSAggregator.t.sol:235`; this maps directly to the first-UserOp check at `src/aggregator/AAStarBLSAggregator.sol:140`.
test_execute_erc20Transfer_unconfiguredToken_passes | WEAK | The pass is compatible with the intended unconfigured-token rule at `src/core/AAStarGlobalGuard.sol:181`, but the test would also pass if `_checkTokenGuard()` were skipped entirely because the target has no code and no token config at `test/AirAccountDelegate.t.sol:327` and execution is only asserted by no revert at `test/AirAccountDelegate.t.sol:335`.
test_execute_erc20Transfer_aboveTier1_reverts | ADD-PRECISE-SELECTOR | It configures tier1=100 and transfers 200 at `test/AirAccountDelegate.t.sol:345` and `test/AirAccountDelegate.t.sol:351`, but bare `vm.expectRevert()` at `test/AirAccountDelegate.t.sol:356` could mask a different revert than `AAStarGlobalGuard.InsufficientTokenTier`, which is the intended guard error at `src/core/AAStarGlobalGuard.sol:202`.
test_execute_erc20Approve_aboveTier1_reverts | ADD-PRECISE-SELECTOR | It configures tier1=100 and approves 500 at `test/AirAccountDelegate.t.sol:366` and `test/AirAccountDelegate.t.sol:372`, but bare `vm.expectRevert()` at `test/AirAccountDelegate.t.sol:377` should be replaced with an `InsufficientTokenTier` selector+args expectation for the guard branch at `src/core/AAStarGlobalGuard.sol:202`.
test_execute_nonERC20_calldata_skipsTokenGuard | WEAK | The random selector is present at `test/AirAccountDelegate.t.sol:386`, but the target is unconfigured at `test/AirAccountDelegate.t.sol:384`, so an accidental guard call would still pass through `src/core/AAStarGlobalGuard.sol:181`; configure the target with restrictive token limits to prove selector skip.

### Open Issues

1. `test/AirAccountDelegate.t.sol:356` and `test/AirAccountDelegate.t.sol:377` — replace bare `vm.expectRevert()` with `vm.expectRevert(abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, 2, 1))` so transfer/approve tests prove the exact guard error from `src/core/AAStarGlobalGuard.sol:202`.
2. `test/AirAccountDelegate.t.sol:381` — configure `target` with a restrictive `TokenConfig` before sending random-selector calldata, so the test fails if `_checkTokenGuard()` at `src/core/AirAccountDelegate.sol:299` accidentally routes non-ERC20 selectors into `checkTokenTransaction`.

**Overall verdict: BLOCKED — ADD-PRECISE-SELECTOR and weak non-ERC20 delegate guard test**

## Round 8 Final Verification

**Commit**: 0fc486d | **Scope**: test-only verification follow-up

| Finding | Round 8 Status | Evidence |
|---------|----------------|----------|
| HIGH-1 BLS cache invalidation | VERIFIED-CLOSED | No source changes in 0fc486d; Round 7 closure remains intact. |
| HIGH-2 BLS infinity bypass | VERIFIED-CLOSED | No source changes in 0fc486d; Round 7 closure remains intact for standalone, first-UserOp, and looped-UserOp infinity paths. |
| ADD-TEST HIGH-2 infinity-input tests | VERIFIED-CLOSED | No test regression observed in this review; existing selector-specific infinity tests remain the Round 7 closure evidence. |
| HIGH-3 aggregator binding to submitted UserOps | VERIFIED-CLOSED | No source changes in 0fc486d; aggregate recomputation from submitted UserOps remains the verified closure. |
| HIGH-4 RailgunParser fail-open default deployment | VERIFIED-CLOSED | No source or deployment-script changes in 0fc486d; beta default parser disablement remains the verified closure. |
| HIGH-5 UniswapV3Parser fail-open default deployment | VERIFIED-CLOSED | No source or deployment-script changes in 0fc486d; beta default parser disablement remains the verified closure. |
| MEDIUM-1 delegate ERC20 guard source fix | VERIFIED-CLOSED | No source changes in 0fc486d; delegate still gates only ERC20 `transfer`/`approve` selectors through `_checkTokenGuard`. |
| ADD-TEST MEDIUM-1 delegate ERC20 tests | VERIFIED-CLOSED | `test_execute_erc20Transfer_aboveTier1_reverts` and `test_execute_erc20Approve_aboveTier1_reverts` now expect `abi.encodeWithSelector(AAStarGlobalGuard.InsufficientTokenTier.selector, uint8(2), uint8(1))`. The arguments match the actual path: direct EOA execution uses ECDSA tier 1, tier1 is 100, cumulative token spend is 200/500, so required tier is 2 and provided tier is 1. `test_execute_nonERC20_calldata_skipsTokenGuard` now configures the non-ERC20 target with tier1=1; if selector filtering accidentally routed `0x12345678` into `_checkTokenGuard`, decoded amount 1,000,000 would exceed tier1 and revert. Correct filtering skips token guard and execution completes. |
| MEDIUM-2 weighted-sig token tier | VERIFIED-CLOSED | No source changes in 0fc486d; resolved algId continues to be used for token tier checks while guard whitelist uses pre-resolution algId. |

LOW-1 duplicate BLS node IDs, LOW-3 ForceExit proposal expiry, and INFO-1 through INFO-5 remain explicit deferrals and are not blockers for this beta tag. LOW-2 was previously addressed for infinity G1 keys and does not change the release verdict.

0fc486d changes only `test/AirAccountDelegate.t.sol`, so it does not affect the Round 5/6 verified-closed source fixes.

**Overall verdict: SHIP-READY for v0.17.2-beta.1 tag**
