/**
 * deploy-bls-aggregator.ts — Deploy AAStarBLSAggregator to Sepolia via viem
 *
 * The BLS aggregator enables ERC-4337 handleAggregatedOps flows where multiple
 * BLS-signed UserOps can be submitted with a single aggregated signature,
 * reducing on-chain verification costs for batch operations.
 *
 * Constructor: constructor(address _blsAlgorithm)
 *   _blsAlgorithm = AAStarBLSAlgorithm already deployed on Sepolia (M2)
 *
 * Usage:
 *   pnpm tsx scripts/deploy-bls-aggregator.ts
 *
 * After deploy, update .env.sepolia:
 *   AIRACCOUNT_M5_BLS_AGGREGATOR=<deployed address>
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeDeployData,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Constants ────────────────────────────────────────────────────────────────

// AAStarBLSAlgorithm deployed on Sepolia in M2
const BLS_ALGORITHM_ADDRESS = "0xc2096E8D04beb3C337bb388F5352710d62De0287" as Address;

// ─── Env ──────────────────────────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;

if (!RPC_URL) {
  console.error("Missing SEPOLIA_RPC_URL in .env.sepolia");
  process.exit(1);
}
if (!PRIVATE_KEY) {
  console.error("Missing PRIVATE_KEY in .env.sepolia");
  process.exit(1);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(
      resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`),
      "utf-8"
    )
  );
  return {
    abi: artifact.abi,
    bytecode: artifact.bytecode.object as Hex,
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Deploy AAStarBLSAggregator to Sepolia ===\n");
  console.log("Purpose: ERC-4337 IAggregator for handleAggregatedOps BLS batch flows");
  console.log("F67: BLS aggregator integration | F70: batch gas benchmark\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  console.log(`Deployer:        ${signer.address}`);
  console.log(`BLS Algorithm:   ${BLS_ALGORITHM_ADDRESS}`);
  console.log();

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account: signer,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  // Check deployer balance
  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Deployer balance: ${formatEther(balance)} ETH\n`);

  if (balance < 10000000000000000n) {
    console.error("Need at least 0.01 ETH to deploy.");
    process.exit(1);
  }

  // Load artifact (requires forge build to have been run)
  console.log("Loading artifact: out/AAStarBLSAggregator.sol/AAStarBLSAggregator.json");
  const artifact = loadArtifact("AAStarBLSAggregator");
  console.log(`  ABI functions: ${artifact.abi.filter((x: any) => x.type === "function").map((x: any) => x.name).join(", ")}`);
  console.log();

  // Encode deploy data: constructor(address _blsAlgorithm)
  const deployData = encodeDeployData({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
    args: [BLS_ALGORITHM_ADDRESS],
  });

  console.log("Deploying AAStarBLSAggregator...");
  const txHash = await walletClient.sendTransaction({
    data: deployData,
  });
  console.log(`  TX:       ${txHash}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${txHash}`);
  console.log("  Waiting for confirmation...");

  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

  if (!receipt.contractAddress) {
    console.error("Deploy failed — no contractAddress in receipt.");
    console.error("Receipt status:", receipt.status);
    process.exit(1);
  }

  const aggregatorAddress = receipt.contractAddress;
  console.log(`  Contract: ${aggregatorAddress}`);
  console.log(`  Gas used: ${receipt.gasUsed}`);
  console.log(`  Block:    ${receipt.blockNumber}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${aggregatorAddress}`);
  console.log();

  // Verify the blsAlgorithm storage slot was set correctly
  console.log("Verifying deployment...");
  const AGGREGATOR_READ_ABI = [
    {
      name: "blsAlgorithm",
      type: "function",
      inputs: [],
      outputs: [{ name: "", type: "address" }],
      stateMutability: "view",
    },
  ] as const;

  const storedAlgorithm = await publicClient.readContract({
    address: aggregatorAddress,
    abi: AGGREGATOR_READ_ABI,
    functionName: "blsAlgorithm",
  });

  if (storedAlgorithm.toLowerCase() === BLS_ALGORITHM_ADDRESS.toLowerCase()) {
    console.log(`  blsAlgorithm: ${storedAlgorithm} ✓`);
  } else {
    console.warn(`  WARNING: blsAlgorithm mismatch! Got ${storedAlgorithm}, expected ${BLS_ALGORITHM_ADDRESS}`);
  }
  console.log();

  // ─── Summary ──────────────────────────────────────────────────────────────
  console.log("=== Deployment Summary ===");
  console.log(`Contract:          AAStarBLSAggregator`);
  console.log(`Address:           ${aggregatorAddress}`);
  console.log(`TX hash:           ${txHash}`);
  console.log(`Gas used:          ${receipt.gasUsed}`);
  console.log();
  console.log("Add to .env.sepolia:");
  console.log(`  AIRACCOUNT_M5_BLS_AGGREGATOR=${aggregatorAddress}`);
  console.log();
  console.log("Easy copy:");
  console.log(`AIRACCOUNT_M5_BLS_AGGREGATOR=${aggregatorAddress}`);
  console.log();
  console.log("Next steps:");
  console.log("  pnpm tsx scripts/test-m5-bls-aggregator-e2e.ts");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
