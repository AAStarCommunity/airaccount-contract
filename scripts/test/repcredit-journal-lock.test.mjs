/**
 * Fault-injection and dual-process tests for the journal mutex (CC-51 focused review LOW-2).
 *
 * The defect being closed was demonstrated, not theorised: `flush()` writes the whole in-process
 * state, so two runs sharing a journal path overwrite each other and a hash that is already on the
 * network disappears from the record. The first test here reproduces exactly that against the
 * unlocked journal, so the rest of the file is measured against a real failure rather than a
 * hypothetical one.
 *
 * The interesting cases are all about *who may take a lock away*:
 *   - a live holder: never;
 *   - a dead holder on this host, younger than the grace period: not yet (recovery stays a
 *     deliberate, auditable event rather than a side effect of a fast retry);
 *   - a dead holder on this host, older than the grace period: recovered, with the superseded
 *     record carried forward;
 *   - a holder on another host, or a lock that cannot be parsed: never, because liveness is
 *     unknowable and guessing costs a broadcast hash.
 *
 * Two of the tests fork real child processes; nothing here is simulated with mocks alone.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { JournalLockError, acquireJournalLock, inspectJournalLock } from "../lib/repcredit-journal-lock.mjs";
import { createJournal, planFingerprint } from "../lib/repcredit-tx-journal.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const workdir = mkdtempSync(join(tmpdir(), "repcredit-lock-"));
let seq = 0;
const nextPath = () => join(workdir, `journal-${seq++}.json`);
const read = (path) => JSON.parse(readFileSync(path, "utf8"));

// Tests never wait out a real settle delay; the ordering it guards is exercised by the dual-process
// cases below, where the delay is left at its default.
const fast = { settleMs: 0 };

describe("the defect the lock exists for", () => {
  it("loses an already-broadcast hash when two journals share a path unlocked", () => {
    const path = nextPath();
    const fingerprint = planFingerprint({ script: "test", labels: ["a", "b"] });
    const a = createJournal({ path, fingerprint, plan: ["a", "b"] });
    const b = createJournal({ path, fingerprint, plan: ["a", "b"] });

    a.recordPrebroadcast("a", { hash: "0xAAA", digest: "d", from: "0xf0", nonce: 0, raw: "0x01" });
    b.recordPrebroadcast("b", { hash: "0xBBB", digest: "d", from: "0xf0", nonce: 1, raw: "0x02" });

    // b's flush wrote its whole state over a's. 0xAAA may already be in a mempool, and the only
    // record of it is gone. This is what the mutex prevents.
    assert.deepEqual(Object.keys(read(path).entries), ["b"]);
    assert.equal(readFileSync(path, "utf8").includes("0xAAA"), false);
  });
});

describe("acquire / release", () => {
  it("creates an auditable lock and releases it", async () => {
    const path = nextPath();
    const lock = await acquireJournalLock({ path, ...fast, registerExitHook: false });
    const record = inspectJournalLock(path);
    assert.equal(record.kind, "repcredit-journal-lock");
    assert.equal(record.journal, path);
    assert.equal(record.pid, process.pid);
    assert.equal(record.host, hostname());
    assert.ok(Date.parse(record.acquiredAt) > 0);
    assert.equal(lock.release(), true);
    assert.equal(existsSync(`${path}.lock`), false);
    assert.equal(lock.release(), false, "release is idempotent");
  });

  it("refuses a second acquisition while the holder is alive", async () => {
    const path = nextPath();
    const lock = await acquireJournalLock({ path, ...fast, registerExitHook: false });
    await assert.rejects(
      () => acquireJournalLock({ path, ...fast, registerExitHook: false }),
      (error) => {
        assert.ok(error instanceof JournalLockError);
        assert.match(error.message, /is still running/);
        assert.match(error.message, /erase hashes that are already on the network/);
        return true;
      },
    );
    // The refusal must not have disturbed the holder's lock.
    assert.equal(inspectJournalLock(path).token, lock.token);
    lock.release();
  });

  it("never deletes a lock that is no longer ours", async () => {
    const path = nextPath();
    const lock = await acquireJournalLock({ path, ...fast, registerExitHook: false });
    // Someone else's lock now occupies the path (e.g. after a recovery we lost).
    writeFileSync(`${path}.lock`, JSON.stringify({ kind: "repcredit-journal-lock", token: "other", pid: 1, host: hostname() }));
    assert.equal(lock.release(), false, "release is token-scoped");
    assert.equal(inspectJournalLock(path).token, "other");
  });
});

describe("stale-lock recovery rules", () => {
  /** Plant a lock file as if a previous process had written it. */
  const plant = (path, overrides = {}) => {
    writeFileSync(
      `${path}.lock`,
      `${JSON.stringify({
        kind: "repcredit-journal-lock",
        schemaVersion: 1,
        journal: path,
        token: "stale-token",
        pid: 424242,
        host: hostname(),
        acquiredAt: new Date(Date.now() - 3_600_000).toISOString(),
        ...overrides,
      })}\n`,
    );
  };

  it("recovers a dead holder's lock once the grace period has passed, and records why", async () => {
    const path = nextPath();
    plant(path);
    const events = [];
    const lock = await acquireJournalLock({
      path,
      ...fast,
      registerExitHook: false,
      isAlive: () => false,
      onEvent: (event) => events.push(event),
    });

    assert.deepEqual(events.map((e) => e.status), ["lock-recovered", "lock-acquired"]);
    assert.equal(events[0].stalePid, 424242);
    // The audit trail: whose lock was taken, when, how old, and on what grounds.
    const [superseded] = inspectJournalLock(path).supersedes;
    assert.equal(superseded.token, "stale-token");
    assert.equal(superseded.pid, 424242);
    assert.ok(superseded.ageMsAtRecovery >= 3_599_000);
    assert.match(superseded.reason, /pid not running/);
    assert.ok(Date.parse(superseded.recoveredAt) > 0);
    lock.release();
  });

  it("refuses a dead holder's lock that is younger than the grace period", async () => {
    const path = nextPath();
    plant(path, { acquiredAt: new Date().toISOString() });
    await assert.rejects(
      () => acquireJournalLock({ path, ...fast, registerExitHook: false, isAlive: () => false, staleAfterMs: 60_000 }),
      (error) => {
        assert.match(error.message, /gone but the lock is only/);
        assert.match(error.message, /stale grace is 60000 ms/);
        return true;
      },
    );
    assert.equal(inspectJournalLock(path).token, "stale-token", "the lock is left exactly as found");
  });

  it("refuses a lock taken on another host, however old", async () => {
    const path = nextPath();
    plant(path, { host: "some-other-machine", acquiredAt: new Date(0).toISOString() });
    await assert.rejects(
      () => acquireJournalLock({ path, ...fast, registerExitHook: false, isAlive: () => false }),
      (error) => {
        assert.match(error.message, /taken on host some-other-machine/);
        assert.match(error.message, /cannot be checked from here/);
        return true;
      },
    );
    assert.ok(existsSync(`${path}.lock`));
  });

  it("refuses an unparsable or foreign lock file rather than guessing its owner", async () => {
    for (const content of ["not json at all", JSON.stringify({ kind: "something-else", pid: 1 })]) {
      const path = nextPath();
      writeFileSync(`${path}.lock`, content);
      await assert.rejects(
        () => acquireJournalLock({ path, ...fast, registerExitHook: false, isAlive: () => false }),
        (error) => {
          assert.match(error.message, /not a readable repcredit-journal-lock/);
          return true;
        },
      );
      assert.ok(existsSync(`${path}.lock`), "an unreadable lock is never removed automatically");
    }
  });

  it("treats EPERM from kill(pid, 0) as alive", async () => {
    const path = nextPath();
    plant(path, { pid: 1 }); // pid 1 exists but is not ours: kill(1, 0) raises EPERM
    await assert.rejects(
      () => acquireJournalLock({ path, ...fast, registerExitHook: false }),
      (error) => {
        assert.match(error.message, /pid 1 .* is still running/);
        return true;
      },
    );
  });

  it("fails closed when another process wins the lock during acquisition", async () => {
    const path = nextPath();
    plant(path);
    // The narrow race: two processes both find the same stale lock and both recover it. The
    // settle-and-read-back leaves exactly one holder; this one must see that it lost.
    const lock = await acquireJournalLock({
      path,
      registerExitHook: false,
      isAlive: () => false,
      settleMs: 5,
      sleep: async () => {
        writeFileSync(
          `${path}.lock`,
          JSON.stringify({ kind: "repcredit-journal-lock", token: "rival", pid: 999_999, host: hostname() }),
        );
      },
    }).then(
      (value) => value,
      (error) => error,
    );
    assert.ok(lock instanceof JournalLockError, `expected to lose the race, got ${lock}`);
    assert.match(lock.message, /was taken by another process while this one was acquiring it/);
    assert.equal(inspectJournalLock(path).token, "rival", "the winner's lock is untouched");
  });
});

