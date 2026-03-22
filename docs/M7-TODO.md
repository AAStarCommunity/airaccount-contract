# M7 Developer TODO — AirAccount v0.16.0

**Generated**: 2026-03-21 | **Scope**: M6-complete → M7 release
**Two goals**: (1) ERC-7579 systematic upgrade preserving security model, (2) WalletBeat Stage 1/2 contract items + frontend items documented for companion SDK

> Legend: 🔴 High priority · 🟡 Medium · 🟢 Low | ⬛ Contract layer · 🟦 Frontend/SDK layer

---

## Status Summary (2026-03-21, updated 2026-03-21)

| Status | Count | Items |
|--------|-------|-------|
| ✅ Done | 19 | C1-C18 (all contract layer items) |
| 🔲 Planned | 7 | F1-F7 (frontend SDK — separate repo, out of scope) |

---

## CONTRACT LAYER — ERC-7579 Module Compliance (M7.2)

### C1 — `installModule()` implementation
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: M | **Depends on**: —

```solidity
function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;
```

- Add to `AAStarAirAccountV7` (implements `IERC7579Account`)
- Permission gate: configurable `_installModuleThreshold` (default weight 70 = owner40 + 1guardian30)
  - Stored in `InitConfig.installModuleThreshold` (uint8: 40/70/100)
  - If threshold not met → 48h timelock before module activates
- Module type dispatch: Validator(1) / Executor(2) / Fallback(3) / Hook(4)
- Storage: `mapping(address module => bool) _installedModules` + `mapping(address module => uint256 moduleType)`
- Emit `ModuleInstalled(uint256 moduleTypeId, address module)`
- Guard: `module != address(0)`, `module.code.length > 0`, no re-install of existing

**Files**: `src/core/AAStarAirAccountV7.sol`, `src/core/AAStarAirAccountBase.sol` (add field to InitConfig)

---

### C2 — `uninstallModule()` implementation
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: M | **Depends on**: C1

```solidity
function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;
```

- Permission gate: **guardian 2-of-3 vote** (same weight as `cancelRecovery`)
  - Exception: `installModuleThreshold == 40` (owner-only install) → owner alone can uninstall
- Special case: uninstalling `TierGuardHook` requires guardian 2-of-3 regardless of threshold config
- Emit `ModuleUninstalled(uint256 moduleTypeId, address module)`
- On uninstall of CompositeValidator: emit `WARNING_CompositeValidatorRemoved` event + NatSpec warn

**Files**: `src/core/AAStarAirAccountV7.sol`

---

### C3 — `executeFromExecutor()` implementation
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: S | **Depends on**: C1

```solidity
function executeFromExecutor(ModeCode mode, bytes calldata executionCalldata) external returns (bytes[] memory);
```

- Caller must be installed Executor module: `require(_installedModules[msg.sender] && _moduleType[msg.sender] == 2)`
- Enforce daily limit via `_checkExecutorTransaction()` (new helper — checks guard daily limit only, no tier re-check)
- ModeCode decode: `callType` byte → single call / batch / delegatecall
- No re-validation of algId (executor modules are pre-authorized at install time via guardian gate)
- Return bytes array with call results

**Files**: `src/core/AAStarAirAccountV7.sol`

---

### C4 — TierGuardHook (ERC-7579 Hook module)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: M | **Depends on**: C1, C5

Create `src/core/TierGuardHook.sol`:

```solidity
// IHook implementation — replaces direct _enforceGuard call in execute()
contract TierGuardHook is IHook {
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external returns (bytes memory hookData);
    function postCheck(bytes calldata hookData) external;
}
```

- `preCheck`: read `algId` from TSTORE (slot = `keccak256(abi.encodePacked("AIRACCOUNT_ALG_ID", msg.sender))`), call `_enforceGuard(algId, target, value, calldata)` — reverts if tier/daily violated
- `postCheck`: no-op (all logic is pre-check)
- Uninstall restricted: requires guardian 2-of-3 (enforced in `uninstallModule`)
- Default install: pre-installed by factory at `initialize()` time

