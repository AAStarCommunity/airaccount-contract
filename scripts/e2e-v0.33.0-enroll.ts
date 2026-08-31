/**
 * e2e-v0.33.0-enroll.ts — Deploy-success + enroll test for the v0.33.0 stack (Sepolia).
 *
 * Confirms the freshly-deployed v0.33.0 stack (CC-116 committee-off fail-closed) is wired correctly
 * on-chain and exercises the CC-98 account-side enroll:
 *   1. Create a test account via the v0.33.0 Factory (direct mode, msg.sender = owner). InitConfig carries
 *      #161 tier1Limit/tier2Limit (else createAccount throws "undefined to BigInt").
 *   2. account.enrollInCommitteeValidator() → self-enrolls (msg.sender at the validator = the account).
 *   3. Read-verify: accountId==airaccount.v7@0.33.0, owner, validatorRouter, enrolledAccount[account]==true,
 *      committee validator committeeActive()==FALSE (v0.33.0 deploys committee-OFF; interlock: dvt flips LAST),
 *      3+ registered nodes.
 *
 * NOTE (v0.33.0 vs v0.31.0): the mounted validator 0x1A8Db639 is ALREADY armed (committeeActive()==true),
 * so unlike the v0.31.0 enroll test this expects `true`. Under CC-116 a fresh account's tier-2/3 is
 * FAIL-CLOSED until it enrolls; after enroll it can submit committee-framed tier-2/3. Committee tier-2/3
 * UserOp E2E is still NOT here — it needs SDK/KMS per-signer signatures (Seeder b8f3441f). This proves the
 * stack + enroll wiring only.
 *
 * Usage: pnpm tsx scripts/e2e-v0.33.0-enroll.ts
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
// Validate BEFORE privateKeyToAccount() — else viem throws a cryptic undefined-slice error (pr-daemon #211 Low).
if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set in .env.sepolia");
const owner = privateKeyToAccount(PRIVATE_KEY);

function envAddr(k: string): Address { const v = process.env[k]; if (!v) throw new Error(`${k} not set`); return getAddress(v); }
const FACTORY   = envAddr("AIRACCOUNT_V0330_FACTORY");
const ROUTER    = envAddr("AIRACCOUNT_V0330_VALIDATOR_ROUTER");
const COMMITTEE = envAddr("AIRACCOUNT_V0330_COMMITTEE_VALIDATOR");

function loadAbi(name: string) {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const FACTORY_ABI = loadAbi("AAStarAirAccountFactoryV7");
const ACCOUNT_ABI = loadAbi("AAStarAirAccountV7");
const COMMITTEE_ABI = [
  { name: "committeeActive",        type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "bool" }] },
  { name: "getRegisteredNodeCount", type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "uint256" }] },
  { name: "enrolledAccount",        type: "function", stateMutability: "view", inputs: [{ type: "address" }],  outputs: [{ type: "bool" }] },
  { name: "requiredQuorum",         type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "uint256" }] },
  { name: "epochLength",            type: "function", stateMutability: "view", inputs: [],                     outputs: [{ type: "uint256" }] },
  { name: "epochPinned",            type: "function", stateMutability: "view", inputs: [{ type: "uint256" }],  outputs: [{ type: "bool" }] },
] as const;
const ROUTER_ABI = [
  { name: "getAlgorithm", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const UINT256_MAX = 2n ** 256n - 1n; // requiredQuorum() sentinel = "prerequisite snapshot missing" (unsatisfiable)

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
  console.log(`\n=== v0.33.0 deploy-success + enroll test — Sepolia ===`);
  console.log(`Owner/deployer: ${owner.address}\nFactory: ${FACTORY}\nCommittee validator: ${COMMITTEE}\n`);

  // Salt is env-overridable so a genuine FRESH create+enroll is reproducible on demand
  // (pr-daemon #211 r2 blocker-2 alternative prescription). Default reuses the standing test account.
  const salt = BigInt(process.env.E2E_SALT || "330001"); // `||` not `??`: E2E_SALT="" must not become salt 0
  const predicted = getAddress(await pub.readContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [owner.address, salt, CONFIG, ZERO32, ZERO32],
  }) as string);
  console.log(`Test account (salt=${salt}): ${predicted}`);

  // Track whether the MUTATING branches actually ran, so a reuse (no-op) run is distinguishable from a
  // genuine end-to-end create+enroll in the summary (pr-daemon #211 r2 blocker 2). A run that touched
  // nothing must not read the same as one that exercised both paths.
  const code = await pub.getBytecode({ address: predicted });
  const createdRan = !code || code === "0x";
  if (createdRan) {
    console.log("Creating account (direct mode, msg.sender = owner)...");
    await send("createAccount", FACTORY, encodeFunctionData({
      abi: FACTORY_ABI, functionName: "createAccount", args: [owner.address, salt, CONFIG, ZERO32, ZERO32, 0n, 0n, "0x"],
    }) as Hex, 3_000_000n);
  } else {
    console.log("  [reuse] account already deployed");
  }

  // enroll (owner tx; account self-enrolls at the committee validator). enroll() is callable regardless of
  // committee mode — self-registration for when tier-2/3 committee sigs are later submitted.
  const already = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "enrolledAccount", args: [predicted] }) as boolean;
  const enrollRan = !already;
  if (enrollRan) {
    console.log("\nEnrolling account in committee validator...");
    await send("enrollInCommitteeValidator", predicted, encodeFunctionData({ abi: ACCOUNT_ABI, functionName: "enrollInCommitteeValidator", args: [] }) as Hex, 200_000n);
  } else {
    console.log("\n  [reuse] account already enrolled");
  }

  console.log("\n=== Verify ===");
  check("accountId", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "accountId" }), "airaccount.v7@0.33.0");
  check("account owner", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "owner" }), owner.address);
  check("validatorRouter", await pub.readContract({ address: predicted, abi: ACCOUNT_ABI, functionName: "validatorRouter" }), ROUTER);
  check("enrolledAccount[account]", await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "enrolledAccount", args: [predicted] }), "true");
  // v0.33.0 option-1 deploy: validator is ALREADY armed → committeeActive()==true. CC-116 makes the
  // pre-enroll tier-2/3 window fail-closed; this test confirms enroll lands so committee sigs can follow.
  // v0.33.0 deploys against a COMMITTEE-OFF validator (epochLength==0) — the ORIGINAL interlock:
  // deploy -> enroll -> e2e -> ONLY THEN dvt flips setEpochLength. So the expected pairing is
  // phase-dependent, and the two fields must stay CONSISTENT with each other:
  //   committee OFF  -> requiredQuorum() IS the UINT256_MAX sentinel (no epoch snapshot yet)
  //   committee ARMED -> requiredQuorum() is a real, satisfiable quorum (>=1, not sentinel)
  // Asserting the pairing (not a hardcoded phase) means this same script also validates the
  // post-flip state, and still catches "armed but unsatisfiable" (pr-daemon #211 r2 blocker 1).
  const armed = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "committeeActive" }) as boolean;
  const rq = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "requiredQuorum" }) as bigint;
  if (!armed) {
    check("committee OFF (pre-arm interlock) -> requiredQuorum is sentinel (consistent)", rq === UINT256_MAX, "true");
    console.log("  NOTE: committee OFF -> CC-116 makes tier-2/3 FAIL-CLOSED on this stack until dvt flips setEpochLength (tier-1 owner-only works).");
  } else {
    // THIRD PHASE (dvt, 2026-08-31). requiredQuorum needs _epochUsable(e) AND _epochUsable(e-1), but
    // snapshotEpoch cannot run until block > epochStart — so at every epoch rollover there is a
    // STRUCTURAL ~2-3 block (~36s, ~4.7% duty cycle at L=64) window where the sentinel is CORRECT and
    // e-1 is still serving. A two-phase assertion reds every epoch (~13 min) and trains operators to
    // ignore it — and that alert fatigue is precisely what caused the earlier 10h outage. So tolerate
    // exactly this state, identified from on-chain reads only:
    //   epochPinned(e)==false AND epochPinned(e-1)==true AND (block - epochStart) <= min(256, L-1)
    const L = await pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "epochLength" }) as bigint;
    const bn = await pub.getBlockNumber();
    const e = bn / L, start = e * L;
    const [pinnedE, pinnedPrev] = await Promise.all([
      pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "epochPinned", args: [e] }) as Promise<boolean>,
      pub.readContract({ address: COMMITTEE, abi: COMMITTEE_ABI, functionName: "epochPinned", args: [e - 1n] }) as Promise<boolean>,
    ]);
    // cap encodes the KEEPER's pin latency, NOT the epoch's pin window. Using the pin window
    // (min(256, L-1)) was a unit error: bn-start is by definition in [0, L-1], so that bound is
    // vacuously true for any L <= 257 and tolerates the WHOLE epoch (100%), not the ~2-3 blocks the
    // comment claimed — masking "keeper pinned e-1 then died" for a full epoch. Measured keeper
    // latency is 2-3 blocks (epoch 181318 self-pin), so 4 leaves margin without hiding a dead keeper.
    const cap = 4n;
    const keeperLatency = !pinnedE && pinnedPrev && (bn - start) <= cap;
    if (rq === UINT256_MAX && keeperLatency) {
      check("ARMED + epoch pending pin (e-1 still serving) -> sentinel is EXPECTED, not an incident", true, "true");
      console.log(`  NOTE: structural keeper-latency window — epoch ${e} not yet pinned, e-1 pinned, block ${bn} is ${bn - start} into the epoch. tier-2/3 is transiently fail-closed (<=${cap} blocks tolerated; measured keeper latency 2-3). NOT a failure.`);
    } else {
      check("committee ARMED -> requiredQuorum satisfiable (not sentinel, >=1)", rq !== UINT256_MAX && rq >= 1n, "true");
    }
    console.log(`  (armed=${armed} requiredQuorum=${rq === UINT256_MAX ? "SENTINEL(max)" : rq} epoch=${e} pinned(e)=${pinnedE} pinned(e-1)=${pinnedPrev})`);
  }
  // Blocker 3 (pr-daemon #211 r2): every check above can hold with the router wired to a DIFFERENT
  // validator at 0x01. Pin that the account's router actually routes 0x01 to THIS committee validator.
  check("router 0x01 -> committee validator",
    getAddress(await pub.readContract({ address: ROUTER, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [1] }) as string), COMMITTEE);

  // Blocker 2: report whether the mutating branches ran, so ✅ PASS on a reuse (no-op) run is not
  // mistaken for a fresh end-to-end. A genuine E2E requires createdRan && enrollRan at least once.
  const e2eKind = createdRan && enrollRan ? "FRESH end-to-end (created+enrolled)" : `REUSE (createdRan=${createdRan} enrollRan=${enrollRan}) — re-run with a new salt for a fresh E2E`;
  console.log(`\n=== ${fail === 0 ? "✅ PASS" : "❌ FAIL"} — ${pass} passed, ${fail} failed | ${e2eKind} ===`);
  console.log(`Test account: ${predicted}`);
  if (fail === 0) console.log(`v0.33.0 stack confirmed + account enrolled. Committee ${armed ? "ARMED" : "OFF (pre-arm; tier-2/3 fail-closed until dvt flips setEpochLength)"}; tier-2/3 committee UserOp E2E needs SDK/KMS per-signer sigs (Seeder b8f3441f).`);
  process.exit(fail === 0 ? 0 : 1);
}
main().catch((err) => { console.error(err); process.exit(1); });
