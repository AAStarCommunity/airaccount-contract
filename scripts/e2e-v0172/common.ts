/**
 * scripts/e2e-v0172/common.ts
 *
 * Shared utilities for v0.17.2-beta.1 Sepolia E2E tests.
 *
 * Centralizes:
 *  - .env.sepolia loading + address resolution
 *  - viem public + wallet clients (Anni / Jason / Bob)
 *  - ABI loading from out/<Contract>.sol/<Contract>.json
 *  - Result recorder appending to docs/e2e-results-v0.17.2-beta.1.md
 *  - Generic assertion helpers
 */

import { config } from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { readFileSync, appendFileSync, existsSync, writeFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  fallback,
  type Address,
  type Hash,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, "..", "..");

config({ path: resolve(REPO_ROOT, ".env.sepolia") });

function envRequired(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name} in .env.sepolia`);
  return v;
}

function pk(name: string): `0x${string}` {
  const v = envRequired(name);
  return (v.startsWith("0x") ? v : `0x${v}`) as `0x${string}`;
}

// ─── Deployed v0.17.2-beta.1 Sepolia addresses ─────────────────────────

// Prefer v0.18 (beta.2) addresses when present (AIRACCOUNT_V018_*), else fall back to beta.4.
// This points phases 08-12 at the current beta.2 deployment without per-phase edits.
const a18 = (v018: string, beta: string): Address =>
  (process.env[v018] ?? envRequired(beta)) as Address;
export const ADDR = {
  blsAlgorithm:        a18("AIRACCOUNT_V018_BLS_ALGORITHM",        "AIRACCOUNT_V0172_BETA_BLS_ALGORITHM"),
  validatorRouter:     a18("AIRACCOUNT_V018_VALIDATOR_ROUTER",     "AIRACCOUNT_V0172_BETA_VALIDATOR_ROUTER"),
  blsAggregator:       a18("AIRACCOUNT_V018_BLS_AGGREGATOR",       "AIRACCOUNT_V0172_BETA_BLS_AGGREGATOR"),
  sessionKeyValidator: a18("AIRACCOUNT_V018_SESSION_KEY_VALIDATOR", "AIRACCOUNT_V0172_BETA_SESSION_KEY_VALIDATOR"),
  forceExitModule:     a18("AIRACCOUNT_V018_FORCE_EXIT_MODULE",    "AIRACCOUNT_V0172_BETA_FORCE_EXIT_MODULE"),
  delegate:            a18("AIRACCOUNT_V018_DELEGATE",             "AIRACCOUNT_V0172_BETA_DELEGATE"),
  parserRegistry:      a18("AIRACCOUNT_V018_PARSER_REGISTRY",      "AIRACCOUNT_V0172_BETA_PARSER_REGISTRY"),
  factory:             a18("AIRACCOUNT_V018_FACTORY",             "AIRACCOUNT_V0172_BETA_FACTORY"),
  impl:                a18("AIRACCOUNT_V018_IMPL",                 "AIRACCOUNT_V0172_BETA_IMPL"),
  extension:           a18("AIRACCOUNT_V018_EXTENSION",            "AIRACCOUNT_V0172_BETA_EXTENSION"),
  agentRegistry:       a18("AIRACCOUNT_V018_AGENT_REGISTRY",       "AIRACCOUNT_V0172_BETA_AGENT_REGISTRY"),
  entryPoint:          envRequired("ENTRY_POINT_ADDRESS")                        as Address,
  communityGuardian:   envRequired("COMMUNITY_GUARDIAN_ADDRESS")                 as Address,
} as const;

// ─── Clients ───────────────────────────────────────────────────────────

const rpcUrl  = envRequired("SEPOLIA_RPC_URL");
const rpcUrl2 = process.env.SEPOLIA_RPC_URL2;
const rpcUrl3 = process.env.SEPOLIA_RPC_URL3;
const rpcs = [rpcUrl, rpcUrl2, rpcUrl3].filter(Boolean) as string[];

// Robust EIP-1559 fee policy for Sepolia. Default viem baseFeeMultiplier (1.2) under-provisions
// when Sepolia's baseFee is volatile → txs get dropped from the mempool as underpriced (observed
// 2026-06: createAccount txs silently dropped, cascading into nonce snarls). This replicates the
// PROVEN deploy-script formula (scripts/deploy-v0.18.ts `fees()`): maxFeePerGas = baseFee*2 + tip,
// with a 2 gwei priority floor so inclusion never stalls. base*2 covers ~6 blocks of baseFee growth.
const sepoliaRobust = {
  ...sepolia,
  fees: {
    baseFeeMultiplier: 2,
    maxPriorityFeePerGas: 2_000_000_000n, // 2 gwei floor (Sepolia tip)
  },
} as const;

export const publicClient: PublicClient = createPublicClient({
  chain: sepolia,
  transport: fallback(rpcs.map((u) => http(u, { timeout: 60_000 }))),
});

export const annie  = privateKeyToAccount(pk("PRIVATE_KEY_ANNI"));
export const jason  = privateKeyToAccount(pk("PRIVATE_KEY_JASON"));
export const bob    = privateKeyToAccount(pk("PRIVATE_KEY_BOB"));

export const wAnnie: WalletClient = createWalletClient({
  account: annie,
  chain: sepoliaRobust,
  transport: fallback(rpcs.map((u) => http(u, { timeout: 60_000 }))),
});
export const wJason: WalletClient = createWalletClient({
  account: jason,
  chain: sepoliaRobust,
  transport: fallback(rpcs.map((u) => http(u, { timeout: 60_000 }))),
});
export const wBob: WalletClient = createWalletClient({
  account: bob,
  chain: sepoliaRobust,
  transport: fallback(rpcs.map((u) => http(u, { timeout: 60_000 }))),
});

// ─── ABI loading ────────────────────────────────────────────────────────

export function loadAbi(contractName: string, fileName?: string): readonly unknown[] {
  const file = fileName ?? `${contractName}.sol`;
  const path = resolve(REPO_ROOT, "out", file, `${contractName}.json`);
  if (!existsSync(path)) {
    throw new Error(`ABI not found at ${path}. Run \`forge build\` first.`);
  }
  const artifact = JSON.parse(readFileSync(path, "utf8"));
  return artifact.abi as readonly unknown[];
}

