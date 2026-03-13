# M5 Milestone Plan — ERC20 Token Guard, Governance Hardening & Chain Expansion

## Overview

M5 focuses on three main areas:
1. **ERC20/Token value-aware tier enforcement** — extend Guard to cover token transfers, not just ETH
2. **Governance hardening** — Validator timelock enforcement, messagePoint binding, guardian validation
3. **Chain compatibility** — P256/BLS fallback support for broader L2 deployment

## M4 Deployment (Prerequisite — DONE)

- **M4 Factory**: `0x914db0a849f55e68a726c72fd02b7114b1176d88`
- **200 Foundry tests + 15 Sepolia E2E tests**: ALL PASSED
- **Finding 1 fixed**: `_lastValidatedAlgId` → transient storage queue (prevents cross-UserOp contamination)
- **Finding 2 fixed**: `registerPublicKey` now `onlyOwner`
- **Finding 5 fixed**: `setTierLimits` validates `tier1 <= tier2`
- **Finding 6 fixed**: `createAccountWithDefaults` validates guardian non-zero

---

## M5.1 — ERC20 Token-Aware Guard (calldata-based, no oracle)

### Business Goal

Current Guard only checks `msg.value` (ETH). ERC20 transfers (`value=0`) bypass tier enforcement entirely. M5 extends Guard to parse calldata and enforce per-token spending limits.

### Design Principles

1. **No price oracle** — check raw token amounts in calldata, not USD value
2. **Per-token daily limits** — each token has its own tier thresholds, configured in native token units
3. **Monotonic security** — daily limits can only tighten (decrease), tokens can only be added
4. **Admin-extensible** — multisig (Safe) can add new tokens after deployment
5. **Immutable base tokens** — known tokens (ETH, USDC, USDT, WETH, WBTC, aPNTs, GToken) configured at deployment

### Current Implementation (M4)

```solidity
// AAStarAirAccountBase.sol
uint256 public tier1Limit; // e.g., 0.1 ETH — ECDSA only
uint256 public tier2Limit; // e.g., 1 ETH — dual factor

function setTierLimits(uint256 _tier1, uint256 _tier2) external onlyOwner {
    if (_tier1 > _tier2 && _tier2 > 0) revert InvalidTierConfig();
    tier1Limit = _tier1;
    tier2Limit = _tier2;
}
```

- `tier1Limit` / `tier2Limit` are **mutable storage**, settable by `onlyOwner`
- No restriction on increasing (can loosen — NOT monotonic for tier limits)
- Only applies to ETH (msg.value)
- User can change limits at any time via `setTierLimits`

### Design Options

#### Option A: Extend AAStarGlobalGuard (Recommended)

Add token config to the existing Guard contract. Guard is already monotonic and bound to account.

```solidity
// New structs in AAStarGlobalGuard
struct TokenTierConfig {
    uint256 tier1Limit;    // small — ECDSA only (in token's native decimals)
    uint256 tier2Limit;    // medium — P256+BLS
    uint256 dailyLimit;    // total daily spending (in token's native decimals)
}

// New storage
mapping(address => TokenTierConfig) public tokenConfigs;
mapping(address => mapping(uint256 => uint256)) public tokenDailySpent; // token → day → spent
address[] public configuredTokens; // for enumeration

// Constructor initializes base tokens
constructor(
    address _account,
    uint256 _dailyLimit,       // ETH daily limit
    uint8[] memory _algIds,
    TokenInitConfig[] memory _baseTokens  // immutable base tokens
) {
    // ... existing logic
    for (uint i = 0; i < _baseTokens.length; i++) {
        tokenConfigs[_baseTokens[i].token] = _baseTokens[i].config;
        configuredTokens.push(_baseTokens[i].token);
    }
}

// Admin can add new tokens (only add, never remove)
function addTokenConfig(address token, TokenTierConfig calldata config) external onlyAccount {
    require(tokenConfigs[token].dailyLimit == 0, "Already configured");
    tokenConfigs[token] = config;
    configuredTokens.push(token);
}

// Admin can decrease token daily limit (monotonic tighten)
function decreaseTokenDailyLimit(address token, uint256 newLimit) external onlyAccount {
    require(newLimit < tokenConfigs[token].dailyLimit, "Can only decrease");
    tokenConfigs[token].dailyLimit = newLimit;
}

// Check ERC20 transfer
function checkTokenTransaction(
    address token,
    uint256 amount,
    uint8 algId
) external onlyAccount returns (bool) {
    if (!approvedAlgorithms[algId]) revert AlgorithmNotApproved(algId);
    TokenTierConfig memory config = tokenConfigs[token];
    if (config.dailyLimit == 0) return true; // unconfigured token → no limits
    // ... tier check + daily limit logic
}
```

