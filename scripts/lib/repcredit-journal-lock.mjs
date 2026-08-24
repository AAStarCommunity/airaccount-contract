/**
 * Fail-closed process mutex for a RepCredit evidence journal path (CC-51 focused review LOW-2).
 *
 * The journal is the only record of a broadcast hash, and `flush()` writes the whole in-process
 * state every time. Two runs pointed at the same journal path therefore do not merely interleave —
 * the second one's write erases the first one's entries, and with them the hashes of transactions
 * that are already on the network. That was demonstrated, not hypothesised: two journals on one
 * path, one hash each, left a single entry on disk.
 *
 * The rule here is deliberately boring:
 *
 *   - acquiring is `O_EXCL` (`wx`) on `<journal>.lock`. Exactly one process can win; every other
 *     process fails closed with the holder's pid, host and age. There is no `--force` flag: a flag
 *     would be a licence to do the one thing this lock exists to prevent.
 *   - a lock may only be *recovered* — never simply ignored — and only when all three hold:
 *       1. it names this host (liveness of a pid on another machine is unknowable from here);
 *       2. the pid is provably not running (`kill(pid, 0)`; EPERM counts as alive);
 *       3. it is older than the stale grace period (default 60 s, REPCREDIT_LOCK_STALE_MS).
 *     Anything else — a live holder, another host, an unparsable lock — refuses and tells the
 *     operator what to check. Recovery is audited: the superseded record is carried forward in the
 *     new lock's `supersedes` chain and reported through `onEvent`.
 *   - the recovery path re-reads and re-stats the lock immediately before unlinking it, and the
 *     winner re-reads its own lock after a settle delay. If two processes reach recovery at the
 *     same instant, the read-back leaves exactly one holder and the other fails closed.
 *
 * Residual risk, stated plainly: this is a same-host advisory lock. It does not defend against a
 * shared network filesystem, and the recovery read-back is a timing bound (100 ms), not a proof.
 * For the evidence scripts — one operator, one machine, one deploy at a time — that is the right
 * amount of machinery; the contended case that actually happens (a second run started by hand
 * while the first is alive) is closed by O_EXCL alone.
 */

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname } from "node:path";

export const LOCK_KIND = "repcredit-journal-lock";
export const LOCK_SCHEMA_VERSION = 1;
/** A dead pid cannot write, but a grace period keeps recovery an explicit, auditable event. */
export const DEFAULT_STALE_AFTER_MS = 60_000;
const SETTLE_MS = 100;
const MAX_ATTEMPTS = 3;

/** The journal path is held by another process, or a lock could not be resolved safely. */
export class JournalLockError extends Error {
  constructor(message, details) {
    super(message);
    this.name = "JournalLockError";
    this.details = details;
  }
}

