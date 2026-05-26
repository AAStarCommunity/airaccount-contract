#!/usr/bin/env node
// build-full-abi.mjs — Produce the public "full" ABI for the diamond-lite AirAccount.
//
// AAStarAirAccountV7 routes its cold functions (ERC-8004 agent + weighted-signature
// governance) to the singleton AirAccountExtension via fallback + delegatecall. Those
// functions execute on-chain but are NOT in the AAStarAirAccountV7 compiler ABI, so a
// downstream consumer using only that ABI cannot encode them. This script merges the
// account ABI with the fallback-routed surface (IAirAccountAgent) into one artifact that
// integrators / the SDK should consume.
//
// It uses solc's `methodIdentifiers` (authoritative signature->4-byte-selector map, with
// tuples already expanded to canonical component form) so selector reasoning is exact, and
// it FAILS if:
//   - any fallback-routed selector is missing from the merged ABI, or
//   - any routed selector COLLIDES with a different account-native selector (which would
//     mean the account intercepts that selector and the fallback function is unreachable).
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

// Canonical type string with tuple components expanded — matches solc's methodIdentifiers keys.
function canonicalType(input) {
  if (input.type.startsWith("tuple")) {
    const inner = "(" + (input.components || []).map(canonicalType).join(",") + ")";
    return inner + input.type.slice("tuple".length); // preserve [] / [N] array suffixes
  }
  return input.type;
}

// Canonical function signature: name(type,type,...) with tuples expanded.
function canonicalSig(entry) {
  return `${entry.name}(${(entry.inputs || []).map(canonicalType).join(",")})`;
}

const account = loadArtifact(ACCOUNT);
const routed  = loadArtifact(ROUTED);

// solc methodIdentifiers: { "canonicalSig": "deadbeef" }  (no 0x prefix)
const accountIds = account.methodIdentifiers || {};
const routedIds  = routed.methodIdentifiers || {};

// Selector -> signature for account-native functions (for collision detection).
const accountSelToSig = new Map(Object.entries(accountIds).map(([sig, sel]) => [sel, sig]));
const accountSigs = new Set(Object.keys(accountIds));

// 1) Selector-collision guard: a routed selector that already resolves to a DIFFERENT
//    account-native function would be intercepted by the account and never hit the fallback.
const collisions = [];
for (const [rSig, rSel] of Object.entries(routedIds)) {
  const nativeSig = accountSelToSig.get(rSel);
  if (nativeSig && nativeSig !== rSig) {
    collisions.push(`0x${rSel}: routed ${rSig} shadowed by account-native ${nativeSig}`);
  }
}
if (collisions.length) {
  console.error(`Selector collision — fallback-routed function(s) unreachable:\n  ${collisions.join("\n  ")}`);
  process.exit(1);
}

// 2) Merge: account ABI + routed function entries whose canonical signature is not already
//    present on the account (e.g. inherited getters like weightConfig() are skipped).
const routedFns = routed.abi.filter((e) => e.type === "function");
const additions = routedFns.filter((e) => !accountSigs.has(canonicalSig(e)));
const fullAbi = [...account.abi, ...additions];

// 3) Completeness guard: every fallback-routed selector must be encodable from the merged ABI.
const fullSigs = new Set(fullAbi.filter((e) => e.type === "function").map(canonicalSig));
const missing = Object.keys(routedIds).filter((sig) => !fullSigs.has(sig));
if (missing.length) {
  console.error(`Full ABI is missing fallback-routed selectors:\n  ${missing.join("\n  ")}`);
  process.exit(1);
}

const serialized = JSON.stringify({ abi: fullAbi }, null, 2) + "\n";
const fnCount = fullAbi.filter((e) => e.type === "function").length;
const routedCount = Object.keys(routedIds).length;

if (process.argv.includes("--check")) {
  const current = existsSync(OUT) ? readFileSync(OUT, "utf8") : "";
  if (current !== serialized) {
    console.error(`${OUT} is stale — run \`node scripts/build-full-abi.mjs\` and commit.`);
    process.exit(1);
  }
  console.log(`${OUT} up to date (${fnCount} functions, ${routedCount} fallback-routed, no selector collisions).`);
} else {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, serialized);
  console.log(`Wrote ${OUT}: ${fnCount} functions (+${additions.length} fallback-routed merged, no selector collisions).`);
}
