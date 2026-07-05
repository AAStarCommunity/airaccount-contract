# Deployment & Migration — v0.27.0 (Sepolia)

**Network:** Sepolia · **Date:** 2026-07-05 · **Blocks:** 11207163–11207169
**Deployer:** `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` · **EntryPoint:** v0.7
**Script:** `scripts/deploy-v0.27.0.ts`

> **DVT validator unification (Seeder CC-10).** Mounts the DVT-repo authoritative BLS validator at
> algId 0x01, replacing airaccount's own `AAStarBLSAlgorithm` (0xAF525A).

## New addresses (v0.27.0)

| Contract | Address |
|---|---|
| **AAStarAirAccountFactoryV7** | [`0xf25621DF4c6100cdfe224054C2b09f2963bF487b`](https://sepolia.etherscan.io/address/0xf25621DF4c6100cdfe224054C2b09f2963bF487b) |
| AAStarAirAccountV7 (impl) | [`0x4a76dEf9eE4EE44eF6D0B2a327a068B5B7931E1C`](https://sepolia.etherscan.io/address/0x4a76dEf9eE4EE44eF6D0B2a327a068B5B7931E1C) |
| AirAccountExtension | `0xEcE87546989Da7df573b107D54a0ead0aCB49923` |
| **AAStarValidator (router, new)** | [`0xe68d6A7Bb60DA4caE62ceC2439722fc5eEF87a5c`](https://sepolia.etherscan.io/address/0xe68d6A7Bb60DA4caE62ceC2439722fc5eEF87a5c) |
| **DVT validator (algId 0x01)** | [`0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC`](https://sepolia.etherscan.io/address/0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC) |
| AgentRegistry | `0x239960EeA98cEC6f02608ED4Bc440b7d8442f3Da` |

Reused: SessionKeyValidator `0x6b044fB2…` (0x08), ForceExit, Delegate, ParserRegistry.

## Router wiring (verified on-chain)
- `router.getAlgorithm(0x01)` → `0x539B9681…` (DVT validator) ✓
- `router.getAlgorithm(0x08)` → `0x6b044fB2…` (reused SessionKeyValidator) ✓
- `impl.validatorRouter()` → the new router ✓
- `DVT.validate(goldenUserOpHash, [nodeIds↑][blsSig])` → `0` (dvt golden vector, 2 nodes) ✓

## Verification
- 900 tests (cancun + prague). EIP-170: impl 24,304 B (272 headroom, runs=200).
- On-chain **E2E 31/31** (T31 = DVT mount + golden-vector BLS validate()==0) + **4/4 real UserOp**
  (0x02 included `0x0c3b527e…`; raw-65 rejected AA24 — no regression).
- Bytecode-identity keccak `0x7b0cf2917fef54397ffd1bfb91a5d2fcdcbc18913f8769cd13a12958e3eb7ec6`
  (immutable-masked) matches the fixed artifact.

## 0xAF525A retirement / migration plan
`AAStarValidator` is add-only + set-once — 0x01 on the OLD router (`0x10fAfB…`) is permanently
`0xAF525A`, and existing accounts' `validator` pointer is set-once. So there is **no in-place migration**:

- **New accounts** (from the v0.27.0 factory `0xf25621DF…`) use the DVT validator at 0x01. ✅
- **Existing accounts** (v0.24.0–v0.26.0, on `0x10fAfB…`) keep using `0xAF525A` — unaffected, no break.
- **"Retiring" 0xAF525A** = stop using it for NEW deployments only. Optionally, the protocol Safe
  (owner of 0xAF525A) can later `revokePublicKey()` all DVT nodes to disable the old BLS path, but only
  after users migrate — coordinate the timing with SDK/bundler to avoid a validation-failure window.
- **User migration** (optional): create a new v0.27.0 account and move assets (social recovery or
  active transfer). Not forced — old accounts remain fully functional on 0xAF525A.

## Known limitation
DVT validator has no `aggregator()` → v0.27.0 accounts use inline single-op BLS (ERC-4337 IAggregator
batch aggregation unavailable). Future no-break upgrade: a DVT validator that adds `aggregator()` + a
future validator-stack version. The account already reads `aggregator()` via try/catch.

## Wire contract (SDK)
BLS aggregate payloads `[nodeIds...][blsSig(256)]` must have **strictly-ascending nodeIds**
(aastar-sdk#274). DVT operators re-register with `nodeId = keccak256(pubkey)`.
