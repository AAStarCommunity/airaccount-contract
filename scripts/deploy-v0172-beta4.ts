/**
 * deploy-v0172-beta4.ts — Incremental deploy for v0.17.2-beta.4 (bundler-compat algId fix)
 *
 * Only the contracts changed by the beta.4 fix are redeployed:
 *   1. AAStarAirAccountFactoryV7   — auto-deploys new AAStarAirAccountV7 impl + AirAccountExtension
 *   2. AirAccountDelegate          — EIP-7702 path aligned (ECDSA-only, recordSpend/recordTokenSpend)
 *   3. AgentRegistry               — MANDATORY re-deploy (bindFactory is set-once per factory)
 *
 * REUSED unchanged (from .env.sepolia): AAStarValidator (router), SessionKeyValidator,
 * ForceExitModule, AAStarBLSAlgorithm, AAStarBLSAggregator, CalldataParserRegistry.
 *
 * Wiring: agentRegistry.bindFactory(factory); factory.setAgentRegistry(agentRegistry).
 *
 * v0.17.2-beta.4 deploy-robustness fix: each tx is SENT ONCE (never re-sent on a receipt-wait
 * timeout — re-sending caused nonce conflicts / stuck duplicates), then its receipt is polled
 * across all RPCs. An explicit priority fee (2 gwei) is set so txns are not parked with a near-zero
 * tip (the prior failure mode).
 *
 * Usage: pnpm tsx scripts/deploy-v0172-beta4.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  formatEther, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// Priority fee (tip). Adaptive: use max(network-suggested, floor); env-overridable. A fixed tip
// can be too low under congestion (txn parked) or wastefully high when the network is quiet.
const PRIORITY_FEE_FLOOR = 1_500_000_000n; // 1.5 gwei floor — enough to be picked up on Sepolia
const PRIORITY_FEE_OVERRIDE = process.env.DEPLOY_PRIORITY_FEE_GWEI
  ? BigInt(Math.round(Number(process.env.DEPLOY_PRIORITY_FEE_GWEI) * 1e9))
  : 0n;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

const deployer = privateKeyToAccount(PRIVATE_KEY);

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: a.bytecode.object as Hex };
}
function pub(rpcUrl: string) { return createPublicClient({ chain: sepolia, transport: http(rpcUrl, { timeout: 60_000 }) }); }
function wal(rpcUrl: string) { return createWalletClient({ account: deployer, chain: sepolia, transport: http(rpcUrl, { timeout: 60_000 }) }); }

function maxBig(a: bigint, b: bigint): bigint { return a > b ? a : b; }

async function fees(): Promise<{ maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }> {
  const client = pub(RPC_URLS[0]);
  const block = await client.getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
  // Network-suggested tip (eth_maxPriorityFeePerGas), with a floor; env override wins if set.
  let suggested = PRIORITY_FEE_FLOOR;
  try { suggested = await client.estimateMaxPriorityFeePerGas(); } catch { /* fall back to floor */ }
  const priority = PRIORITY_FEE_OVERRIDE > 0n ? PRIORITY_FEE_OVERRIDE : maxBig(suggested, PRIORITY_FEE_FLOOR);
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}

/** Poll the receipt across ALL RPCs without ever re-sending the tx. */
async function waitReceiptAnyRpc(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  for (let attempt = 0; attempt < 90; attempt++) { // ~7.5 min
    for (const rpcUrl of RPC_URLS) {
      try {
        const r = await pub(rpcUrl).getTransactionReceipt({ hash });
        if (r) {
          if (r.status !== "success") throw new Error(`${label} reverted (status=${r.status})`);
          console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
          return r;
        }
      } catch (e: any) {
        if (String(e.message ?? "").includes("reverted")) throw e;
        // else: not mined yet on this RPC — keep polling
      }
    }
    await new Promise((res) => setTimeout(res, 5000));
  }
  throw new Error(`${label}: receipt not found after polling — check ${hash}`);
}

async function deployOnce(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }),
    gas, ...f,
  });
  const r = await waitReceiptAnyRpc(hash, label);
  return r.contractAddress!;
}

