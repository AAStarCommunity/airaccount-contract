/**
 * bench-tier-gas.ts — CC-95 / Onion paper §5.1 tiered-gas benchmark
 *
 * Measures REAL on-chain gas for validateUserOp+execute across the three
 * authorization tiers on a single v0.29.0 account, holding EVERYTHING constant
 * except the tier (same account, same recipient, same calldata shape — only the
 * transfer value changes to cross requiredTier thresholds):
 *
 *   tier-1 (algId 0x03): P256 passkey only                (single factor)
 *   tier-2 (algId 0x04): P256 + real 3-node BLS aggregate (dvt1/2/3 live)
 *   tier-3 (algId 0x05): P256 + BLS + guardian ECDSA
 *
 * Choosing 0x03 (not owner-ECDSA) for tier-1 makes the deltas clean:
 *   tier1→2 delta = pure BLS pairing cost   (both tiers carry P256)
 *   tier2→3 delta = pure guardian ecrecover cost (both carry P256+BLS)
 *
 * BLS aggregate is produced by the LIVE DVT committee (dvt1/2/3.aastar.io,
 * aNode v1.13.1) whose nodeIds are registered on the mounted validator 0x539B —
 * NOT a local/mock aggregate. Every submitted tx is verifiable on Etherscan.
 *
 * Submission is a direct EntryPoint.handleOps (one UserOp per tx): one op per tx
 * keeps receipt.gasUsed clean (no bundler batching noise); the UserOperationEvent
 * still carries actualGasUsed. Both are recorded.
 *
 * SCOPE NOTE: dailyLimit=0 ⇒ no AAStarGlobalGuard deployed, so this isolates the
 * native tier signature-verification path (guard/whitelist cost excluded). The
 * tier→tier DELTA is unaffected by the guard; disclosed to DSR.
 *
 * ⚠️ CITE `receipt_gasUsed`, NOT `event_actualGasUsed`: the event column = internal gas + the
 *    hard-coded synthetic `preVerificationGas`(80,000), which biases tier-1 by +52% and distorts the
 *    cross-tier ratio. See scripts/out/README.md for column caliber, provenance, and the SCOPE note
 *    (dailyLimit=0 ⇒ no guard ⇒ §4.3 cumulative path not covered).
 *
 * Output CSV: scripts/out/bench-tier-gas-<salt>.csv
 *   tier,run_idx,block_number,tx_hash,receipt_gasUsed,event_actualGasUsed,event_actualGasCost,tier_factors
 *
 * Run: npx tsx scripts/bench-tier-gas.ts [N]   (N = runs per tier, default 10)
 *      DRYCHECK=1 npx tsx scripts/bench-tier-gas.ts   (config print, no chain writes)
 */

import { config } from "dotenv";
import { resolve } from "path";
import { mkdirSync, writeFileSync, readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, parseEther, formatEther,
  encodeFunctionData, toHex, hexToBytes, bytesToHex, getAddress, type Hex, type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { p256 } from "@noble/curves/p256";
import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { randomBytes } from "crypto";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });
const required = (k: string): string => { const v = process.env[k]; if (!v) { console.error(`Missing env: ${k}`); process.exit(1); } return v; };

// ─── Config ────────────────────────────────────────────────────────────
const N = Number(process.argv[2] ?? "10");
const RPC_URL = process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const FACTORY = getAddress(required("AIRACCOUNT_V0290_FACTORY"));
const ROUTER  = getAddress(required("AIRACCOUNT_V0290_VALIDATOR_ROUTER"));

const owner = privateKeyToAccount((process.env.PRIVATE_KEY_JASON ?? required("PRIVATE_KEY")) as Hex);
const guardian = privateKeyToAccount(required("PRIVATE_KEY_BOB") as Hex);   // tier-3 signer = guardians[0]
const anni = privateKeyToAccount(required("PRIVATE_KEY_ANNI") as Hex);
const charlie = privateKeyToAccount(required("PRIVATE_KEY_CHARLIE") as Hex);
const RECIPIENT = owner.address;                                            // recycle value back to owner