// ── real processes ───────────────────────────────────────────────────────────────────────────

const CHILD = `
import { acquireJournalLock } from ${JSON.stringify(join(repoRoot, "scripts/lib/repcredit-journal-lock.mjs"))};
import { createJournal, planFingerprint } from ${JSON.stringify(join(repoRoot, "scripts/lib/repcredit-tx-journal.mjs"))};
const { JOURNAL_PATH: path, STEP_LABEL: label, STEP_HASH: hash, HOLD_MS: holdMs } = process.env;
const lock = await acquireJournalLock({ path });
const journal = createJournal({
  path,
  fingerprint: planFingerprint({ script: "child", labels: ["a", "b"] }),
  plan: ["a", "b"],
});
journal.load();
journal.recordPrebroadcast(label, { hash, digest: "d", from: "0xf0", nonce: 0, raw: "0x01" });
process.stdout.write(JSON.stringify({ acquired: true, label }) + "\\n");
await new Promise((r) => setTimeout(r, Number(holdMs)));
lock.release();
`;

function runChild(path, label, hash, holdMs) {
  return new Promise((done) => {
    execFile(
      process.execPath,
      ["--input-type=module", "-e", CHILD],
      {
        cwd: repoRoot,
        timeout: 30_000,
        env: { ...process.env, JOURNAL_PATH: path, STEP_LABEL: label, STEP_HASH: hash, HOLD_MS: String(holdMs) },
      },
      (error, stdout, stderr) => done({ code: error?.code ?? 0, stdout, stderr }),
    );
  });
}

