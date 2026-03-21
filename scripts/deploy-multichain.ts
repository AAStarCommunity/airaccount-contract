/**
 * deploy-multichain.ts — Deploy AirAccount factory + default modules to multiple L2s
 *
 * Deploys M7 factory + default modules to:
 *   - Sepolia (testnet)
 *   - Base Sepolia (testnet)
 *   - OP Sepolia (testnet)
 *   - Base (mainnet)
 *   - Optimism (mainnet)
 *
 * Uses CREATE2 via 0x4e59b44847b379578588920cA78FbF26c0B4956C for deterministic addresses.
 *
 * Deployed contracts per chain:
 *   1. AirAccountCompositeValidator  (validator module)
 *   2. TierGuardHook                 (hook module)
 *   3. ForceExitModule               (executor module, C10)
 *   4. AAStarAirAccountV7            (account implementation)
 *   5. AAStarAirAccountFactoryV7     (clone factory)
 *
 * Usage:
 *   pnpm tsx scripts/deploy-multichain.ts --testnet
 *   pnpm tsx scripts/deploy-multichain.ts --mainnet
 *   pnpm tsx scripts/deploy-multichain.ts          # deploys to all chains
 *
 * Results written to docs/multichain-deployment.md
 */

import { config as dotenvConfig } from "dotenv";
import { resolve } from "path";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeDeployData,
  keccak256,
  concat,
  toHex,
  formatEther,
  type Address,
  type Hex,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  sepolia,
  baseSepolia,
  optimismSepolia,
  base,
  optimism,
} from "viem/chains";