// Live DVT committee — nodeIds registered on validator 0x539B; on-chain payload
// nodeId set must be STRICTLY ASCENDING (0x539B wire contract): 0x1f < 0x96 < 0xe3.
const DVT = [
  { url: "https://dvt1.aastar.io", nodeId: "0x1f5e41c69465733eeb19341d95853ee6d9295a9e6698f5398d70e509be8f326d" as Hex },
  { url: "https://dvt3.aastar.io", nodeId: "0x96d64ba8240694153c757707732a11ff175380065ddacb6406094c9d5fa5cfce" as Hex },
  { url: "https://dvt2.aastar.io", nodeId: "0xe3a4a3af3973b65bc95dd962e767e17592dfb331f3544209676271b188fd9f80" as Hex },
];
const TIER1_LIMIT = parseEther("0.0001");
const TIER2_LIMIT = parseEther("0.0002");
const AMOUNT: Record<number, bigint> = {
  1: parseEther("0.00005"),  // ≤ tier1Limit → requiredTier 1
  2: parseEther("0.00015"),  // (tier1,tier2] → requiredTier 2
  3: parseEther("0.00025"),  // > tier2Limit → requiredTier 3
};

const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;
const ACCOUNT_CREATED_TOPIC = "0x33310a89c32d8cc00057ad6ef6274d2f8fe22389a992cf89983e09fc84f6cfff" as Hex;
const USER_OP_EVENT_TOPIC = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f" as Hex;

