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
