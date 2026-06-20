<!-- GENERATED FILE — DO NOT EDIT BY HAND.
     Regenerate with `pnpm gen:abi-docs` (scripts/gen-abi-docs.mjs).
     Source of truth: out/ compiled ABIs + NatSpec. Hand edits will be overwritten. -->

# AirAccount — Generated ABI Reference

Authoritative, auto-generated reference for every external/public function, event, and error across the AirAccount `src/` contracts. Generated from compiled `out/` artifacts (ABI + solc selectors + NatSpec). See [`README.md`](./README.md) for how this is produced and [`capabilities.md`](./capabilities.md) for a capability-grouped map.

> **Access control** is scraped best-effort from Solidity source modifiers (`onlyOwner`, `onlyEntryPoint`, …); `—` means no recognised access modifier was found on the declaration (it may still be guarded inside the body — verify against source).

## Contracts

- [ERC8004Addresses](#erc8004addresses) — `src/config/ERC8004Addresses.sol`
- [AAStarAgentStorageLayout](#aastaragentstoragelayout) — `src/core/AAStarAgentStorageLayout.sol`
- [AAStarAirAccountBase](#aastarairaccountbase) — `src/core/AAStarAirAccountBase.sol`
- [IBLSAggregatorSource](#iblsaggregatorsource) — `src/core/AAStarAirAccountBase.sol`
- [AAStarAirAccountV7](#aastarairaccountv7) — `src/core/AAStarAirAccountV7.sol`
- [AAStarGlobalGuard](#aastarglobalguard) — `src/core/AAStarGlobalGuard.sol`
- [AirAccountExtension](#airaccountextension) — `src/core/AirAccountExtension.sol`
- [IAAStarAlgorithm](#iaastaralgorithm) — `src/interfaces/IAAStarAlgorithm.sol`
- [IAAStarValidator](#iaastarvalidator) — `src/interfaces/IAAStarValidator.sol`
- [IAirAccountAgent](#iairaccountagent) — `src/interfaces/IAirAccountAgent.sol`
- [ICalldataParser](#icalldataparser) — `src/interfaces/ICalldataParser.sol`
- [ICalldataParserRegistry](#icalldataparserregistry) — `src/interfaces/ICalldataParser.sol`
- [IERC8004IdentityRegistry](#ierc8004identityregistry) — `src/interfaces/IERC8004IdentityRegistry.sol`
- [IERC8004ReputationRegistry](#ierc8004reputationregistry) — `src/interfaces/IERC8004ReputationRegistry.sol`
- [AlgTierLib](#algtierlib) — `src/utils/AlgTierLib.sol`

## ERC8004Addresses

- **Source:** `src/config/ERC8004Addresses.sol`
- **Functions:** 0 · **Events:** 0 · **Errors:** 1
- **Title:** ERC8004Addresses — Official ERC-8004 "Trustless Agents" contract addresses
- All contracts are deployed at deterministic addresses via CREATE2 (SAFE Singleton Factory).         Mainnet and testnet each share a single address across all supported EVM chains.         Supported mainnet chains (chain IDs): 1, 10, 137, 8453, 42161, 43114, 56, 534352, ...         Supported testnet chains (chain IDs): 11155111, 11155420, 84532, 421614, 80002, ...         Source: https://github.com/erc-8004/erc-8004-contracts (scripts/addresses.ts)

### Errors

| selector | error |
|---|---|
| `0xc3a55c98` | `UnsupportedChain(uint256)` |

## AAStarAgentStorageLayout

- **Source:** `src/core/AAStarAgentStorageLayout.sol`
- **Functions:** 13 · **Events:** 1 · **Errors:** 2
- **Title:** AAStarAgentStorageLayout
- Shared persistent-storage layout for AAStarAirAccountBase and AirAccountExtension.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xb5cb7bb8` | `activeRecovery()` | view | — | Active recovery proposal |
| `0x8450a928` | `approvedAlgorithms(uint8)` | view | — | Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4). |
| `0xb0d691fe` | `entryPoint()` | view | — | The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility) |
| `0x7ceab3b1` | `guard()` | view | — | Global guard for spending limits (set at construction, cannot be removed) |
| `0x8da5cb5b` | `owner()` | view | — | Account owner and ECDSA signer (mutable for social recovery) |
| `0x863ee512` | `p256KeyX()` | view | — | P256 public key x-coordinate |
| `0xc4bb0566` | `p256KeyY()` | view | — | P256 public key y-coordinate |
| `0x56dc31d0` | `parserRegistry()` | view | — | Optional calldata parser registry for DeFi protocol support (address(0) = disabled) |
| `0x7bea8f76` | `pendingWeightChange()` | view | — | Pending weight-change proposal (M6.2). proposedAt == 0 means none pending. |
| `0x8efdc881` | `tier1Limit()` | view | — | Tier1 max (ECDSA only) |
| `0xdbaf0cc3` | `tier2Limit()` | view | — | Tier2 max (dual factor); above this requires multi-sig (BLS triple) |
| `0x3a5381b5` | `validator()` | view | — | Optional validator router for external algorithms (BLS, PQ, etc.) |
| `0x085aa197` | `weightConfig()` | view | — | Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails. |

### Functions

#### `activeRecovery()`

`0xb5cb7bb8` · view · access: —

> Active recovery proposal

| returns | type | description |
|---|---|---|
| `newOwner` | `address` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |
| `cancellationBitmap` | `uint256` |  |

#### `approvedAlgorithms(uint8 arg0)`

`0x8450a928` · view · access: —

> Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4).

| param | type | description |
|---|---|---|
| `arg0` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `guard()`

`0x7ceab3b1` · view · access: —

> Global guard for spending limits (set at construction, cannot be removed)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

> Account owner and ECDSA signer (mutable for social recovery)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `p256KeyX()`

`0x863ee512` · view · access: —

> P256 public key x-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `p256KeyY()`

`0xc4bb0566` · view · access: —

> P256 public key y-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `parserRegistry()`

`0x56dc31d0` · view · access: —

> Optional calldata parser registry for DeFi protocol support (address(0) = disabled)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingWeightChange()`

`0x7bea8f76` · view · access: —

> Pending weight-change proposal (M6.2). proposedAt == 0 means none pending.

| returns | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |

#### `tier1Limit()`

`0x8efdc881` · view · access: —

> Tier1 max (ECDSA only)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tier2Limit()`

`0xdbaf0cc3` · view · access: —

> Tier2 max (dual factor); above this requires multi-sig (BLS triple)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `validator()`

`0x3a5381b5` · view · access: —

> Optional validator router for external algorithms (BLS, PQ, etc.)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `weightConfig()`

`0x085aa197` · view · access: —

> Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails.

| returns | type | description |
|---|---|---|
| `passkeyWeight` | `uint8` |  |
| `ecdsaWeight` | `uint8` |  |
| `blsWeight` | `uint8` |  |
| `guardian0Weight` | `uint8` |  |
| `guardian1Weight` | `uint8` |  |
| `guardian2Weight` | `uint8` |  |
| `_padding` | `uint8` |  |
| `tier1Threshold` | `uint8` |  |
| `tier2Threshold` | `uint8` |  |
| `tier3Threshold` | `uint8` |  |

### Events

| topic0 | event |
|---|---|
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |

### Errors

| selector | error |
|---|---|
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0xd7e6bcf8` | `NotInitializing()` |

## AAStarAirAccountBase

- **Source:** `src/core/AAStarAirAccountBase.sol`
- **Functions:** 35 · **Events:** 27 · **Errors:** 58
- **Title:** AAStarAirAccountBase
- Non-upgradable ERC-4337 smart wallet base with algId-based signature routing,         tiered verification, P256 passkey, social recovery, and global guard.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xb5cb7bb8` | `activeRecovery()` | view | — | Active recovery proposal |
| `0x4a58db19` | `addDeposit()` | payable | — |  |
| `0xa526d83b` | `addGuardian(address)` | nonpayable | onlyOwner | Add a recovery guardian. Owner-only when fewer than RECOVERY_THRESHOLD guardians exist         (pre-consensus bootstrap — a single guardian cannot form the required quorum anyway).         Once RECOVERY_THRESHOLD guardians are set, use addGuardianWithMixedSigs so a stolen         owner key cannot unilaterally change the guardian set. |
| `0x8fc2128e` | `agentExtension()` | view | — | Singleton AgentExtension holding ERC-8004 agent functions, reached via fallback. |
| `0x8450a928` | `approvedAlgorithms(uint8)` | view | — | Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4). |
| `0xb0d691fe` | `entryPoint()` | view | — | The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility) |
| `0xb61d27f6` | `execute(address,uint256,bytes)` | nonpayable | onlyOwnerOrEntryPoint, nonReentrant | Execute a single call from this account. |
| `0x47e1da2a` | `executeBatch(address[],uint256[],bytes[])` | nonpayable | onlyOwnerOrEntryPoint, nonReentrant | Execute a batch of calls from this account. |
| `0xc399ec88` | `getDeposit()` | view | — |  |
| `0x3e43b0b6` | `getRecoveryNonce()` | view | — | Returns the current recovery nonce (monotonic counter for P-256 sig replay protection). |
| `0x7ceab3b1` | `guard()` | view | — | Global guard for spending limits (set at construction, cannot be removed) |
| `0xc19c7050` | `guardAddTokenConfig(address,(uint128,uint128,uint256))` | nonpayable | onlyOwner | Add a new ERC20 token config to the guard (monotonic: add-only, never remove) |
| `0xa314d1c5` | `guardApproveAlgorithm(uint8)` | nonpayable | onlyOwner | Approve a new algorithm (add-only, never revoke). |
| `0x3847c084` | `guardDecreaseDailyLimit(uint256)` | nonpayable | onlyOwner | Decrease the guard's ETH daily limit (tighten-only, never increase) |
| `0xf64fd67c` | `guardDecreaseTokenDailyLimit(address,uint256)` | nonpayable | onlyOwner | Decrease a token's daily limit in the guard (tighten-only, never increase) |
| `0x54387ad7` | `guardianCount()` | view | — | Returns number of active guardians. |
| `0xf560c734` | `guardians(uint256)` | view | — | Returns guardian address at index (0-2). Returns address(0) for empty slots. |
| `0x253e659b` | `guardSetStrictMode(bool)` | nonpayable | onlyOwner | #22: toggle the guard's strict mode (block unconfigured tokens). Default OFF. |
| `0x3fe81b6a` | `modifyTierLimitsWithGuardians(uint256,uint256,uint256,bytes[])` | nonpayable | onlyOwner | Modify tier limits after initial setup — requires RECOVERY_THRESHOLD guardian signatures.         Handles all post-init changes: increase, decrease, or reset to (0,0) to disable tiering.         Security principle: the authorization level to change a spending guard must match         the tier level being guarded (spending at T2 requires a guardian; modifying T2 does too). |
| `0x8da5cb5b` | `owner()` | view | — | Account owner and ECDSA signer (mutable for social recovery) |
| `0x863ee512` | `p256KeyX()` | view | — | P256 public key x-coordinate |
| `0xc4bb0566` | `p256KeyY()` | view | — | P256 public key y-coordinate |
| `0x56dc31d0` | `parserRegistry()` | view | — | Optional calldata parser registry for DeFi protocol support (address(0) = disabled) |
| `0x7bea8f76` | `pendingWeightChange()` | view | — | Pending weight-change proposal (M6.2). proposedAt == 0 means none pending. |
| `0x34e33bf6` | `removeGuardian(uint8,bytes[])` | nonpayable | onlyOwner | Remove a guardian by index.         Requires >= RECOVERY_THRESHOLD distinct guardian signatures to prevent unilateral removal.         Cannot remove when only 2 guardians remain (minimum 2 must be kept). |
| `0xd0771689` | `requiredTier(uint256)` | view | — |  |
| `0x6fa36465` | `setP256Key(bytes32,bytes32)` | nonpayable | onlyOwner |  |
| `0x148d13d1` | `setParserRegistry(address)` | nonpayable | onlyOwner | Set the calldata parser registry for DeFi protocol support.         Can be updated by owner (unlike guard which is immutable).         Set to address(0) to disable parser support. |
| `0x7b471153` | `setTierLimits(uint256,uint256)` | nonpayable | onlyOwner | Set tier thresholds — INITIAL SETUP ONLY.         Callable exactly once, ever. After the first configuration (here or via         modifyTierLimitsWithGuardians), this function is permanently locked.         Any subsequent modification (increase, decrease, or disable) must go through         modifyTierLimitsWithGuardians(). Gating on a latch rather than on the current         limit values closes the bypass where a guardian reset to (0,0) would otherwise         re-open owner-only configuration. |
| `0x1327d3d8` | `setValidator(address)` | nonpayable | onlyOwner | Set the validator router — SET-ONCE (issue #45, Codex CRITICAL). The router resolves         the BLS/DVT algorithm AND the protocol aggregator (`blsAlgorithm.aggregator()`), so if         the owner could SWAP it, a compromised owner would point at a malicious router whose         `getAlgorithm(ALG_BLS)` returns a fake BLS algorithm (no-op `validate()` / attacker         `aggregator()`) and nullify the BLS/DVT factor on BOTH the single-op and batch paths.         The router is a protocol singleton (only-add registry + 7-day timelock for new         algorithms), so an account never needs to change it after the initial wiring. Once set         to a non-zero router it can never be changed — the DVT factor's algorithm source is         thereafter immutable from the (possibly compromised) owner's perspective. |
| `0x8efdc881` | `tier1Limit()` | view | — | Tier1 max (ECDSA only) |
| `0xdbaf0cc3` | `tier2Limit()` | view | — | Tier2 max (dual factor); above this requires multi-sig (BLS triple) |
| `0x3a5381b5` | `validator()` | view | — | Optional validator router for external algorithms (BLS, PQ, etc.) |
| `0x085aa197` | `weightConfig()` | view | — | Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails. |
| `0x4d44560d` | `withdrawDepositTo(address,uint256)` | nonpayable | onlyOwner |  |

### Functions

#### `activeRecovery()`

`0xb5cb7bb8` · view · access: —

> Active recovery proposal

| returns | type | description |
|---|---|---|
| `newOwner` | `address` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |
| `cancellationBitmap` | `uint256` |  |

#### `addDeposit()`

`0x4a58db19` · payable · access: —

#### `addGuardian(address _guardian)`

`0xa526d83b` · nonpayable · access: onlyOwner

> Add a recovery guardian. Owner-only when fewer than RECOVERY_THRESHOLD guardians exist         (pre-consensus bootstrap — a single guardian cannot form the required quorum anyway).         Once RECOVERY_THRESHOLD guardians are set, use addGuardianWithMixedSigs so a stolen         owner key cannot unilaterally change the guardian set.

| param | type | description |
|---|---|---|
| `_guardian` | `address` |  |

#### `agentExtension()`

`0x8fc2128e` · view · access: —

> Singleton AgentExtension holding ERC-8004 agent functions, reached via fallback.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `approvedAlgorithms(uint8 arg0)`

`0x8450a928` · view · access: —

> Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4).

| param | type | description |
|---|---|---|
| `arg0` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `execute(address dest, uint256 value, bytes func)`

`0xb61d27f6` · nonpayable · access: onlyOwnerOrEntryPoint, nonReentrant

> Execute a single call from this account.

| param | type | description |
|---|---|---|
| `dest` | `address` |  |
| `value` | `uint256` |  |
| `func` | `bytes` |  |

#### `executeBatch(address[] dest, uint256[] value, bytes[] func)`

`0x47e1da2a` · nonpayable · access: onlyOwnerOrEntryPoint, nonReentrant

> Execute a batch of calls from this account.

| param | type | description |
|---|---|---|
| `dest` | `address[]` |  |
| `value` | `uint256[]` |  |
| `func` | `bytes[]` |  |

#### `getDeposit()`

`0xc399ec88` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getRecoveryNonce()`

`0x3e43b0b6` · view · access: —

> Returns the current recovery nonce (monotonic counter for P-256 sig replay protection).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `guard()`

`0x7ceab3b1` · view · access: —

> Global guard for spending limits (set at construction, cannot be removed)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `guardAddTokenConfig(address token, (uint128,uint128,uint256) config)`

`0xc19c7050` · nonpayable · access: onlyOwner

> Add a new ERC20 token config to the guard (monotonic: add-only, never remove)

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `config` | `(uint128,uint128,uint256)` |  |

#### `guardApproveAlgorithm(uint8 algId)`

`0xa314d1c5` · nonpayable · access: onlyOwner

> Approve a new algorithm (add-only, never revoke).

*@dev* v0.17.2-beta.4: writes the account's own whitelist (single source of truth) instead of      the guard. The whitelist is enforced in validateUserOp. Name kept for ABI stability.

| param | type | description |
|---|---|---|
| `algId` | `uint8` |  |

#### `guardDecreaseDailyLimit(uint256 newLimit)`

`0x3847c084` · nonpayable · access: onlyOwner

> Decrease the guard's ETH daily limit (tighten-only, never increase)

| param | type | description |
|---|---|---|
| `newLimit` | `uint256` |  |

#### `guardDecreaseTokenDailyLimit(address token, uint256 newLimit)`

`0xf64fd67c` · nonpayable · access: onlyOwner

> Decrease a token's daily limit in the guard (tighten-only, never increase)

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `newLimit` | `uint256` |  |

#### `guardianCount()`

`0x54387ad7` · view · access: —

> Returns number of active guardians.

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `guardians(uint256 i)`

`0xf560c734` · view · access: —

> Returns guardian address at index (0-2). Returns address(0) for empty slots.

| param | type | description |
|---|---|---|
| `i` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `guardSetStrictMode(bool enabled)`

`0x253e659b` · nonpayable · access: onlyOwner

> #22: toggle the guard's strict mode (block unconfigured tokens). Default OFF.

| param | type | description |
|---|---|---|
| `enabled` | `bool` |  |

#### `modifyTierLimitsWithGuardians(uint256 _tier1, uint256 _tier2, uint256 deadline, bytes[] guardianSigs)`

`0x3fe81b6a` · nonpayable · access: onlyOwner

> Modify tier limits after initial setup — requires RECOVERY_THRESHOLD guardian signatures.         Handles all post-init changes: increase, decrease, or reset to (0,0) to disable tiering.         Security principle: the authorization level to change a spending guard must match         the tier level being guarded (spending at T2 requires a guardian; modifying T2 does too).

| param | type | description |
|---|---|---|
| `_tier1` | `uint256` | New Tier 1 threshold (single-factor limit). |
| `_tier2` | `uint256` | New Tier 2 threshold (dual-factor limit). 0 = T2 not used. |
| `deadline` | `uint256` | Signature expiry timestamp — guardians must sign within this window.                      Prevents long-term signature hoarding and delayed replay attacks. |
| `guardianSigs` | `bytes[]` | ECDSA signatures from RECOVERY_THRESHOLD distinct guardians. |

#### `owner()`

`0x8da5cb5b` · view · access: —

> Account owner and ECDSA signer (mutable for social recovery)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `p256KeyX()`

`0x863ee512` · view · access: —

> P256 public key x-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `p256KeyY()`

`0xc4bb0566` · view · access: —

> P256 public key y-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `parserRegistry()`

`0x56dc31d0` · view · access: —

> Optional calldata parser registry for DeFi protocol support (address(0) = disabled)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingWeightChange()`

`0x7bea8f76` · view · access: —

> Pending weight-change proposal (M6.2). proposedAt == 0 means none pending.

| returns | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |

#### `removeGuardian(uint8 index, bytes[] guardianSigs)`

`0x34e33bf6` · nonpayable · access: onlyOwner

> Remove a guardian by index.         Requires >= RECOVERY_THRESHOLD distinct guardian signatures to prevent unilateral removal.         Cannot remove when only 2 guardians remain (minimum 2 must be kept).

| param | type | description |
|---|---|---|
| `index` | `uint8` | Guardian slot to remove (0-indexed) |
| `guardianSigs` | `bytes[]` | At least RECOVERY_THRESHOLD guardian signatures over the removal hash |

#### `requiredTier(uint256 txValue)`

`0xd0771689` · view · access: —

*@dev* Determine the required algorithm tier based on transaction value.      Tier 1 (≤tier1Limit): ECDSA only      Tier 2 (≤tier2Limit): ECDSA + P256 dual factor      Tier 3 (>tier2Limit): BLS triple signature (multi-sig consensus)

| param | type | description |
|---|---|---|
| `txValue` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `setP256Key(bytes32 _x, bytes32 _y)`

`0x6fa36465` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `_x` | `bytes32` |  |
| `_y` | `bytes32` |  |

#### `setParserRegistry(address registry)`

`0x148d13d1` · nonpayable · access: onlyOwner

> Set the calldata parser registry for DeFi protocol support.         Can be updated by owner (unlike guard which is immutable).         Set to address(0) to disable parser support.

| param | type | description |
|---|---|---|
| `registry` | `address` |  |

#### `setTierLimits(uint256 _tier1, uint256 _tier2)`

`0x7b471153` · nonpayable · access: onlyOwner

> Set tier thresholds — INITIAL SETUP ONLY.         Callable exactly once, ever. After the first configuration (here or via         modifyTierLimitsWithGuardians), this function is permanently locked.         Any subsequent modification (increase, decrease, or disable) must go through         modifyTierLimitsWithGuardians(). Gating on a latch rather than on the current         limit values closes the bypass where a guardian reset to (0,0) would otherwise         re-open owner-only configuration.

| param | type | description |
|---|---|---|
| `_tier1` | `uint256` |  |
| `_tier2` | `uint256` |  |

#### `setValidator(address _validator)`

`0x1327d3d8` · nonpayable · access: onlyOwner

> Set the validator router — SET-ONCE (issue #45, Codex CRITICAL). The router resolves         the BLS/DVT algorithm AND the protocol aggregator (`blsAlgorithm.aggregator()`), so if         the owner could SWAP it, a compromised owner would point at a malicious router whose         `getAlgorithm(ALG_BLS)` returns a fake BLS algorithm (no-op `validate()` / attacker         `aggregator()`) and nullify the BLS/DVT factor on BOTH the single-op and batch paths.         The router is a protocol singleton (only-add registry + 7-day timelock for new         algorithms), so an account never needs to change it after the initial wiring. Once set         to a non-zero router it can never be changed — the DVT factor's algorithm source is         thereafter immutable from the (possibly compromised) owner's perspective.

| param | type | description |
|---|---|---|
| `_validator` | `address` |  |

#### `tier1Limit()`

`0x8efdc881` · view · access: —

> Tier1 max (ECDSA only)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tier2Limit()`

`0xdbaf0cc3` · view · access: —

> Tier2 max (dual factor); above this requires multi-sig (BLS triple)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `validator()`

`0x3a5381b5` · view · access: —

> Optional validator router for external algorithms (BLS, PQ, etc.)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `weightConfig()`

`0x085aa197` · view · access: —

> Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails.

| returns | type | description |
|---|---|---|
| `passkeyWeight` | `uint8` |  |
| `ecdsaWeight` | `uint8` |  |
| `blsWeight` | `uint8` |  |
| `guardian0Weight` | `uint8` |  |
| `guardian1Weight` | `uint8` |  |
| `guardian2Weight` | `uint8` |  |
| `_padding` | `uint8` |  |
| `tier1Threshold` | `uint8` |  |
| `tier2Threshold` | `uint8` |  |
| `tier3Threshold` | `uint8` |  |

#### `withdrawDepositTo(address to, uint256 amount)`

`0x4d44560d` · nonpayable · access: onlyOwner

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0x169142414aeecec3d3dfa03ef8b7d72d56023ead068694f563affe4276792bed` | `AgentIdentityMinted(uint256,address,string)` |
| `0xee0112c63253e47e4ff7403776240bef35d82b6feba08ea6ecb20f8a4ab75e92` | `AgentReputationSubmitted(uint256,address,int128,string)` |
| `0xc8982c1ad4646a1ed6bb40061ac7f2a6aaffef7f2e096aa9805cf705fa12933b` | `AgentWalletSet(uint256,address,address)` |
| `0x70d0659af0992f8fb991c96aa6a5918129fb57f88068bf35fd6f08fc2d4476f0` | `AlgorithmApproved(uint8)` |
| `0xaadd69bae4c5060e9be224899997360e78e4ee632c9951aa0055eeeb5bfc6662` | `ERC8004WalletBound(uint256,address,address)` |
| `0xeca9cd482b52ddd909a1a2ffcceae1b6dd76b5491ec997d8d9ac05c6426fa344` | `GuardianAdded(uint8,address)` |
| `0x21d14a63615c145863fb5004c412ccf4ba2439b31bfd93baf5892142417ae5bf` | `GuardianRemoved(uint8,address)` |
| `0x9166f3e5ae2db68b5385784060aa2e9342e45b8afc746b322fe51f18d19d474b` | `GuardInitialized(address,uint256)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0xd21d0b289f126c4b473ea641963e766833c2f13866e4ff480abd787c100ef123` | `ModuleInstalled(uint256,address)` |
| `0x341347516a9de374859dfda710fa4828b2d48cb57d4fbe4c1149612b8e02276e` | `ModuleUninstalled(uint256,address)` |
| `0xb532073b38c83145e3e5135377a08bf9aab55bc0fd7c1179cd4fb995d2a5159c` | `OwnerChanged(address,address)` |
| `0x2ab721df8af22606080fcc695d2c255bf7bfb356dbe68e84057a3e29678de3ec` | `P256GuardianAdded(uint8,bytes32,bytes32)` |
| `0x2e5ddc493d81d77b0b68b6603b29c467c94419656cea1684d2dce03f4bf321d6` | `P256KeySet(bytes32,bytes32)` |
| `0x977b07fd434a26f95f2850c9ba651937e650394c8cfb96e9ffba8e42cb5ac76d` | `ParserRegistrySet(address)` |
| `0x3e6e8da9cdbaf0d18a1123306c76e088d32bb5e76edabe32eaaa4ba7a50adb37` | `RecoveryApproved(address,address,uint256,uint8)` |
| `0xedd770ee01b7c0ef4f503125eafdc2725536cbf32342dffcaa300d95a7cafce3` | `RecoveryCancelled()` |
| `0x85d108740bb57aaf934ce63690f939704d2ce4cd099bc9c8ac11cd38db40392b` | `RecoveryCancelVoted(address,uint256,uint8)` |
| `0x60f9f98be64687700419cfa6fdd7877bc88c6daeb10bc664a2be9fdd6b0c7921` | `RecoveryExecuted(address,address)` |
| `0x201c40b4643e8b76c330a24e1a20d94dd5f798a3654180da40a29c00c18fe3b8` | `RecoveryProposed(address,address,uint8)` |
| `0xcfe045f2bad73057c49e23a745cb13c8b763723eeb93336c01c3bcb32cb1fc91` | `TierLimitsSet(uint256,uint256)` |
| `0x128d225533052ebf55fcccaa33435927c3530b794ac392f55bfda36e7d474543` | `ValidatorSet(address)` |
| `0x15f128f27bdfb175cfbe98c20eeca3038a9ee15470ec88a4fbd5a16a20a73267` | `WeightChangeApproved(address,uint256)` |
| `0x576deb2334d64aacc3de78fdc843b12c4601431d7d7546f8ef6ff413d18ad8e7` | `WeightChangeCancelled()` |
| `0xc94d426438944eb97ead040cba3930306dd959e6f9382bf215ad45427c03ecb6` | `WeightChangeExecuted((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |
| `0xba5c9da7994a2da6979c6d04d134da98d13c8cd4b70710bfc12400a72cb90072` | `WeightChangeProposed((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),address)` |
| `0x0c37cb722e39215324249ac820b21073307d8cf91ab4281713d68e95e9c7090a` | `WeightConfigUpdated((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |

### Errors

| selector | error |
|---|---|
| `0x71a31c27` | `AgentRegistrationFailed()` |
| `0xcf38f997` | `AgentSessionBatchNotSupported()` |
| `0x101f817a` | `AlreadyApproved()` |
| `0x0f5ff7bf` | `AlreadyCancelVoted()` |
| `0xa24a13a6` | `ArrayLengthMismatch()` |
| `0xa5fa8d2b` | `CallFailed(bytes)` |
| `0x9f081f40` | `CannotIncreaseTierLimit()` |
| `0xa27fbc63` | `DuplicateGuardianSig()` |
| `0x1e36aab2` | `DuplicateP256GuardianKey()` |
| `0xf645eedf` | `ECDSAInvalidSignature()` |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256)` |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32)` |
| `0x53682430` | `GuardianAlreadySet()` |
| `0x7abd948c` | `HookReverted()` |
| `0xe04a2600` | `IdentityRegistrationFailed()` |
| `0xa59a4151` | `InsecureWeightConfig()` |
| `0xdb5c22f4` | `InstallModuleUnauthorized()` |
| `0x16730a70` | `InsufficientGuardianApprovals()` |
| `0x4678a028` | `InsufficientTier(uint8,uint8)` |
| `0x4957e263` | `InsufficientWeight(uint8,uint8,uint8)` |
| `0xa6c1146b` | `InvalidGuardian()` |
| `0x07a81bc4` | `InvalidGuardianSignature()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0x2125deae` | `InvalidModuleType()` |
| `0x54a56786` | `InvalidNewOwner()` |
| `0x9b27bc53` | `InvalidP256GuardianKey()` |
| `0x275178f8` | `InvalidP256GuardianSignature(uint8)` |
| `0x2e14ce87` | `InvalidP256Key()` |
| `0x9100d347` | `InvalidTierConfig()` |
| `0xdfc3481a` | `MaxGuardiansReached()` |
| `0x36bf0fb2` | `MinGuardianRequired()` |
| `0x24c377e2` | `ModuleAlreadyInstalled()` |
| `0xf45e530b` | `ModuleInstallCallbackFailed(uint256,address)` |
| `0x74be437f` | `ModuleInvalid()` |
| `0x2a6f7929` | `ModuleNotInstalled()` |
| `0x8267d100` | `NoActiveRecovery()` |
| `0xd663742a` | `NotEntryPoint()` |
| `0xef6d0f02` | `NotGuardian()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x30cd7471` | `NotOwner()` |
| `0x50a222f4` | `NotOwnerOrEntryPoint()` |
| `0x1e142ec1` | `NoWeightChangeProposal()` |
| `0x6e5510ce` | `RecoveryAlreadyActive()` |
| `0x39d51cb2` | `RecoveryNotApproved()` |
| `0xaa40cfc6` | `RecoveryTimelockNotExpired()` |
| `0xab143c06` | `Reentrancy()` |
| `0xbc5e8e59` | `ReputationRegistryFailed()` |
| `0x3f041335` | `SessionScopeViolation()` |
| `0x54123466` | `TierLimitSigExpired()` |
| `0xf5b28a64` | `UnauthorizedRegistry()` |
| `0x6cd89112` | `UseGuardianConsensus()` |
| `0x2157e2e7` | `ValidatorAlreadySet()` |
| `0x2e0ec5bc` | `WeakeningRequiresProposal()` |
| `0xf6b2ebb8` | `WeightChangeAlreadyApproved()` |
| `0xf0854cb8` | `WeightChangeNotApproved()` |
| `0xc30fc6f5` | `WeightChangePending()` |
| `0xac2edbf6` | `WeightChangeTimelockNotExpired()` |
| `0x16bf332d` | `WeightConfigNotInitialized()` |

## IBLSAggregatorSource

- **Source:** `src/core/AAStarAirAccountBase.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x245a7bfc` | `aggregator()` | view | — |  |

### Functions

#### `aggregator()`

`0x245a7bfc` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

## AAStarAirAccountV7

- **Source:** `src/core/AAStarAirAccountV7.sol`
- **Functions:** 51 · **Events:** 27 · **Errors:** 59
- **Title:** AAStarAirAccountV7 — ERC-4337 account for EntryPoint v0.7
- Non-upgradable, inherits core logic from AAStarAirAccountBase. ERC-7579 Minimum Compatibility Shim (M6):   AirAccount is NOT a full ERC-7579 implementation (that is M7 work).   This shim adds the minimum surface so that ERC-7579 ecosystem tools   (paymaster SDKs, session key wizards, ZeroDev tooling) can query   account metadata and installed modules without custom integration.   Supported in M6 (read/query only):     - accountId()           — identity string for tooling     - supportsModule()      — declares validator(1) and executor(2) support     - isModuleInstalled()   — maps to existing validator slot     - supportsInterface()   — ERC-165 for ERC-1271 and ERC-7579 interface IDs     - isValidSignature()    — ERC-1271 on-chain signature validation   NOT supported in M6 (full M7):     - installModule() / uninstallModule() with guardian gate + timelock     - executeFromExecutor()     - Full ModeCode execution dispatch

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xbc68c676` | `ACCOUNT_VERSION()` | view | — | Semantic version of this contract deployment. Used by SDKs for programmatic version detection. |
| `0x9cfd7cff` | `accountId()` | pure | — | ERC-7579 account identity string.         Format: "vendor.name.version" — enables tooling to identify this account type. |
| `0xb5cb7bb8` | `activeRecovery()` | view | — | Active recovery proposal |
| `0x4a58db19` | `addDeposit()` | payable | — |  |
| `0xa526d83b` | `addGuardian(address)` | nonpayable | — | Add a recovery guardian. Owner-only when fewer than RECOVERY_THRESHOLD guardians exist         (pre-consensus bootstrap — a single guardian cannot form the required quorum anyway).         Once RECOVERY_THRESHOLD guardians are set, use addGuardianWithMixedSigs so a stolen         owner key cannot unilaterally change the guardian set. |
| `0x8fc2128e` | `agentExtension()` | view | — | Singleton AgentExtension holding ERC-8004 agent functions, reached via fallback. |
| `0x8450a928` | `approvedAlgorithms(uint8)` | view | — | Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4). |
| `0xb0d691fe` | `entryPoint()` | view | — | The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility) |
| `0xb61d27f6` | `execute(address,uint256,bytes)` | nonpayable | — | Execute a single call from this account. |
| `0x47e1da2a` | `executeBatch(address[],uint256[],bytes[])` | nonpayable | — | Execute a batch of calls from this account. |
| `0xd691c964` | `executeFromExecutor(bytes32,bytes)` | nonpayable | nonReentrant | ERC-7579: Execute a single call on behalf of this account, called by an installed executor module.         Executor modules are installed via guardians (installModule requires guardian sig), providing         authentication. The full guard is enforced here at Tier 1 (ALG_ECDSA). |
| `0x8dd7712f` | `executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)` | nonpayable | onlyEntryPoint |  |
| `0xc399ec88` | `getDeposit()` | view | — |  |
| `0x3e43b0b6` | `getRecoveryNonce()` | view | — | Returns the current recovery nonce (monotonic counter for P-256 sig replay protection). |
| `0x7ceab3b1` | `guard()` | view | — | Global guard for spending limits (set at construction, cannot be removed) |
| `0xc19c7050` | `guardAddTokenConfig(address,(uint128,uint128,uint256))` | nonpayable | — | Add a new ERC20 token config to the guard (monotonic: add-only, never remove) |
| `0xa314d1c5` | `guardApproveAlgorithm(uint8)` | nonpayable | — | Approve a new algorithm (add-only, never revoke). |
| `0x3847c084` | `guardDecreaseDailyLimit(uint256)` | nonpayable | — | Decrease the guard's ETH daily limit (tighten-only, never increase) |
| `0xf64fd67c` | `guardDecreaseTokenDailyLimit(address,uint256)` | nonpayable | — | Decrease a token's daily limit in the guard (tighten-only, never increase) |
| `0x54387ad7` | `guardianCount()` | view | — | Returns number of active guardians. |
| `0xf560c734` | `guardians(uint256)` | view | — | Returns guardian address at index (0-2). Returns address(0) for empty slots. |
| `0x253e659b` | `guardSetStrictMode(bool)` | nonpayable | — | #22: toggle the guard's strict mode (block unconfigured tokens). Default OFF. |
| `0x1ab193d8` | `initialize(address,address,(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]),address)` | nonpayable | initializer | Initialize this account with a pre-deployed guard.         Guard must be deployed by the caller (factory or test) before calling this.         Keeping guard deployment outside the account removes ~4,595B of creation code         from the account's runtime, keeping it under EIP-170's 24,576-byte limit. |
| `0x3cb406a8` | `initialize(address,address,(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]))` | nonpayable | initializer | Initialize this account without a guard (called directly in tests or for no-guard accounts).         The `initializer` modifier from OZ Initializable prevents re-initialization. |
| `0xe2a30d26` | `initializeAgentAccount(address,address,(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]),address)` | nonpayable | initializer | Initialize an autonomous-agent account. |
| `0x9517e29f` | `installModule(uint256,address,bytes)` | nonpayable | onlyOwnerOrEntryPoint | ERC-7579: Install a module. |
| `0x112d3a7d` | `isModuleInstalled(uint256,address,bytes)` | view | — | ERC-7579: check whether a module is installed.         Checks the unified module registry for supported types (1,2,4).         Note: the built-in ECDSA validator is registered at initialize time. |
| `0x1626ba7e` | `isValidSignature(bytes32,bytes)` | view | — | ERC-1271: on-chain signature validation used by ERC-7579 tooling and DeFi protocols.         Validates that the ECDSA signature was produced by this account's owner. |
| `0x3fe81b6a` | `modifyTierLimitsWithGuardians(uint256,uint256,uint256,bytes[])` | nonpayable | — | Modify tier limits after initial setup — requires RECOVERY_THRESHOLD guardian signatures.         Handles all post-init changes: increase, decrease, or reset to (0,0) to disable tiering.         Security principle: the authorization level to change a spending guard must match         the tier level being guarded (spending at T2 requires a guardian; modifying T2 does too). |
| `0x2c364ef6` | `moduleManagementNonce()` | view | — | Current module-management nonce (issue #75). A guardian signing an installModule /         uninstallModule request must fold this value into the signed hash; it increments         after every successful install AND uninstall, so a signature cannot be replayed         after an uninstall+reinstall cycle. |
| `0x150b7a02` | `onERC721Received(address,address,uint256,bytes)` | pure | — | ERC-721 receiver — required because official ERC-8004 IdentityRegistry uses _safeMint.         Without this, minting an agent identity NFT directly to this account would revert. |
| `0x8da5cb5b` | `owner()` | view | — | Account owner and ECDSA signer (mutable for social recovery) |
| `0x863ee512` | `p256KeyX()` | view | — | P256 public key x-coordinate |
| `0xc4bb0566` | `p256KeyY()` | view | — | P256 public key y-coordinate |
| `0x56dc31d0` | `parserRegistry()` | view | — | Optional calldata parser registry for DeFi protocol support (address(0) = disabled) |
| `0x7bea8f76` | `pendingWeightChange()` | view | — | Pending weight-change proposal (M6.2). proposedAt == 0 means none pending. |
| `0x34e33bf6` | `removeGuardian(uint8,bytes[])` | nonpayable | — | Remove a guardian by index.         Requires >= RECOVERY_THRESHOLD distinct guardian signatures to prevent unilateral removal.         Cannot remove when only 2 guardians remain (minimum 2 must be kept). |
| `0xd0771689` | `requiredTier(uint256)` | view | — |  |
| `0x6fa36465` | `setP256Key(bytes32,bytes32)` | nonpayable | — |  |
| `0x148d13d1` | `setParserRegistry(address)` | nonpayable | — | Set the calldata parser registry for DeFi protocol support.         Can be updated by owner (unlike guard which is immutable).         Set to address(0) to disable parser support. |
| `0x7b471153` | `setTierLimits(uint256,uint256)` | nonpayable | — | Set tier thresholds — INITIAL SETUP ONLY.         Callable exactly once, ever. After the first configuration (here or via         modifyTierLimitsWithGuardians), this function is permanently locked.         Any subsequent modification (increase, decrease, or disable) must go through         modifyTierLimitsWithGuardians(). Gating on a latch rather than on the current         limit values closes the bypass where a guardian reset to (0,0) would otherwise         re-open owner-only configuration. |
| `0x1327d3d8` | `setValidator(address)` | nonpayable | — | Set the validator router — SET-ONCE (issue #45, Codex CRITICAL). The router resolves         the BLS/DVT algorithm AND the protocol aggregator (`blsAlgorithm.aggregator()`), so if         the owner could SWAP it, a compromised owner would point at a malicious router whose         `getAlgorithm(ALG_BLS)` returns a fake BLS algorithm (no-op `validate()` / attacker         `aggregator()`) and nullify the BLS/DVT factor on BOTH the single-op and batch paths.         The router is a protocol singleton (only-add registry + 7-day timelock for new         algorithms), so an account never needs to change it after the initial wiring. Once set         to a non-zero router it can never be changed — the DVT factor's algorithm source is         thereafter immutable from the (possibly compromised) owner's perspective. |
| `0x01ffc9a7` | `supportsInterface(bytes4)` | pure | — | ERC-165: interface detection.         Signals support for ERC-1271 (isValidSignature), ERC-4337, and ERC-721 receiver. |
| `0xf2dc691d` | `supportsModule(uint256)` | pure | — | ERC-7579: declare which module types this account supports.         Declares validator(1), executor(2), and hook(4). Fallback(3) is not supported. |
| `0x8efdc881` | `tier1Limit()` | view | — | Tier1 max (ECDSA only) |
| `0xdbaf0cc3` | `tier2Limit()` | view | — | Tier2 max (dual factor); above this requires multi-sig (BLS triple) |
| `0xa71763a8` | `uninstallModule(uint256,address,bytes)` | nonpayable | onlyOwnerOrEntryPoint | ERC-7579: Uninstall a module. |
| `0x19822f7c` | `validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)` | nonpayable | onlyEntryPoint | Validate user's signature and nonce the entryPoint will make the call to the recipient only if this validation call returns successfully. signature failure should be reported by returning SIG_VALIDATION_FAILED (1). This allows making a "simulation call" without a valid signature Other failures (e.g. nonce mismatch, or invalid signature format) should still revert to signal failure. |
| `0x3a5381b5` | `validator()` | view | — | Optional validator router for external algorithms (BLS, PQ, etc.) |
| `0x085aa197` | `weightConfig()` | view | — | Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails. |
| `0x4d44560d` | `withdrawDepositTo(address,uint256)` | nonpayable | — |  |

### Functions

#### `ACCOUNT_VERSION()`

`0xbc68c676` · view · access: —

> Semantic version of this contract deployment. Used by SDKs for programmatic version detection.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `accountId()`

`0x9cfd7cff` · pure · access: —

> ERC-7579 account identity string.         Format: "vendor.name.version" — enables tooling to identify this account type.

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `activeRecovery()`

`0xb5cb7bb8` · view · access: —

> Active recovery proposal

| returns | type | description |
|---|---|---|
| `newOwner` | `address` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |
| `cancellationBitmap` | `uint256` |  |

#### `addDeposit()`

`0x4a58db19` · payable · access: —

#### `addGuardian(address _guardian)`

`0xa526d83b` · nonpayable · access: —

> Add a recovery guardian. Owner-only when fewer than RECOVERY_THRESHOLD guardians exist         (pre-consensus bootstrap — a single guardian cannot form the required quorum anyway).         Once RECOVERY_THRESHOLD guardians are set, use addGuardianWithMixedSigs so a stolen         owner key cannot unilaterally change the guardian set.

| param | type | description |
|---|---|---|
| `_guardian` | `address` |  |

#### `agentExtension()`

`0x8fc2128e` · view · access: —

> Singleton AgentExtension holding ERC-8004 agent functions, reached via fallback.

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `approvedAlgorithms(uint8 arg0)`

`0x8450a928` · view · access: —

> Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4).

| param | type | description |
|---|---|---|
| `arg0` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `execute(address dest, uint256 value, bytes func)`

`0xb61d27f6` · nonpayable · access: —

> Execute a single call from this account.

| param | type | description |
|---|---|---|
| `dest` | `address` |  |
| `value` | `uint256` |  |
| `func` | `bytes` |  |

#### `executeBatch(address[] dest, uint256[] value, bytes[] func)`

`0x47e1da2a` · nonpayable · access: —

> Execute a batch of calls from this account.

| param | type | description |
|---|---|---|
| `dest` | `address[]` |  |
| `value` | `uint256[]` |  |
| `func` | `bytes[]` |  |

#### `executeFromExecutor(bytes32 mode, bytes executionCalldata)`

`0xd691c964` · nonpayable · access: nonReentrant

> ERC-7579: Execute a single call on behalf of this account, called by an installed executor module.         Executor modules are installed via guardians (installModule requires guardian sig), providing         authentication. The full guard is enforced here at Tier 1 (ALG_ECDSA).

*@dev* C-4: executors run at Tier 1 and cannot supply higher-tier (multi-factor) signatures, so they         are bound to the account's Tier-1 ceiling. Routing through _enforceGuard (rather than a bare         guard.checkTransaction) applies the cumulative ETH tier check too: an executor op whose value         pushes today's spend above tier1Limit reverts InsufficientTier. The account owner controls what         counts as "small" by tuning tier1Limit.NOTE: the tier check is only active when tiering is configured (tier1Limit or tier2Limit > 0).         If both are 0, tiering is disabled and an executor is bounded only by the guard's daily limit         (and token limits) — it is NOT implicitly capped. Set tier1Limit to enforce a per-op ETH ceiling.

| param | type | description |
|---|---|---|
| `mode` | `bytes32` | ModeCode (bytes32): byte[0] must be 0x00 (single call). Batch mode not supported in M7. |
| `executionCalldata` | `bytes` | abi.encodePacked(target(20), value(32), calldata) |

| returns | type | description |
|---|---|---|
| `returnData` | `bytes[]` | Single-element array with the call's return bytes |

#### `executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 userOpHash)`

`0x8dd7712f` · nonpayable · access: onlyEntryPoint

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` |  |
| `userOpHash` | `bytes32` |  |

#### `getDeposit()`

`0xc399ec88` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `getRecoveryNonce()`

`0x3e43b0b6` · view · access: —

> Returns the current recovery nonce (monotonic counter for P-256 sig replay protection).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `guard()`

`0x7ceab3b1` · view · access: —

> Global guard for spending limits (set at construction, cannot be removed)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `guardAddTokenConfig(address token, (uint128,uint128,uint256) config)`

`0xc19c7050` · nonpayable · access: —

> Add a new ERC20 token config to the guard (monotonic: add-only, never remove)

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `config` | `(uint128,uint128,uint256)` |  |

#### `guardApproveAlgorithm(uint8 algId)`

`0xa314d1c5` · nonpayable · access: —

> Approve a new algorithm (add-only, never revoke).

*@dev* v0.17.2-beta.4: writes the account's own whitelist (single source of truth) instead of      the guard. The whitelist is enforced in validateUserOp. Name kept for ABI stability.

| param | type | description |
|---|---|---|
| `algId` | `uint8` |  |

#### `guardDecreaseDailyLimit(uint256 newLimit)`

`0x3847c084` · nonpayable · access: —

> Decrease the guard's ETH daily limit (tighten-only, never increase)

| param | type | description |
|---|---|---|
| `newLimit` | `uint256` |  |

#### `guardDecreaseTokenDailyLimit(address token, uint256 newLimit)`

`0xf64fd67c` · nonpayable · access: —

> Decrease a token's daily limit in the guard (tighten-only, never increase)

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `newLimit` | `uint256` |  |

#### `guardianCount()`

`0x54387ad7` · view · access: —

> Returns number of active guardians.

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `guardians(uint256 i)`

`0xf560c734` · view · access: —

> Returns guardian address at index (0-2). Returns address(0) for empty slots.

| param | type | description |
|---|---|---|
| `i` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `guardSetStrictMode(bool enabled)`

`0x253e659b` · nonpayable · access: —

> #22: toggle the guard's strict mode (block unconfigured tokens). Default OFF.

| param | type | description |
|---|---|---|
| `enabled` | `bool` |  |

#### `initialize(address _entryPoint, address _owner, (address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]) _config, address _guardAddr)`

`0x1ab193d8` · nonpayable · access: initializer

> Initialize this account with a pre-deployed guard.         Guard must be deployed by the caller (factory or test) before calling this.         Keeping guard deployment outside the account removes ~4,595B of creation code         from the account's runtime, keeping it under EIP-170's 24,576-byte limit.

| param | type | description |
|---|---|---|
| `_entryPoint` | `address` | ERC-4337 EntryPoint address |
| `_owner` | `address` | Initial account owner (ECDSA signer) |
| `_config` | `(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[])` | Initialization config: guardians (dailyLimit/algIds used to deploy _guardAddr) |
| `_guardAddr` | `address` | Pre-deployed AAStarGlobalGuard address bound to this account's address |

#### `initialize(address _entryPoint, address _owner, (address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]) _config)`

`0x3cb406a8` · nonpayable · access: initializer

> Initialize this account without a guard (called directly in tests or for no-guard accounts).         The `initializer` modifier from OZ Initializable prevents re-initialization.

| param | type | description |
|---|---|---|
| `_entryPoint` | `address` | ERC-4337 EntryPoint address |
| `_owner` | `address` | Initial account owner (ECDSA signer) |
| `_config` | `(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[])` | Initialization config: guardians and algorithm list (dailyLimit ignored — no guard deployed) |

#### `initializeAgentAccount(address _entryPoint, address _owner, (address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[]) _config, address _guardAddr)`

`0xe2a30d26` · nonpayable · access: initializer

> Initialize an autonomous-agent account.

*@dev* v0.17.2: this no longer pre-installs any validator module. Session keys (for agents      or DApp gaming flows) are managed via the unified `SessionKeyValidator` registered      in the router at algId 0x08 — no per-account install is required. After creation the      owner calls `SessionKeyValidator.grantSession[Direct]` to authorize a specific session.      Kept as a separate entrypoint from `initialize` to allow factory `createAgentAccount` to      carry agent-specific semantics (deterministic salt from agentId, agentKey consent sig)      without forcing those checks on `createAccount` / `createAccountWithDefaults`.

| param | type | description |
|---|---|---|
| `_entryPoint` | `address` |  |
| `_owner` | `address` |  |
| `_config` | `(address[3],bytes32[3],bytes32[3],uint256,uint8[],uint256,address[],(uint128,uint128,uint256)[])` |  |
| `_guardAddr` | `address` |  |

#### `installModule(uint256 moduleTypeId, address module, bytes initData)`

`0x9517e29f` · nonpayable · access: onlyOwnerOrEntryPoint

> ERC-7579: Install a module.

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` | 1=Validator, 2=Executor, 3=Hook |
| `module` | `address` | Module contract address (must be deployed) |
| `initData` | `bytes` | Layout: guardian sig(s) prepended, then module init data.   Guardian sig count: 0 if threshold<=40, 1 if threshold<=70, 2 if threshold=100.   Sig hash: _guardianOpHash("INSTALL_MODULE", abi.encode(moduleTypeId, module, moduleInitDataHash, moduleManagementNonce))   = keccak256(abi.encode(GUARDIAN_SIG_VERSION, chainId, account, "INSTALL_MODULE", opData)).toEthSignedMessageHash()   Bytes after the sig(s) are passed as initData to onInstall(bytes). |

#### `isModuleInstalled(uint256 moduleTypeId, address module, bytes arg2)`

`0x112d3a7d` · view · access: —

> ERC-7579: check whether a module is installed.         Checks the unified module registry for supported types (1,2,4).         Note: the built-in ECDSA validator is registered at initialize time.

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` |  |
| `module` | `address` |  |
| `arg2` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isValidSignature(bytes32 hash, bytes sig)`

`0x1626ba7e` · view · access: —

> ERC-1271: on-chain signature validation used by ERC-7579 tooling and DeFi protocols.         Validates that the ECDSA signature was produced by this account's owner.

*@dev* NO EIP-191 prefix is applied — `hash` must be the EXACT bytes32 that was signed.      Integration guide for callers:      • EIP-712 / DeFi flows (Permit2, OpenSea, CoW, most DeFi protocols):        Pass the final EIP-712 digest, i.e. `keccak256("\x19\x01" \|\| domainSeparator \|\| hashStruct)`        (what `TypedDataEncoder.hash(...)` / ethers `_signTypedData` produce). The owner signs this        digest directly (no personal_sign prefix). Pass that same bytes32 here — no wrapping needed.      • personal_sign / MetaMask `eth_sign` flows:        The wallet prepends the EIP-191 prefix "\x19Ethereum Signed Message:\n32" before        signing. The caller must therefore pass the PREFIXED hash, i.e.:          keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rawHash))        This is what `MessageHashUtils.toEthSignedMessageHash(rawHash)` produces.      This behaviour matches Gnosis Safe and the canonical ERC-1271 production pattern.      NOTE: _validateECDSA (the UserOp validation path) DOES apply toEthSignedMessageHash()      because EOA signers use personal_sign for userOpHash. These are intentionally separate      paths — ERC-1271 serves DeFi protocols, UserOp validation serves the ERC-4337 bundler.

| param | type | description |
|---|---|---|
| `hash` | `bytes32` | The exact bytes32 that was signed (no prefix added by this contract). |
| `sig` | `bytes` | 65-byte ECDSA signature (r \|\| s \|\| v) produced by the account owner. |

| returns | type | description |
|---|---|---|
| `_0` | `bytes4` | 0x1626ba7e if the signature is valid, 0xffffffff otherwise. |

#### `modifyTierLimitsWithGuardians(uint256 _tier1, uint256 _tier2, uint256 deadline, bytes[] guardianSigs)`

`0x3fe81b6a` · nonpayable · access: —

> Modify tier limits after initial setup — requires RECOVERY_THRESHOLD guardian signatures.         Handles all post-init changes: increase, decrease, or reset to (0,0) to disable tiering.         Security principle: the authorization level to change a spending guard must match         the tier level being guarded (spending at T2 requires a guardian; modifying T2 does too).

| param | type | description |
|---|---|---|
| `_tier1` | `uint256` | New Tier 1 threshold (single-factor limit). |
| `_tier2` | `uint256` | New Tier 2 threshold (dual-factor limit). 0 = T2 not used. |
| `deadline` | `uint256` | Signature expiry timestamp — guardians must sign within this window.                      Prevents long-term signature hoarding and delayed replay attacks. |
| `guardianSigs` | `bytes[]` | ECDSA signatures from RECOVERY_THRESHOLD distinct guardians. |

#### `moduleManagementNonce()`

`0x2c364ef6` · view · access: —

> Current module-management nonce (issue #75). A guardian signing an installModule /         uninstallModule request must fold this value into the signed hash; it increments         after every successful install AND uninstall, so a signature cannot be replayed         after an uninstall+reinstall cycle.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `onERC721Received(address arg0, address arg1, uint256 arg2, bytes arg3)`

`0x150b7a02` · pure · access: —

> ERC-721 receiver — required because official ERC-8004 IdentityRegistry uses _safeMint.         Without this, minting an agent identity NFT directly to this account would revert.

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `address` |  |
| `arg2` | `uint256` |  |
| `arg3` | `bytes` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes4` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

> Account owner and ECDSA signer (mutable for social recovery)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `p256KeyX()`

`0x863ee512` · view · access: —

> P256 public key x-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `p256KeyY()`

`0xc4bb0566` · view · access: —

> P256 public key y-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `parserRegistry()`

`0x56dc31d0` · view · access: —

> Optional calldata parser registry for DeFi protocol support (address(0) = disabled)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingWeightChange()`

`0x7bea8f76` · view · access: —

> Pending weight-change proposal (M6.2). proposedAt == 0 means none pending.

| returns | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |

#### `removeGuardian(uint8 index, bytes[] guardianSigs)`

`0x34e33bf6` · nonpayable · access: —

> Remove a guardian by index.         Requires >= RECOVERY_THRESHOLD distinct guardian signatures to prevent unilateral removal.         Cannot remove when only 2 guardians remain (minimum 2 must be kept).

| param | type | description |
|---|---|---|
| `index` | `uint8` | Guardian slot to remove (0-indexed) |
| `guardianSigs` | `bytes[]` | At least RECOVERY_THRESHOLD guardian signatures over the removal hash |

#### `requiredTier(uint256 txValue)`

`0xd0771689` · view · access: —

*@dev* Determine the required algorithm tier based on transaction value.      Tier 1 (≤tier1Limit): ECDSA only      Tier 2 (≤tier2Limit): ECDSA + P256 dual factor      Tier 3 (>tier2Limit): BLS triple signature (multi-sig consensus)

| param | type | description |
|---|---|---|
| `txValue` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint8` |  |

#### `setP256Key(bytes32 _x, bytes32 _y)`

`0x6fa36465` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `_x` | `bytes32` |  |
| `_y` | `bytes32` |  |

#### `setParserRegistry(address registry)`

`0x148d13d1` · nonpayable · access: —

> Set the calldata parser registry for DeFi protocol support.         Can be updated by owner (unlike guard which is immutable).         Set to address(0) to disable parser support.

| param | type | description |
|---|---|---|
| `registry` | `address` |  |

#### `setTierLimits(uint256 _tier1, uint256 _tier2)`

`0x7b471153` · nonpayable · access: —

> Set tier thresholds — INITIAL SETUP ONLY.         Callable exactly once, ever. After the first configuration (here or via         modifyTierLimitsWithGuardians), this function is permanently locked.         Any subsequent modification (increase, decrease, or disable) must go through         modifyTierLimitsWithGuardians(). Gating on a latch rather than on the current         limit values closes the bypass where a guardian reset to (0,0) would otherwise         re-open owner-only configuration.

| param | type | description |
|---|---|---|
| `_tier1` | `uint256` |  |
| `_tier2` | `uint256` |  |

#### `setValidator(address _validator)`

`0x1327d3d8` · nonpayable · access: —

> Set the validator router — SET-ONCE (issue #45, Codex CRITICAL). The router resolves         the BLS/DVT algorithm AND the protocol aggregator (`blsAlgorithm.aggregator()`), so if         the owner could SWAP it, a compromised owner would point at a malicious router whose         `getAlgorithm(ALG_BLS)` returns a fake BLS algorithm (no-op `validate()` / attacker         `aggregator()`) and nullify the BLS/DVT factor on BOTH the single-op and batch paths.         The router is a protocol singleton (only-add registry + 7-day timelock for new         algorithms), so an account never needs to change it after the initial wiring. Once set         to a non-zero router it can never be changed — the DVT factor's algorithm source is         thereafter immutable from the (possibly compromised) owner's perspective.

| param | type | description |
|---|---|---|
| `_validator` | `address` |  |

#### `supportsInterface(bytes4 interfaceId)`

`0x01ffc9a7` · pure · access: —

> ERC-165: interface detection.         Signals support for ERC-1271 (isValidSignature), ERC-4337, and ERC-721 receiver.

| param | type | description |
|---|---|---|
| `interfaceId` | `bytes4` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `supportsModule(uint256 moduleTypeId)`

`0xf2dc691d` · pure · access: —

> ERC-7579: declare which module types this account supports.         Declares validator(1), executor(2), and hook(4). Fallback(3) is not supported.

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `tier1Limit()`

`0x8efdc881` · view · access: —

> Tier1 max (ECDSA only)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tier2Limit()`

`0xdbaf0cc3` · view · access: —

> Tier2 max (dual factor); above this requires multi-sig (BLS triple)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `uninstallModule(uint256 moduleTypeId, address module, bytes deInitData)`

`0xa71763a8` · nonpayable · access: onlyOwnerOrEntryPoint

> ERC-7579: Uninstall a module.

*@dev* Requires min(guardianCount, 2) guardian sigs.      Accounts with fewer than 2 real guardians use all available guardian sigs      so that modules are never permanently locked even on minimal-guardian accounts.      Sig hash: _guardianOpHash("UNINSTALL_MODULE", abi.encode(moduleTypeId, module, moduleManagementNonce))      = keccak256(abi.encode(GUARDIAN_SIG_VERSION, chainId, account, "UNINSTALL_MODULE", opData)).toEthSignedMessageHash()

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` |  |
| `module` | `address` |  |
| `deInitData` | `bytes` |  |

#### `validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes) userOp, bytes32 userOpHash, uint256 missingAccountFunds)`

`0x19822f7c` · nonpayable · access: onlyEntryPoint

> Validate user's signature and nonce the entryPoint will make the call to the recipient only if this validation call returns successfully. signature failure should be reported by returning SIG_VALIDATION_FAILED (1). This allows making a "simulation call" without a valid signature Other failures (e.g. nonce mismatch, or invalid signature format) should still revert to signal failure.

*@dev* Must validate caller is the entryPoint.      Must validate the signature and nonce

| param | type | description |
|---|---|---|
| `userOp` | `(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)` | - The operation that is about to be executed. |
| `userOpHash` | `bytes32` | - Hash of the user's request data. can be used as the basis for signature. |
| `missingAccountFunds` | `uint256` | - Missing funds on the account's deposit in the entrypoint.                              This is the minimum amount to transfer to the sender(entryPoint) to be                              able to make the call. The excess is left as a deposit in the entrypoint                              for future calls. Can be withdrawn anytime using "entryPoint.withdrawTo()".                              In case there is a paymaster in the request (or the current deposit is high                              enough), this value will be zero. |

| returns | type | description |
|---|---|---|
| `validationData` | `uint256` | - Packaged ValidationData structure. use `_packValidationData` and                              `_unpackValidationData` to encode and decode.                              <20-byte> aggregatorOrSigFail - 0 for valid signature, 1 to mark signature failure,                                 otherwise, an address of an "aggregator" contract.                              <6-byte> validUntil - Last timestamp this operation is valid at, or 0 for "indefinitely"                              <6-byte> validAfter - First timestamp this operation is valid                                                    If an account doesn't use time-range, it is enough to                                                    return SIG_VALIDATION_FAILED value (1) for signature failure.                              Note that the validation code cannot use block.timestamp (or block.number) directly. |

#### `validator()`

`0x3a5381b5` · view · access: —

> Optional validator router for external algorithms (BLS, PQ, etc.)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `weightConfig()`

`0x085aa197` · view · access: —

> Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails.

| returns | type | description |
|---|---|---|
| `passkeyWeight` | `uint8` |  |
| `ecdsaWeight` | `uint8` |  |
| `blsWeight` | `uint8` |  |
| `guardian0Weight` | `uint8` |  |
| `guardian1Weight` | `uint8` |  |
| `guardian2Weight` | `uint8` |  |
| `_padding` | `uint8` |  |
| `tier1Threshold` | `uint8` |  |
| `tier2Threshold` | `uint8` |  |
| `tier3Threshold` | `uint8` |  |

#### `withdrawDepositTo(address to, uint256 amount)`

`0x4d44560d` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `amount` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0x169142414aeecec3d3dfa03ef8b7d72d56023ead068694f563affe4276792bed` | `AgentIdentityMinted(uint256,address,string)` |
| `0xee0112c63253e47e4ff7403776240bef35d82b6feba08ea6ecb20f8a4ab75e92` | `AgentReputationSubmitted(uint256,address,int128,string)` |
| `0xc8982c1ad4646a1ed6bb40061ac7f2a6aaffef7f2e096aa9805cf705fa12933b` | `AgentWalletSet(uint256,address,address)` |
| `0x70d0659af0992f8fb991c96aa6a5918129fb57f88068bf35fd6f08fc2d4476f0` | `AlgorithmApproved(uint8)` |
| `0xaadd69bae4c5060e9be224899997360e78e4ee632c9951aa0055eeeb5bfc6662` | `ERC8004WalletBound(uint256,address,address)` |
| `0xeca9cd482b52ddd909a1a2ffcceae1b6dd76b5491ec997d8d9ac05c6426fa344` | `GuardianAdded(uint8,address)` |
| `0x21d14a63615c145863fb5004c412ccf4ba2439b31bfd93baf5892142417ae5bf` | `GuardianRemoved(uint8,address)` |
| `0x9166f3e5ae2db68b5385784060aa2e9342e45b8afc746b322fe51f18d19d474b` | `GuardInitialized(address,uint256)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0xd21d0b289f126c4b473ea641963e766833c2f13866e4ff480abd787c100ef123` | `ModuleInstalled(uint256,address)` |
| `0x341347516a9de374859dfda710fa4828b2d48cb57d4fbe4c1149612b8e02276e` | `ModuleUninstalled(uint256,address)` |
| `0xb532073b38c83145e3e5135377a08bf9aab55bc0fd7c1179cd4fb995d2a5159c` | `OwnerChanged(address,address)` |
| `0x2ab721df8af22606080fcc695d2c255bf7bfb356dbe68e84057a3e29678de3ec` | `P256GuardianAdded(uint8,bytes32,bytes32)` |
| `0x2e5ddc493d81d77b0b68b6603b29c467c94419656cea1684d2dce03f4bf321d6` | `P256KeySet(bytes32,bytes32)` |
| `0x977b07fd434a26f95f2850c9ba651937e650394c8cfb96e9ffba8e42cb5ac76d` | `ParserRegistrySet(address)` |
| `0x3e6e8da9cdbaf0d18a1123306c76e088d32bb5e76edabe32eaaa4ba7a50adb37` | `RecoveryApproved(address,address,uint256,uint8)` |
| `0xedd770ee01b7c0ef4f503125eafdc2725536cbf32342dffcaa300d95a7cafce3` | `RecoveryCancelled()` |
| `0x85d108740bb57aaf934ce63690f939704d2ce4cd099bc9c8ac11cd38db40392b` | `RecoveryCancelVoted(address,uint256,uint8)` |
| `0x60f9f98be64687700419cfa6fdd7877bc88c6daeb10bc664a2be9fdd6b0c7921` | `RecoveryExecuted(address,address)` |
| `0x201c40b4643e8b76c330a24e1a20d94dd5f798a3654180da40a29c00c18fe3b8` | `RecoveryProposed(address,address,uint8)` |
| `0xcfe045f2bad73057c49e23a745cb13c8b763723eeb93336c01c3bcb32cb1fc91` | `TierLimitsSet(uint256,uint256)` |
| `0x128d225533052ebf55fcccaa33435927c3530b794ac392f55bfda36e7d474543` | `ValidatorSet(address)` |
| `0x15f128f27bdfb175cfbe98c20eeca3038a9ee15470ec88a4fbd5a16a20a73267` | `WeightChangeApproved(address,uint256)` |
| `0x576deb2334d64aacc3de78fdc843b12c4601431d7d7546f8ef6ff413d18ad8e7` | `WeightChangeCancelled()` |
| `0xc94d426438944eb97ead040cba3930306dd959e6f9382bf215ad45427c03ecb6` | `WeightChangeExecuted((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |
| `0xba5c9da7994a2da6979c6d04d134da98d13c8cd4b70710bfc12400a72cb90072` | `WeightChangeProposed((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),address)` |
| `0x0c37cb722e39215324249ac820b21073307d8cf91ab4281713d68e95e9c7090a` | `WeightConfigUpdated((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |

### Errors

| selector | error |
|---|---|
| `0x71a31c27` | `AgentRegistrationFailed()` |
| `0xcf38f997` | `AgentSessionBatchNotSupported()` |
| `0x101f817a` | `AlreadyApproved()` |
| `0x0f5ff7bf` | `AlreadyCancelVoted()` |
| `0xa24a13a6` | `ArrayLengthMismatch()` |
| `0xa5fa8d2b` | `CallFailed(bytes)` |
| `0x9f081f40` | `CannotIncreaseTierLimit()` |
| `0xa27fbc63` | `DuplicateGuardianSig()` |
| `0x1e36aab2` | `DuplicateP256GuardianKey()` |
| `0xf645eedf` | `ECDSAInvalidSignature()` |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256)` |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32)` |
| `0x53682430` | `GuardianAlreadySet()` |
| `0x7abd948c` | `HookReverted()` |
| `0xe04a2600` | `IdentityRegistrationFailed()` |
| `0xa59a4151` | `InsecureWeightConfig()` |
| `0xdb5c22f4` | `InstallModuleUnauthorized()` |
| `0x16730a70` | `InsufficientGuardianApprovals()` |
| `0x4678a028` | `InsufficientTier(uint8,uint8)` |
| `0x4957e263` | `InsufficientWeight(uint8,uint8,uint8)` |
| `0xa6c1146b` | `InvalidGuardian()` |
| `0x07a81bc4` | `InvalidGuardianSignature()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0x2125deae` | `InvalidModuleType()` |
| `0x54a56786` | `InvalidNewOwner()` |
| `0x9b27bc53` | `InvalidP256GuardianKey()` |
| `0x275178f8` | `InvalidP256GuardianSignature(uint8)` |
| `0x2e14ce87` | `InvalidP256Key()` |
| `0x9100d347` | `InvalidTierConfig()` |
| `0xdfc3481a` | `MaxGuardiansReached()` |
| `0x36bf0fb2` | `MinGuardianRequired()` |
| `0x24c377e2` | `ModuleAlreadyInstalled()` |
| `0xf45e530b` | `ModuleInstallCallbackFailed(uint256,address)` |
| `0x74be437f` | `ModuleInvalid()` |
| `0x2a6f7929` | `ModuleNotInstalled()` |
| `0x8267d100` | `NoActiveRecovery()` |
| `0xd663742a` | `NotEntryPoint()` |
| `0xef6d0f02` | `NotGuardian()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x30cd7471` | `NotOwner()` |
| `0x50a222f4` | `NotOwnerOrEntryPoint()` |
| `0x1e142ec1` | `NoWeightChangeProposal()` |
| `0x6e5510ce` | `RecoveryAlreadyActive()` |
| `0x39d51cb2` | `RecoveryNotApproved()` |
| `0xaa40cfc6` | `RecoveryTimelockNotExpired()` |
| `0xab143c06` | `Reentrancy()` |
| `0xbc5e8e59` | `ReputationRegistryFailed()` |
| `0x3f041335` | `SessionScopeViolation()` |
| `0x54123466` | `TierLimitSigExpired()` |
| `0xf5b28a64` | `UnauthorizedRegistry()` |
| `0x63ce4efa` | `UnsupportedInnerSelector()` |
| `0x6cd89112` | `UseGuardianConsensus()` |
| `0x2157e2e7` | `ValidatorAlreadySet()` |
| `0x2e0ec5bc` | `WeakeningRequiresProposal()` |
| `0xf6b2ebb8` | `WeightChangeAlreadyApproved()` |
| `0xf0854cb8` | `WeightChangeNotApproved()` |
| `0xc30fc6f5` | `WeightChangePending()` |
| `0xac2edbf6` | `WeightChangeTimelockNotExpired()` |
| `0x16bf332d` | `WeightConfigNotInitialized()` |

## AAStarGlobalGuard

- **Source:** `src/core/AAStarGlobalGuard.sol`
- **Functions:** 16 · **Events:** 6 · **Errors:** 12
- **Title:** AAStarGlobalGuard — Immutable spending guard bound to an AA account
- Deployed BY the account contract at construction. Cannot be removed or transferred.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x5dab2420` | `account()` | view | — | The AA account that owns this guard (set at construction, never changes) |
| `0x332a0da9` | `addTokenConfig(address,(uint128,uint128,uint256))` | nonpayable | — | Add a new ERC20 token config. Monotonic: can only ADD, never remove.         Reverts if token is already configured. |
| `0x26ccb471` | `blockUnconfiguredTokens()` | view | — | #22 strict mode (opt-in, default OFF). When true, `recordTokenSpend` reverts on a         token that has NO config instead of passing it through with no limits. Lets an account         opt into a strict allowlist (only pre-configured tokens are spendable) for a higher         security posture, while the default-OFF behavior stays backward-compatible (new         airdrops / tokens added after account creation still pass through). |
| `0x67eeba0c` | `dailyLimit()` | view | — | Daily ETH spending limit in wei (0 = unlimited) |
| `0x387b9436` | `dailySpent(uint256)` | view | — | Tracks ETH spending per day (day number → amount spent) |
| `0x66683b61` | `decreaseDailyLimit(uint256)` | nonpayable | — | Decrease ETH daily limit. Can NEVER increase. Cannot go below minDailyLimit. |
| `0x1eadabce` | `decreaseTokenDailyLimit(address,uint256)` | nonpayable | — | Decrease a token's daily limit. Can NEVER increase.         Cannot decrease to 0 when tier limits are configured — that would break cumulative tracking. |
| `0xd0f1216f` | `minDailyLimit()` | view | — | Absolute floor — daily limit can never be decreased below this value. |
| `0x31159b41` | `recordSpend(uint256)` | nonpayable | — | Record an ETH spend and enforce the ETH daily limit. Pure accounting. |
| `0x6227c617` | `recordTokenSpend(address,uint256,uint8)` | nonpayable | — | Check if an ERC20 token transaction is allowed.         Enforces algorithm whitelist, token tier limits (cumulative), and token daily limit.         DESIGN: Guard is opt-in per token. Unconfigured tokens pass through with no limits.         Rationale: blocking all unconfigured tokens would prevent users from handling new         airdrops or tokens added after account creation. High-value tokens (USDC, USDT,         WETH, WBTC, aPNTs) are pre-configured at account creation via factory defaults.         #22: an opt-in "strict mode" flag (blockUnconfiguredTokens, default OFF) flips this         to an allowlist — when set, an unconfigured token reverts with TokenNotConfigured().         NOTE: Checks happen at execution, not validation (ERC-4337 constraint: validation         must be stateless; cumulative spend tracking requires state writes → must be exec).         Consequence: a blocked execution still consumes gas from the account's EP deposit.         This is standard ERC-4337 behavior, not specific to this implementation. |
| `0x39dcbd6f` | `remainingDailyAllowance()` | view | — | Query remaining ETH daily allowance |
| `0x86ef40c0` | `setStrictMode(bool)` | nonpayable | — | #22: enable/disable strict mode (block unconfigured tokens). Default OFF.         Only the bound account may call this (the account exposes an owner-gated wrapper). |
| `0x2a88a496` | `todaySpent()` | view | — | Query ETH spent today (for account's cumulative tier enforcement) |
| `0x1b69dc5f` | `tokenConfigs(address)` | view | — | Per-token tier and daily limit configuration |
| `0xc5ee9862` | `tokenDailySpent(address,uint256)` | view | — | Tracks token spending per day: token → day → amount spent |
| `0xf8618150` | `tokenTodaySpent(address)` | view | — | Query token spent today (for off-chain monitoring / dashboards) |

### Functions

#### `account()`

`0x5dab2420` · view · access: —

> The AA account that owns this guard (set at construction, never changes)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `addTokenConfig(address token, (uint128,uint128,uint256) config)`

`0x332a0da9` · nonpayable · access: —

> Add a new ERC20 token config. Monotonic: can only ADD, never remove.         Reverts if token is already configured.

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `config` | `(uint128,uint128,uint256)` |  |

#### `blockUnconfiguredTokens()`

`0x26ccb471` · view · access: —

> #22 strict mode (opt-in, default OFF). When true, `recordTokenSpend` reverts on a         token that has NO config instead of passing it through with no limits. Lets an account         opt into a strict allowlist (only pre-configured tokens are spendable) for a higher         security posture, while the default-OFF behavior stays backward-compatible (new         airdrops / tokens added after account creation still pass through).

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `dailyLimit()`

`0x67eeba0c` · view · access: —

> Daily ETH spending limit in wei (0 = unlimited)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `dailySpent(uint256 arg0)`

`0x387b9436` · view · access: —

> Tracks ETH spending per day (day number → amount spent)

| param | type | description |
|---|---|---|
| `arg0` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `decreaseDailyLimit(uint256 _newLimit)`

`0x66683b61` · nonpayable · access: —

> Decrease ETH daily limit. Can NEVER increase. Cannot go below minDailyLimit.

| param | type | description |
|---|---|---|
| `_newLimit` | `uint256` |  |

#### `decreaseTokenDailyLimit(address token, uint256 newLimit)`

`0x1eadabce` · nonpayable · access: —

> Decrease a token's daily limit. Can NEVER increase.         Cannot decrease to 0 when tier limits are configured — that would break cumulative tracking.

| param | type | description |
|---|---|---|
| `token` | `address` |  |
| `newLimit` | `uint256` |  |

#### `minDailyLimit()`

`0xd0f1216f` · view · access: —

> Absolute floor — daily limit can never be decreased below this value.

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `recordSpend(uint256 value)`

`0x31159b41` · nonpayable · access: —

> Record an ETH spend and enforce the ETH daily limit. Pure accounting.

*@dev* v0.17.2-beta.4: renamed from checkTransaction; the algorithm-whitelist check moved to      the account (enforced in validateUserOp). Tier enforcement is handled by the account      (reads todaySpent for the cumulative check). This function only meters the daily limit.

| param | type | description |
|---|---|---|
| `value` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `recordTokenSpend(address token, uint256 amount, uint8 algId)`

`0x6227c617` · nonpayable · access: —

> Check if an ERC20 token transaction is allowed.         Enforces algorithm whitelist, token tier limits (cumulative), and token daily limit.         DESIGN: Guard is opt-in per token. Unconfigured tokens pass through with no limits.         Rationale: blocking all unconfigured tokens would prevent users from handling new         airdrops or tokens added after account creation. High-value tokens (USDC, USDT,         WETH, WBTC, aPNTs) are pre-configured at account creation via factory defaults.         #22: an opt-in "strict mode" flag (blockUnconfiguredTokens, default OFF) flips this         to an allowlist — when set, an unconfigured token reverts with TokenNotConfigured().         NOTE: Checks happen at execution, not validation (ERC-4337 constraint: validation         must be stateless; cumulative spend tracking requires state writes → must be exec).         Consequence: a blocked execution still consumes gas from the account's EP deposit.         This is standard ERC-4337 behavior, not specific to this implementation.

*@dev* v0.17.2-beta.4: renamed from checkTokenTransaction; whitelist revert removed.

| param | type | description |
|---|---|---|
| `token` | `address` | ERC20 token contract address (= calldata dest) |
| `amount` | `uint256` | Token amount from parsed calldata (transfer/approve amount) |
| `algId` | `uint8` | Resolved algorithm tier input for cumulative token-tier math (NOT a whitelist                 check — the account already enforced the algorithm whitelist in validateUserOp). |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `remainingDailyAllowance()`

`0x39dcbd6f` · view · access: —

> Query remaining ETH daily allowance

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `setStrictMode(bool enabled)`

`0x86ef40c0` · nonpayable · access: —

> #22: enable/disable strict mode (block unconfigured tokens). Default OFF.         Only the bound account may call this (the account exposes an owner-gated wrapper).

| param | type | description |
|---|---|---|
| `enabled` | `bool` |  |

#### `todaySpent()`

`0x2a88a496` · view · access: —

> Query ETH spent today (for account's cumulative tier enforcement)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tokenConfigs(address arg0)`

`0x1b69dc5f` · view · access: —

> Per-token tier and daily limit configuration

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |

| returns | type | description |
|---|---|---|
| `tier1Limit` | `uint128` |  |
| `tier2Limit` | `uint128` |  |
| `dailyLimit` | `uint256` |  |

#### `tokenDailySpent(address arg0, uint256 arg1)`

`0xc5ee9862` · view · access: —

> Tracks token spending per day: token → day → amount spent

| param | type | description |
|---|---|---|
| `arg0` | `address` |  |
| `arg1` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tokenTodaySpent(address token)`

`0xf8618150` · view · access: —

> Query token spent today (for off-chain monitoring / dashboards)

| param | type | description |
|---|---|---|
| `token` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0xf5815a4e208c14f86faefba14ac3ebbfd5daa37a4d9ce3ce73ddf3fc5e97aca4` | `DailyLimitDecreased(uint256,uint256)` |
| `0xf963f384870dfbbabec85a70562ad3436b8bf2724843588d2fe72db42df2607f` | `SpendRecorded(uint256,uint256,uint256)` |
| `0x790efd28ff80a4aa071e4b37879d170d77321bd15b4c4c1f79085dd5930bf5dc` | `StrictModeSet(bool)` |
| `0x03a77b8c6329eff10fdac568960f268ba42d9fed2d82b3bca689a6b9875c0bf2` | `TokenConfigAdded(address,uint256,uint256,uint256)` |
| `0xf57c96b39ac1b62dc14fd2f7771c0b162be2177d35ceeef7ae969e664ffe0b50` | `TokenDailyLimitDecreased(address,uint256,uint256)` |
| `0x2a70682e83ca15beb889228127ae9150ee912cfc14183168af24b65eb591bc61` | `TokenSpendRecorded(address,uint256,uint256,uint256)` |

### Errors

| selector | error |
|---|---|
| `0x6c4fb8ff` | `BelowMinDailyLimit(uint256,uint256)` |
| `0x46ce6b5f` | `CanOnlyDecreaseLimit(uint256,uint256)` |
| `0xef664d6a` | `DailyLimitExceeded(uint256,uint256)` |
| `0x4e622dca` | `InsufficientTokenTier(uint8,uint8)` |
| `0x1e11b17d` | `InvalidTokenConfig(address,uint256,uint256,uint256)` |
| `0xf3f6425d` | `OnlyAccount()` |
| `0x886d7fb9` | `TierLimitTooLarge()` |
| `0x54d67cef` | `TokenAlreadyConfigured(address)` |
| `0x267f818e` | `TokenCanOnlyDecreaseLimit(address,uint256,uint256)` |
| `0xcc9741af` | `TokenConfigLengthMismatch()` |
| `0x7ef81e65` | `TokenDailyLimitExceeded(address,uint256,uint256)` |
| `0xec398688` | `TokenNotConfigured()` |

## AirAccountExtension

- **Source:** `src/core/AirAccountExtension.sol`
- **Functions:** 42 · **Events:** 25 · **Errors:** 56
- **Title:** AirAccountExtension — cold-function facet for AAStarAirAccountV7 (diamond-lite)
- Holds the cold, loosely-coupled functions that were split out of AAStarAirAccountBase         to keep the account under EIP-170's 24,576-byte runtime limit:           - ERC-8004 agent identity / reputation / wallet binding           - weighted-signature config governance (setWeightConfig + change proposal flow)         Deployed once (singleton) per implementation; the account reaches it via fallback +         delegatecall, so all logic runs in the ACCOUNT's storage/context: msg.sender,         address(this), owner, guardians, events and reverts are exactly as if inline.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xb5cb7bb8` | `activeRecovery()` | view | — | Active recovery proposal |
| `0x79e26729` | `addGuardianWithMixedSigs(address,uint8[],bytes[])` | nonpayable | onlyOwner | Add an ECDSA guardian with existing guardian consensus.         Requires RECOVERY_THRESHOLD valid guardian signatures. |
| `0x04f79674` | `addP256Guardian(bytes32,bytes32)` | nonpayable | onlyOwner | Add a P-256 (passkey) guardian — owner-only while fewer than RECOVERY_THRESHOLD         guardians exist (pre-consensus bootstrap; a single guardian cannot form a quorum).         Once RECOVERY_THRESHOLD guardians are set, call addP256GuardianWithMixedSigs instead. |
| `0xd99b0a36` | `addP256GuardianWithMixedSigs(bytes32,bytes32,uint8[],bytes[])` | nonpayable | onlyOwner | Add a P-256 (passkey) guardian with existing guardian consensus.         Requires RECOVERY_THRESHOLD valid guardian signatures so a stolen owner key         cannot expand the guardian set without the current guardians' approval. |
| `0x8450a928` | `approvedAlgorithms(uint8)` | view | — | Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4). |
| `0xfcae8d38` | `approveRecovery()` | nonpayable | — | An ECDSA guardian approves the active recovery proposal. |
| `0x47a90550` | `approveRecoveryWithSig(uint8,bytes)` | nonpayable | — | P-256 guardian approves an active recovery proposal. |
| `0xcc2b82d9` | `approveWeightChange()` | nonpayable | — | Guardian approves the pending weight-change proposal. |
| `0x67e3afe7` | `bindERC8004AgentWallet(address,uint256,address,uint256,bytes)` | nonpayable | onlyOwner, nonReentrant | Bind an execution wallet to an ERC-8004 agent identity NFT. |
| `0xb60295e1` | `cancelModuleInstall()` | nonpayable | — | Cancel the pending module-install proposal during the timelock window (issue #58 / KI-6). |
| `0x0ba234d6` | `cancelRecovery()` | nonpayable | — | An ECDSA guardian votes to cancel the active recovery. 2-of-3 threshold clears it. |
| `0x20617b94` | `cancelRecoveryWithSig(uint8,bytes)` | nonpayable | — | P-256 guardian votes to cancel an active recovery proposal. |
| `0x5f9613dd` | `cancelWeightChange()` | nonpayable | — | Cancel a pending weight-change proposal. Owner or any guardian can cancel. |
| `0xb0d691fe` | `entryPoint()` | view | — | The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility) |
| `0x4bc15d2b` | `executeModuleInstall(bytes)` | nonpayable | nonReentrant | Execute a matured module-install proposal (issue #58 / KI-6). |
| `0x20c5a3e1` | `executeRecovery()` | nonpayable | — | Execute recovery after timelock and threshold are met. Permissionless trigger. |
| `0x35905bb0` | `executeWeightChange()` | nonpayable | — | Execute an approved weight-change after timelock and threshold are met. |
| `0x43538f9c` | `getGuardianP256Key(uint8)` | view | — | Get the P-256 public key stored for a guardian slot (returns (0,0) if not a P-256 slot). |
| `0x7ceab3b1` | `guard()` | view | — | Global guard for spending limits (set at construction, cannot be removed) |
| `0x353f0860` | `mintAgentIdentity(address,string)` | nonpayable | onlyOwner, nonReentrant | Mint an ERC-8004 agent identity NFT to this AirAccount via the official registry. |
| `0x642c7989` | `modifyTierLimitsWithMixedGuardians(uint256,uint256,uint256,uint8[],bytes[])` | nonpayable | onlyOwner | Modify tier limits with mixed-type guardian signatures (ECDSA or P-256).         Required when at least one guardian is a P-256 type. |
| `0xc8175b3f` | `moduleInstallTimelock()` | view | — | Read the active module-install timelock (seconds). 0 = disabled (immediate installs). |
| `0x8da5cb5b` | `owner()` | view | — | Account owner and ECDSA signer (mutable for social recovery) |
| `0x863ee512` | `p256KeyX()` | view | — | P256 public key x-coordinate |
| `0xc4bb0566` | `p256KeyY()` | view | — | P256 public key y-coordinate |
| `0x56dc31d0` | `parserRegistry()` | view | — | Optional calldata parser registry for DeFi protocol support (address(0) = disabled) |
| `0x8dbbce84` | `pendingModuleInstall()` | view | — | Read the pending module-install proposal. proposedAt == 0 means none pending. |
| `0x7bea8f76` | `pendingWeightChange()` | view | — | Pending weight-change proposal (M6.2). proposedAt == 0 means none pending. |
| `0x9bbbb8ae` | `proposeModuleInstall(uint256,address,bytes)` | nonpayable | onlyOwnerOrEntryPoint | Propose a module install for the timelocked two-step flow (issue #58 / KI-6). |
| `0x7ee76082` | `proposeRecovery(address)` | nonpayable | — | An ECDSA guardian proposes a recovery. Any guardian may propose; auto-approves self. |
| `0x1110ac2e` | `proposeRecoveryWithSig(address,uint8,bytes)` | nonpayable | — | P-256 guardian proposes a recovery (any relayer can submit the pre-signed calldata). |
| `0x6b56c654` | `proposeWeightChange((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` | nonpayable | onlyOwner | Propose a weakening weight-config change (guardian-gated, M6.2). |
| `0xf9c391f6` | `queryAgentReputation(address,uint256,address[],string,string)` | view | — | Query aggregated reputation for an agent across a set of clients. |
| `0x8abb1c2a` | `removeGuardianWithMixedSigs(uint8,uint8[],bytes[])` | nonpayable | onlyOwner | Remove a guardian by index using mixed-type guardian signatures (ECDSA or P-256).         Required when at least one guardian is a P-256 type (which can't use the ECDSA-only path). |
| `0x293e07f2` | `setAgentWallet(uint256,address,address,bytes)` | nonpayable | onlyOwner | Link an agent wallet to this AirAccount by registering it in AgentRegistry. |
| `0xa5b915b5` | `setModuleInstallTimelock(uint256,bytes)` | nonpayable | onlyOwnerOrEntryPoint | Configure the optional module-install timelock (issue #58 / KI-6). |
| `0x10d47802` | `setWeightConfig((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` | nonpayable | onlyOwner | Set the weight configuration for algId 0x07. First-time: direct owner call.         Subsequent weakening changes require the guardian proposal flow (M6.2). |
| `0x6e795333` | `submitAgentReputation(address,uint256,int128,uint8,string,string,string,string,bytes32)` | nonpayable | onlyOwner, nonReentrant | Submit reputation feedback for an agent interaction via the official registry. |
| `0x8efdc881` | `tier1Limit()` | view | — | Tier1 max (ECDSA only) |
| `0xdbaf0cc3` | `tier2Limit()` | view | — | Tier2 max (dual factor); above this requires multi-sig (BLS triple) |
| `0x3a5381b5` | `validator()` | view | — | Optional validator router for external algorithms (BLS, PQ, etc.) |
| `0x085aa197` | `weightConfig()` | view | — | Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails. |

### Functions

#### `activeRecovery()`

`0xb5cb7bb8` · view · access: —

> Active recovery proposal

| returns | type | description |
|---|---|---|
| `newOwner` | `address` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |
| `cancellationBitmap` | `uint256` |  |

#### `addGuardianWithMixedSigs(address _guardian, uint8[] signerIdxs, bytes[] sigs)`

`0x79e26729` · nonpayable · access: onlyOwner

> Add an ECDSA guardian with existing guardian consensus.         Requires RECOVERY_THRESHOLD valid guardian signatures.

| param | type | description |
|---|---|---|
| `_guardian` | `address` |  |
| `signerIdxs` | `uint8[]` |  |
| `sigs` | `bytes[]` |  |

#### `addP256Guardian(bytes32 x, bytes32 y)`

`0x04f79674` · nonpayable · access: onlyOwner

> Add a P-256 (passkey) guardian — owner-only while fewer than RECOVERY_THRESHOLD         guardians exist (pre-consensus bootstrap; a single guardian cannot form a quorum).         Once RECOVERY_THRESHOLD guardians are set, call addP256GuardianWithMixedSigs instead.

| param | type | description |
|---|---|---|
| `x` | `bytes32` |  |
| `y` | `bytes32` |  |

#### `addP256GuardianWithMixedSigs(bytes32 x, bytes32 y, uint8[] signerIdxs, bytes[] sigs)`

`0xd99b0a36` · nonpayable · access: onlyOwner

> Add a P-256 (passkey) guardian with existing guardian consensus.         Requires RECOVERY_THRESHOLD valid guardian signatures so a stolen owner key         cannot expand the guardian set without the current guardians' approval.

| param | type | description |
|---|---|---|
| `x` | `bytes32` |  |
| `y` | `bytes32` |  |
| `signerIdxs` | `uint8[]` |  |
| `sigs` | `bytes[]` |  |

#### `approvedAlgorithms(uint8 arg0)`

`0x8450a928` · view · access: —

> Algorithm whitelist — SINGLE SOURCE OF TRUTH (v0.17.2-beta.4).

| param | type | description |
|---|---|---|
| `arg0` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `approveRecovery()`

`0xfcae8d38` · nonpayable · access: —

> An ECDSA guardian approves the active recovery proposal.

#### `approveRecoveryWithSig(uint8 gIdx, bytes sig)`

`0x47a90550` · nonpayable · access: —

> P-256 guardian approves an active recovery proposal.

| param | type | description |
|---|---|---|
| `gIdx` | `uint8` | Guardian slot index |
| `sig` | `bytes` | WebAuthn assertion blob authorizing this approval |

#### `approveWeightChange()`

`0xcc2b82d9` · nonpayable · access: —

> Guardian approves the pending weight-change proposal.

#### `bindERC8004AgentWallet(address identityRegistry, uint256 agentId, address agentWallet, uint256 deadline, bytes signature)`

`0x67e3afe7` · nonpayable · access: onlyOwner, nonReentrant

> Bind an execution wallet to an ERC-8004 agent identity NFT.

| param | type | description |
|---|---|---|
| `identityRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `agentWallet` | `address` |  |
| `deadline` | `uint256` |  |
| `signature` | `bytes` |  |

#### `cancelModuleInstall()`

`0xb60295e1` · nonpayable · access: —

> Cancel the pending module-install proposal during the timelock window (issue #58 / KI-6).

*@dev* Owner OR any single guardian may veto. The timelock exists precisely to let ANY other      stakeholder stop an install pushed through by a compromised owner+1-guardian pair, so a      single honest party must be able to cancel. This deliberately mirrors cancelWeightChange      (owner-or-any-guardian) rather than the 2-of-3 cancelRecovery: recovery's higher cancel bar      stops a lone compromised guardian from blocking legitimate recovery, but here easy      cancellation IS the defense, so the looser rule is the safer one.

#### `cancelRecovery()`

`0x0ba234d6` · nonpayable · access: —

> An ECDSA guardian votes to cancel the active recovery. 2-of-3 threshold clears it.

*@dev* Owner cannot cancel: a stolen owner key could otherwise block legitimate recovery.

#### `cancelRecoveryWithSig(uint8 gIdx, bytes sig)`

`0x20617b94` · nonpayable · access: —

> P-256 guardian votes to cancel an active recovery proposal.

| param | type | description |
|---|---|---|
| `gIdx` | `uint8` | Guardian slot index |
| `sig` | `bytes` | WebAuthn assertion blob authorizing this cancel vote |

#### `cancelWeightChange()`

`0x5f9613dd` · nonpayable · access: —

> Cancel a pending weight-change proposal. Owner or any guardian can cancel.

#### `entryPoint()`

`0xb0d691fe` · view · access: —

> The ERC-4337 EntryPoint contract (set once in initialize, not immutable for clone compatibility)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `executeModuleInstall(bytes moduleInitData)`

`0x4bc15d2b` · nonpayable · access: nonReentrant

> Execute a matured module-install proposal (issue #58 / KI-6).

*@dev* Permissionless (like executeRecovery) — authorization was captured at propose time and the      timelock window has elapsed. The caller must reproduce the exact module init data that was      proposed (its keccak256 must match the stored hash) so onInstall receives the authorized config.

| param | type | description |
|---|---|---|
| `moduleInitData` | `bytes` | The module init data committed at propose time. |

#### `executeRecovery()`

`0x20c5a3e1` · nonpayable · access: —

> Execute recovery after timelock and threshold are met. Permissionless trigger.

#### `executeWeightChange()`

`0x35905bb0` · nonpayable · access: —

> Execute an approved weight-change after timelock and threshold are met.

#### `getGuardianP256Key(uint8 index)`

`0x43538f9c` · view · access: —

> Get the P-256 public key stored for a guardian slot (returns (0,0) if not a P-256 slot).

| param | type | description |
|---|---|---|
| `index` | `uint8` |  |

| returns | type | description |
|---|---|---|
| `x` | `bytes32` |  |
| `y` | `bytes32` |  |

#### `guard()`

`0x7ceab3b1` · view · access: —

> Global guard for spending limits (set at construction, cannot be removed)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `mintAgentIdentity(address identityRegistry, string agentURI)`

`0x353f0860` · nonpayable · access: onlyOwner, nonReentrant

> Mint an ERC-8004 agent identity NFT to this AirAccount via the official registry.

| param | type | description |
|---|---|---|
| `identityRegistry` | `address` |  |
| `agentURI` | `string` |  |

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `modifyTierLimitsWithMixedGuardians(uint256 _tier1, uint256 _tier2, uint256 deadline, uint8[] signerIdxs, bytes[] sigs)`

`0x642c7989` · nonpayable · access: onlyOwner

> Modify tier limits with mixed-type guardian signatures (ECDSA or P-256).         Required when at least one guardian is a P-256 type.

| param | type | description |
|---|---|---|
| `_tier1` | `uint256` |  |
| `_tier2` | `uint256` |  |
| `deadline` | `uint256` |  |
| `signerIdxs` | `uint8[]` | Guardian slot indices corresponding to each signature |
| `sigs` | `bytes[]` | Signatures: 65-byte (r\|\|s\|\|v) eth-signed sig for ECDSA; for P-256 the WebAuthn                   assertion blob abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s) |

#### `moduleInstallTimelock()`

`0xc8175b3f` · view · access: —

> Read the active module-install timelock (seconds). 0 = disabled (immediate installs).

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `owner()`

`0x8da5cb5b` · view · access: —

> Account owner and ECDSA signer (mutable for social recovery)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `p256KeyX()`

`0x863ee512` · view · access: —

> P256 public key x-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `p256KeyY()`

`0xc4bb0566` · view · access: —

> P256 public key y-coordinate

| returns | type | description |
|---|---|---|
| `_0` | `bytes32` |  |

#### `parserRegistry()`

`0x56dc31d0` · view · access: —

> Optional calldata parser registry for DeFi protocol support (address(0) = disabled)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `pendingModuleInstall()`

`0x8dbbce84` · view · access: —

> Read the pending module-install proposal. proposedAt == 0 means none pending.

| returns | type | description |
|---|---|---|
| `module` | `address` | Module contract pending install. |
| `moduleTypeId` | `uint8` | 1=validator, 2=executor, 4=hook. |
| `proposedAt` | `uint40` | Timestamp the proposal was created. |
| `executeAfter` | `uint40` | Fixed timestamp from which the proposal may be executed (immutable once set). |
| `initDataHash` | `bytes32` | keccak256 of the committed module init data. |

#### `pendingWeightChange()`

`0x7bea8f76` · view · access: —

> Pending weight-change proposal (M6.2). proposedAt == 0 means none pending.

| returns | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |
| `proposedAt` | `uint256` |  |
| `approvalBitmap` | `uint256` |  |

#### `proposeModuleInstall(uint256 moduleTypeId, address module, bytes initData)`

`0x9bbbb8ae` · nonpayable · access: onlyOwnerOrEntryPoint

> Propose a module install for the timelocked two-step flow (issue #58 / KI-6).

*@dev* Only valid when the timelock is enabled. Requires the SAME authorization as a normal      install at the configured threshold (owner + N guardian sigs); the guardian signature is      consumed via the module-management nonce so it cannot be replayed. After the timelock      elapses anyone may call executeModuleInstall; meanwhile owner or any guardian may cancel.

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` | 1=validator, 2=executor, 4=hook. |
| `module` | `address` | Module contract address (must be deployed). |
| `initData` | `bytes` | Layout: guardian sig(s) prepended (per configured threshold), then module init data.        Sig hash: _guardianOpHash("INSTALL_MODULE", abi.encode(moduleTypeId, module, keccak256(moduleInitData), moduleManagementNonce)). |

#### `proposeRecovery(address newOwner)`

`0x7ee76082` · nonpayable · access: —

> An ECDSA guardian proposes a recovery. Any guardian may propose; auto-approves self.

| param | type | description |
|---|---|---|
| `newOwner` | `address` |  |

#### `proposeRecoveryWithSig(address newOwner, uint8 gIdx, bytes sig)`

`0x1110ac2e` · nonpayable · access: —

> P-256 guardian proposes a recovery (any relayer can submit the pre-signed calldata).

| param | type | description |
|---|---|---|
| `newOwner` | `address` | Target owner address after recovery |
| `gIdx` | `uint8` | Guardian slot index (0/1/2) |
| `sig` | `bytes` | WebAuthn assertion blob authorizing this proposal |

#### `proposeWeightChange((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8) proposed)`

`0x6b56c654` · nonpayable · access: onlyOwner

> Propose a weakening weight-config change (guardian-gated, M6.2).

| param | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |

#### `queryAgentReputation(address reputationRegistry, uint256 agentId, address[] clientAddresses, string tag1, string tag2)`

`0xf9c391f6` · view · access: —

> Query aggregated reputation for an agent across a set of clients.

| param | type | description |
|---|---|---|
| `reputationRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `clientAddresses` | `address[]` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |
| `summaryValue` | `int128` |  |
| `summaryDecimals` | `uint8` |  |

#### `removeGuardianWithMixedSigs(uint8 index, uint8[] signerIdxs, bytes[] sigs)`

`0x8abb1c2a` · nonpayable · access: onlyOwner

> Remove a guardian by index using mixed-type guardian signatures (ECDSA or P-256).         Required when at least one guardian is a P-256 type (which can't use the ECDSA-only path).

| param | type | description |
|---|---|---|
| `index` | `uint8` | Slot to remove (0-indexed) |
| `signerIdxs` | `uint8[]` | Guardian slot indices corresponding to each signature |
| `sigs` | `bytes[]` | Signatures: 65-byte (r\|\|s\|\|v) eth-signed sig for ECDSA guardians; for P-256                   guardians the WebAuthn assertion blob                   abi.encode(authenticatorData, clientDataJSONPrefix, clientDataJSONSuffix, r, s) |

#### `setAgentWallet(uint256 agentId, address agentWallet, address agentRegistry, bytes agentWalletSig)`

`0x293e07f2` · nonpayable · access: onlyOwner

> Link an agent wallet to this AirAccount by registering it in AgentRegistry.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `agentWallet` | `address` |  |
| `agentRegistry` | `address` |  |
| `agentWalletSig` | `bytes` |  |

#### `setModuleInstallTimelock(uint256 newTimelock, bytes guardianSigs)`

`0xa5b915b5` · nonpayable · access: onlyOwnerOrEntryPoint

> Configure the optional module-install timelock (issue #58 / KI-6).

*@dev* Strengthening (increasing, or first-time set) is a direct owner action. Weakening      (reducing or disabling → 0) requires the SAME elevated owner+2-guardian consensus as the      immediate-install bypass, so a compromised owner+1-guardian pair cannot silently switch      the protection off and then install instantly. On accounts with fewer than 2 guardians the      weakening bar degrades to all available guardians (mirrors uninstallModule's min(count,2)),      so the timelock can never become permanently un-removable.

| param | type | description |
|---|---|---|
| `newTimelock` | `uint256` | New timelock in seconds (0 disables). Capped at MAX_MODULE_INSTALL_TIMELOCK        (30 days); larger values revert ModuleInstallTimelockTooLong. |
| `guardianSigs` | `bytes` | Concatenated 65-byte guardian sigs over        _guardianOpHash("SET_MODULE_TIMELOCK", abi.encode(newTimelock, moduleManagementNonce)).        Ignored (may be empty) when strengthening. |

#### `setWeightConfig((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8) config)`

`0x10d47802` · nonpayable · access: onlyOwner

> Set the weight configuration for algId 0x07. First-time: direct owner call.         Subsequent weakening changes require the guardian proposal flow (M6.2).

| param | type | description |
|---|---|---|
| `config` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |

#### `submitAgentReputation(address reputationRegistry, uint256 agentId, int128 value, uint8 valueDecimals, string tag1, string tag2, string endpoint, string feedbackURI, bytes32 feedbackHash)`

`0x6e795333` · nonpayable · access: onlyOwner, nonReentrant

> Submit reputation feedback for an agent interaction via the official registry.

| param | type | description |
|---|---|---|
| `reputationRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `value` | `int128` |  |
| `valueDecimals` | `uint8` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |
| `endpoint` | `string` |  |
| `feedbackURI` | `string` |  |
| `feedbackHash` | `bytes32` |  |

#### `tier1Limit()`

`0x8efdc881` · view · access: —

> Tier1 max (ECDSA only)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `tier2Limit()`

`0xdbaf0cc3` · view · access: —

> Tier2 max (dual factor); above this requires multi-sig (BLS triple)

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `validator()`

`0x3a5381b5` · view · access: —

> Optional validator router for external algorithms (BLS, PQ, etc.)

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `weightConfig()`

`0x085aa197` · view · access: —

> Current weight config. tier1Threshold == 0 means uninitialised → ALG_WEIGHTED fails.

| returns | type | description |
|---|---|---|
| `passkeyWeight` | `uint8` |  |
| `ecdsaWeight` | `uint8` |  |
| `blsWeight` | `uint8` |  |
| `guardian0Weight` | `uint8` |  |
| `guardian1Weight` | `uint8` |  |
| `guardian2Weight` | `uint8` |  |
| `_padding` | `uint8` |  |
| `tier1Threshold` | `uint8` |  |
| `tier2Threshold` | `uint8` |  |
| `tier3Threshold` | `uint8` |  |

### Events

| topic0 | event |
|---|---|
| `0x169142414aeecec3d3dfa03ef8b7d72d56023ead068694f563affe4276792bed` | `AgentIdentityMinted(uint256,address,string)` |
| `0xee0112c63253e47e4ff7403776240bef35d82b6feba08ea6ecb20f8a4ab75e92` | `AgentReputationSubmitted(uint256,address,int128,string)` |
| `0xc8982c1ad4646a1ed6bb40061ac7f2a6aaffef7f2e096aa9805cf705fa12933b` | `AgentWalletSet(uint256,address,address)` |
| `0xaadd69bae4c5060e9be224899997360e78e4ee632c9951aa0055eeeb5bfc6662` | `ERC8004WalletBound(uint256,address,address)` |
| `0xeca9cd482b52ddd909a1a2ffcceae1b6dd76b5491ec997d8d9ac05c6426fa344` | `GuardianAdded(uint8,address)` |
| `0x21d14a63615c145863fb5004c412ccf4ba2439b31bfd93baf5892142417ae5bf` | `GuardianRemoved(uint8,address)` |
| `0xc7f505b2f371ae2175ee4913f4499e1f2633a7b5936321eed1cdaeb6115181d2` | `Initialized(uint64)` |
| `0xfc129a9cf9c86292bfb325ad90f24fea23449a3870fdaa024bbfbf1afdf3db31` | `ModuleInstallCancelled(uint256,address,address)` |
| `0xd21d0b289f126c4b473ea641963e766833c2f13866e4ff480abd787c100ef123` | `ModuleInstalled(uint256,address)` |
| `0xcb23826c065976de3d72ab586bb16e6910ad23028abf0885a015fa54face86b3` | `ModuleInstallExecuted(uint256,address)` |
| `0x961131cbbaf1bc03ad2365a2fb7e266c712005e704c38832cfb7a3014a3580fb` | `ModuleInstallProposed(uint256,address,uint256)` |
| `0x27db7bd98a100c6f2a3ebfce33cb9dd05ee5a152452bd211e8535ac2becb861a` | `ModuleInstallTimelockChanged(uint256,uint256)` |
| `0xb532073b38c83145e3e5135377a08bf9aab55bc0fd7c1179cd4fb995d2a5159c` | `OwnerChanged(address,address)` |
| `0x2ab721df8af22606080fcc695d2c255bf7bfb356dbe68e84057a3e29678de3ec` | `P256GuardianAdded(uint8,bytes32,bytes32)` |
| `0x3e6e8da9cdbaf0d18a1123306c76e088d32bb5e76edabe32eaaa4ba7a50adb37` | `RecoveryApproved(address,address,uint256,uint8)` |
| `0xedd770ee01b7c0ef4f503125eafdc2725536cbf32342dffcaa300d95a7cafce3` | `RecoveryCancelled()` |
| `0x85d108740bb57aaf934ce63690f939704d2ce4cd099bc9c8ac11cd38db40392b` | `RecoveryCancelVoted(address,uint256,uint8)` |
| `0x60f9f98be64687700419cfa6fdd7877bc88c6daeb10bc664a2be9fdd6b0c7921` | `RecoveryExecuted(address,address)` |
| `0x201c40b4643e8b76c330a24e1a20d94dd5f798a3654180da40a29c00c18fe3b8` | `RecoveryProposed(address,address,uint8)` |
| `0xcfe045f2bad73057c49e23a745cb13c8b763723eeb93336c01c3bcb32cb1fc91` | `TierLimitsSet(uint256,uint256)` |
| `0x15f128f27bdfb175cfbe98c20eeca3038a9ee15470ec88a4fbd5a16a20a73267` | `WeightChangeApproved(address,uint256)` |
| `0x576deb2334d64aacc3de78fdc843b12c4601431d7d7546f8ef6ff413d18ad8e7` | `WeightChangeCancelled()` |
| `0xc94d426438944eb97ead040cba3930306dd959e6f9382bf215ad45427c03ecb6` | `WeightChangeExecuted((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |
| `0xba5c9da7994a2da6979c6d04d134da98d13c8cd4b70710bfc12400a72cb90072` | `WeightChangeProposed((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8),address)` |
| `0x0c37cb722e39215324249ac820b21073307d8cf91ab4281713d68e95e9c7090a` | `WeightConfigUpdated((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` |

### Errors

| selector | error |
|---|---|
| `0x71a31c27` | `AgentRegistrationFailed()` |
| `0x101f817a` | `AlreadyApproved()` |
| `0x0f5ff7bf` | `AlreadyCancelVoted()` |
| `0x9f081f40` | `CannotIncreaseTierLimit()` |
| `0xa27fbc63` | `DuplicateGuardianSig()` |
| `0x1e36aab2` | `DuplicateP256GuardianKey()` |
| `0xf645eedf` | `ECDSAInvalidSignature()` |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256)` |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32)` |
| `0x53682430` | `GuardianAlreadySet()` |
| `0xe04a2600` | `IdentityRegistrationFailed()` |
| `0xa59a4151` | `InsecureWeightConfig()` |
| `0xdb5c22f4` | `InstallModuleUnauthorized()` |
| `0x16730a70` | `InsufficientGuardianApprovals()` |
| `0xfc934792` | `InvalidAuthenticatorData()` |
| `0xa6c1146b` | `InvalidGuardian()` |
| `0x07a81bc4` | `InvalidGuardianSignature()` |
| `0xf92ee8a9` | `InvalidInitialization()` |
| `0x2125deae` | `InvalidModuleType()` |
| `0x54a56786` | `InvalidNewOwner()` |
| `0x9b27bc53` | `InvalidP256GuardianKey()` |
| `0x275178f8` | `InvalidP256GuardianSignature(uint8)` |
| `0x9100d347` | `InvalidTierConfig()` |
| `0xdfc3481a` | `MaxGuardiansReached()` |
| `0x36bf0fb2` | `MinGuardianRequired()` |
| `0x24c377e2` | `ModuleAlreadyInstalled()` |
| `0xe8e195da` | `ModuleInstallAuthChanged()` |
| `0xf45e530b` | `ModuleInstallCallbackFailed(uint256,address)` |
| `0x253ee849` | `ModuleInstallDataMismatch()` |
| `0xbb849f5a` | `ModuleInstallProposalExists()` |
| `0x33afc34b` | `ModuleInstallProposalExpired()` |
| `0x1bce553b` | `ModuleInstallTimelockDisabled()` |
| `0xce1d6b48` | `ModuleInstallTimelockNotExpired()` |
| `0xfb3e466e` | `ModuleInstallTimelockTooLong()` |
| `0x74be437f` | `ModuleInvalid()` |
| `0x8267d100` | `NoActiveRecovery()` |
| `0x69cc141f` | `NoModuleInstallProposal()` |
| `0xef6d0f02` | `NotGuardian()` |
| `0xd7e6bcf8` | `NotInitializing()` |
| `0x30cd7471` | `NotOwner()` |
| `0x50a222f4` | `NotOwnerOrEntryPoint()` |
| `0x1e142ec1` | `NoWeightChangeProposal()` |
| `0x6e5510ce` | `RecoveryAlreadyActive()` |
| `0xab4e316d` | `RecoveryAlreadyProposed()` |
| `0x39d51cb2` | `RecoveryNotApproved()` |
| `0xaa40cfc6` | `RecoveryTimelockNotExpired()` |
| `0xab143c06` | `Reentrancy()` |
| `0x54123466` | `TierLimitSigExpired()` |
| `0xf5b28a64` | `UnauthorizedRegistry()` |
| `0xc3a55c98` | `UnsupportedChain(uint256)` |
| `0x6cd89112` | `UseGuardianConsensus()` |
| `0x2e0ec5bc` | `WeakeningRequiresProposal()` |
| `0xf6b2ebb8` | `WeightChangeAlreadyApproved()` |
| `0xf0854cb8` | `WeightChangeNotApproved()` |
| `0xc30fc6f5` | `WeightChangePending()` |
| `0xac2edbf6` | `WeightChangeTimelockNotExpired()` |

## IAAStarAlgorithm

- **Source:** `src/interfaces/IAAStarAlgorithm.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0
- **Title:** IAAStarAlgorithm - Interface for signature algorithm implementations
- Each algorithm (BLS, PQ, etc.) implements this interface

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x65a8613c` | `validate(bytes32,bytes)` | view | — |  |

### Functions

#### `validate(bytes32 userOpHash, bytes signature)`

`0x65a8613c` · view · access: —

*@dev* Validate a signature using this algorithm

| param | type | description |
|---|---|---|
| `userOpHash` | `bytes32` | The hash of the UserOperation |
| `signature` | `bytes` | The algorithm-specific signature data (algId prefix already stripped) |

| returns | type | description |
|---|---|---|
| `validationData` | `uint256` | 0 for success, 1 for failure |

## IAAStarValidator

- **Source:** `src/interfaces/IAAStarValidator.sol`
- **Functions:** 2 · **Events:** 0 · **Errors:** 0
- **Title:** IAAStarValidator - Generic algorithm router interface
- Routes signature validation to algorithm-specific implementations

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xacfff8f6` | `getAlgorithm(uint8)` | view | — |  |
| `0x333daf92` | `validateSignature(bytes32,bytes)` | view | — |  |

### Functions

#### `getAlgorithm(uint8 algId)`

`0xacfff8f6` · view · access: —

*@dev* Check if an algorithm is registered

| param | type | description |
|---|---|---|
| `algId` | `uint8` | The algorithm identifier |

| returns | type | description |
|---|---|---|
| `_0` | `address` | The address of the algorithm implementation (address(0) if not registered) |

#### `validateSignature(bytes32 userOpHash, bytes signature)`

`0x333daf92` · view · access: —

*@dev* Validate a signature by routing to the appropriate algorithm

| param | type | description |
|---|---|---|
| `userOpHash` | `bytes32` | The hash of the UserOperation |
| `signature` | `bytes` | The signature to validate (sig[0] = algId) |

| returns | type | description |
|---|---|---|
| `validationData` | `uint256` | 0 for success, 1 for failure |

## IAirAccountAgent

- **Source:** `src/interfaces/IAirAccountAgent.sol`
- **Functions:** 16 · **Events:** 0 · **Errors:** 0
- **Title:** IAirAccountAgent
- ABI surface for the cold functions that AAStarAirAccountV7 routes to the singleton         AirAccountExtension via fallback + delegatecall (diamond-lite): ERC-8004 agent         identity/reputation and weighted-signature config governance.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xcc2b82d9` | `approveWeightChange()` | nonpayable | — |  |
| `0x67e3afe7` | `bindERC8004AgentWallet(address,uint256,address,uint256,bytes)` | nonpayable | — |  |
| `0xb60295e1` | `cancelModuleInstall()` | nonpayable | — |  |
| `0x5f9613dd` | `cancelWeightChange()` | nonpayable | — |  |
| `0x4bc15d2b` | `executeModuleInstall(bytes)` | nonpayable | — |  |
| `0x35905bb0` | `executeWeightChange()` | nonpayable | — |  |
| `0x353f0860` | `mintAgentIdentity(address,string)` | nonpayable | — |  |
| `0xc8175b3f` | `moduleInstallTimelock()` | view | — |  |
| `0x8dbbce84` | `pendingModuleInstall()` | view | — |  |
| `0x9bbbb8ae` | `proposeModuleInstall(uint256,address,bytes)` | nonpayable | — |  |
| `0x6b56c654` | `proposeWeightChange((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` | nonpayable | — |  |
| `0xf9c391f6` | `queryAgentReputation(address,uint256,address[],string,string)` | view | — |  |
| `0x293e07f2` | `setAgentWallet(uint256,address,address,bytes)` | nonpayable | — |  |
| `0xa5b915b5` | `setModuleInstallTimelock(uint256,bytes)` | nonpayable | — |  |
| `0x10d47802` | `setWeightConfig((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8))` | nonpayable | — |  |
| `0x6e795333` | `submitAgentReputation(address,uint256,int128,uint8,string,string,string,string,bytes32)` | nonpayable | — |  |

### Functions

#### `approveWeightChange()`

`0xcc2b82d9` · nonpayable · access: —

#### `bindERC8004AgentWallet(address identityRegistry, uint256 agentId, address agentWallet, uint256 deadline, bytes signature)`

`0x67e3afe7` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `identityRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `agentWallet` | `address` |  |
| `deadline` | `uint256` |  |
| `signature` | `bytes` |  |

#### `cancelModuleInstall()`

`0xb60295e1` · nonpayable · access: —

#### `cancelWeightChange()`

`0x5f9613dd` · nonpayable · access: —

#### `executeModuleInstall(bytes moduleInitData)`

`0x4bc15d2b` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `moduleInitData` | `bytes` |  |

#### `executeWeightChange()`

`0x35905bb0` · nonpayable · access: —

#### `mintAgentIdentity(address identityRegistry, string agentURI)`

`0x353f0860` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `identityRegistry` | `address` |  |
| `agentURI` | `string` |  |

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `moduleInstallTimelock()`

`0xc8175b3f` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `uint256` |  |

#### `pendingModuleInstall()`

`0x8dbbce84` · view · access: —

| returns | type | description |
|---|---|---|
| `module` | `address` |  |
| `moduleTypeId` | `uint8` |  |
| `proposedAt` | `uint40` |  |
| `executeAfter` | `uint40` |  |
| `initDataHash` | `bytes32` |  |

#### `proposeModuleInstall(uint256 moduleTypeId, address module, bytes initData)`

`0x9bbbb8ae` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `moduleTypeId` | `uint256` |  |
| `module` | `address` |  |
| `initData` | `bytes` |  |

#### `proposeWeightChange((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8) proposed)`

`0x6b56c654` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `proposed` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |

#### `queryAgentReputation(address reputationRegistry, uint256 agentId, address[] clientAddresses, string tag1, string tag2)`

`0xf9c391f6` · view · access: —

| param | type | description |
|---|---|---|
| `reputationRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `clientAddresses` | `address[]` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |
| `summaryValue` | `int128` |  |
| `summaryDecimals` | `uint8` |  |

#### `setAgentWallet(uint256 agentId, address agentWallet, address agentRegistry, bytes agentWalletSig)`

`0x293e07f2` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `agentWallet` | `address` |  |
| `agentRegistry` | `address` |  |
| `agentWalletSig` | `bytes` |  |

#### `setModuleInstallTimelock(uint256 newTimelock, bytes guardianSigs)`

`0xa5b915b5` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `newTimelock` | `uint256` |  |
| `guardianSigs` | `bytes` |  |

#### `setWeightConfig((uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8) config)`

`0x10d47802` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `config` | `(uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8)` |  |

#### `submitAgentReputation(address reputationRegistry, uint256 agentId, int128 value, uint8 valueDecimals, string tag1, string tag2, string endpoint, string feedbackURI, bytes32 feedbackHash)`

`0x6e795333` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `reputationRegistry` | `address` |  |
| `agentId` | `uint256` |  |
| `value` | `int128` |  |
| `valueDecimals` | `uint8` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |
| `endpoint` | `string` |  |
| `feedbackURI` | `string` |  |
| `feedbackHash` | `bytes32` |  |

## ICalldataParser

- **Source:** `src/interfaces/ICalldataParser.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x94ddedee` | `parseTokenTransfer(bytes)` | pure | — | Parse calldata to extract the effective token address and spend amount. |

### Functions

#### `parseTokenTransfer(bytes data)`

`0x94ddedee` · pure · access: —

> Parse calldata to extract the effective token address and spend amount.

| param | type | description |
|---|---|---|
| `data` | `bytes` | Full calldata of the external call (includes 4-byte selector) |

| returns | type | description |
|---|---|---|
| `token` | `address` | ERC20 token address being spent (address(0) = not applicable) |
| `amount` | `uint256` | Amount of token being spent in token native units (0 = not applicable) |

## ICalldataParserRegistry

- **Source:** `src/interfaces/ICalldataParser.sol`
- **Functions:** 1 · **Events:** 0 · **Errors:** 0
- **Title:** ICalldataParser — Interface for DeFi protocol calldata interpretersICalldataParserRegistry — Registry mapping protocol contracts to their calldata parsers
- Implemented by protocol-specific parsers that extract the effective         token address and amount from complex protocol calldata.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x280973a2` | `getParser(address)` | view | — | Get the calldata parser for a given protocol contract address. |

### Functions

#### `getParser(address token)`

`0x280973a2` · view · access: —

> Get the calldata parser for a given protocol contract address.

| param | type | description |
|---|---|---|
| `token` | `address` | Protocol/contract address (e.g., Uniswap router) |

| returns | type | description |
|---|---|---|
| `_0` | `address` | Parser contract address, or address(0) if not registered |

## IERC8004IdentityRegistry

- **Source:** `src/interfaces/IERC8004IdentityRegistry.sol`
- **Functions:** 21 · **Events:** 6 · **Errors:** 0
- **Title:** IERC8004IdentityRegistry — ERC-8004 "Trustless Agents" Identity Registry
- Interface matching the official ERC-8004 IdentityRegistryUpgradeable deployed on all chains.         Agents register as ERC-721 NFTs; owning the NFT = owning that agent identity.         Each identity can bind one `agentWallet` via EIP-712-signed `setAgentWallet()`.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0x095ea7b3` | `approve(address,uint256)` | nonpayable | — |  |
| `0x70a08231` | `balanceOf(address)` | view | — |  |
| `0x00339509` | `getAgentWallet(uint256)` | view | — | Returns the wallet currently bound to this agent identity. |
| `0x081812fc` | `getApproved(uint256)` | view | — |  |
| `0xcb4799f2` | `getMetadata(uint256,string)` | view | — |  |
| `0x0d8e6e2c` | `getVersion()` | pure | — |  |
| `0xe985e9c5` | `isApprovedForAll(address,address)` | view | — |  |
| `0xd95e72be` | `isAuthorizedOrOwner(address,uint256)` | view | — |  |
| `0x6352211e` | `ownerOf(uint256)` | view | — |  |
| `0x1aa3a008` | `register()` | nonpayable | — | Register an agent with no URI (agentWallet defaults to msg.sender). |
| `0x8ea42286` | `register(string,(string,bytes)[])` | nonpayable | — | Register an agent with URI and additional metadata entries. |
| `0xf2c298be` | `register(string)` | nonpayable | — | Register an agent with a metadata URI (agentWallet defaults to msg.sender). |
| `0xb88d4fde` | `safeTransferFrom(address,address,uint256,bytes)` | nonpayable | — |  |
| `0x42842e0e` | `safeTransferFrom(address,address,uint256)` | nonpayable | — |  |
| `0x0af28bd3` | `setAgentURI(uint256,string)` | nonpayable | — |  |
| `0x2d1ef5ae` | `setAgentWallet(uint256,address,uint256,bytes)` | nonpayable | — | Link a wallet address to this agent identity. |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | nonpayable | — |  |
| `0x466648da` | `setMetadata(uint256,string,bytes)` | nonpayable | — |  |
| `0x01ffc9a7` | `supportsInterface(bytes4)` | view | — |  |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | nonpayable | — |  |
| `0x3fddcf19` | `unsetAgentWallet(uint256)` | nonpayable | — | Clear the wallet binding for this agent identity. |

### Functions

#### `approve(address to, uint256 tokenId)`

`0x095ea7b3` · nonpayable · access: —

*@dev* Gives permission to `to` to transfer `tokenId` token to another account. The approval is cleared when the token is transferred. Only a single account can be approved at a time, so approving the zero address clears previous approvals. Requirements: - The caller must own the token or be an approved operator. - `tokenId` must exist. Emits an {Approval} event.

| param | type | description |
|---|---|---|
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `balanceOf(address owner)`

`0x70a08231` · view · access: —

*@dev* Returns the number of tokens in ``owner``'s account.

| param | type | description |
|---|---|---|
| `owner` | `address` |  |

| returns | type | description |
|---|---|---|
| `balance` | `uint256` |  |

#### `getAgentWallet(uint256 agentId)`

`0x00339509` · view · access: —

> Returns the wallet currently bound to this agent identity.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getApproved(uint256 tokenId)`

`0x081812fc` · view · access: —

*@dev* Returns the account approved for `tokenId` token. Requirements: - `tokenId` must exist.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `operator` | `address` |  |

#### `getMetadata(uint256 agentId, string metadataKey)`

`0xcb4799f2` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `metadataKey` | `string` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bytes` |  |

#### `getVersion()`

`0x0d8e6e2c` · pure · access: —

| returns | type | description |
|---|---|---|
| `_0` | `string` |  |

#### `isApprovedForAll(address owner, address operator)`

`0xe985e9c5` · view · access: —

*@dev* Returns if the `operator` is allowed to manage all of the assets of `owner`. See {setApprovalForAll}

| param | type | description |
|---|---|---|
| `owner` | `address` |  |
| `operator` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `isAuthorizedOrOwner(address spender, uint256 agentId)`

`0xd95e72be` · view · access: —

| param | type | description |
|---|---|---|
| `spender` | `address` |  |
| `agentId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `ownerOf(uint256 tokenId)`

`0x6352211e` · view · access: —

*@dev* Returns the owner of the `tokenId` token. Requirements: - `tokenId` must exist.

| param | type | description |
|---|---|---|
| `tokenId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `owner` | `address` |  |

#### `register()`

`0x1aa3a008` · nonpayable · access: —

> Register an agent with no URI (agentWallet defaults to msg.sender).

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `register(string agentURI, (string,bytes)[] metadata)`

`0x8ea42286` · nonpayable · access: —

> Register an agent with URI and additional metadata entries.

| param | type | description |
|---|---|---|
| `agentURI` | `string` |  |
| `metadata` | `(string,bytes)[]` |  |

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `register(string agentURI)`

`0xf2c298be` · nonpayable · access: —

> Register an agent with a metadata URI (agentWallet defaults to msg.sender).

| param | type | description |
|---|---|---|
| `agentURI` | `string` |  |

| returns | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId, bytes data)`

`0xb88d4fde` · nonpayable · access: —

*@dev* Safely transfers `tokenId` token from `from` to `to`. Requirements: - `from` cannot be the zero address. - `to` cannot be the zero address. - `tokenId` token must exist and be owned by `from`. - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}. - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon   a safe transfer. Emits a {Transfer} event.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |
| `data` | `bytes` |  |

#### `safeTransferFrom(address from, address to, uint256 tokenId)`

`0x42842e0e` · nonpayable · access: —

*@dev* Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients are aware of the ERC-721 protocol to prevent tokens from being forever locked. Requirements: - `from` cannot be the zero address. - `to` cannot be the zero address. - `tokenId` token must exist and be owned by `from`. - If the caller is not `from`, it must have been allowed to move this token by either {approve} or   {setApprovalForAll}. - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon   a safe transfer. Emits a {Transfer} event.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `setAgentURI(uint256 agentId, string newURI)`

`0x0af28bd3` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `newURI` | `string` |  |

#### `setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes signature)`

`0x2d1ef5ae` · nonpayable · access: —

> Link a wallet address to this agent identity.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` | The agent NFT token ID. |
| `newWallet` | `address` | Address of the execution wallet (EOA or smart contract). |
| `deadline` | `uint256` | Unix timestamp; must be <= block.timestamp + 5 minutes. |
| `signature` | `bytes` | EIP-712 `AgentWalletSet(uint256,address,address,uint256)` sig from newWallet. |

#### `setApprovalForAll(address operator, bool approved)`

`0xa22cb465` · nonpayable · access: —

*@dev* Approve or remove `operator` as an operator for the caller. Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller. Requirements: - The `operator` cannot be the address zero. Emits an {ApprovalForAll} event.

| param | type | description |
|---|---|---|
| `operator` | `address` |  |
| `approved` | `bool` |  |

#### `setMetadata(uint256 agentId, string metadataKey, bytes metadataValue)`

`0x466648da` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `metadataKey` | `string` |  |
| `metadataValue` | `bytes` |  |

#### `supportsInterface(bytes4 interfaceId)`

`0x01ffc9a7` · view · access: —

*@dev* Returns true if this contract implements the interface defined by `interfaceId`. See the corresponding https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section] to learn more about how these ids are created. This function call must use less than 30 000 gas.

| param | type | description |
|---|---|---|
| `interfaceId` | `bytes4` |  |

| returns | type | description |
|---|---|---|
| `_0` | `bool` |  |

#### `transferFrom(address from, address to, uint256 tokenId)`

`0x23b872dd` · nonpayable · access: —

*@dev* Transfers `tokenId` token from `from` to `to`. WARNING: Note that the caller is responsible to confirm that the recipient is capable of receiving ERC-721 or else they may be permanently lost. Usage of {safeTransferFrom} prevents loss, though the caller must understand this adds an external call which potentially creates a reentrancy vulnerability. Requirements: - `from` cannot be the zero address. - `to` cannot be the zero address. - `tokenId` token must be owned by `from`. - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}. Emits a {Transfer} event.

| param | type | description |
|---|---|---|
| `from` | `address` |  |
| `to` | `address` |  |
| `tokenId` | `uint256` |  |

#### `unsetAgentWallet(uint256 agentId)`

`0x3fddcf19` · nonpayable · access: —

> Clear the wallet binding for this agent identity.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

### Events

| topic0 | event |
|---|---|
| `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` | `Approval(address,address,uint256)` |
| `0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31` | `ApprovalForAll(address,address,bool)` |
| `0x2c149ed548c6d2993cd73efe187df6eccabe4538091b33adbd25fafdb8a1468b` | `MetadataSet(uint256,string,string,bytes)` |
| `0xca52e62c367d81bb2e328eb795f7c7ba24afb478408a26c0e201d155c449bc4a` | `Registered(uint256,string,address)` |
| `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | `Transfer(address,address,uint256)` |
| `0x3a2c7fffc2cba7582c690e3b82c453ea02a308326a98a3ad7576c606336409fb` | `URIUpdated(uint256,string,address)` |

## IERC8004ReputationRegistry

- **Source:** `src/interfaces/IERC8004ReputationRegistry.sol`
- **Functions:** 11 · **Events:** 3 · **Errors:** 0
- **Title:** IERC8004ReputationRegistry — ERC-8004 "Trustless Agents" Reputation Registry
- Interface matching the official ERC-8004 ReputationRegistryUpgradeable.         Callers (clients) submit signed fixed-point feedback for agent interactions.         Aggregation functions (`getSummary`) provide trust signals across many clients.

### Function selector index

| selector | function | mutability | access | notice |
|---|---|---|---|---|
| `0xc2349ab2` | `appendResponse(uint256,address,uint64,string,bytes32)` | nonpayable | — | Agent owner appends a response to a feedback record. |
| `0x42dd519c` | `getClients(uint256)` | view | — |  |
| `0xbc4d861b` | `getIdentityRegistry()` | view | — |  |
| `0xf2d81759` | `getLastIndex(uint256,address)` | view | — |  |
| `0x6e04cacd` | `getResponseCount(uint256,address,uint64,address[])` | view | — |  |
| `0x81bbba58` | `getSummary(uint256,address[],string,string)` | view | — | Aggregate reputation score across a set of clients for a specific tag. |
| `0x3c036a7e` | `giveFeedback(uint256,int128,uint8,string,string,string,string,bytes32)` | nonpayable | — | Submit feedback for an agent interaction. |
| `0xc4d66de8` | `initialize(address)` | nonpayable | — |  |
| `0xd9d84224` | `readAllFeedback(uint256,address[],string,string,bool)` | view | — |  |
| `0x232b0810` | `readFeedback(uint256,address,uint64)` | view | — |  |
| `0x4ab3ca99` | `revokeFeedback(uint256,uint64)` | nonpayable | — | Revoke a previously submitted feedback entry. |

### Functions

#### `appendResponse(uint256 agentId, address clientAddress, uint64 feedbackIndex, string responseURI, bytes32 responseHash)`

`0xc2349ab2` · nonpayable · access: —

> Agent owner appends a response to a feedback record.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddress` | `address` |  |
| `feedbackIndex` | `uint64` |  |
| `responseURI` | `string` |  |
| `responseHash` | `bytes32` |  |

#### `getClients(uint256 agentId)`

`0x42dd519c` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |

| returns | type | description |
|---|---|---|
| `_0` | `address[]` |  |

#### `getIdentityRegistry()`

`0xbc4d861b` · view · access: —

| returns | type | description |
|---|---|---|
| `_0` | `address` |  |

#### `getLastIndex(uint256 agentId, address clientAddress)`

`0xf2d81759` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddress` | `address` |  |

| returns | type | description |
|---|---|---|
| `_0` | `uint64` |  |

#### `getResponseCount(uint256 agentId, address clientAddress, uint64 feedbackIndex, address[] responders)`

`0x6e04cacd` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddress` | `address` |  |
| `feedbackIndex` | `uint64` |  |
| `responders` | `address[]` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |

#### `getSummary(uint256 agentId, address[] clientAddresses, string tag1, string tag2)`

`0x81bbba58` · view · access: —

> Aggregate reputation score across a set of clients for a specific tag.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddresses` | `address[]` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |

| returns | type | description |
|---|---|---|
| `count` | `uint64` |  |
| `summaryValue` | `int128` |  |
| `summaryValueDecimals` | `uint8` |  |

#### `giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals, string tag1, string tag2, string endpoint, string feedbackURI, bytes32 feedbackHash)`

`0x3c036a7e` · nonpayable · access: —

> Submit feedback for an agent interaction.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` | ERC-8004 agent token ID. |
| `value` | `int128` | Signed fixed-point score (e.g. 95 with decimals=2 → 0.95). |
| `valueDecimals` | `uint8` | Decimal places for `value`. |
| `tag1` | `string` | Primary category tag (e.g. "quality"). |
| `tag2` | `string` | Secondary tag (e.g. "task:summarize"). |
| `endpoint` | `string` | The agent endpoint/API that served the request. |
| `feedbackURI` | `string` | URI to detailed feedback data (IPFS or HTTPS). |
| `feedbackHash` | `bytes32` | keccak256 of the off-chain feedback payload. |

#### `initialize(address identityRegistry_)`

`0xc4d66de8` · nonpayable · access: —

| param | type | description |
|---|---|---|
| `identityRegistry_` | `address` |  |

#### `readAllFeedback(uint256 agentId, address[] clientAddresses, string tag1, string tag2, bool includeRevoked)`

`0xd9d84224` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddresses` | `address[]` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |
| `includeRevoked` | `bool` |  |

| returns | type | description |
|---|---|---|
| `clients` | `address[]` |  |
| `feedbackIndexes` | `uint64[]` |  |
| `values` | `int128[]` |  |
| `valueDecimals` | `uint8[]` |  |
| `tag1s` | `string[]` |  |
| `tag2s` | `string[]` |  |
| `revokedStatuses` | `bool[]` |  |

#### `readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)`

`0x232b0810` · view · access: —

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `clientAddress` | `address` |  |
| `feedbackIndex` | `uint64` |  |

| returns | type | description |
|---|---|---|
| `value` | `int128` |  |
| `valueDecimals` | `uint8` |  |
| `tag1` | `string` |  |
| `tag2` | `string` |  |
| `isRevoked` | `bool` |  |

#### `revokeFeedback(uint256 agentId, uint64 feedbackIndex)`

`0x4ab3ca99` · nonpayable · access: —

> Revoke a previously submitted feedback entry.

| param | type | description |
|---|---|---|
| `agentId` | `uint256` |  |
| `feedbackIndex` | `uint64` |  |

### Events

| topic0 | event |
|---|---|
| `0x25156fd3288212246d8b008d5921fde376c71ed14ac2e072a506eb06fde6d09d` | `FeedbackRevoked(uint256,address,uint64)` |
| `0x6a4a61743519c9d648a14e6493f47dbe3ff1aa29e7785c96c8326a205e58febc` | `NewFeedback(uint256,address,uint64,int128,uint8,string,string,string,string,string,bytes32)` |
| `0xb1c6be0b5b8aef6539e2fac0fd131a2faa7b49edf8e505b5eb0ad487d56051d4` | `ResponseAppended(uint256,address,uint64,address,string,bytes32)` |

## AlgTierLib

- **Source:** `src/utils/AlgTierLib.sol`
- **Functions:** 0 · **Events:** 0 · **Errors:** 0
- **Title:** AlgTierLib
- Shared algorithm-to-security-tier mapping for AAStarAirAccountBase and AAStarGlobalGuard.
