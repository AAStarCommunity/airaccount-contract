/**
 * Deploy M4 AirAccount contracts to Sepolia via viem
 *
 * DEPRECATED: This script uses the old 2-arg Factory constructor (entryPoint, communityGuardian).
 * The current factory requires 4 args: (entryPoint, communityGuardian, defaultTokens, defaultConfigs).
 * Do NOT use this script to deploy a new factory — it will fail or produce an unusable factory.
 * Use scripts/deploy-m5.ts instead.
 *
 * Deploys the updated Factory with cumulative signature support (algId 0x04, 0x05).
 * The creation code embedded in the Factory includes _validateCumulativeTier2/Tier3.
 *
 * Usage: pnpm tsx scripts/deploy-m4.ts
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

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

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

async function main() {
  console.log("=== Deploy M4 AirAccount Factory to Sepolia ===\n");
  console.log("This Factory includes cumulative signature validation (T2/T3).\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  console.log(`Deployer: ${signer.address}`);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account: signer,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Balance: ${formatEther(balance)} ETH\n`);

  if (balance < 10000000000000000n) {
    console.error("Need at least 0.01 ETH to deploy.");
    process.exit(1);
  }

  // ─── Deploy Factory ──────────────────────────────────────
  console.log("1. Deploying AAStarAirAccountFactoryV7 (M4)...");

  const factoryArtifact = loadArtifact("AAStarAirAccountFactoryV7");

  const factoryDeployData = encodeDeployData({
    abi: factoryArtifact.abi,
    bytecode: factoryArtifact.bytecode,
    args: [
      ENTRYPOINT,
      "0x0000000000000000000000000000000000000000", // No community guardian for testing
    ],
  });

  const factoryTxHash = await walletClient.sendTransaction({
    data: factoryDeployData,
  });
  console.log(`   TX: ${factoryTxHash}`);

  const factoryReceipt = await publicClient.waitForTransactionReceipt({
    hash: factoryTxHash,
  });
  const factoryAddress = factoryReceipt.contractAddress!;
  console.log(`   Factory deployed: ${factoryAddress}`);
  console.log(`   Gas used: ${factoryReceipt.gasUsed}\n`);

  // ─── Summary ──────────────────────────────────────────────
  console.log("=== M4 Factory Deployment Summary ===");
  console.log(`AIRACCOUNT_M4_FACTORY=${factoryAddress}`);
  console.log(`\nhttps://sepolia.etherscan.io/address/${factoryAddress}`);
  console.log("\nUpdate .env.sepolia and test scripts with this address.");
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
