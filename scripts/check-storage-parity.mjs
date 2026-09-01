#!/usr/bin/env node
/**
 * check-storage-parity.mjs — CI gate for the diamond-lite delegatecall boundary (security "CI").
 *
 * AAStarAirAccountV7 (the account) and AirAccountExtension (the fallback-routed facet) run in the
 * SAME storage via delegatecall, so they MUST agree on every storage slot. Today that holds only by
 * convention: both inherit AAStarAgentStorageLayout first and neither declares its own state var.
 * Nothing in the build fails if a future edit adds a state variable to one side (or reorders the
 * layout), which would silently corrupt storage across the boundary (e.g. an Extension write landing
 * on `owner` or `guard`). The in-file slot comments have already drifted ("off-by-2"), raising that
 * risk. This script makes the invariant machine-checked.
 *
 * It compares `forge inspect <C> storage-layout` for both contracts on (slot, offset, label, type)
 * and fails (exit 1) on any divergence. Run in CI after `forge build`/`forge test`.
 *
 * Usage: node scripts/check-storage-parity.mjs
 */
import { execSync } from "node:child_process";

const PAIRS = [["AAStarAirAccountV7", "AirAccountExtension"]];

// Resolve a type id to its LAYOUT SHAPE. The raw `type` string embeds solc's AST node id
// (`t_contract(IAAStarValidator)19712`), which is a compilation artifact, not storage layout: the same
// declaration gets different ids in different builds. Keying on it made this check compare compiler
// bookkeeping while claiming to compare layout — and it passed for months only because the two
// contracts happened to be assigned matching ids under the pinned toolchain. Unpinning removed the
// coincidence and the check reported six "mismatches" whose slot, offset, label and type shape were
// all identical. The types map gives what we actually care about: encoding, width, a node-id-free
// label, and members for structs.
function shape(types, typeId, depth = 0) {
  const t = types?.[typeId];
  if (!t) return typeId; // unresolved: fall back to the raw id rather than silently matching
  const base = `${t.label}|${t.encoding}|${t.numberOfBytes}`;
  if (!t.members || depth > 4) return base;
  const members = t.members
    .map((m) => `${m.slot}:${m.offset}:${m.label}:${shape(types, m.type, depth + 1)}`)
    .join(",");
  return `${base}{${members}}`;
}

function layout(contract) {
  const out = execSync(`forge inspect ${contract} storage-layout --json`, { maxBuffer: 1e8 }).toString();
  const parsed = JSON.parse(out);
  // Key each slot on the fields that matter for the shared-storage boundary.
  return (parsed.storage || []).map(
    (s) => `${s.slot}:${s.offset}:${s.label}:${shape(parsed.types, s.type)}`
  );
}

let failed = false;
for (const [a, b] of PAIRS) {
  const la = layout(a);
  const lb = layout(b);
  const sa = new Set(la);
  const sb = new Set(lb);
  const onlyA = la.filter((x) => !sb.has(x));
  const onlyB = lb.filter((x) => !sa.has(x));

  if (la.length !== lb.length || onlyA.length || onlyB.length) {
    failed = true;
    console.error(`❌ Storage-layout MISMATCH between ${a} and ${b} — the delegatecall boundary is unsafe.`);
    console.error(`   ${a}: ${la.length} slots · ${b}: ${lb.length} slots`);
    if (onlyA.length) console.error(`   only in ${a}:\n     ${onlyA.join("\n     ")}`);
    if (onlyB.length) console.error(`   only in ${b}:\n     ${onlyB.join("\n     ")}`);
    console.error(`   Fix: put ALL persistent state in AAStarAgentStorageLayout (append-only); never`);
    console.error(`   declare a state variable directly in the account or the Extension.`);
  } else {
    console.log(`✅ Storage-layout parity OK: ${a} ≡ ${b} (${la.length} slots).`);
  }
}

process.exit(failed ? 1 : 0);
