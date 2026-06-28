# E2E Results — v0.20.3 (Sepolia, 2026-06-28)

## Scope

v0.20.3 is a targeted patch: `onlyOwner` → `onlyOwnerOrSelf` on 4 config functions.
E2E covers the new self-call path specifically; full regression is inherited from v0.20.2 (no other behaviour changed).

## Deployment under test

| Contract | Address |
|---|---|
| AAStarAirAccountV7 (impl) | `0x91Ee5a7ec57A82f3FcEe991bDc75d918266edcb8` |
| AirAccountExtension | `0xC3F4Ff562b8cB806bc3207cFD2d4621994599880` |
| AAStarAirAccountFactoryV7 | `0x78775786dc6B1CD2f6631Ab59C2BE86B1a1e585e` |
| AgentRegistry | `0x33B3287Ef08219E84fEEF8BF3BE787347A3Df064` |

Script: `scripts/e2e-v0203-self-call.ts`

## Results (5/5 PASS)

| Test | Description | Status | Tx / Notes |
|---|---|---|---|
| T1 | Create account from v0.20.3 factory | ✅ PASS | [0xeeae92fb…](https://sepolia.etherscan.io/tx/0xeeae92fb7af43beb5436ef7954138c667772cdd670fb426b582a384a3e584f25) Gas: 260,967 |
| T2 | ACCOUNT_VERSION == "0.20.3" on-chain | ✅ PASS | read `0x3fC13887379Bf3A884c978Caa73873cA52b9ea06`.ACCOUNT_VERSION → "0.20.3" |
| T3 | `setTierLimits` via self-call (owner → execute) | ✅ PASS | [0xab498fcc…](https://sepolia.etherscan.io/tx/0xab498fcc1c0db1538b79e1e9cf0e3a1303d9ef3eaf89421eeacd97a45862c30f) Gas: 105,696 |
| T4 | tier1Limit / tier2Limit updated on-chain | ✅ PASS | tier1=0.1 ETH, tier2=1 ETH — confirmed via `readContract` |
| T5 | Second `setTierLimits` reverts (latch) | ✅ PASS | `simulateContract` → `CannotIncreaseTierLimit` (0x9f081f40) |

Account under test: `0x3fC13887379Bf3A884c978Caa73873cA52b9ea06`

## Security review

10-vector Codex adversarial audit performed pre-merge (PR #142). All vectors SAFE.
See PR body for full table (reentrancy, ERC-7562, guardian-sig bypass, latch bypass,
flash-loan atomic, weakening guard, batch execute, validation-phase trigger, delegatecall
`address(this)`, ERC-1271 path).

## Known limitations (Info from reviewer)

- E2E uses EOA→`execute()` path, not a full gasless bundler UserOp chain. The contract-level
  self-call path is fully exercised; bundler-level E2E is covered by the separate bundler test suite.
- `modifyTierLimitsWithGuardians`, `setWeightConfig`, `modifyTierLimitsWithMixedGuardians`
  self-call paths are covered by unit tests (`test_modifyTierLimitsWithGuardians_selfCall_succeeds`,
  `test_setWeightConfig_selfCall_succeeds`, `test_modifyTierLimitsWithMixedGuardians_selfCall_succeeds`)
  but not in this on-chain E2E (would require guardian sigs + P-256 infra).