**Calldata parsing in account:**

```solidity
function _enforceGuard(uint256 value, uint8 algId, address dest, bytes calldata func) internal {
    // ETH value check (existing)
    _enforceEthGuard(value, algId);

    // ERC20 calldata check (new)
    if (func.length >= 68 && address(guard) != address(0)) {
        bytes4 selector = bytes4(func[:4]);
        if (selector == 0xa9059cbb || selector == 0x095ea7b3) {
            // transfer(to, amount) or approve(spender, amount)
            uint256 tokenAmount = abi.decode(func[36:68], (uint256));
            guard.checkTokenTransaction(dest, tokenAmount, algId);
        }
    }
}
```

**Gas**: +1 SLOAD per ERC20 check (~2,100 gas). Negligible for ETH-only transactions.

**Pros**: Reuses existing Guard monotonic model. No new contract. Simple.
**Cons**: Guard constructor gets larger. Requires Factory update for base token init.

#### Option B: Separate TokenGuard Contract

Deploy a new `AAStarTokenGuard` alongside `AAStarGlobalGuard`.

```solidity
contract AAStarTokenGuard {
    address public immutable account;
    // Same token config logic as Option A
    // Deployed atomically in account constructor alongside GlobalGuard
}
```

**Pros**: Clean separation. GlobalGuard stays simple.
**Cons**: Extra deployment gas (~400k). Two guard checks per execute. More complex.

#### Option C: Modular ERC-7579 Hook

Implement token guard as an ERC-7579 hook module (requires kernel-style module system).

**Pros**: Standard module interface. Composable.
**Cons**: Requires major architectural change. Not compatible with current non-modular design.

### Recommendation

**Option A** — extend existing Guard. Reasoning:
1. Guard is already monotonic and immutable-bound — no new trust assumptions
2. One contract, one check — minimal gas overhead
3. Constructor can accept base tokens as parameter
4. Factory update is needed anyway for M5 contract changes

### Base Token Configuration (Sepolia)

| Token | Address | Decimals | Tier1 (small) | Tier2 (medium) | Daily Limit |
|-------|---------|----------|---------------|----------------|-------------|
| ETH | native | 18 | 0.1 ETH | 1 ETH | 5 ETH |
| USDC | network-specific | 6 | 100 USDC | 1,000 USDC | 5,000 USDC |
| USDT | network-specific | 6 | 100 USDT | 1,000 USDT | 5,000 USDT |
| WETH | network-specific | 18 | 0.1 WETH | 1 WETH | 5 WETH |
| WBTC | network-specific | 8 | 0.005 WBTC | 0.05 WBTC | 0.2 WBTC |
| aPNTs | `0xDf66...` | 18 | 1,000 aPNTs | 10,000 aPNTs | 50,000 aPNTs |
| GToken | `0x9ceD...` | 18 | 1,000 GT | 10,000 GT | 50,000 GT |

Note: These are example defaults. User/admin can adjust limits downward after deployment.

### Tier Limit Mutability Discussion

**Current (M4)**: `setTierLimits` allows both increase and decrease — NOT monotonic.

**Question**: Should tier limits also be monotonic (only decrease)?

**Analysis**:
- **Pro monotonic**: Consistent with Guard's "only tighten" principle. A stolen key can't loosen limits.
- **Con monotonic**: User might legitimately want to increase tier1 limit as they build trust. Overly restrictive.
- **Recommended approach**: Keep ETH tier limits owner-mutable (current behavior). Token tier limits in Guard follow monotonic (decrease-only). The Guard provides a hard floor that the owner cannot bypass.

### ERC20 Selectors to Monitor

| Selector | Function | Value Field |
|----------|----------|-------------|
| `0xa9059cbb` | `transfer(address,uint256)` | `func[36:68]` |
| `0x095ea7b3` | `approve(address,uint256)` | `func[36:68]` |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | `func[68:100]` |

For M5, support `transfer` and `approve` only. `transferFrom` and DeFi interactions (swap, addLiquidity) deferred to M6.

### Tasks

- [ ] F47: Add `TokenTierConfig` struct and token storage to `AAStarGlobalGuard`
- [ ] F48: Implement `checkTokenTransaction()` with tier + daily limit enforcement
- [ ] F49: Add `addTokenConfig()` and `decreaseTokenDailyLimit()` (monotonic)
- [ ] F50: Implement calldata parsing in `_enforceGuard` for ERC20 selectors
- [ ] F51: Update Factory constructor to accept base token configs
- [ ] F52: Unit tests for token guard (all tiers, daily limits, monotonic)
- [ ] F53: Integration test — ERC20 transfer blocked by insufficient tier

