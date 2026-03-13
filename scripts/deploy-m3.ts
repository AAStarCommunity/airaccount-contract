/**
 * Deploy M3 AirAccount contracts to Sepolia via viem
 *
 * Deploys:
 *   1. AAStarAirAccountFactoryV7 (with M3 security fixes)
 *   2. First test account via createAccount() with empty config
 *
 * Usage: npx tsx scripts/deploy-m3.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  encodeDeployData,
  parseEther,
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

// Load compiled artifacts
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
  console.log("=== Deploy M3 AirAccount to Sepolia ===\n");

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

  // Check deployer balance
  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Balance: ${formatEther(balance)} ETH\n`);

  // ─── Step 1: Deploy Factory ──────────────────────────────────
  console.log("1. Deploying AAStarAirAccountFactoryV7...");

  const factoryArtifact = loadArtifact("AAStarAirAccountFactoryV7");

  // Constructor args: (address _entryPoint, address _communityGuardian)
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

  // ─── Step 2: Create first test account ──────────────────────
  console.log("2. Creating test account via createAccount()...");

  const emptyConfig = {
    guardians: [
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
    ] as readonly [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [] as number[],
  };

  // Predict address first
  const predictedAddress = await publicClient.readContract({
    address: factoryAddress,
    abi: factoryArtifact.abi,
    functionName: "getAddress",
    args: [signer.address, 0n, emptyConfig],
  });
  console.log(`   Predicted: ${predictedAddress}`);

  // Create account
  const createTxHash = await walletClient.writeContract({
    address: factoryAddress,
    abi: factoryArtifact.abi,
    functionName: "createAccount",
    args: [signer.address, 0n, emptyConfig],
  });
  console.log(`   TX: ${createTxHash}`);

  const createReceipt = await publicClient.waitForTransactionReceipt({
    hash: createTxHash,
  });
  console.log(`   Gas used: ${createReceipt.gasUsed}`);

  // Verify
  const code = await publicClient.getBytecode({
    address: predictedAddress as Address,
  });
  if (code && code !== "0x") {
    console.log(`   Account deployed: ${predictedAddress}\n`);
  } else {
    console.error("   FAILED: No code at predicted address\n");
    process.exit(1);
  }

  // Verify owner
  const owner = await publicClient.readContract({
    address: predictedAddress as Address,
    abi: [
      {
        type: "function",
        name: "owner",
        inputs: [],
        outputs: [{ type: "address" }],
        stateMutability: "view",
      },
    ],
    functionName: "owner",
  });
  console.log(`   Owner: ${owner}`);
  console.log(
    `   Owner matches: ${(owner as string).toLowerCase() === signer.address.toLowerCase()}\n`
  );

  // ─── Summary ──────────────────────────────────────────────────
  console.log("=== M3 Deployment Summary ===");
  console.log(`AIRACCOUNT_M3_FACTORY=${factoryAddress}`);
  console.log(`AIRACCOUNT_M3_ACCOUNT=${predictedAddress}`);
  console.log(`\nhttps://sepolia.etherscan.io/address/${factoryAddress}`);
  console.log(`https://sepolia.etherscan.io/address/${predictedAddress}`);
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
