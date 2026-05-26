#!/usr/bin/env node
// build-full-abi.mjs — Produce the public "full" ABI for the diamond-lite AirAccount.
//
// AAStarAirAccountV7 routes its cold functions (ERC-8004 agent + weighted-signature
// governance) to the singleton AirAccountExtension via fallback + delegatecall. Those
// functions execute on-chain but are NOT in the AAStarAirAccountV7 compiler ABI, so a
// downstream consumer using only that ABI cannot encode them. This script merges the
// account ABI with the fallback-routed surface (IAirAccountAgent) into one artifact that
// integrators / the SDK should consume, and FAILS if any routed selector is missing —
// doubling as the regression check Codex asked for.
//
// Usage: node scripts/build-full-abi.mjs            (writes abi/AAStarAirAccountV7.full.json)
//        node scripts/build-full-abi.mjs --check    (verify the committed file is up to date)
//
// Requires `forge build` to have produced out/ artifacts first.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname } from "node:path";

const ACCOUNT = "out/AAStarAirAccountV7.sol/AAStarAirAccountV7.json";
const ROUTED  = "out/IAirAccountAgent.sol/IAirAccountAgent.json";
const OUT     = "abi/AAStarAirAccountV7.full.json";

function loadArtifact(p) {
  if (!existsSync(p)) {
    console.error(`Missing artifact ${p} — run \`forge build\` first.`);
    process.exit(2);
  }
  return JSON.parse(readFileSync(p, "utf8"));
}

// Stable signature key for an ABI function entry: name(type,type,...)
function sig(entry) {
  return `${entry.name}(${(entry.inputs || []).map((i) => i.type).join(",")})`;
}

const account = loadArtifact(ACCOUNT);
const routed  = loadArtifact(ROUTED);

const accountAbi = account.abi;
const routedFns  = routed.abi.filter((e) => e.type === "function");

// Merge: account ABI + any routed function not already present (by signature).
const present = new Set(accountAbi.filter((e) => e.type === "function").map(sig));
const additions = routedFns.filter((e) => !present.has(sig(e)));
const fullAbi = [...accountAbi, ...additions];

// Regression: every fallback-routed selector MUST be present in the merged ABI.
const fullSigs = new Set(fullAbi.filter((e) => e.type === "function").map(sig));
const missing = routedFns.map(sig).filter((s) => !fullSigs.has(s));
if (missing.length) {
  console.error(`Full ABI is missing fallback-routed selectors:\n  ${missing.join("\n  ")}`);
  process.exit(1);
}

const serialized = JSON.stringify({ abi: fullAbi }, null, 2) + "\n";

const isCheck = process.argv.includes("--check");
if (isCheck) {
  const current = existsSync(OUT) ? readFileSync(OUT, "utf8") : "";
  if (current !== serialized) {
    console.error(`${OUT} is stale — run \`node scripts/build-full-abi.mjs\` and commit.`);
    process.exit(1);
  }
  console.log(`${OUT} up to date (${fullAbi.filter((e) => e.type === "function").length} functions, ${routedFns.length} fallback-routed).`);
} else {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, serialized);
  console.log(`Wrote ${OUT}: ${fullAbi.filter((e) => e.type === "function").length} functions (+${additions.length} fallback-routed merged).`);
}
