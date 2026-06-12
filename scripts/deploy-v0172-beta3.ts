/**
 * deploy-v0172-beta3.ts — Incremental deploy for v0.17.2-beta.3
 *
 * Deploys ONLY the contracts that changed vs beta.2:
 *   1. AAStarValidator (router)       NEW — M3 governance timelock
 *   2. ForceExitModule                MODULE_VERSION + IncompatibleAccount guard
 *   3. SessionKeyValidator            MODULE_VERSION
 *   4. AAStarAirAccountFactoryV7      FACTORY_VERSION + custom errors
 *        └─ auto-deploys AAStarAirAccountV7 impl (ACCOUNT_VERSION)
 *
 * Reused from beta.2 (addresses unchanged):
 *   AAStarBLSAlgorithm  0xB82127182A855B82eED05e47536FcE568b626457
 *   AAStarBLSAggregator 0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1
 *   AirAccountDelegate  0x8603AAF6C3f07fdae810B323c95a198D796EC52E
 *   CalldataParserRegistry 0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F
 *   AgentRegistry       0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB
 *
 * Post-deploy wiring:
 *   newRouter.registerAlgorithm(0x01, blsAlgorithm)   — re-register BLS
 *   newRouter.registerAlgorithm(0x08, newSessionKeyValidator)
 *   newRouter.finalizeSetup()                          — lock router (use timelock for future changes)
 *
 * NOTE: AgentRegistry (0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB) is set-once bound
 *       to the beta.2 factory and CANNOT be rebound. New accounts via beta.3 factory
 *       will not be auto-registered in AgentRegistry (no SuperPaymaster eligibility)
 *       until a new AgentRegistry is deployed and bound to the beta.3 factory.
 *
 * Usage:
 *   pnpm tsx scripts/deploy-v0172-beta3.ts
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

// ── Unchanged beta.2 addresses ──────────────────────────────────────────────
const BLS_ALGORITHM     = "0xB82127182A855B82eED05e47536FcE568b626457" as Address;
const AGENT_REGISTRY    = "0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB" as Address;
const ENTRYPOINT        = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const ALG_BLS           = 0x01;
const ALG_SESSION_KEY   = 0x08;

// ── Env ─────────────────────────────────────────────────────────────────────
const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL,
  process.env.SEPOLIA_RPC_URL2,
  process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

// ── Helpers ──────────────────────────────────────────────────────────────────
function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return { abi: artifact.abi as unknown[], bytecode: artifact.bytecode.object as Hex };
}

function makeClients(rpcUrl: string, account: ReturnType<typeof privateKeyToAccount>) {
  const transport = http(rpcUrl, { timeout: 300_000 });
  return {
    pub: createPublicClient({ chain: sepolia, transport }),
    wal: createWalletClient({ account, chain: sepolia, transport }),
  };
}

async function waitTx(
  pub: ReturnType<typeof createPublicClient>,
  hash: Hex,
  label: string
) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 600_000 });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

async function withRetry<T>(label: string, fn: (rpcUrl: string) => Promise<T>): Promise<T> {
  for (const rpcUrl of RPC_URLS) {
    try {
      console.log(`  [${label}] RPC: ${rpcUrl.slice(0, 55)}...`);
      return await fn(rpcUrl);
    } catch (err: any) {
      console.warn(`  [${label}] failed: ${err.message?.slice(0, 80)}`);
    }
  }
  throw new Error(`All RPCs failed for: ${label}`);
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  if (!PRIVATE_KEY) { console.error("ERROR: PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set"); process.exit(1); }
  if (!COMMUNITY)   { console.error("ERROR: COMMUNITY_GUARDIAN_ADDRESS not set"); process.exit(1); }

  const deployer = privateKeyToAccount(PRIVATE_KEY);
  console.log("=== Deploy AirAccount v0.17.2-beta.3 (incremental) ===");
  console.log(`Deployer:     ${deployer.address}`);
  console.log(`Community:    ${COMMUNITY}`);
  console.log(`EntryPoint:   ${ENTRYPOINT}`);
  console.log(`BLSAlgorithm: ${BLS_ALGORITHM}  (unchanged)`);
  console.log(`AgentReg:     ${AGENT_REGISTRY}  (unchanged)`);
  console.log("");

  const { pub: pub0 } = makeClients(RPC_URLS[0], deployer);
  const bal = await pub0.getBalance({ address: deployer.address });
  console.log(`Balance:      ${formatEther(bal)} ETH`);
  if (bal < 50_000_000_000_000_000n) {
    console.error("ERROR: balance below 0.05 ETH minimum"); process.exit(1);
  }
  console.log("");

  // ── 1. Deploy AAStarValidator (new router with M3 governance timelock) ───
  console.log("[1/4] Deploy AAStarValidator router (M3 governance timelock)...");
  const routerAddr = await withRetry("AAStarValidator", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("AAStarValidator");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
      gas: 1_000_000n,
    });
    const r = await waitTx(pub, hash, "AAStarValidator");
    return r.contractAddress!;
  });
  console.log(`  AAStarValidator: ${routerAddr}\n`);

  // ── 2. Deploy ForceExitModule ─────────────────────────────────────────────
  console.log("[2/4] Deploy ForceExitModule (MODULE_VERSION + IncompatibleAccount guard)...");
  const forceExitAddr = await withRetry("ForceExitModule", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("ForceExitModule");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
      gas: 1_500_000n,
    });
    const r = await waitTx(pub, hash, "ForceExitModule");
    return r.contractAddress!;
  });
  console.log(`  ForceExitModule: ${forceExitAddr}\n`);

  // ── 3. Deploy SessionKeyValidator ────────────────────────────────────────
  console.log("[3/4] Deploy SessionKeyValidator (MODULE_VERSION)...");
  const sessionKeyAddr = await withRetry("SessionKeyValidator", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("SessionKeyValidator");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
      gas: 3_500_000n,
    });
    const r = await waitTx(pub, hash, "SessionKeyValidator");
    return r.contractAddress!;
  });
  console.log(`  SessionKeyValidator: ${sessionKeyAddr}\n`);

  // ── 4. Deploy Factory (auto-deploys Impl + Extension) ────────────────────
  console.log("[4/4] Deploy Factory + Impl (FACTORY_VERSION + ACCOUNT_VERSION + custom errors)...");
  const { factoryAddr, implAddr, extensionAddr } = await withRetry("Factory", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const fA = loadArtifact("AAStarAirAccountFactoryV7");
    const hash = await wal.sendTransaction({
      gas: 10_000_000n,
      data: encodeDeployData({
        abi: fA.abi,
        bytecode: fA.bytecode,
        args: [ENTRYPOINT, COMMUNITY, [], []],
      }),
    });
    const r = await waitTx(pub, hash, "Factory");
    const factory = r.contractAddress!;
    const impl = await pub.readContract({
      address: factory, abi: fA.abi, functionName: "implementation",
    }) as Address;
    const ext = await pub.readContract({
      address: impl,
      abi: [{ name: "agentExtension", type: "function", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" }],
      functionName: "agentExtension",
    }).catch(() => "0x0000000000000000000000000000000000000000") as Address;
    return { factoryAddr: factory, implAddr: impl, extensionAddr: ext };
  });
  console.log(`  Factory:   ${factoryAddr}`);
  console.log(`  Impl:      ${implAddr}`);
  console.log(`  Extension: ${extensionAddr}\n`);

  // ── Wiring ────────────────────────────────────────────────────────────────
  const { pub, wal } = makeClients(RPC_URLS[0], deployer);
  const routerAbi = [
    { name: "registerAlgorithm", type: "function", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [], stateMutability: "nonpayable" },
    { name: "finalizeSetup", type: "function", inputs: [], outputs: [], stateMutability: "nonpayable" },
  ];
  console.log("[Wire 1/3] newRouter.registerAlgorithm(0x01, BLS)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "registerAlgorithm", args: [ALG_BLS, BLS_ALGORITHM] });
    await waitTx(pub, hash, "registerAlgorithm(BLS)");
  }

  console.log("[Wire 2/3] newRouter.registerAlgorithm(0x08, new SessionKeyValidator)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "registerAlgorithm", args: [ALG_SESSION_KEY, sessionKeyAddr] });
    await waitTx(pub, hash, "registerAlgorithm(SessionKey)");
  }

  console.log("[Wire 3/3] newRouter.finalizeSetup() — lock router (use proposeAlgorithm for future)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "finalizeSetup", args: [] });
    await waitTx(pub, hash, "finalizeSetup");
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("");
  console.log("=== v0.17.2-beta.3 Deployment Summary ===");
  console.log(`AAStarValidator (new router):      ${routerAddr}`);
  console.log(`ForceExitModule:                   ${forceExitAddr}`);
  console.log(`SessionKeyValidator:               ${sessionKeyAddr}`);
  console.log(`AAStarAirAccountFactoryV7:         ${factoryAddr}`);
  console.log(`AAStarAirAccountV7 (impl):         ${implAddr}`);
  console.log(`AirAccountExtension:               ${extensionAddr}`);
  console.log("");
  console.log("=== Unchanged from beta.2 ===");
  console.log(`AAStarBLSAlgorithm:                ${BLS_ALGORITHM}`);
  console.log(`AgentRegistry:                     ${AGENT_REGISTRY}  (factory binding unchanged — beta.2 factory)`);
  console.log("");
  console.log("NOTES:");
  console.log("  1. Existing accounts with OLD router (0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F)");
  console.log("     must call setValidator(<newRouterAddr>) to use the new SessionKeyValidator.");
  console.log("  2. AgentRegistry.bindFactory is set-once (bound to beta.2 factory).");
  console.log("     New beta.3 accounts will NOT auto-register in AgentRegistry.");
  console.log("     A new AgentRegistry deployment is required for full beta.3 SuperPaymaster integration.");
  console.log("");
  console.log("Add addresses to DEPLOYMENT-v0.17.2-beta.3.md and update SDK issue AAStarCommunity/aastar-sdk#48");
}

main().catch((err) => { console.error(err); process.exit(1); });