// Load env from .env.sepolia (extends to include all RPC URLs + PRIVATE_KEY)
dotenvConfig({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Chain Configs ─────────────────────────────────────────────────────────

interface ChainConfig {
  name: string;
  rpcEnv: string;
  chainId: number;
  entryPoint: Address;
  viemChain: Chain;
  isTestnet: boolean;
}

const CHAIN_CONFIGS: ChainConfig[] = [
  {
    name: "sepolia",
    rpcEnv: "SEPOLIA_RPC_URL",
    chainId: 11155111,
    entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    viemChain: sepolia,
    isTestnet: true,
  },
  {
    name: "base-sepolia",
    rpcEnv: "BASE_SEPOLIA_RPC_URL",
    chainId: 84532,
    entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    viemChain: baseSepolia,
    isTestnet: true,
  },
  {
    name: "op-sepolia",
    rpcEnv: "OP_SEPOLIA_RPC_URL",
    chainId: 11155420,
    entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    viemChain: optimismSepolia,
    isTestnet: true,
  },
  {
    name: "base",
    rpcEnv: "BASE_RPC_URL",
    chainId: 8453,
    entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    viemChain: base,
    isTestnet: false,
  },
  {
    name: "optimism",
    rpcEnv: "OP_MAINNET_RPC_URL",
    chainId: 10,
    entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    viemChain: optimism,
    isTestnet: false,
  },
];

// ─── Constants ─────────────────────────────────────────────────────────────

// Arachnid deterministic CREATE2 factory (deployed on all EVM chains)
const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C" as Address;

// Zero address constant
const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as Address;

// ─── Artifact Loader ───────────────────────────────────────────────────────

function loadArtifact(contractName: string): { abi: unknown[]; bytecode: Hex } {
  const artifactPath = resolve(
    import.meta.dirname,
    `../out/${contractName}.sol/${contractName}.json`
  );
  const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
  return {
    abi: artifact.abi as unknown[],
    bytecode: artifact.bytecode.object as Hex,
  };
}

// ─── CREATE2 Address Prediction ────────────────────────────────────────────

function predictCreate2Address(salt: Hex, initCode: Hex): Address {
  const initCodeHash = keccak256(initCode);
  const hash = keccak256(
    concat(["0xff", CREATE2_FACTORY, salt, initCodeHash])
  );
  return `0x${hash.slice(-40)}` as Address;
}

function makeSalt(deployer: Address, label: string, chainId: number): Hex {
  return keccak256(
    concat([deployer, toHex(chainId, { size: 32 }), toHex(label)])
  );
}

// ─── Deploy via Arachnid CREATE2 ───────────────────────────────────────────

async function deployViaCreate2(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  salt: Hex,
  initCode: Hex,
  label: string
): Promise<{ address: Address; alreadyDeployed: boolean }> {
  const predicted = predictCreate2Address(salt, initCode);

  // Check if already deployed
  const existingCode = await publicClient.getBytecode({ address: predicted });
  if (existingCode && existingCode.length > 2) {
    console.log(`  [${label}] Already deployed at ${predicted}`);
    return { address: predicted, alreadyDeployed: true };
  }

  console.log(`  [${label}] Deploying to ${predicted}...`);

  const callData = concat([salt, initCode]) as Hex;

  const txHash = await walletClient.sendTransaction({
    to: CREATE2_FACTORY,
    data: callData,
    gas: 10_000_000n,
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

  if (receipt.status !== "success") {
    throw new Error(`  [${label}] Deploy TX reverted: ${txHash}`);
  }

  // Verify deployment
  const deployedCode = await publicClient.getBytecode({ address: predicted });
  if (!deployedCode || deployedCode.length <= 2) {
    throw new Error(`  [${label}] Bytecode missing after TX — check gas or constructor revert`);
  }

  console.log(`  [${label}] Deployed (gas: ${receipt.gasUsed})`);
  return { address: predicted, alreadyDeployed: false };
}

// ─── Per-Chain Deployment ──────────────────────────────────────────────────

interface ChainDeployResult {
  chain: string;
  chainId: number;
  compositeValidator: Address;
  tierGuardHook: Address;
  forceExitModule: Address;
  implementation: Address;
  factory: Address;
  status: "success" | "skipped" | "error";
  error?: string;
}

async function deployToChain(
  cfg: ChainConfig,
  deployerKey: Hex
): Promise<ChainDeployResult> {
  const rpcUrl = process.env[cfg.rpcEnv];
  if (!rpcUrl) {
    console.log(`\n[${cfg.name}] SKIPPED — ${cfg.rpcEnv} not set in env`);
    return {
      chain: cfg.name,
      chainId: cfg.chainId,
      compositeValidator: ZERO_ADDR,
      tierGuardHook: ZERO_ADDR,
      forceExitModule: ZERO_ADDR,
      implementation: ZERO_ADDR,
      factory: ZERO_ADDR,
      status: "skipped",
    };
  }

  console.log(`\n${"─".repeat(60)}`);
  console.log(`Deploying to: ${cfg.name} (chainId=${cfg.chainId})`);
  console.log(`${"─".repeat(60)}`);

  const signer = privateKeyToAccount(deployerKey);

  const publicClient = createPublicClient({
    chain: cfg.viemChain,
    transport: http(rpcUrl),
  });

  const walletClient = createWalletClient({
    account: signer,
    chain: cfg.viemChain,
    transport: http(rpcUrl),
  });

  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`  Deployer: ${signer.address}`);
  console.log(`  Balance:  ${formatEther(balance)} ETH`);

  if (balance === 0n) {
    console.log(`  [${cfg.name}] SKIPPED — deployer has zero balance`);
    return {
      chain: cfg.name,
      chainId: cfg.chainId,
      compositeValidator: ZERO_ADDR,
      tierGuardHook: ZERO_ADDR,
      forceExitModule: ZERO_ADDR,
      implementation: ZERO_ADDR,
      factory: ZERO_ADDR,
      status: "skipped",
      error: "Zero balance",
    };
  }

  try {
    // Load artifacts (built by forge build before this script runs)
    const compositeValidatorArtifact = loadArtifact("AirAccountCompositeValidator");
    const tierGuardHookArtifact      = loadArtifact("TierGuardHook");
    const forceExitModuleArtifact    = loadArtifact("ForceExitModule");
    const accountArtifact            = loadArtifact("AAStarAirAccountV7");
    const factoryArtifact            = loadArtifact("AAStarAirAccountFactoryV7");

    // ── 1. AirAccountCompositeValidator ───────────────────────────────────
    const compositeValidatorInitCode = encodeDeployData({
      abi: compositeValidatorArtifact.abi,
      bytecode: compositeValidatorArtifact.bytecode,
      args: [],
    });
    const cvSalt = makeSalt(signer.address, "composite-validator-v1", cfg.chainId);
    const { address: compositeValidatorAddr } = await deployViaCreate2(
      publicClient,
      walletClient,
      cvSalt,
      compositeValidatorInitCode,
      "AirAccountCompositeValidator"
    );

    // ── 2. TierGuardHook ──────────────────────────────────────────────────
    const tierGuardHookInitCode = encodeDeployData({
      abi: tierGuardHookArtifact.abi,
      bytecode: tierGuardHookArtifact.bytecode,
      args: [],
    });
    const tghSalt = makeSalt(signer.address, "tier-guard-hook-v1", cfg.chainId);
    const { address: tierGuardHookAddr } = await deployViaCreate2(
      publicClient,
      walletClient,
      tghSalt,
      tierGuardHookInitCode,
      "TierGuardHook"
    );

    // ── 3. ForceExitModule ────────────────────────────────────────────────
    const forceExitModuleInitCode = encodeDeployData({
      abi: forceExitModuleArtifact.abi,
      bytecode: forceExitModuleArtifact.bytecode,
      args: [],
    });
    const femSalt = makeSalt(signer.address, "force-exit-module-v1", cfg.chainId);
    const { address: forceExitModuleAddr } = await deployViaCreate2(
      publicClient,
      walletClient,
      femSalt,
      forceExitModuleInitCode,
      "ForceExitModule"
    );

    // ── 4. AAStarAirAccountV7 (implementation) ────────────────────────────
    // AAStarAirAccountV7 has a no-arg constructor; clones call initialize() post-deploy.
    // Note: the factory also deploys its own implementation internally via `new AAStarAirAccountV7()`.
    // This separate CREATE2 deployment provides a stable reference address.
    const implInitCode = accountArtifact.bytecode;
    const implSalt = makeSalt(signer.address, "airaccount-v7-impl-v1", cfg.chainId);
    const { address: implAddr } = await deployViaCreate2(
      publicClient,
      walletClient,
      implSalt,
      implInitCode,
      "AAStarAirAccountV7 (impl)"
    );

    // ── 5. AAStarAirAccountFactoryV7 ──────────────────────────────────────
    const factoryInitCode = encodeDeployData({
      abi: factoryArtifact.abi,
      bytecode: factoryArtifact.bytecode,
      args: [
        cfg.entryPoint,
        ZERO_ADDR,   // communityGuardian (configure post-deploy)
        [],          // defaultTokens (none for now)
        [],          // defaultTokenConfigs
        compositeValidatorAddr,
        tierGuardHookAddr,
      ],
    });
    const factorySalt = makeSalt(signer.address, "airaccount-factory-v7-v1", cfg.chainId);
    const { address: factoryAddr } = await deployViaCreate2(
      publicClient,
      walletClient,
      factorySalt,
      factoryInitCode,
      "AAStarAirAccountFactoryV7"
    );

    console.log(`\n  ${cfg.name} deployment complete:`);
    console.log(`    CompositeValidator : ${compositeValidatorAddr}`);
    console.log(`    TierGuardHook      : ${tierGuardHookAddr}`);
    console.log(`    ForceExitModule    : ${forceExitModuleAddr}`);
    console.log(`    Implementation     : ${implAddr}`);
    console.log(`    Factory            : ${factoryAddr}`);

    return {
      chain: cfg.name,
      chainId: cfg.chainId,
      compositeValidator: compositeValidatorAddr,
      tierGuardHook: tierGuardHookAddr,
      forceExitModule: forceExitModuleAddr,
      implementation: implAddr,
      factory: factoryAddr,
      status: "success",
    };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`  [${cfg.name}] ERROR: ${msg}`);
    return {
      chain: cfg.name,
      chainId: cfg.chainId,
      compositeValidator: ZERO_ADDR,
      tierGuardHook: ZERO_ADDR,
      forceExitModule: ZERO_ADDR,
      implementation: ZERO_ADDR,
      factory: ZERO_ADDR,
      status: "error",
      error: msg,
    };
  }
}

// ─── Markdown Report Generator ────────────────────────────────────────────

function generateMarkdownReport(results: ChainDeployResult[]): string {
  const now = new Date().toISOString();

  const rows = results.map((r) => {
    const status =
      r.status === "success"
        ? "✅"
        : r.status === "skipped"
        ? "⏭️ skipped"
        : `❌ ${r.error ?? "error"}`;
    return [
      r.chain,
      String(r.chainId),
      r.compositeValidator,
      r.tierGuardHook,
      r.forceExitModule,
      r.factory,
      status,
    ];
  });

  const header = [
    "| Chain | ChainId | CompositeValidator | TierGuardHook | ForceExitModule | Factory | Status |",
    "|-------|---------|-------------------|---------------|-----------------|---------|--------|",
  ];

  const tableRows = rows.map(
    ([chain, id, cv, tgh, fem, factory, status]) =>
      `| ${chain} | ${id} | \`${cv}\` | \`${tgh}\` | \`${fem}\` | \`${factory}\` | ${status} |`
  );

  return `# AirAccount Multi-Chain Deployment

> Generated: ${now}
> Deployer: Uses \`PRIVATE_KEY\` from env.

## Deployed Addresses

${header.join("\n")}
${tableRows.join("\n")}

## Contract Roles

| Contract | Module Type | Purpose |
|----------|-------------|---------|
| AirAccountCompositeValidator | Validator (type 1) | Weighted/cumulative signature validation |
| TierGuardHook | Hook (type 3) | Tier-based spending limit enforcement |
| ForceExitModule | Executor (type 2) | L2→L1 forced withdrawal with 2-of-3 guardian protection |
| AAStarAirAccountV7 | Implementation | Shared implementation for EIP-1167 clones |
| AAStarAirAccountFactoryV7 | Factory | Deterministic clone factory with default modules |

## Notes

- All contracts deployed via [Arachnid CREATE2 factory](https://github.com/Arachnid/deterministic-deployment-proxy) for deterministic addresses.
- Addresses may differ across chains due to \`chainId\` in the salt derivation.
- ForceExitModule supports OP Stack (L2_TYPE=1) and Arbitrum (L2_TYPE=2) exit paths.
- EntryPoint: \`0x0000000071727De22E5E9d8BAf0edAc6f37da032\` (ERC-4337 v0.7)
`;
}

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== AirAccount Multi-Chain Deployment ===\n");

  const args = process.argv.slice(2);
  const testnetsOnly = args.includes("--testnet");
  const mainnetsOnly = args.includes("--mainnet");

  const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex | undefined;
  if (!PRIVATE_KEY) {
    console.error("ERROR: PRIVATE_KEY not set in environment");
    process.exit(1);
  }

  // Select chains based on flags
  let targets = CHAIN_CONFIGS;
  if (testnetsOnly) {
    targets = CHAIN_CONFIGS.filter((c) => c.isTestnet);
    console.log("Mode: testnets only");
  } else if (mainnetsOnly) {
    targets = CHAIN_CONFIGS.filter((c) => !c.isTestnet);
    console.log("Mode: mainnets only");
  } else {
    console.log("Mode: all chains");
  }

  console.log(`Chains: ${targets.map((c) => c.name).join(", ")}\n`);

  const results: ChainDeployResult[] = [];

  for (const chainCfg of targets) {
    const result = await deployToChain(chainCfg, PRIVATE_KEY);
    results.push(result);
  }

  // ─── Summary table ───────────────────────────────────────────────────
  console.log("\n\n=== DEPLOYMENT SUMMARY ===");
  console.log(
    `${"Chain".padEnd(14)} ${"ChainId".padEnd(10)} ${"Status".padEnd(10)} Factory`
  );
  console.log("─".repeat(80));
  for (const r of results) {
    const statusStr =
      r.status === "success"
        ? "OK"
        : r.status === "skipped"
        ? "SKIPPED"
        : "ERROR";
    console.log(
      `${r.chain.padEnd(14)} ${String(r.chainId).padEnd(10)} ${statusStr.padEnd(10)} ${r.factory}`
    );
  }

  // ─── Write markdown report ────────────────────────────────────────────
  const docsDir = resolve(import.meta.dirname, "../docs");
  try {
    mkdirSync(docsDir, { recursive: true });
  } catch {}

  const reportPath = resolve(docsDir, "multichain-deployment.md");
  writeFileSync(reportPath, generateMarkdownReport(results), "utf-8");
  console.log(`\nReport written to: ${reportPath}`);

  const errorCount = results.filter((r) => r.status === "error").length;
  if (errorCount > 0) {
    console.error(`\n${errorCount} chain(s) failed.`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Fatal:", err instanceof Error ? err.message : err);
  process.exit(1);
});