---

## M5.2 — Governance Hardening

### Tasks

- [ ] F54: Add `setupComplete` flag to Validator — disable `registerAlgorithm` after initial setup
  ```solidity
  bool public setupComplete;
  function finalizeSetup() external onlyOwner { setupComplete = true; }
  function registerAlgorithm(uint8 algId, address alg) external {
      if (setupComplete) revert SetupAlreadyClosed();
      // ... existing logic
  }
  ```
  After initial deployment, owner calls `finalizeSetup()`. Future algorithm additions must use the 7-day timelock path (`proposeAlgorithm` → `executeProposal`). Owner can then transfer ownership to Safe multisig.

- [ ] F55: Bind messagePoint signature to userOpHash
  ```solidity
  // Before:
  bytes32 mpHash = keccak256(messagePoint).toEthSignedMessageHash();
  // After:
  bytes32 mpHash = keccak256(abi.encodePacked(userOpHash, messagePoint)).toEthSignedMessageHash();
  ```
  Prevents messagePoint signature reuse across different UserOps.

- [ ] F56: Guardian acceptance flow — require guardian signature at account creation
  See M5.3 below for detailed design.

---

## M5.3 — Guardian Validation (Accept-Pattern)

### Problem

Current `createAccountWithDefaults` allows any address as guardian. If a user enters an invalid/wrong address, social recovery becomes permanently impossible (2-of-3 threshold unreachable).

### Design Options

#### Option A: Off-chain Validation Only

Frontend verifies guardian addresses are valid EOAs before calling Factory. No contract change.

**Pros**: Zero gas cost. Simple.
**Cons**: Doesn't protect against direct Factory calls (scripts, bots). No on-chain guarantee.

#### Option B: Guardian Signature at Creation (Atomic)

Require each guardian to sign a message proving they accept. Pass signatures to Factory.

```solidity
function createAccountWithDefaults(
    address owner, uint256 salt,
    address guardian1, bytes calldata guardian1Sig,
    address guardian2, bytes calldata guardian2Sig,
    uint256 dailyLimit
) external returns (address account) {
    // Verify guardian1 signed: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt))
    bytes32 acceptHash = keccak256(abi.encodePacked("ACCEPT_GUARDIAN", owner, salt));
    bytes32 ethHash = acceptHash.toEthSignedMessageHash();
    require(ethHash.recover(guardian1Sig) == guardian1, "Guardian1 not accepted");
    require(ethHash.recover(guardian2Sig) == guardian2, "Guardian2 not accepted");
    // ... deploy
}
```

**Pros**: Atomic — account is created with verified guardians. On-chain guarantee.
**Cons**: Guardians must sign before account creation. Adds coordination step. Extra gas (~6k for 2 ecrecover).

#### Option C: Post-Creation Accept (Two-Phase)

Account is created with "pending" guardians. Each guardian calls `acceptGuardianRole()` on the account.

```solidity
// In AAStarAirAccountBase:
mapping(uint8 => bool) public guardianAccepted;

function acceptGuardianRole() external {
    uint8 idx = _guardianIndex(msg.sender); // reverts if not guardian
    guardianAccepted[idx] = true;
    emit GuardianAccepted(idx, msg.sender);
}

// Social recovery checks guardianAccepted before allowing proposals
function proposeRecovery(address _newOwner) external {
    uint8 idx = _guardianIndex(msg.sender);
    require(guardianAccepted[idx], "Guardian not accepted");
    // ...
}
```

**Pros**: No coordination needed at creation time. Guardian verifies at their convenience.
**Cons**: Recovery doesn't work until guardians accept. Two-phase complexity.

### Recommendation

**Option B** for `createAccountWithDefaults` (convenience method — guardians should confirm).
**No change** for `createAccount` (full-config method — advanced users take responsibility).

The UX flow:
1. Frontend asks user to invite 2 guardians
2. Each guardian receives an invite link
3. Guardian opens link → signs "I accept being guardian for [owner] account"
4. Frontend collects 2 signatures
5. Frontend calls `createAccountWithDefaults(owner, salt, g1, g1Sig, g2, g2Sig, dailyLimit)`
6. Account deployed with verified guardians

### Tasks

- [ ] F56: Implement guardian signature verification in `createAccountWithDefaults`
- [ ] F57: Update frontend onboarding flow with guardian invitation step
- [ ] F58: Unit tests for guardian acceptance (valid sig, invalid sig, wrong signer)

---

## M5.4 — Chain Compatibility & Fallback

### Precompile Support Status (as of 2026-03)

