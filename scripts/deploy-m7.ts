/**
 * deploy-m7.ts — Deploy M7 AirAccount via factory to Sepolia
 *
 * Deploys an account with 3 guardians and 0.01 ETH daily limit.
 * After deploy, set AIRACCOUNT_M7_ACCOUNT= in .env.sepolia.
 *
 * Usage: pnpm tsx scripts/deploy-m7.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  encodeFunctionData,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const GUARDIAN1_KEY = (process.env.PRIVATE_KEY_BOB ?? "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d") as Hex;
const GUARDIAN2_KEY = (process.env.PRIVATE_KEY_JACK ?? "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a") as Hex;
const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL!;
const FACTORY = (process.env.AIRACCOUNT_M7_FACTORY ?? "0x9D0735E3096C02eC63356F21d6ef79586280289f") as Address;

function loadABI(name: string): unknown[] {
  const path = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  return JSON.parse(readFileSync(path, "utf-8")).abi;
}

async function main() {
  const ownerAccount = privateKeyToAccount(PRIVATE_KEY);
  const g1Account = privateKeyToAccount(GUARDIAN1_KEY);
  const g2Account = privateKeyToAccount(GUARDIAN2_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: ownerAccount, chain: sepolia, transport: http(RPC_URL) });

  console.log("=== Deploy M7 AirAccount via factory ===\n");
  console.log(`Owner:     ${ownerAccount.address}`);
  console.log(`Guardian1: ${g1Account.address}`);
  console.log(`Guardian2: ${g2Account.address}`);
  console.log(`Factory:   ${FACTORY}\n`);

  const factoryABI = loadABI("AAStarAirAccountFactoryV7");

  // Predict account address first (salt=700 for M7)
  const SALT = 700n;
  const DAILY_LIMIT = parseEther("0.01");

  const guardABI = loadABI("AAStarGlobalGuard");
  const _ = guardABI; // unused but loaded

  // Build InitConfig (no guard for simplicity — just guardian setup)
  const initConfig = {
    guardians: [g1Account.address, g2Account.address, "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [0x02, 0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predictedAddr = await publicClient.readContract({
    address: FACTORY,
    abi: factoryABI,
    functionName: "getAddress",
    args: [ownerAccount.address, SALT, initConfig],
  }) as Address;

  console.log(`Predicted address: ${predictedAddr}`);

  const code = await publicClient.getBytecode({ address: predictedAddr });
  if (code && code.length > 2) {
    console.log("Account already deployed!");
    console.log(`\nAIRACCOUNT_M7_ACCOUNT=${predictedAddr}`);
    return;
  }

  console.log("Deploying...");
  const txHash = await walletClient.writeContract({
    address: FACTORY,
    abi: factoryABI,
    functionName: "createAccount",
    args: [ownerAccount.address, SALT, initConfig],
    gas: 500_000n,
  });

  console.log(`Tx: ${txHash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`Status: ${receipt.status} (block ${receipt.blockNumber})`);

  if (receipt.status === "success") {
    const deployed = await publicClient.getBytecode({ address: predictedAddr });
    if (deployed && deployed.length > 2) {
      console.log(`\n✅ Account deployed: ${predictedAddr}`);
      console.log(`\n=== Add to .env.sepolia ===`);
      console.log(`AIRACCOUNT_M7_ACCOUNT=${predictedAddr}`);
    } else {
      console.error("ERROR: Tx succeeded but no bytecode at predicted address");
    }
  }
}

main().catch(console.error);
