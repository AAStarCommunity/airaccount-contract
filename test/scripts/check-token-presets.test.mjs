/**
 * Tests for scripts/check-token-presets.mjs.
 *
 * These codify the negative controls that were previously only run by hand. That distinction is the
 * point: a check is not finished when it goes green once, it is finished when there is a control that
 * goes RED for each distinct way the thing can be wrong. Every case below flipped this script's exit
 * code at some point in its history — none is hypothetical.
 *
 * Live RPC is required: the script's whole job is comparing a file against chains, so stubbing the
 * chain would test something else. Exit code 2 means a chain could not be read, and the tests report
 * that as a skip rather than a failure — a run that could not see the chain has abstained, not passed,
 * and that distinction is itself one of the behaviours under test.
 *
 * Run: node --test test/scripts/check-token-presets.test.mjs
 */
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("../../scripts/check-token-presets.mjs", import.meta.url).pathname;
const REAL = new URL("../../configs/token-presets.json", import.meta.url).pathname;
const SEPOLIA = "11155111";
const OP = "10";
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), "presets-")); });

/** Write a mutated copy of the real presets and run the checker against it. Never touches the real file. */
function run(mutate, args = []) {
  const presets = JSON.parse(readFileSync(REAL, "utf-8"));
  if (mutate) mutate(presets);
  const path = join(dir, `p-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(path, JSON.stringify(presets, null, 2));
  try {
    const stdout = execFileSync("node", [SCRIPT, "--presets", path, ...args], { encoding: "utf-8" });
    return { code: 0, out: stdout };
  } catch (e) {
    return { code: e.status, out: `${e.stdout ?? ""}${e.stderr ?? ""}` };
  }
}

/** Scale every limit of one token entry by 10^n — the shape of a decimals mismatch. */
const scale = (t, n) => {
  for (const p of ["conservative", "standard", "trader"])
    for (const k of ["tier1Limit", "tier2Limit", "dailyLimit"])
      t[p][k] = (BigInt(t[p][k]) / 10n ** BigInt(n)).toString();
};

const expectFail = (r, needle) => {
  if (r.code === 2) return void console.log(`    (skipped: a chain was unreachable)\n${r.out}`);
  assert.equal(r.code, 1, `expected exit 1, got ${r.code}\n${r.out}`);
  if (needle) assert.ok(r.out.includes(needle), `expected output to contain ${JSON.stringify(needle)}\n${r.out}`);
};

test("unmodified presets pass", () => {
  const r = run(null);
  if (r.code === 2) return void console.log("    (skipped: a chain was unreachable)");
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /0 failure\(s\)/);
});

test("A — declared decimals disagree with the chain", () => {
  expectFail(run((p) => { const t = p.chains[SEPOLIA].tokens.aPNTs; t.decimals = 6; scale(t, 12); }),
    "FAIL decimals");
});

test("B — decimals corrected but limits left at the old scale", () => {
  // The case the first version of this script was blind to: its only hard assertion was decimals.
  expectFail(run((p) => scale(p.chains[SEPOLIA].tokens.aPNTs, 12)), "FAIL limits");
});

test("C — a TBD-address token still has its limits checked", () => {
  expectFail(run((p) => scale(p.chains[OP].tokens.aPNTs, 12)), "FAIL limits");
});

test("D — a TBD token whose wrong decimals agree with its own wrong limits", () => {
  // Self-consistent, so only the cross-chain rule can see it. This is the original bug's exact shape.
  expectFail(run((p) => { const t = p.chains[OP].tokens.aPNTs; t.decimals = 6; scale(t, 12); }),
    "chain 11155111 reads 18");
});

test("D' — the arbitration clause is only claimed when no chain carries the symbol", () => {
  const r = run((p) => { const t = p.chains[SEPOLIA].tokens.aPNTs; t.decimals = 6; scale(t, 12); });
  if (r.code === 2) return;
  assert.ok(!r.out.includes("no chain carries it to arbitrate"),
    `a chain does carry aPNTs here, so that clause must not appear\n${r.out}`);
});

test("N1 — a chain declaring no tokens fails instead of shrinking the run", () => {
  expectFail(run((p) => { p.chains[SEPOLIA].tokens = {}; }), "declares no tokens");
});

test("N1b — deleting the only entry with a real address fails", () => {
  // Leaves aPNTs on two chains, so 'appears on at least one chain' does not catch it; what it removes
  // is the ability to verify the symbol at all.
  expectFail(run((p) => { delete p.chains[SEPOLIA].tokens.aPNTs; }), "no chain gives it a real address");
});

test("N1c — contradictory declarations with no chain to arbitrate", () => {
  expectFail(run((p) => {
    delete p.chains[SEPOLIA].tokens.aPNTs;
    const t = p.chains[OP].tokens.aPNTs; t.decimals = 6; scale(t, 12);
  }), "no chain carries it to arbitrate");
});

test("F — --chain naming a chain that is not in the file fails rather than matching nothing", () => {
  const r = run(null, ["--chain", "999", "--require-verified"]);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /no such chain/);
});

test("G — a chain with no RPC configured fails instead of being skipped in silence", () => {
  expectFail(run((p) => { p.chains["42161"] = { _name: "Arbitrum", tokens: {} }; }, ["--chain", "42161"]),
    "no RPC configured");
});

test("H — an empty token set fails on the roster rule, before --require-verified sees it", () => {
  // This test used to assert only "it failed", and so passed through N1 while claiming to cover the
  // --require-verified empty-set guard. Naming the reason is what makes it test one thing.
  expectFail(run((p) => { p.chains["1"].tokens = {}; }, ["--chain", "1", "--require-verified"]),
    "declares no tokens");
});

test("a chain whose tokens are all unreadable ABSTAINS — it does not report a mismatch", () => {
  // The only path that actually reaches the --require-verified empty-set guard, and the one where
  // getting it wrong is worst: every token unreadable means the run could not look, and calling that
  // a failure overwrites exit 2 with exit 1 — a mismatch reported that was never found.
  const r = run((p) => {
    for (const t of Object.values(p.chains["1"].tokens)) t.address = "0x000000000000000000000000000000000000dEaD";
  }, ["--chain", "1", "--require-verified"]);
  assert.equal(r.code, 2, `expected exit 2 (abstained), got ${r.code}\n${r.out}`);
  assert.ok(r.out.includes("abstained rather than passed"), r.out);
  assert.ok(!r.out.includes("the gate matched no tokens"),
    `unreadability is not an empty gate; that message would be false here\n${r.out}`);
  assert.ok(!/^OK —/m.test(r.out), `a run that abstained must not print OK\n${r.out}`);
});

test("--require-verified rejects a token whose address is still TBD", () => {
  expectFail(run(null, ["--chain", OP, "--require-verified"]), "address is TBD");
});

test("the cross-chain escape hatch waives decimals but never the limits", () => {
  const mk = (correctLimits) => (p) => {
    const t = structuredClone(p.chains["1"].tokens.USDT);
    t.address = "0x4200000000000000000000000000000000000006"; // 18-decimal token on Base
    t.decimals = 18;
    t.decimalsIntentionallyDiffers = "USDT is 6 on Ethereum, 18 here";
    if (correctLimits) for (const pr of ["conservative", "standard", "trader"])
      for (const k of ["tier1Limit", "tier2Limit", "dailyLimit"]) t[pr][k] = (BigInt(t[pr][k]) * 10n ** 12n).toString();
    p.chains["8453"].tokens.USDT = t;
  };
  const ok = run(mk(true), ["--chain", "8453"]);
  if (ok.code !== 2) {
    assert.equal(ok.code, 0, ok.out);
    assert.match(ok.out, /differ on purpose/);
  }
  expectFail(run(mk(false), ["--chain", "8453"]), "FAIL limits");
});

test("EXPECTED is not derived from the file it checks", () => {
  // The hand-maintained table is the only independent observer here; deriving it from the presets
  // would make the check pass forever. Changing a limit must therefore fail even though the file
  // remains perfectly self-consistent.
  expectFail(run((p) => {
    const t = p.chains[SEPOLIA].tokens.aPNTs;
    t.standard.tier1Limit = (BigInt(t.standard.tier1Limit) * 2n).toString();
  }), "expected 7500");
});
