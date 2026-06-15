# E2E Test Plan — AirAccount v0.18.0-beta.2 (Sepolia, real on-chain)

> The release E2E gate. Three parts, all required:
> **Part 1** data/accounts/tokens prep → `E2E_TESTDATA_v0.18.0-beta.2.md`
> **Part 2** test cases + on-chain run → this doc + `E2E_RESULTS_*.md` (tx records)
> **Part 3** Codex challenge → each tx verified REAL (RPC receipt) **and** verified to actually achieve its product feature.
> **Bar:** every core scenario runs on-chain, every tx recorded with its business-expectation check, Codex challenge passes. Only then is this release-aspect "达标".

Legend — **Pass type:** ✅ success tx (status 0x1) · ⛔ negative tx (expected revert, status 0x0 — proves a guard actually blocks). Negative txs are first-class: they prove the security feature, not just the happy path.

---

## How each tx is checked against business expectation (the method)
For every scenario we record AND assert three layers, so a green receipt alone never counts as "feature achieved":
1. **Receipt layer** — tx mined, `status` matches Pass type (0x1 for ✅, 0x0 for ⛔), `to` = expected contract, gasUsed sane.
2. **State layer** — read on-chain state AFTER the tx and assert the exact expected delta (balance moved by exactly X, nonce advanced, flag set, owner changed, session active=false, etc.). This is "did the business effect happen".
3. **Feature layer (Codex challenge)** — Codex is told the scenario + feature + params and must independently confirm, via RPC, that the tx demonstrates THAT feature (e.g. "this proves the DVT BLS co-sign was verified on-chain and bound to this userOpHash", "this proves a non-owner is blocked by access control"), not merely that a tx happened.

---

## Scenario matrix (30 — core features one-to-one)

### A. Account model & determinism
| ID | Tx | Feature | Actor | Params | Business expectation | Verification (check) | Type |
|---|---|---|---|---|---|---|---|
| A1 | `createAccountWithDefaults` | CREATE2 deterministic account + guard + 3 guardians | Annie | guardians=[J,B,C], dailyLimit=0.01 ETH, salt=S1 | a guard-enabled account is deployed at the predicted address | `getAddress(...)`==deployed addr; code present; `owner`==Annie; `guardianCount`==3; `guard`!=0 | ✅ |
| A2 | `createAccount` (no guard) | raw owner account variant | Annie | dailyLimit=0, guardians=2, salt=S2 | a no-guard account deploys | code present; `guard`==0; `owner`==Annie | ✅ |
| A3 | `createAgentAccount` | agent-economy account + AgentRegistry bind | Annie | agentId, agentKey consent sig, salt=S3 | an agent account deploys & registers | `getAgentAddress`==deployed; `AgentRegistry.isValidAccount`==true | ✅ |
| A4 | `createAccountWithDefaults` salt=S4 | OAPD primitive — N isolated accounts per owner | Annie | same owner, different salt | distinct isolated address, same owner | addr(A4)≠addr(A1); both `owner`==Annie | ✅ |

### B. Execution & transfers (varied params/methods)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| B1 | `execute(bob, 0.005 ETH, 0x)` | Tier-1 ETH transfer (ECDSA 0x02) | Annie(owner) | value=0.005 ETH | account sends exactly 0.005 ETH to Bob | Bob balance +0.005; account balance −0.005−gas; status 0x1 | ✅ |
| B2 | `executeBatch([self,self],[0,0],[0x,0x])` | batch execution | Annie | 2 no-op calls | both calls execute atomically | status 0x1; 2 internal calls | ✅ |
| B3 | `execute(token,0,transfer(to,amt))` | ERC-20 transfer + per-asset guard + inner-calldata parse | Annie | MockERC20, amt under token tier | token moves; guard records token spend by parsed inner amount | recipient token balance +amt; `recordTokenSpend` effect; status 0x1 | ✅ |
| B4 | `addDeposit{value:0.003}` | EntryPoint deposit mechanism | Annie | 0.003 ETH | account's EntryPoint deposit increases | `EntryPoint.balanceOf(account)` +0.003 | ✅ |

