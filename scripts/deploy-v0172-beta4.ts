/**
 * deploy-v0172-beta4.ts — Incremental deploy for v0.17.2-beta.4 (bundler-compat algId fix)
 *
 * Only the contracts changed by the beta.4 fix are redeployed:
 *   1. AAStarAirAccountFactoryV7   — auto-deploys new AAStarAirAccountV7 impl + AirAccountExtension
 *                                    (account: executeUserOp + account-owned whitelist + validation gate;
 *                                     guard: pure accounting recordSpend/recordTokenSpend)
 *   2. AirAccountDelegate          — EIP-7702 path aligned (ECDSA-only, recordSpend/recordTokenSpend)
 *   3. AgentRegistry               — MANDATORY re-deploy (bindFactory is set-once per factory)
 *
 * REUSED unchanged (addresses from .env.sepolia, not redeployed):
 *   AAStarValidator (router), SessionKeyValidator, ForceExitModule, AAStarBLSAlgorithm,
 *   AAStarBLSAggregator, CalldataParserRegistry.
 *
 * Wiring:
 *   agentRegistry.bindFactory(factory)        — MANDATORY
 *   factory.setAgentRegistry(agentRegistry)   — MANDATORY
 *
 * Usage: pnpm tsx scripts/deploy-v0172-beta4.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, formatEther,
  type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: a.bytecode.object as Hex };
}
function makeClients(rpcUrl: string, account: ReturnType<typeof privateKeyToAccount>) {
  const transport = http(rpcUrl, { timeout: 300_000 });
  return { pub: createPublicClient({ chain: sepolia, transport }), wal: createWalletClient({ account, chain: sepolia, transport }) };
}
async function waitTx(pub: ReturnType<typeof createPublicClient>, hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 600_000 });
  if (r.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
  return r;
}
async function withRetry<T>(label: string, fn: (rpcUrl: string) => Promise<T>): Promise<T> {
  for (const rpcUrl of RPC_URLS) {
    try { console.log(`  [${label}] RPC: ${rpcUrl.slice(0, 55)}...`); return await fn(rpcUrl); }
    catch (err: any) { console.warn(`  [${label}] failed: ${err.message?.slice(0, 120)}`); }
  }
  throw new Error(`All RPCs failed for: ${label}`);
}

async function main() {
  if (!PRIVATE_KEY) { console.error("ERROR: PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set"); process.exit(1); }
  if (!COMMUNITY)   { console.error("ERROR: COMMUNITY_GUARDIAN_ADDRESS not set"); process.exit(1); }

  const deployer = privateKeyToAccount(PRIVATE_KEY);
  console.log("=== Deploy AirAccount v0.17.2-beta.4 (bundler-compat algId fix) ===");
  console.log(`Deployer:   ${deployer.address}`);
  console.log(`Community:  ${COMMUNITY}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const { pub: pub0 } = makeClients(RPC_URLS[0], deployer);
  const bal = await pub0.getBalance({ address: deployer.address });
  console.log(`Balance:    ${formatEther(bal)} ETH`);
  if (bal < 30_000_000_000_000_000n) { console.error("ERROR: balance below 0.03 ETH"); process.exit(1); }
  console.log("");

  // ── 1. Factory (auto-deploys Impl + Extension) ──────────────────────────────
  console.log("[1/3] Deploy Factory + Impl + Extension (beta.4)...");
  const { factoryAddr, implAddr, extensionAddr } = await withRetry("Factory", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const fA = loadArtifact("AAStarAirAccountFactoryV7");
    const hash = await wal.sendTransaction({
      gas: 10_000_000n,
      data: encodeDeployData({ abi: fA.abi, bytecode: fA.bytecode, args: [ENTRYPOINT, COMMUNITY, [], []] }),
    });
    const r = await waitTx(pub, hash, "Factory");
    const factory = r.contractAddress!;
    const impl = await pub.readContract({ address: factory, abi: fA.abi, functionName: "implementation" }) as Address;
    const ext = await pub.readContract({
      address: impl,
      abi: [{ name: "agentExtension", type: "function", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" }],
      functionName: "agentExtension",
    }).catch(() => "0x0000000000000000000000000000000000000000") as Address;
    return { factoryAddr: factory, implAddr: impl, extensionAddr: ext };
  });
  console.log(`  Factory:   ${factoryAddr}`);
  console.log(`  Impl:      ${implAddr}`);
  console.log(`  Extension: ${extensionAddr}\n`);

  // ── 2. AirAccountDelegate (EIP-7702, changed in beta.4) ─────────────────────
  console.log("[2/3] Deploy AirAccountDelegate (beta.4)...");
  const delegateAddr = await withRetry("AirAccountDelegate", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("AirAccountDelegate");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }), gas: 3_000_000n,
    });
    const r = await waitTx(pub, hash, "AirAccountDelegate");
    return r.contractAddress!;
  });
  console.log(`  AirAccountDelegate: ${delegateAddr}\n`);

  // ── 3. AgentRegistry (MANDATORY per-factory) ────────────────────────────────
  console.log("[3/3] Deploy AgentRegistry (bindFactory is set-once)...");
  const agentRegistryAddr = await withRetry("AgentRegistry", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("AgentRegistry");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }), gas: 1_500_000n,
    });
    const r = await waitTx(pub, hash, "AgentRegistry");
    return r.contractAddress!;
  });
  console.log(`  AgentRegistry: ${agentRegistryAddr}\n`);

  // ── Wiring ──────────────────────────────────────────────────────────────────
  const { pub, wal } = makeClients(RPC_URLS[0], deployer);
  const registryAbi = [{ name: "bindFactory", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" }];
  const factoryAbi  = [{ name: "setAgentRegistry", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" }];

  console.log("[Wire 1/2] agentRegistry.bindFactory(factory)...");
  await waitTx(pub, await wal.writeContract({ address: agentRegistryAddr, abi: registryAbi, functionName: "bindFactory", args: [factoryAddr] }), "bindFactory");

  console.log("[Wire 2/2] factory.setAgentRegistry(agentRegistry)...");
  await waitTx(pub, await wal.writeContract({ address: factoryAddr, abi: factoryAbi, functionName: "setAgentRegistry", args: [agentRegistryAddr] }), "setAgentRegistry");

  console.log("\n=== beta.4 Deployment Summary — update .env.sepolia ===");
  console.log(`AIRACCOUNT_V0172_BETA_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_EXTENSION=${extensionAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_DELEGATE=${delegateAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_AGENT_REGISTRY=${agentRegistryAddr}`);
  console.log("\nREUSED (unchanged): VALIDATOR_ROUTER, SESSION_KEY_VALIDATOR, FORCE_EXIT_MODULE, BLS_ALGORITHM, BLS_AGGREGATOR, PARSER_REGISTRY");
}

main().catch((err) => { console.error(err); process.exit(1); });
