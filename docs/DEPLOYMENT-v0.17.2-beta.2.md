# Deployment — v0.17.2-beta.2 (Delta Release)

**Date**: 2026-06-02
**Base**: v0.17.2-beta.1 (deployed 2026-06-01, `docs/DEPLOYMENT-v0.17.2-beta.1.md`)
**Scope**: 1 contract redeploy + Etherscan verify. 10 contracts unchanged.

## Summary

v0.17.2-beta.2 contains ONE Solidity source change vs beta.1:

- **`src/core/ForceExitModule.sol`** — LOW-3 partial fix (stale-guardian check in `approveForceExit`). See `docs/forceexit-design-notes.md` for the full discussion of why expiry was rejected and stale-guardian check accepted.

All other 10 contracts have identical bytecode to beta.1 and **keep their addresses**.

## What changed in ForceExitModule

```solidity
// New error
error SignerNoLongerGuardian();

// Inside approveForceExit, after the snapshot check:
address[3] memory currentGuardians = _readGuardians(account);
bool stillCurrentGuardian = false;
for (uint256 i = 0; i < 3; i++) {
    if (currentGuardians[i] == signer) { stillCurrentGuardian = true; break; }
}
if (!stillCurrentGuardian) revert SignerNoLongerGuardian();
```

Effect: a guardian who was rotated out (via `removeGuardian` + `addGuardian`) cannot complete an approval on an existing proposal — even if their signature still matches the proposal's snapshot. The dApp layer should warn users about pending proposals when they rotate guardians.

## Sepolia addresses (v0.17.2-beta.2)

| Contract | Address | Status vs beta.1 |
|---|---|---|
| AAStarBLSAlgorithm | [`0xB82127182A855B82eED05e47536FcE568b626457`](https://sepolia.etherscan.io/address/0xB82127182A855B82eED05e47536FcE568b626457) | unchanged ✅ |
| AAStarValidator (router) | [`0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F`](https://sepolia.etherscan.io/address/0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F) | unchanged ✅ |
| AAStarBLSAggregator | [`0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1`](https://sepolia.etherscan.io/address/0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1) | unchanged ✅ |
| SessionKeyValidator | [`0xc1e2534D9Cae27Fd9776e612229115604A9e07E9`](https://sepolia.etherscan.io/address/0xc1e2534D9Cae27Fd9776e612229115604A9e07E9) | unchanged ✅ |
| **ForceExitModule** | [`0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9`](https://sepolia.etherscan.io/address/0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9) | **NEW (v0.17.2-beta.2)** ✅ verified |
| ~~ForceExitModule (deprecated)~~ | ~~`0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9`~~ | **DEPRECATED** — beta.1 version without LOW-3 fix; do not install on new accounts |
| AirAccountDelegate | [`0x8603AAF6C3f07fdae810B323c95a198D796EC52E`](https://sepolia.etherscan.io/address/0x8603AAF6C3f07fdae810B323c95a198D796EC52E) | unchanged ✅ |
| CalldataParserRegistry | [`0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F`](https://sepolia.etherscan.io/address/0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F) | unchanged ✅ |
| AAStarAirAccountFactoryV7 | [`0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9`](https://sepolia.etherscan.io/address/0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9) | unchanged ✅ |
| AAStarAirAccountV7 (impl) | [`0x05274e4Af481e5c23287571F71C52afCCC5Df127`](https://sepolia.etherscan.io/address/0x05274e4Af481e5c23287571F71C52afCCC5Df127) | unchanged ✅ |
| AirAccountExtension | [`0x6e3E6d7e6DFb383CeaAe6A9ae478745FFc5cAac0`](https://sepolia.etherscan.io/address/0x6e3E6d7e6DFb383CeaAe6A9ae478745FFc5cAac0) | unchanged ✅ |
| AgentRegistry | [`0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB`](https://sepolia.etherscan.io/address/0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB) | unchanged ✅ |

## Impact on existing accounts

`ForceExitModule` is a **per-account installed module** (ERC-7579 Executor, moduleTypeId=2). It is NOT auto-wired by the factory and NOT part of any default install.

- **No production AirAccount on beta.1 has installed ForceExitModule.** The first beta.1 AirAccount instance (`0x0f214C7681…`) never called `installModule(2, forceExitModule)`. So **zero migration needed**.
- New accounts wanting force-exit functionality should install the **new** address `0xc7128A1F66DFf7B607d595371FCAEeAdC485CFC9`. The deprecated address still works but lacks the LOW-3 stale-guardian fix.
- The `.env.sepolia` retains the old address as `AIRACCOUNT_V0172_BETA1_FORCE_EXIT_MODULE` for historical reference; the canonical pointer `AIRACCOUNT_V0172_BETA_FORCE_EXIT_MODULE` now points to the new address.

## Re-deploy command

```bash
bash scripts/deploy-v0172-beta-sepolia.sh    # If redeploying the full stack
# OR (delta-only, for ForceExitModule alone):
DEPLOYER_KEY=$PRIVATE_KEY_ANNI \
forge script script/DeployForceExitOnly.s.sol \
  --rpc-url $SEPOLIA_RPC_URL3 \
  --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

(Note: in the actual deploy, `SEPOLIA_RPC_URL` was unstable and `SEPOLIA_RPC_URL3` succeeded. Fallback RPCs in `.env.sepolia` were all useful.)

## Verification status

| Item | Status |
|---|---|
| Deployment broadcast | ✅ 2026-06-02 |
| Etherscan auto-verify | ✅ "Pass - Verified" in same broadcast |
| forge test regression | ✅ 674/0/0 (3 new stale-guardian tests pass) |
| Gas used (1 contract) | ~1.8M gas (~0.002 ETH) |

## Next steps

- [ ] Tag `v0.17.2-beta.2`
- [ ] GitHub Release notes (prerelease)
- [ ] Optional: run Phase 7 E2E targeting new ForceExitModule (stale-guardian on-chain proof)
- [ ] OP Sepolia deploy (separate exercise — different chain)
