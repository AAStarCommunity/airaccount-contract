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

### Tasks

- [ ] F59: Document chain-specific deployment configs (precompile availability per chain)
- [ ] F60: Integrate fallback P256 verifier (Daimo's P256Verifier.sol) for chains without EIP-7212
- [ ] F61: Consider fallback BLS library for chains without EIP-2537 (or document as requirement)
- [ ] F62: Multi-chain deployment script with per-chain precompile detection

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

## M5.8 — T1 Security Enhancement (P256-first mode)

### Problem

Tier 1 currently accepts either ECDSA (0x02) OR P256 passkey (0x03) independently.
ECDSA private keys can be stolen (phishing, malware). P256 keys are device-bound
(secure enclave/TPM) and cannot be remotely extracted — no key extraction risk.

### Proposal

Add an optional per-account security mode: if `p256RequiredForTier1 = true`, all
transactions (including Tier 1) must include a P256 signature in addition to ECDSA.
This makes ALL transactions device-bound by default.

```solidity
// New field in account:
bool public p256RequiredForTier1; // if true, all tiers must include P256

// In _enforceGuard:
if (p256RequiredForTier1 && _algTier(algId) < 2 && algId != ALG_P256) {
    // algId must be P256 or cumulative (which includes P256)
    revert P256RequiredForTier1();
}
```

**Trade-offs**:
- PRO: Eliminates ECDSA key theft attack on Tier 1 (~all normal transactions)
- PRO: P256 gas cost is negligible (EIP-7212 precompile, ~40k gas total)
- CON: If P256 key is lost, Tier 1 is bricked until social recovery (but social recovery works)
- CON: Requires P256 key to be set on account
- CON: Breaks automation (bots can't easily provide P256 sigs without device)

**Recommendation**: opt-in flag, off by default. User enables via `enableP256Tier1Requirement()`.
Backend/scripts that use ECDSA directly won't be affected unless opted in.

### Tasks

- [ ] F74: Add `p256RequiredForTier1` flag and `enableP256Tier1Requirement()` to account
- [ ] F75: Update `_enforceGuard` to check flag before allowing Tier 1 with ECDSA alone
- [ ] F76: Unit tests for P256-required mode (enabled/disabled, with/without P256 key)

---

## Priority Order (updated 2026-03-13)

1. **M5.1** (F47-F53) — ERC20 token guard ← highest business value
2. **M5.2** (F54-F55) — Governance hardening ← security critical (C-1/C-2/H-3 from security review)
3. **M5.3** (F56-F58) — Guardian validation ← UX improvement
4. **M5.4** (F59-F62) — Chain compatibility ← deployment expansion
5. **M5.6** (F67-F70) — Gas optimization (BLS aggregator integration)
6. **M5.7** (F71-F73) — Force guard requirement ← production safety
7. **M5.8** (F74-F76) — P256-first mode ← advanced security opt-in
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

## Post-M5 Checklist (run after all M5 tasks complete)

- [ ] **Gas Analysis V2** — Update `docs/gas-analysis.md` with M5 gas measurements
  (new tokens check overhead, aggregator batch savings, P256-first mode cost)
- [ ] **Gasless E2E Test** — Re-run full gasless flow per `docs/gasless-e2e-test-report.md`
  standard with M5 factory (new contract addresses, M5 features enabled)
- [ ] **Deployment Record** — Create `docs/m5-deployment-record.md` following the same
  standard as `docs/yetanother-deployment-record.md` with all M5 deployed addresses,
  tx hashes, gas costs, and verification links
