/**
 * deploy-m7-r5.ts — Deploy AirAccount M7 r5 (full module stack) to Sepolia
 *
 * Deploys all M7 contracts with the latest security fixes:
 *   - algId queue pollution fix (validationData==0 guard)
 *   - installModule passes actual initData to onInstall
 *   - delegateSession selectorAllowlist scope check
 *   - TierGuardHook ALG_WEIGHTED tier mapping
 *   - getCurrentAlgId() added to base
 *
 * Deploys:
 *   1. AirAccountCompositeValidator
 *   2. TierGuardHook
 *   3. AgentSessionKeyValidator
 *   4. AAStarAirAccountFactoryV7 (r5 implementation)
 *   5. Test account via factory (salt=740, 2-of-3 guardians, all algIds)
 *   6. Funds account with 0.05 ETH
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m7-r5.ts
 *
 * After deploy, update .env.sepolia with printed addresses.
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
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Constants ───────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const SALT = 750n; // M7 r5 account salt

// ─── Env ─────────────────────────────────────────────────────────────────────

const RPC_URL     = (process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL)!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
// Guardian keys must be explicitly set — no fallback to well-known test keys to prevent
// accidental use of publicly-known guardians on any network (testnet or mainnet).
const G1_KEY      = process.env.PRIVATE_KEY_BOB  as Hex;
const G2_KEY      = process.env.PRIVATE_KEY_JACK as Hex;
const COMMUNITY   = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return { abi: artifact.abi as unknown[], bytecode: artifact.bytecode.object as Hex };
}

async function waitTx(
  client: ReturnType<typeof createPublicClient>,
  hash: Hex,
  label: string
) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas used: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }
  if (!RPC_URL)     { console.error("Missing SEPOLIA_RPC_URL"); process.exit(1); }
  if (!G1_KEY)      { console.error("Missing PRIVATE_KEY_BOB — guardian keys must be explicit, no public-key fallback allowed"); process.exit(1); }
  if (!G2_KEY)      { console.error("Missing PRIVATE_KEY_JACK — guardian keys must be explicit, no public-key fallback allowed"); process.exit(1); }

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const g1    = privateKeyToAccount(G1_KEY);
  const g2    = privateKeyToAccount(G2_KEY);

  const pub  = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const wal  = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });

  console.log("=== Deploy AirAccount M7 r5 (recordSpend auth + hook overwrite fix) to Sepolia ===\n");
  console.log(`Owner:      ${owner.address}`);
  console.log(`Guardian1:  ${g1.address}`);
  console.log(`Guardian2:  ${g2.address}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const bal = await pub.getBalance({ address: owner.address });
  console.log(`Deployer balance: ${formatEther(bal)} ETH`);
  if (bal < parseEther("0.15")) {
    console.error("Need at least 0.15 ETH to deploy all contracts and fund account.");
    process.exit(1);
  }

  // ─── 1. AirAccountCompositeValidator ─────────────────────────────────────
  console.log("\n[1/6] Deploy AirAccountCompositeValidator...");
  const cvA = loadArtifact("AirAccountCompositeValidator");
  const cvH = await wal.sendTransaction({
    data: encodeDeployData({ abi: cvA.abi, bytecode: cvA.bytecode, args: [] }),
  });
  const cvR = await waitTx(pub, cvH, "CompositeValidator");
  const compositeValidatorAddr = cvR.contractAddress!;
  console.log(`  Address: ${compositeValidatorAddr}`);

  // ─── 2. TierGuardHook ────────────────────────────────────────────────────
  console.log("\n[2/6] Deploy TierGuardHook...");
  const tghA = loadArtifact("TierGuardHook");
  const tghH = await wal.sendTransaction({
    data: encodeDeployData({ abi: tghA.abi, bytecode: tghA.bytecode, args: [] }),
  });
  const tghR = await waitTx(pub, tghH, "TierGuardHook");
  const tierGuardHookAddr = tghR.contractAddress!;
  console.log(`  Address: ${tierGuardHookAddr}`);

  // ─── 3. AgentSessionKeyValidator ─────────────────────────────────────────
  console.log("\n[3/6] Deploy AgentSessionKeyValidator...");
  const askA = loadArtifact("AgentSessionKeyValidator");
  const askH = await wal.sendTransaction({
    data: encodeDeployData({ abi: askA.abi, bytecode: askA.bytecode, args: [] }),
  });
  const askR = await waitTx(pub, askH, "AgentSessionKeyValidator");
  const agentSessionValidatorAddr = askR.contractAddress!;
  console.log(`  Address: ${agentSessionValidatorAddr}`);

  // ─── 4. AAStarAirAccountFactoryV7 ────────────────────────────────────────
  console.log("\n[4/6] Deploy AAStarAirAccountFactoryV7 (M7 r5)...");
  const fA = loadArtifact("AAStarAirAccountFactoryV7");
  const fH = await wal.sendTransaction({
    data: encodeDeployData({
      abi: fA.abi,
      bytecode: fA.bytecode,
      args: [
        ENTRYPOINT,
        COMMUNITY,
        [],
        [],
        compositeValidatorAddr,
        "0x0000000000000000000000000000000000000000" as Address,
      ],
    }),
  });
  const fR = await waitTx(pub, fH, "Factory");
  const factoryAddr = fR.contractAddress!;
  const implAddr = await pub.readContract({
    address: factoryAddr, abi: fA.abi, functionName: "implementation",
  }) as Address;
  console.log(`  Factory:        ${factoryAddr}`);
  console.log(`  Implementation: ${implAddr}`);

  // ─── 5. Deploy test account ───────────────────────────────────────────────
  console.log(`\n[5/6] Deploy test account (salt=${SALT})...`);
  const initConfig = {
    guardians: [g1.address, g2.address, "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predictedAddr = await pub.readContract({
    address: factoryAddr, abi: fA.abi, functionName: "getAddress",
    args: [owner.address, SALT, initConfig],
  }) as Address;
  console.log(`  Predicted: ${predictedAddr}`);

  const existingCode = await pub.getBytecode({ address: predictedAddr });
  if (existingCode && existingCode.length > 2) {
    console.log("  Already deployed.");
  } else {
    const cH = await wal.writeContract({
      address: factoryAddr, abi: fA.abi, functionName: "createAccount",
      args: [owner.address, SALT, initConfig],
      gas: 1_200_000n,
    });
    await waitTx(pub, cH, "createAccount");
  }
  console.log(`  Account: https://sepolia.etherscan.io/address/${predictedAddr}`);

  // ─── 6. Fund account ─────────────────────────────────────────────────────
  console.log("\n[6/6] Fund account...");
  const accBal = await pub.getBalance({ address: predictedAddr });
  console.log(`  Current balance: ${formatEther(accBal)} ETH`);
  if (accBal < parseEther("0.03")) {
    const fTx = await wal.sendTransaction({ to: predictedAddr, value: parseEther("0.05") });
    await waitTx(pub, fTx, "fund");
  } else {
    console.log("  Sufficient, skipping.");
  }

  const epH = await wal.writeContract({
    address: ENTRYPOINT,
    abi: [{ name: "depositTo", type: "function", stateMutability: "payable",
      inputs: [{ name: "account", type: "address" }], outputs: [] }],
    functionName: "depositTo",
    args: [predictedAddr],
    value: parseEther("0.02"),
  });
  await waitTx(pub, epH, "depositToEntryPoint");

  // ─── Summary ─────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(" M7 r5 Deployment Complete");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("\nAdd to .env.sepolia:");
  console.log(`AIRACCOUNT_M7_R5_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_R5_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_R5_ACCOUNT=${predictedAddr}`);
  console.log(`AIRACCOUNT_M7_R5_COMPOSITE_VALIDATOR=${compositeValidatorAddr}`);
  console.log(`AIRACCOUNT_M7_R5_TIER_GUARD_HOOK=${tierGuardHookAddr}`);
  console.log(`AIRACCOUNT_M7_R5_AGENT_SESSION_VALIDATOR=${agentSessionValidatorAddr}`);
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
