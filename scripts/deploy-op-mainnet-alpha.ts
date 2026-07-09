/**
 * deploy-op-mainnet-alpha.ts — OP Mainnet Alpha deploy SKELETON (CC-30).
 *
 * ⚠️ SKELETON — do NOT run until every MUST-SET guard below is satisfied. See
 * docs/DEPLOYMENT-OP-MAINNET-ALPHA.md (preconditions P1–P6) + docs/PRODUCTION_READINESS.md.
 *
 * Architecture = v0.28.0 (same as v0.27.0 CC-10 unification): the DVT authoritative BLS validator
 * is mounted at algId 0x01 (there is NO local BLS contract in the deployed router). Fresh full stack:
 *   [1] SessionKeyValidator (algId 0x08)
 *   [2] AAStarValidator router → registerAlgorithm(0x01, DVT_VALIDATOR_MAINNET) +
 *       registerAlgorithm(0x08, sessionKeyValidator) + finalizeSetup
 *   [3] AAStarAirAccountV7 impl (router baked in) → fresh AirAccountExtension
 *   [4] AAStarAirAccountFactoryV7 (impl, EntryPoint, COMMUNITY guardian Safe)
 *   [5] AgentRegistry → bindFactory + factory.setAgentRegistry
 * Auxiliary modules (ForceExitModule / AirAccountDelegate / CalldataParserRegistry) are installed
 * per-account, not core-stack deps — deploy separately if the alpha needs them (see TODO block).
 *
 * KEY DIFFERENCES vs deploy-v0.27.0.ts (Sepolia):
 *   - chain = optimism (chainId 10); explorer = optimistic.etherscan.io
 *   - signing = `cast wallet` keystore (NO PRIVATE_KEY in any .env — P2)
 *   - RPC from .env.op-mainnet (OP_MAINNET_RPC_URL)
 *   - DVT validator + COMMUNITY guardian = OP-mainnet addresses (from @repo:dvt / OP Gnosis Safe)
 *
 * Foundry on macOS can't `forge create` (socket error) — this TS+viem path is the deploy method.
 *
 * Usage (keystore already exists — `cast wallet list` shows `optimism-deployer`):
 *   pnpm tsx scripts/deploy-op-mainnet-alpha.ts --account optimism-deployer
 * DVT mainnet validator + OP Safe come via CC-30/CC-31 coordination (subscribe by @-mentioning
 * @repo:dvt / @repo:sp — they @ you on release); do NOT hardcode or ask for them here.
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import { execSync } from "child_process";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { optimism } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.op-mainnet") });

// ── Canonical constants (OP Mainnet) ─────────────────────────────────────────
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address; // EntryPoint v0.7 (same on all chains)
const TARGET_VERSION = "0.28.0";
const PRIORITY_FEE_FLOOR = 1_000_000n; // OP gas is cheap; floor low

// ── MUST-SET from config (guarded in main) ───────────────────────────────────
// DVT authoritative BLS validator on OP MAINNET — from @repo:dvt (Sepolia was 0x539B…; mainnet TBD).
const DVT_VALIDATOR = process.env.DVT_VALIDATOR_MAINNET as Address;
// Protocol Gnosis Safe on OP Mainnet = community guardian / owner (CC-31 / #135).
const COMMUNITY = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? process.env.PROTOCOL_SAFE_ADDRESS) as Address;
const RPC_URLS = [process.env.OP_MAINNET_RPC_URL, process.env.OP_MAINNET_RPC_URL2].filter(Boolean) as string[];

// ── Signing via `cast wallet` keystore (NO PRIVATE_KEY env — P2) ─────────────
function keystoreAccountArg(): string {
  const i = process.argv.indexOf("--account");
  const acct = i >= 0 ? process.argv[i + 1] : process.argv.find(a => a.startsWith("--account="))?.split("=")[1];
  if (!acct) throw new Error("Usage: pnpm tsx scripts/deploy-op-mainnet-alpha.ts --account <keystore-name>");
  return acct;
}
function loadDeployerFromKeystore(): ReturnType<typeof privateKeyToAccount> {
  const acct = keystoreAccountArg();
  // cast prompts for the keystore password interactively (tty required).
  const pk = execSync(`cast wallet private-key --account ${acct}`, { stdio: ["inherit", "pipe", "inherit"] })
    .toString().trim() as Hex;
  return privateKeyToAccount(pk);
}
let deployer: ReturnType<typeof privateKeyToAccount>;

// ── ABIs (identical to deploy-v0.27.0.ts) ────────────────────────────────────
const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "finalizeSetup",     type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "getAlgorithm",      type: "function", stateMutability: "view",       inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const REGISTRY_ABI = [
  { name: "bindFactory", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
] as const;
const IMPL_ABI = [
  { name: "agentExtension",  type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "validatorRouter", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "ACCOUNT_VERSION", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: a.bytecode.object as Hex };
}
function pub(url: string) { return createPublicClient({ chain: optimism, transport: http(url, { timeout: 60_000 }) }); }
function wal(url: string) { return createWalletClient({ account: deployer, chain: optimism, transport: http(url, { timeout: 60_000 }) }); }

async function fees() {
  const block = await pub(RPC_URLS[0]).getBlock();
  const base = block.baseFeePerGas ?? 1_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try { tip = await pub(RPC_URLS[0]).estimateMaxPriorityFeePerGas(); } catch { /**/ }
  const priority = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}
