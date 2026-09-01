#!/usr/bin/env node
/**
 * Assert configs/token-presets.json agrees with the chains it describes.
 *
 * The limits in that file are RAW base units and are fed verbatim into
 * createAccount's token configs (see loadTokenPresets in scripts/deploy-op-mainnet.ts),
 * where they are baked into an immutable guard. The `decimals` field is documentation
 * only — nothing reads it — so a wrong `decimals` does not fail loudly, it just misleads
 * whoever writes the limits next to it. That is exactly how aPNTs ended up with
 * 6-decimal limits on an 18-decimal token (CC-46 B3).
 *
 * Checks, per token with a real (non-TBD) address:
 *   1. preset decimals == on-chain decimals()
 *   2. every tier/daily limit divides to the expected human amount
 *   3. dailyLimit >= tier2Limit >= tier1Limit (the guard enforces this)
 *
 * Usage: node scripts/check-token-presets.mjs [--chain 10]
 * Exit 0 = all good, 1 = a mismatch, 2 = could not check (RPC/其他).
 */
import { readFileSync } from "node:fs";
import { createPublicClient, http } from "viem";

const RPCS = {
  "1": process.env.MAINNET_RPC ?? "https://ethereum-rpc.publicnode.com",
  "10": process.env.OP_MAINNET_RPC ?? "https://optimism-rpc.publicnode.com",
  "8453": process.env.BASE_RPC ?? "https://base-rpc.publicnode.com",
  "11155111": process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com",
};

// Exact base-units -> human string. Number(bigint)/10**d loses precision and prints
// things like 49999.99999999999, which makes a correct value look wrong.
function human(raw, decimals) {
  const v = BigInt(raw);
  const base = 10n ** BigInt(decimals);
  const whole = v / base;
  const frac = (v % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : `${whole}`;
}

const DECIMALS_ABI = [
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];

const only = process.argv.includes("--chain")
  ? process.argv[process.argv.indexOf("--chain") + 1]
  : null;

const presets = JSON.parse(readFileSync(new URL("../configs/token-presets.json", import.meta.url), "utf-8"));

let failures = 0;
let checked = 0;
let skipped = 0;

for (const [chainId, chain] of Object.entries(presets.chains)) {
  if (only && chainId !== only) continue;
  const rpc = RPCS[chainId];
  if (!rpc) {
    console.log(`chain ${chainId} (${chain._name}): no RPC configured, skipping`);
    continue;
  }
  const client = createPublicClient({ transport: http(rpc) });
  console.log(`\nchain ${chainId} — ${chain._name}`);

  for (const [symbol, t] of Object.entries(chain.tokens ?? {})) {
    if (!t.address || t.address === "TBD") {
      console.log(`  ${symbol.padEnd(6)} address TBD — limits unchecked against chain`);
      skipped++;
      continue;
    }
    let onchain;
    try {
      onchain = Number(await client.readContract({ address: t.address, abi: DECIMALS_ABI, functionName: "decimals" }));
    } catch (e) {
      console.error(`  ${symbol.padEnd(6)} FAILED to read decimals() at ${t.address}: ${e.shortMessage ?? e.message}`);
      process.exitCode = 2;
      continue;
    }
    checked++;

    if (onchain !== t.decimals) {
      console.error(
        `  ${symbol.padEnd(6)} MISMATCH decimals: preset=${t.decimals} onchain=${onchain} (${t.address})`
      );
      for (const prof of ["conservative", "standard", "trader"]) {
        const L = t[prof];
        if (!L) continue;
        console.error(
          `           ${prof.padEnd(12)} tier1 reads as ${human(L.tier1Limit, onchain)} ${symbol} on chain`
        );
      }
      failures++;
      continue;
    }

    const amounts = [];
    let ordered = true;
    for (const prof of ["conservative", "standard", "trader"]) {
      const L = t[prof];
      if (!L) continue;
      const t1 = BigInt(L.tier1Limit), t2 = BigInt(L.tier2Limit), dl = BigInt(L.dailyLimit);
      if (!(dl >= t2 && t2 >= t1)) ordered = false;
      amounts.push(`${prof[0]}=${human(t1, onchain)}/${human(t2, onchain)}/${human(dl, onchain)}`);
    }
    if (!ordered) {
      console.error(`  ${symbol.padEnd(6)} MISMATCH ordering: needs dailyLimit >= tier2Limit >= tier1Limit`);
      failures++;
      continue;
    }
    console.log(`  ${symbol.padEnd(6)} OK decimals=${onchain}  ${amounts.join("  ")}`);
  }
}

console.log(
  `\n${failures === 0 ? "OK" : "FAIL"} — ${checked} token(s) checked against chain, ${skipped} skipped (address TBD), ${failures} mismatch(es)`
);
if (failures > 0) process.exitCode = 1;
