/**
 * deploy-m7-r3.ts — Deploy AirAccount M7 r3 to Sepolia
 *
 * M7 r3 changes vs M7 r1:
 *   - H-4: uninstallModule now requires onlyOwnerOrEntryPoint (guardian collusion bypass fixed)
 *   - H-5: CompositeValidator uses validateCompositeSignature callback (not isValidSignature)
 *   - H-6: nonce-key routing stores algId in transient queue so Guard sees correct tier
 *   - M-9: parserRegistry.getParser() wrapped in try/catch (DoS via malicious registry fixed)
 *   - M-10: installModule calls onInstall; uninstallModule calls onUninstall (best-effort)
 *
 * Deploys:
 *   1. AAStarAirAccountFactoryV7 (new implementation with M7 r3 fixes)
 *   2. AirAccountCompositeValidator (updated validateCompositeSignature callback)
 *   3. Test account via factory (salt=731, 3 guardians, all algIds)
 *   4. Funds account with 0.05 ETH for E2E tests
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m7-r3.ts
 *
 * After deploy, update .env.sepolia:
 *   AIRACCOUNT_M7_R3_FACTORY=<factory>
 *   AIRACCOUNT_M7_R3_IMPL=<implementation>
 *   AIRACCOUNT_M7_R3_ACCOUNT=<account>
 *   AIRACCOUNT_M7_R3_COMPOSITE_VALIDATOR=<compositeValidator>
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeDeployData,
  encodeFunctionData,
  parseEther,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Constants ───────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const SALT = 731n; // M7 r3 account salt

// ─── Env ─────────────────────────────────────────────────────────────────────

const RPC_URL = (process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL)!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
// Guardian keys must be explicitly set — no fallback to well-known test keys.
const GUARDIAN1_KEY = process.env.PRIVATE_KEY_BOB  as Hex;
const GUARDIAN2_KEY = process.env.PRIVATE_KEY_JACK as Hex;
const COMMUNITY_GUARDIAN = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return { abi: artifact.abi as unknown[], bytecode: artifact.bytecode.object as Hex };
}

async function waitTx(publicClient: ReturnType<typeof createPublicClient>, hash: Hex, label: string) {
  console.log(`  TX(${label}): ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} tx reverted`);
  console.log(`  Gas: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Deploy AirAccount M7 r3 to Sepolia ===\n");
  console.log("Security fixes: H-4 (uninstall auth), H-5 (composite validator),");
  console.log("H-6 (algId queue), M-9 (parser registry), M-10 (onInstall/onUninstall)\n");

  if (!PRIVATE_KEY)    { console.error("Missing PRIVATE_KEY in .env.sepolia"); process.exit(1); }
  if (!RPC_URL)        { console.error("Missing SEPOLIA_RPC_URL in .env.sepolia"); process.exit(1); }
  if (!GUARDIAN1_KEY)  { console.error("Missing PRIVATE_KEY_BOB — guardian keys must be explicit, no public-key fallback allowed"); process.exit(1); }
  if (!GUARDIAN2_KEY)  { console.error("Missing PRIVATE_KEY_JACK — guardian keys must be explicit, no public-key fallback allowed"); process.exit(1); }

  const ownerAccount    = privateKeyToAccount(PRIVATE_KEY);
  const guardian1Account = privateKeyToAccount(GUARDIAN1_KEY);
  const guardian2Account = privateKeyToAccount(GUARDIAN2_KEY);

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: ownerAccount, chain: sepolia, transport: http(RPC_URL) });

  console.log(`Owner:      ${ownerAccount.address}`);
  console.log(`Guardian1:  ${guardian1Account.address}`);
  console.log(`Guardian2:  ${guardian2Account.address}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const balance = await publicClient.getBalance({ address: ownerAccount.address });
  console.log(`Deployer balance: ${formatEther(balance)} ETH`);
  if (balance < parseEther("0.1")) {
    console.error("Need at least 0.1 ETH to deploy and fund account.");
    process.exit(1);
  }

  // ─── 1. Deploy AirAccountCompositeValidator ──────────────────────────────
  console.log("\n[1/4] Deploy AirAccountCompositeValidator...");
  const cvArtifact = loadArtifact("AirAccountCompositeValidator");
  const cvTxHash = await walletClient.sendTransaction({
    data: encodeDeployData({ abi: cvArtifact.abi, bytecode: cvArtifact.bytecode, args: [] }),
  });
  const cvReceipt = await waitTx(publicClient, cvTxHash, "AirAccountCompositeValidator");
  const compositeValidatorAddr = cvReceipt.contractAddress!;
  console.log(`  CompositeValidator: ${compositeValidatorAddr}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${compositeValidatorAddr}`);

  // ─── 2. Deploy AAStarAirAccountFactoryV7 (with M7 r3 implementation) ─────
  console.log("\n[2/4] Deploy AAStarAirAccountFactoryV7 (M7 r3 implementation)...");
  const factoryArtifact = loadArtifact("AAStarAirAccountFactoryV7");
  const factoryTxHash = await walletClient.sendTransaction({
    data: encodeDeployData({
      abi: factoryArtifact.abi,
      bytecode: factoryArtifact.bytecode,
      args: [
        ENTRYPOINT,
        COMMUNITY_GUARDIAN,
        [],  // no default tokens
        [],  // no default token configs
        compositeValidatorAddr,  // defaultValidatorModule
        "0x0000000000000000000000000000000000000000" as Address,  // no defaultHookModule
      ],
    }),
  });
  const factoryReceipt = await waitTx(publicClient, factoryTxHash, "Factory");
  const factoryAddr = factoryReceipt.contractAddress!;
  console.log(`  Factory: ${factoryAddr}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${factoryAddr}`);

  const implAddr = await publicClient.readContract({
    address: factoryAddr,
    abi: factoryArtifact.abi,
    functionName: "implementation",
  }) as Address;
  console.log(`  Implementation: ${implAddr}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${implAddr}`);

  // ─── 3. Deploy account via factory ───────────────────────────────────────
  console.log(`\n[3/4] Deploy account via factory (salt=${SALT})...`);

  const initConfig = {
    guardians: [
      guardian1Account.address,
      guardian2Account.address,
      "0x0000000000000000000000000000000000000000",
    ] as [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predictedAddr = await publicClient.readContract({
    address: factoryAddr,
    abi: factoryArtifact.abi,
    functionName: "getAddress",
    args: [ownerAccount.address, SALT, initConfig],
  }) as Address;
  console.log(`  Predicted address: ${predictedAddr}`);

  const existingCode = await publicClient.getBytecode({ address: predictedAddr });
  if (existingCode && existingCode.length > 2) {
    console.log("  Account already deployed at this address.");
  } else {
    const createTxHash = await walletClient.writeContract({
      address: factoryAddr,
      abi: factoryArtifact.abi,
      functionName: "createAccount",
      args: [ownerAccount.address, SALT, initConfig],
      gas: 1_000_000n,
    });
    await waitTx(publicClient, createTxHash, "createAccount");
    const deployedCode = await publicClient.getBytecode({ address: predictedAddr });
    if (!deployedCode || deployedCode.length <= 2) {
      throw new Error("Account deployment: tx succeeded but no bytecode at predicted address");
    }
    console.log(`  Account deployed: ${predictedAddr}`);
  }
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${predictedAddr}`);

  // ─── 4. Fund account ─────────────────────────────────────────────────────
  console.log("\n[4/4] Fund account with 0.05 ETH for E2E tests...");
  const accountBalance = await publicClient.getBalance({ address: predictedAddr });
  console.log(`  Current balance: ${formatEther(accountBalance)} ETH`);

  if (accountBalance < parseEther("0.03")) {
    const fundTx = await walletClient.sendTransaction({
      to: predictedAddr,
      value: parseEther("0.05"),
    });
    await waitTx(publicClient, fundTx, "fund");
    const newBalance = await publicClient.getBalance({ address: predictedAddr });
    console.log(`  New balance: ${formatEther(newBalance)} ETH`);
  } else {
    console.log("  Sufficient balance, skipping fund.");
  }

  // ─── Deposit to EntryPoint ────────────────────────────────────────────────
  console.log("\n[+] Deposit 0.02 ETH to EntryPoint for gas...");
  const epDepositTx = await walletClient.writeContract({
    address: ENTRYPOINT,
    abi: [{ name: "depositTo", type: "function", stateMutability: "payable",
      inputs: [{ name: "account", type: "address" }], outputs: [] }],
    functionName: "depositTo",
    args: [predictedAddr],
    value: parseEther("0.02"),
  });
  await waitTx(publicClient, epDepositTx, "depositToEntryPoint");

  // ─── Summary ─────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log(" M7 r3 Deployment Complete");
  console.log("═══════════════════════════════════════════════════════");
  console.log("\nAdd to .env.sepolia:");
  console.log(`AIRACCOUNT_M7_R3_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_R3_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_R3_ACCOUNT=${predictedAddr}`);
  console.log(`AIRACCOUNT_M7_R3_COMPOSITE_VALIDATOR=${compositeValidatorAddr}`);
  console.log(`\n# Update canonical pointers:`);
  console.log(`AIRACCOUNT_M7_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_ACCOUNT=${predictedAddr}`);
  console.log(`\nNext step:`);
  console.log(`  pnpm tsx scripts/test-m7-e2e.ts`);
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
