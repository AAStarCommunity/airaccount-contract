/**
 * e2e-v0.27.0.ts — Full on-chain E2E for v0.27.0 (isValidOwnerAuth, issue #159) on Sepolia.
 *
 * Deployment + wiring + algId whitelist (T1–T21, same coverage as v0.22.0's release E2E, which is
 * the canonical gate since v0.22.0 changed the factory API and retired the legacy v0172 behavioral
 * harness), PLUS the v0.27.0 additions:
 *   T22–T25  isValidOwnerAuth (fallback-routed view): owner ECDSA → magic; wrong-signer / unknown-tag
 *            / empty → 0xffffffff.
 *   T26–T27  PR #158 factory relay-mode views present on-chain (getConfigHash, hashCreateAccount) —
 *            proves the rebase brought #158 into the v0.27.0 factory.
 *
 * The account/tier/recovery/module/session/BLS behavioral logic is byte-identical to v0.22.0
 * (impl unchanged except the added Extension view); its regression is inherited from v0.22.0's E2E.
 *
 * Fees use baseFee*2 + 2gwei tip (release-checklist §7) so txs don't drop as underpriced.
 *
 * Run: pnpm tsx scripts/e2e-v0.27.0.ts
 */

import {
  createPublicClient, createWalletClient, http, keccak256, toBytes, concat,
  getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const VERSION = "0.27.0";
const RPC_URL        = process.env.SEPOLIA_RPC_URL as string;
const FACTORY        = getAddress(process.env.AIRACCOUNT_V0270_FACTORY!);
const IMPL           = getAddress(process.env.AIRACCOUNT_V0270_IMPL!);
const VALIDATOR_ROUTER = getAddress(process.env.AIRACCOUNT_V0270_VALIDATOR_ROUTER!);

const owner   = privateKeyToAccount((process.env.PRIVATE_KEY_JASON ?? process.env.PRIVATE_KEY) as Hex);
const anni    = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const bob     = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);
const charlie = privateKeyToAccount(process.env.PRIVATE_KEY_CHARLIE as Hex);

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
  { name: "isValidOwnerAuth",   type: "function", stateMutability: "view",
    inputs: [{ type: "bytes32" }, { type: "bytes" }], outputs: [{ type: "bytes4" }] },
] as const;

const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
const ACCOUNT_CREATED_TOPIC = "0x33310a89c32d8cc00057ad6ef6274d2f8fe22389a992cf89983e09fc84f6cfff" as Hex;
const MAGIC = "0xa0cf00cf";
const FAIL  = "0xffffffff";

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

async function ownerAuth(account: Address, userOpHash: Hex, auth: Hex): Promise<string> {
  return await pub.readContract({
    address: account, abi: ACCOUNT_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, auth],
  }) as string;
}

