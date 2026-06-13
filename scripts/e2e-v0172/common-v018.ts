/**
 * scripts/e2e-v0172/common-v018.ts
 *
 * Shared helpers for the v0.18 (WS-A/B/C/G) E2E scripts (phases 13–16).
 *
 * THESE TESTS ARE PENDING THE v0.18 DEPLOY. The v0.18 contracts (with the
 * WS-A module-management nonce, WS-B ForceExit TOCTOU re-verify, WS-C
 * session-key cap + sliding velocity, WS-G P256 low-S guard) are NOT yet
 * deployed to Sepolia — beta.4 is still the live deployment.
 *
 * Each phase-13..16 script calls `requireV018()`. When the v0.18 addresses
 * are absent from `.env.sepolia` the script prints a clear PENDING banner and
 * exits 0 (SKIP, not FAIL). Once v0.18 is deployed, add the addresses below to
 * `.env.sepolia` and the scripts run unchanged.
 *
 * Expected `.env.sepolia` keys (add after the v0.18 deploy):
 *   AIRACCOUNT_V018_FACTORY
 *   AIRACCOUNT_V018_IMPL
 *   AIRACCOUNT_V018_SESSION_KEY_VALIDATOR
 *   AIRACCOUNT_V018_FORCE_EXIT_MODULE
 *   AIRACCOUNT_V018_VALIDATOR_ROUTER
 *   AIRACCOUNT_V018_EXTENSION        (optional)
 *   AIRACCOUNT_V018_AGENT_REGISTRY   (optional)
 */

import {
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  type Address,
} from "viem";

// v0.18 on-chain constants (must match the merged source).
export const GUARDIAN_SIG_VERSION = 4;          // AAStarAirAccountBase.GUARDIAN_SIG_VERSION
export const CHAIN_ID = 11155111n;              // Sepolia
export const MAX_SESSION_KEYS_PER_ACCOUNT = 50; // SessionKeyValidator (issue #83)

export interface V018Addr {
  factory: Address;
  impl: Address;
  sessionKeyValidator: Address;
  forceExitModule: Address;
  validatorRouter: Address;
}

/**
 * Resolve the v0.18 deployed addresses, or `null` if not yet deployed.
 * Returning null (rather than throwing) lets the caller SKIP cleanly.
 */
export function v018Addr(): V018Addr | null {
  const factory = process.env.AIRACCOUNT_V018_FACTORY;
  const impl = process.env.AIRACCOUNT_V018_IMPL;
  const skv = process.env.AIRACCOUNT_V018_SESSION_KEY_VALIDATOR;
  const fem = process.env.AIRACCOUNT_V018_FORCE_EXIT_MODULE;
  const router = process.env.AIRACCOUNT_V018_VALIDATOR_ROUTER;
  if (!factory || !impl || !skv || !fem || !router) return null;
  return {
    factory: factory as Address,
    impl: impl as Address,
    sessionKeyValidator: skv as Address,
    forceExitModule: fem as Address,
    validatorRouter: router as Address,
  };
}

/**
 * If v0.18 is not deployed, print a PENDING banner and exit 0 (SKIP).
 * Returns the resolved addresses otherwise.
 */
export function requireV018(phase: string): V018Addr {
  const a = v018Addr();
  if (a) return a;
  console.log(`\n${"=".repeat(72)}`);
  console.log(`  Phase ${phase} — PENDING v0.18 DEPLOY (SKIPPED)`);
  console.log(`${"=".repeat(72)}`);
  console.log(
    `\n  The v0.18 (WS-A/B/C/G) contracts are not yet deployed to Sepolia.\n` +
    `  beta.4 is still live. This E2E is scaffolded and verified against the\n` +
    `  merged v0.18 source ABI, but cannot run on-chain until the v0.18 deploy\n` +
    `  lands and these keys are added to .env.sepolia:\n\n` +
    `    AIRACCOUNT_V018_FACTORY\n` +
    `    AIRACCOUNT_V018_IMPL\n` +
    `    AIRACCOUNT_V018_SESSION_KEY_VALIDATOR\n` +
    `    AIRACCOUNT_V018_FORCE_EXIT_MODULE\n` +
    `    AIRACCOUNT_V018_VALIDATOR_ROUTER\n\n` +
    `  TODO: run this script after the v0.18 deploy.\n`,
  );
  process.exit(0);
}

/**
 * Build the inner hash for a v0.18 guardian-signed operation, matching
 * AAStarAirAccountBase._guardianOpHash:
 *
 *   keccak256(abi.encode(
 *     GUARDIAN_SIG_VERSION, block.chainid, address(this), opLabel, opData
 *   )).toEthSignedMessageHash()
 *
 * The returned value is the PRE-EIP-191 hash; sign it with
 * `signer.signMessage({ message: { raw } })` so viem applies the
 * "\x19Ethereum Signed Message:\n32" prefix the contract expects.
 */
export function guardianOpHashRaw(
  account: Address,
  opLabel: string,
  opData: `0x${string}`,
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("uint8, uint256, address, string, bytes"),
      [GUARDIAN_SIG_VERSION, CHAIN_ID, account, opLabel, opData],
    ),
  );
}

/**
 * opData for INSTALL_MODULE (issue #75):
 *   abi.encode(moduleTypeId, module, moduleInitDataHash, moduleManagementNonce)
 */
export function installOpData(
  moduleTypeId: bigint,
  module: Address,
  moduleInitDataHash: `0x${string}`,
  nonce: bigint,
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("uint256, address, bytes32, uint256"),
    [moduleTypeId, module, moduleInitDataHash, nonce],
  );
}

/**
 * opData for UNINSTALL_MODULE (issue #75):
 *   abi.encode(moduleTypeId, module, moduleManagementNonce)
 */
export function uninstallOpData(
  moduleTypeId: bigint,
  module: Address,
  nonce: bigint,
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("uint256, address, uint256"),
    [moduleTypeId, module, nonce],
  );
}

// secp256r1 (P-256) curve order / 2 — low-S canonicality bound (WS-G, issue #78).
// Mirrors SECP256R1_N_OVER_2 in AAStarAirAccountBase.
export const SECP256R1_N_OVER_2 =
  0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8n;
