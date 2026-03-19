/**
 * Onboard Step 2: Create AirAccount via Factory
 *
 * Flow:
 *   1. Load KMS wallet info from .env.wallet
 *   2. Fund the EOA address with ETH (for deployment gas)
 *   3. Deploy AirAccount via Factory.createAccountWithDefaults()
 *   4. Set P-256 passkey on the account
 *   5. Save account address to .env.wallet
 *
 * Usage: npx tsx scripts/onboard-2-create-account.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync, writeFileSync, appendFileSync } from "fs";
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

// Load both env files
config({ path: resolve(import.meta.dirname, "../.env.sepolia") });
config({ path: resolve(import.meta.dirname, "../.env.wallet") });

const WALLET_ENV_PATH = resolve(import.meta.dirname, "../.env.wallet");

// ─── ABI Fragments ──────────────────────────────────────────────────

const factoryAbi = [
  {
    name: "createAccountWithDefaults",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian2", type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "getAddressWithDefaults",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian2", type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "createAccount",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "guardians", type: "address[3]" },
          { name: "dailyLimit", type: "uint256" },
          { name: "approvedAlgIds", type: "uint8[]" },
          { name: "minDailyLimit", type: "uint256" },
          { name: "initialTokens", type: "address[]" },
          { name: "initialTokenConfigs", type: "tuple[]", components: [
            { name: "tier1Limit", type: "uint256" },
            { name: "tier2Limit", type: "uint256" },
            { name: "dailyLimit", type: "uint256" },
          ]},
        ],
      },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "getAddress",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "guardians", type: "address[3]" },
          { name: "dailyLimit", type: "uint256" },
          { name: "approvedAlgIds", type: "uint8[]" },
          { name: "minDailyLimit", type: "uint256" },
          { name: "initialTokens", type: "address[]" },
          { name: "initialTokenConfigs", type: "tuple[]", components: [
            { name: "tier1Limit", type: "uint256" },
            { name: "tier2Limit", type: "uint256" },
            { name: "dailyLimit", type: "uint256" },
          ]},
        ],
      },
    ],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

const accountAbi = [
  {
    name: "setP256Key",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_x", type: "bytes32" },
      { name: "_y", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    name: "owner",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "p256KeyX",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    name: "guardianCount",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    name: "entryPoint",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

async function main() {
  console.log("=== Onboard Step 2: Create AirAccount ===\n");

  // ─── Load Config ───────────────────────────────────────────────
  const eoaAddress = process.env.KMS_EOA_ADDRESS as Address;
  const passkeyX = process.env.PASSKEY_X as Hex;
  const passkeyY = process.env.PASSKEY_Y as Hex;
  const fundingKey = process.env.PRIVATE_KEY as Hex;
  const factoryAddress = process.env.AIRACCOUNT_FACTORY as Address;
  const rpcUrl = process.env.SEPOLIA_RPC_URL!;

  if (!eoaAddress) {
    throw new Error("KMS_EOA_ADDRESS not found. Run onboard-1-create-keys.ts first.");
  }
  if (!factoryAddress) {
    throw new Error("AIRACCOUNT_FACTORY not set in .env.sepolia");
  }

  console.log(`EOA Owner    : ${eoaAddress}`);
  console.log(`Factory      : ${factoryAddress}`);

  // ─── Setup Clients ─────────────────────────────────────────────
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(rpcUrl),
  });

  const funder = privateKeyToAccount(fundingKey);
  const walletClient = createWalletClient({
    account: funder,
    chain: sepolia,
    transport: http(rpcUrl),
  });

  // ─── Step 1: Predict Account Address ───────────────────────────
  // Use createAccount with minimal config (no guard) for initial testing
  // This works with existing M2 factory deployment
  const emptyConfig = {
    guardians: [
      "0x0000000000000000000000000000000000000000" as Address,
      "0x0000000000000000000000000000000000000000" as Address,
      "0x0000000000000000000000000000000000000000" as Address,
    ] as readonly [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [],
  };

  const salt = 0n;

  console.log("\n1. Predicting account address...");
  const predictedAddress = (await publicClient.readContract({
    address: factoryAddress,
    abi: factoryAbi,
    functionName: "getAddress",
    args: [eoaAddress, salt, emptyConfig],
  })) as Address;
  console.log(`   Predicted: ${predictedAddress}`);

  // Check if already deployed
  const existingCode = await publicClient.getBytecode({ address: predictedAddress });
  if (existingCode && existingCode !== "0x") {
    console.log("   Account already deployed!");
    appendAccountToEnv(predictedAddress);
    return;
  }

  // ─── Step 2: Fund EOA for gas (if needed) ──────────────────────
  // The factory is called by the funder, not the EOA, so we fund the predicted account
  console.log("\n2. Funding predicted account address with 0.01 ETH...");
  const fundTx = await walletClient.sendTransaction({
    to: predictedAddress,
    value: parseEther("0.01"),
  });
  console.log(`   Fund tx: ${fundTx}`);
  await publicClient.waitForTransactionReceipt({ hash: fundTx });

  // ─── Step 3: Deploy Account via Factory ────────────────────────
  console.log("\n3. Deploying AirAccount via Factory.createAccount()...");
  const deployTx = await walletClient.writeContract({
    address: factoryAddress,
    abi: factoryAbi,
    functionName: "createAccount",
    args: [eoaAddress, salt, emptyConfig],
  });
  console.log(`   Deploy tx: ${deployTx}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
  console.log(`   Gas used: ${receipt.gasUsed}`);

  // Verify deployment
  const code = await publicClient.getBytecode({ address: predictedAddress });
  if (!code || code === "0x") {
    throw new Error("Account deployment failed - no code at predicted address");
  }
  console.log(`   Account deployed at: ${predictedAddress} ✓`);

  // ─── Step 4: Verify Account State ──────────────────────────────
  console.log("\n4. Verifying account state...");
  const owner = await publicClient.readContract({
    address: predictedAddress,
    abi: accountAbi,
    functionName: "owner",
  });
  const ep = await publicClient.readContract({
    address: predictedAddress,
    abi: accountAbi,
    functionName: "entryPoint",
  });
  console.log(`   Owner     : ${owner}`);
  console.log(`   EntryPoint: ${ep}`);
  console.log(`   Owner matches EOA: ${(owner as string).toLowerCase() === eoaAddress.toLowerCase()} ✓`);

  // ─── Step 5: Save to .env.wallet ───────────────────────────────
  appendAccountToEnv(predictedAddress);

  console.log("\n=== Summary ===");
  console.log(`   Account Address: ${predictedAddress}`);
  console.log(`   Owner (EOA)    : ${eoaAddress}`);
  console.log(`   Passkey X      : ${passkeyX?.slice(0, 20)}...`);
  console.log("\nNext: npx tsx scripts/onboard-3-test-transfer.ts");
}

function appendAccountToEnv(accountAddress: Address) {
  const existing = readFileSync(WALLET_ENV_PATH, "utf-8");
  if (existing.includes("AIRACCOUNT_ADDRESS=")) {
    console.log("   Account address already in .env.wallet");
    return;
  }
  appendFileSync(
    WALLET_ENV_PATH,
    `\n# AirAccount (deployed)\nAIRACCOUNT_ADDRESS=${accountAddress}\n`
  );
  console.log(`\n5. Saved account address to ${WALLET_ENV_PATH}`);
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
