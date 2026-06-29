/**
 * e2e-v0.21.0.ts — v0.21.0 E2E: verify WebAuthn-native cumulative algIds (0x09/0x0a) on Sepolia.
 *
 * Tests:
 *   T1. Create a fresh account from v0.21.0 factory
 *   T2. ACCOUNT_VERSION on impl == "0.21.0"
 *   T3. clone ACCOUNT_VERSION == "0.21.0"
 *   T4. accountId == "airaccount.v7@0.21.0"
 *   T5. algId 0x09 (ALG_CUMULATIVE_T2_WA) approved ✓
 *   T6. algId 0x0a (ALG_CUMULATIVE_T3_WA) approved ✓
 *   T7–T11. Legacy algIds 0x01–0x05 still approved (no regression)
 *
 * Run: pnpm tsx scripts/e2e-v0.21.0.ts
 */

import {
  createPublicClient, createWalletClient, http,
  getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = process.env.SEPOLIA_RPC_URL as string;
const FACTORY = getAddress(process.env.AIRACCOUNT_V0210_FACTORY!);
const IMPL    = getAddress(process.env.AIRACCOUNT_V0210_IMPL!);

const owner   = privateKeyToAccount((process.env.PRIVATE_KEY_JASON ?? process.env.PRIVATE_KEY) as Hex);
const anni    = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const bob     = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);
const charlie = privateKeyToAccount(process.env.PRIVATE_KEY_CHARLIE as Hex);

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL, { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: robust, transport: http(RPC_URL, { timeout: 60_000 }) });

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return a.abi as unknown[];
}

const FACTORY_ABI = loadArtifact("AAStarAirAccountFactoryV7");
const ACCOUNT_ABI = [
  { name: "ACCOUNT_VERSION",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "accountId",          type: "function", stateMutability: "pure", inputs: [], outputs: [{ type: "string" }] },
  { name: "approvedAlgorithms", type: "function", stateMutability: "view",
    inputs: [{ name: "algId", type: "uint8" }], outputs: [{ type: "bool" }] },
] as const;

const ACCOUNT_CREATED_TOPIC = "0x33310a89c32d8cc00057ad6ef6274d2f8fe22389a992cf89983e09fc84f6cfff" as Hex;

let passed = 0, failed = 0;
function ok(label: string)  { console.log(`  [PASS] ${label}`); passed++; }
function fail(label: string, detail?: string) {
  console.error(`  [FAIL] ${label}${detail ? `: ${detail}` : ""}`); failed++;
}

async function waitTx(hash: Hex, label: string) {
  console.log(`    TX: https://sepolia.etherscan.io/tx/${hash}`);
  for (let i = 0; i < 60; i++) {
    try {
      const r = await pub.getTransactionReceipt({ hash });
      if (r) {
        if (r.status !== "success") throw new Error(`${label} reverted`);
        console.log(`    Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
        return r;
      }
    } catch (e: any) { if (String(e.message).includes("reverted")) throw e; }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`Timeout: ${label}`);
}

async function main() {
  console.log("\n=== v0.21.0 E2E — Sepolia ===");
  console.log(`Owner:   ${owner.address}`);
  console.log(`Factory: ${FACTORY}`);
  console.log(`Impl:    ${IMPL}\n`);

  // T2: ACCOUNT_VERSION on impl
  console.log("[T2] ACCOUNT_VERSION on impl...");
  const ver = await pub.readContract({ address: IMPL, abi: ACCOUNT_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (ver === "0.21.0") ok(`ACCOUNT_VERSION = "${ver}"`); else fail("ACCOUNT_VERSION", `got "${ver}"`);

  // T1: Create account
  console.log("\n[T1] Create account from v0.21.0 factory...");
  const salt = BigInt(Date.now());
  const initConfig = {
    guardians:      [anni.address, bob.address, charlie.address] as [Address, Address, Address],
    guardianP256X:  ["0x0000000000000000000000000000000000000000000000000000000000000000",
                     "0x0000000000000000000000000000000000000000000000000000000000000000",
                     "0x0000000000000000000000000000000000000000000000000000000000000000"] as [Hex, Hex, Hex],
    guardianP256Y:  ["0x0000000000000000000000000000000000000000000000000000000000000000",
                     "0x0000000000000000000000000000000000000000000000000000000000000000",
                     "0x0000000000000000000000000000000000000000000000000000000000000000"] as [Hex, Hex, Hex],
    dailyLimit:     0n,
    approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a] as number[],
    minDailyLimit:  0n,
    initialTokens:  [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
  };

  const createHash = await wal.writeContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount",
    args: [owner.address, salt, initConfig],
    gas: 3_000_000n,
  });
  const receipt = await waitTx(createHash, "createAccount");

  const createdLog = receipt.logs.find(
    l => l.address.toLowerCase() === FACTORY.toLowerCase() && l.topics[0] === ACCOUNT_CREATED_TOPIC
  );
  if (!createdLog) throw new Error("AccountCreated event not found");
  const account = getAddress("0x" + createdLog.topics[1]!.slice(26)) as Address;
  console.log(`  Account: ${account}`);
  ok("createAccount succeeded");

  // T3: clone version
  const cloneVer = await pub.readContract({ address: account, abi: ACCOUNT_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (cloneVer === "0.21.0") ok(`clone ACCOUNT_VERSION = "${cloneVer}"`); else fail("clone ACCOUNT_VERSION", `got "${cloneVer}"`);

  // T4: accountId
  const id = await pub.readContract({ address: account, abi: ACCOUNT_ABI, functionName: "accountId" }) as string;
  if (id === "airaccount.v7@0.21.0") ok(`accountId = "${id}"`); else fail("accountId", `got "${id}"`);

  // T5-T11: algId whitelist
  console.log("\n[T5-T11] algId whitelist checks...");
  const algChecks = [
    { id: 0x09, label: "ALG_CUMULATIVE_T2_WA (new)" },
    { id: 0x0a, label: "ALG_CUMULATIVE_T3_WA (new)" },
    { id: 0x04, label: "ALG_CUMULATIVE_T2 (legacy)" },
    { id: 0x05, label: "ALG_CUMULATIVE_T3 (legacy)" },
    { id: 0x02, label: "ALG_ECDSA" },
    { id: 0x01, label: "ALG_BLS" },
    { id: 0x03, label: "ALG_P256" },
  ];
  for (const { id, label } of algChecks) {
    const hex = `0x${id.toString(16).padStart(2, "0")}`;
    try {
      const approved = await pub.readContract({
        address: account, abi: ACCOUNT_ABI, functionName: "approvedAlgorithms", args: [id],
      }) as boolean;
      if (approved) ok(`${hex} (${label}): approved ✓`); else fail(`${hex} (${label})`, "not approved");
    } catch (e: any) { fail(`${hex} check`, e.shortMessage ?? e.message?.slice(0, 60)); }
  }

  console.log(`\n=== E2E Results: ${passed} passed, ${failed} failed ===`);
  console.log(`Account: https://sepolia.etherscan.io/address/${account}`);
  if (failed > 0) { console.error("FAILED — do not release."); process.exit(1); }
  console.log("All tests PASSED — ready for release.");
}

main().catch((e) => { console.error(e); process.exit(1); });