**Files**: `src/core/TierGuardHook.sol` (new), factory install in `AAStarAirAccountFactoryV7.sol`

---

### C5 — algId TSTORE bridge (Validator → Hook)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: S | **Depends on**: —

- In `AAStarValidator._validateSignature()`: after algId is determined, add:
  ```solidity
  assembly { tstore(keccak256(abi.encodePacked("AIRACCOUNT_ALG_ID", account)), algId) }
  ```
- In `TierGuardHook.preCheck()`: read:
  ```solidity
  assembly { algId := tload(keccak256(abi.encodePacked("AIRACCOUNT_ALG_ID", address(this)))) }
  ```
- Slot namespaced by account address → no cross-account contamination
- TSTORE cost: ~100 gas write, ~100 gas read (EIP-1153, Cancun+)
- Auto-clears after transaction — no manual cleanup needed

**Files**: `src/validators/AAStarValidator.sol`, `src/core/TierGuardHook.sol`

---

### C6 — AirAccountCompositeValidator (Weighted + Cumulative merged)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: M | **Depends on**: C5

Create `src/validators/AirAccountCompositeValidator.sol`:

- Merges `ALG_WEIGHTED (0x07)` + `ALG_CUMULATIVE_T2 (0x04)` + `ALG_CUMULATIVE_T3 (0x05)` into single IValidator module
- Routes internally by `algId` byte in signature prefix
- Implements `IValidator.validateUserOp()` + `IValidator.isValidSignatureWithSender()`
- Re-use existing `_validateCumulativeTier2/Tier3/Weighted` logic from `AAStarAirAccountBase` — extract to library
- Default install: pre-installed by factory at `initialize()` time

**Files**: `src/validators/AirAccountCompositeValidator.sol` (new)

---

### C7 — nonce key → validator module routing
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: S | **Depends on**: C1

- ERC-4337 nonce high 192 bits = `validatorId` (which IValidator module to call)
- In `validateUserOp()`: decode nonce → look up `_installedModules[validatorId]` → delegate to that module
- Default `validatorId=0` → AAStarValidator (ECDSA, backward compatible)
- New validatorId assignments:
  - `0x0001` → AirAccountCompositeValidator
  - `0x0002` → AgentSessionKey (M7.14)

**Files**: `src/core/AAStarAirAccountV7.sol`

---

### C8 — Factory pre-install default modules
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: S | **Depends on**: C1, C4, C6

In `AAStarAirAccountFactoryV7.createAccount()` / `createAccountWithDefaults()`, after `initialize()`:

```solidity
// Pre-install default modules (zero user cost — done at account creation)
account.installModule(1, address(compositeValidator), ""); // Validator
account.installModule(4, address(tierGuardHook), "");      // Hook
```

- Factory stores `compositeValidatorImpl` and `tierGuardHookImpl` as immutable addresses
- Add to constructor params: `address _compositeValidator, address _tierGuardHook`
- All factory-deployed accounts get default modules at creation → no user action required

**Files**: `src/core/AAStarAirAccountFactoryV7.sol`

---

## CONTRACT LAYER — WalletBeat Stage 1/2 Items

### C9 — ERC-7828 chainId helper (M7.4) — Stage 2 / S2-8
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: S | **Depends on**: —

Add to `AAStarAirAccountFactoryV7`:

```solidity
/// @notice ERC-7828: chain-qualified address = keccak256(address ++ chainId)
function getChainQualifiedAddress(address account) external view returns (bytes32) {
    return keccak256(abi.encodePacked(account, block.chainid));
}
```

Add ERC-7831 resolver registration method — one-time setup for canonical cross-chain address lookup.

**Files**: `src/core/AAStarAirAccountFactoryV7.sol`

---