### C. Signature factors & tiered verification (the core differentiation)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| C1 | UserOp (ECDSA) via bundler | Tier-1 single-factor through real bundler | Annie | algId 0x02 | small op validates with one factor | UserOpEvent success=true; on-chain effect applied | ✅ |
| C2 | `setP256Key` + P256 UserOp | WebAuthn/passkey factor (RIP-7212) | Annie | P256 (x,y), low-S sig | passkey op validates via 0x100 precompile | `p256KeyX/Y` set; UserOp validates; status 0x1 | ✅ |
| C3 | P256 op with HIGH-S sig | P256 low-S malleability guard (#78) | Annie | high-S (r, n−s) | account REJECTS malleated sig | validateUserOp→1 / op rejected; proves #78 guard | ⛔ |
| C4 | Cumulative T2 UserOp | **DVT co-sign: P256 + ≥threshold BLS aggregate** (headline) | Annie + node1/2 | algId 0x04, real BLS aggregate over userOpHash | large op requires & verifies DVT BLS on-chain, bound to this userOpHash | UserOp validates; BLS `validate(userOpHash,...)`==0; replay onto other hash would fail (#45) | ✅ |
| C5 | Cumulative T3 UserOp | DVT + guardian factor (P256+BLS+Guardian ECDSA) | Annie + node1/2 + guardian | algId 0x05 | highest tier requires 3 factors | UserOp validates only with all 3; status 0x1 | ✅ |
| C6 | Weighted multi-sig UserOp | configurable per-source weight tiers (0x07) | Annie + factors | algId 0x07, weights sum ≥ tier threshold | op validates iff cumulative weight ≥ threshold | validates at sufficient weight | ✅ |
| C7 | Combined T1 UserOp | zero-trust Tier-1 (P256 AND ECDSA, 0x06) | Annie | algId 0x06, both sigs | requires BOTH passkey and owner ECDSA | validates only with both present | ✅ |

### D. ERC-4337 / bundler
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| D1 | self-paying UserOp (Pimlico) | guard-enabled account works through ANY bundler (beta.4 fix) | Annie | guard account, executeUserOp wrapper | bundler includes a guard-account self-paying op | tx on-chain via bundler; UserOpEvent success; (the bug class that returned `AlgorithmNotApproved(0)` is gone) | ✅ |

### E. Session keys
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| E1 | `grantSessionDirect(sk1, open)` | owner direct ECDSA session grant | Annie | sk1, no scope | session becomes active | `isSessionActive(sk1)`==true | ✅ |
| E2 | `grantSession(sk2, scoped, ownerSig)` | DApp session grant w/ scope + velocity | Annie | sk2, scope=execute, velocity=10/hr, ownerSig | scoped session active | `isSessionActive(sk2)`==true; scope/velocity stored | ✅ |
| E3 | session-key **USE**: UserOp signed by sk2 | session key actually spends within scope | sk2 | op within callTarget/selector scope | a session key (not owner) drives a valid op | UserOp validates with sk2; effect applied; status 0x1 | ✅ |
| E4 | UserOp by sk2 OUT of scope | session scope enforcement | sk2 | call target/selector outside scope | out-of-scope op REJECTED | validateUserOp→1 / revert `SessionScopeViolation` | ⛔ |
| E5 | `revokeSession(sk1)` | session revocation | Annie | sk1 | session deactivated | `isSessionActive(sk1)`==false | ✅ |

### F. Social recovery (2-of-3 guardian)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| F1 | `proposeRecovery(newOwner)` | guardian proposes recovery | Jason(g0) | newOwner | recovery proposal opens | `activeRecovery.newOwner`==newOwner | ✅ |
| F2 | `approveRecovery()` | 2/3 threshold reached | Bob(g1) | — | 2 approvals recorded | `approvalBitmap` has 2 bits | ✅ |
| F3 | `cancelRecovery()` by 2-of-3 | recovery cancel requires 2 guardian votes | Jason+Bob | — | recovery cancelled by 2 guardians | `activeRecovery.newOwner`==0 after 2 votes | ✅ |
| F4 | `cancelRecovery()` by owner | owner CANNOT cancel (only guardians) | Annie | — | reverts `NotGuardian` (selector 0xef6d0f02) | status 0x0; exact revert | ⛔ |

### G. ERC-7579 modules
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| G1 | `installModule(EXECUTOR, ForceExit, sig@nonce)` | module install + guardian sig + nonce | Annie + guardian sig | typeId=2, ForceExit, sig@nonce0 | module installed; nonce advances | `isModuleInstalled`==true; `moduleManagementNonce` 0→1 | ✅ |
| G2 | `uninstallModule(2, ForceExit, 2×sig)` | module uninstall (2 guardian sigs) | Annie + 2 sigs | typeId=2 | module removed; nonce advances | `isModuleInstalled`==false; nonce 1→2 | ✅ |
| G3 | replay `installModule` with stale sig@nonce0 | module-nonce replay protection (#75) | attacker | stale sig | replay REJECTED | revert `NotGuardian()`; proves #75 | ⛔ |

### H. ForceExit (emergency, ERC-7579 executor)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| H1 | propose→approve×2→`executeForceExit` | full ForceExit cycle 2-of-3 | account + guardians | proposal + 2 approvals | emergency exit executes | proposal opened; 2 approvals; execute status 0x1 | ✅ |
| H2 | `executeForceExit` after a guardian rotated out | TOCTOU re-check (#70) | — | approve then remove guardian | execute REJECTS stale approver | revert `ApproverNoLongerGuardian()`; proves #70 | ⛔ |

### I. Guard enforcement (negative — prove the immutable guard blocks)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| I1 | `execute` by non-owner | access control | Jason (non-owner) | calls account.execute | reverts (not owner/EntryPoint) | status 0x0; `NotOwnerOrEntryPoint` | ⛔ |
| I2 | `execute(value > dailyLimit)` | daily-limit guard | Annie | value > 0.01 ETH | reverts `DailyLimitExceeded` | status 0x0; account balance unchanged | ⛔ |
| I3 | under-tier large op (no DVT) | tier gate (large needs higher factor) | Annie | value > tier1, ECDSA only | reverts `InsufficientTier` / validate→1 | status 0x0 / rejected | ⛔ |

### J. Governance (guardian-gated config — CA can't change alone)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| J1 | `modifyTierLimitsWithGuardians` | tier-limit change needs guardian consensus | Annie + 2 guardian sigs | new (tier1,tier2) | limits change only with guardian sigs | `tier1Limit/tier2Limit` updated; status 0x1 | ✅ |
| J2 | `guardApproveAlgorithm(algId)` | algorithm whitelist (account-owned, single source) | Annie | algId 0x09 | algId approved on the account | `approvedAlgorithms(0x09)`==true | ✅ |

### K. DVT / BLS infra
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| K1 | BLS single `validate` via a T2/T3 op | #45 userOpHash binding (on-chain hashToG2 recompute) | node1/2 | aggregate over userOpHash_A | aggregate valid for A, not replayable to B | `validate(A,...)`==0; (replay to B would be 1) — overlaps C4 evidence | ✅ |
| K2 | `registerPublicKey(node3)` | DVT node key registration (Safe-governed singleton) | owner(BLS alg) | node3 pubkey | a new DVT node key is registered | `getRegisteredNodeCount` +1 | ✅ |

### L. Additions (approved by owner → 36 total)
| ID | Tx | Feature | Actor | Params | Business expectation | Verification | Type |
|---|---|---|---|---|---|---|---|
| L1 | replay C4's BLS aggregate onto a different userOpHash | #45 binding (most direct proof) | attacker | C4 aggregate, hash_B | aggregate valid for A is REJECTED for B | `validate(B, aggregate_A)`==1 / op rejected | ⛔ |
| L2 | session-key UserOp exceeding velocity limit | velocity-limit enforcement | sk2 | (N+1)th op within window | over-rate op REJECTED | revert / validate→1 on velocity breach | ⛔ |
| L3 | `addGuardian` then `removeGuardian` | guardian set management | Annie (+ guardian sigs as required) | new guardian addr | guardian set changes correctly | `guardianCount` +1 then −1; set reflects change | ✅ |
| L4 | `installModule(HOOK=4, hookModule, sig)` | ERC-7579 hook module (typeId 4) | Annie + guardian sig | typeId=4 | hook module installs | `isModuleInstalled(4,...)`==true | ✅ |
| L5 | register DeFi parser + `execute` Uniswap-shape call | CalldataParserRegistry amount extraction | Annie | parser for a router, swap-shape calldata | guard extracts spend amount via the registered parser | parser returns (token,amount); guard records parsed amount; status 0x1 | ✅ |
| L6 | weight-config change governance | `pendingWeightChange` guardian-gated weight update | Annie + 2 guardian sigs | new WeightConfig | weight config changes only with guardian consensus | `weightConfig` updated after threshold | ✅ |

**Totals:** **36 scenarios — 24 ✅ success + 12 ⛔ negative(revert).** ≥10 real on-chain txs target far exceeded; negatives prove security features actually block, not just happy paths.

---

## Self-audit — feature coverage & known omissions (self-challenge round 1)

**Covered (code → scenario):** account creation 3 variants + OAPD (A1-A4); ECDSA/P256/BLS-DVT/weighted/combined/session = all 7 algIds (C1-C7,E3); tiered T1/T2/T3 + guard daily + per-asset token + hard tier gate (B1,B3,C4,C5,I2,I3); batch (B2); real bundler (D1); session grant/use/scope/velocity/revoke (E1-E5); 2-of-3 recovery + owner-can't-cancel (F1-F4); ERC-7579 install/uninstall/nonce-replay (G1-G3); ForceExit full + TOCTOU (H1-H2); access control (I1); guardian-gated governance (J1-J2); #45 BLS binding + node registration (K1-K2); plus #75/#78/#70 security regressions as negatives (G3,C3,H2).

**Deliberately deferred (with reason — NOT silent gaps):**
- **Gasless via SuperPaymaster** — depends on a live SP paymaster deployment on Sepolia; defer unless an SP test paymaster address is provided. (Flag, not skip.)
- **EIP-7702 delegate (`AirAccountDelegate`)** — needs a 7702-type tx (set-code) which the bundler/RPC must support; include only if the RPC accepts type-0x04. Otherwise documented as environment-limited.
- **Validation-side PolicyRegistry consumer** — NOT merged to main (decided), so NOT in the released contract → correctly out of scope for this release's E2E.
- **velocity-limit hit (E2 over-rate)** — folded into E4 scope-enforcement family; add as E6 if a dedicated velocity-breach revert is wanted.

**Reviewer-approved additions (2026-06-15 → now Group L, 36 total):** C4-replay (L1), velocity-breach (L2), guardian add/remove (L3), hook module (L4), DeFi parser (L5), weight-config governance (L6). All folded into the matrix above.

**Operational note:** call `clearStaleRecovery` before the F-series on salt-reused accounts (avoids `RecoveryAlreadyActive`) — operational step, not a scored scenario.

---

## Part 3 — Codex challenge protocol
After the run, hand `E2E_RESULTS_v0.18.0-beta.2.md` (every tx + its scenario/feature/params/expected-check) to Codex with this instruction:
> For each tx: (1) via Sepolia RPC confirm REAL — `eth_getTransactionReceipt` status matches the declared Pass type, `to`/gasUsed sane, not fabricated; (2) confirm the tx actually demonstrates the declared product feature (read the asserted post-state), not merely that a tx exists; (3) for ⛔ negatives, confirm it reverted for the declared reason. Output REAL/FABRICATED + FEATURE-MET/NOT-MET per tx.

**Release bar (this aspect):** all core scenarios run on-chain + recorded + Codex returns REAL & FEATURE-MET for every tx (negatives: REAL & correctly-reverted). Recorded into `RELEASE_CHECKLIST.md` as a mandatory gate.
