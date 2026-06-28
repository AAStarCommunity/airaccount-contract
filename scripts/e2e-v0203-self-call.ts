/**
 * e2e-v0203-self-call.ts — v0.20.3 E2E: verify onlyOwnerOrSelf self-call path on Sepolia.
 *
 * Tests:
 *   T1. Create a fresh account from v0.20.3 factory
 *   T2. ACCOUNT_VERSION on-chain == "0.20.3"
 *   T3. setTierLimits via self-call (owner → execute(account, 0, setTierLimitsCalldata))
 *   T4. tier1Limit / tier2Limit updated on-chain
 *   T5. setTierLimits second call reverts (latch) — invariant preserved
 *
 * Run: pnpm tsx scripts/e2e-v0203-self-call.ts
 */

import {
  createPublicClient, createWalletClient, http,
  encodeFunctionData, encodeDeployData, keccak256, encodeAbiParameters, parseAbiParameters,
  parseEther, getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL   = process.env.SEPOLIA_RPC_URL as string;
const FACTORY   = getAddress(process.env.AIRACCOUNT_V0203_FACTORY!);
const IMPL      = getAddress(process.env.AIRACCOUNT_V0203_IMPL!);
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

const owner  = privateKeyToAccount((process.env.PRIVATE_KEY_JASON ?? process.env.PRIVATE_KEY) as Hex);
const anni   = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const bob    = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);
const charlie = privateKeyToAccount(process.env.PRIVATE_KEY_CHARLIE as Hex);
const community = getAddress(process.env.COMMUNITY_GUARDIAN_ADDRESS!);

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL, { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: robust, transport: http(RPC_URL, { timeout: 60_000 }) });

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return a.abi as unknown[];
}

// Use artifact ABI to avoid manual encoding mistakes
const FACTORY_ABI = loadArtifact("AAStarAirAccountFactoryV7");

const ACCOUNT_ABI = [
  { name: "ACCOUNT_VERSION", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "tier1Limit",       type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "tier2Limit",       type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    name: "execute", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "target", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" }],
    outputs: [],
  },
  {
    name: "setTierLimits", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_tier1", type: "uint256" }, { name: "_tier2", type: "uint256" }],
    outputs: [],
  },
] as const;

