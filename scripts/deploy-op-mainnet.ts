/**
 * deploy-op-mainnet.ts — Deploy AirAccount M6 Factory to OP Mainnet (Optimism)
 *
 * Same M6 r2 codebase as Sepolia. Key differences:
 *   - Chain: OP Mainnet (chainId=10), not Sepolia
 *   - Token addresses: OP Mainnet USDC/USDT/WETH/WBTC (native bridged)
 *   - EIP-7212 P256 precompile: available on OP Mainnet (Fjord upgrade, Jun 2024)
 *   - Gas price: ~0.001–0.01 gwei (sub-cent per tx, L2 economy)
 *   - EntryPoint v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (same as Sepolia)
 *
 * Prerequisites:
 *   - forge build (need compiled artifacts)
 *   - .env.op: OP_MAINNET_RPC_URL, PRIVATE_KEY, COMMUNITY_GUARDIAN_ADDRESS (optional)
 *   - Deployer wallet funded with OP ETH (~0.005 ETH sufficient, gas is cheap)
 *
 * Usage:
 *   pnpm tsx scripts/deploy-op-mainnet.ts
 *   TOKEN_PROFILE=standard pnpm tsx scripts/deploy-op-mainnet.ts
 *
 * After deploy, add to .env.op:
 *   AIRACCOUNT_OP_FACTORY=<factory address>
 *   AIRACCOUNT_OP_IMPL=<implementation address>
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
import { optimism } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.optimism") });

// ─── Constants ─────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const CHAIN_ID = "10"; // OP Mainnet

// ─── Env ───────────────────────────────────────────────────────────────────

const RPC_URL = process.env.OPT_MAINNET_RPC ?? process.env.OP_MAINNET_RPC ?? process.env.RPC_URL ?? "https://mainnet.optimism.io";
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const COMMUNITY_GUARDIAN = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address;
const TOKEN_PROFILE = process.env.TOKEN_PROFILE ?? "standard";

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

interface TokenPreset {
  address: string;
  decimals: number;
  conservative: { tier1Limit: string; tier2Limit: string; dailyLimit: string };
  standard:     { tier1Limit: string; tier2Limit: string; dailyLimit: string };
  trader:       { tier1Limit: string; tier2Limit: string; dailyLimit: string };
}

interface TokenPresetsJson {
  chains: Record<string, { tokens: Record<string, TokenPreset> }>;
  profiles: Record<string, { _tokens: string[] }>;
}

function loadTokenPresets(profile: string, chainId: string): {
  tokens: Address[];
  configs: { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[];
} {
  const presetsPath = resolve(import.meta.dirname, "../configs/token-presets.json");
  const presets: TokenPresetsJson = JSON.parse(readFileSync(presetsPath, "utf-8"));

  const chainData = presets.chains[chainId];
  if (!chainData) {
    console.warn(`  No token presets for chainId ${chainId}, skipping token config.`);
    return { tokens: [], configs: [] };
  }

  const profileData = presets.profiles[profile];
  if (!profileData) {
    console.warn(`  Unknown profile "${profile}", skipping token config.`);
    return { tokens: [], configs: [] };
  }

  const tokens: Address[] = [];
  const configs: { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[] = [];

  for (const symbol of profileData._tokens) {
    const tokenData = chainData.tokens[symbol];
    if (!tokenData) continue;
    if (tokenData.address === "TBD") {
      console.warn(`  Skipping ${symbol}: address TBD on chain ${chainId}`);
      continue;
    }

    const limits = tokenData[profile as keyof Pick<TokenPreset, "conservative" | "standard" | "trader">];
    tokens.push(tokenData.address as Address);
    configs.push({
      tier1Limit: BigInt(limits.tier1Limit),
      tier2Limit: BigInt(limits.tier2Limit),
      dailyLimit: BigInt(limits.dailyLimit),
    });
  }

  return { tokens, configs };
}

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Deploy AirAccount M6 Factory to OP Mainnet (Optimism) ===\n");
  console.log("Chain: OP Mainnet (chainId=10)");
  console.log("EIP-7212 P256 precompile: available (Fjord upgrade, Jun 2024)");
  console.log("Gas model: L2 sub-cent (~0.001–0.01 gwei execution gas)\n");
  console.log(`  AAStarAirAccountV7:        20,900B (EIP-170 compliant)`);
  console.log(`  AAStarAirAccountFactoryV7:  9,527B`);
  console.log(`  Estimated deploy cost: ~0.001–0.003 ETH on OP\n`);

  if (!PRIVATE_KEY) {
    console.error("Missing PRIVATE_KEY. Create .env.op with PRIVATE_KEY=0x...");
    process.exit(1);
  }

  const signer = privateKeyToAccount(PRIVATE_KEY);
  console.log(`Deployer:           ${signer.address}`);
  console.log(`Community guardian: ${COMMUNITY_GUARDIAN}`);
  console.log(`Token profile:      ${TOKEN_PROFILE}`);
  console.log(`RPC:                ${RPC_URL}\n`);

  const transport = http(RPC_URL, { retryCount: 3, retryDelay: 1500 });

  const publicClient = createPublicClient({
    chain: optimism,
    transport,
    pollingInterval: 3_000,
  });

  const walletClient = createWalletClient({
    account: signer,
    chain: optimism,
    transport,
  });

  // Verify we are on the right chain
  const chainId = await publicClient.getChainId();
  if (chainId !== 10) {
    console.error(`Wrong chain! Expected OP Mainnet (10), got ${chainId}`);
    console.error("Check your OP_MAINNET_RPC_URL in .env.op");
    process.exit(1);
  }
  console.log(`Chain ID verified: ${chainId} (OP Mainnet ✓)\n`);

  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Deployer balance: ${formatEther(balance)} ETH`);

  if (balance < 1000000000000000n) { // 0.001 ETH minimum
    console.error("Need at least 0.001 ETH on OP Mainnet to deploy.");
    console.error("Bridge ETH from Ethereum: https://app.optimism.io/bridge");
    process.exit(1);
  }

  // ─── Load token presets ──────────────────────────────────────────
  console.log(`\nLoading token presets (profile: ${TOKEN_PROFILE}, chain: OP Mainnet ${CHAIN_ID})...`);
  const { tokens: tokenAddresses, configs: tokenConfigs } = loadTokenPresets(TOKEN_PROFILE, CHAIN_ID);
  if (tokenAddresses.length > 0) {
    const symbols = ["USDC", "USDT", "WETH", "WBTC", "aPNTs"];
    console.log(`  ${tokenAddresses.length} token(s) pre-configured:`);
    tokenAddresses.forEach((addr, i) => {
      const sym = symbols[i] ?? `token${i}`;
      const cfg = tokenConfigs[i];
      console.log(`    ${sym} (${addr}): tier1=${cfg.tier1Limit}, tier2=${cfg.tier2Limit}, daily=${cfg.dailyLimit}`);
    });
  } else {
    console.log("  No token presets loaded.");
  }

  // ─── Load artifact ────────────────────────────────────────────────
  console.log("\nLoading artifacts from out/ ...");
  const factoryArtifact = loadArtifact("AAStarAirAccountFactoryV7");
  console.log("  AAStarAirAccountFactoryV7 artifact loaded.\n");

  // ─── Deploy Factory ───────────────────────────────────────────────
  console.log("Deploying AAStarAirAccountFactoryV7 to OP Mainnet...");
  console.log("  (Factory constructor also deploys shared AAStarAirAccountV7 implementation)\n");

  const factoryDeployData = encodeDeployData({
    abi: factoryArtifact.abi,
    bytecode: factoryArtifact.bytecode,
    args: [
      ENTRYPOINT,
      COMMUNITY_GUARDIAN,
      tokenAddresses,
      tokenConfigs.map(c => ({ tier1Limit: c.tier1Limit, tier2Limit: c.tier2Limit, dailyLimit: c.dailyLimit })),
    ],
  });

  const factoryTxHash = await walletClient.sendTransaction({
    data: factoryDeployData,
  });
  console.log(`  TX submitted: ${factoryTxHash}`);
  console.log(`  Explorer: https://optimistic.etherscan.io/tx/${factoryTxHash}`);
  console.log("  Waiting for confirmation (~2s on OP)...");

  const factoryReceipt = await publicClient.waitForTransactionReceipt({
    hash: factoryTxHash,
  });
  const factoryAddress = factoryReceipt.contractAddress!;
  console.log(`\n  ✓ Factory deployed: ${factoryAddress}`);
  console.log(`  Gas used: ${factoryReceipt.gasUsed}`);
  console.log(`  Explorer: https://optimistic.etherscan.io/address/${factoryAddress}\n`);

  // ─── Read implementation address ─────────────────────────────────
  const implAddress = await publicClient.readContract({
    address: factoryAddress,
    abi: factoryArtifact.abi,
    functionName: "implementation",
  }) as Address;
  console.log(`  Implementation (shared): ${implAddress}`);
  console.log(`  Explorer: https://optimistic.etherscan.io/address/${implAddress}\n`);

  // ─── Verify EIP-7212 precompile ───────────────────────────────────
  console.log("Checking EIP-7212 P256 precompile availability...");
  try {
    const precompileCode = await publicClient.getCode({ address: "0x0000000000000000000000000000000000000100" });
    if (precompileCode && precompileCode !== "0x") {
      console.log("  ✓ EIP-7212 P256 precompile available at 0x100");
    } else {
      console.warn("  ⚠ EIP-7212 precompile not detected. P256/WebAuthn transactions will fail.");
      console.warn("    OP Mainnet supports P256 since Fjord upgrade (Jun 2024). Check your RPC.");
    }
  } catch {
    console.warn("  ⚠ Could not check precompile availability.");
  }

  // ─── Summary ──────────────────────────────────────────────────────
  console.log("\n=== OP Mainnet Deployment Complete ===");
  console.log(`AIRACCOUNT_OP_FACTORY=${factoryAddress}`);
  console.log(`AIRACCOUNT_OP_IMPL=${implAddress}`);
  console.log("\nAdd to .env.op:");
  console.log(`  AIRACCOUNT_OP_FACTORY=${factoryAddress}`);
  console.log(`  AIRACCOUNT_OP_IMPL=${implAddress}`);
  console.log(`  FACTORY_ADDRESS=${factoryAddress}`);
  console.log("\nVerify on Optimism Explorer:");
  console.log(`  https://optimistic.etherscan.io/address/${factoryAddress}`);
  console.log("\nNext steps:");
  console.log("  1. Run E2E tests: OP_FACTORY_ADDRESS=<addr> pnpm tsx scripts/test-op-e2e.ts");
  console.log("  2. Update docs/airaccount-comprehensive-analysis.md with OP deployment addresses");
  console.log("  3. Register aPNTs token on OP once contract address is available");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
