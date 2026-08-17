/**
 * e2e-v0.31.0-enroll.ts — Deploy-success + enroll test for the v0.31.0 stack (Sepolia).
 *
 * Confirms the freshly-deployed v0.31.0 stack is wired correctly on-chain and exercises the CC-98
 * account-side enroll:
 *   1. Create a test account via the v0.31.0 Factory (direct mode, msg.sender = owner). InitConfig carries
 *      #161 tier1Limit/tier2Limit (else createAccount throws "undefined to BigInt").
 *   2. account.enrollInCommitteeValidator() → self-enrolls (msg.sender at the validator = the account).
 *   3. Read-verify: accountId==airaccount.v7@0.31.0, owner, validatorRouter, enrolledAccount[account]==true,
 *      committee validator committeeActive()==false (legacy 2-of-3), 3 registered nodes.
 *
 * Committee tier-2/3 UserOp E2E is NOT here — it needs SDK/KMS per-signer signatures (Seeder b8f3441f)
 * AND the committee-mode flip (after this enroll → dvt setEpochLength). This proves the stack + enroll only.
 *
 * Usage: pnpm tsx scripts/e2e-v0.31.0-enroll.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeFunctionData, getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const PRIORITY_FEE_FLOOR = 2_000_000_000n;
const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const RPC = process.env.SEPOLIA_RPC_URL as string;
const owner = privateKeyToAccount(PRIVATE_KEY);

function envAddr(k: string): Address { const v = process.env[k]; if (!v) throw new Error(`${k} not set`); return getAddress(v); }
const FACTORY   = envAddr("AIRACCOUNT_V0310_FACTORY");
const ROUTER    = envAddr("AIRACCOUNT_V0310_VALIDATOR_ROUTER");
const COMMITTEE = envAddr("AIRACCOUNT_V0310_COMMITTEE_VALIDATOR");

function loadAbi(name: string) {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const FACTORY_ABI = loadAbi("AAStarAirAccountFactoryV7");
const ACCOUNT_ABI = loadAbi("AAStarAirAccountV7");
const COMMITTEE_ABI = [
  { name: "committeeActive",        type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "bool" }] },
  { name: "getRegisteredNodeCount", type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "uint256" }] },
  { name: "enrolledAccount",        type: "function", stateMutability: "view", inputs: [{ type: "address" }],  outputs: [{ type: "bool" }] },
] as const;

const ZERO32 = ("0x" + "0".repeat(64)) as Hex;
const CONFIG = {
  guardians:           ["0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"] as const,
  guardianP256X:       [ZERO32, ZERO32, ZERO32] as const,
  guardianP256Y:       [ZERO32, ZERO32, ZERO32] as const,
  dailyLimit:          0n,
  approvedAlgIds:      [] as number[],
  minDailyLimit:       0n,
  initialTokens:       [] as Address[],
  initialTokenConfigs: [] as unknown[],
  tier1Limit:          0n, // #161: field MUST be present (0 = unset) or createAccount throws "undefined to BigInt"
  tier2Limit:          0n,
};

const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });

async function fees() {
  const block = await pub.getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try { tip = await pub.estimateMaxPriorityFeePerGas(); } catch { /**/ }
  const priority = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}
async function send(label: string, to: Address, data: Hex, gas: bigint) {
  const f = await fees();
  const hash = await wal.sendTransaction({ to, data, gas, ...f });
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
}

let pass = 0, fail = 0;
function check(name: string, got: unknown, want: unknown) {
  const ok = String(got).toLowerCase() === String(want).toLowerCase();
  console.log(`  ${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (want ${want})`}`);
  ok ? pass++ : fail++;
}

async function main() {
  console.log(`\n=== v0.31.0 deploy-success + enroll test — Sepolia ===`);
  console.log(`Owner/deployer: ${owner.address}\nFactory: ${FACTORY}\nCommittee validator: ${COMMITTEE}\n`);

  const salt = 310001n;
  const predicted = getAddress(await pub.readContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [owner.address, salt, CONFIG, ZERO32, ZERO32],
  }) as string);
  console.log(`Test account (salt=${salt}): ${predicted}`);

  const code = await pub.getBytecode({ address: predicted });
  if (!code || code === "0x") {
    console.log("Creating account (direct mode, msg.sender = owner)...");
    await send("createAccount", FACTORY, encodeFunctionData({
      abi: FACTORY_ABI, functionName: "createAccount", args: [owner.address, salt, CONFIG, ZERO32, ZERO32, 0n, 0n, "0x"],
    }) as Hex, 3_000_000n);
  } else {
    console.log("  [reuse] account already deployed");
  }

  // enroll (owner tx; account self-enrolls at the committee validator)
  const already = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "enrolledAccount", args: [predicted] }) as boolean;
  if (!already) {
    console.log("\nEnrolling account in committee validator...");
    await send("enrollInCommitteeValidator", predicted, encodeFunctionData({ abi: ACCOUNT_ABI, functionName: "enrollInCommitteeValidator", args: [] }) as Hex, 200_000n);
  } else {
    console.log("\n  [reuse] account already enrolled");
  }

  console.log("\n=== Verify ===");
  check("accountId", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "accountId" }), "airaccount.v7@0.31.0");
  check("account owner", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "owner" }), owner.address);
  check("validatorRouter", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "validatorRouter" }), ROUTER);
  check("enrolledAccount[account]", await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "enrolledAccount", args: [predicted] }), "true");
  check("committeeActive() (legacy mode)", await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "committeeActive" }), "false");
  const nodes = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "getRegisteredNodeCount" }) as bigint;
  check("committee registeredNodes >= 3", nodes >= 3n, "true");

  console.log(`\n=== ${fail === 0 ? "✅ PASS" : "❌ FAIL"} — ${pass} passed, ${fail} failed ===`);
  console.log(`Test account: ${predicted}`);
  if (fail === 0) console.log("Deploy confirmed + account enrolled. NEXT: send dvt the \"可翻\" signal (CC-104).");
  process.exit(fail === 0 ? 0 : 1);
}
main().catch((err) => { console.error(err); process.exit(1); });