/** `kill(pid, 0)`: ESRCH means gone, EPERM means alive under another uid. Alive ⇒ never recover. */
function defaultIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function readLock(lockPath) {
  let raw;
  try {
    raw = readFileSync(lockPath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  let record = null;
  try {
    record = JSON.parse(raw);
  } catch {
    record = null;
  }
  let mtimeMs = 0;
  try {
    mtimeMs = statSync(lockPath).mtimeMs;
  } catch {
    // Raced with an unlink; the caller re-reads and retries.
  }
  return { raw, record, mtimeMs };
}

function lockAgeMs(record, mtimeMs, nowMs) {
  const stamped = Date.parse(record?.acquiredAt ?? "");
  const base = Number.isFinite(stamped) ? stamped : mtimeMs;
  return base > 0 ? nowMs - base : Number.POSITIVE_INFINITY;
}

/**
 * Decide what to do about an existing lock. Returns the record when it may be recovered; throws
 * JournalLockError otherwise. Never returns for a lock that might still have a writer behind it.
 */
function assessExistingLock({ lockPath, existing, nowMs, host, staleAfterMs, isAlive }) {
  const held = (reason, extra = {}) =>
    new JournalLockError(
      `${lockPath} is held: ${reason}. The journal must not be written by two processes — the second ` +
      `write would erase hashes that are already on the network. Wait for the holder to finish, or ` +
      `point REPCREDIT_JOURNAL/REPCREDIT_OUTPUT at a different path. A lock is recovered ` +
      `automatically only when it names this host, its pid is provably gone and it is older than ` +
      `${staleAfterMs} ms; if you are certain the holder is dead, verify that and remove ${lockPath} by hand.`,
      { lockPath, reason, ...extra },
    );

  if (!existing.record || existing.record.kind !== LOCK_KIND) {
    throw held("the lock file is not a readable repcredit-journal-lock, so its owner is unknown", {
      raw: existing.raw?.slice(0, 200),
    });
  }
  const { pid, host: lockHost, token } = existing.record;
  const ageMs = lockAgeMs(existing.record, existing.mtimeMs, nowMs);
  const info = { pid, host: lockHost, token, ageMs };
  if (lockHost !== host) {
    throw held(`it was taken on host ${lockHost} (this is ${host}), whose pid ${pid} cannot be checked from here`, info);
  }
  if (isAlive(pid)) {
    throw held(`pid ${pid} on ${lockHost} is still running (age ${Math.round(ageMs)} ms)`, info);
  }
  if (!(ageMs >= staleAfterMs)) {
    throw held(
      `pid ${pid} is gone but the lock is only ${Math.round(ageMs)} ms old (stale grace is ${staleAfterMs} ms); ` +
      `re-run once the grace period has elapsed so recovery stays a deliberate event`,
      info,
    );
  }
  return { record: existing.record, ageMs };
}

/**
 * Take over a lock that `assessExistingLock` cleared as stale.
 *
 * Re-reads and re-stats immediately before unlinking: if anything changed since the assessment,
 * another process got there first and this attempt restarts rather than deleting a live lock.
 */
function recoverStaleLock({ lockPath, existing }) {
  const current = readLock(lockPath);
  if (!current) return true; // already gone; retry the plain wx create
  if (current.raw !== existing.raw || current.mtimeMs !== existing.mtimeMs) return false;
  try {
    unlinkSync(lockPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return true;
}

/**
 * Acquire the mutex for `path`'s journal, or fail closed.
 *
 * @param {{
 *   path: string,
 *   staleAfterMs?: number,
 *   now?: () => number,
 *   pid?: number,
 *   host?: string,
 *   isAlive?: (pid: number) => boolean,
 *   onEvent?: (event: object) => void,
 *   settleMs?: number,
 *   sleep?: (ms: number) => Promise<void>,
 *   registerExitHook?: boolean,
 * }} options
 * @returns {Promise<{ path: string, token: string, record: object, release: () => boolean }>}
 * @throws {JournalLockError}
 */
export async function acquireJournalLock({
  path,
  staleAfterMs = DEFAULT_STALE_AFTER_MS,
  now = () => Date.now(),
  pid = process.pid,
  host = hostname(),
  isAlive = defaultIsAlive,
  onEvent,
  settleMs = SETTLE_MS,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  registerExitHook = true,
}) {
  const lockPath = `${path}.lock`;
  const token = randomUUID();
  let supersedes = [];

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    const record = {
      kind: LOCK_KIND,
      schemaVersion: LOCK_SCHEMA_VERSION,
      journal: path,
      token,
      pid,
      host,
      acquiredAt: new Date(now()).toISOString(),
      ...(supersedes.length > 0 ? { supersedes } : {}),
    };
    try {
      mkdirSync(dirname(lockPath), { recursive: true });
      writeFileSync(lockPath, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx" });
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      const existing = readLock(lockPath);
      if (!existing) continue; // vanished between the failed create and the read; try again
      // Throws unless the lock is provably recoverable — a live holder never reaches the next line.
      const stale = assessExistingLock({ lockPath, existing, nowMs: now(), host, staleAfterMs, isAlive });
      if (!recoverStaleLock({ lockPath, existing })) continue;
      supersedes = [
        ...(Array.isArray(stale.record.supersedes) ? stale.record.supersedes : []),
        {
          token: stale.record.token,
          pid: stale.record.pid,
          host: stale.record.host,
          acquiredAt: stale.record.acquiredAt,
          recoveredAt: new Date(now()).toISOString(),
          ageMsAtRecovery: Math.round(stale.ageMs),
          reason: "pid not running on this host and older than the stale grace period",
        },
      ];
      onEvent?.({
        status: "lock-recovered",
        lock: lockPath,
        stalePid: stale.record.pid,
        staleToken: stale.record.token,
        ageMs: Math.round(stale.ageMs),
      });
      continue;
    }

    // Settle, then confirm the lock on disk is still ours. If two processes recovered the same
    // stale lock concurrently, the loser sees the winner's token here and fails closed.
    await sleep(settleMs);
    const readback = readLock(lockPath);
    if (readback?.record?.token !== token) {
      throw new JournalLockError(
        `${lockPath} was taken by another process while this one was acquiring it ` +
        `(now held by pid ${readback?.record?.pid ?? "?"}, token ${readback?.record?.token ?? "none"}); ` +
        `refusing to write the journal concurrently`,
        { lockPath, token, observed: readback?.record ?? null },
      );
    }
    onEvent?.({ status: "lock-acquired", lock: lockPath, pid, ...(supersedes.length > 0 ? { supersedes } : {}) });

    let released = false;
    const release = () => {
      if (released) return false;
      released = true;
      // Only ever unlink our own lock: a recovered-by-someone-else lock must survive.
      const current = readLock(lockPath);
      if (current?.record?.token !== token) return false;
      try {
        unlinkSync(lockPath);
      } catch (error) {
        if (error?.code !== "ENOENT") return false;
      }
      return true;
    };
    if (registerExitHook) process.on("exit", release);
    return { path: lockPath, token, record, release };
  }

  throw new JournalLockError(
    `could not acquire ${lockPath} after ${MAX_ATTEMPTS} attempts: another process kept winning the race`,
    { lockPath, attempts: MAX_ATTEMPTS },
  );
}

/** Read a lock file for diagnostics; null when absent. Never used to decide ownership. */
export function inspectJournalLock(path) {
  const lockPath = `${path}.lock`;
  if (!existsSync(lockPath)) return null;
  return readLock(lockPath)?.record ?? null;
}
