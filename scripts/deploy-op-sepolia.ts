/**
 * deploy-op-sepolia.ts — Deploy AirAccount M7 to OP Sepolia (chainId 11155420)
 *
 * Deploys:
 *   1. AAStarAirAccountV7 implementation
 *   2. AAStarAirAccountFactoryV7
 *   3. ForceExitModule (ERC-7579 executor for L2→L1 force withdrawal)
 *
 * Same codebase as Sepolia M7. Same CREATE2 salt → same account addresses across chains.
 *
 * OP Sepolia specifics:
 *   - chainId: 11155420
 *   - EntryPoint v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (universal)
 *   - L2ToL1MessagePasser: 0x4200000000000000000000000000000000000016 (OP precompile)
 *   - Public RPC: https://sepolia.optimism.io (no API key needed)
 *   - Faucet: https://app.optimism.io/faucet (requires mainnet ETH or Superchain faucet)
 *
 * Prerequisites:
 *   - forge build
 *   - .env.sepolia (reuses PRIVATE_KEY and guardian keys)
 *   - Deployer funded on OP Sepolia (~0.01 ETH, gas is cheap on L2)
 *
 * Run: pnpm tsx scripts/deploy-op-sepolia.ts
 *
 * After deploy, add to .env.sepolia:
 *   AIRACCOUNT_OP_SEPOLIA_FACTORY=<factory>
 *   AIRACCOUNT_OP_SEPOLIA_IMPL=<impl>
 *   FORCE_EXIT_MODULE=<forceExitModule>
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { optimismSepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }

const RPC_URL = process.env.OP_SEPOLIA_RPC_URL ?? "https://sepolia.optimism.io";
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const COMMUNITY_GUARDIAN = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return { abi: artifact.abi as unknown[], bytecode: artifact.bytecode.object as Hex };
}

async function deployContract(
  client: ReturnType<typeof createWalletClient>,
  publicClient: ReturnType<typeof createPublicClient>,
  name: string,
  args: unknown[] = [],
  label = name
): Promise<Address> {
  const { abi, bytecode } = loadArtifact(name);
  console.log(`  Deploying ${label}...`);
  const hash = await client.deployContract({ abi, bytecode, args } as Parameters<typeof client.deployContract>[0]);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) throw new Error(`${label} deploy failed`);
  console.log(`  ✓ ${label}: ${receipt.contractAddress} (gas: ${receipt.gasUsed})`);
  return receipt.contractAddress;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== Deploy AirAccount M7 to OP Sepolia ===\n");

  const publicClient = createPublicClient({ chain: optimismSepolia, transport: http(RPC_URL) });
  const deployer = privateKeyToAccount(PRIVATE_KEY);
  const walletClient = createWalletClient({ account: deployer, chain: optimismSepolia, transport: http(RPC_URL) });

  const balance = await publicClient.getBalance({ address: deployer.address });
  console.log(`Deployer:  ${deployer.address}`);
  console.log(`Balance:   ${formatEther(balance)} ETH (OP Sepolia)`);
  console.log(`RPC:       ${RPC_URL}`);
  console.log(`Chain:     OP Sepolia (chainId ${optimismSepolia.id})\n`);

  if (balance < 5_000_000_000_000_000n) { // < 0.005 ETH
    console.error("Insufficient balance. Need at least 0.005 ETH on OP Sepolia.");
    console.error("Faucet: https://app.optimism.io/faucet  or  https://faucet.quicknode.com/optimism/sepolia");
    process.exit(1);
  }

  // ── Check for existing deployments ──────────────────────────────────────

  const existingFactory = process.env.AIRACCOUNT_OP_SEPOLIA_FACTORY as Address | undefined;
  const existingImpl    = process.env.AIRACCOUNT_OP_SEPOLIA_IMPL as Address | undefined;
  const existingFEM     = process.env.FORCE_EXIT_MODULE as Address | undefined;

  if (existingFactory) {
    const code = await publicClient.getBytecode({ address: existingFactory });
    if (code && code.length > 2) {
      console.log(`Reusing existing factory: ${existingFactory}`);
      const implResult2 = await publicClient.call({ to: existingFactory, data: "0x5c60da1b" as Hex });
      const implAddr2 = ("0x" + (implResult2.data ?? "0x").slice(-40)) as Address;
      console.log(`Existing impl:            ${implAddr2}`);

      let femAddr = existingFEM;
      if (!femAddr || !(await publicClient.getBytecode({ address: existingFEM! }))?.length) {
        femAddr = await deployContract(walletClient, publicClient, "ForceExitModule", [], "ForceExitModule");
      } else {
        console.log(`Reusing ForceExitModule:  ${femAddr}`);
      }

      printSummary(existingFactory, implAddr2, femAddr!);
      return;
    }
  }

  // ── Step 1: Deploy factory (factory deploys impl internally) ─────────────

  console.log("[1/2] Deploy AAStarAirAccountFactoryV7 (incl. impl)");
  // Constructor: (entryPoint, communityGuardian, defaultTokens[], defaultConfigs[], validatorModule, hookModule)
  // Use empty token arrays and address(0) modules for minimal OP Sepolia deployment.
  const factoryArgs = [
    ENTRYPOINT,
    COMMUNITY_GUARDIAN,
    [],   // defaultTokens: empty for testnet
    [],   // defaultConfigs: empty for testnet
    "0x0000000000000000000000000000000000000000" as Address, // defaultValidatorModule
    "0x0000000000000000000000000000000000000000" as Address, // defaultHookModule
  ];
  const factoryAddr = await deployContract(walletClient, publicClient, "AAStarAirAccountFactoryV7", factoryArgs, "AirAccountFactoryV7");

  // Read implementation address via raw call (selector 0x5c60da1b = implementation())
  const implResult = await publicClient.call({ to: factoryAddr, data: "0x5c60da1b" as Hex });
  const implAddr = ("0x" + (implResult.data ?? "0x").slice(-40)) as Address;
  console.log(`  Implementation (auto-deployed by factory): ${implAddr}`);

  // ── Step 2: Deploy ForceExitModule ────────────────────────────────────────

  console.log("\n[2/2] Deploy ForceExitModule");
  const femAddr = await deployContract(walletClient, publicClient, "ForceExitModule", [], "ForceExitModule");

  printSummary(factoryAddr, implAddr, femAddr);
}

function printSummary(factory: Address, impl: Address, fem: Address) {
  console.log("\n══════════════════════════════════════════");
  console.log(" OP Sepolia Deployment Summary");
  console.log("══════════════════════════════════════════\n");
  console.log(`  Factory:          ${factory}`);
  console.log(`  Implementation:   ${impl}`);
  console.log(`  ForceExitModule:  ${fem}`);
  console.log(`  EntryPoint:       0x0000000071727De22E5E9d8BAf0edAc6f37da032`);
  console.log(`  L2ToL1Passer:     0x4200000000000000000000000000000000000016`);
  console.log();
  console.log("Add to .env.sepolia:");
  console.log(`  AIRACCOUNT_OP_SEPOLIA_FACTORY=${factory}`);
  console.log(`  AIRACCOUNT_OP_SEPOLIA_IMPL=${impl}`);
  console.log(`  FORCE_EXIT_MODULE=${fem}`);
  console.log();
  console.log("Next: pnpm tsx scripts/test-force-exit-e2e.ts");
}

main().catch(e => { console.error(e); process.exit(1); });