// ─── Result recorder ────────────────────────────────────────────────────

export interface E2EResult {
  phase: string;
  test: string;
  status: "PASS" | "FAIL" | "SKIP";
  txHash?: Hash;
  gas?: bigint;
  notes?: string;
  evidence?: string;
}

const RESULT_FILE = resolve(REPO_ROOT, "docs", "e2e-results-v0.17.2-beta.3.md");

export function initResultFile(): void {
  if (existsSync(RESULT_FILE)) return;
  const header = `# E2E Test Results — v0.17.2-beta.3 (Sepolia)

**Deployment**: 2026-06-12 (see \`docs/DEPLOYMENT-v0.17.2-beta.3.md\` for addresses).
**Test infrastructure**: TypeScript + viem (\`scripts/e2e-v0172/\`).
**Coverage matrix**: \`docs/abi-coverage-v0.17.2-beta.3.md\`.

Each row below is a single E2E test run; results are appended chronologically.

| Timestamp | Phase | Test | Status | Tx hash | Gas | Notes |
|---|---|---|---|---|---|---|
`;
  writeFileSync(RESULT_FILE, header);
}

export function recordResult(r: E2EResult): void {
  initResultFile();
  const ts = new Date().toISOString();
  const tx = r.txHash ? `[\`${r.txHash.slice(0, 14)}…\`](https://sepolia.etherscan.io/tx/${r.txHash})` : "—";
  const gas = r.gas != null ? r.gas.toString() : "—";
  const notes = (r.notes ?? "").replace(/\|/g, "\\|");
  const row = `| ${ts} | ${r.phase} | ${r.test} | ${r.status} | ${tx} | ${gas} | ${notes} |\n`;
  appendFileSync(RESULT_FILE, row);
}

// ─── Test harness ───────────────────────────────────────────────────────

export interface TestCase {
  name: string;
  run: () => Promise<{ txHash?: Hash; gas?: bigint; notes?: string; evidence?: string }>;
}

export async function runTests(phase: string, tests: TestCase[]): Promise<void> {
  console.log(`\n${"=".repeat(72)}`);
  console.log(`  Phase ${phase} — running ${tests.length} test(s) against Sepolia`);
  console.log(`${"=".repeat(72)}\n`);

  let pass = 0, fail = 0;

  for (const t of tests) {
    process.stdout.write(`  ${t.name.padEnd(60)}`);
    try {
      const res = await t.run();
      console.log(`  PASS  gas=${res.gas ?? "—"}`);
      if (res.notes) console.log(`    ${res.notes}`);
      recordResult({ phase, test: t.name, status: "PASS", ...res });
      pass++;
    } catch (err: any) {
      console.log(`  FAIL`);
      console.log(`    ${err?.shortMessage ?? err?.message ?? String(err)}`);
      recordResult({
        phase,
        test: t.name,
        status: "FAIL",
        notes: err?.shortMessage ?? err?.message ?? String(err),
      });
      fail++;
    }
  }

  console.log(`\n  Phase ${phase} summary: ${pass} passed, ${fail} failed.\n`);
  if (fail > 0) process.exitCode = 1;
}

