#!/usr/bin/env node
/**
 * Assert configs/token-presets.json agrees with the chains it describes.
 *
 * The limits in that file are RAW base units and are fed verbatim into createAccount's
 * token configs (loadTokenPresets in scripts/deploy-op-mainnet.ts:82, deploy-m5.ts:86,
 * deploy-m6-r2.ts:80), where they bake into a guard that is bound once in `initialize`
 * and can only ever be tightened — `addTokenConfig` reverts with TokenAlreadyConfigured
 * and `decreaseTokenDailyLimit` refuses any increase. A wrong limit is therefore not a
 * config mistake you fix later; it is permanent for every account already created.
 *
 * The `decimals` field is documentation — no code reads it — so it cannot be the only
 * assertion here. The LIMITS are load-bearing, so they are checked against an expected
 * human amount declared below, independently of the file. Checking decimals alone passes
 * a file whose decimals were corrected but whose limits were left at the old scale, which
 * is the bug itself (CC-46 B3).
 *
 * Per token:
 *   1. preset decimals == on-chain decimals()          [tokens with a real address]
 *   2. every tier/daily limit == expected human amount scaled by decimals   [always]
 *   3. dailyLimit >= tier2Limit >= tier1Limit          [always]
 *
 * Tokens whose address is still "TBD" are checked against their DECLARED decimals — the
 * limits can still be self-inconsistent before an address exists. That path cannot, by
 * construction, catch a token whose declared decimals are simply wrong but whose limits
 * agree with them: that is the original bug's exact shape, and it would pass. Two things
 * close it:
 *
 *   - CROSS-CHAIN CONSISTENCY (always on): one symbol must declare the same decimals on
 *     every chain, and if ANY chain has a real address, every chain's declaration must
 *     equal what that chain reports. aPNTs verified at 18 on Sepolia therefore convicts a
 *     `"decimals": 6` on chain 10 while its address is still TBD.
 *   - --require-verified: treat any declared-only token as a failure. This is what the
 *     pre-deploy gate should use, so passing is `EXIT=0` rather than a human reading the
 *     word "DECLARED" out of a line of output.
 *
 * Usage: node scripts/check-token-presets.mjs [--chain 10] [--require-verified]
 * Exit 0 = all good, 1 = a mismatch, 2 = could not reach a chain.
 */
import { readFileSync } from "node:fs";
import { createPublicClient, http, parseUnits } from "viem";

const RPCS = {
  "1": process.env.MAINNET_RPC ?? "https://ethereum-rpc.publicnode.com",
  "10": process.env.OP_MAINNET_RPC ?? "https://optimism-rpc.publicnode.com",
  "8453": process.env.BASE_RPC ?? "https://base-rpc.publicnode.com",
  "11155111": process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com",
};

/**
 * Intended human-readable limits, as decimal strings: [tier1, tier2, daily].
 * This is the expectation the file is checked AGAINST, so it must be maintained by hand —
 * deriving it from the file being checked would make the check circular and always pass.
 * Same amounts on every chain; scaling is applied per-token from that token's decimals.
 */
const EXPECTED = {
  USDC:  { conservative: ["100", "1000", "5000"],    standard: ["500", "5000", "10000"],  trader: ["2000", "20000", "50000"] },
  USDT:  { conservative: ["100", "1000", "5000"],    standard: ["500", "5000", "10000"],  trader: ["2000", "20000", "50000"] },
  WETH:  { conservative: ["0.1", "1", "5"],          standard: ["0.5", "5", "10"],        trader: ["2", "10", "50"] },
  WBTC:  { conservative: ["0.01", "0.1", "0.5"],     standard: ["0.05", "0.5", "1"],      trader: ["0.2", "2", "5"] },
  aPNTs: { conservative: ["1500", "15000", "75000"], standard: ["7500", "75000", "150000"], trader: ["30000", "300000", "750000"] },
};

const PROFILES = ["conservative", "standard", "trader"];
const LIMIT_KEYS = ["tier1Limit", "tier2Limit", "dailyLimit"];

