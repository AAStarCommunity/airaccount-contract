I now have a thorough understanding of the entire codebase. Let me produce the comprehensive M6 design document.

---

# AirAccount M6 — Comprehensive Design Document

**Status**: Planning  
**Basis**: M5 finalized (289 tests, factory r3 at `0x03d47604c5b04194ce4cc09d26e14eaf856875bc`)  
**Date**: 2026-03-19  
**Author**: Design by Claude Code, reviewed for implementation

---

## Preface: Key Constraints From M5 (Inviolable)

Before feature-by-feature design, these M5 invariants must be preserved across all M6 work:

1. **Non-upgradable**: No proxy patterns. New features deploy as new contracts; assets migrate by user choice.
2. **algId namespace**: Any new algId requires updating `_algTier()` in BOTH `AAStarAirAccountBase` and `AAStarGlobalGuard`. These two functions must remain in sync — they are the single source of tier truth.
3. **Guard monotonicity**: `approvedAlgorithms` can only grow. `dailyLimit` can only decrease. `tokenConfigs` entries can only be added. These invariants are enforced by the guard's `onlyAccount` modifier.
4. **Guardian acceptance**: `createAccountWithDefaults` requires domain-separated ECDSA signatures from both personal guardians before atomically deploying the account.
5. **Factory eager validation**: All default configs are validated in the factory constructor — invalid configs revert at deploy time rather than silently failing per-account.
6. **Transient storage queue**: algId flows validation→execution via `_storeValidatedAlgId`/`_consumeValidatedAlgId`. Any new algId that reaches `_validateSignature` must call `_storeValidatedAlgId` before returning.
7. **`IAAStarAlgorithm.validate(bytes32, bytes) → uint256`**: Every algorithm module exposes this interface. Return 0 = success, 1 = failure.

---

## M6.4 — Session Key (Time-Limited Contract Authorization)

### Difficulty: Easy — ~250 lines of new Solidity

### Dependencies

None. This is a fully standalone module with zero base contract changes.

### Key Design Decisions

**Architecture**: `SessionKeyValidator.sol` is a standalone contract, NOT integrated into `AAStarAirAccountBase`. It is called by the account's existing `_validateSignature` fallback path (`validator.validateSignature(userOpHash, signature)`) when algId byte `0x08` is encountered. The account owner calls `setValidator(sessionKeyValidatorAddress)` to enable it, or the validator router already at `address(validator)` can incorporate it internally.

However, there is an important subtlety: the existing `IAAStarValidator` interface routes by algId, so `SessionKeyValidator` should be registered in `AAStarValidator` as algId `0x08`. The existing fallback in `_validateSignature` (lines 407-410 of the base) already handles this:

```
if (address(validator) == address(0)) return 1;
_storeValidatedAlgId(firstByte);
return validator.validateSignature(userOpHash, signature);
```

This means when `sig[0] == 0x08`, the base contract stores algId `0x08` and delegates to the validator router, which dispatches to `SessionKeyValidator`.

**Session Grant**: The account owner creates a session by calling a method on `SessionKeyValidator` directly. The session grant is a signed authorization stored in `SessionKeyValidator`'s own storage, keyed by `(account, sessionKey)`. No storage in `AAStarAirAccountBase`.

**Tier Implications**: Session key transactions are Tier 1 (same as ECDSA), because the session itself was authorized by the owner at Tier 1+. The `_algTier(0x08)` must return `1` to allow session-key-authorized transactions within Tier 1 spending bounds. The guard's `_algTier` in `AAStarGlobalGuard` must also return `1` for `0x08`.

**Storage Layout in `SessionKeyValidator`**:

```
struct Session {
    address sessionKey;         // The temp public key (P256 or ECDSA)
    uint48  expiry;             // Unix timestamp, max 24h from grant
    address contractScope;      // address(0) = any, non-zero = restricted to this dest
    bytes4  selectorScope;      // bytes4(0) = any selector, non-zero = restricted selector
    uint96  spendCap;           // Max ETH in wei per session (0 = no cap)
    uint96  spentSoFar;         // Cumulative ETH spent in this session
    bool    revoked;            // Owner can revoke before expiry
}

// Storage: account → sessionKey → Session
mapping(address => mapping(address => Session)) public sessions;
```

Packed carefully: `sessionKey` is the map key, not stored in the struct. `expiry` as `uint48` covers timestamps until year 2815. `contractScope + selectorScope` fit in one slot with `spendCap`. `spentSoFar` and `revoked` fit in one slot.

**Actual slot layout** (32 bytes each):
- Slot 0: `expiry(6) | contractScope(20) | selectorScope(4) | revoked(1) | [1 byte padding]`
- Slot 1: `spendCap(12) | spentSoFar(12) | [8 bytes padding]`

This achieves 2 SLOAD for a full session read.

**Session Grant Flow**:

The owner signs a session grant off-chain. The session key (or anyone) submits it on-chain via `grantSession(account, session, ownerSig)`. The `ownerSig` must recover to `account.owner()`. Domain separation:

```
keccak256(abi.encodePacked(
    "GRANT_SESSION",
    block.chainid,
    address(sessionKeyValidator),
    account,
    sessionKey,
    expiry,
    contractScope,
    selectorScope,
    spendCap
)).toEthSignedMessageHash()
```

**Signature format for algId 0x08** (after algId byte stripped):

```
[sessionKey(20)][sessionKeyECDSA(65)]
```

Total: 85 bytes after the algId prefix (86 total).

The `sessionKeyECDSA` is signed by `sessionKey` (the temp key), not the owner. The validator looks up the session by `(account = msg.sender context... wait — see below)`.

**Critical Context Problem**: `SessionKeyValidator.validate(userOpHash, sig)` is called from `AAStarValidator.validateSignature()` which is called from `AAStarAirAccountBase._validateSignature()`. The `msg.sender` in the validator is `AAStarValidator`, not the account. The account address must be passed in the signature payload.

Revised signature format for algId 0x08:
```
[0x08][account(20)][sessionKey(20)][sessionKeyECDSA(65)]
```