async function callOnce(label: string, to: Address, abi: unknown[], functionName: string, args: unknown[], gas: bigint) {
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    to, data: encodeFunctionData({ abi, functionName, args } as any), gas, ...f,
  });
  await waitReceiptAnyRpc(hash, label);
}

async function main() {
  if (!PRIVATE_KEY) { console.error("ERROR: PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set"); process.exit(1); }
  if (!COMMUNITY)   { console.error("ERROR: COMMUNITY_GUARDIAN_ADDRESS not set"); process.exit(1); }

  console.log("=== Deploy AirAccount v0.17.2-beta.4 (bundler-compat algId fix) ===");
  console.log(`Deployer:   ${deployer.address}`);
  console.log(`Community:  ${COMMUNITY}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const bal = await pub(RPC_URLS[0]).getBalance({ address: deployer.address });
  console.log(`Balance:    ${formatEther(bal)} ETH`);
  if (bal < 30_000_000_000_000_000n) { console.error("ERROR: balance below 0.03 ETH"); process.exit(1); }
  console.log("");

  // ── 1. Factory (auto-deploys Impl + Extension) ──────────────────────────────
  console.log("[1/3] Deploy Factory + Impl + Extension (beta.4)...");
  const factoryAddr = await deployOnce("Factory", "AAStarAirAccountFactoryV7", [ENTRYPOINT, COMMUNITY, [], []], 10_000_000n);
  const fAbi = loadArtifact("AAStarAirAccountFactoryV7").abi;
  const implAddr = await pub(RPC_URLS[0]).readContract({ address: factoryAddr, abi: fAbi, functionName: "implementation" }) as Address;
  const extensionAddr = await pub(RPC_URLS[0]).readContract({
    address: implAddr,
    abi: [{ name: "agentExtension", type: "function", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" }],
    functionName: "agentExtension",
  }).catch(() => "0x0000000000000000000000000000000000000000") as Address;
  console.log(`  Factory:   ${factoryAddr}`);
  console.log(`  Impl:      ${implAddr}`);
  console.log(`  Extension: ${extensionAddr}\n`);

  // ── 2. AirAccountDelegate (EIP-7702, changed in beta.4) ─────────────────────
  console.log("[2/3] Deploy AirAccountDelegate (beta.4)...");
  const delegateAddr = await deployOnce("AirAccountDelegate", "AirAccountDelegate", [], 3_000_000n);
  console.log(`  AirAccountDelegate: ${delegateAddr}\n`);

  // ── 3. AgentRegistry (MANDATORY per-factory) ────────────────────────────────
  console.log("[3/3] Deploy AgentRegistry (bindFactory is set-once)...");
  const agentRegistryAddr = await deployOnce("AgentRegistry", "AgentRegistry", [], 1_500_000n);
  console.log(`  AgentRegistry: ${agentRegistryAddr}\n`);

  // ── Wiring ──────────────────────────────────────────────────────────────────
  const registryAbi = [{ name: "bindFactory", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" }];
  const factoryWireAbi = [{ name: "setAgentRegistry", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" }];

  console.log("[Wire 1/2] agentRegistry.bindFactory(factory)...");
  await callOnce("bindFactory", agentRegistryAddr, registryAbi, "bindFactory", [factoryAddr], 200_000n);

  console.log("[Wire 2/2] factory.setAgentRegistry(agentRegistry)...");
  await callOnce("setAgentRegistry", factoryAddr, factoryWireAbi, "setAgentRegistry", [agentRegistryAddr], 200_000n);

  console.log("\n=== beta.4 Deployment Summary — update .env.sepolia ===");
  console.log(`AIRACCOUNT_V0172_BETA_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_EXTENSION=${extensionAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_DELEGATE=${delegateAddr}`);
  console.log(`AIRACCOUNT_V0172_BETA_AGENT_REGISTRY=${agentRegistryAddr}`);
  console.log("\nREUSED (unchanged): VALIDATOR_ROUTER, SESSION_KEY_VALIDATOR, FORCE_EXIT_MODULE, BLS_ALGORITHM, BLS_AGGREGATOR, PARSER_REGISTRY");
}

main().catch((err) => { console.error(err); process.exit(1); });