### C10 — L2 deployment + force-exit (M7.5) — Stage 2 / S2-4
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: M | **Depends on**: M6 factory deployed

- Deploy factory at deterministic address using `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 deployer)
- Target chains: Base, Arbitrum One, OP Mainnet (already tested), zkSync Era
- Force-exit module per chain:
  - OP Stack: `L2ToL1MessagePasser.initiateWithdrawal()` with guardian 2-of-3 gate
  - Arbitrum: `ArbSys.sendTxToL1()` with guardian 2-of-3 gate
- Guardian gate: prevent single-key theft via L1 exit
- Add `scripts/deploy-multichain.ts` for batch deployment

**Files**: `scripts/deploy-multichain.ts` (new), `src/core/ForceExitModule.sol` (new)

---

### C11 — Railgun privacy pool integration (M7.11) — Stage 1 / S1-4
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: M | **Depends on**: CalldataParserRegistry (done)

Create `src/parsers/RailgunParser.sol`:

```solidity
// ICalldataParser — parses Railgun deposit calldata
contract RailgunParser is ICalldataParser {
    // Railgun V3 deposit selector: transact() + extractTokensFromNotes()
    function parse(bytes calldata data) external pure
        returns (address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);
}
```

- Register: `registry.registerParser(RAILGUN_PROXY_MAINNET, address(railgunParser))`
- Guard enforcement: large Railgun deposits require T3 (guardian co-sign) — automatic via guard
- Test: `test/RailgunParser.t.sol` with mock deposit calldata
- Withdraw direction: unshield returns tokens to AirAccount — no parser needed

**Files**: `src/parsers/RailgunParser.sol` (new), `test/RailgunParser.t.sol` (new)

---

### C12 — Professional audit prep (M7.6) — Stage 1 / S1-1 (BLOCKING)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🔴 | **Effort**: L | **Depends on**: M7.2 complete

- **Scope doc**: `docs/audit-scope.md` — list all in-scope contracts, interfaces, deployment scripts
- **Known issues doc**: `docs/known-issues.md` — explicitly document accepted risks (EIP-7702 private key permanence, guardian self-dealing after trust established)
- **Test coverage**: target 95%+ line coverage on in-scope contracts (`forge coverage`)
- **NatSpec audit**: every public function with `@param`, `@return`, `@dev` explaining security invariants
- **Apply to CodeHawks** (codehawks.com) public goods track — contact Cyfrin for reduced-cost competitive audit
- **Target**: $15–20k prize pool

---

### C13 — Bug bounty setup (M7.7) — Stage 2 / S2-1
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟢 | **Effort**: S | **Depends on**: C12 audit complete

- Add `SECURITY.md` with vulnerability disclosure policy
- Add `docs/bug-bounty.md` with severity tiers and reward schedule
- Register on Immunefi after audit report published
- Initial funding: ~$50k in smart contract (Immunefi vault)

---

### C14 — FUNDING.md (Stage 2 / S2-6)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟢 | **Effort**: XS | **Depends on**: —

Create `FUNDING.md` at repo root:
- Funding sources, grants received/applied for, academic affiliation (CMU PhD)
- GitHub Sponsors setup (optional)
- Transparency: no VCs, no commercial entity, academic public goods

---

### C15 — ERC-5564 Stealth Address (M7.13)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟢 | **Effort**: S | **Depends on**: —

Add to `AirAccountDelegate.sol`:

```solidity
/// @notice ERC-5564: Publish stealth address announcement
function announceForStealth(
    address stealthAddress,
    bytes calldata ephemeralPubKey,
    bytes calldata metadata
) external {
    IERC5564Announcer(ERC5564_ANNOUNCER).announce(1, stealthAddress, ephemeralPubKey, metadata);
}
```

**Files**: `src/core/AirAccountDelegate.sol`

---

## CONTRACT LAYER — Agentic Economy

### C16 — Agent Session Key Module (M7.14)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟡 | **Effort**: M | **Depends on**: C1 (installModule)

Extend `SessionKeyValidator` or create `AgentSessionKeyValidator.sol`:

```solidity
struct AgentSessionConfig {
    address sessionKey;
    uint48  expiry;
    uint16  velocityLimit;     // max calls per window
    uint32  velocityWindow;    // window in seconds
    address[] callTargets;     // allowlisted contracts (empty = all)
    bytes4[]  selectorAllowlist; // per M7.18 prompt injection defense
    address spendToken;        // ERC-20 (address(0) = ETH)
    uint256 spendCap;          // max cumulative spend this session
}

