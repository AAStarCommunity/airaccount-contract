/**
 * BLS Key Cache Pre-computation Script
 *
 * Call cacheAggregatedKey(nodeIds) on AAStarBLSAlgorithm BEFORE submitting
 * batched UserOps to save ~20,000 gas per Tier 2/3 transaction.
 *
 * Without cache: each UserOp triggers N G1Add precompile calls (500 gas each)
 *                to aggregate public keys on-chain.
 * With cache:    aggregated key is read from a single SLOAD (~2,100 gas).
 *
 * When to call:
 *   - After new DVT nodes are registered (registerPublicKey)
 *   - Before any Tier 2/3 batch submission
 *   - Cache persists across transactions — call once per node set
 *
 * Usage: pnpm tsx scripts/cache-bls-keys.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;

// AirAccount M4 deployed addresses
const BLS_ALGORITHM_ADDRESS =
  (process.env.BLS_ALGORITHM_ADDRESS as Address) ||
  "0xc2096E8D04beb3C337bb388F5352710d62De0287"; // M2 BLS Algorithm

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(
      resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`),
      "utf-8"
    )
  );
  return { abi: artifact.abi };
}

async function main() {
  console.log("=== BLS Key Cache Pre-computation ===\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: signer, chain: sepolia, transport: http(RPC_URL) });

  const { abi } = loadArtifact("AAStarBLSAlgorithm");
  console.log(`Operator:      ${signer.address}`);
  console.log(`BLS Algorithm: ${BLS_ALGORITHM_ADDRESS}\n`);

  // 1. Get all registered nodes
  const nodeCount = await publicClient.readContract({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "getRegisteredNodeCount",
  }) as bigint;

  console.log(`Registered nodes: ${nodeCount}`);
  if (nodeCount === 0n) {
    console.log("No registered nodes. Register nodes first with registerPublicKey().");
    return;
  }

  // 2. Fetch nodeIds
  const [nodeIds] = await publicClient.readContract({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "getRegisteredNodes",
    args: [0n, nodeCount],
  }) as [Hex[], Hex[]];

  console.log(`\nNode IDs:`);
  nodeIds.forEach((id, i) => console.log(`  [${i}] ${id}`));

  // 3. Check if cache already exists for the full node set
  const setHash = await publicClient.readContract({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "computeSetHash",
    args: [nodeIds],
  }) as Hex;

  const cachedKey = await publicClient.readContract({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "cachedAggKeys",
    args: [setHash],
  }) as Hex;

  if (cachedKey && cachedKey !== "0x") {
    console.log(`\n✅ Cache already exists for full node set (${nodeIds.length} nodes)`);
    console.log(`   Set hash: ${setHash}`);
    console.log(`   Cached key (first 32 bytes): ${cachedKey.slice(0, 66)}...`);
    console.log(`\nNo action needed.`);
    return;
  }

  // 4. Cache the aggregated key for all registered nodes
  console.log(`\nCaching aggregated key for ${nodeIds.length} nodes...`);
  const gasEstimate = await publicClient.estimateContractGas({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "cacheAggregatedKey",
    args: [nodeIds],
    account: signer.address,
  });

  console.log(`Estimated gas: ${gasEstimate.toLocaleString()}`);

  const hash = await walletClient.writeContract({
    address: BLS_ALGORITHM_ADDRESS,
    abi,
    functionName: "cacheAggregatedKey",
    args: [nodeIds],
  });

  console.log(`\nTx submitted: ${hash}`);
  console.log(`Waiting for confirmation...`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`\n✅ Cache stored successfully!`);
  console.log(`   Block:    ${receipt.blockNumber}`);
  console.log(`   Gas used: ${receipt.gasUsed.toLocaleString()}`);
  console.log(`   Set hash: ${setHash}`);
  console.log(`\nBenefit: Future Tier 2/3 UserOps will save ~${(Number(nodeCount) - 1) * 500 + 2100} gas`);
  console.log(`         per transaction (cache hit = 1 SLOAD vs ${Number(nodeCount)} G1Add calls)`);

  // 5. If specific subsets are commonly used, cache them too
  if (nodeIds.length > 2) {
    console.log(`\nTip: Cache subsets if specific node combinations are used frequently:`);
    console.log(`  const subsetIds = nodeIds.slice(0, 3); // first 3 nodes`);
    console.log(`  await cacheAggregatedKey(subsetIds);`);
  }
}

main().catch(console.error);