async function main() {
  console.log(`\n=== v${VERSION} E2E — Sepolia ===`);
  console.log(`Owner:           ${owner.address}`);
  console.log(`Factory:         ${FACTORY}`);
  console.log(`Impl:            ${IMPL}`);
  console.log(`ValidatorRouter: ${VALIDATOR_ROUTER}\n`);

  // T1
  console.log("[T1] ACCOUNT_VERSION on impl...");
  const ver = await pub.readContract({ address: IMPL, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (ver === VERSION) ok(`ACCOUNT_VERSION = "${ver}"`); else fail("ACCOUNT_VERSION", `got "${ver}"`);

  // T2
  console.log("\n[T2] impl.validatorRouter() == VALIDATOR_ROUTER...");
  const router = await pub.readContract({ address: IMPL, abi: IMPL_ABI, functionName: "validatorRouter" }) as Address;
  if (router.toLowerCase() === VALIDATOR_ROUTER.toLowerCase()) ok(`validatorRouter = ${router}`);
  else fail("validatorRouter", `got ${router}`);

  // T3
  const salt1 = BigInt(Date.now());
  console.log(`\n[T3] Create account (no P256 key, salt=${salt1})...`);
  let account1: Address;
  try {
    account1 = await createAccountOnChain(salt1, ZERO32, ZERO32, "createAccount-noP256");
    console.log(`  Account1: ${account1}`);
    ok("createAccount (no P256 key) succeeded");
  } catch (e: any) { fail("createAccount (no P256 key)", e.shortMessage ?? e.message?.slice(0, 80)); process.exit(1); }

  // T4
  console.log("\n[T4] clone ACCOUNT_VERSION...");
  const cloneVer = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "ACCOUNT_VERSION" }) as string;
  if (cloneVer === VERSION) ok(`clone ACCOUNT_VERSION = "${cloneVer}"`); else fail("clone ACCOUNT_VERSION", `got "${cloneVer}"`);

  // T5
  console.log("\n[T5] accountId...");
  const id = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "accountId" }) as string;
  if (id === `airaccount.v7@${VERSION}`) ok(`accountId = "${id}"`); else fail("accountId", `got "${id}"`);

  // T6
  console.log("\n[T6] account.validator() == VALIDATOR_ROUTER (P1 auto-wire)...");
  const v = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "validator" }) as Address;
  if (v.toLowerCase() === VALIDATOR_ROUTER.toLowerCase()) ok(`validator = ${v} (auto-wired ✓)`);
  else fail("validator auto-wire", `got ${v}`);

  // T7
  console.log("\n[T7] account.p256KeyX() == 0 (no key passed)...");
  const kx1 = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "p256KeyX" }) as Hex;
  if (kx1 === ZERO32) ok("p256KeyX == bytes32(0) when not set"); else fail("p256KeyX should be 0", `got ${kx1}`);

  // T8
  const salt2 = salt1 + 1n;
  console.log(`\n[T8] Create account (with P256 key, salt=${salt2})...`);
  let account2: Address;
  try {
    account2 = await createAccountOnChain(salt2, TEST_PX, TEST_PY, "createAccount-withP256");
    console.log(`  Account2: ${account2}`);
    ok("createAccount (with P256 key) succeeded");
  } catch (e: any) { fail("createAccount (with P256 key)", e.shortMessage ?? e.message?.slice(0, 80)); process.exit(1); }

  // T9
  console.log("\n[T9] account2.p256KeyX() == TEST_PX...");
  const kx2 = await pub.readContract({ address: account2, abi: ACCOUNT_ABI, functionName: "p256KeyX" }) as Hex;
  if (kx2.toLowerCase() === TEST_PX.toLowerCase()) ok(`p256KeyX set at birth ✓`); else fail("p256KeyX", `got ${kx2}`);

  // T10
  console.log("\n[T10] account2.p256KeyY() == TEST_PY...");
  const ky2 = await pub.readContract({ address: account2, abi: ACCOUNT_ABI, functionName: "p256KeyY" }) as Hex;
  if (ky2.toLowerCase() === TEST_PY.toLowerCase()) ok(`p256KeyY set at birth ✓`); else fail("p256KeyY", `got ${ky2}`);

  // T11
  console.log("\n[T11] different P256 keys → different CREATE2 addresses...");
  const cfg = makeConfig([anni.address, bob.address, charlie.address]);
  const salt3 = salt1 + 2n;
  const [addrNoPX, addrWithPX] = await Promise.all([
    pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [owner.address, salt3, cfg, ZERO32, ZERO32] }) as Promise<Address>,
    pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [owner.address, salt3, cfg, TEST_PX, TEST_PY] }) as Promise<Address>,
  ]);
  if (addrNoPX.toLowerCase() !== addrWithPX.toLowerCase()) ok(`diff passkey → diff addr ✓`);
  else fail("P256 key must change CREATE2 address", "identical");

  // T12-T21
  console.log("\n[T12-T21] algId whitelist checks...");
  const algChecks = [
    { id: 0x09, label: "ALG_CUMULATIVE_T2_WA" }, { id: 0x0a, label: "ALG_CUMULATIVE_T3_WA" },
    { id: 0x04, label: "ALG_CUMULATIVE_T2" }, { id: 0x05, label: "ALG_CUMULATIVE_T3" },
    { id: 0x02, label: "ALG_ECDSA" }, { id: 0x01, label: "ALG_BLS" }, { id: 0x03, label: "ALG_P256" },
    { id: 0x06, label: "ALG_COMBINED_T1" }, { id: 0x07, label: "ALG_WEIGHTED" }, { id: 0x08, label: "ALG_SESSION_KEY" },
  ];
  let tIdx = 12;
  for (const { id, label } of algChecks) {
    const hex = `0x${id.toString(16).padStart(2, "0")}`;
    try {
      const approved = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "approvedAlgorithms", args: [id] }) as boolean;
      if (approved) ok(`[T${tIdx}] ${hex} (${label}): approved ✓`); else fail(`[T${tIdx}] ${hex} (${label})`, "not approved");
    } catch (e: any) { fail(`[T${tIdx}] ${hex}`, e.shortMessage ?? e.message?.slice(0, 60)); }
    tIdx++;
  }

  // ── v0.27.0 additions ──────────────────────────────────────────────────────
  // isValidOwnerAuth on account1 (owner = the deployer key `owner`).
  const uoh = keccak256(toBytes(`e2e-v${VERSION}-isValidOwnerAuth`));

  console.log("\n[T22] isValidOwnerAuth: owner ECDSA personal_sign → magic...");
  const sigOwner = await owner.signMessage({ message: { raw: uoh } });
  const outOk = await ownerAuth(account1, uoh, concat(["0x01", sigOwner]));
  if (outOk.toLowerCase() === MAGIC) ok(`owner ECDSA → ${MAGIC} ✓`); else fail("isValidOwnerAuth owner ECDSA", `got ${outOk}`);

  console.log("\n[T23] isValidOwnerAuth: wrong signer → fail...");
  const stranger = privateKeyToAccount(generatePrivateKey());
  const sigStranger = await stranger.signMessage({ message: { raw: uoh } });
  const outBad = await ownerAuth(account1, uoh, concat(["0x01", sigStranger]));
  if (outBad.toLowerCase() === FAIL) ok(`wrong signer → ${FAIL} ✓`); else fail("isValidOwnerAuth wrong signer", `got ${outBad}`);

  console.log("\n[T24] isValidOwnerAuth: unknown tag → fail...");
  const outTag = await ownerAuth(account1, uoh, concat(["0x03", sigOwner]));
  if (outTag.toLowerCase() === FAIL) ok(`unknown tag → ${FAIL} ✓`); else fail("isValidOwnerAuth unknown tag", `got ${outTag}`);

  console.log("\n[T25] isValidOwnerAuth: empty ownerAuth → fail...");
  const outEmpty = await ownerAuth(account1, uoh, "0x");
  if (outEmpty.toLowerCase() === FAIL) ok(`empty → ${FAIL} ✓`); else fail("isValidOwnerAuth empty", `got ${outEmpty}`);

  // PR #158 relay-mode factory views present on this factory (rebase merge live on-chain).
  console.log("\n[T26] factory.getConfigHash(...) present (PR #158)...");
  try {
    const gch = await pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getConfigHash", args: [cfg] }) as Hex;
    if (gch && gch !== ZERO32) ok(`getConfigHash → ${gch.slice(0, 18)}… ✓`); else fail("getConfigHash", `got ${gch}`);
  } catch (e: any) { fail("getConfigHash", e.shortMessage ?? e.message?.slice(0, 60)); }

  console.log("\n[T27] factory.hashCreateAccount(...) present (PR #158)...");
  try {
    const hca = await pub.readContract({
      address: FACTORY, abi: FACTORY_ABI, functionName: "hashCreateAccount",
      args: [owner.address, salt1, cfg, ZERO32, ZERO32, 0n, 0n],
    }) as Hex;
    if (hca && hca !== ZERO32) ok(`hashCreateAccount → ${hca.slice(0, 18)}… ✓`); else fail("hashCreateAccount", `got ${hca}`);
  } catch (e: any) { fail("hashCreateAccount", e.shortMessage ?? e.message?.slice(0, 60)); }

  // ── v0.27.0 security-hardening on-chain checks ──────────────────────────────
  // T28 (fix c): guardian identities now change the createAccountWithDefaults CREATE2 address.
  console.log("\n[T28] fix c — getAddressWithDefaults: different guardians → different address...");
  try {
    const DEFAULTS_ABI = [{ name: "getAddressWithDefaults", type: "function", stateMutability: "view",
      inputs: [{ type: "address" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "uint256" }],
      outputs: [{ type: "address" }] }] as const;
    const [aG, bG] = await Promise.all([
      pub.readContract({ address: FACTORY, abi: DEFAULTS_ABI, functionName: "getAddressWithDefaults", args: [owner.address, 77n, anni.address, bob.address, 1n] }) as Promise<Address>,
      pub.readContract({ address: FACTORY, abi: DEFAULTS_ABI, functionName: "getAddressWithDefaults", args: [owner.address, 77n, charlie.address, bob.address, 1n] }) as Promise<Address>,
    ]);
    if (aG.toLowerCase() !== bG.toLowerCase()) ok(`guardian set changes address ✓ (${aG.slice(0,10)}… ≠ ${bG.slice(0,10)}…)`);
    else fail("fix c: guardians must change address", "identical");
  } catch (e: any) { fail("fix c getAddressWithDefaults", e.shortMessage ?? e.message?.slice(0, 60)); }

  // T29 (fix d): the account's router resolves algId 0x08 to the NEW SessionKeyValidator.
  console.log("\n[T29] fix d — router 0x08 == new SessionKeyValidator...");
  try {
    const ROUTER = getAddress(process.env.AIRACCOUNT_V0270_VALIDATOR_ROUTER!);
    const SKV    = getAddress(process.env.AIRACCOUNT_V0270_SESSION_KEY_VALIDATOR!);
    const ROUTER_ABI = [{ name: "getAlgorithm", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] }] as const;
    const r08 = await pub.readContract({ address: ROUTER, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x08] }) as Address;
    const acctValidator = await pub.readContract({ address: account1, abi: ACCOUNT_ABI, functionName: "validator" }) as Address;
    if (r08.toLowerCase() === SKV.toLowerCase() && acctValidator.toLowerCase() === ROUTER.toLowerCase())
      ok(`account.validator == new router, router[0x08] == new SessionKeyValidator ✓`);
    else fail("fix d session validator wiring", `router0x08=${r08} acctValidator=${acctValidator}`);
  } catch (e: any) { fail("fix d router check", e.shortMessage ?? e.message?.slice(0, 60)); }

  // T30 (CRITICAL-1): the DEPLOYED impl runtime bytecode equals the locally-compiled FIXED artifact.
  // On a live network validateUserOp can't be called as the EntryPoint, so we prove the fix is on-chain
  // by matching the deployed runtime to the fixed build (the 895 unit tests, incl. the 0x0a exploit-vector
  // rejection, run against exactly this artifact).
  console.log("\n[T30] CRITICAL-1 — deployed impl bytecode == local fixed artifact...");
  try {
    const { readFileSync } = await import("fs");
    const { resolve } = await import("path");
    const IMPL = getAddress(process.env.AIRACCOUNT_V0270_IMPL!);
    const artifact = JSON.parse(readFileSync(resolve(import.meta.dirname, "../out/AAStarAirAccountV7.sol/AAStarAirAccountV7.json"), "utf-8"));
    // Mask immutable regions (e.g. validatorRouter) — the on-chain code has the real address there,
    // the local artifact has placeholder zeros. Zero both sides at those offsets, then compare.
    const maskImmutables = (hex: string): string => {
      const bytes = Buffer.from(hex.replace(/^0x/, ""), "hex");
      const refs = artifact.deployedBytecode.immutableReferences ?? {};
      for (const id of Object.keys(refs)) for (const { start, length } of refs[id]) bytes.fill(0, start, start + length);
      return bytes.toString("hex");
    };
    const localRuntime = maskImmutables(artifact.deployedBytecode.object as string);
    const onchain = maskImmutables((await pub.getBytecode({ address: IMPL }) ?? "0x"));
    if (onchain === localRuntime && localRuntime.length > 2)
      ok(`deployed impl runtime == fixed artifact (immutables masked, ${(onchain.length / 2)} B) ✓`);
    else fail("CRITICAL-1 bytecode match", `onchain ${onchain.length} vs local ${localRuntime.length}`);
  } catch (e: any) { fail("CRITICAL-1 bytecode match", e.shortMessage ?? e.message?.slice(0, 60)); }

  // T31 (v0.27.0 DVT unification): router 0x01 == DVT validator, and the DVT validator validates a real
  // BLS aggregate (dvt-provided golden vector) returning 0. Proves the mount + BLS/DVT path is live.
  console.log("\n[T31] DVT unification — router 0x01 == DVT validator + golden-vector validate()==0...");
  try {
    const ROUTER = getAddress(process.env.AIRACCOUNT_V0270_VALIDATOR_ROUTER!);
    const DVT = getAddress(process.env.AIRACCOUNT_V0270_DVT_VALIDATOR!);
    const RABI = [{ name: "getAlgorithm", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] }] as const;
    const VABI = [{ name: "validate", type: "function", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "bytes" }], outputs: [{ type: "uint256" }] }] as const;
    const goldenHash = "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex;
    const nodeIds = ["b002c9fe0b579486a3d3e877d5b78e63603d0619adafdf50296d0391792dd967", "e45a016fb66918f6e9322c88b3b3ec7b05ccfe0cbb2c21eb3091c474462e611a"];
    const blsSig = "000000000000000000000000000000000b9f176f5113c4ccad075895d342d551ab705281d3a134902b8f6f0eb172a02b476efe18a58791bb5308a721bd87a417000000000000000000000000000000000f28139976fdab5e48503ad8d94c08ed65ef56219e423aa5942ae4b1926545ecabd48cde24179509a99ccac4b958499e000000000000000000000000000000000b7f5bcdb9f61925e00695c3a8c04dfe93258e7db5b923f6dd9b18a620e86ad45df02f23039a3ece1a09ea58e0e1677b0000000000000000000000000000000009ccf8330835ca4660012e0f587a6e0727241c3ac771858cc6d3b01d8659e3bf8a4582015610cacb9bee5f10945887af";
    const payload = ("0x" + nodeIds.join("") + blsSig) as Hex;
    const r01 = await pub.readContract({ address: ROUTER, abi: RABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
    const pos = await pub.readContract({ address: DVT, abi: VABI, functionName: "validate", args: [goldenHash, payload] }) as bigint;
    // NEGATIVE vectors (Codex 2026-07-05): prove the DEPLOYED validator actually verifies BLS — a mutated
    // hash and a corrupted sig must be REJECTED (return != 0), ruling out an always-pass stub.
    const mutHash = "0x2222222222222222222222222222222222222222222222222222222222222222" as Hex;
    const mutPayload = ("0x" + nodeIds.join("") + blsSig.slice(0, -4) + "dead") as Hex;
    const negH = await pub.readContract({ address: DVT, abi: VABI, functionName: "validate", args: [mutHash, payload] }).catch(() => 1n) as bigint;
    const negS = await pub.readContract({ address: DVT, abi: VABI, functionName: "validate", args: [goldenHash, mutPayload] }).catch(() => 1n) as bigint;
    if (r01.toLowerCase() === DVT.toLowerCase() && pos === 0n && negH !== 0n && negS !== 0n)
      ok(`router 0x01 == DVT, golden validate()==0, mutated-hash + corrupted-sig REJECTED (not a stub) ✓`);
    else fail("DVT mount", `router0x01=${r01} pos=${pos} negH=${negH} negS=${negS}`);
  } catch (e: any) { fail("DVT mount check", e.shortMessage ?? e.message?.slice(0, 60)); }

  const total = 31;
  console.log(`\n=== E2E Results: ${passed} passed, ${failed} failed (${total} total) ===`);
  console.log(`Account1 (no P256): https://sepolia.etherscan.io/address/${account1}`);
  console.log(`Account2 (P256 set): https://sepolia.etherscan.io/address/${account2}`);
  if (failed > 0) { console.error("FAILED — do not release."); process.exit(1); }
  console.log("All tests PASSED — ready for release.");
}

main().catch((e) => { console.error(e); process.exit(1); });