function grantAgentSession(address account, AgentSessionConfig calldata cfg) external;
```

- Maps to ERC-7715 `wallet_grantPermissions` + ERC-7710 Delegation
- Storage: `mapping(address key => AgentSessionConfig) _agentSessions`
- Velocity tracking: `mapping(address key => uint256) _callCount`, reset each window
- Install as Validator module via `installModule(1, agentSessionKeyValidator, "")`

**Files**: `src/validators/AgentSessionKeyValidator.sol` (new), `test/AgentSessionKey.t.sol` (new)

---

### C17 — ERC-8004 agent identity binding (M7.16)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟢 | **Effort**: S | **Depends on**: —

Add to `AAStarAirAccountBase`:

```solidity
// ERC-8004 Identity Registry (Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e)
function setAgentWallet(uint256 agentId, address agentWallet, address erc8004Registry)
    external onlyOwner;

event AgentWalletSet(uint256 indexed agentId, address indexed agentWallet);
```

**Files**: `src/core/AAStarAirAccountBase.sol`

---

### C18 — Hierarchical delegation / sub-agents (M7.17)
**STATUS: ✅ DONE (2026-03-21)**
**Priority**: 🟢 | **Effort**: MH | **Depends on**: C16

Extend `AgentSessionKeyValidator`:

```solidity
// Session key holder can sub-delegate with equal or narrower scope
function delegateSession(address subKey, AgentSessionConfig calldata subCfg) external;
```

- Scope check: `subCfg.spendCap <= parentSession.spendCap`, `subCfg.expiry <= parentSession.expiry`
- No scope escalation allowed (verified on-chain)
- Chain of delegation verifiable via events

---

## FRONTEND / SDK LAYER (separate repos)

> These items are NOT part of this contract repo. They belong in the AirAccount frontend / companion SDK repo. Listed here for cross-team planning.

### F1 — Hardware wallet SDK integration (S1-2)
**Priority**: 🔴 | **Effort**: M | **Layer**: 🟦 Frontend SDK

```bash
pnpm add @ledgerhq/device-management-kit @ledgerhq/hw-app-eth @ledgerhq/hw-transport-webhid
pnpm add @trezor/connect-web gridplus-sdk @noble/curves webauthn-p256
```

- Ledger: `hw-app-eth.signPersonalMessage()` → format as AirAccount UserOp signature
- YubiKey/Passkey: `navigator.credentials.get()` → P-256 (r,s) → `algId=0x03` signature
- Trezor: ECDSA only for now (`algId=0x02`)
- See `docs/M7-plan.md` § "Frontend Integration Guide: Hardware Wallet SDK" for full code

**Deliverable**: `airaccount-sdk/src/signers/hardware.ts`

---

### F2 — Helios light client integration (S1-3)
**Priority**: 🟡 | **Effort**: M | **Layer**: 🟦 Frontend SDK

```bash
pnpm add @a16z/helios
```

```typescript
import { createHeliosClient } from '@a16z/helios';
import { createPublicClient, custom } from 'viem';