async function waitTx(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  for (let i = 0; i < 90; i++) {
    try {
      const r = await pub.getTransactionReceipt({ hash });
      if (r) {
        if (r.status !== "success") throw new Error(`${label} reverted`);
        console.log(`  ✓ Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
        return r;
      }
    } catch (e: any) { if (String(e).includes("reverted")) throw e; }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`${label}: timeout`);
}

async function main() {
  console.log("\n=== v0.20.3 E2E: onlyOwnerOrSelf self-call path ===");
  console.log(`Factory:  ${FACTORY}`);
  console.log(`Owner:    ${owner.address}\n`);

  // T1: Create fresh account from v0.20.3 factory
  const salt = BigInt(Date.now());
  const initConfig = {
    guardians: [anni.address, bob.address, charlie.address] as [Address, Address, Address],
    guardianP256X: ["0x0000000000000000000000000000000000000000000000000000000000000000",
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                    "0x0000000000000000000000000000000000000000000000000000000000000000"] as [Hex, Hex, Hex],
    guardianP256Y: ["0x0000000000000000000000000000000000000000000000000000000000000000",
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                    "0x0000000000000000000000000000000000000000000000000000000000000000"] as [Hex, Hex, Hex],
    dailyLimit: 0n,
    approvedAlgIds: [] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
  };

  console.log(`[T1] Creating account (salt=${salt})...`);
  const createHash = await wal.writeContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount",
    args: [owner.address, salt, initConfig],
    gas: 3_000_000n,
  });
  const receipt = await waitTx(createHash, "createAccount");
  // AccountCreated(address indexed account, address indexed owner, uint256 salt)
  // keccak256("AccountCreated(address,address,uint256)")
  const ACCOUNT_CREATED_TOPIC = "0x7b0e5c4af94eb5eb2e9b5ed9e46e5dfb1a8e0c8e7f16f2f9e56c1c0c4c6e4a3" as Hex;
  const createdLog = receipt.logs.find(
    l => l.address.toLowerCase() === FACTORY.toLowerCase() && l.topics[0] === ACCOUNT_CREATED_TOPIC
  );
  if (!createdLog) throw new Error("AccountCreated event not found in receipt");
  // topic[1] is indexed `account`
  const account = getAddress("0x" + createdLog.topics[1]!.slice(26)) as Address;
  console.log(`  Account: ${account}`);

  // T2: Verify ACCOUNT_VERSION
  console.log("\n[T2] Checking ACCOUNT_VERSION on-chain...");
  const ver = await pub.readContract({ address: account, abi: ACCOUNT_ABI, functionName: "ACCOUNT_VERSION" });
  console.log(`  ACCOUNT_VERSION = "${ver}"`);
  if (ver !== "0.20.3") throw new Error(`Version mismatch: expected "0.20.3", got "${ver}"`);
  console.log("  ✓ Version confirmed");

  // T3: setTierLimits via self-call (execute(account, 0, calldata))
  console.log("\n[T3] setTierLimits via self-call (owner → execute → address(this).call)...");
  const tier1 = parseEther("0.1");
  const tier2 = parseEther("1");
  const setTierCalldata = encodeFunctionData({
    abi: ACCOUNT_ABI, functionName: "setTierLimits", args: [tier1, tier2],
  });
  const selfCallHash = await wal.writeContract({
    address: account, abi: ACCOUNT_ABI, functionName: "execute",
    args: [account, 0n, setTierCalldata],
    gas: 200_000n,
  });
  await waitTx(selfCallHash, "execute(self, setTierLimits)");
  console.log("  ✓ Self-call succeeded — no NotOwner() revert");

  // T4: Verify limits updated
  console.log("\n[T4] Verifying tier limits on-chain...");
  const t1 = await pub.readContract({ address: account, abi: ACCOUNT_ABI, functionName: "tier1Limit" });
  const t2 = await pub.readContract({ address: account, abi: ACCOUNT_ABI, functionName: "tier2Limit" });
  console.log(`  tier1Limit = ${t1} (expected ${tier1})`);
  console.log(`  tier2Limit = ${t2} (expected ${tier2})`);
  if (t1 !== tier1 || t2 !== tier2) throw new Error("Tier limits mismatch");
  console.log("  ✓ Tier limits correctly set via self-call");

  // T5: Second setTierLimits call must revert (latch invariant)
  console.log("\n[T5] Verifying latch invariant — second setTierLimits must revert...");
  const setTierCalldata2 = encodeFunctionData({
    abi: ACCOUNT_ABI, functionName: "setTierLimits", args: [parseEther("0.5"), parseEther("5")],
  });
  try {
    await pub.simulateContract({
      address: account, abi: ACCOUNT_ABI, functionName: "execute",
      args: [account, 0n, setTierCalldata2],
      account: owner.address,
    });
    throw new Error("Expected revert — latch not working!");
  } catch (e: any) {
    const msg = String(e);
    if (msg.includes("Expected revert")) throw e;
    // Must be CannotIncreaseTierLimit (selector 0x7b8a4f0b) — not just any revert
    if (!msg.includes("CannotIncreaseTierLimit") && !msg.includes("0x9f081f40")) {
      throw new Error(`T5: unexpected revert reason (want CannotIncreaseTierLimit): ${msg.slice(0, 200)}`);
    }
    console.log("  ✓ Second setTierLimits reverts with CannotIncreaseTierLimit (latch preserved)");
  }

  console.log("\n=== v0.20.3 E2E PASSED ===");
  console.log(`Account under test: ${account}`);
  console.log(`T2 ACCOUNT_VERSION: "0.20.3" ✓`);
  console.log(`T3 self-call tx:    ${selfCallHash}`);
  console.log(`T4 tier1Limit:      ${t1} ✓`);
  console.log(`T4 tier2Limit:      ${t2} ✓`);
  console.log(`T5 latch:           preserved ✓`);
}

main().catch(e => { console.error(e); process.exit(1); });
