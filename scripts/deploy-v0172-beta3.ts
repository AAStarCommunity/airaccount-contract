/**
 * deploy-v0172-beta3.ts — Incremental deploy for v0.17.2-beta.3
 *
 * Contracts deployed (5 new + 1 re-deployed infra):
 *   1. AAStarValidator (router)       NEW — M3 governance timelock
 *   2. ForceExitModule                MODULE_VERSION + IncompatibleAccount guard
 *   3. SessionKeyValidator            MODULE_VERSION
 *   4. AAStarAirAccountFactoryV7      FACTORY_VERSION + custom errors
 *        └─ auto-deploys AAStarAirAccountV7 impl (ACCOUNT_VERSION)
 *   5. AgentRegistry                  MANDATORY re-deploy — bindFactory is set-once;
 *                                     must be re-deployed every time a new Factory is deployed
 *
 * Circular dependency resolution:
 *   Factory is deployed first (gets an address) → AgentRegistry is deployed (deployer = Anni)
 *   → agentRegistry.bindFactory(factory) → factory.setAgentRegistry(agentRegistry)
 *
 * Reused from beta.2 (addresses unchanged):
 *   AAStarBLSAlgorithm  0xB82127182A855B82eED05e47536FcE568b626457
 *   AAStarBLSAggregator 0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1
 *   AirAccountDelegate  0x8603AAF6C3f07fdae810B323c95a198D796EC52E
 *   CalldataParserRegistry 0x076EE45d2a97F70FCb2e45809DC5f9b72BB4883F
 *
 * Post-deploy wiring (5 steps):
 *   router.registerAlgorithm(0x01, blsAlgorithm)
 *   router.registerAlgorithm(0x08, sessionKeyValidator)
 *   router.finalizeSetup()                          — lock router
 *   agentRegistry.bindFactory(factory)              — MANDATORY
 *   factory.setAgentRegistry(agentRegistry)         — MANDATORY
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
const BLS_ALGORITHM  = "0xB82127182A855B82eED05e47536FcE568b626457" as Address;
const ENTRYPOINT     = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const ALG_BLS        = 0x01;
const ALG_SESSION_KEY = 0x08;

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
  console.log("=== Deploy AirAccount (incremental) ===");
  console.log(`Deployer:     ${deployer.address}`);
  console.log(`Community:    ${COMMUNITY}`);
  console.log(`EntryPoint:   ${ENTRYPOINT}`);
  console.log(`BLSAlgorithm: ${BLS_ALGORITHM}  (unchanged)`);
  console.log("");

  const { pub: pub0 } = makeClients(RPC_URLS[0], deployer);
  const bal = await pub0.getBalance({ address: deployer.address });
  console.log(`Balance:      ${formatEther(bal)} ETH`);
  if (bal < 50_000_000_000_000_000n) {
    console.error("ERROR: balance below 0.05 ETH minimum"); process.exit(1);
  }
  console.log("");

  // ── 1. Deploy AAStarValidator (new router with M3 governance timelock) ───
  console.log("[1/5] Deploy AAStarValidator router (M3 governance timelock)...");
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
  console.log("[2/5] Deploy ForceExitModule (MODULE_VERSION + IncompatibleAccount guard)...");
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
  // Gas: 10297 bytes × 200 gas/byte (EIP-170 code deposit) = 2,059,400 → need > 2M
  console.log("[3/5] Deploy SessionKeyValidator (MODULE_VERSION)...");
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
  console.log("[4/5] Deploy Factory + Impl (FACTORY_VERSION + ACCOUNT_VERSION + custom errors)...");
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

  // ── 5. Deploy AgentRegistry ───────────────────────────────────────────────
  // MANDATORY: bindFactory is set-once. A new AgentRegistry must be deployed for every
  // new Factory. Without this, new accounts cannot registerAgent and SuperPaymaster
  // will not sponsor them (isValidAccount never set).
  console.log("[5/5] Deploy AgentRegistry (MANDATORY — bindFactory is set-once per registry)...");
  const agentRegistryAddr = await withRetry("AgentRegistry", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, deployer);
    const art = loadArtifact("AgentRegistry");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
      gas: 1_500_000n,
    });
    const r = await waitTx(pub, hash, "AgentRegistry");
    return r.contractAddress!;
  });
  console.log(`  AgentRegistry: ${agentRegistryAddr}\n`);

  // ── Wiring ────────────────────────────────────────────────────────────────
  const { pub, wal } = makeClients(RPC_URLS[0], deployer);
  const routerAbi = [
    { name: "registerAlgorithm", type: "function", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [], stateMutability: "nonpayable" },
    { name: "finalizeSetup", type: "function", inputs: [], outputs: [], stateMutability: "nonpayable" },
  ];
  const registryAbi = [
    { name: "bindFactory", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" },
  ];
  const factoryAbi = [
    { name: "setAgentRegistry", type: "function", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" },
  ];

  console.log("[Wire 1/5] router.registerAlgorithm(0x01, BLS)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "registerAlgorithm", args: [ALG_BLS, BLS_ALGORITHM] });
    await waitTx(pub, hash, "registerAlgorithm(BLS)");
  }

  console.log("[Wire 2/5] router.registerAlgorithm(0x08, SessionKeyValidator)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "registerAlgorithm", args: [ALG_SESSION_KEY, sessionKeyAddr] });
    await waitTx(pub, hash, "registerAlgorithm(SessionKey)");
  }

  console.log("[Wire 3/5] router.finalizeSetup() — lock router (use proposeAlgorithm for future changes)...");
  {
    const hash = await wal.writeContract({ address: routerAddr, abi: routerAbi, functionName: "finalizeSetup", args: [] });
    await waitTx(pub, hash, "finalizeSetup");
  }

  console.log("[Wire 4/5] agentRegistry.bindFactory(factory) — MANDATORY...");
  {
    const hash = await wal.writeContract({ address: agentRegistryAddr, abi: registryAbi, functionName: "bindFactory", args: [factoryAddr] });
    await waitTx(pub, hash, "bindFactory");
  }

  console.log("[Wire 5/5] factory.setAgentRegistry(agentRegistry) — MANDATORY...");
  {
    const hash = await wal.writeContract({ address: factoryAddr, abi: factoryAbi, functionName: "setAgentRegistry", args: [agentRegistryAddr] });
    await waitTx(pub, hash, "setAgentRegistry");
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("");
  console.log("=== Deployment Summary ===");
  console.log(`AAStarValidator (router):          ${routerAddr}`);
  console.log(`ForceExitModule:                   ${forceExitAddr}`);
  console.log(`SessionKeyValidator:               ${sessionKeyAddr}`);
  console.log(`AAStarAirAccountFactoryV7:         ${factoryAddr}`);
  console.log(`AAStarAirAccountV7 (impl):         ${implAddr}`);
  console.log(`AirAccountExtension:               ${extensionAddr}`);
  console.log(`AgentRegistry:                     ${agentRegistryAddr}`);
  console.log("");
  console.log("=== Unchanged ===");
  console.log(`AAStarBLSAlgorithm:                ${BLS_ALGORITHM}`);
  console.log("");
  console.log("MIGRATION NOTE:");
  console.log("  Existing accounts pointing to the OLD router must call:");
  console.log(`  account.setValidator(${routerAddr})`);
}

main().catch((err) => { console.error(err); process.exit(1); });
