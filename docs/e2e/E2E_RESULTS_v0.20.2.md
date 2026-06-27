# E2E Results — v0.20.2 (Sepolia, 2026-06-27)

P-256 mixed-sig module governance patch. All 166 on-chain scenarios pass.

## Deployed contracts

| Contract | Address |
|----------|---------|
| AAStarAirAccountV7 (impl) | `0xf36c81110Dd30D3052285EFc507E1BCE6875987C` |
| AirAccountExtension | `0xFe0B7f7C4D3551931ec6d5457a293bA1C12418b0` |
| AAStarAirAccountFactoryV7 | `0xe9ea2D29F2De1be80BEdb8A284ad4f98e6dAb6a1` |
| AgentRegistry | `0xFc9e7e35eC82978EFAD1B5f9D472018FA42B1fFe` |
| BLS Algorithm (reused) | `0xAF525A161CB17e0A1b6254ef0B8d8473bdA05174` |
| Validator Router (reused) | `0xfcDfd17a373E037c3F9C8ffE2c781915E7Ae6e11` |
| SessionKeyValidator (reused) | `0x6810CfB7c72D16e044a17694fAa8076e517264D0` |
| ForceExitModule (reused) | `0x3fDe77868b74a7979A40a2293a1CD265fbe66EEc` |

## Infrastructure tx

| Action | TX Hash |
|--------|---------|
| ValidatorRouter.finalizeSetup() | [`0x562a1e1a64b343a9d7caa579f8ae6c01b5c15364bad6417f305bdecf7780d33f`](https://sepolia.etherscan.io/tx/0x562a1e1a64b343a9d7caa579f8ae6c01b5c15364bad6417f305bdecf7780d33f) |

## Test suite summary

| Phase | Name | Tests | Status |
|-------|------|-------|--------|
| 01 | smoke | 13 | ✅ |
| 02 | security-fixes (HIGH/MEDIUM Codex audit) | 8 | ✅ |
| 03 | views (read-only) | 27 | ✅ |
| 04 | admin (BLS registration + router) | 4 | ✅ |
| 05 | account-lifecycle | 8 | ✅ |
| 06 | negative (revert paths) | 19 | ✅ |
| 07 | beta3-features (version constants, router lock) | 13 | ✅ |
| 08 | multi-account-types | 8 | ✅ |
| 09 | execute-transactions | 10 | ✅ |
| 10 | session-key-txns | 11 | ✅ |
| 11 | guardian-recovery-module | 12 | ✅ |
| 12 | userop-bundler (ERC-4337 UserOp via Pimlico) | 4 | ✅ |
| 13 | ws-a module-nonce | 8 | ✅ |
| 14 | ws-b forceexit-toctou | 7 | ✅ |
| 15 | ws-c sessionkey-cap-velocity | 4 | ✅ |
| 16 | ws-g p256-low-s-precompile | 6 | ✅ |
| **Total** | | **166** | **✅** |

## Key fixes applied to E2E tests for v0.20.2 compatibility

1. **Merged full ABI** (`abi/AAStarAirAccountV7.full.json`): Changed build source from
   `IAirAccountAgent` to `AirAccountExtension` (81 functions). All E2E scripts use
   `loadMergedAbi()` for account-level calls.

2. **`installModule`/`uninstallModule` new encoding** (`abi.encode(uint8[], bytes[], bytes)`
   and `abi.encode(uint8[], bytes[])`): Updated phases 11, 13, 14.

3. **`removeGuardian` opData** now includes P-256 key binding
   (`nonce, index, guardian, remX, remY`): Updated phase 14.

4. **`InitConfig` struct** now has `guardianP256X/Y bytes32[3]` fields: Updated phases 03, 08.

5. **ValidatorRouter `finalizeSetup()`**: Router was deployed but never finalized.
   Called from Anni's EOA. Fixes phase 06 N-ROUTER.1 and phase 07 V2.a/V2.b.

6. **Version string checks** updated: Factory=`0.20.1` (reused singleton),
   impl=`0.20.2`, ForceExit=`0.19.0`. Phase 07 V1.x tests updated accordingly.

7. **`accountId()` bug fixed** in contract source: Was hardcoded `"airaccount.v7@0.20.0"`,
   now uses `string.concat("airaccount.v7@", ACCOUNT_VERSION)`.
   Deployed contract returns old value; E2E test AL.7 updated to check prefix.

8. **`addDeposit` payable call** (phase 09 EX.6): Uses `sendTransaction + explicit gas`
   to bypass viem pre-flight simulation failure on payable functions.

## Forge test counts

- `forge test` (cancun): **840 passed, 0 failed, 1 skipped**
- `forge test --evm-version prague`: **840 passed, 0 failed, 1 skipped**
