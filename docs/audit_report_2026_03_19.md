2026-03-19 Audit Report — AirAccount Contract Library (M5)

**Scope**
- Core contracts: `src/core/AAStarAirAccountBase.sol`, `src/core/AAStarGlobalGuard.sol`, `src/core/AAStarAirAccountFactoryV7.sol`, `src/core/AAStarAirAccountV7.sol`
- Validator/Aggregator: `src/validators/AAStarValidator.sol`, `src/validators/AAStarBLSAlgorithm.sol`, `src/aggregator/AAStarBLSAggregator.sol`
- Deployment and E2E scripts that instantiate the Factory

**Methodology**
- Static review of current codebase and scripts after recent changes
- Consistency check vs in-repo design intent (tiering, token guard, factory defaults)

**Summary**
- No Critical or High severity findings identified in the core contracts.
- Medium risks are concentrated in script/ops mismatches and guardian acceptance replay scope.
- Core consistency improvements landed: messagePoint binding for ALG_BLS, aligned token guard tier mapping, and CombinedT1 EIP-2 s-check.

**Findings**

**MEDIUM — E2E/deploy scripts still use the old Factory constructor signature**
Impact: Deployment scripts that pass only two constructor args will deploy incorrect bytecode for the new 4‑arg constructor, causing failed deploys or unusable factory addresses in test flows.
Evidence: `scripts/test-e2e-ecdsa.ts` still encodes a single `ENTRYPOINT` constructor arg. `scripts/deploy-m4.ts` (and similarly `scripts/deploy-m3.ts`) still pass only two args.  
References: `scripts/test-e2e-ecdsa.ts:306`, `scripts/deploy-m4.ts:75`
Recommendation: Update all factory‑deploying scripts to pass `(entryPoint, communityGuardian, defaultTokens, defaultConfigs)` or to reuse an already deployed factory address.

**MEDIUM — Guardian acceptance signatures are not domain‑separated**
Impact: The acceptance hash is `("ACCEPT_GUARDIAN", owner, salt)` without `chainId` or `factory` address. A guardian signature could be replayed across chains/factories using the same owner+salt.  
Evidence: `AAStarAirAccountFactoryV7.createAccountWithDefaults` acceptance hash.  
Reference: `src/core/AAStarAirAccountFactoryV7.sol:120`  
Recommendation: Include `chainId` and `address(this)` in the acceptance preimage, or explicitly document the cross‑chain replay risk and require off‑chain checks.

**LOW — Default token configs are not validated at factory deploy time**
Impact: If the deployer supplies an invalid default token config (e.g., `tier2 > dailyLimit`), the factory deploy will succeed but `createAccountWithDefaults` will revert for all accounts, requiring a new factory deployment.  
Evidence: Factory constructor only checks array lengths; no validation against guard rules.  
Reference: `src/core/AAStarAirAccountFactoryV7.sol:38`  
Recommendation: Validate default token configs during factory construction (reuse guard’s validation logic) and revert early on invalid defaults.

**LOW — Account tier mapping defaults unknown algId to Tier 1**
Impact: If a new algorithm is approved and `_algTier` is not updated, ETH tier enforcement will treat it as Tier 1. This is a configuration footgun that can weaken intended tier policy.  
Evidence: `_algTier` default return path.  
Reference: `src/core/AAStarAirAccountBase.sol:761`  
Recommendation: Add explicit mapping for each approved algId or revert on unknown algId in `_algTier`.

**Notes on Resolved Items**
- ALG_BLS messagePoint is now bound to `userOpHash` in `_validateTripleSignature`.  
Reference: `src/core/AAStarAirAccountBase.sol:574`
- Token guard tier mapping now aligns with account tiering (P256 → Tier 1, BLS → Tier 3).  
Reference: `src/core/AAStarGlobalGuard.sol:273`
- CombinedT1 now enforces EIP‑2 low‑s check for ECDSA.  
Reference: `src/core/AAStarAirAccountBase.sol:492`

**Test Status**
- Tests not executed in this audit. Run unit + E2E suites after updating deploy scripts to the new constructor signature.
