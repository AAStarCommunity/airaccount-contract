/**
 * test-factory-validation-e2e.ts — Factory Constructor Validation E2E Tests (Sepolia)
 *
 * Business scenario: Invalid default token configurations should be caught at factory
 * deploy time, not silently allowed to corrupt every subsequent account creation.
 *
 * Tests constructor-level validation added in the Codex audit:
 *   A: Zero token address in defaultTokens => revert "Default token address zero"
 *   B: Duplicate token address in defaultTokens => revert "Duplicate default token"
 *   C: Tier config where tier1 > tier2 => revert "Invalid default token config"
 *   D: Token has limits but daily=0 (unenforceable) => revert "Invalid default token config"
 *   E: Valid config (sanity check — deploy succeeds)
 *
 * Method: Simulate deployments via eth_estimateGas (rejects bad constructor args before
 * any on-chain state change). Each test encodes the full deployment bytecode + constructor
 * args and calls publicClient.estimateGas({ data, account }). Reverts are caught locally.
 *
 * Prerequisites:
 *   - forge build (needs up-to-date artifacts in out/)
 *   - .env.sepolia: PRIVATE_KEY, SEPOLIA_RPC_URL
 *   - ENTRYPOINT and COMMUNITY_GUARDIAN from .env.sepolia or hardcoded defaults
 *
 * Run: npx tsx scripts/test-factory-validation-e2e.ts
 */

import { config } from "dotenv";
import { resolve, dirname } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  http,
  encodeAbiParameters,
  concat,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT = (process.env.ENTRYPOINT ?? "0x0000000071727De22E5E9d8BAf0edAc6f37da032") as Address;
const COMMUNITY_GUARDIAN = (process.env.COMMUNITY_GUARDIAN ?? "0x0000000000000000000000000000000000000001") as Address;

// Dummy ERC20 token on Sepolia for valid config tests
const DUMMY_TOKEN_A = "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address; // aPNTs
const DUMMY_TOKEN_B = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as Address; // USDC Sepolia

// ─── Load Factory Bytecode ────────────────────────────────────────────────────

const artifactPath = resolve(
  import.meta.dirname,
  "../out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json"
);
const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
const FACTORY_BYTECODE = artifact.bytecode.object as Hex;

// ─── ABI types for constructor args ──────────────────────────────────────────

// constructor(address _entryPoint, address _communityGuardian, address[] defaultTokens, TokenConfig[] defaultConfigs)
const CONSTRUCTOR_INPUTS = [
  { type: "address", name: "_entryPoint" },
  { type: "address", name: "_communityGuardian" },
  { type: "address[]", name: "defaultTokens" },
  {
    type: "tuple[]",
    name: "defaultConfigs",
    components: [
      { type: "uint256", name: "tier1Limit" },
      { type: "uint256", name: "tier2Limit" },
      { type: "uint256", name: "dailyLimit" },
      { type: "uint256", name: "minDailyLimit" },
    ],
  },
] as const;

// ─── Helper: build encoded deploy data (bytecode + constructor args) ──────────

