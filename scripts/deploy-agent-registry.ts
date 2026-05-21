/**
 * deploy-agent-registry.ts — Deploy AgentRegistry (M8.1)
 *
 * Deploys the AgentRegistry contract that maps agent execution wallets to their
 * human AirAccount owners. Used by AirAccount.setAgentWallet() and SuperPaymaster
 * for sponsorship eligibility checks.
 *
 * Usage:
 *   pnpm tsx scripts/deploy-agent-registry.ts
 *
 * Prerequisites:
 *   - .env.sepolia with PRIVATE_KEY and SEPOLIA_RPC_URL
 *   - Run `forge build` first to generate out/AgentRegistry.sol/AgentRegistry.json
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

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;

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
  pub: ReturnType<typeof createPublicClient>,
  hash: Hex,
  label: string
) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas used: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

async function tryDeploy(rpcUrl: string, owner: ReturnType<typeof privateKeyToAccount>) {
  const transport = http(rpcUrl, { timeout: 300_000 });
  const pub = createPublicClient({ chain: sepolia, transport });
  const wal = createWalletClient({ account: owner, chain: sepolia, transport });

  const art = loadArtifact("AgentRegistry");
  const hash = await wal.sendTransaction({
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
    gas: 800_000n,
  });
  const receipt = await waitTx(pub, hash, "AgentRegistry");
  return receipt.contractAddress as Address;
}

async function main() {
  if (!PRIVATE_KEY) {
    console.error("Missing PRIVATE_KEY in .env.sepolia");
    process.exit(1);
  }
  if (RPC_URLS.length === 0) {
    console.error("Missing SEPOLIA_RPC_URL in .env.sepolia");
    process.exit(1);
  }

  const owner = privateKeyToAccount(PRIVATE_KEY);

  console.log("=== Deploy AgentRegistry (M8.1) ===");
  console.log(`Deployer: ${owner.address}`);

  // Check balance on first RPC
  const pub0 = createPublicClient({ chain: sepolia, transport: http(RPC_URLS[0]) });
  const bal  = await pub0.getBalance({ address: owner.address });
  console.log(`Balance:  ${formatEther(bal)} ETH\n`);

  let agentRegistryAddr: Address | undefined;

  for (const rpcUrl of RPC_URLS) {
    try {
      console.log(`Trying RPC: ${rpcUrl.slice(0, 60)}...`);
      agentRegistryAddr = await tryDeploy(rpcUrl, owner);
      break;
    } catch (err: any) {
      console.warn(`  Failed: ${err.message?.slice(0, 100)}`);
    }
  }

  if (!agentRegistryAddr) {
    console.error("All RPCs failed.");
    process.exit(1);
  }

  console.log(`\n✓ AgentRegistry deployed at: ${agentRegistryAddr}`);
  console.log(`  Verify: https://sepolia.etherscan.io/address/${agentRegistryAddr}`);
  console.log(`\nNext step: pass this address as agentRegistry to setAgentWallet()`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
