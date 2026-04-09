/**
 * deploy-m7-r11.ts — Deploy r11: AgentSessionKeyValidator + Factory/Impl
 *
 * Changes vs r10 (PR #12 review fixes):
 *   AgentSessionKeyValidator:
 *     - delegateSession() now takes explicit `account` param (MEDIUM: cross-account overwrite)
 *     - velocity rate cross-multiply comparison (HIGH: window bypass)
 *     - velocityLimit>0 && velocityWindow==0 guard in grantAgentSession (LOW)
 *     - SESSION_SIG_LENGTH: != → < (LOW)
 *
 *   AAStarAirAccountV7 (Impl changed, Factory must be redeployed):
 *     - _callLifecycle: assembly removed, uses abi.encodeWithSelector (LOW)
 *     - uninstallModule: sigsRequired = min(_guardianCount, 2) (MEDIUM: guardian lock)
 *
 * Reused from r10 (no changes):
 *   CompositeValidator:  0x7442631286f7a93487ccf9bebae28d37c88574c6
 *   TierGuardHook:       0xea1d2eaa73b7e6757303b29968ded26868be20b8
 *
 * Usage:
 *   pnpm tsx scripts/deploy-m7-r11.ts
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
  fallback,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT          = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const COMPOSITE_VALIDATOR = "0x7442631286f7a93487ccf9bebae28d37c88574c6" as Address;  // r10, unchanged
const TIER_GUARD_HOOK     = "0xea1d2eaa73b7e6757303b29968ded26868be20b8" as Address;  // r10, unchanged
const ACCOUNT_SALT        = 1004n;  // fresh account, no stale module state

const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const G1_KEY      = process.env.PRIVATE_KEY_BOB  as Hex;
const G2_KEY      = process.env.PRIVATE_KEY_JACK as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

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

function makeClients(rpcUrl: string, owner: ReturnType<typeof privateKeyToAccount>) {
  const transport = http(rpcUrl, { timeout: 300_000 });
  return {
    pub: createPublicClient({ chain: sepolia, transport }),
    wal: createWalletClient({ account: owner, chain: sepolia, transport }),
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
  console.log(`  Gas used: ${receipt.gasUsed}  Block: ${receipt.blockNumber}`);
  return receipt;
}

async function deployWithRetry<T>(
  label: string,
  fn: (rpcUrl: string) => Promise<T>
): Promise<T> {
  for (const rpcUrl of RPC_URLS) {
    try {
      console.log(`  [${label}] Trying RPC: ${rpcUrl.slice(0, 60)}...`);
      return await fn(rpcUrl);
    } catch (err: any) {
      console.warn(`  [${label}] Failed: ${err.message?.slice(0, 80)}`);
    }
  }
  throw new Error(`All RPCs failed for: ${label}`);
}

async function main() {
  if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }
  if (!COMMUNITY)   { console.error("Missing COMMUNITY_GUARDIAN_ADDRESS"); process.exit(1); }

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const g1    = privateKeyToAccount(G1_KEY);
  const g2    = privateKeyToAccount(G2_KEY);

  console.log("=== Deploy M7 r11 (PR #12 review fixes) ===");
  console.log(`Owner:     ${owner.address}`);
  console.log(`Community: ${COMMUNITY}`);
  console.log(`Reusing CompositeValidator: ${COMPOSITE_VALIDATOR}`);
  console.log(`Reusing TierGuardHook:      ${TIER_GUARD_HOOK}\n`);

  // Check balance
  const { pub: pub0 } = makeClients(RPC_URLS[0], owner);
  const bal = await pub0.getBalance({ address: owner.address });
  console.log(`Deployer balance: ${formatEther(bal)} ETH\n`);

  // ── Step 1: Deploy AgentSessionKeyValidator ──────────────────────────────
  console.log("[1/4] Deploy AgentSessionKeyValidator (r11 — delegateSession+account param, velocity rate fix)...");
  const agentValidatorAddr = await deployWithRetry("AgentSessionKeyValidator", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, owner);
    const art = loadArtifact("AgentSessionKeyValidator");
    const hash = await wal.sendTransaction({
      data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args: [] }),
      gas: 2_000_000n,
    });
    const r = await waitTx(pub, hash, "AgentSessionKeyValidator");
    return r.contractAddress!;
  });
  console.log(`  AgentSessionKeyValidator: ${agentValidatorAddr}\n`);

  // ── Step 2: Deploy Factory (deploys new Impl internally) ─────────────────
  console.log("[2/4] Deploy Factory + Impl (r11 — _callLifecycle fix, uninstall guardian-count fix)...");
  const { factoryAddr, implAddr } = await deployWithRetry("Factory", async (rpcUrl) => {
    const { pub, wal } = makeClients(rpcUrl, owner);
    const fA = loadArtifact("AAStarAirAccountFactoryV7");
    const hash = await wal.sendTransaction({
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
    const r = await waitTx(pub, hash, "Factory");
    const factory = r.contractAddress!;
    const impl = await pub.readContract({
      address: factory, abi: fA.abi, functionName: "implementation",
    }) as Address;
    return { factoryAddr: factory, implAddr: impl };
  });
  console.log(`  Factory: ${factoryAddr}`);
  console.log(`  Impl:    ${implAddr}\n`);

  // ── Step 3: Create test account (salt=1004) ────────────────────────────────
  console.log(`[3/4] Create test account (salt=${ACCOUNT_SALT})...`);
  const { pub, wal } = makeClients(RPC_URLS[0], owner);
  const fA = loadArtifact("AAStarAirAccountFactoryV7");

  const initConfig = {
    guardians:          [g1.address, g2.address, "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
    dailyLimit:         0n,
    approvedAlgIds:     [1, 2, 3, 4, 5, 6, 7, 8],
    minDailyLimit:      0n,
    initialTokens:      [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predicted = await pub.readContract({
    address: factoryAddr, abi: fA.abi, functionName: "getAddress",
    args: [owner.address, ACCOUNT_SALT, initConfig],
  }) as Address;
  console.log(`  Predicted: ${predicted}`);

  const code = await pub.getBytecode({ address: predicted });
  if (code && code.length > 2) {
    console.log("  Already deployed.");
  } else {
    let createHash: Hex | null = null;
    for (const rpcUrl of RPC_URLS) {
      try {
        const { wal: w, pub: p } = makeClients(rpcUrl, owner);
        createHash = await w.writeContract({
          address: factoryAddr, abi: fA.abi, functionName: "createAccount",
          args: [owner.address, ACCOUNT_SALT, initConfig], gas: 1_200_000n,
        });
        await waitTx(p, createHash, "createAccount");
        break;
      } catch (e: any) {
        console.warn(`  createAccount failed on ${rpcUrl.slice(0, 60)}: ${e.message?.slice(0, 60)}`);
      }
    }
    if (!createHash) throw new Error("createAccount failed on all RPCs");
  }

  // ── Step 4: Fund account ──────────────────────────────────────────────────
  console.log("\n[4/4] Fund account...");
  const accBal = await pub.getBalance({ address: predicted });
  console.log(`  ETH balance: ${formatEther(accBal)} ETH`);
  if (accBal < parseEther("0.03")) {
    const fTx = await wal.sendTransaction({ to: predicted, value: parseEther("0.05") });
    await waitTx(pub, fTx, "fund");
    console.log("  Funded +0.05 ETH");
  } else {
    console.log("  Sufficient, skipping.");
  }

  const epH = await wal.writeContract({
    address: ENTRYPOINT,
    abi: [{ name: "depositTo", type: "function", stateMutability: "payable",
      inputs: [{ name: "account", type: "address" }], outputs: [] }],
    functionName: "depositTo", args: [predicted], value: parseEther("0.02"),
  });
  await waitTx(pub, epH, "depositToEntryPoint");
  console.log("  EP deposit +0.02 ETH");

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(" M7 r11 Deploy Complete");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("\nAdd to .env.sepolia:\n");
  console.log(`# r11 — PR #12 review fixes: velocity rate, cross-account delegation, guardian lock, lifecycle assembly (2026-04-09)`);
  console.log(`AIRACCOUNT_M7_R11_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_R11_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_R11_ACCOUNT=${predicted}`);
  console.log(`AIRACCOUNT_M7_R11_COMPOSITE_VALIDATOR=${COMPOSITE_VALIDATOR}`);
  console.log(`AIRACCOUNT_M7_R11_TIER_GUARD_HOOK=${TIER_GUARD_HOOK}`);
  console.log(`AIRACCOUNT_M7_R11_AGENT_SESSION_VALIDATOR=${agentValidatorAddr}`);
  console.log(`# Canonical M7 pointers — update to r11`);
  console.log(`AIRACCOUNT_M7_FACTORY=${factoryAddr}`);
  console.log(`AIRACCOUNT_M7_IMPL=${implAddr}`);
  console.log(`AIRACCOUNT_M7_ACCOUNT=${predicted}`);
  console.log(`AIRACCOUNT_M7_AGENT_SESSION_VALIDATOR=${agentValidatorAddr}`);
  console.log(`AIRACCOUNT_M7_COMPOSITE_VALIDATOR=${COMPOSITE_VALIDATOR}`);
  console.log(`AIRACCOUNT_M7_TIER_GUARD_HOOK=${TIER_GUARD_HOOK}`);
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