| Chain | P256 (0x100) | Since | BLS12-381 (0x0a-0x10) | Since |
|-------|-------------|-------|----------------------|-------|
| **Ethereum Mainnet** | YES (EIP-7951) | 2025-12-03 (Fusaka) | YES (EIP-2537) | 2025-05-07 (Pectra) |
| **Optimism** | YES (RIP-7212) | 2024-07-10 (Fjord) | YES (EIP-2537) | 2025-05-09 (Isthmus) |
| **Base** | YES (RIP-7212) | 2024-07-10 (Fjord) | YES (EIP-2537) | 2025-05-09 (Isthmus) |
| **Other Superchain** (Ink, Soneium, Unichain, Zora, Mode) | YES | Fjord+ | YES | 2025-05-09 (Isthmus) |
| **Arbitrum One/Nova** | YES (RIP-7212) | ~2024 Q3 (ArbOS 31) | YES (EIP-2537) | ~2025-06 (ArbOS 40) |
| **Polygon PoS** | YES (PIP-27) | 2024-03 (Napoli) | PLANNED | Lisovo (draft, 2026) |
| **zkSync Era** | YES (RIP-7212) | Protocol v24 | UNKNOWN | No timeline |
| **Scroll** | PLANNED | 2025 roadmap | UNKNOWN | No timeline |
| **Linea** | UNKNOWN | — | IN PROGRESS | gnark PR |
| **Celo** (OP Stack) | YES | Fjord+ | YES | 2025-07-09 (Isthmus) |

**Key findings:**
- **Best deployment targets**: Ethereum mainnet, OP Stack (Optimism/Base), Arbitrum — all support both P256 and BLS
- **P256-only chains**: Polygon PoS, zkSync — can use Tier 1 (ECDSA) and Tier 2 (P256 alone) but NOT BLS-dependent tiers
- **EIP-7951 vs RIP-7212**: Mainnet uses EIP-7951 (security fix of RIP-7212), same interface at `0x100`, gas 6,900 vs 3,450

