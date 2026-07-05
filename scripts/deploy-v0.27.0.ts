/**
 * deploy-v0.27.0.ts — Deploy for v0.27.0 (DVT validator unification, CC-10).
 *
 * Mounts the DVT authoritative BLS validator at algId 0x01, replacing airaccount's own
 * AAStarBLSAlgorithm (0xAF525A). Because the AAStarValidator router is set-once + finalized, a NEW
 * validator stack is required (same lesson as v0.24.0/v0.25.0). Deploys:
 *   - AAStarValidator (NEW router) → registerAlgorithm(0x01, DVT_VALIDATOR) +
 *     registerAlgorithm(0x08, reused SessionKeyValidator) + finalizeSetup
 *   - AAStarAirAccountV7 (new impl, new router baked in) → fresh AirAccountExtension
 *   - AAStarAirAccountFactoryV7 (new factory → new impl)
 *   - AgentRegistry (fresh — bindFactory is set-once)
 *
 * The DVT validator (0x539B…, YetAnotherAA-Validator PR #170/#171, Codex-approved) implements
 * `validate(bytes32,bytes) view returns(uint256)` (0=pass), same DST + sig layout as 0xAF525A.
 * DECISIONS (CC-10, dvt-confirmed): (1) dvt validator has NO aggregator() → v0.27.0 accounts use
 * inline single-op BLS (batch IAggregator aggregation is a future no-break upgrade). (2) validate()
 * reads only its own staked storage → ERC-7562 bundler-safe (same as 0xAF525A). If the bundler requires
 * the validator to be EntryPoint-staked, dvt will addStake on 0x539B.
 *
 * Reused from v0.26.0: SessionKeyValidator, ForceExitModule, Delegate, ParserRegistry.
 * NOT reused: 0xAF525A BLS algorithm + its aggregator (replaced by the DVT validator; retired for new
 * deployments — existing accounts keep 0xAF525A, non-upgradable).
 *
 * Output env keys: AIRACCOUNT_V0270_*
 * Usage: pnpm tsx scripts/deploy-v0.27.0.ts
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
const TARGET_VERSION = "0.27.0";
// DVT authoritative BLS validator (YetAnotherAA-Validator, Sepolia) — mounted at algId 0x01.
const DVT_VALIDATOR = "0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC" as Address;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3].filter(Boolean) as string[];

function v0260(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0260_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0260_${key} not set — run deploy-v0.26.0.ts first`);
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
  console.log(`\n=== v0.27.0 deploy — Sepolia (DVT validator unification) ===`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`DVT validator (algId 0x01): ${DVT_VALIDATOR}\n`);

  const sessionValidator = v0260("SESSION_KEY_VALIDATOR");
  const forceExitModule  = v0260("FORCE_EXIT_MODULE");
  const delegate         = v0260("DELEGATE");
  const parserRegistry   = v0260("PARSER_REGISTRY");
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

  console.log("\n=== v0.27.0 Deployment Complete ===\nAppend to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0270_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0270_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0270_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0270_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0270_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0270_DVT_VALIDATOR=${DVT_VALIDATOR}`);
  console.log(`AIRACCOUNT_V0270_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0270_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0270_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0270_PARSER_REGISTRY=${parserRegistry}`);
}
main().catch((err) => { console.error(err); process.exit(1); });
