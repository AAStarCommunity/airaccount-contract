# AirAccount M7 E2E Test + Security Review Report
**Date**: 2026-04-07  
**Scope**: M7 r8 deployed contracts (Sepolia) + full E2E test suite (A-H groups)  
**Account**: [0x37b5c83859c9D8BA472678649D15DeDc5A8469C5](https://sepolia.etherscan.io/address/0x37b5c83859c9D8BA472678649D15DeDc5A8469C5)

---

## Part 1 — E2E Test Findings (Test Design Issues)

### T1. algId=0x09 was not a valid routing path (Test design error, contract correct)
The original E2E test used `[0x09][addr(20)][sig(65)]` = 86 bytes, expecting the account to route to AgentSessionKeyValidator. r8 has no 0x09 constant — the signature fell into "all other → external validator" which fails silently. **Fix**: use ERC-7579 nonce-key routing (nonce key = agentValidatorAddr, plain 65-byte ECDSA). All B2/B3/H1 now pass.

### T2. B3 velocity window too short
60s window caused false pass after RPC retry delays caused the window to expire. **Fix**: 600s window in B1 grant.

### T3. A2 TierGuardHook UnknownAlgId not E2E testable
Account's `_validateSignature` rejects unknown algId before reaching the hook. C16/C17 is unit-test only by design.

---

## Part 2 — Security Review Findings (Contract Changes Required)

### 🔴 HIGH-1: Session scope bypass via algId=signature[0] in nonce-key routing

**File**: `src/core/AAStarAirAccountV7.sol` line ~150  
**Severity**: HIGH  
**Status**: TO FIX (r9)

**Issue**: When ERC-7579 nonce-key routing is used, the account stores `uint8(userOp.signature[0])` as algId after successful validation. For AgentSessionKeyValidator (raw 65-byte ECDSA, no prefix), `sig[0]` is the first byte of `r` — attacker-controllable. Consequences:
1. `_enforceGuard` does NOT recognize it as `ALG_SESSION_KEY` → session `callTargets`/`selectorAllowlist` scope enforcement is **skipped**
2. TierGuardHook `_algTier()` gets unknown algId → **reverts in execute()** → DoS

**Impact**: A session key holder with restricted callTargets/selectorAllowlist can bypass those restrictions. Sessions with empty allowlists (current E2E tests) are unaffected.

**Fix**: Add `0x08` algId prefix requirement to `AgentSessionKeyValidator.validateUserOp`, recover from `sig[1:66]` instead of `sig[0:65]`.

---

### 🟡 MEDIUM-1: Module marked installed BEFORE onInstall — stuck state on callback failure

**File**: `src/core/AAStarAirAccountV7.sol` `installModule()`  
**Severity**: MEDIUM  
**Status**: TO FIX (r9)

**Issue**: `_installedModules[typeId][module] = true` and `_activeHook = module` are set before `module.call(onInstall)`. If onInstall fails, the module is permanently marked installed but uninitialized. `validateUserOp` returns 1 forever (stuck state).

Current code just emits `ModuleInstallCallbackFailed` event — **silently leaves broken state**.

**Fix**: Convert to hard revert: `if (!_ok) revert ModuleInstallCallbackFailed(moduleTypeId, module)`. Since revert rolls back all state, the module will not be marked installed.

---

### 🟡 MEDIUM-2: `_initialized` shared across typeId=1 and typeId=2 installs

**File**: `src/validators/AgentSessionKeyValidator.sol`  
**Severity**: MEDIUM  
**Status**: TO FIX (r9)

**Issue**: `mapping(address => bool) _initialized` is set in `onInstall` and cleared in `onUninstall`. If the same module is installed as both validator (typeId=1) and executor (typeId=2), uninstalling one calls `onUninstall → _initialized[account] = false`. The remaining role then has `validateUserOp` return 1 (stuck).

**Fix** (account-side): In `uninstallModule`, only call `onUninstall` if the module has no remaining active installations (check all three typeIds). Similarly, only call `onInstall` on first installation.

---

### 🟡 MEDIUM-3: TierGuardHook UnknownAlgId revert amplifies HIGH-1 into execution DoS

**File**: `src/core/TierGuardHook.sol`  
**Severity**: MEDIUM (cascades from HIGH-1)  
**Status**: Fixed by HIGH-1 fix (correct algId stored → no unknown algId in hook)

---

### 🟢 LOW-1: All-zero guardian set allows locking module installs

**File**: `src/core/AAStarAirAccountFactoryV7.sol`  
**Severity**: LOW  
**Status**: Documented, optional fix

Factory allows creating accounts with all-zero guardians. Default `_installModuleThreshold=70` requires 1 guardian sig → zero-guardian accounts cannot installModule.

---

### ℹ️ INFO-1: `_callLifecycle` (onUninstall) failures are silent

**File**: `src/core/AAStarAirAccountV7.sol`  
**Severity**: INFO  
**Status**: Fixed by MEDIUM-1 fix (add `ModuleUninstallCallbackFailed` event symmetrically)

---

## Part 3 — E2E Test Results (All 16 Pass)

| Test | Feature | Status | Tx |
|------|---------|--------|----|
| A1 | installModule(1, CompositeValidator) | ✅ | on-chain |
| A2 | installModule(3, TierGuardHook) LOW-1 guard | ✅ | ModuleAlreadyInstalled |
| A3 | executeFromExecutor guard | ✅ | — |
| A4 | uninstallModule no guardian sigs → revert | ✅ | — |
| B1 | grantAgentSession | ✅ | 0x23b1c8b3... |
| B2 | Agent session key UserOp (nonce-key routing) | ✅ | 0x0c2126... |
| B3 | VelocityLimitExceeded on 3rd call/600s | ✅ | simulateContract |
| B4 | delegateSession sub-agent chain | ✅ | — |
| C1 | getChainQualifiedAddress | ✅ | read-only |
| C2 | Cross-chain isolation | ✅ | read-only |
| D1 | announceForStealth ERC5564 event | ✅ | 0xf47ca449... |
| E1 | uninstallModule with 2 guardian sigs | ✅ | 0x0572c97a / 0x091fad41 |
| G1 | delegateSession expiry escalation → ScopeEscalationDenied | ✅ | simulateContract |
| G2 | delegateSession spendCap escalation → ScopeEscalationDenied | ✅ | simulateContract |
| G3 | delegateSession velocityLimit escalation → ScopeEscalationDenied | ✅ | simulateContract |
| H1 | Velocity window reset (5s window) | ✅ | 0xe26635 / 0xf3bc43 |

---

## Part 4 — Required Contract Changes for r9

1. **AgentSessionKeyValidator**: add `0x08` algId prefix to `validateUserOp` (HIGH-1)
2. **AAStarAirAccountV7.installModule**: revert on `onInstall` failure (MEDIUM-1)  
3. **AAStarAirAccountV7.uninstallModule**: skip `onUninstall` if module still installed under other typeId (MEDIUM-2)
4. **AAStarAirAccountV7.installModule**: skip `onInstall` if module already installed under other typeId (MEDIUM-2)
5. Add `error ModuleInstallCallbackFailed` + `event ModuleUninstallCallbackFailed` for observability