Total: 106 bytes. The validator uses `account` from the payload, looks up `sessions[account][sessionKey]`, verifies the ECDSA sig recovers to `sessionKey`, checks `!revoked`, checks `block.timestamp < expiry`, checks `contractScope` constraint is enforced externally (the guard does this via calldata; the session key cannot bypass the guard's algorithm whitelist check — algId `0x08` must be in `approvedAlgorithms`).

**Spend cap tracking**: The validator cannot track spend because `IAAStarAlgorithm.validate()` is a `view` function. This is a fundamental constraint: spend tracking requires state writes which aren't allowed during validation. The spend cap must be enforced at execution time through a different mechanism.

The cleanest approach: add a `recordSessionSpend(address account, address sessionKey, uint256 amount)` function callable only by the account during execution. The account calls this in `_enforceGuard` when algId is `0x08`. But this requires a change to `_enforceGuard`... which is a base contract change.

**Alternative**: Omit spend-cap enforcement on-chain initially. The DVT nodes enforce spend caps off-chain before co-signing. This is weaker but avoids any base contract change and keeps M6.4 at "easy" difficulty. The `contractScope` and `selectorScope` restrictions provide hard guarantees; `spendCap` becomes a soft off-chain limit. Document this explicitly as a known limitation with a path to enforce it in M7 if needed.

**Revocation**: Owner calls `revokeSession(account, sessionKey)` on `SessionKeyValidator`. Sets `revoked = true`. No timelock needed — revocation is immediate and synchronous. The session key's existing in-flight transactions (submitted but not yet included) will still pass until the revoke transaction is included.

### Contract Changes

- **New file**: `src/validators/SessionKeyValidator.sol` — implements `IAAStarAlgorithm`
- **`AAStarAirAccountBase._algTier()`**: Add `if (algId == ALG_SESSION_KEY) return 1;` — where `ALG_SESSION_KEY = 0x08`
- **`AAStarGlobalGuard._algTier()`**: Add `algId == 0x08` to the Tier 1 group
- **`AAStarAirAccountFactoryV7._buildDefaultConfig()`**: Add `0x08` to the approved algIds array (now 7 entries instead of 6)
- **`AAStarValidator`**: Register `SessionKeyValidator` at algId `0x08` (off-chain deploy step, not a code change)

No changes to `execute()`, `executeBatch()`, `_enforceGuard()`, guardian storage, or `InitConfig`.

### Security Considerations

- **Session replay across chains**: The grant domain hash includes `block.chainid` — chain-specific.
- **Session replay across factories/accounts**: The grant hash includes `account` address — account-specific.
- **Short-lived keys**: Max 24h expiry. No on-chain revoke needed at expiry — the timestamp check suffices.
- **Selector scope abuse**: A session scoped to `contractScope=UniswapRouter, selectorScope=swap()` cannot be used to call `approve()` on the same contract. Must be checked in the validator.
- **The validator cannot prevent a session key from repeatedly calling within scope**: DVT co-sign requirement is the off-chain enforcement layer.
- **algId 0x08 must be in guard's `approvedAlgorithms`**: If the user didn't add it at account creation, session-key UserOps will revert at execution with `AlgorithmNotApproved`. The factory default should include it.
- **Owner's `validator` address must point to `AAStarValidator`**: If owner uses a different validator, session keys won't work. Document this dependency.

### Interaction with M5 Security Model

- Does NOT touch guardian storage, guardian acceptance, social recovery.
- Touches `_algTier` in both contracts (required).
- Guard algorithm whitelist: `0x08` added to factory defaults.
- Transient storage queue: `_storeValidatedAlgId(0x08)` is called by the existing fallback path in `_validateSignature` — no change needed.
- The guard's `checkTransaction(value, algId)` with `algId=0x08` will check `approvedAlgorithms[0x08]`. This acts as the on-chain spend control at the daily-limit level.

### Test Strategy

**Unit tests**:
- `grantSession`: valid owner sig → session stored
- `grantSession`: expired expiry → revert
- `grantSession`: expiry > 24h → revert
- `grantSession`: invalid owner sig → revert
- `validate`: valid session key sig, non-expired → returns 0
- `validate`: expired session → returns 1
- `validate`: revoked session → returns 1
- `validate`: wrong session key → returns 1
- `validate`: contractScope mismatch → returns 1
- `validate`: selectorScope mismatch → returns 1
- `revokeSession`: owner revokes → revoked = true
- `revokeSession`: non-owner → revert

**Scenario tests (E2E on Sepolia)**:
- Gaming scenario: grant 4h session scoped to GameContract, session key signs 10 UserOps without passkey prompt, verify ETH balance after each, session expires and 11th UserOp fails
- DeFi scenario: grant session scoped to UniswapRouter swap selector, attempt to call approve → reverts at validator

### Open Questions / Risks

1. **Spend cap on-chain enforcement**: Currently off-chain only. If DVT nodes are offline or malicious, spend cap is not enforced. Acceptable for M6, but should be flagged clearly.
2. **Session key type**: Currently ECDSA only. Should P256 session keys be supported? More complex but possible (pass P256 pubkey + sig). Defer to M6.4b.
3. **Multiple sessions per account**: Unlimited in the current design. Should there be a cap (e.g., max 10 active sessions) to prevent storage bloat? Consider adding `uint8 maxActiveSessions` check.
4. **DVT co-sign for session key UserOps**: Should sessions require BLS DVT approval too? If yes, tier becomes 2 and session key alone is insufficient. This is a significant UX trade-off — the whole point of session keys is to avoid repeated signing prompts. Recommend: session keys are Tier 1, DVT co-sign is optional (off-chain recommendation).

---

## M6.6a — OAPD (One Account Per DApp) Deployment Support

### Difficulty: Easy — ~50 lines of TypeScript/script, zero Solidity

### Dependencies

None. No contract changes required. Uses existing `createAccountWithDefaults` factory.

### Key Design Decisions

**Architecture**: OAPD is purely a deployment pattern. A "privacy account" is a second `AAStarAirAccountV7` with a different `salt`. The main account and OAPD account are independent — separate addresses, separate guards, separate owners (though the owner may be the same EOA).

**Salt convention**: To distinguish OAPD accounts from main accounts, establish a salt namespace convention:
- Main account: salt in range `[0, 999_999]` (user-chosen or auto-generated)
- OAPD account: salt = `keccak256(abi.encodePacked("OAPD", mainAccountAddress, dappName))` truncated to a `uint256`, or alternatively `mainSalt + 1_000_000` as a simple human-readable offset.

The recommended approach is a deterministic derivation scheme so users can reconstruct their OAPD address without storing it:
```
oapdSalt = uint256(keccak256(abi.encodePacked("OAPD_v1", mainSalt, dappIdentifier)))
```

**Deployment script changes**: The `deploy-m5.ts` (or a new `deploy-m6-oapd.ts`) accepts a `--privacy-account` flag. When set:
1. Derives the OAPD salt from the main account salt + dapp identifier
2. Calls `getAddressWithDefaults(owner, oapdSalt, g1, g2, dailyLimit)` to preview the address
3. Collects guardian signatures for the OAPD salt specifically (guardians sign over `owner + oapdSalt`, not `owner + mainSalt`)
4. Calls `createAccountWithDefaults(owner, oapdSalt, ...)`

**Privacy configuration**: The OAPD account should have a tighter configuration than the main account:
- Lower `dailyLimit` (e.g., user specifies explicitly — no default from factory)
- No pre-configured mainstream tokens (no USDC, WBTC) — the OAPD is for privacy pool interactions where tokens are shielded
- Same guardians as main account (guardians must re-sign for the new salt — this is intentional, prevents unintended account creation)

**Frontend badge**: Frontend shows two accounts in the account switcher:
- "Main Account" — `0xABCD...` (orange badge)
- "Private Account @ Railgun" — `0xDEF0...` (purple/shield badge)

The frontend derives the OAPD address using `getAddressWithDefaults` with the OAPD salt — no new contract methods needed.

**No cross-account linkage on-chain**: The main account and OAPD account are not linked in any smart contract. The only link is off-chain (same owner, known salt derivation). This is intentional for privacy — an on-chain link would deanonymize the OAPD account.

### Contract Changes

None. No Solidity changes.

**New files**:
- `scripts/deploy-m6-oapd.ts` — deployment helper with `--privacy-account` flag
- `scripts/lib/oapd-utils.ts` — salt derivation and address prediction utilities

### Security Considerations

- Guardians must sign with the OAPD salt, not the main account salt. The guardian acceptance hash includes `salt` (from M5 design: `keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt))`). If a guardian re-uses their main-account signature, it will fail because `salt` differs.
- The OAPD account's guard is independent. Privacy pool transactions are NOT subject to the main account's daily limit.
- Social recovery for the OAPD account is independent from the main account's recovery state.

### Interaction with M5 Security Model

No interaction. Pure deployment tooling.

### Test Strategy

**Script tests**:
- Deploy main account with salt=1, OAPD with derived salt → two distinct addresses predicted correctly
- Guardian signatures valid for OAPD salt but fail for main salt (replay prevention)
- `getAddressWithDefaults(owner, oapdSalt, ...)` matches deployed address

**Scenario test**:
- Main account sends ETH, guard decrements main account's daily limit
- OAPD account sends ETH, guard decrements OAPD account's daily limit separately
- Verify no cross-account leakage

### Open Questions / Risks

1. **Salt management UX**: Users need to remember both salts (or the dapp identifier). Recommend storing OAPD metadata in an off-chain user profile (or in the factory event logs — `AccountCreated` events can be queried).
2. **Multiple OAPDs per user**: Salt derivation formula `keccak256("OAPD_v1", mainSalt, dappName)` naturally supports multiple OAPDs for different dapps. Document this capability.
3. **Guardian burden**: Both accounts require guardian acceptance signatures. If the user has the same 3 guardians, each guardian must sign twice (once per account). This is correct behavior (2 independent accounts) but may confuse users. Frontend should clearly communicate this.

---

## M6.6b — Pluggable Calldata Parser (`ICalldataParser` + Registry)

### Difficulty: Medium — ~180 lines of Solidity across 3 files

### Dependencies

- M6.6a (conceptual understanding of OAPD use case)
- No code dependency on other M6 features

### Key Design Decisions

**Problem**: `_enforceGuard` in `AAStarAirAccountBase` currently only parses `transfer(address,uint256)` and `approve(address,uint256)` selectors (ERC20 standard). Privacy pool contracts like Railgun use non-standard calldata structures. The guard cannot enforce token-level limits on shielded pool interactions without knowing how to parse those calls.

**Interface design**:

```solidity
// src/interfaces/ICalldataParser.sol
interface ICalldataParser {
    /// @notice Parse calldata to extract a token amount for guard enforcement
    /// @param dest The destination contract address
    /// @param data The full calldata (including 4-byte selector)
    /// @return token  The ERC20 token address involved (address(0) = ETH or not applicable)
    /// @return amount The token amount for guard purposes (0 = no enforcement needed)
    function parse(address dest, bytes calldata data)
        external view returns (address token, uint256 amount);
}
```

**Parser Registry in the account**: Add a mapping in `AAStarAirAccountBase`:

```solidity
// Destination address → parser contract
mapping(address => ICalldataParser) public calldataParsers;
```

One new storage slot per registered destination (mapping, not packed). This is acceptable since parsers are registered once at account setup and rarely change.

**Registration**: Owner calls `registerCalldataParser(address dest, address parser)` (owner-only). Monotonic? Unlike the guard, calldata parsers are NOT monotonic — an owner might want to update a parser if a contract migrates. However, for security, consider making it unidirectional: once a parser is set for a dest, it cannot be removed (only replaced). This prevents an attacker with a stolen key from removing a parser to bypass limits. Alternatively, treat parsers as non-monotonic since they don't change the security level — they only add enforcement coverage.

**Decision**: Make parsers replaceable but require the replacement to be non-null (`address(0)` not allowed as replacement). This is a compromise: protects against accidental limit removal while allowing parser upgrades when a DeFi protocol migrates.

**Modified `_enforceGuard`**:

```
// After existing ERC20 check:
if (func.length >= 4 && address(guard) != address(0)) {
    ICalldataParser parser = calldataParsers[dest];
    if (address(parser) != address(0)) {
        (address token, uint256 amount) = parser.parse(dest, func);
        if (token != address(0) && amount > 0) {
            guard.checkTokenTransaction(token, amount, algId);
        }
    }
}
```

This runs AFTER the existing ERC20 check. If `dest` has both a standard ERC20 transfer AND a custom parser registered, both checks run (safe: the guard tracks cumulative spend per token per day).

**Parser contracts to implement**:

`RailgunCalldataParser.sol`: Parses Railgun shield calls to extract token address and shield amount. Railgun's `shield(TokenData[] calldata _tokenData, uint256 _minGasPrice, ShieldRequest[] calldata _shieldRequests)` would be parsed to extract each token and its amount.

`PrivacyPoolsCalldataParser.sol`: Similar pattern for Privacy Pools deposit interface.

Both parsers are stateless (pure view functions, no storage), making them extremely lightweight.

**Storage Layout Changes in `AAStarAirAccountBase`**:

Add one new storage variable:
```solidity
mapping(address => ICalldataParser) public calldataParsers;
```

Solidity maps don't occupy contiguous slots; this is a 32-byte slot pointer in the contract's storage layout. The actual mapping entries are at `keccak256(key . slot)`.

**`InitConfig` extension**: Add `calldataParser` entries to `InitConfig` to allow parsers to be registered at account creation. However, this changes `InitConfig` which changes the constructor ABI — a breaking change. Recommend NOT changing `InitConfig`. Instead, parsers are registered post-deployment via `registerCalldataParser(dest, parser)` as owner transactions. Most users won't need parsers, so this extra step is acceptable.

**`AccountConfig` extension**: Add `uint8 parserCount` or `address[] registeredParsers` to `AccountConfig` for UI display. Since enumerating a mapping is expensive, track parser count separately:

```solidity
uint8 public parserCount;
```

Or omit from `AccountConfig` and let the frontend query specific destinations it knows about. Recommended: omit from `AccountConfig` (keep it simple).

### Contract Changes

- **New file**: `src/interfaces/ICalldataParser.sol` — 15-line interface
- **New file**: `src/parsers/RailgunCalldataParser.sol` — ~60 lines, stateless
- **New file**: `src/parsers/PrivacyPoolsCalldataParser.sol` — ~60 lines, stateless
- **`AAStarAirAccountBase`**:
  - Add `mapping(address => ICalldataParser) public calldataParsers;`
  - Add `function registerCalldataParser(address dest, ICalldataParser parser) external onlyOwner`
  - Modify `_enforceGuard()` to run parser check after existing ERC20 check
  - Add custom error: `error ParserAddressZero()`
  - Add event: `event CalldataParserRegistered(address indexed dest, address indexed parser)`

### Security Considerations

- **Parser return value manipulation**: A malicious parser could return `amount=0` for large transfers, bypassing limits. Since parsers are set by the owner (`onlyOwner`), this is equivalent to the owner disabling their own limits. Acceptable.
- **Parser external call gas cost**: `parser.parse()` is a `view` staticcall. If the parser has a bug that reverts, `_enforceGuard` wraps it in try/catch and falls through (fails open: no limit enforcement). This is safer than failing closed (would break all calls to that dest). Document this explicitly.
- **Reentrancy via parser**: The parser is a staticcall — cannot modify state, cannot reenter. Safe.
- **Parser for a non-ERC20 dest**: If a parser is registered for ETH-sending calls (e.g., a Railgun ETH shield), the returned `token=address(0)` is handled by the check `if (token != address(0))` — skipped gracefully. ETH spending is already enforced by `guard.checkTransaction(value, algId)`.
- **Double-counting risk**: If `dest` is an ERC20 token AND has a parser registered, both the standard ERC20 check AND the parser check run. The guard's cumulative tracking would count the same amount twice. Mitigation: document that parsers should NOT be registered for standard ERC20 token addresses. The standard check handles ERC20 transfers natively.

### Interaction with M5 Security Model

- Adds a call site in `_enforceGuard` — the guard's `checkTokenTransaction` is already called there. Adding a second call path for parser-detected tokens is additive, not structural.
- Does NOT touch `_algTier`, guardian storage, transient storage queue, or factory defaults.
- Parser registration is `onlyOwner` — not subject to guardian veto. This is correct: adding a parser tightens security (adds enforcement), it doesn't loosen it.

### Test Strategy

**Unit tests for `ICalldataParser` implementations**:
- `RailgunCalldataParser.parse(railgunAddr, shieldCalldata)` → correct token + amount
- `RailgunCalldataParser.parse(other, data)` → returns (address(0), 0)
- Edge cases: empty calldata, unknown selector, multi-token shield

**Unit tests for `registerCalldataParser`**:
- Non-owner → revert `NotOwner`
- `parser=address(0)` → revert `ParserAddressZero`
- Valid registration → `CalldataParserRegistered` event emitted
- Replace existing parser (non-null) → succeeds, event emitted

**Integration tests for `_enforceGuard` with parser**:
- Call to Railgun with USDC shield amount above Tier 1 limit → `InsufficientTokenTier` revert
- Call to Railgun with USDC amount within Tier 1 limit using ECDSA → succeeds
- Standard ERC20 transfer to different address (not Railgun) → only standard check runs
- Parser that returns (address(0), 0) → no token check, guard passes through

### Open Questions / Risks

1. **Session Key interaction (M6.4)**: If a session is scoped to `contractScope=RailgunRouter` but the parser exposes a token limit, the parser enforcement still applies because guard enforcement happens in `_enforceGuard` regardless of algId. Good — this is the intended layered security.
2. **Parser versioning**: If Railgun upgrades their contract to a new address, the parser registration must be updated. Since registration is `onlyOwner`, this requires an owner transaction. If the owner uses a session key, the session must have scope covering the parser registration call (to `address(this)`).
3. **Enumeration**: No way to enumerate all registered parsers from the contract. Clients must either track registration events or query specific known destinations. Acceptable for now.

---

## M6.1 — Weight-Based Multi-Signature (algId 0x07)

### Difficulty: Medium — ~350 lines of new/modified Solidity

### Dependencies

- M6.4 (Session Key) must NOT use `0x07` — this algId is reserved for weighted
- No other code dependencies, but should be implemented after M6.4/M6.6b to avoid conflicting slot numbering
- `AAStarValidator` must have algId `0x07` slot available (it does — no collision)

### Key Design Decisions

**algId**: `0x07` — this was described as `0x06` in the M4.5 research doc, but M5 already used `0x06` for `ALG_COMBINED_T1`. The correct algId for weighted signatures is `0x07`.

**Weight config struct** (7 uint8 values = 7 bytes, fits in one 32-byte storage slot):

```solidity
struct WeightConfig {
    uint8 passkeyWeight;      // P256 passkey (default: 3)
    uint8 ecdsaWeight;        // Owner ECDSA   (default: 2)
    uint8 blsWeight;          // DVT BLS       (default: 2)
    uint8 guardian0Weight;    // Guardian[0]   (default: 1)
    uint8 guardian1Weight;    // Guardian[1]   (default: 1)
    uint8 guardian2Weight;    // Guardian[2]   (default: 1)
    uint8 _padding;           // Reserved for future weight source (e.g., hardware key)
    // Remaining 25 bytes in slot — add threshold values here:
    uint8 tier1Threshold;     // e.g., 3
    uint8 tier2Threshold;     // e.g., 5
    uint8 tier3Threshold;     // e.g., 6
    // Total: 10 bytes used, 22 bytes spare in slot
}
```

All 10 meaningful bytes pack into a single storage slot. `WeightConfig` storage variable:

```solidity
WeightConfig public weightConfig;
```

Slot assignment: follows `p256KeyY` in the contract's storage layout. Needs careful audit of storage slot order to avoid collisions. The current storage layout in `AAStarAirAccountBase` ends at `activeRecovery` (a struct occupying 4 slots). `weightConfig` goes after — but since it's only 10 bytes, it fits in slot N+4 entirely.

**Default weights**: Match the research doc defaults. These defaults are set when `setWeightConfig()` is first called. If `weightConfig` is never configured (all zeros), algId `0x07` returns 1 (failure) — this prevents using weighted mode without explicit setup.

**Signature format for algId `0x07`** (after algId byte stripped):

```
[sourceBitmap(1)][P256?(64)][ECDSA?(65)][BLS_payload?(variable)][guardian0?(65)][guardian1?(65)][guardian2?(65)]
```

`sourceBitmap` bits:
- bit 0: P256 passkey present (64 bytes: r, s)
- bit 1: ECDSA present (65 bytes: r, s, v)
- bit 2: BLS aggregate present (variable — must be parsed with BLS payload framing)
- bit 3: Guardian[0] ECDSA present (65 bytes)
- bit 4: Guardian[1] ECDSA present (65 bytes)
- bit 5: Guardian[2] ECDSA present (65 bytes)
- bits 6-7: Reserved (must be 0)

**The BLS parsing problem**: BLS payload is variable-length (depends on number of node IDs). When BLS is present (bit 2 set), the signature parser must first parse the BLS block to determine its length before reading guardian signatures that follow. The BLS block format is: `[nodeIdsLength(32)][nodeIds(N×32)][blsSig(256)][messagePoint(256)][mpSig(65)]` = `32 + N×32 + 577` bytes. The `nodeIdsLength` at the start of the BLS block allows forward-parsing without a separate length field.

**Weight validation function `_validateWeightedSignature`**:

Pseudocode:
```
1. Check WeightConfig is initialized (tier1Threshold > 0)
2. Parse sourceBitmap
3. For each set bit, validate the corresponding signature component:
   a. P256: call _validateP256, add passkeyWeight if valid, else return 1
   b. ECDSA: call _validateECDSA, add ecdsaWeight if valid, else return 1
   c. BLS: parse BLS block length, verify BLS via validator.getAlgorithm(ALG_BLS), add blsWeight
   d. Guardian[i]: verify ECDSA recovers to guardians[i], add guardianWeight[i]
4. Determine required weight based on transaction context
```

**Critical design issue — tier threshold lookup during validation**: `_validateWeightedSignature` is called during `_validateSignature`, which happens in the ERC-4337 validation phase. At validation time, we know `userOpHash` but not the transaction `value` or `dest` (those are in `callData`). The tier enforcement (which threshold to use) normally happens in `_enforceGuard` during execution based on `value`.

**Resolution**: Weighted signatures must include ALL required components regardless of tier, and the threshold check in `_enforceGuard` must be modified. At validation time, `_validateWeightedSignature` computes the total accumulated weight, stores it alongside the algId in transient storage. At execution time, `_enforceGuard` reads the weight from transient storage and compares it to the threshold required by `requiredTier(alreadySpent + value)`.

This requires a second transient storage slot for the weight value. Add:

```solidity
uint256 internal constant WEIGHT_SLOT_BASE = 0x0A1601;  // after ALG_ID_SLOT_BASE
```

Then `_storeValidatedWeight(uint8 weight)` and `_consumeValidatedWeight() → uint8`.

And in `_enforceGuard`, when `algId == ALG_WEIGHTED`, replace the `_algTier` lookup with:
```
uint8 weight = _consumeValidatedWeight();
uint8 required = requiredTier(alreadySpent + value);
uint8 requiredWeight = _thresholdForTier(required);
if (weight < requiredWeight) revert InsufficientWeight(required, weight, requiredWeight);
```

Where `_thresholdForTier(tier)` reads from `weightConfig.tier1/2/3Threshold`.

**`_algTier(0x07)` return value**: Since tier enforcement for weighted signatures happens via weight comparison (not a fixed tier), `_algTier(0x07)` should return a special sentinel or the actual accumulated tier. The cleanest approach: return `0` from `_algTier(0x07)` (unknown/special-cased) and handle weighted sig in `_enforceGuard` as a separate branch. The guard's `checkTransaction(value, algId)` only needs `algId` for the algorithm whitelist — the guard does NOT do tier enforcement for `_algTier`; the account does. So:

- Account's `_algTier(0x07)` returns `0` (sentinel: "use weight path")
- `_enforceGuard` has a special branch: `if (algId == ALG_WEIGHTED) { // weight-based enforcement } else { // standard tier enforcement }`
- Guard's `_algTier(0x07)` in `AAStarGlobalGuard` also returns `0` — but this is only used by `checkTokenTransaction` for token tier enforcement. Token tier for weighted sigs also needs the weight-to-tier mapping.

**Simpler approach for token tier enforcement in guard**: Pass the computed tier (1, 2, or 3) instead of the raw algId to `checkTokenTransaction`. But that requires changing the `checkTransaction` and `checkTokenTransaction` function signatures — a significant interface change.

**Cleanest resolution**: Add a `uint8 resolvedTier` concept. In `_enforceGuard` for weighted sigs, compute the resolved tier from the weight, then call `guard.checkTransaction(value, resolvedAlgId)` where `resolvedAlgId` maps the tier back to a synthetic algId: tier1→`0x02`, tier2→`0x04`, tier3→`0x05`. The guard's algorithm whitelist then uses the underlying algId, not `0x07`. This means the guard doesn't need to know about `0x07` at all — weighted sigs are "translated" to their effective tier's representative algId before the guard call.

However, this requires the guard's `approvedAlgorithms[0x02/0x04/0x05]` to be set. Since factory defaults already approve all these, this works for `createAccountWithDefaults` accounts. For `createAccount` with custom config, the user must approve the underlying algIds.

### Contract Changes

- **`AAStarAirAccountBase`**:
  - Add `uint8 internal constant ALG_WEIGHTED = 0x07;`
  - Add `WeightConfig public weightConfig;` struct definition and storage variable
  - Add `_validateWeightedSignature(userOpHash, sigData)` internal function
  - Add `_storeValidatedWeight(uint8)` and `_consumeValidatedWeight()` transient storage helpers
  - Modify `_validateSignature`: add `if (firstByte == ALG_WEIGHTED)` branch before the external validator fallback
  - Modify `_enforceGuard`: add weight-based enforcement branch for `algId == ALG_WEIGHTED`
  - Add `function setWeightConfig(WeightConfig calldata config) external onlyOwner` (guarded by M6.2)
  - Add `error InsufficientWeight(uint8 tier, uint8 provided, uint8 required)`
  - Add `error WeightConfigNotInitialized()`
  - Add event `WeightConfigUpdated(WeightConfig config)`
  - `_algTier(0x07)` returns `0` (special sentinel, handled separately in `_enforceGuard`)

- **`AAStarGlobalGuard`**:
  - `_algTier(0x07)` returns `0` (weighted sigs pass a resolved tier instead)
  - No other changes — guard doesn't need to know about weight configs

- **New struct** `WeightConfig` — defined in `AAStarAirAccountBase` (used only there)
- **`AccountConfig`**: Add `bool hasWeightConfig` field and `WeightConfig weightConfig` for UI display

### Security Considerations

- **Weight inflation**: A single compromised source should not reach threshold alone. The `tier1Threshold` should always be ≥ 2, enforced in `setWeightConfig` validation: if any single `weight ≥ tier1Threshold`, revert with `InsecureWeightConfig`.
- **Zero weight sources**: A guardian with `weight=0` effectively has no power. This is valid (disabled guardian weight) but may confuse users. Allow weight=0 but document clearly.
- **Guardian weight for non-existent guardian**: If `_guardianCount < 3` but `guardian2Weight > 0`, the signature parser must not count weight for a guardian that doesn't exist. During validation, check `i < _guardianCount` before accepting guardian weight.
- **BLS messagePoint binding**: BLS validation within weighted sigs must still include the `messagePointSignature` binding (`keccak256(userOpHash, messagePoint)` signed by owner) to prevent messagePoint manipulation. The BLS block in weighted sigs uses the SAME format as standalone BLS — the existing `_validateCumulativeTier2` BLS parsing logic is reused.
- **Transient storage collision**: `WEIGHT_SLOT_BASE` must not overlap with `ALG_ID_SLOT_BASE`. Current: `ALG_ID_SLOT_BASE = 0x0A1600`. The slot base uses indices `0x0A1600`, `0x0A1601` (read/write ptrs), then `0x0A1602+`. A safe choice: `WEIGHT_SLOT_BASE = 0x0A1700` (256 slots away, no collision risk).

### Interaction with M5 Security Model

- Requires `_algTier` changes in both files (required protocol step for any new algId).
- Adds a new transient storage dimension (weight alongside algId).
- The guard monotonicity is preserved: weighted sig enforcement maps to existing tier algIds.
- Guardian storage is read (not modified) during validation for guardian sig checking.
- Factory: `0x07` should be added to approved algIds in `_buildDefaultConfig`. However, weight config is NOT set at factory creation — the owner must call `setWeightConfig()` post-deployment. This means the algId is approved by the guard but unusable until weight config is initialized. This is safe: the validation returns 1 if `weightConfig.tier1Threshold == 0`.

### Test Strategy

**Unit tests**:
- `setWeightConfig`: valid config → stored, event emitted
- `setWeightConfig`: `singleSourceWeight >= tier1Threshold` → revert `InsecureWeightConfig`
- `_validateWeightedSignature`: P256 only, weight=3, threshold=3 → success
- `_validateWeightedSignature`: P256+BLS, weight=5, threshold=5 → success
- `_validateWeightedSignature`: wrong passkey → revert (weight never reaches threshold)
- `_validateWeightedSignature`: invalid guardian index → weight not added
- Execute: weighted sig with accumulated weight above tier1 threshold, ETH value at tier 1 → success
- Execute: weighted sig with only passkey (weight=3), ETH value requiring tier 2 → `InsufficientWeight`
- Batch: weighted sig, 2 calls — second call crosses tier boundary → reverts

**Gas benchmark tests**:
- Compare gas for P256+BLS via algId `0x04` vs equivalent via algId `0x07`
- Expected: `0x07` adds ~500-800 gas for bitmap parse + weight accumulation

**Scenario tests**:
- DAO scenario: guardian-heavy setup where passkey=1, each guardian=3, threshold=6 → guardian trio can authorize without passkey
- High-security personal: passkey=3, ECDSA=2, BLS=2, threshold for T1=5 → passkey alone insufficient

### Open Questions / Risks

1. **Transient storage for weight**: Requires careful slot allocation. Any error here causes silent mis-enforcement. Extensive fuzzing needed.
2. **BLS payload parsing reuse**: The weighted sig's BLS block uses the same format as ALG_CUMULATIVE_T2. Can `_validateCumulativeTier2`'s BLS parsing logic be extracted into a shared internal function? Yes — refactor to `_validateAndExtractBLS(userOpHash, blsPayload) → (uint256 result, uint256 bytesConsumed)`. This prevents code duplication across algId 0x04, 0x05, and 0x07.
3. **Weight config update governance**: Covered in M6.2 below.
4. **Frontend UX for weight config**: The "simulate weight" feature (M6.3) is needed for users to understand their configuration. Without the frontend, M6.1 is hard to use. Consider shipping M6.3 (minimal simulation tool in TypeScript/viem, no UI) alongside M6.1.

---

## M6.2 — Guardian Consent for Weight Changes

### Difficulty: Medium — ~120 lines of new Solidity in `AAStarAirAccountBase`

### Dependencies

- **M6.1 must be complete first**: M6.2 is a governance wrapper around `setWeightConfig()`. No M6.1 = no weight config = nothing to guard.

### Key Design Decisions

**Problem**: An owner with a stolen ECDSA key could call `setWeightConfig()` to lower thresholds (e.g., `tier3Threshold` from 6 to 3), making large transactions require only the stolen ECDSA key. This defeats the purpose of weight-based security.

**Rule**: If a weight config change would **reduce** any tier threshold (making the tier easier to pass), it must receive guardian approval before taking effect. If a change only increases thresholds (more restrictive), it can be applied immediately by the owner.

**Detecting a "weakening" change**: Compare new config to current config:
- `newConfig.tier1Threshold < currentConfig.tier1Threshold` → weakening
- `newConfig.tier2Threshold < currentConfig.tier2Threshold` → weakening
- `newConfig.tier3Threshold < currentConfig.tier3Threshold` → weakening
- Any individual weight increase could also be a weakening (if one source's weight jumps past a threshold). However, checking all combinations is complex. Simpler and more conservative: flag ANY change to thresholds or to passkeyWeight/ecdsaWeight (the highest-weight sources) as requiring guardian approval. Weight changes to guardian weights (lower-value sources) can be immediate.

**Timelocked proposal pattern** (mirrors `AAStarValidator.proposeAlgorithm`):

```solidity
struct WeightChangeProposal {
    WeightConfig proposedConfig;
    uint256 proposedAt;
    uint256 approvalBitmap;   // guardian approval bitmap (same as recovery)
}

WeightChangeProposal public pendingWeightChange;

uint256 internal constant WEIGHT_CHANGE_TIMELOCK = 2 days;  // same as RECOVERY_TIMELOCK
uint256 internal constant WEIGHT_CHANGE_THRESHOLD = 2;       // 2-of-3 guardians
```

**Flow for weakening changes**:
1. Owner calls `proposeWeightChange(WeightConfig calldata newConfig)` → stores proposal, emits event
2. Guardians call `approveWeightChange()` → increments approval bitmap
3. After `WEIGHT_CHANGE_TIMELOCK` AND `approvalBitmap popcount >= WEIGHT_CHANGE_THRESHOLD`, anyone calls `executeWeightChange()`
4. `weightConfig` is updated

**Flow for tightening changes**:
Owner calls `setWeightConfig(WeightConfig calldata newConfig)` directly, function validates it's a tightening change (all thresholds >= current), applies immediately.

**Weakening detection function**:

```solidity
function _isWeakening(WeightConfig memory current, WeightConfig memory proposed) internal pure returns (bool) {
    // Any threshold reduction is a weakening
    if (proposed.tier1Threshold < current.tier1Threshold) return true;
    if (proposed.tier2Threshold < current.tier2Threshold) return true;
    if (proposed.tier3Threshold < current.tier3Threshold) return true;
    // Increasing a high-weight source could let it reach threshold alone
    // Conservative: flag any increase to passkey or ECDSA weight if it would
    // allow either to exceed a threshold alone
    if (proposed.passkeyWeight >= proposed.tier1Threshold && current.passkeyWeight < current.tier1Threshold) return true;
    if (proposed.ecdsaWeight >= proposed.tier1Threshold && current.ecdsaWeight < current.tier1Threshold) return true;
    return false;
}
```

**`setWeightConfig` revised behavior**:

```
if (_isWeakening(weightConfig, newConfig)) {
    // Cannot apply directly — must go through proposal
    revert WeakeningRequiresProposal();
}
// Apply immediately
weightConfig = newConfig;
emit WeightConfigUpdated(newConfig);
```

**Owner cancel of proposal**: Owner can cancel a pending weight change proposal (for example if they proposed incorrectly). This is safe — cancellation doesn't weaken security, it abandons a proposed change.

**No active recovery constraint**: If a recovery is active, block weight change proposals. An attacker who compromised the key AND is in recovery should not be able to simultaneously weaken weight config.

```solidity
if (activeRecovery.newOwner != address(0)) revert RecoveryInProgress();
```

**First-time initialization**: When `weightConfig` is all-zeros (first call), any config can be applied directly (no weakening check — there's nothing to weaken). The check `if (weightConfig.tier1Threshold == 0)` indicates first-time setup.

### Contract Changes

- **`AAStarAirAccountBase`**:
  - Add `WeightChangeProposal public pendingWeightChange;` storage variable
  - Add `uint256 internal constant WEIGHT_CHANGE_TIMELOCK = 2 days;`
  - Add `uint256 internal constant WEIGHT_CHANGE_THRESHOLD = 2;`
  - Modify `setWeightConfig()`: add weakening check, revert with `WeakeningRequiresProposal` if weakening
  - Add `proposeWeightChange(WeightConfig calldata newConfig)` — owner only, stores proposal
  - Add `approveWeightChange()` — guardian only, adds approval bit
  - Add `executeWeightChange()` — permissionless, checks timelock + threshold
  - Add `cancelWeightChange()` — owner only, deletes proposal
  - Add custom errors: `WeakeningRequiresProposal`, `WeightChangePending`, `WeightChangeTimelockNotExpired`, `WeightChangeNotApproved`, `NoWeightChangeProposal`, `WeightChangeAlreadyApproved`, `RecoveryInProgress`
  - Add events: `WeightChangeProposed`, `WeightChangeApproved`, `WeightChangeExecuted`, `WeightChangeCancelled`

### Security Considerations

- **Guardian collusion**: 2-of-3 guardians can approve a weakening change against owner's wishes. This is intentional — same as recovery. If owner disagrees, they have the 2-day timelock window to cancel (via `cancelWeightChange()`) and potentially remove the colluding guardian.
- **Timelock and active recovery**: Both simultaneously possible if an attacker compromises 2 guardians. The `RecoveryInProgress` guard prevents stacking an attack.
- **First-time setup bypass**: The first `setWeightConfig()` can set any config (including insecure ones). The `InsecureWeightConfig` check in M6.1 (single source ≥ threshold) prevents obviously bad first configurations.
- **Proposal with invalid config**: Validate the proposed config in `proposeWeightChange` using the same `InsecureWeightConfig` check. Revert early rather than discovering it at execution.
- **Guardian approval for non-existent guardians**: If `_guardianCount < 2`, cannot reach the `WEIGHT_CHANGE_THRESHOLD = 2`. Proposal is submitted but can never be approved. Document: weight change proposals require at least 2 guardians.

### Interaction with M5 Security Model

- Deeply integrates with guardian storage (`_guardianIndex`, `_popcount`, approval bitmap).
- Uses same pattern as `RecoveryProposal` (bitmap, timelock, threshold).
- Does NOT touch `_algTier`, guard, transient storage.
- Interacts with `activeRecovery` (blocks proposal if recovery active).

### Test Strategy

**Unit tests**:
- `setWeightConfig` with all thresholds equal or higher than current → applies immediately
- `setWeightConfig` with one threshold lower → `WeakeningRequiresProposal`
- `proposeWeightChange` with invalid config → `InsecureWeightConfig`
- `proposeWeightChange` during active recovery → `RecoveryInProgress`
- `approveWeightChange` by non-guardian → `NotGuardian`
- `approveWeightChange` twice by same guardian → `WeightChangeAlreadyApproved`
- `executeWeightChange` before timelock → `WeightChangeTimelockNotExpired`
- `executeWeightChange` after timelock, insufficient approvals → `WeightChangeNotApproved`
- Full happy path: propose → 2 guardian approvals → 2 days → execute → weightConfig updated
- `cancelWeightChange` by owner → proposal deleted, can propose again
- Interaction test: active recovery → propose weight change → `RecoveryInProgress`

**Scenario test**:
- Stolen key scenario: owner (stolen key) proposes weakening → guardians refuse to approve → proposal expires → owner proposes recovery → new owner cancels old proposal → sets secure weight config

### Open Questions / Risks

1. **What counts as "weakening"?** The definition in `_isWeakening` is conservative but might be overly broad. For example, redistributing guardian weights without changing thresholds might be flagged. Consider: only flag threshold changes and changes that allow a single source to exceed a threshold. Weight redistribution without threshold change is neutral.
2. **Abandoned proposals**: A proposal can sit indefinitely without approval. Should there be an expiry after which it auto-cancels? (e.g., 30 days). Recommend: add `proposalExpiry = 30 days`. Owner can re-propose after expiry.
3. **No guardian = no weight change governance**: An account with 0 or 1 guardians cannot do governed weight changes. This is correct behavior (not enough social recovery either). Document as a precondition.

---

## M6.5 — Will Execution (Inactivity-Triggered Transfer)

### Difficulty: Hard — ~400 lines of new Solidity + significant off-chain DVT infrastructure

### Dependencies

- **Off-chain DVT multi-chain scanner** must be designed and deployed before on-chain contract is useful
- **`IAAStarAlgorithm.validate` interface**: `WillExecutor` will verify a DVT BLS aggregate proof of inactivity — same BLS algorithm as existing `AAStarBLSAlgorithm`
- M6.4 (Session Key) should be complete to understand DVT co-sign patterns
- No hard code dependency on M6.1/M6.2

### Key Design Decisions

**Architecture**: `WillExecutor.sol` is a standalone contract, NOT inside the account. Any AirAccount can authorize a will by pointing to this contract and providing a signed authorization. The will executor is a shared infrastructure contract, deployed once per chain.

**Will authorization struct**:

```solidity
struct WillAuthorization {
    address account;                // The AirAccount whose inactivity triggers the will
    address heir;                   // Recipient of assets upon execution
    uint96  inactivityThreshold;    // Seconds of inactivity required (e.g., 180 days = 15_552_000)
    uint32  chainScope;             // Bit mask of chainIds to check (0 = this chain only)
    bool    revoked;                // Owner can revoke
    uint64  lastConfirmedActivity;  // Unix timestamp of last confirmed activity (DVT-updated)
    uint64  willCreatedAt;          // When the will was registered
}

// account → WillAuthorization
mapping(address => WillAuthorization) public wills;
```

Packed layout:
- Slot 0: `account(20) | revoked(1) | [11 bytes padding]` — but account is the mapping key, so not stored here
- Store as: `heir(20) | revoked(1) | [11]` in one slot
- `inactivityThreshold(12) | chainScope(4) | lastConfirmedActivity(8) | willCreatedAt(8)` in one slot

**Will registration**:

The owner registers a will by calling `registerWill(heir, inactivityThreshold, chainScope, ownerSig)` on `WillExecutor`. The `ownerSig` is verified against `account.owner()` (via an external call to the account contract):

```solidity
bytes32 willHash = keccak256(abi.encodePacked(
    "REGISTER_WILL",
    block.chainid,
    address(this),   // WillExecutor address
    account,
    heir,
    inactivityThreshold,
    chainScope
)).toEthSignedMessageHash();
```

The owner can call `registerWill` directly from their EOA (no UserOp needed), OR sign the message offline and have anyone submit it. This is important: if the owner is incapacitated but can still sign (e.g., from a hospital bed), they shouldn't need gas.

**Activity confirmation by DVT**:

DVT nodes call `confirmActivity(address account, uint64 timestamp, bytes calldata dvtSignature)`. The DVT signature is a BLS aggregate over `keccak256(abi.encodePacked("ACTIVITY", account, timestamp, block.chainid))` signed by a quorum of DVT nodes. This updates `lastConfirmedActivity`.

DVT nodes observe on-chain activity by scanning for `UserOperationEvent` (EntryPoint events) from `account`. If activity is detected on any chain in `chainScope`, DVT nodes emit an aggregate signature confirming activity.

**Cross-chain inactivity**: `chainScope` is a 32-bit mask where bit `i` corresponds to chainId `i` (for small chainIds like 1=mainnet, 8453=Base — note: Base's chainId won't fit in a bitmap by direct mapping). Use a pre-registered chain index table instead:

```solidity
// Registered chain index: index (0-31) → chainId
mapping(uint8 => uint256) public chainIndex;  // Registered by WillExecutor owner/governance
// chainScope bits map to chainIndex entries
```

This allows up to 32 chain registrations. DVT nodes monitor all chains in the account's `chainScope`.

**Will execution**:

After `inactivityThreshold` seconds without `lastConfirmedActivity` update, any DVT node (or anyone) calls `executeWill(address account, bytes calldata dvtProof)`.

`dvtProof` = BLS aggregate signature over `keccak256(abi.encodePacked("INACTIVITY_CONFIRMED", account, lastConfirmedActivity, inactivityThreshold, block.timestamp))` signed by a quorum of DVT nodes.

`WillExecutor` verifies the BLS proof via `IAAStarAlgorithm(blsAlgorithm).validate(inactivityHash, dvtProof)`. If valid and threshold exceeded, calls the account to transfer assets to heir.

**The transfer execution problem**: `WillExecutor` cannot call `account.execute(heir, balance, "")` because `execute` requires `onlyOwnerOrEntryPoint`. The account must pre-authorize `WillExecutor` as a trusted caller for will execution.

**Resolution — Account-side authorization**: Add to `AAStarAirAccountBase`:

```solidity
address public willExecutor;  // Set by owner; if non-zero, willExecutor can call executeWill()

function setWillExecutor(address _willExecutor) external onlyOwner {
    willExecutor = _willExecutor;
    emit WillExecutorSet(_willExecutor);
}

function executeWill(address heir) external {
    if (msg.sender != willExecutor) revert NotWillExecutor();
    // Transfer all ETH + optionally tokens
    _call(heir, address(this).balance, "");
}
```

The `executeWill(heir)` on the account is called by `WillExecutor`. The account trusts `WillExecutor` to have already verified the DVT proof and inactivity threshold.

**Alternative**: `WillExecutor` submits a UserOp on behalf of the account. But that requires the account to be the sender, and the signature would need to come from... somewhere. The DVT nodes don't have the owner's private key. Unless we use a special DVT-signed UserOp — but this requires a new algId for "DVT-authorized will execution" which is far more complex.

**Recommended approach**: The explicit `willExecutor` address in the account, callable by `WillExecutor.sol`. Simple and auditable.

**Asset scope for the will**: The `executeWill` on the account transfers ETH. For ERC20 tokens, the heir address could call `account.execute(token, 0, abi.encodeCall(IERC20.transfer, (heir, balance)))` after taking ownership... but that requires ownership transfer. Better: include a `tokenList` in `WillAuthorization` and have `WillExecutor` call `account.executeWillWithTokens(heir, tokens[])` which transfers ETH + all listed tokens.

**Timelock on will execution**: Add a mandatory challenge period after DVT submits the inactivity proof. During this window, the owner can demonstrate liveness by calling `cancelWillExecution(account)` with a valid owner signature:

```
WillExecutionPending {
    account: address,
    initiatedAt: uint64,
    dvtProofHash: bytes32
}
challengeWindow = 7 days
```

This prevents DVT node compromise from executing wills immediately. The owner has 7 days to prove they're alive by signing a cancellation.

**Heartbeat protocol (DVT off-chain spec)**:

DVT nodes must implement:
1. `scanActivity(account, chainIds[])` — scan EntryPoint events for UserOperations from `account`
2. `aggregateInactivityProof(account)` — produce BLS aggregate when no activity detected for `threshold - challengeWindow` time
3. `submitActivityConfirmation(account, timestamp)` — call `WillExecutor.confirmActivity()` when activity found
4. `initiateWillExecution(account)` — call `WillExecutor.initiateExecution()` after inactivity confirmed

The DVT nodes for will execution can be a DIFFERENT set than the DVT nodes used for BLS co-signing UserOps. They share the same algorithm contract (`AAStarBLSAlgorithm`) but have different node registration.

### Contract Changes

**New file**: `src/will/WillExecutor.sol` (~300 lines):
- `wills` mapping
- `pendingExecutions` mapping (for challenge period)
- `registerWill(account, heir, inactivityThreshold, chainScope, ownerSig)`
- `revokeWill(account, ownerSig)`
- `confirmActivity(account, timestamp, dvtSig)`
- `initiateExecution(account, dvtProof)`
- `cancelExecution(account, ownerSig)` (owner proves liveness during challenge window)
- `finalizeExecution(account)` (called after challenge window + no cancellation)
- `chainIndex` registry
- `blsAlgorithm` address (immutable, set at construction)
- `dvtNodeSet` address (the registered BLS node registry for will DVT)

**`AAStarAirAccountBase`**:
- Add `address public willExecutor;`
- Add `function setWillExecutor(address) external onlyOwner`
- Add `function executeWill(address heir) external` (only callable by `willExecutor`)
- Add `function executeWillWithTokens(address heir, address[] calldata tokens) external` (only callable by `willExecutor`)
- Add custom error: `NotWillExecutor`
- Add event: `WillExecutorSet`, `WillExecuted`

**`AccountConfig`**: Add `bool hasWillExecutor` and `address willExecutorAddress`.

### Security Considerations

- **DVT node compromise**: If 2-of-3 DVT nodes are compromised, they can false-sign an inactivity proof. The 7-day challenge window gives the real owner time to cancel. If the owner's key is also compromised, they cannot cancel — this is the fundamental limitation.
- **Will vs Recovery attack**: An attacker with 2 compromised guardians could initiate social recovery AND 2 compromised DVT nodes could initiate will execution simultaneously. These are independent attack surfaces — having both compromised simultaneously is extremely unlikely but should be documented.
- **Heir address validation**: `heir` must not be `address(0)` and must not be the account itself. Validate in `registerWill`.
- **Inactivity threshold minimum**: Enforce `inactivityThreshold >= 30 days` to prevent accidental will execution due to DVT delays or user travel.
- **Challenge window**: `challengeWindow` must be significantly less than `inactivityThreshold`. Enforce: `challengeWindow <= inactivityThreshold / 4`.
- **DVT node set for wills**: Should be distinct from transaction DVT nodes. Will DVT nodes are long-running observers; transaction DVT nodes are real-time co-signers. Mixing them creates a single point of failure.
- **Gas griefing on `finalizeExecution`**: Anyone can call `finalizeExecution` after the challenge window. This is acceptable (permissionless finalization is a feature). The DVT nodes are expected to call it if no one else does.
- **Cross-chain asset incompleteness**: The will only executes on the chain where `WillExecutor` is deployed. Assets on other chains are NOT transferred. This is an explicit limitation — document clearly.

### Interaction with M5 Security Model

- Adds `willExecutor` as a new trusted role alongside `entryPoint` and `owner`.
- The `executeWill()` function bypasses tier enforcement and guard limits — this is intentional. A will execution should not be blocked by daily limits. However, the algId whitelist doesn't apply either (no algId in will execution path). This is a deliberate design exception.
- Does NOT touch `_algTier`, guardian storage (M5 guardians are for key recovery; will DVT nodes are separate), or transient storage.
- Guard monotonicity: `executeWill` bypasses the guard entirely. This is an important security note — the guard cannot block will execution. Document as a design intent.

### Test Strategy

**Unit tests for `WillExecutor`**:
- `registerWill`: valid owner sig → will stored
- `registerWill`: invalid sig → revert
- `registerWill`: threshold < 30 days → revert
- `registerWill`: heir = address(0) → revert
- `revokeWill`: owner sig → will deleted
- `confirmActivity`: valid DVT BLS sig → `lastConfirmedActivity` updated
- `confirmActivity`: invalid BLS sig → revert
- `initiateExecution`: before threshold → revert
- `initiateExecution`: after threshold, valid DVT proof → `WillExecutionPending` created
- `cancelExecution`: within challenge window, valid owner sig → pending deleted
- `cancelExecution`: after challenge window → revert
- `finalizeExecution`: before challenge window expires → revert
- `finalizeExecution`: after challenge window, no cancellation → calls account.executeWill

**Unit tests for account `executeWill`**:
- `executeWill`: called by `willExecutor` → transfers ETH to heir
- `executeWill`: called by non-`willExecutor` → `NotWillExecutor`
- `executeWillWithTokens`: transfers ETH + each listed token
- `setWillExecutor`: non-owner → `NotOwner`

**Scenario tests**:
- Full inactivity scenario: register will → DVT nodes scan → no activity for threshold+1 day → DVT submits proof → 7-day window → finalize → heir receives ETH
- Liveness proof: register will → approach threshold → owner submits UserOp → DVT confirms activity → will reset → execution not possible
- Cancellation: will initiated → owner signs cancellation within window → execution blocked

### Open Questions / Risks

1. **DVT off-chain infrastructure timeline**: The on-chain contract is easy; the hard part is building and deploying DVT nodes that scan multiple chains continuously. This is months of backend work. Ship contract first, delay E2E testing until DVT infrastructure is ready.
2. **Cross-chain asset aggregation**: Handling assets on 10 different chains from a single will is a complex UX problem. For M6, scope the will to single-chain ETH only. Multi-chain will is a separate feature.
3. **Inactivity definition**: Does a failed UserOp count as activity? (The EntryPoint emits `UserOperationEvent` even for failed ops.) Recommendation: any UserOp submission counts as activity, regardless of success. The user demonstrated liveness by submitting.
4. **Will update vs revoke+re-register**: Currently no `updateWill` — only revoke + re-register. This requires a new owner signature each time. Consider adding `updateHeir(account, newHeir, ownerSig)` and `updateThreshold(account, newThreshold, ownerSig)` for convenience.
5. **ERC20 token enumeration**: `executeWillWithTokens` requires the will registrant to specify which tokens to transfer. If they forget a token, it won't be transferred. A better design: have DVT nodes detect token balances and submit the full token list at execution time — but this requires off-chain awareness and on-chain trust in DVT's token list. Complex. Defer.
6. **What if `heir` is a smart contract?**: The ETH transfer via `_call` will succeed if the target has a `receive()` fallback. If the heir is a broken contract, ETH gets locked. Consider: heir must be an EOA (check code size = 0). Or accept smart contract heirs and document the risk.

---

## Implementation Sequencing

Given the dependencies and difficulty ratings:

| Order | Feature | Duration Estimate | Gate |
|-------|---------|------------------|------|
| 1 | M6.6a OAPD scripts | 1-2 days | — |
| 2 | M6.4 Session Key | 3-5 days | M6.6a complete |
| 3 | M6.6b Calldata Parser | 3-4 days | M6.4 complete (algId namespace established) |
| 4 | M6.1 Weighted Signature | 5-7 days | M6.4+M6.6b complete |
| 5 | M6.2 Guardian Consent | 2-3 days | M6.1 complete |
| 6 | M6.5 Will Execution | 8-12 days | All others complete; DVT infra separate |

**New constants needed** (to be locked before any M6 implementation starts):
```
ALG_WEIGHTED    = 0x07
ALG_SESSION_KEY = 0x08
```

These must be claimed in `AAStarAirAccountBase` constants section before any feature work begins to prevent accidental collisions.

---

## Summary of All Contract Changes

### New Files
- `src/validators/SessionKeyValidator.sol` (implements `IAAStarAlgorithm`)
- `src/interfaces/ICalldataParser.sol`
- `src/parsers/RailgunCalldataParser.sol`
- `src/parsers/PrivacyPoolsCalldataParser.sol`
- `src/will/WillExecutor.sol`

### Modified Files
- `src/core/AAStarAirAccountBase.sol`:
  - Constants: `ALG_WEIGHTED = 0x07`, `ALG_SESSION_KEY = 0x08`
  - Storage: `WeightConfig public weightConfig`, `WeightChangeProposal public pendingWeightChange`, `mapping(address => ICalldataParser) public calldataParsers`, `address public willExecutor`
  - Constants: `WEIGHT_SLOT_BASE = 0x0A1700`, `WEIGHT_CHANGE_TIMELOCK = 2 days`, `WEIGHT_CHANGE_THRESHOLD = 2`
  - New functions: weight config management (6 functions), parser registry (1 function), will execution (3 functions)
  - Modified: `_validateSignature` (add 0x07 branch), `_enforceGuard` (add parser call + weight branch), `_algTier` (add 0x07 and 0x08)
  - New transient storage helpers: `_storeValidatedWeight`, `_consumeValidatedWeight`
- `src/core/AAStarGlobalGuard.sol`:
  - `_algTier`: add `0x07` returns `0`, add `0x08` to Tier 1 group
- `src/core/AAStarAirAccountFactoryV7.sol`:
  - `_buildDefaultConfig`: add `0x07` and `0x08` to approved algIds (array size: 8)

### Unchanged
- `src/validators/AAStarValidator.sol` — no code changes; new algIds registered via `registerAlgorithm` deploy step
- `src/validators/AAStarBLSAlgorithm.sol` — reused as-is by weighted sigs and will execution
- `src/core/AAStarAirAccountV7.sol` — no changes (thin wrapper)
- `src/interfaces/IAAStarAlgorithm.sol` — no changes
- `src/interfaces/IAAStarValidator.sol` — no changes
- `src/aggregator/AAStarBLSAggregator.sol` — no changes

---

### Critical Files for Implementation

- `/Users/jason/Dev/mycelium/my-exploration/projects/airaccount-contract/src/core/AAStarAirAccountBase.sol` — Core logic to modify: `_validateSignature`, `_enforceGuard`, `_algTier`, storage layout for WeightConfig + calldataParsers + willExecutor + transient weight slot
- `/Users/jason/Dev/mycelium/my-exploration/projects/airaccount-contract/src/core/AAStarGlobalGuard.sol` — Must stay in sync with account's `_algTier`; add `0x07`/`0x08` entries and optional `blockUnconfiguredTokens` flag
- `/Users/jason/Dev/mycelium/my-exploration/projects/airaccount-contract/src/core/AAStarAirAccountFactoryV7.sol` — Approved algId list expansion (add 0x07, 0x08); test that factory constructor validation still passes with 8-element array
- `/Users/jason/Dev/mycelium/my-exploration/projects/airaccount-contract/src/validators/AAStarValidator.sol` — Pattern to follow for `SessionKeyValidator` registration (algId 0x08) and weighted sig routing (algId 0x07)
- `/Users/jason/Dev/mycelium/my-exploration/projects/airaccount-contract/src/interfaces/IAAStarAlgorithm.sol` — Interface all new validator modules (`SessionKeyValidator`, will DVT verifier) must implement; `validate(bytes32, bytes) → uint256`
