/**
 * test-v0171-diamond-e2e.ts — v0.17.1 diamond-lite smoke E2E
 *
 * Fills the gap left by unit tests: confirms a *freshly deployed* v0.17.1 set is wired
 * correctly for the two release-specific behaviours, using only view / low-level eth_call
 * checks (no UserOp building, no signing) so it is safe and deterministic to run in CI
 * right after a broadcast.
 *
 * Checks:
 *   1. Factory wiring (#21):   factory.agentSessionKeyValidator() == deployed validator (has code).
 *   2. Diamond-lite singleton: account.agentExtension() is a non-zero address with code.
 *   3. Agent default-install:  account.isModuleInstalled(1, agentSessionValidator, 0x) == true.
 *   4. Fallback routing live:  low-level eth_call of a fallback-routed view (queryAgentReputation)
 *                              reaches AirAccountExtension (returns data, not an empty no-fallback
 *                              revert). Best-effort — reported as WARN, never fatal.
 *
 * The heavier on-chain agent-session UserOp flow (grantAgentSession, agent-key UserOp,
 * velocity limiting) lives in scripts/test-m7-e2e.ts — run that too against the new addresses.
 *
 * Prerequisites (.env.sepolia, or pass via env):
 *   - RPC: SEPOLIA_RPC_URL (or SEPOLIA_RPC_URL2/3, RPC_URL)
 *   - AIRACCOUNT_FACTORY            factory address from the v0.17.1 deploy
 *   - AGENT_SESSION_VALIDATOR       AgentSessionKeyValidator address from the deploy
 *   - AIRACCOUNT_AGENT_ACCOUNT      an account created via factory.createAgentAccount(...)
 *   If any required address is unset, the script SKIPs (exit 0) — wire it into CI to run
 *   only once the deploy has populated .env.<network>.
 *
 * Run: pnpm tsx scripts/test-v0171-diamond-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  http,
  fallback,
  encodeFunctionData,
  type Hex,
  type Address,
} from "viem";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ────────────────────────────────────────────────────────────────────

const RPC_URLS: string[] = [
  process.env.SEPOLIA_RPC_URL,
  process.env.SEPOLIA_RPC_URL2,
  process.env.SEPOLIA_RPC_URL3,
  process.env.RPC_URL,
].filter(Boolean) as string[];

const FACTORY        = process.env.AIRACCOUNT_FACTORY as Address | undefined;
const AGENT_VALIDATOR = process.env.AGENT_SESSION_VALIDATOR as Address | undefined;
const AGENT_ACCOUNT  = process.env.AIRACCOUNT_AGENT_ACCOUNT as Address | undefined;

// ERC-8004 Reputation registry (Sepolia testnet) — only used for the best-effort routing probe.
const REPUTATION_REGISTRY_TESTNET =
  "0x8004B663056A597Dffe9eCcC1965A193B7388713" as Address;

const MODULE_TYPE_VALIDATOR = 1n;

// ─── Minimal ABIs ────────────────────────────────────────────────────────────────

const FACTORY_ABI = [
  { name: "agentSessionKeyValidator", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address" }] },
] as const;

const ACCOUNT_ABI = [
  { name: "agentExtension", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "isModuleInstalled", type: "function", stateMutability: "view",
    inputs: [
      { name: "moduleTypeId", type: "uint256" },
      { name: "module", type: "address" },
      { name: "additionalContext", type: "bytes" },
    ], outputs: [{ name: "", type: "bool" }] },
] as const;

// Fallback-routed view (lives on AirAccountExtension, reached via the account fallback).
const AGENT_ABI = [
  { name: "queryAgentReputation", type: "function", stateMutability: "view",
    inputs: [
      { name: "reputationRegistry", type: "address" },
      { name: "agentId", type: "uint256" },
      { name: "clientAddresses", type: "address[]" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
    ], outputs: [
      { name: "count", type: "uint64" },
      { name: "summaryValue", type: "int128" },
      { name: "summaryDecimals", type: "uint8" },
    ] },
] as const;

// ─── Harness ────────────────────────────────────────────────────────────────────

let pass = 0, fail = 0, warn = 0;
const ok   = (m: string) => { pass++; console.log(`  ✅ ${m}`); };
const bad  = (m: string) => { fail++; console.log(`  ❌ ${m}`); };
const note = (m: string) => { warn++; console.log(`  ⚠️  ${m}`); };

function skip(msg: string): never {
  console.log(`\n⏭️  SKIP — ${msg}`);
  process.exit(0);
}

async function main() {
  console.log("=== v0.17.1 diamond-lite smoke E2E ===\n");

  if (RPC_URLS.length === 0) skip("no RPC url (set SEPOLIA_RPC_URL)");
  if (!FACTORY)        skip("AIRACCOUNT_FACTORY unset (set after deploy)");
  if (!AGENT_VALIDATOR) skip("AGENT_SESSION_VALIDATOR unset (set after deploy)");
  if (!AGENT_ACCOUNT)  skip("AIRACCOUNT_AGENT_ACCOUNT unset (create one via createAgentAccount, then set)");

  const client = createPublicClient({
    transport: fallback(RPC_URLS.map((u) => http(u))),
  });

  console.log(`Factory  : ${FACTORY}`);
  console.log(`Validator: ${AGENT_VALIDATOR}`);
  console.log(`Account  : ${AGENT_ACCOUNT}\n`);

  // ── Check 1: factory wiring (#21) ──
  console.log("Check 1 — factory.agentSessionKeyValidator() wiring");
  try {
    const wired = await client.readContract({
      address: FACTORY, abi: FACTORY_ABI, functionName: "agentSessionKeyValidator",
    }) as Address;
    if (wired.toLowerCase() === AGENT_VALIDATOR.toLowerCase()) {
      ok(`factory points at the deployed validator (${wired})`);
    } else if (wired === "0x0000000000000000000000000000000000000000") {
      bad("factory.agentSessionKeyValidator() == address(0) — setAgentSessionKeyValidator was never called");
    } else {
      bad(`factory points at ${wired}, expected ${AGENT_VALIDATOR}`);
    }
    const code = await client.getCode({ address: wired });
    code && code !== "0x" ? ok("validator address has code") : bad("validator address has no code");
  } catch (e) {
    bad(`factory read reverted: ${(e as Error).message.split("\n")[0]}`);
  }

  // ── Check 2: diamond-lite Extension singleton ──
  console.log("\nCheck 2 — account.agentExtension() singleton deployed");
  let extension: Address | undefined;
  try {
    extension = await client.readContract({
      address: AGENT_ACCOUNT, abi: ACCOUNT_ABI, functionName: "agentExtension",
    }) as Address;
    if (extension && extension !== "0x0000000000000000000000000000000000000000") {
      ok(`agentExtension = ${extension}`);
      const code = await client.getCode({ address: extension });
      code && code !== "0x" ? ok("AirAccountExtension has code") : bad("AirAccountExtension has no code");
    } else {
      bad("agentExtension == address(0)");
    }
  } catch (e) {
    bad(`agentExtension read reverted: ${(e as Error).message.split("\n")[0]}`);
  }

  // ── Check 3: agent default-install (#21) ──
  console.log("\nCheck 3 — AgentSessionKeyValidator default-installed on the agent account");
  try {
    const installed = await client.readContract({
      address: AGENT_ACCOUNT, abi: ACCOUNT_ABI, functionName: "isModuleInstalled",
      args: [MODULE_TYPE_VALIDATOR, AGENT_VALIDATOR, "0x"],
    }) as boolean;
    installed
      ? ok("isModuleInstalled(1, agentSessionValidator) == true")
      : bad("validator NOT installed — createAgentAccount did not default-install it");
  } catch (e) {
    bad(`isModuleInstalled read reverted: ${(e as Error).message.split("\n")[0]}`);
  }

  // ── Check 4: fallback routing live (best-effort) ──
  console.log("\nCheck 4 — fallback→delegatecall routing reaches AirAccountExtension (best-effort)");
  try {
    const data = encodeFunctionData({
      abi: AGENT_ABI, functionName: "queryAgentReputation",
      args: [REPUTATION_REGISTRY_TESTNET, 0n, [], "", ""],
    });
    const res = await client.call({ to: AGENT_ACCOUNT, data });
    // Any non-empty return means the account fallback delegatecalled into the Extension and it ran.
    res.data && res.data !== "0x"
      ? ok("routed view returned data — fallback delegatecall to Extension works")
      : note("routed view returned empty data — inconclusive (registry may have no record)");
  } catch (e) {
    // A revert that carries data still proves the call reached Extension code; an empty revert
    // at the account would indicate a routing problem. viem surfaces both as a throw, so this is
    // reported as a non-fatal WARN — confirm via the full UserOp flow in test-m7-e2e.ts.
    note(`routed view reverted (inconclusive): ${(e as Error).message.split("\n")[0]}`);
  }

  // ── Summary ──
  console.log(`\n=== Summary: ${pass} passed, ${fail} failed, ${warn} warnings ===`);
  if (fail > 0) {
    console.log("❌ v0.17.1 smoke FAILED — deployment wiring is not correct.");
    process.exit(1);
  }
  console.log("✅ v0.17.1 smoke passed (run test-m7-e2e.ts for the full agent-session flow).");
}

main().catch((e) => { console.error(e); process.exit(1); });
