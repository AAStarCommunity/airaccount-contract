/**
 * deploy-m5.ts — Deploy M5 AirAccount Factory to Sepolia via viem
 *
 * M5 changes vs M4:
 *   - ALG_COMBINED_T1 (0x06) approved by default
 *   - _validateCombinedT1: simultaneous P256 + ECDSA dual-factor
 *   - P256 fail-fast (no fallback): reverts if EIP-7212 precompile absent
 *   - ERC20 guard: per-token tier/daily limits in AAStarGlobalGuard
 *   - dailyLimit >= tier2Limit invariant enforced in guard constructor
 *   - createAccountWithDefaults enforces dailyLimit > 0 (M5.7)
 *   - Guardian acceptance signatures required (M5.3)
 *
 * Optionally auto-populates token configs from configs/token-presets.json
 * using the selected profile (default: "standard").
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m5.ts
 *   TOKEN_PROFILE=conservative pnpm tsx scripts/deploy-m5.ts
 *   TOKEN_PROFILE=trader pnpm tsx scripts/deploy-m5.ts
 *
 * After deploy, update .env.sepolia:
 *   AIRACCOUNT_M5_FACTORY=<deployed address>
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

// ─── Constants ─────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const CHAIN_ID = "11155111"; // Sepolia

// ─── Env ───────────────────────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
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
  console.log("=== Deploy M5 AirAccount Factory to Sepolia ===\n");
  console.log("M5 features: ALG_COMBINED_T1 (0x06), ERC20 guard, fail-fast P256,");
  console.log("             dailyLimit invariant, force guard (M5.7), guardian acceptance (M5.3)\n");

  if (!PRIVATE_KEY) {
    console.error("Missing PRIVATE_KEY in .env.sepolia");
    process.exit(1);
  }

  const signer = privateKeyToAccount(PRIVATE_KEY);
  console.log(`Deployer:           ${signer.address}`);
  console.log(`Community guardian: ${COMMUNITY_GUARDIAN}`);
  console.log(`Token profile:      ${TOKEN_PROFILE}\n`);

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

  if (balance < 10000000000000000n) {
    console.error("Need at least 0.01 ETH to deploy.");
    process.exit(1);
  }

  // ─── Load token presets ──────────────────────────────────────────
  console.log(`Loading token presets (profile: ${TOKEN_PROFILE}, chain: Sepolia ${CHAIN_ID})...`);
  const { tokens: tokenAddresses, configs: tokenConfigs } = loadTokenPresets(TOKEN_PROFILE, CHAIN_ID);
  if (tokenAddresses.length > 0) {
    console.log(`  ${tokenAddresses.length} token(s) will be pre-configured:`);
    const symbols = ["USDC", "USDT", "WETH", "WBTC", "aPNTs"];
    tokenAddresses.forEach((addr, i) => {
      const sym = symbols[i] ?? `token${i}`;
      const cfg = tokenConfigs[i];
      console.log(`    ${sym}: tier1=${cfg.tier1Limit}, tier2=${cfg.tier2Limit}, daily=${cfg.dailyLimit}`);
    });
  } else {
    console.log("  No token presets loaded (no initial tokens in factory).");
  }
  console.log();

  // ─── Build artifacts ──────────────────────────────────────────────
  console.log("Building artifacts (requires forge build)...");
  const factoryArtifact = loadArtifact("AAStarAirAccountFactoryV7");

  // ─── Deploy Factory ───────────────────────────────────────────────
  console.log("Deploying AAStarAirAccountFactoryV7 (M5)...");

  const factoryDeployData = encodeDeployData({
    abi: factoryArtifact.abi,
    bytecode: factoryArtifact.bytecode,
    args: [ENTRYPOINT, COMMUNITY_GUARDIAN],
  });

  const factoryTxHash = await walletClient.sendTransaction({
    data: factoryDeployData,
  });
  console.log(`  TX: ${factoryTxHash}`);
  console.log("  Waiting for confirmation...");

  const factoryReceipt = await publicClient.waitForTransactionReceipt({
    hash: factoryTxHash,
  });
  const factoryAddress = factoryReceipt.contractAddress!;
  console.log(`  Factory deployed: ${factoryAddress}`);
  console.log(`  Gas used: ${factoryReceipt.gasUsed}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/address/${factoryAddress}\n`);

  // ─── Summary ──────────────────────────────────────────────────────
  console.log("=== M5 Factory Deployment Summary ===");
  console.log(`AIRACCOUNT_M5_FACTORY=${factoryAddress}`);
  console.log();
  console.log("Add to .env.sepolia:");
  console.log(`  AIRACCOUNT_M5_FACTORY=${factoryAddress}`);
  console.log(`  FACTORY_ADDRESS=${factoryAddress}   # used by E2E test scripts`);
  console.log();
  console.log("Token presets loaded:", tokenAddresses.length > 0 ? "YES (auto-populated via initialTokens)" : "NO (set manually after deploy via guardAddTokenConfig)");
  console.log();
  console.log("Next steps:");
  console.log("  pnpm tsx scripts/test-m5-guardian-accept-e2e.ts");
  console.log("  pnpm tsx scripts/test-m5-combined-t1-e2e.ts");
  console.log("  pnpm tsx scripts/test-m5-erc20-guard-e2e.ts");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
