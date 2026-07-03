# E2E Results — v0.21.0 (Sepolia)

**Date:** 2026-06-29 · **Script:** `scripts/e2e-v0.21.0.ts` · **Network:** Sepolia
**Factory:** `0x3891c6543af966B11F772448228c7eC1906EF382`
**Impl:** `0x55fcEdC0902f192e4118E682b4f58582eaE78A73`

## Result: 14/14 PASS

| # | Test | Result |
|---|------|--------|
| T1 | `ACCOUNT_VERSION` on impl == "0.21.0" | ✅ |
| T2 | `createAccount` succeeds from v0.21.0 factory | ✅ |
| T3 | Clone `ACCOUNT_VERSION` == "0.21.0" | ✅ |
| T4 | `accountId()` == "airaccount.v7@0.21.0" | ✅ |
| T5 | algId 0x09 (ALG_CUMULATIVE_T2_WA) in whitelist | ✅ |
| T6 | algId 0x0a (ALG_CUMULATIVE_T3_WA) in whitelist | ✅ |
| T7 | algId 0x04 (ALG_CUMULATIVE_T2) still approved (regression) | ✅ |
| T8 | algId 0x05 (ALG_CUMULATIVE_T3) still approved (regression) | ✅ |
| T9 | algId 0x02 (ALG_ECDSA) still approved (regression) | ✅ |
| T10 | algId 0x01 (ALG_BLS) still approved (regression) | ✅ |
| T11 | algId 0x03 (ALG_P256) still approved (regression) | ✅ |
| T12 | algId 0x06 (ALG_COMBINED_T1) still approved (regression) | ✅ |
| T13 | algId 0x07 (ALG_WEIGHTED) still approved (regression) | ✅ |
| T14 | algId 0x08 (ALG_SESSION_KEY) still approved (regression) | ✅ |

**E2E account:** [`0xF8ea7bc0228367AfF187e970227B22EdFFdacDeB`](https://sepolia.etherscan.io/address/0xF8ea7bc0228367AfF187e970227B22EdFFdacDeB)
**createAccount tx:** [`0x282cc25793b7b33df67fd6ac2b4074f47c5eddb95b3b36478f6e82c560478ba6`](https://sepolia.etherscan.io/tx/0x282cc25793b7b33df67fd6ac2b4074f47c5eddb95b3b36478f6e82c560478ba6)
**Gas used:** 502,463

## What is NOT covered by script E2E

| Gap | Reason | Mitigation |
|-----|---------|------------|
| 0x09 actual WebAuthn signature validation | Requires browser `navigator.credentials.get` | 12 forge unit tests in `test/CumulativeSignature.t.sol` (CI green) |
| 0x0a actual WebAuthn + guardian ECDSA validation | Same | Same |
| `_base64UrlEncode32` collision resistance | Cryptographic property | Forge property tests + code review |

Full WebAuthn path E2E closure: SDK team runs a real passkey UserOp against this factory.
