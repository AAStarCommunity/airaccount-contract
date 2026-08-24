/**
 * CC-51 focused review LOW: strict env parsing and failure-sidecar semantics.
 *
 *   - `Number(env) || undefined` turned every malformed timeout into a silent fall-back to viem's
 *     180 s default (and `=0` into "no timeout at all"). Both are fail-open;
 *   - the failure sidecar was rewritten in place, so each attempt destroyed the previous account of
 *     what had been broadcast.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import { optionalPositiveInt } from "../lib/repcredit-env.mjs";
import { writeFailureRecord } from "../lib/repcredit-failure.mjs";

const workdir = mkdtempSync(join(tmpdir(), "repcredit-env-"));
let seq = 0;
const nextPath = () => join(workdir, `failed-${seq++}.json`);
const read = (path) => JSON.parse(readFileSync(path, "utf8"));

describe("strict env parsing", () => {
  it("accepts an unset or empty variable as 'use the default'", () => {
    assert.equal(optionalPositiveInt("T", {}), undefined);
    assert.equal(optionalPositiveInt("T", { T: "" }), undefined);
    assert.equal(optionalPositiveInt("T", { T: "   " }), undefined);
  });

  it("parses a positive integer, with surrounding whitespace tolerated", () => {
    assert.equal(optionalPositiveInt("T", { T: "3000" }), 3000);
    assert.equal(optionalPositiveInt("T", { T: " 180000 " }), 180000);
  });

  it("rejects every value that used to become a silent undefined", () => {
    // Each of these previously fell through `Number(...) || undefined` without a word.
    for (const value of ["abc", "30s", "NaN", "1e3", "12.5", "-1", "0", "0x10", "1,000", "Infinity", "1 2"]) {
      assert.throws(
        () => optionalPositiveInt("REPCREDIT_RECEIPT_TIMEOUT_MS", { REPCREDIT_RECEIPT_TIMEOUT_MS: value }),
        /must be a positive integer number of milliseconds/,
        `${JSON.stringify(value)} must be rejected, not silently ignored`,
      );
    }
  });

  it("rejects a value beyond safe-integer range rather than truncating it", () => {
    assert.throws(() => optionalPositiveInt("T", { T: "9".repeat(25) }), /positive integer/);
  });
});

describe("failure sidecar", () => {
  it("timestamps the first record and numbers the attempt", () => {
    const path = nextPath();
    const written = writeFailureRecord({ path, record: { error: "boom", broadcasts: [{ label: "a", hash: "0x1" }] } });
    assert.equal(written.status, "failed");
    assert.equal(written.attempt, 1);
    assert.ok(Date.parse(written.generatedAt) > 0, "generatedAt is an ISO timestamp");
    assert.equal(written.supersedes, undefined, "nothing to supersede on a first failure");
    assert.deepEqual(read(path), written);
  });

  it("supersedes the previous record instead of erasing it", () => {
    const path = nextPath();
    writeFailureRecord({
      path,
      record: { error: "first failure", broadcasts: [{ label: "deploy:A", hash: "0xaa" }] },
      now: () => "2026-08-24T10:00:00.000Z",
    });
    const second = writeFailureRecord({
      path,
      record: { error: "second failure", broadcasts: [{ label: "deploy:A", hash: "0xaa" }, { label: "deploy:B", hash: "0xbb" }] },
      now: () => "2026-08-24T10:05:00.000Z",
    });

    assert.equal(second.attempt, 2);
    assert.equal(second.generatedAt, "2026-08-24T10:05:00.000Z");
    assert.equal(second.supersedes.length, 1);
    assert.equal(second.supersedes[0].generatedAt, "2026-08-24T10:00:00.000Z");
    assert.equal(second.supersedes[0].error, "first failure");
    // The point of the chain: the earlier attempt's hashes are still readable.
    assert.deepEqual(second.supersedes[0].broadcasts, [{ label: "deploy:A", hash: "0xaa" }]);
  });

  it("keeps the whole chain across several attempts, newest first", () => {
    const path = nextPath();
    for (let attempt = 1; attempt <= 4; attempt += 1) {
      writeFailureRecord({
        path,
        record: { error: `failure ${attempt}`, broadcasts: [{ label: "deploy:A", hash: `0x0${attempt}` }] },
        now: () => `2026-08-24T10:0${attempt}:00.000Z`,
      });
    }
    const final = read(path);
    assert.equal(final.attempt, 4);
    assert.deepEqual(final.supersedes.map((s) => s.error), ["failure 3", "failure 2", "failure 1"]);
  });

  it("replaces an unreadable sidecar rather than failing the failure path", () => {
    const path = nextPath();
    writeFileSync(path, "{ this is not json");
    const written = writeFailureRecord({ path, record: { error: "boom" } });
    assert.equal(written.attempt, 1);
    assert.equal(read(path).error, "boom");
  });
});