// ─── Etherscan helpers ──────────────────────────────────────────────────

export function etherscanTx(h: Hash): string {
  return `https://sepolia.etherscan.io/tx/${h}`;
}
export function etherscanAddr(a: Address): string {
  return `https://sepolia.etherscan.io/address/${a}`;
}

// ─── Negative-path / revert-selector helpers ───────────────────────────

import { keccak256, toBytes, slice, toHex } from "viem";

/**
 * Compute the 4-byte custom-error selector from its signature ("NotDeployer()").
 * Result is a 10-char "0x..." hex string suitable for prefix-matching error data.
 */
export function errSelector(signature: string): `0x${string}` {
  return slice(keccak256(toBytes(signature)), 0, 4);
}

/**
 * Look at a viem ContractFunctionRevertedError and extract the on-chain revert data.
 * Returns the hex-encoded data including the 4-byte selector (e.g. "0xabcdefgh...").
 */
export function getRevertData(err: any): string | undefined {
  // viem nests errors: BaseError → ContractFunctionExecutionError → ContractFunctionRevertedError
  const walk = (e: any, depth = 0): any => {
    if (!e || depth > 6) return undefined;
    if (typeof e.data === "string" && e.data.startsWith("0x")) return e.data;
    if (typeof e.raw === "string" && e.raw.startsWith("0x")) return e.raw;
    if (e.cause) return walk(e.cause, depth + 1);
    return undefined;
  };
  return walk(err);
}

/**
 * Assert that a simulateContract call rejected with the expected custom error.
 * Throws if the call succeeded OR if it rejected with a different selector.
 *
 * Usage:
 *   await expectRevert(
 *     () => publicClient.simulateContract({...}),
 *     "NotDeployer()",
 *   );
 */
export async function expectRevert(
  call: () => Promise<unknown>,
  errorSignature: string,
): Promise<{ selector: `0x${string}` }> {
  const expected = errSelector(errorSignature);
  try {
    await call();
  } catch (err: any) {
    const data = getRevertData(err);
    if (!data) {
      throw new Error(`expected revert with ${errorSignature} but got no revert data; raw: ${err?.shortMessage ?? err?.message}`);
    }
    const sel = data.slice(0, 10).toLowerCase();
    if (sel !== expected.toLowerCase()) {
      throw new Error(`expected ${errorSignature} (${expected}) but got selector ${sel} (data=${data.slice(0, 26)}…)`);
    }
    return { selector: expected };
  }
  throw new Error(`expected revert with ${errorSignature} but call succeeded`);
}

/**
 * Lower-level negative-path assertion using raw eth_call. More reliable than
 * `simulateContract` for nonpayable functions that revert with custom errors —
 * we observed viem occasionally swallowing reverts during simulate of nonpayable fns.
 *
 * Usage:
 *   await expectRawCallRevert({
 *     to: ADDR.sessionKeyValidator,
 *     data: encodeFunctionData({ abi, functionName, args }),
 *     from: bob.address,
 *   }, "NotAirAccount()");
 */
import { encodeFunctionData } from "viem";

export async function expectRawCallRevert(
  call: { to: Address; data: `0x${string}`; from: Address; value?: bigint },
  errorSignature: string,
): Promise<{ selector: `0x${string}` }> {
  const expected = errSelector(errorSignature);
  try {
    await publicClient.call({
      to: call.to,
      data: call.data,
      account: call.from,
      value: call.value,
    });
  } catch (err: any) {
    const data = getRevertData(err);
    if (!data) {
      // Some RPCs return revert reason in err.details or err.cause.data
      const raw = err?.cause?.data ?? err?.data ?? err?.details ?? "";
      const m = typeof raw === "string" ? raw.match(/0x[0-9a-f]{8,}/i) : null;
      if (m) {
        const sel = m[0].slice(0, 10).toLowerCase();
        if (sel === expected.toLowerCase()) return { selector: expected };
        throw new Error(`expected ${errorSignature} (${expected}) but got selector ${sel}`);
      }
      throw new Error(`expected revert with ${errorSignature} but no revert data; raw: ${err?.shortMessage ?? err?.message}`);
    }
    const sel = data.slice(0, 10).toLowerCase();
    if (sel !== expected.toLowerCase()) {
      throw new Error(`expected ${errorSignature} (${expected}) but got selector ${sel} (data=${data.slice(0, 26)}…)`);
    }
    return { selector: expected };
  }
  throw new Error(`expected revert with ${errorSignature} but call succeeded`);
}

export { encodeFunctionData };
