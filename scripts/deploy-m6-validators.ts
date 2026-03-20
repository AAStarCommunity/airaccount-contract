/**
 * deploy-m6-validators.ts — Deploy M6.4 + M6.6b standalone contracts to Sepolia
 *
 * Deploys:
 *   1. SessionKeyValidator.sol   (algId 0x08 — time-limited session key)
 *   2. CalldataParserRegistry.sol (per-account DeFi calldata parser registry)
 *   3. UniswapV3Parser.sol       (pure parser for exactInputSingle + exactInput)
 *
 * After deploy, registers:
 *   - SessionKeyValidator in AAStarValidator at algId 0x08
 *   - UniswapV3Parser in CalldataParserRegistry for Uniswap V3 SwapRouter02
 *
 * Run: pnpm tsx scripts/deploy-m6-validators.ts
 *
 * Add to .env.sepolia after running:
 *   SESSION_KEY_VALIDATOR=<addr>
 *   CALLDATA_PARSER_REGISTRY=<addr>
 *   UNISWAP_V3_PARSER=<addr>
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
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const RPC_URL     = process.env.SEPOLIA_RPC_URL!;

// AAStarValidator router (must register SessionKeyValidator here)
const AASTAR_VALIDATOR = (process.env.VALIDATOR_CONTRACT_ADDRESS || "") as Address;

// Uniswap V3 SwapRouter02 on Sepolia
const UNISWAP_V3_ROUTER = "0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD" as Address;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(
      resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`),
      "utf-8"
    )
  );
  return { abi: artifact.abi, bytecode: artifact.bytecode.object as Hex };
}

async function deployContract(
  walletClient: ReturnType<typeof createWalletClient>,
  publicClient: ReturnType<typeof createPublicClient>,
  label: string,
  abi: readonly unknown[],
  bytecode: Hex,
  args: unknown[] = []
): Promise<Address> {
  process.stdout.write(`  Deploying ${label}... `);
  const hash = await walletClient.deployContract({ abi, bytecode, args } as any);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) throw new Error(`${label} deploy failed`);
  console.log(`${receipt.contractAddress} (gas: ${receipt.gasUsed.toLocaleString()})`);
  return receipt.contractAddress;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });

  const bal = await publicClient.getBalance({ address: owner.address });
  console.log(`\n=== Deploy M6 Validators (Sepolia) ===`);
  console.log(`Deployer: ${owner.address}`);
  console.log(`Balance:  ${formatEther(bal)} ETH\n`);

  if (bal < 10000000000000000n) { // 0.01 ETH
    console.error("Need at least 0.01 ETH"); process.exit(1);
  }

  // ── 1. SessionKeyValidator ────────────────────────────────────────────────
  console.log("[1/4] SessionKeyValidator (algId 0x08)");
  const skv = loadArtifact("SessionKeyValidator");
  const sessionKeyValidatorAddr = await deployContract(
    walletClient, publicClient, "SessionKeyValidator", skv.abi, skv.bytecode
  );

  // ── 2. CalldataParserRegistry ─────────────────────────────────────────────
  console.log("\n[2/4] CalldataParserRegistry");
  const cpr = loadArtifact("CalldataParserRegistry");
  const calldataParserRegistryAddr = await deployContract(
    walletClient, publicClient, "CalldataParserRegistry", cpr.abi, cpr.bytecode
  );

  // ── 3. UniswapV3Parser ────────────────────────────────────────────────────
  console.log("\n[3/4] UniswapV3Parser");
  const uvp = loadArtifact("UniswapV3Parser");
  const uniswapV3ParserAddr = await deployContract(
    walletClient, publicClient, "UniswapV3Parser", uvp.abi, uvp.bytecode
  );

  // ── 4. Register UniswapV3Parser in CalldataParserRegistry ─────────────────
  console.log("\n[4/4] Register UniswapV3Parser for Uniswap SwapRouter02");
  const CALLDATA_PARSER_REGISTRY_ABI = [
    {
      name: "registerParser",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [
        { name: "target", type: "address" },
        { name: "parser", type: "address" },
      ],
      outputs: [],
    },
  ] as const;

  const regHash = await walletClient.writeContract({
    address: calldataParserRegistryAddr,
    abi: CALLDATA_PARSER_REGISTRY_ABI,
    functionName: "registerParser",
    args: [UNISWAP_V3_ROUTER, uniswapV3ParserAddr],
  });
  await publicClient.waitForTransactionReceipt({ hash: regHash });
  console.log(`  Registered: SwapRouter02 → UniswapV3Parser (tx: ${regHash})`);

  // ── 5. Register SessionKeyValidator in AAStarValidator (optional) ──────────
  if (AASTAR_VALIDATOR && AASTAR_VALIDATOR !== "") {
    console.log("\n[5/5] Register SessionKeyValidator in AAStarValidator at algId 0x08");
    const VALIDATOR_ABI = [
      {
        name: "setAlgorithm",
        type: "function",
        stateMutability: "nonpayable",
        inputs: [
          { name: "algId", type: "uint8" },
          { name: "algorithm", type: "address" },
        ],
        outputs: [],
      },
    ] as const;
    try {
      const regHash2 = await walletClient.writeContract({
        address: AASTAR_VALIDATOR,
        abi: VALIDATOR_ABI,
        functionName: "setAlgorithm",
        args: [8, sessionKeyValidatorAddr],
      });
      await publicClient.waitForTransactionReceipt({ hash: regHash2 });
      console.log(`  Registered algId 0x08 in AAStarValidator (tx: ${regHash2})`);
    } catch (e: any) {
      console.warn(`  WARN: AAStarValidator registration failed (${e.message?.slice(0, 80)})`);
      console.warn("  Manual step: call setAlgorithm(8, sessionKeyValidatorAddr) on validator");
    }
  } else {
    console.log("\n[5/5] AAStarValidator registration: SKIPPED (VALIDATOR_CONTRACT_ADDRESS not set)");
    console.log("  Manual step: call setAlgorithm(8, sessionKeyValidatorAddr) on your validator");
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("  M6 VALIDATOR DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════════════════════════════");
  console.log("  Add to .env.sepolia:");
  console.log(`  SESSION_KEY_VALIDATOR=${sessionKeyValidatorAddr}`);
  console.log(`  CALLDATA_PARSER_REGISTRY=${calldataParserRegistryAddr}`);
  console.log(`  UNISWAP_V3_PARSER=${uniswapV3ParserAddr}`);
  console.log();
  console.log("  Next steps:");
  console.log("  1. Update .env.sepolia with addresses above");
  console.log("  2. Run: pnpm tsx scripts/test-session-key-e2e.ts");
  console.log("  3. Accounts must have algId 0x08 in approvedAlgIds (already in M6 r2 factory defaults)");
  console.log("  4. CalldataParserRegistry: each account must call registerParser() per-account");
  console.log("     OR use global registry from AAStarAirAccountBase if wired at deploy time");
}

main().catch((err) => {
  console.error("Fatal:", err.message ?? err);
  process.exit(1);
});
