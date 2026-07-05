/**
 * deploy-v0.26.0.ts — Deploy for v0.26.0 (HIGH-1: ERC-7579 nonce-key module route tier binding).
 *
 * What changed vs v0.25.0: ONLY AAStarAirAccountV7 + AAStarAirAccountBase — the nonce-key validator-
 * module route now caps to Tier-1 (rejects session 0x08, weighted 0x07, and any algId with tier > 1),
 * plus a stale-weight defense-in-depth guard in _populateExecAlg. No validator-stack change.
 *
 * REUSES the entire v0.25.0 validator stack (router + SessionKeyValidator + BLS + aggregator +
 * ForceExit + Delegate + ParserRegistry). Deploys ONLY:
 *   - AAStarAirAccountV7 (new impl, same v0.25.0 router baked in) — brings a fresh AirAccountExtension
 *   - AAStarAirAccountFactoryV7 (new factory → new impl)
 *   - AgentRegistry (fresh — bindFactory is set-once, the v0.25.0 registry is bound to the old factory)
 *
 * Wiring: agentRegistry.bindFactory(factory); factory.setAgentRegistry(agentRegistry).
 *
 * Non-breaking: only rejects an exploit path that should never have been reachable. Existing accounts
 * (old impl) are unaffected — non-upgradable, only new accounts get the fix.
 *
 * Output env keys: AIRACCOUNT_V0260_*
 * Usage: pnpm tsx scripts/deploy-v0.26.0.ts
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
const TARGET_VERSION = "0.26.0";

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

function v0250(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0250_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0250_${key} not set in .env.sepolia — run deploy-v0.25.0.ts first`);
  return getAddress(v);
}

const deployer = privateKeyToAccount(PRIVATE_KEY);

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
  const base  = block.baseFeePerGas ?? 10_000_000_000n;
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
        if (r) {
          if (r.status !== "success") throw new Error(`${label} reverted`);
          console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
          return r;
        }
      } catch (e: any) { if (String(e.message).includes("reverted")) throw e; }
    }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`${label}: timeout — check ${hash}`);
}

async function deploy(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f   = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }), gas, ...f,
  });
  const r = await waitReceipt(hash, label);
  return getAddress(r.contractAddress!);
}

async function call(label: string, to: Address, abi: unknown[], fn: string, args: unknown[], gas: bigint) {
  const f    = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    to, data: encodeFunctionData({ abi, functionName: fn, args } as any), gas, ...f,
  });
  await waitReceipt(hash, label);
}

async function main() {
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY or PRIVATE_KEY_ANNI not set");
  if (!COMMUNITY)   throw new Error("COMMUNITY_GUARDIAN_ADDRESS not set");
  console.log(`\n=== v0.26.0 deploy — Sepolia (HIGH-1 module-route tier binding) ===`);
  console.log(`Deployer: ${deployer.address}\n`);

  // Reused v0.25.0 validator stack (unchanged bytecode).
  const router          = v0250("VALIDATOR_ROUTER");
  const sessionValidator = v0250("SESSION_KEY_VALIDATOR");
  const blsAlgorithm    = v0250("BLS_ALGORITHM");
  const blsAggregator   = v0250("BLS_AGGREGATOR");
  const forceExitModule = v0250("FORCE_EXIT_MODULE");
  const delegate        = v0250("DELEGATE");
  const parserRegistry  = v0250("PARSER_REGISTRY");
  console.log("Reusing v0.25.0 validator stack:");
  console.log(`  Router:              ${router}`);
  console.log(`  SessionKeyValidator: ${sessionValidator}`);
  console.log(`  BLS Algorithm:       ${blsAlgorithm}\n`);

  const reader = pub(RPC_URLS[0]);

  // [1] new impl (same v0.25.0 router baked in) → fresh Extension.
  console.log("[1/3] AAStarAirAccountV7 (impl, validatorRouter = reused v0.25.0 router)...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [router], 15_000_000n);
  const extension = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "agentExtension" }) as Address;
  const wiredRouter = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "validatorRouter" }) as Address;
  console.log(`  Impl:            ${impl}`);
  console.log(`  Extension:       ${extension}`);
  console.log(`  validatorRouter: ${wiredRouter}`);
  if (wiredRouter.toLowerCase() !== router.toLowerCase()) throw new Error(`validatorRouter mismatch on impl: ${wiredRouter}`);

  // [2] new factory → new impl.
  console.log("\n[2/3] AAStarAirAccountFactoryV7 (→ new impl)...");
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // [3] fresh AgentRegistry (bindFactory is set-once → the v0.25.0 registry is bound to the old factory).
  console.log("\n[3/3] AgentRegistry (fresh)...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 2_000_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);

  // Wiring.
  console.log("\n[Wire 1/2] agentRegistry.bindFactory(factory)...");
  const bound = await reader.readContract({ address: agentRegistry, abi: REGISTRY_ABI, functionName: "factory" }) as Address;
  if (bound.toLowerCase() === factory.toLowerCase()) console.log("  [skip] already bound");
  else await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);

  console.log("[Wire 2/2] factory.setAgentRegistry(agentRegistry)...");
  const setReg = await reader.readContract({ address: factory, abi: FACTORY_WIRE_ABI, functionName: "agentRegistry" }) as Address;
  if (setReg.toLowerCase() === agentRegistry.toLowerCase()) console.log("  [skip] already set");
  else await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  // On-chain version verification.
  console.log("\n[Verify] ACCOUNT_VERSION on-chain...");
  const ver = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" });
  console.log(`  ACCOUNT_VERSION = "${ver}"`);
  if (ver !== TARGET_VERSION) throw new Error(`Version mismatch: expected "${TARGET_VERSION}", got "${ver}"`);
  console.log(`  v${TARGET_VERSION} confirmed\n`);

  console.log("=== v0.26.0 Deployment Complete ===");
  console.log("Append to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0260_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0260_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0260_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0260_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0260_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0260_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0260_BLS_ALGORITHM=${blsAlgorithm}`);
  console.log(`AIRACCOUNT_V0260_BLS_AGGREGATOR=${blsAggregator}`);
  console.log(`AIRACCOUNT_V0260_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0260_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0260_PARSER_REGISTRY=${parserRegistry}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
