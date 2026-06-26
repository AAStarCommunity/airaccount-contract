/**
 * deploy-v0.20.1.ts — Patch deploy for v0.20.1 (tierLimitNonce getter, issue #131).
 *
 * Only AirAccountExtension changed (added tierLimitNonce() view getter). Since Extension
 * is deployed inside the impl constructor, we need a new impl + factory + agentRegistry.
 * All other singletons are reused from v0.20.
 *
 * Reused from v0.20 (unchanged bytecode):
 *   AAStarBLSAlgorithm, AAStarValidator, AAStarBLSAggregator, SessionKeyValidator,
 *   ForceExitModule, AirAccountDelegate, CalldataParserRegistry
 *
 * Redeployed (bytecode changed or set-once binding):
 *   AAStarAirAccountV7 (impl)   — Extension embedded in ctor; new Extension auto-deploys
 *   AAStarAirAccountFactoryV7   — must point to new impl
 *   AgentRegistry               — bindFactory is set-once; needs fresh instance for new factory
 *
 * Wiring (post-deploy):
 *   W1. agentRegistry.bindFactory(factory)
 *   W2. factory.setAgentRegistry(agentRegistry)
 *
 * Output env keys: AIRACCOUNT_V0201_*
 *
 * Usage: pnpm tsx scripts/deploy-v0.20.1.ts
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

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

// ── Reused v0.20 singletons (must be set in .env.sepolia) ──────────────────
function v020(key: string): Address {
  const v = process.env[`AIRACCOUNT_V020_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V020_${key} not set in .env.sepolia — run deploy-v0.20.ts first`);
  return getAddress(v);
}

const deployer = privateKeyToAccount(PRIVATE_KEY);

const REGISTRY_ABI = [
  { name: "bindFactory",  type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "factory",      type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "agentRegistry",    type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const IMPL_EXT_ABI = [
  { name: "agentExtension", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
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
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }),
    gas, ...f,
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
  console.log(`\n=== v0.20.1 patch deploy — Sepolia ===`);
  console.log(`Deployer: ${deployer.address}\n`);

  // ── Reused v0.20 singletons ──────────────────────────────────────────
  const blsAlgorithm       = v020("BLS_ALGORITHM");
  const validatorRouter    = v020("VALIDATOR_ROUTER");
  const blsAggregator      = v020("BLS_AGGREGATOR");
  const sessionKeyValidator = v020("SESSION_KEY_VALIDATOR");
  const forceExitModule    = v020("FORCE_EXIT_MODULE");
  const delegate           = v020("DELEGATE");
  const parserRegistry     = v020("PARSER_REGISTRY");
  console.log("Reusing v0.20 singletons:");
  console.log(`  BLS Algorithm:        ${blsAlgorithm}`);
  console.log(`  Validator Router:     ${validatorRouter}`);
  console.log(`  BLS Aggregator:       ${blsAggregator}`);
  console.log(`  SessionKeyValidator:  ${sessionKeyValidator}`);
  console.log(`  ForceExitModule:      ${forceExitModule}`);
  console.log(`  Delegate:             ${delegate}`);
  console.log(`  ParserRegistry:       ${parserRegistry}\n`);

  // ── Deploy: impl (embeds new Extension with tierLimitNonce()) ─────────
  console.log("[1/3] AAStarAirAccountV7 (impl + AirAccountExtension v0.20.1)...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [], 10_000_000n);
  const extension = await pub(RPC_URLS[0]).readContract({
    address: impl, abi: IMPL_EXT_ABI, functionName: "agentExtension",
  }) as Address;
  console.log(`  Impl:      ${impl}`);
  console.log(`  Extension: ${extension}`);

  // ── Deploy: factory ───────────────────────────────────────────────────
  console.log("[2/3] AAStarAirAccountFactoryV7 (pointing to new impl)...");
  // Pass empty token arrays — same as v0.20 deploy; presets are set post-deploy via setDefaultTokenConfig.
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7",
    [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // ── Deploy: agentRegistry (fresh instance for new factory) ───────────
  console.log("[3/3] AgentRegistry (fresh — bindFactory is set-once)...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 1_500_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);

  // ── Wiring ────────────────────────────────────────────────────────────
  const reader = pub(RPC_URLS[0]);

  console.log("\n[Wire 1/2] agentRegistry.bindFactory(factory)...");
  const bound = await reader.readContract({ address: agentRegistry, abi: REGISTRY_ABI, functionName: "factory" }) as Address;
  if (bound.toLowerCase() === factory.toLowerCase()) console.log("  [skip] already bound");
  else await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);

  console.log("[Wire 2/2] factory.setAgentRegistry(agentRegistry)...");
  const setReg = await reader.readContract({ address: factory, abi: FACTORY_WIRE_ABI, functionName: "agentRegistry" }) as Address;
  if (setReg.toLowerCase() === agentRegistry.toLowerCase()) console.log("  [skip] already set");
  else await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  // ── Summary ───────────────────────────────────────────────────────────
  console.log("\n=== v0.20.1 Deployment Complete ===");
  console.log("Append to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0201_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0201_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0201_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0201_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0201_BLS_ALGORITHM=${blsAlgorithm}`);
  console.log(`AIRACCOUNT_V0201_BLS_AGGREGATOR=${blsAggregator}`);
  console.log(`AIRACCOUNT_V0201_VALIDATOR_ROUTER=${validatorRouter}`);
  console.log(`AIRACCOUNT_V0201_SESSION_KEY_VALIDATOR=${sessionKeyValidator}`);
  console.log(`AIRACCOUNT_V0201_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0201_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0201_PARSER_REGISTRY=${parserRegistry}`);
  console.log("\nVerify on-chain:");
  console.log(`  ACCOUNT_VERSION:  cast call ${impl} "ACCOUNT_VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL`);
  console.log(`  FACTORY_VERSION:  cast call ${factory} "FACTORY_VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL`);
  console.log(`  tierLimitNonce:   cast call <account> "tierLimitNonce()(uint256)" --rpc-url $SEPOLIA_RPC_URL`);
}

main().catch((err) => { console.error(err); process.exit(1); });
