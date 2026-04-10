/**
 * deploy-m7-r10-factory.ts — Deploy ONLY the factory for r10 (resume after step 1-3 succeeded)
 *
 * Already deployed:
 *   CompositeValidator:      0x7442631286f7a93487ccf9bebae28d37c88574c6
 *   TierGuardHook:           0xea1d2eaa73b7e6757303b29968ded26868be20b8
 *   AgentSessionKeyValidator: 0xd80c97d993ac0a3427ea9807cbfabe1435f411cd
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m7-r10-factory.ts
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

const ENTRYPOINT            = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const SALT                  = 1002n;
const COMPOSITE_VALIDATOR   = "0x7442631286f7a93487ccf9bebae28d37c88574c6" as Address;

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const G1_KEY      = process.env.PRIVATE_KEY_BOB  as Hex;
const G2_KEY      = process.env.PRIVATE_KEY_JACK as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

// Rotate through all Alchemy keys — try each in sequence with long timeout
const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL,
  process.env.SEPOLIA_RPC_URL2,
  process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

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
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 600_000 });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas used: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

async function tryDeployFactory(rpcUrl: string, owner: ReturnType<typeof privateKeyToAccount>, g1: ReturnType<typeof privateKeyToAccount>, g2: ReturnType<typeof privateKeyToAccount>): Promise<{ factoryAddr: Address; implAddr: Address }> {
  console.log(`  Trying RPC: ${rpcUrl.slice(0, 60)}...`);
  const transport = http(rpcUrl, { timeout: 300_000 });
  const pub = createPublicClient({ chain: sepolia, transport });
  const wal = createWalletClient({ account: owner, chain: sepolia, transport });

  const fA = loadArtifact("AAStarAirAccountFactoryV7");
  const fH = await wal.sendTransaction({
    gas: 8_000_000n,
    data: encodeDeployData({
      abi: fA.abi,
      bytecode: fA.bytecode,
      args: [
        ENTRYPOINT,
        COMMUNITY,
        [],
        [],
        COMPOSITE_VALIDATOR,
        "0x0000000000000000000000000000000000000000" as Address,
      ],
    }),
  });
  const fR = await waitTx(pub, fH, "Factory");
  const factoryAddr = fR.contractAddress!;
  const implAddr = await pub.readContract({
    address: factoryAddr, abi: fA.abi, functionName: "implementation",
  }) as Address;
  return { factoryAddr, implAddr };
}

async function main() {
  if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }
  if (!COMMUNITY)   { console.error("Missing COMMUNITY_GUARDIAN_ADDRESS"); process.exit(1); }

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const g1    = privateKeyToAccount(G1_KEY);
  const g2    = privateKeyToAccount(G2_KEY);

  console.log("=== Deploy r10 Factory (resume) ===");
  console.log(`Owner:    ${owner.address}`);
  console.log(`Community:${COMMUNITY}`);
  console.log(`CompositeValidator: ${COMPOSITE_VALIDATOR}\n`);

  // Check balance using first RPC
  const pub0 = createPublicClient({ chain: sepolia, transport: http(RPC_URLS[0], { timeout: 60_000 }) });
  const bal = await pub0.getBalance({ address: owner.address });
  console.log(`Deployer balance: ${formatEther(bal)} ETH\n`);

  // Try each RPC until factory deploys successfully
  let result: { factoryAddr: Address; implAddr: Address } | null = null;
  for (const rpcUrl of RPC_URLS) {
    try {
      result = await tryDeployFactory(rpcUrl, owner, g1, g2);
      break;
    } catch (err: any) {
      console.warn(`  Failed with ${rpcUrl.slice(0, 60)}: ${err.message?.slice(0, 80)}`);
    }
  }
  if (!result) {
    console.error("All RPCs failed for factory deploy.");
    process.exit(1);
  }

  const { factoryAddr, implAddr } = result;
  console.log(`\n  Factory:        ${factoryAddr}`);
  console.log(`  Implementation: ${implAddr}`);

  // Deploy test account
  const fA = loadArtifact("AAStarAirAccountFactoryV7");
  const transport = http(RPC_URLS[0], { timeout: 300_000 });
  const pub = createPublicClient({ chain: sepolia, transport });
  const wal = createWalletClient({ account: owner, chain: sepolia, transport });

  console.log(`\n[5/6] Deploy test account (salt=${SALT})...`);
  const initConfig = {
    // guardian[0] = trusted contact, guardian[1] = user device, guardian[2] = community Safe guardian
    guardians: [g1.address, g2.address, COMMUNITY] as [Address, Address, Address],
    dailyLimit: 0n,
    approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08] as number[],
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

  // Fund account
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

  // Summary
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(" M7 r10 Factory + Account Complete");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("\nAdd to .env.sepolia:");
  console.log(`AIRACCOUNT_M7_R10_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_R10_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_R10_ACCOUNT=${predictedAddr}`);
  console.log(`AIRACCOUNT_M7_R10_COMPOSITE_VALIDATOR=${COMPOSITE_VALIDATOR}`);
  console.log(`AIRACCOUNT_M7_R10_TIER_GUARD_HOOK=0xea1d2eaa73b7e6757303b29968ded26868be20b8`);
  console.log(`AIRACCOUNT_M7_R10_AGENT_SESSION_VALIDATOR=0xd80c97d993ac0a3427ea9807cbfabe1435f411cd`);
  console.log(`\n# Canonical pointers:`);
  console.log(`AIRACCOUNT_M7_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_ACCOUNT=${predictedAddr}`);
  console.log(`AIRACCOUNT_M7_AGENT_SESSION_VALIDATOR=0xd80c97d993ac0a3427ea9807cbfabe1435f411cd`);
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