const helios = await createHeliosClient({ network: 'mainnet', consensus: 'beacon' });
const client = createPublicClient({ transport: custom(helios) });
```

- Wrap Helios as viem `custom()` transport
- User enables "verify with light client" toggle → queries go through Helios instead of RPC
- See `docs/M7-plan.md` § "Frontend Integration Guide: Helios Light Client"

**Deliverable**: `airaccount-sdk/src/transports/helios.ts`

---

### F3 — ENS address resolution (S1-8)
**Priority**: 🟡 | **Effort**: S | **Layer**: 🟦 Frontend SDK

```typescript
import { getEnsAddress, normalize } from 'viem/ens';
const address = await client.getEnsAddress({ name: normalize('vitalik.eth') });
```

- Resolve ENS names before any `to:` field in the UI
- Reverse lookup: show `vitalik.eth` instead of `0xd8dA…` where available

**Deliverable**: `airaccount-sdk/src/utils/ens.ts`

---

### F4 — EIP-1193 provider wrapper + EIP-6963 (S1-9)
**Priority**: 🟡 | **Effort**: M | **Layer**: 🟦 Frontend SDK

```bash
pnpm add @mipd/store
```

```typescript
// EIP-6963: Multi-wallet discovery
import { MIPD } from '@mipd/store';
const providerStore = MIPD.createStore();
providerStore.subscribe(providers => renderWalletButtons(providers));
window.dispatchEvent(new Event('eip6963:requestProvider'));
```

- Expose AirAccount as EIP-1193 provider: `window.ethereum` compatible shim
- Announce via EIP-6963 so DApps auto-discover it alongside MetaMask/Coinbase
- Handle `eth_sendTransaction` by converting to `eth_sendUserOperation`

**Deliverable**: `airaccount-sdk/src/providers/eip1193.ts`, `eip6963.ts`

---

### F5 — x402 payment client (M7.15)
**Priority**: 🟡 | **Effort**: S | **Layer**: 🟦 Frontend SDK

```bash
pnpm add @x402/core @x402/express
```

```typescript
import { createX402Client } from '@x402/core';
const client = createX402Client({
  signer: sessionKeyAccount,   // viem LocalAccount from AgentSessionKey
  token: USDC_SEPOLIA,
  maxAmount: parseUnits('1', 6),
});
const response = await client.fetch('https://api.example.com/v1/chat');
```

- No new contract needed for basic x402 (agent session key signs EIP-3009 authorization off-chain)
- Optional: `X402Paymaster.sol` (see M7-plan.md) for gas sponsorship via x402 proofs

**Deliverable**: `airaccount-sdk/src/payments/x402.ts`

---

### F6 — Daily limit UI (S2-7)
**Priority**: 🟢 | **Effort**: S | **Layer**: 🟦 Frontend SDK

```typescript
const todaySpent = await guard.read.todaySpent();
const dailyLimit = await guard.read.dailyLimit();
const progress = (todaySpent * 100n) / dailyLimit;
```

- Show `todaySpent / dailyLimit` progress bar
- Show gas sponsorship status: `entryPoint.getDeposit(account)` balance
- Show tier level for current tx amount (T1/T2/T3)

---

### F7 — Per-DApp OAPD address UI (S2-2)
**Priority**: 🟢 | **Effort**: S | **Layer**: 🟦 Frontend SDK

- Derive OAPD address: `salt = keccak256(owner ++ dappId)` → `factory.getAddress(owner, salt, config)`
- Show which addresses are linked to the same owner (correlation prevention)
- Let user switch between "main" and per-DApp addresses in UI

---

## CLEANUP / QUICK WINS

### Q1 — Fix CHANGELOG.md merge conflict
**Priority**: 🔴 | **Effort**: XS | **Depends on**: —
- Remove `<<<<<<< HEAD` / `=======` / `>>>>>>>` markers at line 11

### Q2 — `AirAccountDelegate` ArrayLengthMismatch custom error (M7.10, already identified)
**Priority**: 🟢 | **Effort**: XS | **Depends on**: —
- `src/core/AirAccountDelegate.sol`: replace `require(...)` with `if (...) revert ArrayLengthMismatch()`

### Q3 — Reserve algId 0x10 for post-quantum (M7.8, already identified)
**Priority**: 🟢 | **Effort**: XS | **Depends on**: —
- Add comment in `AAStarValidator.sol`: `// algId 0x10: Reserved for ML-DSA/Dilithium (EVM precompile TBD ~2027-2029)`

