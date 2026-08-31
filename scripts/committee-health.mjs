/**
 * committee-health.mjs — durable health check for the committee validator this stack actually mounts.
 *
 * WHY THIS EXISTS
 *   The account's CC-116 gate mirrors `k >= requiredQuorum()` whenever `committeeActive()` is true.
 *   If the validator is armed but `requiredQuorum()` is the UINT256_MAX sentinel, that mirror can never
 *   hold => tier-2/3 is fully fail-closed while every individual getter still looks fine. That exact
 *   state once went unseen for ~10 hours upstream. This check exists to make it visible in minutes.
 *
 * ANTI-STALENESS (the #252 failure mode, killed structurally)
 *   The validator address is NEVER hardcoded. We read it from the router at algId 0x01 every run, so
 *   swapping validators (v0.32.0 -> v0.33.0 did exactly that) can never leave this check "green forever
 *   against the old address". Set EXPECTED_COMMITTEE to additionally pin the expected value.
 *
 * THREE TIERS (two is not enough)
 *   requiredQuorum() needs _epochUsable(e) AND _epochUsable(e-1), but snapshotEpoch cannot run until
 *   block > epochStart. So every epoch rollover has a STRUCTURAL ~2-3 block window where the sentinel is
 *   CORRECT and e-1 is still serving. Alerting on it would page every ~13 min (L=64) and train operators
 *   to ignore this check — and that alert fatigue is what made the earlier outage last 10 hours.
 *     OK       armed + requiredQuorum satisfiable
 *     WARN     armed + sentinel + e unpinned + e-1 usable + (block-epochStart) <= K   (normal keeper latency)
 *     CRITICAL armed + sentinel + same shape but (block-epochStart) > K               (keeper is late)
 *     CRITICAL armed + sentinel + any other shape (e-1 unpinned / past pin window)    (real failure)
 *     WARN     committee OFF — safe (CC-116 fail-closes tier-2/3) but notable for a production stack
 *
 * K CALIBRATION — empirically validated, not guessed (default 20 blocks, ~4 min)
 *   K is really an AVAILABILITY POLICY, not a measurement of keeper speed: while epoch e is unpinned,
 *   requiredQuorum() is the sentinel and tier-2/3 is fail-closed regardless of e-1. So K answers "how long
 *   may tier-2/3 be down before this is an incident", and the measurements only tell us whether K will
 *   produce false pages. Both available boundaries were replayed with AT_BLOCK:
 *     epoch 181318 (healthy keeper, self-pinned): unpinned 0-2 blocks in -> WARN, pinned by block 3.
 *                  => K=20 stays quiet through normal operation (true negative).
 *     epoch 181317 (keeper BROKEN, pinned manually): still unpinned 22 blocks in -> CRITICAL.
 *                  => K=20 fires on a genuinely degraded stack (true positive).
 *   So K=20 separates healthy from broken on both samples we have. Retest with AT_BLOCK after collecting
 *   more boundaries; if a healthy keeper is ever seen pinning later than ~10 blocks, raise K rather than
 *   accept a recurring false CRITICAL — a page every epoch is the alert fatigue this design exists to avoid.
 *
 * Exit: 0 = OK/WARN, 1 = CRITICAL.
 * Usage: node scripts/committee-health.mjs
 */
import { createPublicClient, http, getAddress } from "viem";
import { sepolia } from "viem/chains";

const RPC = process.env.SEPOLIA_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com";
const ROUTER = getAddress(process.env.AIRACCOUNT_ROUTER || "0xA97A752779ebfDA58612F6727Ec7C8366c39f897");
const EXPECTED = process.env.EXPECTED_COMMITTEE ? getAddress(process.env.EXPECTED_COMMITTEE) : null;
const K = BigInt(process.env.KEEPER_LATENCY_BLOCKS ?? "20");
// Optional historical replay: evaluate the verdict as of a past block. Used to prove each tier fires
// when it should (a check whose branches were never exercised is not a check).
const AT_BLOCK = process.env.AT_BLOCK ? BigInt(process.env.AT_BLOCK) : null;
const UINT256_MAX = 2n ** 256n - 1n;