const DECIMALS_ABI = [
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];

// Exact base-units -> human string. Number(bigint)/10**d loses precision and prints
// things like 49999.99999999999, which makes a correct value look wrong.
function human(raw, decimals) {
  const v = BigInt(raw);
  const base = 10n ** BigInt(decimals);
  const frac = (v % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${v / base}.${frac}` : `${v / base}`;
}

const only = process.argv.includes("--chain")
  ? process.argv[process.argv.indexOf("--chain") + 1]
  : null;
const requireVerified = process.argv.includes("--require-verified");

const presets = JSON.parse(readFileSync(new URL("../configs/token-presets.json", import.meta.url), "utf-8"));

let failures = 0, verified = 0, declaredOnly = 0;

const clientFor = (chainId) => createPublicClient({ transport: http(RPCS[chainId]) });
const readDecimals = (chainId, address) =>
  clientFor(chainId).readContract({ address, abi: DECIMALS_ABI, functionName: "decimals" });

/**
 * Pass 1 — establish, per symbol, what the chains actually say. This runs over EVERY chain
 * regardless of --chain: the cross-chain invariant is only useful if the truth can come from
 * a chain other than the one being checked, which is the whole point when the checked chain's
 * address is still TBD.
 */
const truth = new Map(); // symbol -> { decimals, chainId, address }
const unreachable = [];
for (const [chainId, chain] of Object.entries(presets.chains)) {
  if (!RPCS[chainId]) continue;
  for (const [symbol, t] of Object.entries(chain.tokens ?? {})) {
    if (!t.address || t.address === "TBD") continue;
    let d;
    try {
      d = Number(await readDecimals(chainId, t.address));
    } catch (e) {
      unreachable.push(`${symbol}@${chainId}: ${e.shortMessage ?? e.message}`);
      continue;
    }
    const prior = truth.get(symbol);
    if (prior && prior.decimals !== d) {
      if (t.decimalsIntentionallyDiffers || prior.declaredDiffers) {
        console.log(
          `note ${symbol}: decimals differ across chains on purpose — ${prior.decimals} on chain ` +
          `${prior.chainId}, ${d} on chain ${chainId}`
        );
      } else {
        console.error(
          `FAIL ${symbol}: chains disagree on decimals — ${prior.decimals} at ${prior.address} ` +
          `(chain ${prior.chainId}) vs ${d} at ${t.address} (chain ${chainId})`
        );
        console.error(
          `     if this is genuinely correct, set "decimalsIntentionallyDiffers": "<why>" on the token entry`
        );
        failures++;
      }
      continue;
    }
    if (!prior) truth.set(symbol, { decimals: d, chainId, address: t.address, declaredDiffers: !!t.decimalsIntentionallyDiffers });
  }
}
// Pass 1b — the roster. Every check above compares rows that ARE there; none of them notices a row
// that stopped being there, so the exit code had a second road to 0: "fewer things to verify".
// Deleting one entry is the sharp case — dropping aPNTs from Sepolia removes the only chain that
// carries it, which silently un-anchors the cross-chain rule and lets a wrong declaration back
// through on chain 10. Absence, not disagreement, is the blind spot.
const seen = new Map(); // symbol -> [{chainId, decimals, hasAddress}]
for (const [chainId, chain] of Object.entries(presets.chains)) {
  const tokens = Object.entries(chain.tokens ?? {});
  if (tokens.length === 0) {
    console.error(`FAIL chain ${chainId} (${chain._name}) declares no tokens — nothing here can be checked`);
    failures++;
  }
  for (const [symbol, t] of tokens) {
    if (!seen.has(symbol)) seen.set(symbol, []);
    seen.get(symbol).push({ chainId, decimals: t.decimals, hasAddress: !!t.address && t.address !== "TBD" });
  }
}
for (const symbol of Object.keys(EXPECTED)) {
  const rows = seen.get(symbol);
  if (!rows) {
    console.error(`FAIL ${symbol}: declared in EXPECTED but present on no chain — it was removed, or never added`);
    failures++;
    continue;
  }
  // Declarations must agree with each other even when no chain can arbitrate. Without this, wiping
  // the one chain that carries a symbol turns two contradictory declarations into two passes.
  //
  // The guard tests only that the declarations disagree, so the message must not assert anything
  // about arbitration being unavailable — that is a separate fact, and it is checked here rather
  // than assumed. Saying "no chain carries it" above a line that then quotes a chain sends the
  // reader looking for a deployment that is not missing, and the false sentence prints first.
  const decls = [...new Set(rows.map((r) => r.decimals))];
  const hatched = Object.values(presets.chains).some((c) => c.tokens?.[symbol]?.decimalsIntentionallyDiffers);
  if (decls.length > 1 && !hatched) {
    const arbiter = truth.get(symbol);
    console.error(
      `FAIL ${symbol}: chains declare different decimals (${rows.map((r) => `${r.decimals}@${r.chainId}`).join(", ")})` +
      (arbiter
        ? ` — chain ${arbiter.chainId} reads ${arbiter.decimals} from ${arbiter.address}, so the others are wrong`
        : ` and no chain carries it to arbitrate`)
    );
    console.error(`     if this is genuinely correct, set "decimalsIntentionallyDiffers": "<why>" on the token entry`);
    failures++;
  }
  // A hard failure, not a warning. Dropping the one entry that carries a real address leaves the
  // remaining declarations self-consistent with nothing to check them against — which is how
  // deleting Sepolia's aPNTs quietly reopened the wrong-decimals case on chain 10. A warning is
  // exactly what gets scrolled past, and "the check went quiet" is the failure this file exists for.
  // The remedy is to deploy the token somewhere (testnet counts) or to keep it out of EXPECTED until
  // it exists — not to leave it unverifiable.
  if (!rows.some((r) => r.hasAddress)) {
    console.error(
      `FAIL ${symbol}: no chain gives it a real address, so nothing can verify its decimals — ` +
      `deploy it on at least one chain (testnet counts) or remove it from EXPECTED`
    );
    failures++;
  }
}

if (unreachable.length) {
  console.warn(`warning: could not read decimals for ${unreachable.length} token(s) — cross-chain truth is partial`);
  for (const u of unreachable) console.warn(`  ${u}`);
}

if (only && !presets.chains[only]) {
  console.error(`FAIL --chain ${only}: no such chain in token-presets.json — nothing would be checked`);
  process.exitCode = 1;
  process.exit();
}

for (const [chainId, chain] of Object.entries(presets.chains)) {
  if (only && chainId !== only) continue;
  // A chain present in the presets but absent from RPCS used to be skipped in silence, which
  // is the same empty-set hazard as an unknown --chain: nothing checked, still green.
  if (!RPCS[chainId]) {
    console.error(`  chain ${chainId} (${chain._name}): FAIL no RPC configured — its tokens cannot be checked`);
    failures++;
    continue;
  }
  console.log(`\nchain ${chainId} — ${chain._name}`);

  for (const [symbol, t] of Object.entries(chain.tokens ?? {})) {
    const expected = EXPECTED[symbol];
    if (!expected) {
      console.error(`  ${symbol.padEnd(6)} FAIL no expected limits declared in this script — add them`);
      failures++;
      continue;
    }

    // ── decimals: from chain when we have an address, else the declared value ──
    const isTBD = !t.address || t.address === "TBD";
    let decimals = t.decimals;
    if (!isTBD) {
      let onchain;
      try {
        onchain = Number(await readDecimals(chainId, t.address));
      } catch (e) {
        console.error(`  ${symbol.padEnd(6)} FAILED to read decimals() at ${t.address}: ${e.shortMessage ?? e.message}`);
        process.exitCode = 2;
        continue;
      }
      if (onchain !== t.decimals) {
        console.error(`  ${symbol.padEnd(6)} FAIL decimals: preset=${t.decimals} onchain=${onchain} (${t.address})`);
        failures++;
        continue;
      }
      decimals = onchain;
    }

    // ── cross-chain: a declaration is convicted by any chain that carries this symbol ──
    // A symbol legitimately having different decimals per chain is real (USDT is 6 on
    // Ethereum and 18 on BNB Chain), so the rule has a declared exit rather than only a
    // way around it — otherwise the cheapest response to a false positive is deleting the
    // rule. The failure message names the exit so the next person does not have to find it.
    const known = truth.get(symbol);
    if (known && known.decimals !== t.decimals && t.decimalsIntentionallyDiffers) {
      console.log(`  ${symbol.padEnd(6)} cross-chain decimals differ on purpose: ${t.decimalsIntentionallyDiffers}`);
    } else if (known && known.decimals !== t.decimals) {
      console.error(
        `  ${symbol.padEnd(6)} FAIL decimals: declared ${t.decimals} here, but ${known.decimals} on chain ` +
        `${known.chainId} (${known.address}, read from chain)`
      );
      if (isTBD) console.error(`           address is TBD here, so only this cross-chain check can see it`);
      console.error(
        `           if this is genuinely correct (a token really does differ per chain), set ` +
        `"decimalsIntentionallyDiffers": "<why>" on this token entry`
      );
      failures++;
      continue;
    }

    if (isTBD && requireVerified) {
      console.error(`  ${symbol.padEnd(6)} FAIL address is TBD — --require-verified demands a real address`);
      failures++;
      continue;
    }

    // ── limits: the load-bearing check, against an expectation outside this file ──
    const problems = [];
    const shown = [];
    for (const profile of PROFILES) {
      const limits = t[profile];
      if (!limits) { problems.push(`${profile}: missing`); continue; }
      const want = expected[profile];
      LIMIT_KEYS.forEach((key, i) => {
        const got = BigInt(limits[key]);
        const exp = parseUnits(want[i], decimals);
        if (got !== exp) {
          problems.push(
            `${profile}.${key}: file says ${human(got, decimals)} ${symbol}, expected ${want[i]} ` +
            `(raw ${got} vs ${exp})`
          );
        }
      });
      const [t1, t2, dl] = LIMIT_KEYS.map((k) => BigInt(limits[k]));
      if (!(dl >= t2 && t2 >= t1)) problems.push(`${profile}: needs dailyLimit >= tier2Limit >= tier1Limit`);
      shown.push(`${profile[0]}=${LIMIT_KEYS.map((k) => human(limits[k], decimals)).join("/")}`);
    }

    if (problems.length) {
      console.error(`  ${symbol.padEnd(6)} FAIL limits (decimals=${decimals}${isTBD ? ", declared" : ""})`);
      for (const p of problems) console.error(`           ${p}`);
      failures++;
      continue;
    }

    if (isTBD) {
      declaredOnly++;
      console.log(`  ${symbol.padEnd(6)} OK against DECLARED decimals=${decimals}  ${shown.join("  ")}`);
      console.log(`           ^ address is TBD — NOT verified against a chain. Fill the address, then re-run before deploying.`);
    } else {
      verified++;
      console.log(`  ${symbol.padEnd(6)} OK decimals=${decimals}  ${shown.join("  ")}`);
    }
  }
}

// --require-verified means "every token was verified against a chain". An empty token set
// satisfies that vacuously, so a mistyped --chain or a dropped RPCS entry would pass a gate
// that looked at nothing. Matching zero rows and matching every row must not both be green.
if (requireVerified && verified === 0 && failures === 0) {
  console.error(`FAIL --require-verified: the gate matched no tokens, so it verified nothing`);
  failures++;
}

console.log(
  `\n${failures === 0 ? "OK" : "FAIL"} — ${verified} verified against chain, ` +
  `${declaredOnly} declared-only (address TBD), ${failures} failure(s)` +
  (requireVerified ? "  [--require-verified]" : "")
);
if (failures > 0) process.exitCode = 1;