describe("two processes on one journal path", () => {
  it("admits exactly one writer; the loser fails closed without touching the journal", async () => {
    const path = nextPath();
    // Both are started together and both target the same journal — the operator mistake (a second
    // evidence run launched by hand) that used to silently erase the first run's hash.
    const [first, second] = await Promise.all([
      runChild(path, "a", "0xAAA", 1_500),
      runChild(path, "b", "0xBBB", 1_500),
    ]);

    const winners = [first, second].filter((run) => run.code === 0);
    const losers = [first, second].filter((run) => run.code !== 0);
    assert.equal(winners.length, 1, `exactly one process may hold the lock\n${first.stderr}\n${second.stderr}`);
    assert.equal(losers.length, 1);
    assert.match(losers[0].stderr, /JournalLockError/);
    assert.match(losers[0].stderr, /is held/);

    // The decisive assertion: the winner's hash is still on disk. Unlocked, it was a coin flip.
    const winnerLabel = JSON.parse(winners[0].stdout.trim()).label;
    const entries = read(path).entries;
    assert.deepEqual(Object.keys(entries), [winnerLabel]);
    assert.equal(entries[winnerLabel].hash, winnerLabel === "a" ? "0xAAA" : "0xBBB");
    assert.equal(existsSync(`${path}.lock`), false, "the winner released on exit");
  });

  it("lets a second run proceed once the first has finished", async () => {
    const path = nextPath();
    const first = await runChild(path, "a", "0xAAA", 0);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(existsSync(`${path}.lock`), false);

    const second = await runChild(path, "b", "0xBBB", 0);
    assert.equal(second.code, 0, second.stderr);
    // Sequential runs resume the same journal rather than replacing it: both hashes survive.
    assert.deepEqual(Object.keys(read(path).entries).sort(), ["a", "b"]);
  });

  it("drops the lock when the holder is killed, and recovery is then auditable", async () => {
    const path = nextPath();
    // A SIGKILLed holder leaves its lock behind: the exit hook never runs. That leftover must not
    // be honoured forever, but it must also never be ignored silently.
    const child = execFile(
      process.execPath,
      ["--input-type=module", "-e", CHILD],
      { cwd: repoRoot, env: { ...process.env, JOURNAL_PATH: path, STEP_LABEL: "a", STEP_HASH: "0xAAA", HOLD_MS: "20000" } },
      () => {},
    );
    await new Promise((done) => child.stdout.once("data", done));
    const deadPid = inspectJournalLock(path).pid;
    child.kill("SIGKILL");
    await new Promise((done) => child.once("exit", done));

    assert.ok(existsSync(`${path}.lock`), "a killed process cannot clean up after itself");
    // Fresh lock, dead pid: refused until the grace period turns recovery into a deliberate act.
    await assert.rejects(
      () => acquireJournalLock({ path, ...fast, registerExitHook: false }),
      (error) => {
        assert.match(error.message, /gone but the lock is only/);
        return true;
      },
    );
    // Past the grace period it is recovered — and the record says whose lock was taken.
    const lock = await acquireJournalLock({ path, ...fast, registerExitHook: false, staleAfterMs: 0 });
    const [superseded] = inspectJournalLock(path).supersedes;
    assert.equal(superseded.pid, deadPid);
    // The killed run's hash is still in the journal: recovery takes the lock, never the record.
    assert.equal(read(path).entries.a.hash, "0xAAA");
    lock.release();
  });
});
