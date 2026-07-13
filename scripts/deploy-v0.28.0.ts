/**
 * deploy-v0.28.0.ts — Deploy for v0.28.0 (CC-27 BLS registry rename + version bump).
 *
 * v0.28.0 vs v0.27.0 is a PURE SOURCE-LEVEL release: (1) CC-27 rename
 * AAStarBLSAlgorithm → AAStarBLSKeyRegistry (that registry is airaccount's own retired 0xAF525A
 * path — NOT deployed in this stack, which mounts the DVT validator 0x539B at algId 0x01), and
 * (2) ACCOUNT_VERSION/FACTORY_VERSION 0.27.0 → 0.28.0. No behavior change. Because the account
 * stack is non-upgradable + the AAStarValidator router is set-once + finalized, a NEW stack is
 * required to make the 0.28.0 version constant take effect. Deploys (identical shape to v0.27.0):
 *   - AAStarValidator (NEW router) → 0x01 = DVT validator, 0x08 = reused SessionKeyValidator, finalize
 *   - AAStarAirAccountV7 (new impl, new router baked in) → fresh AirAccountExtension
 *   - AAStarAirAccountFactoryV7 (new factory → new impl)
 *   - AgentRegistry (fresh — bindFactory is set-once)
 *
 * Reused from v0.27.0: SessionKeyValidator, ForceExitModule, Delegate, ParserRegistry, DVT validator.
 * Parsers stay disabled at the account level (KI-14; ParserRegistry reused but no default parser).
 *
 * Output env keys: AIRACCOUNT_V0280_*
 * Usage: pnpm tsx scripts/deploy-v0.28.0.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const TARGET_VERSION = "0.28.0";
// DVT authoritative BLS validator (YetAnotherAA-Validator, Sepolia) — mounted at algId 0x01.
const DVT_VALIDATOR = "0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC" as Address;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3].filter(Boolean) as string[];

function v0270(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0270_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0270_${key} not set — run deploy-v0.27.0.ts first`);
  return getAddress(v);
}
const deployer = privateKeyToAccount(PRIVATE_KEY);

const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "finalizeSetup",     type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "getAlgorithm",      type: "function", stateMutability: "view",       inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const REGISTRY_ABI = [
  { name: "bindFactory", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "factory",     type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "agentRegistry",    type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
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
function pub(url: string) { return createPublicClient({ chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }
function wal(url: string) { return createWalletClient({ account: deployer, chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }

async function fees() {
  const block = await pub(RPC_URLS[0]).getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try { tip = await pub(RPC_URLS[0]).estimateMaxPriorityFeePerGas(); } catch { /**/ }
  const priority = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}
async function waitReceipt(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
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

async function main() {
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");
  if (!COMMUNITY) throw new Error("COMMUNITY_GUARDIAN_ADDRESS not set");
  console.log(`\n=== v0.28.0 deploy — Sepolia (CC-27 rename + version bump) ===`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`DVT validator (algId 0x01): ${DVT_VALIDATOR}\n`);

  const sessionValidator = v0270("SESSION_KEY_VALIDATOR");
  const forceExitModule  = v0270("FORCE_EXIT_MODULE");
  const delegate         = v0270("DELEGATE");
  const parserRegistry   = v0270("PARSER_REGISTRY");
  const reader = pub(RPC_URLS[0]);

  // Sanity: DVT validator is deployed + exposes validate().
  const dvtCode = await reader.getBytecode({ address: DVT_VALIDATOR });
  if (!dvtCode || dvtCode.length <= 2) throw new Error(`DVT validator ${DVT_VALIDATOR} has no code`);
  console.log(`DVT validator code: ${dvtCode.length / 2 - 1} bytes ✓`);

  // [1] new router → 0x01 = DVT validator, 0x08 = reused session validator, finalize
  console.log("\n[1/4] AAStarValidator router (0x01→DVT, 0x08→session)...");
  const router = await deploy("router", "AAStarValidator", [], 2_000_000n);
  console.log(`  Router: ${router}`);
  await call("register-0x01-DVT", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x01, DVT_VALIDATOR], 150_000n);
  await call("register-0x08-session", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x08, sessionValidator], 150_000n);
  await call("finalizeSetup", router, ROUTER_ABI as unknown[], "finalizeSetup", [], 100_000n);
  const r01 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
  const r08 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x08] }) as Address;
  if (r01.toLowerCase() !== DVT_VALIDATOR.toLowerCase()) throw new Error(`router 0x01 mismatch: ${r01}`);
  if (r08.toLowerCase() !== sessionValidator.toLowerCase()) throw new Error(`router 0x08 mismatch: ${r08}`);
  console.log(`  router 0x01=${r01} (DVT) 0x08=${r08} (session) ✓`);

  // [2] new impl
  console.log("\n[2/4] AAStarAirAccountV7 (impl, new router)...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [router], 15_000_000n);
  const extension = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "agentExtension" }) as Address;
  const wiredRouter = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "validatorRouter" }) as Address;
  console.log(`  Impl: ${impl}\n  Extension: ${extension}\n  validatorRouter: ${wiredRouter}`);
  if (wiredRouter.toLowerCase() !== router.toLowerCase()) throw new Error(`validatorRouter mismatch: ${wiredRouter}`);

  // [3] new factory
  console.log("\n[3/4] AAStarAirAccountFactoryV7...");
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // [4] fresh AgentRegistry + wiring
  console.log("\n[4/4] AgentRegistry (fresh)...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 2_000_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);
  console.log("[Wire] bindFactory + setAgentRegistry...");
  await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);
  await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  const ver = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" });
  if (ver !== TARGET_VERSION) throw new Error(`Version mismatch: expected "${TARGET_VERSION}", got "${ver}"`);
  console.log(`\n[Verify] ACCOUNT_VERSION = "${ver}" ✓`);

  console.log("\n=== v0.28.0 Deployment Complete ===\nAppend to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0280_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0280_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0280_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0280_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0280_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0280_DVT_VALIDATOR=${DVT_VALIDATOR}`);
  console.log(`AIRACCOUNT_V0280_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0280_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0280_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0280_PARSER_REGISTRY=${parserRegistry}`);
}
main().catch((err) => { console.error(err); process.exit(1); });
