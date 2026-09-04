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
 * Exit: 0 = OK/WARN, 1 = CRITICAL (determinate), 2 = UNDETERMINED (could not complete the read).
 * Usage: node scripts/committee-health.mjs
 */
import { createPublicClient, http, getAddress } from "viem";
import { sepolia } from "viem/chains";

const RPC = process.env.SEPOLIA_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com";
// The VALIDATOR is derived from the router every run, which is what stops this check going
// green-forever against a retired validator. The ROUTER itself is not: it falls back to a built-in
// address, and nothing forces anyone to update it when the stack moves. That is the same failure
// mode, one level up -- after the next deploy this would happily keep reporting OK about a stack
// nobody uses. It cannot be fixed by picking a better default, so make the choice VISIBLE: say
// whether a human selected this router or the file did.
const ROUTER_DEFAULT_STACK = "v0.33.0";
const ROUTER_DEFAULT = "0xA97A752779ebfDA58612F6727Ec7C8366c39f897"; // ${ROUTER_DEFAULT_STACK}
const ROUTER_IS_DEFAULT = !process.env.AIRACCOUNT_ROUTER;
const ROUTER = getAddress(process.env.AIRACCOUNT_ROUTER || ROUTER_DEFAULT);
const EXPECTED = process.env.EXPECTED_COMMITTEE ? getAddress(process.env.EXPECTED_COMMITTEE) : null;
// `||` not `??`: on the SCHEDULE path GitHub expands an unset `inputs.*` to the EMPTY STRING, and
// `?? ` does not catch "" — BigInt("") === 0n, which would make K=0 and flip every normal keeper
// window (off 1-3, unpinned) from WARN to CRITICAL (~4-5 false pages/day at L=64). Local runs and
// workflow_dispatch both hide this (undefined / real value); only the scheduled context triggers it,
// which is exactly how this check normally runs.
const K = BigInt(process.env.KEEPER_LATENCY_BLOCKS || "20");
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
  { name: "configVersion", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "epochConfigVersion", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "epochSetValidUntil", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "minCommittee", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 30_000 }) });
// ATOMICITY: every read is pinned to ONE block. Reading fields at "latest" independently lets them
// straddle a block boundary and synthesise a state that existed at no single block — and the skew
// window coincides exactly with the epoch rollover, i.e. the only moment this check has anything to
// say. That produced a false CRITICAL (rq read pre-pin, epochPinned read post-pin => "sentinel with
// both epochs pinned", which is unreachable in reality).
let AT = AT_BLOCK; // ASSIGNED here, but RESOLVED as the first statement inside the try below —
// viem treats blockNumber:null as "latest" without throwing, so leaving it null for even one read
// silently un-pins that read. That asymmetry (pinned under AT_BLOCK replay, latest when live) is
// exactly what hid the original read-skew bug from every replay I ran.
const r = (address, abi, functionName, args) =>
  pub.readContract({ address, abi, functionName, args, blockNumber: AT });

let verdict = "OK", detail = "";
const fail = (v, d) => { verdict = v; detail = d; };

