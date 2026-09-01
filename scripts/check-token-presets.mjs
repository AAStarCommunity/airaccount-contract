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
 * limits can still be self-inconsistent before an address exists. Such a token is not
 * fully verified until the address is filled in and this runs again against the chain.
 *
 * Usage: node scripts/check-token-presets.mjs [--chain 10]
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
  aPNTs: { conservative: ["100", "1000", "5000"],    standard: ["500", "5000", "10000"],  trader: ["2000", "20000", "50000"] },
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

const presets = JSON.parse(readFileSync(new URL("../configs/token-presets.json", import.meta.url), "utf-8"));

let failures = 0, verified = 0, declaredOnly = 0;

for (const [chainId, chain] of Object.entries(presets.chains)) {
  if (only && chainId !== only) continue;
  const rpc = RPCS[chainId];
  if (!rpc) { console.log(`chain ${chainId} (${chain._name}): no RPC configured, skipping`); continue; }
  const client = createPublicClient({ transport: http(rpc) });
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
        onchain = Number(await client.readContract({ address: t.address, abi: DECIMALS_ABI, functionName: "decimals" }));
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

console.log(
  `\n${failures === 0 ? "OK" : "FAIL"} — ${verified} verified against chain, ` +
  `${declaredOnly} declared-only (address TBD), ${failures} failure(s)`
);
if (failures > 0) process.exitCode = 1;
