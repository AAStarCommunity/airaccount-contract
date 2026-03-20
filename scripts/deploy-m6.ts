/**
 * deploy-m6.ts — Deploy M6 AirAccount (direct, bypassing broken factory) to Sepolia via viem
 *
 * M6 changes vs M5:
 *   - ALG_WEIGHTED (0x07): Bitmap-driven weighted multi-signature (M6.1)
 *   - Guardian consent for weight-change proposals (M6.2)
 *   - ALG_SESSION_KEY (0x08): Time-limited session key
 *
 * NOTE: AAStarAirAccountFactoryV7 runtime bytecode grew to 30,172 bytes (EIP-170 limit: 24,576 bytes)
 * because M6.1/M6.2 added ~5.5KB to AAStarAirAccountV7 which is embedded in the factory via
 * `type(AAStarAirAccountV7).creationCode`. The factory cannot be deployed as-is.
 * RESOLUTION: Deploy account directly (bypassing factory) for E2E testing.
 * FOLLOW-UP BUG: factory-eip170-overflow — fix by externalizing init code or using proxy pattern.
 *
 * This script deploys AAStarAirAccountV7 directly using the Arachnid CREATE2 factory for
 * deterministic addressing: 0x4e59b44847b379578588920cA78FbF26c0B4956C
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m6.ts
 *
 * After deploy, update .env.sepolia:
 *   AIRACCOUNT_M6_ACCOUNT=<deployed address>
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeDeployData,
  parseEther,
  formatEther,
  keccak256,
  concat,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Constants ─────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
// Arachnid deterministic CREATE2 factory (deployed on all major networks)
const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C" as Address;

// ─── Env ───────────────────────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;

// ─── Helpers ───────────────────────────────────────────────────────────────

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

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Deploy M6 AirAccount to Sepolia (Direct, no factory) ===\n");
  console.log("M6 features:");
  console.log("  - ALG_WEIGHTED (0x07): Bitmap-driven weighted multi-signature (M6.1)");
  console.log("  - Guardian consent for weight-change proposals (M6.2)");
  console.log("  - ALG_SESSION_KEY (0x08): Time-limited session key");
  console.log();
  console.log("NOTE: AAStarAirAccountFactoryV7 exceeds EIP-170 (30,172 > 24,576 bytes).");
  console.log("      M6.1/M6.2 code increased AAStarAirAccountV7 to ~20KB, pushing factory over.");
  console.log("      Deploying account directly via Arachnid CREATE2 factory for E2E testing.");
  console.log("      BUG FILED: factory-eip170-overflow (fix in M7: externalize init code)\n");

  if (!PRIVATE_KEY) {
    console.error("Missing PRIVATE_KEY in .env.sepolia");
    process.exit(1);
  }

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

  if (balance < parseEther("0.01")) {
    console.error("Need at least 0.01 ETH to deploy.");
    process.exit(1);
  }

  // ─── Load account artifact ────────────────────────────────────────────────
  console.log("Loading AAStarAirAccountV7 artifact...");
  const accountArtifact = loadArtifact("AAStarAirAccountV7");

  // ─── Build init config ────────────────────────────────────────────────────
  // Test account for M6 E2E: owner=deployer, 2 funded test guardians (bob + jack from .env.sepolia)
  // Using funded accounts so guardian consent tests (M6.2) can call approveWeightChange without
  // needing external ETH top-up.
  const ZERO = "0x0000000000000000000000000000000000000000" as Address;
  const GUARDIAN0_KEY_M6 = (process.env.PRIVATE_KEY_BOB || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d") as Hex;
  const GUARDIAN1_KEY_M6 = (process.env.PRIVATE_KEY_JACK || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a") as Hex;
  const GUARDIAN0 = privateKeyToAccount(GUARDIAN0_KEY_M6).address;
  const GUARDIAN1 = privateKeyToAccount(GUARDIAN1_KEY_M6).address;

  console.log(`Owner (deployer): ${signer.address}`);
  console.log(`Guardian0:        ${GUARDIAN0}`);
  console.log(`Guardian1:        ${GUARDIAN1}`);

  const initConfig = {
    guardians: [GUARDIAN0, GUARDIAN1, ZERO] as [Address, Address, Address],
    dailyLimit: parseEther("0.1"),
    approvedAlgIds: [1, 2, 3, 4, 5, 6, 7, 8] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
  };

  // ─── Compute deterministic address via Arachnid CREATE2 factory ──────────
  const SALT_NUMBER = 701n; // 701: bob+jack guardians (700 used Hardhat unfunded keys)
  const salt = keccak256(
    concat([
      signer.address as Hex,
      toHex(SALT_NUMBER, { size: 32 }),
    ])
  );

  const initCode = encodeDeployData({
    abi: accountArtifact.abi,
    bytecode: accountArtifact.bytecode,
    args: [ENTRYPOINT, signer.address, initConfig],
  });

  // Arachnid CREATE2: address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
  const initCodeHash = keccak256(initCode);
  const predictedAddr = `0x${keccak256(
    concat([
      "0xff",
      CREATE2_FACTORY,
      salt,
      initCodeHash,
    ])
  ).slice(-40)}` as Address;

  console.log(`\nPredicted account address: ${predictedAddr}`);
  console.log(`Etherscan: https://sepolia.etherscan.io/address/${predictedAddr}`);
  console.log(`Init code size: ${initCode.length / 2 - 1} bytes`);

  // ─── Check if already deployed ───────────────────────────────────────────
  const code = await publicClient.getBytecode({ address: predictedAddr });
  if (code && code.length > 2) {
    console.log("\n[Deploy] Account already deployed, reusing.");
  } else {
    console.log("\n[Deploy] Deploying via Arachnid CREATE2 factory...");

    // Arachnid factory calldata: salt(32) ++ initCode
    const callData = concat([salt, initCode]) as Hex;

    const txHash = await walletClient.sendTransaction({
      to: CREATE2_FACTORY,
      data: callData,
      gas: 6000000n, // account (19,966B × 200) + guard (3,329B × 200) + calldata ≈ 5.1M
    });
    console.log(`  TX: ${txHash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  Status: ${receipt.status}`);
    console.log(`  Gas used: ${receipt.gasUsed}`);

    const deployedCode = await publicClient.getBytecode({ address: predictedAddr });
    if (!deployedCode || deployedCode.length <= 2) {
      console.error("  ERROR: Account not deployed — check gas or constructor revert");
      process.exit(1);
    }
    console.log(`  Deployed: ${predictedAddr} (${deployedCode.length / 2 - 1} bytes runtime)`);
  }

  // ─── Summary ──────────────────────────────────────────────────────────────
  console.log("\n=== M6 Account Deployment Summary ===");
  console.log(`AIRACCOUNT_M6_ACCOUNT=${predictedAddr}`);
  console.log();
  console.log("Add to .env.sepolia:");
  console.log(`  AIRACCOUNT_M6_ACCOUNT=${predictedAddr}`);
  console.log();
  console.log("Known issues:");
  console.log("  [BUG] AAStarAirAccountFactoryV7 exceeds EIP-170 (30,172B > 24,576B limit).");
  console.log("        Root cause: M6.1/M6.2 code grew the account, factory embeds it inline.");
  console.log("        Fix in M7: externalize init code via SSTORE2 or proxy/clone pattern.");
  console.log();
  console.log("Next steps:");
  console.log("  AIRACCOUNT_M6_ACCOUNT=<address above> pnpm tsx scripts/test-m6-weighted-e2e.ts");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