try {
  // FIRST statement in the try: every read after this point — including deriving the validator and
  // fetching its code — is pinned to this one block.
  AT = AT_BLOCK ?? await pub.getBlockNumber();
  // BEFORE the first read that can fail. When the router does not answer, this line is the only
  // diagnostic an operator gets -- and it is exactly the branch where they cannot guess the address
  // or whether anyone chose it. Printing it after getAlgorithm made this whole feature invisible in
  // the one case it was added for.
  console.log(`router   ${ROUTER}${ROUTER_IS_DEFAULT
    ? `  ⚠️ BUILT-IN DEFAULT (${ROUTER_DEFAULT_STACK}) — no AIRACCOUNT_ROUTER set, so this watches that stack even after the stack moves`
    : "  (from AIRACCOUNT_ROUTER)"}`);

  const committee = getAddress(await r(ROUTER, ROUTER_ABI, "getAlgorithm", [1]));
  console.log(`0x01  -> ${committee}${EXPECTED ? (committee === EXPECTED ? "  (matches EXPECTED_COMMITTEE)" : "  ⚠️ DOES NOT MATCH EXPECTED_COMMITTEE " + EXPECTED) : ""}`);
  if (EXPECTED && committee !== EXPECTED) {
    fail("CRITICAL", `router 0x01 is ${committee}, expected ${EXPECTED} — the stack mounts a different validator than pinned`);
  } else {
    const code = await pub.getBytecode({ address: committee, blockNumber: AT });
    if (!code || code === "0x") {
      fail("CRITICAL", `committee validator ${committee} has no code`);
    } else {
      const blk = await pub.getBlock({ blockNumber: AT });
      // Generation probe, by ABSENCE — not by parsing error text. A CALL_EXCEPTION never carries the
      // method name (only the selector), so text matching for "minCommittee" can never fire; and
      // branching the OUTER catch on e.code would misread a genuine revert on the CURRENT validator as
      // "old contract". So: probe the CC-98-hardening-only getters individually and let their absence
      // identify the generation. (dvt's own health check states the principle: inferring a contract
      // generation from an error with several possible causes is how a flaky RPC gets printed as fact.)
      // Pass real args: epochSetValidUntil takes a uint256, so probing it with none fails even where
      // it EXISTS — that mistake marked the LIVE v0.33 validator as retired until the control run
      // caught it. Both are plain mapping/immutable getters, so any epoch key is a safe probe.
      //
      // A bare `catch { return false }` here read "the RPC hiccuped" as "the getter does not exist" —
      // the exact mistake the paragraph above warns about, committed one line below it. Observed:
      // one run reported epochSetValidUntil=ABSENT while minCommittee=present, and a run five blocks
      // later found both present. A deployed contract's ABI does not change, so the ABSENT was
      // transport noise printed as a fact about the stack — and the message it produced sent the
      // reader to investigate a validator swap that had not happened.
      //
      // So a failed probe now has to survive a POSITIVE CONTROL before it may be called absence:
      // re-read a getter that exists on every generation of this contract — verified by selector
      // against the retired 0x1A8Db639 bytecode: configVersion (dd64d24d) present, minCommittee and
      // epochSetValidUntil absent, so pointing at an old stack still lands on the ABI verdict rather
      // than this one. Control fails ⇒ we could not look, which is a different verdict and a
      // different message.
      //
      // What the control does NOT establish: it runs AFTER the probe, so it shows the RPC was
      // answering at t1, not at t0 when the probe failed. A hiccup that clears inside one round trip
      // is still recorded as absence. Narrowing that further needs a multicall or a control on each
      // side of the probe, which costs more than the residue is worth — but do not read this as
      // "a failed probe proves the function is missing". It only rules out an outage still in
      // progress a moment later.
      let transportFailed = false;
      const probe = async (fn, args) => {
        try { await r(committee, CV_ABI, fn, args); return true; } catch {
          try { await r(committee, CV_ABI, "configVersion"); return false; }
          catch { transportFailed = true; return false; }
        }
      };
      const [hasMinCommittee, hasValidUntil] = await Promise.all([probe("minCommittee"), probe("epochSetValidUntil", [0n])]);
      if (transportFailed) {
        fail("UNDETERMINED", `could not probe the validator's ABI — the control read (configVersion) failed too, so this says nothing about which generation ${committee} is, and nothing about stack health`);
      } else if (!hasMinCommittee || !hasValidUntil) {
        fail("UNDETERMINED", `validator predates this check's ABI (minCommittee=${hasMinCommittee ? "present" : "ABSENT"}, epochSetValidUntil=${hasValidUntil ? "present" : "ABSENT"}) — the router points at ${committee}, which lacks the CC-98 hardening getters (e.g. the retired v0.31/v0.32 stack on 0x1A8Db639). This check covers v0.33.0+ only.`);
      } else {
      const [armed, rq, L, nodes, cfg] = await Promise.all([
        r(committee, CV_ABI, "committeeActive"), r(committee, CV_ABI, "requiredQuorum"),
        r(committee, CV_ABI, "epochLength"), r(committee, CV_ABI, "getRegisteredNodeCount"),
        r(committee, CV_ABI, "configVersion"),
      ]);
      const bn = AT;
      const e = L > 0n ? bn / L : 0n, start = e * L, off = bn - start;
      // _epochUsable(x) is THREE conjuncts, not just epochPinned — modelling only the first one makes
      // a config bump or an expired set look like "both pinned yet sentinel", i.e. inexplicable.
      const usable = async (x) => {
        const [pinned, cv, validUntil] = await Promise.all([
          r(committee, CV_ABI, "epochPinned", [x]), r(committee, CV_ABI, "epochConfigVersion", [x]),
          r(committee, CV_ABI, "epochSetValidUntil", [x]),
        ]);
        const ok = pinned && cv === cfg && blk.timestamp < validUntil;
        return { ok, pinned, cvOk: cv === cfg, fresh: blk.timestamp < validUntil };
      };
      const [uE, uPrev] = await Promise.all([usable(e), usable(e - 1n)]);
      const pinnedE = uE.ok, pinnedPrev = uPrev.ok;
      const why = (u) => `pinned=${u.pinned} cfgMatch=${u.cvOk} notExpired=${u.fresh}`;
      const cap = L - 1n < 256n ? L - 1n : 256n;
      console.log(`state    armed=${armed} requiredQuorum=${rq === UINT256_MAX ? "SENTINEL" : rq} nodes=${nodes} L=${L}`);
      console.log(`epoch    e=${e} off=${off}/${cap} usable(e)=${pinnedE} [${why(uE)}] usable(e-1)=${pinnedPrev} [${why(uPrev)}]  block=${bn}`);

      if (!armed) {
        fail("WARN", "committee is OFF — CC-116 fail-closes tier-2/3 (safe, but unexpected for a production stack)");
      } else if (rq !== UINT256_MAX && rq >= 1n) {
        detail = `armed and satisfiable (requiredQuorum=${rq})`;
      } else if (!pinnedE && pinnedPrev && off <= cap && off <= K) {
        fail("WARN", `structural keeper-latency window — epoch ${e} not yet pinned (${off} blocks in, K=${K}), e-1 still serving. Normal.`);
      } else if (!pinnedE && pinnedPrev && off <= cap) {
        fail("CRITICAL", `keeper is LATE — epoch ${e} unpinned ${off} blocks in (K=${K}); tier-2/3 fail-closed`);
      } else {
        fail("CRITICAL", `sentinel OUTSIDE the structural window — usable(e)=${pinnedE} [${why(uE)}] usable(e-1)=${pinnedPrev} [${why(uPrev)}] off=${off}/${cap}; tier-2/3 fail-closed`);
      }
    }
    }
  }
} catch (err) {
  // UNDETERMINED, not CRITICAL. A transport/RPC failure says NOTHING about the stack, and the RPC
  // falls back to a public endpoint by default, so one rate-limit or blip reaches here. Emitting
  // CRITICAL would make the alert assert "tier-2/3 is fail-closed" — a claim we have no evidence
  // for. Distinct exit code so the alerting layer can word it correctly.
  fail("UNDETERMINED", `health check could not complete (says nothing about stack health): ${err?.shortMessage ?? err?.message ?? err}`);
}

const icon = { OK: "✅", WARN: "⚠️", UNDETERMINED: "❓", CRITICAL: "❌" }[verdict] ?? "❌";
// Machine-readable, because the exit code cannot carry this: OK and WARN share 0, and one WARN
// ("committee is OFF") means tier-2/3 is STILL unavailable. Anything deciding "is it resolved?"
// must read the verdict, not the code.
console.log(`verdict=${verdict}`);
console.log(`\n${icon} ${verdict}${detail ? " — " + detail : ""}`);
// 0 = OK/WARN, 1 = CRITICAL (determinate: the stack is bad), 2 = UNDETERMINED (we could not look).
process.exit(verdict === "CRITICAL" ? 1 : verdict === "UNDETERMINED" ? 2 : 0);
