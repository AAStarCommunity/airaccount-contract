/**
 * e2e-v0.22.0.ts — v0.22.0 E2E: verify Factory Passkey Bootstrap on Sepolia.
 *
 * Tests:
 *   T1.  ACCOUNT_VERSION on impl == "0.22.0"
 *   T2.  impl.validatorRouter() == VALIDATOR_ROUTER (P1: baked-in immutable)
 *   T3.  Create account (no P256 key, direct mode): createAccount(owner, salt, config, 0, 0, 0, 0, "0x")
 *   T4.  clone ACCOUNT_VERSION == "0.22.0"
 *   T5.  accountId == "airaccount.v7@0.22.0"
 *   T6.  account.validator() == VALIDATOR_ROUTER (P1: auto-wired at birth)
 *   T7.  account.p256KeyX() == bytes32(0) (no key passed → not set)
 *   T8.  Create account (with P256 key): createAccount(owner, salt2, config, PX, PY, 0, 0, "0x")
 *   T9.  account2.p256KeyX() == PX (key set atomically at birth)
 *   T10. account2.p256KeyY() == PY
 *   T11. getAddress(owner, salt, config, 0, 0) != getAddress(owner, salt, config, PX, PY) (diff passkey → diff addr)
 *   T12. algId 0x09 (ALG_CUMULATIVE_T2_WA) approved ✓
 *   T13. algId 0x0a (ALG_CUMULATIVE_T3_WA) approved ✓
 *   T14. algId 0x04 (ALG_CUMULATIVE_T2) approved ✓
 *   T15. algId 0x05 (ALG_CUMULATIVE_T3) approved ✓
 *   T16. algId 0x02 (ALG_ECDSA) approved ✓
 *   T17. algId 0x01 (ALG_BLS) approved ✓
 *   T18. algId 0x03 (ALG_P256) approved ✓
 *   T19. algId 0x06 (ALG_COMBINED_T1) approved ✓
 *   T20. algId 0x07 (ALG_WEIGHTED) approved ✓
 *   T21. algId 0x08 (ALG_SESSION_KEY) approved ✓
 *
 * Run: pnpm tsx scripts/e2e-v0.22.0.ts
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

const RPC_URL        = process.env.SEPOLIA_RPC_URL as string;
const FACTORY        = getAddress(process.env.AIRACCOUNT_V0220_FACTORY!);
const IMPL           = getAddress(process.env.AIRACCOUNT_V0220_IMPL!);
const VALIDATOR_ROUTER = getAddress(process.env.AIRACCOUNT_V0220_VALIDATOR_ROUTER!);

const owner   = privateKeyToAccount((process.env.PRIVATE_KEY_JASON ?? process.env.PRIVATE_KEY) as Hex);
const anni    = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const bob     = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);
const charlie = privateKeyToAccount(process.env.PRIVATE_KEY_CHARLIE as Hex);

// Deterministic test P256 key (not a real key — just for testing key-folding into salt).
const TEST_PX = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" as Hex;
const TEST_PY = "0xcafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe" as Hex;

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL, { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: robust, transport: http(RPC_URL, { timeout: 60_000 }) });

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return a.abi as unknown[];
}

const FACTORY_ABI = loadArtifact("AAStarAirAccountFactoryV7");
const IMPL_ABI = [
  { name: "ACCOUNT_VERSION",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "validatorRouter",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const ACCOUNT_ABI = [
  { name: "ACCOUNT_VERSION",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { name: "accountId",          type: "function", stateMutability: "pure", inputs: [], outputs: [{ type: "string" }] },
  { name: "validator",          type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "p256KeyX",           type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { name: "p256KeyY",           type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  { name: "approvedAlgorithms", type: "function", stateMutability: "view",
    inputs: [{ name: "algId", type: "uint8" }], outputs: [{ type: "bool" }] },
] as const;

const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
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

function makeConfig(guardians: [Address, Address, Address]) {
  return {
    guardians,
    guardianP256X:  [ZERO32, ZERO32, ZERO32] as [Hex, Hex, Hex],
    guardianP256Y:  [ZERO32, ZERO32, ZERO32] as [Hex, Hex, Hex],
    dailyLimit:     0n,
    approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a] as number[],
    minDailyLimit:  0n,
    initialTokens:  [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
  };
}

async function createAccountOnChain(salt: bigint, px: Hex, py: Hex, label: string): Promise<Address> {
  const cfg = makeConfig([anni.address, bob.address, charlie.address]);
  const hash = await wal.writeContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount",
    // ownerSig = "0x" → direct mode (msg.sender == owner, no KMS sig required)
    args: [owner.address, salt, cfg, px, py, 0n, 0n, "0x" as Hex],
    gas: 3_000_000n,
  });
  const receipt = await waitTx(hash, label);
  const log = receipt.logs.find(
    l => l.address.toLowerCase() === FACTORY.toLowerCase() && l.topics[0] === ACCOUNT_CREATED_TOPIC
  );
  if (!log) throw new Error(`AccountCreated event not found in ${label}`);
  return getAddress("0x" + log.topics[1]!.slice(26));
}

async function main() {
  console.log("\n=== v0.22.0 E2E — Sepolia ===");
  console.log(`Owner:          ${owner.address}`);
  console.log(`Factory:        ${FACTORY}`);
  console.log(`Impl:           ${IMPL}`);
  console.log(`ValidatorRouter: ${VALIDATOR_ROUTER}\n`);

  // T1: ACCOUNT_VERSION on impl
  console.log("[T1] ACCOUNT_VERSION on impl...");
  const ver = await pub.readContract({ address: IMPL, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (ver === "0.22.0") ok(`ACCOUNT_VERSION = "${ver}"`); else fail("ACCOUNT_VERSION", `got "${ver}"`);

  // T2: validatorRouter immutable on impl
  console.log("\n[T2] impl.validatorRouter() == VALIDATOR_ROUTER...");
  const router = await pub.readContract({ address: IMPL, abi: IMPL_ABI, functionName: "validatorRouter" }) as Address;
  if (router.toLowerCase() === VALIDATOR_ROUTER.toLowerCase())
    ok(`validatorRouter = ${router}`);
  else
    fail("validatorRouter", `got ${router}, expected ${VALIDATOR_ROUTER}`);

  // T3: Create account without P256 key (direct mode, ownerSig = "0x")
  const salt1 = BigInt(Date.now());
  console.log(`\n[T3] Create account (no P256 key, salt=${salt1})...`);
  let account1: Address;
  try {
    account1 = await createAccountOnChain(salt1, ZERO32, ZERO32, "createAccount-noP256");
    console.log(`  Account1: ${account1}`);
    ok("createAccount (no P256 key) succeeded");
  } catch (e: any) {
    fail("createAccount (no P256 key)", e.shortMessage ?? e.message?.slice(0, 80));
    process.exit(1);
  }

  // T4: clone ACCOUNT_VERSION
  console.log("\n[T4] clone ACCOUNT_VERSION...");
  const cloneVer = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (cloneVer === "0.22.0") ok(`clone ACCOUNT_VERSION = "${cloneVer}"`); else fail("clone ACCOUNT_VERSION", `got "${cloneVer}"`);

  // T5: accountId
  console.log("\n[T5] accountId...");
  const id = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "accountId" }) as string;
  if (id === "airaccount.v7@0.22.0") ok(`accountId = "${id}"`); else fail("accountId", `got "${id}"`);

  // T6: validator auto-wired to validatorRouter (P1 feature)
  console.log("\n[T6] account.validator() == VALIDATOR_ROUTER (P1 auto-wire)...");
  const v = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "validator" }) as Address;
  if (v.toLowerCase() === VALIDATOR_ROUTER.toLowerCase())
    ok(`validator = ${v} (auto-wired at birth ✓)`);
  else
    fail("validator auto-wire", `got ${v}, expected ${VALIDATOR_ROUTER}`);

  // T7: p256KeyX == 0 (no key passed)
  console.log("\n[T7] account.p256KeyX() == 0 (no key passed)...");
  const kx1 = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "p256KeyX" }) as Hex;
  if (kx1 === ZERO32) ok("p256KeyX == bytes32(0) when not set"); else fail("p256KeyX should be 0", `got ${kx1}`);

  // T8: Create account WITH P256 key
  const salt2 = salt1 + 1n;
  console.log(`\n[T8] Create account (with P256 key, salt=${salt2})...`);
  let account2: Address;
  try {
    account2 = await createAccountOnChain(salt2, TEST_PX, TEST_PY, "createAccount-withP256");
    console.log(`  Account2: ${account2}`);
    ok("createAccount (with P256 key) succeeded");
  } catch (e: any) {
    fail("createAccount (with P256 key)", e.shortMessage ?? e.message?.slice(0, 80));
    process.exit(1);
  }

  // T9: p256KeyX set atomically at birth
  console.log("\n[T9] account2.p256KeyX() == TEST_PX...");
  const kx2 = await pub.readContract({ address: account2, abi: ACCOUNT_ABI, functionName: "p256KeyX" }) as Hex;
  if (kx2.toLowerCase() === TEST_PX.toLowerCase())
    ok(`p256KeyX = ${kx2} (set at birth ✓)`);
  else
    fail("p256KeyX", `got ${kx2}`);

  // T10: p256KeyY set atomically at birth
  console.log("\n[T10] account2.p256KeyY() == TEST_PY...");
  const ky2 = await pub.readContract({ address: account2, abi: ACCOUNT_ABI, functionName: "p256KeyY" }) as Hex;
  if (ky2.toLowerCase() === TEST_PY.toLowerCase())
    ok(`p256KeyY = ${ky2} (set at birth ✓)`);
  else
    fail("p256KeyY", `got ${ky2}`);

  // T11: different P256 keys → different addresses (CREATE2 anti-front-run protection)
  console.log("\n[T11] different P256 keys → different CREATE2 addresses...");
  const cfg = makeConfig([anni.address, bob.address, charlie.address]);
  const salt3 = salt1 + 2n;
  const [addrNoPX, addrWithPX] = await Promise.all([
    pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress",
      args: [owner.address, salt3, cfg, ZERO32, ZERO32] }) as Promise<Address>,
    pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress",
      args: [owner.address, salt3, cfg, TEST_PX, TEST_PY] }) as Promise<Address>,
  ]);
  if (addrNoPX.toLowerCase() !== addrWithPX.toLowerCase())
    ok(`addr(noP256)=${addrNoPX.slice(0,10)}… ≠ addr(withP256)=${addrWithPX.slice(0,10)}… ✓`);
  else
    fail("P256 key must change CREATE2 address", "addresses are identical");

  // T12-T21: algId whitelist on account1 (all 10 approved algIds)
  console.log("\n[T12-T21] algId whitelist checks...");
  const algChecks = [
    { id: 0x09, label: "ALG_CUMULATIVE_T2_WA" },
    { id: 0x0a, label: "ALG_CUMULATIVE_T3_WA" },
    { id: 0x04, label: "ALG_CUMULATIVE_T2 (legacy)" },
    { id: 0x05, label: "ALG_CUMULATIVE_T3 (legacy)" },
    { id: 0x02, label: "ALG_ECDSA" },
    { id: 0x01, label: "ALG_BLS" },
    { id: 0x03, label: "ALG_P256" },
    { id: 0x06, label: "ALG_COMBINED_T1" },
    { id: 0x07, label: "ALG_WEIGHTED" },
    { id: 0x08, label: "ALG_SESSION_KEY" },
  ];
  let tIdx = 12;
  for (const { id, label } of algChecks) {
    const hex = `0x${id.toString(16).padStart(2, "0")}`;
    try {
      const approved = await pub.readContract({
        address: account1, abi: ACCOUNT_ABI, functionName: "approvedAlgorithms", args: [id],
      }) as boolean;
      if (approved) ok(`[T${tIdx}] ${hex} (${label}): approved ✓`);
      else fail(`[T${tIdx}] ${hex} (${label})`, "not approved");
    } catch (e: any) { fail(`[T${tIdx}] ${hex} check`, e.shortMessage ?? e.message?.slice(0, 60)); }
    tIdx++;
  }

  const total = 21;
  console.log(`\n=== E2E Results: ${passed} passed, ${failed} failed (${total} total) ===`);
  console.log(`Account1 (no P256): https://sepolia.etherscan.io/address/${account1}`);
  console.log(`Account2 (P256 set): https://sepolia.etherscan.io/address/${account2}`);
  if (failed > 0) { console.error("FAILED — do not release."); process.exit(1); }
  console.log("All tests PASSED — ready for release.");
}

main().catch((e) => { console.error(e); process.exit(1); });