async function waitReceipt(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://optimistic.etherscan.io/tx/${hash}`);
  for (let i = 0; i < 90; i++) {
    for (const url of RPC_URLS) {
      try {
        const r = await pub(url).getTransactionReceipt({ hash });
        if (r) { if (r.status !== "success") throw new Error(`${label} reverted`); console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`); return r; }
      } catch (e: any) { if (String(e.message).includes("reverted")) throw e; }
    }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`${label}: timeout — check ${hash}`);
}
async function deploy(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({ data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }), gas, ...f });
  return getAddress((await waitReceipt(hash, label)).contractAddress!);
}
async function call(label: string, to: Address, abi: unknown[], fn: string, args: unknown[], gas: bigint) {
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({ to, data: encodeFunctionData({ abi, functionName: fn, args } as any), gas, ...f });
  await waitReceipt(hash, label);
}

function guard(cond: unknown, msg: string) { if (!cond) throw new Error(`[MUST-SET] ${msg}`); }

async function main() {
  // ── Preconditions (P1–P6 in docs/DEPLOYMENT-OP-MAINNET-ALPHA.md) ───────────
  guard(RPC_URLS.length, "OP_MAINNET_RPC_URL not set in .env.op-mainnet (P6)");
  guard(DVT_VALIDATOR, "DVT_VALIDATOR_MAINNET not set — get the OP-mainnet validator from @repo:dvt (P4)");
  guard(COMMUNITY, "COMMUNITY_GUARDIAN_ADDRESS / PROTOCOL_SAFE_ADDRESS not set — OP-mainnet Gnosis Safe (P3)");
  deployer = loadDeployerFromKeystore();

  console.log(`\n=== v${TARGET_VERSION} deploy — OP MAINNET ALPHA (chainId 10) ===`);
  console.log(`Deployer: ${deployer.address}  (cast wallet keystore)`);
  console.log(`DVT validator (algId 0x01): ${DVT_VALIDATOR}`);
  console.log(`Community guardian / owner Safe: ${COMMUNITY}\n`);

  const reader = pub(RPC_URLS[0]);
  const bal = await reader.getBalance({ address: deployer.address });
  guard(bal > 5_000_000_000_000_000n, `deployer balance ${bal} wei < 0.005 ETH — fund it (P2)`);

  // DVT validator must be live on OP mainnet before mounting.
  const dvtCode = await reader.getBytecode({ address: DVT_VALIDATOR });
  guard(dvtCode && dvtCode.length > 2, `DVT validator ${DVT_VALIDATOR} has no code on OP mainnet`);
  console.log(`DVT validator code: ${(dvtCode!.length / 2 - 1)} bytes ✓`);

  // [1] SessionKeyValidator (algId 0x08)
  console.log("\n[1/5] SessionKeyValidator...");
  const sessionKeyValidator = await deploy("sessionKeyValidator", "SessionKeyValidator", [], 4_000_000n);
  console.log(`  SessionKeyValidator: ${sessionKeyValidator}`);

  // [2] router → 0x01=DVT, 0x08=session, finalize
  console.log("\n[2/5] AAStarValidator router...");
  const router = await deploy("router", "AAStarValidator", [], 2_000_000n);
  await call("register-0x01-DVT", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x01, DVT_VALIDATOR], 150_000n);
  await call("register-0x08-session", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x08, sessionKeyValidator], 150_000n);
  await call("finalizeSetup", router, ROUTER_ABI as unknown[], "finalizeSetup", [], 100_000n);
  const r01 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
  guard(r01.toLowerCase() === DVT_VALIDATOR.toLowerCase(), `router 0x01 mismatch: ${r01}`);
  console.log(`  Router: ${router}  (0x01=DVT ✓)`);

  // [3] impl (+ fresh extension)
  console.log("\n[3/5] AAStarAirAccountV7 impl...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [router], 15_000_000n);
  const extension = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "agentExtension" }) as Address;
  console.log(`  Impl: ${impl}\n  Extension: ${extension}`);

  // [4] factory
  console.log("\n[4/5] AAStarAirAccountFactoryV7...");
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // [5] AgentRegistry + wiring
  console.log("\n[5/5] AgentRegistry...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 2_000_000n);
  await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);
  await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);

  const ver = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" });
  guard(ver === TARGET_VERSION, `Version mismatch: expected "${TARGET_VERSION}", got "${ver}"`);
  console.log(`\n[Verify] ACCOUNT_VERSION = "${ver}" ✓`);

  // TODO(post-alpha, non-core): deploy auxiliary modules if the alpha exercises them:
  //   ForceExitModule / AirAccountDelegate / CalldataParserRegistry (confirm ctor args first).
  //   And mint the CC-22 mainnet e2e_account via scripts/cc22-ownerauth-e2e-account.ts (TARGET_CHAIN=mainnet).

  console.log("\n=== OP Mainnet Alpha deploy complete ===\nAppend to .env.op-mainnet:\n");
  console.log(`AIRACCOUNT_OPMAINNET_IMPL=${impl}`);
  console.log(`AIRACCOUNT_OPMAINNET_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_OPMAINNET_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_OPMAINNET_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_OPMAINNET_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_OPMAINNET_DVT_VALIDATOR=${DVT_VALIDATOR}`);
  console.log(`AIRACCOUNT_OPMAINNET_SESSION_KEY_VALIDATOR=${sessionKeyValidator}`);
  console.log("\nNext: verify (scripts/verify-sepolia.sh adapted --chain 10), then notify @repo:sdk / @repo:yaaa (CC-30) + fill SDK CANONICAL_ADDRESSES[10].");
}
main().catch((err) => { console.error(err); process.exit(1); });
