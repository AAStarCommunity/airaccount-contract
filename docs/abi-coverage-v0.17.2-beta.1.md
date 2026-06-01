# ABI Coverage Matrix — v0.17.2-beta.1

**Sepolia deployment**: 2026-06-01 (see `docs/DEPLOYMENT-v0.17.2-beta.1.md` §8 for addresses).
**Total external functions** across the 11 deployed contracts: **~80** (excluding view-only constant getters from public state vars).

## Legend

| Marker | Meaning |
|---|---|
| ✅ U | Covered by Foundry unit test (`test/*.t.sol`) — 671 passing |
| ✅ E | Covered by Sepolia E2E (`scripts/e2e-v0172/*.ts`) |
| ⬜ E | Planned but not yet executed on Sepolia |
| 🔒 admin | Owner-only / privileged — exercised by deploy script (`registerAlgorithm`, `bindFactory`, etc.) |
| ⏸ deferred | Not in beta.1 scope (e.g. parser opt-in path) |
| 📌 negative | Reverts intentionally — covered by negative-path test |

## 1. AAStarBLSAlgorithm (`0xB82127182A855B82eED05e47536FcE568b626457`)

| Function | Visibility | Mutability | U | E | Notes |
|---|---|---|---|---|---|
| `validate(bytes32, bytes)` | external | view | ✅ U | ⬜ E | Round 5 HIGH-2: infinity reject covered (`test_validate_*`) |
| `validateAggregateSignature(bytes32[], bytes, bytes)` | external | view | ✅ U | ⬜ E | Round 5 HIGH-2: infinity reject |
| `verifyAggregateSignature(bytes32[], bytes, bytes)` | external | nonpayable | ✅ U | ⬜ E | |
| `cacheAggregatedKey(bytes32[])` | external | pure | ✅ U 📌 | ⬜ E 📌 | Round 5 HIGH-1: always reverts `CacheDeprecated` |
| `computeSetHash(bytes32[])` | public | pure | ✅ U | ⬜ E | |
| `getGasEstimate(uint256)` | external | pure | ✅ U | ⬜ E | |
| `registerPublicKey(bytes32, bytes)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | Round 5 LOW-2: infinity G1 reject |
| `updatePublicKey(bytes32, bytes)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `revokePublicKey(bytes32)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `batchRegisterPublicKeys(bytes32[], bytes[])` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `getRegisteredNodeCount()` | external | view | ✅ U | ⬜ E | |
| `getRegisteredNodes(uint256, uint256)` | external | view | ✅ U | ⬜ E | |
| `aggregateKeys(bytes32[])` | external | view | ✅ U | ⬜ E | Round 5 HIGH-1: always on-demand |
| `g2Add(bytes, bytes)` | external | view | ✅ U | ⬜ E | |
| `transferOwnership(address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |

State: `registeredKeys`, `isRegistered`, `registeredNodes`, `owner` (public mappings + array + var).

## 2. AAStarValidator router (`0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `getAlgorithm(uint8)` | external | view | ✅ U | ✅ E | Smoke test: verify `getAlgorithm(0x01)` = BLS algo addr, `0x08` = SessionKey |
| `registerAlgorithm(uint8, address)` | external | nonpayable | ✅ U 🔒 | ✅ E 🔒 | Already called by deploy script for 0x01 + 0x08 |
| `finalizeSetup()` | external | nonpayable | ✅ U 🔒 | ⏸ deferred | Beta-1: NOT called (Codex INFO-1; called before GA) |
| `proposeAlgorithm(uint8, address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | Used post-finalizeSetup with timelock |
| `executeProposal(uint8)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `cancelProposal(uint8)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `transferOwnership(address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |

## 3. AAStarBLSAggregator (`0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `validateUserOpSignature(PackedUserOperation)` | external | pure | ✅ U | ⬜ E | Format check only |
| `aggregateSignatures(PackedUserOperation[])` | external | view | ✅ U | ⬜ E | Same-node-set enforce |
| `validateSignatures(PackedUserOperation[], bytes)` | external | view | ✅ U | ⬜ E | Round 5 HIGH-3 + round 6: per-UserOp infinity + ignore caller-supplied aggregate |

## 4. SessionKeyValidator (`0xc1e2534D9Cae27Fd9776e612229115604A9e07E9`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `validate(bytes32, bytes)` | external | view | ✅ U | ⬜ E | Dispatch by sig length 105/148 |
| `grantSession(account, sessionKey, Session, ownerSig)` | external | nonpayable | ✅ U | ⬜ E | Off-chain sig path (default for UserOp/paymaster flows) |
| `grantSessionDirect(account, sessionKey, Session)` | external | nonpayable | ✅ U 🔒 | ✅ E 🔒 | Round 3: **owner EOA only** — smoke test §6 |
| `grantP256Session(...)` | external | nonpayable | ✅ U | ⬜ E | P256 passkey variant |
| `grantP256SessionDirect(...)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | Round 3: owner-only |
| `revokeSession(account, sessionKey)` | external | nonpayable | ✅ U | ✅ E | Smoke test §6: kill-switch via account self-call |
| `revokeP256Session(account, keyX, keyY)` | external | nonpayable | ✅ U | ⬜ E | |
| `buildGrantHash(...)` | external | view | ✅ U | ⬜ E | |
| `buildP256GrantHash(...)` | external | view | ✅ U | ⬜ E | |
| `checkSessionScope(...)` | external | view | ✅ U | ⬜ E | Called by base._enforceGuard during execute |
| `recordCallForVelocity(...)` | external | nonpayable | ✅ U | ⬜ E | Velocity SSTORE (msg.sender == account gated) |
| `getSession(...)` / `getP256Session(...)` | external | view | ✅ U | ⬜ E | |
| `isSessionActive(...)` / `isP256SessionActive(...)` | external | view | ✅ U | ⬜ E | |
| `grantNonces(...)` / `grantNonces_p256(...)` | public | view (mapping) | ✅ U | ⬜ E | |
| `sessionStates(...)` / `sessionStates_p256(...)` | public | view (mapping) | ✅ U | ⬜ E | |

## 5. ForceExitModule (`0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `onInstall(bytes)` | external | nonpayable | ✅ U | ⬜ E | ERC-7579 lifecycle |
| `onUninstall(bytes)` | external | nonpayable | ✅ U | ⬜ E | |
| `isInitialized(address)` | external | view | ✅ U | ⬜ E | |
| `proposeForceExit(target, value, data)` | external | nonpayable | ✅ U | ⬜ E | KI-13: Tier-1 daily-limit constraint |
| `approveForceExit(account, guardianSig)` | external | nonpayable | ✅ U | ⬜ E | |
| `cancelForceExit(account)` | external | nonpayable | ✅ U | ⬜ E | |
| `executeForceExit(account)` | external | nonpayable | ✅ U | ⏸ deferred | Requires L1 bridge precompile + multi-day setup |
| `getPendingExit(account)` | external | view | ✅ U | ⬜ E | |

## 6. AirAccountDelegate (`0x8603AAF6C3f07fdae810B323c95a198D796EC52E`)

⏸ Most paths require an EIP-7702 authorization, which is hard to test from a contract test environment. Marked as **deferred E2E** for beta.1.

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `initialize(g1, sig1, g2, sig2, dailyLimit)` | external | nonpayable | ✅ U | ⏸ deferred | Requires EIP-7702 authorization |
| `execute(dest, value, data)` | external | nonpayable | ✅ U | ⏸ deferred | Round 5 MEDIUM-1: ERC20 selector check |
| `executeBatch(...)` | external | nonpayable | ✅ U | ⏸ deferred | |
| `validateUserOp(...)` | external | nonpayable | ✅ U | ⏸ deferred | |
| `initiateRescue(rescueTo)` / `approveRescue()` / `executeRescue()` / `cancelRescue()` | external | nonpayable | ✅ U | ⏸ deferred | Guardian rescue |
| `addDeposit()` / `getDeposit()` / `withdrawDepositTo(...)` | mixed | mixed | ✅ U | ⏸ deferred | EntryPoint deposit mgmt |
| `owner()` / `entryPoint()` / `getGuard()` / `getGuardians()` / `isInitialized()` / `getRescueState()` | external | view | ✅ U | ⬜ E | All read-only, can call without auth |

## 7. CalldataParserRegistry (`0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F`) ✅ Etherscan verified

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `registerParser(dest, parser)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `getParser(dest)` | external | view | ✅ U | ✅ E | Smoke test — should return 0 for any address (beta.1 no parser opt-in) |
| `transferOwnership(address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |

## 8. AAStarAirAccountFactoryV7 (`0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `createAccount(owner, salt, InitConfig)` | external | nonpayable | ✅ U | ✅ E | Smoke test §6 |
| `createAccountWithDefaults(owner, salt, g1, sig1, g2, sig2, dailyLimit)` | external | nonpayable | ✅ U | ✅ E | Smoke test §6 |
| `createAgentAccount(owner, salt, dailyLimit)` | external | nonpayable | ✅ U | ⬜ E | |
| `getAddress(owner, salt, InitConfig)` | external | view | ✅ U | ⬜ E | CREATE2 prediction |
| `getAddressWithDefaults(owner, salt, g1, g2, dailyLimit)` | external | view | ✅ U | ✅ E | Predict-then-create flow |
| `setAgentRegistry(registry)` | external | nonpayable | ✅ U 🔒 | ✅ E 🔒 | Called by deploy script |
| `agentRegistry()` | external | view | ✅ U | ✅ E | Smoke test verify |
| `implementation()` | external | view | ✅ U | ✅ E | |
| `entryPoint()` | external | view | ✅ U | ✅ E | |
| `getChainQualifiedAddress(account)` | external | view | ✅ U | ⬜ E | ERC-7828 |

## 9. AAStarAirAccountV7 (impl `0x05274e4Af481e5c23287571F71C52afCCC5Df127`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `initialize(entryPoint, owner, InitConfig, guard)` | external | nonpayable | ✅ U | ✅ E (via factory) | |
| `validateUserOp(UserOp, hash, missingFunds)` | external | nonpayable | ✅ U | ✅ E | Smoke test §6 (session-key UserOp) |
| `accountId()` | external | view (pure) | ✅ U | ✅ E | Returns `"airaccount.v7@0.17.2"` |
| `supportsModule(uint256)` | external | view (pure) | ✅ U | ⬜ E | ERC-7579 |
| `isValidSignature(bytes32, bytes)` | external | view | ✅ U | ⬜ E | ERC-1271 |
| `onERC721Received(...)` | external | view (pure) | ✅ U | ⬜ E | |
| `supportsInterface(bytes4)` | external | view (pure) | ✅ U | ⬜ E | ERC-165 |

Inherits from `AAStarAirAccountBase` — see §10.

## 10. AAStarAirAccountBase (inherited by V7, exercised on the V7 instance)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `owner()` | external | view | ✅ U | ✅ E | |
| `execute(dest, value, func)` | external | nonpayable | ✅ U | ✅ E | Smoke test §6 |
| `executeBatch(dest[], value[], func[])` | external | nonpayable | ✅ U | ⬜ E | |
| `executeFromExecutor(mode, calldata)` | external | nonpayable | ✅ U | ⬜ E | ERC-7579 executor entry |
| `setValidator(address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | Per-account wiring |
| `setAggregator(address)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `setP256Key(x, y)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | Passkey |
| `setParserRegistry(address)` | external | nonpayable | ✅ U 🔒 | ⏸ deferred | Beta.1: don't opt in (KI-14) |
| `guardApproveAlgorithm(uint8)` / `guardDecreaseDailyLimit(uint256)` / `guardAddTokenConfig(...)` / `guardDecreaseTokenDailyLimit(...)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `guardians(uint256)` / `guardianCount()` | external | view | ✅ U | ⬜ E | Round 5 INFO: ForceExit reads via this getter |
| `requiredTier(uint256)` | public | view | ✅ U | ⬜ E | |
| `getCurrentAlgId()` / `getCurrentSessionKey()` | external | view | ✅ U | ⬜ E | Transient state |
| `addGuardian(address)` / `removeGuardian(uint8, sigs)` | external | nonpayable | ✅ U | ⬜ E | |
| `initiateRecovery(newOwner, guardianSigs)` / `approveRecovery()` / `executeRecovery()` / `cancelRecovery()` | external | nonpayable | ✅ U | ⏸ deferred | Social recovery — multi-day timelock |
| `addDeposit()` / `getDeposit()` / `withdrawDepositTo(...)` | mixed | mixed | ✅ U | ⬜ E | |

## 11. AirAccountExtension (diamond-lite fallback `0x6e3E6d7e6DFb383CeaAe6A9ae478745FFc5cAac0`)

Reached via fallback delegatecall from AirAccountV7. State lives in the account's storage.

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `setAgentWallet(wallet)` | external | nonpayable | ✅ U | ⬜ E | ERC-8004 |
| `getAgentWallet()` | external | view | ✅ U | ⬜ E | |
| `setWeightConfig(WeightConfig)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `proposeWeightChange(WeightConfig)` | external | nonpayable | ✅ U 🔒 | ⬜ E 🔒 | |
| `approveWeightChange()` | external | nonpayable | ✅ U | ⬜ E | Guardian-signed |
| `executeWeightChange()` | external | nonpayable | ✅ U | ⬜ E | |
| `cancelWeightChange()` | external | nonpayable | ✅ U | ⬜ E | |
| ERC-8004 registry interaction (identity / reputation / validation) | external | nonpayable | ✅ U | ⬜ E | Codex round 5 INFO-4 |

## 12. AAStarGlobalGuard (per-account; deployed by `factory.createAccount*`)

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `checkTransaction(value, algId)` | external | nonpayable (onlyAccount) | ✅ U | ✅ E (implicit via execute) | |
| `remainingDailyAllowance()` | external | view | ✅ U | ⬜ E | |
| `todaySpent()` | external | view | ✅ U | ⬜ E | |
| `checkTokenTransaction(token, amount, algId)` | external | nonpayable (onlyAccount) | ✅ U | ⬜ E | Round 5 MEDIUM-2: resolved algId |
| `tokenTodaySpent(token)` | external | view | ✅ U | ⬜ E | |
| `addTokenConfig(token, config)` | external | nonpayable (onlyAccount) | ✅ U | ⬜ E | Monotonic add-only |
| `decreaseTokenDailyLimit(token, newLimit)` | external | nonpayable (onlyAccount) | ✅ U | ⬜ E | Decrease-only |
| `approveAlgorithm(uint8)` | external | nonpayable (onlyAccount) | ✅ U | ⬜ E | |
| Public getters: `account` / `dailyLimit` / `approvedAlgorithms` / `tokenConfigs` / `minDailyLimit` | public | view | ✅ U | ⬜ E | |

## 13. AgentRegistry (`0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB`) ✅ Etherscan verified

| Function | Vis. | Mut. | U | E | Notes |
|---|---|---|---|---|---|
| `bindFactory(factory)` | external | nonpayable | ✅ U 🔒 | ✅ E 🔒 | Round 3 A2: deployer-only, set-once |
| `markValid(account)` | external | nonpayable | ✅ U 🔒 | ✅ E 🔒 (via createAccount) | Factory-only |
| `registerAgent(agentWallet, sig)` | external | nonpayable | ✅ U | ⬜ E | H-2 fix: account must be factory-spawned |
| `deregisterAgent(agentWallet)` | external | nonpayable | ✅ U | ⬜ E | |
| `revokeAgent(agentWallet)` | external | nonpayable | ✅ U | ⬜ E | Alias for deregister |
| `isRegisteredAgent(agentWallet)` | external | view | ✅ U | ⬜ E | |
| `balanceOf(humanOwner)` | external | view | ✅ U | ⬜ E | |
| `ownerOf(tokenId)` | external | view (pure) | ✅ U 📌 | ⬜ E 📌 | Always reverts NotSupported |
| `getHumanOwner(agentWallet)` | external | view | ✅ U | ⬜ E | |
| `getAgents(humanOwner)` | external | view | ✅ U | ⬜ E | |
| `getAgentByIndex(owner, index)` | external | view | ✅ U | ⬜ E | |
| `getAgentCount(owner)` | external | view | ✅ U | ⬜ E | |
| `getAgentsPage(owner, start, count)` | external | view | ✅ U | ⬜ E | |
| Public state: `factory` / `isValidAccount` / `agentWalletOwner` / `ownerAgents` / `deployer` | public | view | ✅ U | ⬜ E | |

---

## Coverage summary

| Layer | Functions | Unit-tested | E2E (Sepolia) | E2E pending |
|---|---|---|---|---|
| BLS algorithm | 15 | 15/15 ✅ | 0/15 | 15 |
| Validator router | 7 | 7/7 ✅ | 2/7 (deploy-wired) | 5 |
| BLS aggregator | 3 | 3/3 ✅ | 0/3 | 3 |
| SessionKeyValidator | 16 | 16/16 ✅ | 2/16 (smoke) | 14 |
| ForceExitModule | 8 | 8/8 ✅ | 0/8 | 7 + 1 deferred |
| AirAccountDelegate | ~15 | ✅ all | view-only via Sepolia | ⏸ deferred (needs EIP-7702 auth) |
| ParserRegistry | 3 | 3/3 ✅ | 1/3 (smoke read) | 2 |
| Factory V7 | 10 | 10/10 ✅ | 5/10 (smoke) | 5 |
| AirAccountV7 + Base | ~30 | all ✅ | ~6 (smoke) | ~24 |
| AirAccountExtension | ~10 | all ✅ | 0/10 | 10 |
| GlobalGuard | 9 | 9/9 ✅ | implicit via execute | 9 |
| AgentRegistry | 13 | 13/13 ✅ | 2/13 (smoke) | 11 |

**Unit-test coverage: 100%** (671 passing) ✅
**E2E coverage (Sepolia): ~17% (smoke test only)** as of 2026-06-01
**Target**: 100% E2E coverage of non-deferred functions before promoting `-beta.1` → `v0.17.2` final.

## Phases for filling E2E

1. **Phase 1 — Smoke test** (deploy doc §6, 8 items) — _in progress_, `scripts/e2e-v0172/01-smoke.ts`
2. **Phase 2 — Round 5/6 security fix verification on Sepolia** (BLS infinity reject, aggregator binding, 7702 ERC20 path, weighted token tier) — `scripts/e2e-v0172/02-security-fixes.ts`
3. **Phase 3 — Read-only coverage** (every external view function called + return value sanity-checked) — `scripts/e2e-v0172/03-views.ts`
4. **Phase 4 — Privileged write paths** (registerAlgorithm timelock, addTokenConfig monotonic, setWeightConfig, etc.) — `scripts/e2e-v0172/04-admin.ts`
5. **Phase 5 — Per-account lifecycle** (factory create → setValidator/Aggregator → grantSession → execute → revoke → addGuardian → recovery dry-run) — `scripts/e2e-v0172/05-account-lifecycle.ts`
6. **Phase 6 — Negative paths** (`NotDeployer`, `NotAccountOwner`, `CallerNotAirAccount`, `BLSPointAtInfinity`, `CacheDeprecated`, `InsufficientTokenTier`) — `scripts/e2e-v0172/06-negative.ts`

Results recorded in `docs/e2e-results-v0.17.2-beta.1.md` (one row per test: tx hash, gas, pass/fail, finding).