const ROUTER_ABI = [{ name: "getAlgorithm", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] }];
const CV_ABI = [
  { name: "committeeActive", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "requiredQuorum", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "epochLength", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "epochPinned", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "getRegisteredNodeCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 30_000 }) });
const r = (address, abi, functionName, args) =>
  pub.readContract({ address, abi, functionName, args, ...(AT_BLOCK ? { blockNumber: AT_BLOCK } : {}) });

let verdict = "OK", detail = "";
const fail = (v, d) => { verdict = v; detail = d; };

try {
  const committee = getAddress(await r(ROUTER, ROUTER_ABI, "getAlgorithm", [1]));
  console.log(`router   ${ROUTER}`);
  console.log(`0x01  -> ${committee}${EXPECTED ? (committee === EXPECTED ? "  (matches EXPECTED_COMMITTEE)" : "  ⚠️ DOES NOT MATCH EXPECTED_COMMITTEE " + EXPECTED) : ""}`);
  if (EXPECTED && committee !== EXPECTED) {
    fail("CRITICAL", `router 0x01 is ${committee}, expected ${EXPECTED} — the stack mounts a different validator than pinned`);
  } else {
    const code = await pub.getBytecode({ address: committee, ...(AT_BLOCK ? { blockNumber: AT_BLOCK } : {}) });
    if (!code || code === "0x") {
      fail("CRITICAL", `committee validator ${committee} has no code`);
    } else {
      const [armed, rq, L, nodes] = await Promise.all([
        r(committee, CV_ABI, "committeeActive"), r(committee, CV_ABI, "requiredQuorum"),
        r(committee, CV_ABI, "epochLength"), r(committee, CV_ABI, "getRegisteredNodeCount"),
      ]);
      const bn = AT_BLOCK ?? await pub.getBlockNumber();
      const e = L > 0n ? bn / L : 0n, start = e * L, off = bn - start;
      const [pinnedE, pinnedPrev] = L > 0n
        ? await Promise.all([r(committee, CV_ABI, "epochPinned", [e]), r(committee, CV_ABI, "epochPinned", [e - 1n])])
        : [false, false];
      const cap = L - 1n < 256n ? L - 1n : 256n;
      console.log(`state    armed=${armed} requiredQuorum=${rq === UINT256_MAX ? "SENTINEL" : rq} nodes=${nodes} L=${L}`);
      console.log(`epoch    e=${e} off=${off}/${cap} pinned(e)=${pinnedE} pinned(e-1)=${pinnedPrev}  block=${bn}`);

      if (!armed) {
        fail("WARN", "committee is OFF — CC-116 fail-closes tier-2/3 (safe, but unexpected for a production stack)");
      } else if (rq !== UINT256_MAX && rq >= 1n) {
        detail = `armed and satisfiable (requiredQuorum=${rq})`;
      } else if (!pinnedE && pinnedPrev && off <= cap && off <= K) {
        fail("WARN", `structural keeper-latency window — epoch ${e} not yet pinned (${off} blocks in, K=${K}), e-1 still serving. Normal.`);
      } else if (!pinnedE && pinnedPrev && off <= cap) {
        fail("CRITICAL", `keeper is LATE — epoch ${e} unpinned ${off} blocks in (K=${K}); tier-2/3 fail-closed`);
      } else {
        fail("CRITICAL", `sentinel OUTSIDE the structural window — pinned(e)=${pinnedE} pinned(e-1)=${pinnedPrev} off=${off}/${cap}; tier-2/3 fail-closed`);
      }
    }
  }
} catch (err) {
  fail("CRITICAL", `health check could not complete: ${err?.shortMessage ?? err?.message ?? err}`);
}

console.log(`\n${verdict === "OK" ? "✅" : verdict === "WARN" ? "⚠️" : "❌"} ${verdict}${detail ? " — " + detail : ""}`);
process.exit(verdict === "CRITICAL" ? 1 : 0);