### Q4 — Update README M7 row + add doc links
**Priority**: 🔴 | **Effort**: XS | **Depends on**: —
- Update README.md M7 milestone row
- Add links: `architecture-7579-evolution.md`, `M7-TODO.md`, `walletbeat-assessment.md`

---

## EXECUTION ORDER (suggested parallel tracks)

```
Track A (ERC-7579 core) ─── C5 → C4 → C6 → C1 → C2 → C3 → C7 → C8
Track B (WalletBeat)    ─── Q1, Q2, Q3, C14, C9 → C10 → C11 → C12 → C13
Track C (Agentic)       ─── C16 → C17 → C18 (after Track A C1 done)
Track D (Frontend SDK)  ─── F3, F1, F4 → F2 → F5 → F6, F7
```

**Critical path**: C5 (TSTORE) → C4 (TierGuardHook) → C1 (installModule) → C8 (factory pre-install) → C12 (audit prep)

**Audit gate**: C12 cannot start until C1/C2/C3/C4/C5/C6/C8 complete. All other items can proceed in parallel.

---

## Summary Table

| ID | Item | Priority | Effort | Layer | Stage |
|----|------|----------|--------|-------|-------|
| C1 | installModule | 🔴 | M | Contract | M7.2 |
| C2 | uninstallModule | 🔴 | M | Contract | M7.2 |
| C3 | executeFromExecutor | 🔴 | S | Contract | M7.2 |
| C4 | TierGuardHook | 🔴 | M | Contract | M7.2 |
| C5 | algId TSTORE bridge | 🔴 | S | Contract | M7.2 |
| C6 | CompositeValidator | 🟡 | M | Contract | M7.2 |
| C7 | nonce key routing | 🟡 | S | Contract | M7.2 |
| C8 | Factory pre-install | 🔴 | S | Contract | M7.2 |
| C9 | ERC-7828 chainId | 🟡 | S | Contract | M7.4 / S2-8 |
| C10 | L2 + force-exit | 🟡 | M | Contract | M7.5 / S2-4 |
| C11 | Railgun parser | 🟡 | M | Contract | M7.11 / S1-4 |
| C12 | Audit prep | 🔴 | L | Process | M7.6 / S1-1 |
| C13 | Bug bounty | 🟢 | S | Process | M7.7 / S2-1 |
| C14 | FUNDING.md | 🟢 | XS | Docs | S2-6 |
| C15 | ERC-5564 stealth | 🟢 | S | Contract | M7.13 |
| C16 | Agent session key | 🟡 | M | Contract | M7.14 |
| C17 | ERC-8004 binding | 🟢 | S | Contract | M7.16 |
| C18 | Hierarchical delegation | 🟢 | MH | Contract | M7.17 |
| F1 | HW wallet SDK | 🔴 | M | Frontend | S1-2 |
| F2 | Helios light client | 🟡 | M | Frontend | S1-3 |
| F3 | ENS resolution | 🟡 | S | Frontend | S1-8 |
| F4 | EIP-1193 / EIP-6963 | 🟡 | M | Frontend | S1-9 |
| F5 | x402 payment client | 🟡 | S | Frontend | M7.15 |
| F6 | Daily limit UI | 🟢 | S | Frontend | S2-7 |
| F7 | OAPD address UI | 🟢 | S | Frontend | S2-2 |
| Q1 | Fix CHANGELOG conflict | 🔴 | XS | Cleanup | — |
| Q2 | ArrayLengthMismatch | 🟢 | XS | Contract | M7.10 |
| Q3 | Reserve algId 0x10 | 🟢 | XS | Contract | M7.8 |
| Q4 | Update README | 🔴 | XS | Docs | — |