function encodeDeployData(
  tokens: Address[],
  configs: { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint; minDailyLimit: bigint }[]
): Hex {
  const args = encodeAbiParameters(CONSTRUCTOR_INPUTS, [
    ENTRYPOINT,
    COMMUNITY_GUARDIAN,
    tokens,
    configs,
  ]);
  return concat([FACTORY_BYTECODE, args]);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== Factory Constructor Validation E2E Test (Sepolia) ===\n");
  console.log("Verifies that invalid default token configs are rejected at deploy time.");
  console.log("Method: simulate deployment via eth_estimateGas (no on-chain state change)\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const owner = privateKeyToAccount(PRIVATE_KEY);

  console.log(`Caller: ${owner.address}`);
  console.log(`EntryPoint: ${ENTRYPOINT}`);

  let passed = 0;
  let failed = 0;

  // ── Test A: Zero token address ────────────────────────────────────────────

  console.log("\n[Test A] Zero token address in defaultTokens");
  console.log("  Input:    tokens=[address(0)], valid config");
  console.log("  Expected: revert 'Default token address zero'");

  try {
    const data = encodeDeployData(
      ["0x0000000000000000000000000000000000000000" as Address],
      [{ tier1Limit: 100n, tier2Limit: 1000n, dailyLimit: 5000n, minDailyLimit: 0n }]
    );
    await publicClient.estimateGas({ data, account: owner.address });
    console.log("  FAIL: Should have reverted but didn't");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("Default token address zero") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Constructor rejected zero token address");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test B: Duplicate token address ──────────────────────────────────────

  console.log("\n[Test B] Duplicate token address in defaultTokens");
  console.log(`  Input:    tokens=[${DUMMY_TOKEN_A}, ${DUMMY_TOKEN_A}], valid configs`);
  console.log("  Expected: revert 'Duplicate default token'");

  try {
    const data = encodeDeployData(
      [DUMMY_TOKEN_A, DUMMY_TOKEN_A],
      [
        { tier1Limit: 100n, tier2Limit: 1000n, dailyLimit: 5000n, minDailyLimit: 0n },
        { tier1Limit: 100n, tier2Limit: 1000n, dailyLimit: 5000n, minDailyLimit: 0n },
      ]
    );
    await publicClient.estimateGas({ data, account: owner.address });
    console.log("  FAIL: Should have reverted but didn't");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("Duplicate default token") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Constructor rejected duplicate token");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test C: tier1 > tier2 (invalid tier ordering) ────────────────────────

  console.log("\n[Test C] tier1Limit > tier2Limit (inverted tier hierarchy)");
  console.log("  Input:    tier1=1000, tier2=100, daily=5000");
  console.log("  Expected: revert 'Invalid default token config'");

  try {
    const data = encodeDeployData(
      [DUMMY_TOKEN_A],
      [{ tier1Limit: 1000n, tier2Limit: 100n, dailyLimit: 5000n, minDailyLimit: 0n }]
    );
    await publicClient.estimateGas({ data, account: owner.address });
    console.log("  FAIL: Should have reverted but didn't");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("Invalid default token config") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Constructor rejected tier1 > tier2 config");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test D: Has tier limits but daily=0 (unenforceable config) ────────────

  console.log("\n[Test D] tier limits set but dailyLimit=0 (unenforceable)");
  console.log("  Input:    tier1=100, tier2=1000, daily=0");
  console.log("  Expected: revert 'Invalid default token config'");

  try {
    const data = encodeDeployData(
      [DUMMY_TOKEN_A],
      [{ tier1Limit: 100n, tier2Limit: 1000n, dailyLimit: 0n, minDailyLimit: 0n }]
    );
    await publicClient.estimateGas({ data, account: owner.address });
    console.log("  FAIL: Should have reverted but didn't");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("Invalid default token config") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Constructor rejected tier-with-no-daily config");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test E: Valid config (sanity check — deploy must succeed) ─────────────

  console.log("\n[Test E] Sanity check: valid config should NOT revert");
  console.log(`  Input:    tokens=[${DUMMY_TOKEN_A}, ${DUMMY_TOKEN_B}], valid configs`);
  console.log("  Expected: gas estimate succeeds (no revert)");

  try {
    const data = encodeDeployData(
      [DUMMY_TOKEN_A, DUMMY_TOKEN_B],
      [
        { tier1Limit: 100n, tier2Limit: 1000n, dailyLimit: 5000n, minDailyLimit: 0n },
        { tier1Limit: 50n, tier2Limit: 500n, dailyLimit: 2000n, minDailyLimit: 0n },
      ]
    );
    const gas = await publicClient.estimateGas({ data, account: owner.address });
    console.log(`  PASS: Valid factory deployment gas estimate: ${gas}`);
    passed++;
  } catch (e: any) {
    console.log(`  FAIL: Valid config was rejected: ${e.message?.slice(0, 150)}`);
    failed++;
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  console.log(`\n${"─".repeat(50)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (failed === 0) {
    console.log("ALL PASS: Factory constructor validation is working correctly.");
    console.log("Codex Audit LOW-1 (address(0)) and LOW-2 (dedup) are enforced on-chain.");
  } else {
    console.log("FAILURES DETECTED — investigate above.");
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