// ─── ABIs — factory/account from compiled artifacts (never hand-write), EP minimal ──
function loadArtifact(name: string): any[] {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const FACTORY_ABI = loadArtifact("AAStarAirAccountFactoryV7");
const ACCOUNT_ABI = loadArtifact("AAStarAirAccountV7");
const userOpTuple = [
  { name: "sender", type: "address" }, { name: "nonce", type: "uint256" }, { name: "initCode", type: "bytes" },
  { name: "callData", type: "bytes" }, { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
  { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" }, { name: "signature", type: "bytes" },
] as const;
const EP_ABI = [
  { name: "handleOps", type: "function", stateMutability: "nonpayable", inputs: [{ name: "ops", type: "tuple[]", components: userOpTuple }, { name: "beneficiary", type: "address" }], outputs: [] },
  { name: "getUserOpHash", type: "function", stateMutability: "view", inputs: [{ name: "userOp", type: "tuple", components: userOpTuple }], outputs: [{ type: "bytes32" }] },
  { name: "depositTo", type: "function", stateMutability: "payable", inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getNonce", type: "function", stateMutability: "view", inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }] },
] as const;

// ─── clients (robust fee: Sepolia baseFee*2, avoids under-priced tx) ─────
// viem ChainFees key is `defaultPriorityFee`, NOT `maxPriorityFeePerGas` (the latter is silently
// ignored — untyped literal so TS didn't catch it; pr-daemon #199 R2 finding).
const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, defaultPriorityFee: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL, { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: robust, transport: http(RPC_URL, { timeout: 60_000 }) });

const packUint128 = (hi: bigint, lo: bigint): Hex => toHex((hi << 128n) | lo, { size: 32 });

// ─── BLS G2 (EIP-2537 256-byte) encode/decode + local aggregation ────────
// The DVT /aggregate endpoint currently only accepts compact inputs; instead we
// aggregate the three nodes' real EIP-2537 signatures locally (BLS aggregation
// is public G2 point addition, no secrets). The sum is byte-identical to what
// their endpoint would return and is verified on-chain against the DVT-registered
// pubkeys at validator 0x539B — so it remains a genuine live 3-of-3 DVT multi-sig.
const b48 = (n: bigint): Uint8Array => hexToBytes(("0x" + n.toString(16).padStart(96, "0")) as Hex);
function encodeG2(p: any): Hex {
  const a = p.toAffine(); const r = new Uint8Array(256);
  r.set(b48(a.x.c0), 16); r.set(b48(a.x.c1), 80); r.set(b48(a.y.c0), 144); r.set(b48(a.y.c1), 208);
  return bytesToHex(r);
}
function decodeG2(hex: Hex): any {
  const b = hexToBytes(hex);
  if (b.length !== 256) throw new Error(`node sig is ${b.length} bytes, expected 256 EIP-2537 G2`);
  const rd = (o: number) => BigInt(bytesToHex(b.slice(o, o + 48)));
  const Fp2: any = (bls.fields as any).Fp2;
  const p = bls.G2.ProjectivePoint.fromAffine({ x: Fp2.fromBigTuple([rd(16), rd(80)]), y: Fp2.fromBigTuple([rd(144), rd(208)]) });
  p.assertValidity();
  return p;
}

// ─── DVT: fetch 3 live node signatures, aggregate locally to EIP-2537 256B ──
async function liveBlsAggregate(userOp: any, userOpHash: Hex): Promise<Hex> {
  const ownerSig = await owner.signMessage({ message: { raw: hexToBytes(userOpHash) } });  // EIP-191
  const ownerAuth = ("0x01" + ownerSig.slice(2)) as Hex;                                   // tag 0x01 ‖ sig (66B)
  const body = JSON.stringify({ userOp: serializeUserOp(userOp), ownerAuth });

  let agg: any = null;
  for (const node of DVT) {
    const res = await fetch(`${node.url}/signature/sign`, { method: "POST", headers: { "content-type": "application/json" }, body });
    if (!res.ok) throw new Error(`${node.url}/signature/sign HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const j: any = await res.json();
    if (j.status === "pending") throw new Error(`OOB_PENDING@${node.url}: sign returned status=pending (userOpHash ${j.userOpHash ?? userOpHash}) — #124 out-of-band gate; ping DVT to lower threshold for benchmark. Reporting raw, not skipping.`);
    if (!j.signature) throw new Error(`${node.url}/signature/sign: no signature in ${JSON.stringify(j).slice(0, 300)}`);
    const pt = decodeG2(j.signature as Hex);
    agg = agg ? agg.add(pt) : pt;
  }
  return encodeG2(agg);
}
function serializeUserOp(u: any) {
  return {
    sender: u.sender, nonce: toHex(u.nonce), initCode: u.initCode, callData: u.callData,
    accountGasLimits: u.accountGasLimits, preVerificationGas: toHex(u.preVerificationGas),
    gasFees: u.gasFees, paymasterAndData: u.paymasterAndData, signature: u.signature,
  };
}

// ─── signature builders (encoding confirmed vs on-chain validators) ──────
let p256Priv: Uint8Array;
function p256Sig(userOpHash: Hex): Hex {
  const sig = p256.sign(hexToBytes(userOpHash), p256Priv, { lowS: true });
  return (toHex(sig.r, { size: 32 }) + toHex(sig.s, { size: 32 }).slice(2)) as Hex;   // r(32)‖s(32)
}
function blsPayload(agg: Hex): string {                                                // nodeIdsLen(count) ‖ nodeId[asc] ‖ aggSig(256)
  return toHex(BigInt(DVT.length), { size: 32 }).slice(2) + DVT.map((d) => d.nodeId.slice(2)).join("") + agg.slice(2);
}
async function buildTierSig(tier: number, userOp: any, h: Hex): Promise<Hex> {
  const p = p256Sig(h).slice(2);
  if (tier === 1) return ("0x03" + p) as Hex;
  const agg = await liveBlsAggregate(userOp, h);
  if (tier === 2) return ("0x04" + p + blsPayload(agg)) as Hex;
  const gSig = await guardian.signMessage({ message: { raw: hexToBytes(h) } });         // EIP-191 personal_sign(userOpHash)
  return ("0x05" + p + blsPayload(agg) + gSig.slice(2)) as Hex;
}

// ─── userOp builder (gas fields constant across tiers; only value varies) ─
let accountAddr: Address;
async function buildUserOp(value: bigint) {
  const nonce = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [accountAddr, 0n] });
  const callData = encodeFunctionData({ abi: ACCOUNT_ABI, functionName: "execute", args: [RECIPIENT, value, "0x"] });
  const fee = await pub.estimateFeesPerGas();
  return {
    sender: accountAddr, nonce, initCode: "0x" as Hex, callData,
    accountGasLimits: packUint128(900_000n, 200_000n),          // verificationGasLimit ‖ callGasLimit — constant
    preVerificationGas: 80_000n,
    gasFees: packUint128(fee.maxPriorityFeePerGas ?? 2_000_000_000n, fee.maxFeePerGas ?? 20_000_000_000n),
    paymasterAndData: "0x" as Hex, signature: "0x" as Hex,
  };
}

type Row = { tier: number; run: number; block: bigint; tx: Hex; gasUsed: bigint; actualGasUsed: bigint; actualGasCost: bigint };

async function waitTx(hash: Hex) {
  return await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
}

async function main() {
  console.log(`\n=== bench-tier-gas — N=${N}/tier — v0.29.0 Sepolia ===`);
  console.log(`owner/submitter=${owner.address}  guardian=${guardian.address}`);
  const bal = await pub.getBalance({ address: owner.address });
  console.log(`owner balance: ${formatEther(bal)} ETH`);

  // P256 keypair — pubkey baked into the account at creation (folds into CREATE2 salt)
  p256Priv = randomBytes(32);
  const pubKey = p256.getPublicKey(p256Priv, false);
  const px = bytesToHex(pubKey.slice(1, 33)) as Hex, py = bytesToHex(pubKey.slice(33, 65)) as Hex;

  const cfg = {
    guardians: [guardian.address, anni.address, charlie.address] as [Address, Address, Address],
    guardianP256X: [ZERO32, ZERO32, ZERO32] as [Hex, Hex, Hex],
    guardianP256Y: [ZERO32, ZERO32, ZERO32] as [Hex, Hex, Hex],
    dailyLimit: 0n,                                             // 0 ⇒ no guard (isolates tier path — see SCOPE NOTE)
    approvedAlgIds: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as number[],
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
    tier1Limit: TIER1_LIMIT, tier2Limit: TIER2_LIMIT,          // #161 native tiers — baked at birth
  };

  if (process.env.DRYCHECK) {
    console.log("DRYCHECK OK:", { N, FACTORY, ROUTER, owner: owner.address, guardian: guardian.address,
      dvtAsc: DVT.map((d) => d.nodeId.slice(0, 12) + "…"), tiers: { t1: formatEther(TIER1_LIMIT), t2: formatEther(TIER2_LIMIT) },
      amounts: { t1: formatEther(AMOUNT[1]), t2: formatEther(AMOUNT[2]), t3: formatEther(AMOUNT[3]) } });
    process.exit(0);
  }

  // 1. create benchmark account (P256 + tier limits baked at birth; ownerSig="0x" ⇒ direct-tx owner proof)
  const salt = BigInt(Math.floor(Date.now() / 1000));
  console.log(`\n[1] createAccount salt=${salt} (P256 baked, tier limits baked)…`);
  const createTx = await wal.writeContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount",
    args: [owner.address, salt, cfg, px, py, 0n, 0n, "0x" as Hex], gas: 3_000_000n });
  const createRc = await waitTx(createTx);
  const log = createRc.logs.find((l: any) => l.address.toLowerCase() === FACTORY.toLowerCase() && l.topics[0] === ACCOUNT_CREATED_TOPIC);
  if (!log) throw new Error("AccountCreated event not found");
  accountAddr = getAddress("0x" + log.topics[1]!.slice(26));
  console.log(`    account=${accountAddr}  tx=${createTx}`);

  // 2. hard preflight (real ETH ahead — verify EVERY assumption)
  console.log(`[2] preflight…`);
  const [t1, t2, gc, kx, val] = await Promise.all([
    pub.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "tier1Limit" }) as Promise<bigint>,
    pub.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "tier2Limit" }) as Promise<bigint>,
    pub.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "guardianCount" }) as Promise<number>,
    pub.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "p256KeyX" }) as Promise<Hex>,
    pub.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "validator" }) as Promise<Address>,
  ]);
  const check = (c: boolean, m: string) => { if (!c) throw new Error(`preflight FAIL: ${m}`); console.log(`    ✓ ${m}`); };
  check(t1 === TIER1_LIMIT, `tier1Limit=${formatEther(t1)}`);
  check(t2 === TIER2_LIMIT, `tier2Limit=${formatEther(t2)}`);
  check(Number(gc) === 3, `guardianCount=${gc}`);
  check(kx.toLowerCase() === px.toLowerCase(), `p256KeyX==px`);
  check(val.toLowerCase() === ROUTER.toLowerCase(), `validator==ROUTER ${val}`);

  // 3. fund account (transfers) + EntryPoint deposit (gas)
  console.log(`[3] fund account + EP deposit…`);
  await waitTx(await wal.sendTransaction({ to: accountAddr, value: parseEther("0.01") }));
  await waitTx(await wal.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "depositTo", args: [accountAddr], value: parseEther("0.1") }));

  // 4. benchmark — interleave tiers per run so base-fee drift is not tier-correlated
  const rows: Row[] = [];
  for (let run = 1; run <= N; run++) {
    for (const tier of [1, 2, 3]) {
      const userOp = await buildUserOp(AMOUNT[tier]);
      const h = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getUserOpHash", args: [userOp] }) as Hex;
      userOp.signature = await buildTierSig(tier, userOp, h);
      const est = await pub.estimateContractGas({ address: ENTRYPOINT, abi: EP_ABI, functionName: "handleOps", args: [[userOp], owner.address], account: owner.address });
      const tx = await wal.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "handleOps", args: [[userOp], owner.address], gas: (est * 15n) / 10n });
      const rc = await waitTx(tx);
      const ev = rc.logs.find((l: any) => l.topics[0] === USER_OP_EVENT_TOPIC);
      let actualGasUsed = 0n, actualGasCost = 0n, innerSuccess = false;
      if (ev && ev.data.length >= 2 + 64 * 4) {
        innerSuccess = BigInt("0x" + ev.data.slice(66, 130)) === 1n;
        actualGasCost = BigInt("0x" + ev.data.slice(130, 194));
        actualGasUsed = BigInt("0x" + ev.data.slice(194, 258));
      }
      if (rc.status !== "success" || !innerSuccess)
        throw new Error(`tier${tier} run${run} FAILED (status=${rc.status} inner=${innerSuccess}) tx=${tx} — reporting raw, not skipping`);
      rows.push({ tier, run, block: rc.blockNumber, tx, gasUsed: rc.gasUsed, actualGasUsed, actualGasCost });
      console.log(`  t${tier} run${run}/${N} blk=${rc.blockNumber} gasUsed=${rc.gasUsed} actualGasUsed=${actualGasUsed}  ${tx}`);
    }
  }

  // 5. CSV + delta summary
  const outDir = resolve(import.meta.dirname, "out"); mkdirSync(outDir, { recursive: true });
  const factors: Record<number, string> = { 1: "P256(0x03)", 2: "P256+BLS3(0x04)", 3: "P256+BLS3+guardian(0x05)" };
  const header = "tier,run_idx,block_number,tx_hash,receipt_gasUsed,event_actualGasUsed,event_actualGasCost,tier_factors";
  const lines = rows.map((r) => `${r.tier},${r.run},${r.block},${r.tx},${r.gasUsed},${r.actualGasUsed},${r.actualGasCost},${factors[r.tier]}`);
  const outFile = resolve(outDir, `bench-tier-gas-${salt}.csv`);
  writeFileSync(outFile, [header, ...lines].join("\n") + "\n");
  console.log(`\nCSV → ${outFile}  (${rows.length} rows)`);

  const mean = (t: number, f: (r: Row) => bigint) => { const xs = rows.filter((r) => r.tier === t).map(f); return xs.reduce((a, b) => a + b, 0n) / BigInt(xs.length || 1); };
  const g1 = mean(1, (r) => r.gasUsed), g2 = mean(2, (r) => r.gasUsed), g3 = mean(3, (r) => r.gasUsed);
  // Report median too (mean is skewed by the tier-1 cold-write outlier, run#1). Predictions are
  // pre-registered; measured deltas ran ~5.0× (t1→2) and ~2.6× (t2→3) OVER them — that gap is the
  // finding, see scripts/out/README.md. (Persisted there, not only stdout.)
  const median = (t: number) => {
    const xs = rows.filter(r => r.tier === t).map(r => r.gasUsed).sort((a,b)=>a<b?-1:1);
    const n = xs.length; if (n === 0) return 0n;
    // true median: average the two middle values on even n (xs[n/2-1] is the lower-middle);
    // odd n takes the single middle. (Prior xs[floor(n/2)] returned the upper-middle on even n.)
    return n % 2 === 1 ? xs[(n - 1) / 2] : (xs[n / 2 - 1] + xs[n / 2]) / 2n;
  };
  const m1 = median(1), m2 = median(2), m3 = median(3);
  console.log(`\nmean receipt.gasUsed:   t1=${g1} t2=${g2} t3=${g3}`);
  console.log(`median receipt.gasUsed: t1=${m1} t2=${m2} t3=${m3}  ← cite median (t1 run#1 is a cold-write outlier)`);
  console.log(`delta tier1→2 = ${m2 - m1} (pre-registered predict ~106k; measured is ~5×, NOT pure pairing — see README)`);
  console.log(`delta tier2→3 = ${m3 - m2} (pre-registered predict ~3,000 guardian ecrecover; measured is ~2.6×)`);
  console.log(`account=${accountAddr}  (EP deposit recoverable via withdrawTo)`);
}

main().catch((e) => { console.error("\nFATAL:", e.message || e); process.exit(1); });