**EIP-2537 address mapping** (verified against [official spec](https://eips.ethereum.org/EIPS/eip-2537)):
- `0x0b` = G1ADD ✅ (our code uses this)
- `0x0c` = G1MSM, `0x0d` = G2ADD, `0x0e` = G2MSM
- `0x0f` = PAIRING_CHECK ✅ (our code uses this)
- `0x10` = MAP_FP_TO_G1, `0x11` = MAP_FP2_TO_G2

Our precompile addresses are correct. No changes needed.

### Deployment Requirement (Final Decision — 2026-03-13)

AirAccount requires **both** EIP-7212 and EIP-2537 precompiles. No fallback.

| Chain | EIP-7212 (P256, 0x100) | EIP-2537 (BLS, 0x0b–0x12) | Deploy? |
|-------|----------------------|--------------------------|---------|
| Ethereum mainnet | ✅ Fusaka 2025-12-03 | ✅ Pectra 2025-05-07 | ✅ |
| Base | ✅ Fjord 2024-07-10 | ✅ Isthmus 2025-05-09 | ✅ |
| Optimism | ✅ Fjord 2024-07-10 | ✅ Isthmus 2025-05-09 | ✅ |
| Arbitrum One/Nova | ✅ ArbOS 31 ~2024 Q3 | ✅ ArbOS 51 2026-01-08 | ✅ |
| BNB Chain | verify | ✅ Pascal 2025-03-20 | verify |
| zkSync Era | ✅ early adopter | verify | verify |

Fallback verifiers were considered (F60, F61) and **rejected**: pure-Solidity P256
costs ~280k gas (~100× precompile), making gas unpredictable and potentially worse
than a clean failure. Fail-fast is the correct behavior. Verify precompile support
before deploying to any new chain.

- [x] F59: Chain deployment table documented above
- [x] F60: Rejected — fail-fast instead of Solidity fallback
- [x] F61: Rejected — same rationale as F60
- [ ] F62: Multi-chain deployment script with per-chain precompile verification

---

## M5.5 — Weight-Based Multi-Signature (From M4.5 Research) → DEFERRED TO M6

> **Decision (2026-03-13)**: M5.5 is moved to M6. The current Tier 1/2/3 cumulative model
> covers 95% of use cases and is battle-tested (203 unit tests + 15 E2E tests).
> Weight-based signatures require a frontend config UI for weight customization.
> Adding algId 0x06 as opt-in without breaking existing 0x04/0x05 is planned for M6.
> See full analysis in `docs/M4.5-weighted-signature-research.md`.

---

## M5.6 — Gas Optimization Completion (From M5 branch)

### Already Done in M5 branch

- [x] **Assembly ecrecover** in `_validateECDSA` — ~500 gas/tx saved (`AAStarAirAccountBase.sol`)
- [x] **BLS key cache script** — `scripts/cache-bls-keys.ts` for pre-computing `cacheAggregatedKey()`

### Tasks

- [ ] F67: BLS aggregator account integration — set `blsAggregator` on accounts, test batch UserOp flow
- [ ] F68: SDK integration for `handleAggregatedOps` batch submission (off-chain bundler changes)
- [ ] F69: NodeId compression — replace bytes32 nodeIds with uint8 indices for smaller calldata
- [ ] F70: E2E batch gas benchmark — verify ~150k gas/op with 3+ batched UserOps

---

## M5.7 — Force Guard Requirement

### Problem

`createAccount(owner, salt, config)` with empty config creates an unguarded account
(`guard = address(0)`). This is intentional for testing but inadvisable for production.

### Design

Enforce guard in the factory's convenience method while keeping the raw `createAccount`
flexible (for testing and advanced use cases):

```solidity
// In AAStarAirAccountFactoryV7.createAccount():
// Option: require non-empty approvedAlgIds OR non-zero dailyLimit
// OR: just document that createAccountWithDefaults is the production path
```

### Tasks

- [ ] F71: Evaluate whether to enforce guard in `createAccount()` or only in `createAccountWithDefaults()`
- [ ] F72: If enforced: add `require(config.approvedAlgIds.length > 0 || config.dailyLimit > 0)`
- [ ] F73: Update factory tests for the enforcement

---

## M5.8 — Zero-Trust Tier 1: ALG_COMBINED_T1 (0x06)

### Problem

The current TE (Trusted Execution Environment) model has a trust gap:

```
User → [P256 passkey authenticates to TE off-chain] → TE signs with ECDSA → chain sees ECDSA only
```

When a user submits an ECDSA Tier 1 UserOp, the chain has no way to verify whether the
TE actually required P256 authentication before signing. A compromised TE or stolen ECDSA
key can transact without any passkey involvement.

The zero-trust model requires that both the TE (ECDSA key) AND the device (P256 passkey)
sign the same `userOpHash` independently. Neither trusts the other — the chain verifies both.

### Design: ALG_COMBINED_T1 = 0x06

New algId `0x06` simultaneously verifies **P256 passkey AND owner ECDSA** on-chain.
Neither signature alone is sufficient. Both must be valid against the same `userOpHash`.

**Signature format** (130 bytes total):
```
[0x06][P256_r(32)][P256_s(32)][ECDSA_r(32)][ECDSA_s(32)][ECDSA_v(1)]
  1  +    32     +    32     +    32      +    32      +    1       = 130 bytes
```

**Validation logic**:
```solidity
uint8 internal constant ALG_COMBINED_T1 = 0x06;

function _validateCombinedT1(
    bytes32 userOpHash,
    bytes calldata sigData
) internal view returns (uint256) {
    if (sigData.length != 130) return 1;

    // Verify P256 passkey signs userOpHash directly
    bytes32 p256r = bytes32(sigData[0:32]);
    bytes32 p256s = bytes32(sigData[32:64]);
    (bool p256ok,) = P256_VERIFIER.staticcall(
        abi.encode(userOpHash, p256r, p256s, p256x, p256y)
    );
    if (!p256ok) return 1;

    // Verify ECDSA owner signs userOpHash (EIP-191 prefix)
    bytes32 hash = userOpHash.toEthSignedMessageHash();
    bytes32 r; bytes32 s; uint8 v;
    assembly {
        r := calldataload(add(sigData.offset, 64))
        s := calldataload(add(sigData.offset, 96))
        v := byte(0, calldataload(add(sigData.offset, 128)))
    }
    if (v < 27) v += 27;
    address recovered;
    assembly {
        let ptr := mload(0x40)
        mstore(ptr, hash)
        mstore(add(ptr, 32), v)
        mstore(add(ptr, 64), r)
        mstore(add(ptr, 96), s)
        let ok := staticcall(3000, 1, ptr, 128, ptr, 32)
        if ok { recovered := mload(ptr) }
    }
    return (recovered != address(0) && recovered == owner) ? 0 : 1;
}
```

**Tier mapping**: `_algTier(0x06) = 1` — same Tier 1 spending limits, but dual-factor enforced.

**Trust model comparison**:

| algId | What chain verifies | TE trust requirement |
|-------|--------------------|-----------------------|
| 0x02 (ECDSA) | ECDSA only | Full trust in TE |
| 0x03 (P256) | P256 only | N/A (device-bound) |
| 0x06 (combined) | P256 AND ECDSA | Zero trust — both verified independently |

**Trade-offs**:
- PRO: Chain independently verifies P256 passkey — no trust in TE
- PRO: Stolen ECDSA key alone cannot transact (needs device P256)
- PRO: Compromised TE alone cannot transact (needs device P256)
- PRO: No new storage slot — reuses existing `p256x`/`p256y` and `owner`
- CON: Gas cost ~90k (P256 ~40k + ECDSA ~45k) vs ~45k for single sig
- CON: Automation scripts need both keys — breaks pure-ECDSA bots
- CON: If P256 key is lost, must use social recovery (same as T2/T3)

**Recommendation**: opt-in by account. Users with high security requirements use 0x06 for
all transactions. Standard automation-friendly accounts continue using 0x02.

### Tasks

- [ ] F74: Add `ALG_COMBINED_T1 = 0x06` constant to `AAStarAirAccountBase`
- [ ] F75: Implement `_validateCombinedT1()` in `AAStarAirAccountBase`
- [ ] F76: Update `_validateSignature()` dispatch: route 0x06 to `_validateCombinedT1`
- [ ] F77: Update `_algTier()`: `case 0x06: return 1;`
- [ ] F78: Add 0x06 to default approved algorithms in factory `_buildDefaultConfig()`
- [ ] F79: Unit tests — both sigs valid, P256 invalid, ECDSA invalid, wrong length

---

## Priority Order (updated 2026-03-13)

1. **M5.1** (F47-F53) — ERC20 token guard ← highest business value
2. **M5.2** (F54-F55) — Governance hardening ← security critical (C-1/C-2/H-3 from security review)
3. **M5.3** (F56-F58) — Guardian validation ← UX improvement
4. **M5.4** (F59-F62) — Chain compatibility ← deployment expansion
5. **M5.6** (F67-F70) — Gas optimization (BLS aggregator integration)
6. **M5.7** (F71-F73) — Force guard requirement ← production safety
7. **M5.8** (F74-F79) — Zero-trust T1: ALG_COMBINED_T1 (0x06) ← advanced security
8. **M5.5** → **MOVED TO M6** — Weight-based signatures

---

## Test Plan

### Unit Tests (target: +50 tests)
- Token guard: tier enforcement, daily limits, monotonic decrease, unknown token passthrough
- Validator: setupComplete flag, registerAlgorithm blocked after finalize
- messagePoint: bound to userOpHash, old-format signature rejected
- Guardian: acceptance signatures, invalid signer rejection
- P256-required mode: enabled/disabled paths
- Force guard: factory enforcement

### E2E Tests (target: +5 tests)
- ERC20 transfer blocked by insufficient tier
- ERC20 approval blocked by daily limit
- Guardian acceptance flow on Sepolia
- Multi-chain deployment (Sepolia + OP Sepolia)
- Batch UserOp via aggregator (BLS Tier 2/3)

---

---

## Feature Business Scenarios — Before & After

> Each M5 feature is motivated by a real user/business scenario. This section documents
> the exact problem that existed before, how users were affected, and what the feature
> enables after implementation.

---

### M5.1 — ERC20 Token-Aware Guard

#### Before (M4 and earlier)

**Scenario**: Alice holds 10,000 USDC in her AirAccount. Her account tier limits are
configured as: Tier 1 ≤ 0.1 ETH (ECDSA only), Tier 2 ≤ 1 ETH (P256+BLS).

Alice's phone is stolen. The thief extracts her TE (Trusted Execution Environment) ECDSA
key — perhaps via a compromised app or a vulnerable device. The guard prevents ETH transfers
above 0.1 ETH with ECDSA alone. However, the thief calls:

```
account.execute(USDC, 0, transfer(thief_wallet, 10000 * 1e6))
```

`msg.value = 0` — the guard's ETH check passes. The ERC20 calldata is ignored.
**All 10,000 USDC is drained with a single ECDSA signature.**

**Impact**: Any ERC20 token could be fully drained despite spending limits "protecting"
the account. Real-world DeFi accounts hold 80%+ of value in ERC20 tokens.

#### After (M5.1)

The guard parses `transfer(address,uint256)` and `approve(address,uint256)` calldata.
Token-specific tier thresholds apply (configured in native token units — no oracle needed):

```
USDC: tier1Limit = 100e6 ($100), tier2Limit = 1000e6 ($1000), dailyLimit = 5000e6 ($5000)
```

Same attack scenario:
- Thief tries `transfer(thief, 10000 USDC)` with ECDSA → `InsufficientTokenTier(2, 1)` — **REVERTED**
- Thief tries ten batches of 60 USDC each → cumulative check catches it at the second call — **REVERTED**
- Thief tries across multiple blocks → `tokenDailySpent` persists per 24-hour window — **CAPPED**

Alice recovers her account via social recovery. The thief got nothing.

**Business value**: Closes the #1 attack surface on smart wallets — ERC20 draining.
Required for production DeFi wallets where token balances exceed ETH balances.

---

### M5.2 — Governance Hardening (setupComplete + messagePoint binding)

#### Before (M4 and earlier)

**Scenario A — Rogue validator registration**:
The AAStar team deploys a validator router. Any time after deployment, the team's owner
key could call `registerAlgorithm(0x02, maliciousECDSA)` and silently replace the ECDSA
verifier with a backdoored version — no timelock, no community warning, immediate effect.
Users would have no on-chain signal that the validator was modified post-setup.

**Scenario B — messagePoint cross-UserOp replay**:
An EntryPoint bundler collects UserOps from Alice and Bob in the same block. Both use
Tier 2 (P256+BLS). Alice's messagePoint is `mp_alice`. The bundler (or a watching DVT node)
extracts `mp_alice` and its signature from the mempool. If Alice later submits another
UserOp with the same P256+BLS combo (different `userOpHash`), the node can replay the old
`mpSig_alice` — the old signature still validates because `keccak256(mp)` doesn't include
`userOpHash`. This allows a malicious DVT node to participate in tier 2/3 validation for
UserOps it never actually verified.

#### After (M5.2)

**A — setupComplete**:
The team calls `finalizeSetup()` once all initial algorithms are registered.
`setupComplete = true` is stored on-chain and emits `SetupFinalized`. Any user can verify
this state. After finalization:
- `registerAlgorithm` reverts with `SetupAlreadyClosed`
- New algorithms require `proposeAlgorithm(algId, addr)` + 7-day wait + `executeProposal(algId)`
- Community has 7 days to audit and reject any suspicious proposal

**B — messagePoint binding**:
Owner now signs `keccak256(abi.encodePacked(userOpHash, messagePoint))`. The signature is
tied to a specific UserOperation. Replay from a different UserOp produces a different hash —
the old signature fails `ecrecover`. DVT node collaboration is proven per-operation.

**Business value**: Validator governance matches the security level of a 7-day Safe timelock.
MessagePoint binding closes the BLS relay attack surface documented in security review.

---

### M5.3 — Guardian Validation (Accept-Pattern)

#### Before (M4 and earlier)

**Scenario**: David creates an AirAccount for his elderly mother Carol. He names her friend
Bob as guardian 2. David accidentally types Bob's address wrong (one character off).

`createAccountWithDefaults(carol, 0, alice, 0xBOB_TYPO, limit)` — succeeds silently.

Six months later, Carol's phone is lost. She needs social recovery. She contacts Bob.
Bob tries to call `approveRecovery()` — his transaction fails because the stored guardian
address is the wrong one. The actual `0xBOB_TYPO` address is an uncontrolled throwaway.
With only 1-of-3 guardians able to sign (Alice), recovery is permanently impossible.
Carol's funds are locked forever.

**Additional scenario**: A UI bug in a web app pre-fills a guardian field with
`0x0000...0000` (zero address). The factory call succeeds, but zero address can never sign.

#### After (M5.3)

`createAccountWithDefaults` requires guardian acceptance signatures:
```typescript
// Guardian1 must sign before account creation
const acceptMsg = keccak256(encodePacked(["ACCEPT_GUARDIAN", owner, salt]))
const guardian1Sig = await guardian1Wallet.signMessage(acceptMsg)
```

If Bob types his own address wrong (signs with his real key but wrong address in the call),
`tryRecover(guardian1Sig)` returns a different address → `GuardianDidNotAccept(wrongAddr)`.

If the UI puts zero address, there's no key to sign with → `GuardianDidNotAccept(0x0)`.

The account can only be created when both named guardians prove they hold the correct key.

**Business value**: Eliminates the #1 social recovery failure mode (wrong guardian address).
Matches the UX expectations of non-technical users who expect the app to validate inputs.
Required for any production onboarding flow.

---

### M5.4 — Chain Compatibility & P256 Fallback

#### Before (M4 and earlier)

**Scenario**: The AAStar team wants to deploy AirAccount on Polygon PoS for a partner
who needs gasless UX with aPNTs on Polygon. AirAccount uses the EIP-7212 precompile at
`0x100` for P256 verification. On Polygon PoS (Napoli upgrade), P256 is at a different
address. The `staticcall` to `0x100` fails silently — `_validateP256` returns 1 (failure).

Every P256 transaction is rejected. The account falls back to ECDSA-only mode, but
ALG_P256 and all cumulative algorithms (T2, T3, COMBINED_T1) stop working. The partner
cannot offer tiered security on Polygon.

Similarly, zkSync Era implements P256 via RIP-7212 but with a different precompile address.

#### After (M5.4)

Owner calls `setP256FallbackVerifier(daimoP256VerifierAddr)` after account creation.

`daimoP256VerifierAddr` is Daimo's pure-Solidity P256Verifier.sol — a well-audited,
gas-optimized (~174k gas) fallback deployed at a known address on all chains.

`_validateP256` tries the EIP-7212 precompile first (3000 gas, fast). If the precompile
call fails or returns empty, it falls back to the Solidity verifier seamlessly.

Account owners on Polygon, zkSync, Linea, and Scroll can:
1. Deploy the account normally
2. Call `setP256FallbackVerifier(daimo_verifier_on_this_chain)`
3. All P256-based tiers (T2, T3, COMBINED_T1) work immediately

**Business value**: Unlocks deployment on 4+ additional chains without contract changes.
Same security guarantee, same UX, chain-agnostic P256 verification.

---

### M5.7 — Force Guard Requirement (dailyLimit > 0)

#### Before (M4 and earlier)

**Scenario**: A developer integrates AirAccount for a mobile wallet. They call:
```solidity
createAccountWithDefaults(owner, 0, g1, g2, 0)
```

`dailyLimit = 0` means **no cap** (per Guard design: `if (dailyLimit > 0) { check cap }`).
The guard is deployed and linked, but it imposes zero limits. The account is functionally
unguarded. Any tier-1 ECDSA transaction can drain unlimited ETH.

A code review would see "guard configured" and assume security is in place. But
`dailyLimit = 0` is a footgun that looks safe but isn't.

#### After (M5.7)

```
require(dailyLimit > 0, "Daily limit required")
```

`createAccountWithDefaults` rejects zero limit. Developers must explicitly choose a limit.
This forces a conversation: "What's the user's daily spending limit?" rather than accepting
a default that disables all protection.

Raw `createAccount(owner, salt, config)` remains unrestricted for testing and advanced use.

**Business value**: Prevents a class of misconfiguration bugs in production wallet deployments.
Forces developers to reason about spending limits during integration rather than post-incident.

---

### M5.8 — Zero-Trust Tier 1 (ALG_COMBINED_T1 = 0x06)

#### Before (M4 and earlier)

**Scenario**: AirAccount's Tier 1 uses ECDSA — the owner key held by the TE (Trusted
Execution Environment). The TE asks the device passkey (P256) to authenticate, then signs
the UserOp with ECDSA. On-chain, the validator only sees the ECDSA signature.

Attack model: An advanced attacker compromises the TE itself (OS vulnerability, SDK exploit,
supply chain attack on the wallet app). The attacker now holds the ECDSA key. They can:
- Submit up to `tier1Limit` ETH per transaction (e.g., 0.1 ETH)
- Do so 10 times per day up to `dailyLimit` (e.g., 1 ETH/day)
- The chain cannot distinguish "TE signed after passkey auth" vs "attacker signed directly"

For users who keep small balances, this is acceptable. For power users with `tier1Limit`
of 0.01 ETH and 0.1 ETH daily — still 0.1 ETH daily risk from TE compromise.

#### After (M5.8)

With `ALG_COMBINED_T1 = 0x06`, the account verifies BOTH on-chain:
1. P256 passkey signs `userOpHash` directly (device-bound — cannot be extracted from TE)
2. ECDSA owner key signs `userOpHash` with EIP-191 prefix

The TE compromise scenario:
- Attacker has ECDSA key ✓
- Attacker lacks physical device + biometric → cannot produce P256 signature ✗
- On-chain verification of P256 fails → transaction rejected

The device theft scenario:
- Attacker has device + can unlock biometric ✓ → P256 signature OK
- But ECDSA key is in TE (server-side) → cannot produce ECDSA signature ✗
- Both must be valid → transaction rejected

Only when BOTH the physical device AND the TE key cooperate can a Tier-1 transaction
proceed. The user's account security now matches a hardware wallet — no single point of
compromise can drain funds.

**Business value**: Closes the last trust gap in the Tier 1 security model. Enables
institutional-grade security for casual transactions. Recommended for accounts where
`tier1Limit` is set high enough that TE compromise represents meaningful financial risk.

---

## Post-M5 Checklist (run after all M5 tasks complete)

- [ ] **Gas Analysis V2** — Update `docs/gas-analysis.md` with M5 gas measurements
  (new tokens check overhead, aggregator batch savings, P256-first mode cost)
- [ ] **Gasless E2E Test** — Re-run full gasless flow per `docs/gasless-e2e-test-report.md`
  standard with M5 factory (new contract addresses, M5 features enabled)
- [ ] **Deployment Record** — Create `docs/m5-deployment-record.md` following the same
  standard as `docs/yetanother-deployment-record.md` with all M5 deployed addresses,
  tx hashes, gas costs, and verification links
