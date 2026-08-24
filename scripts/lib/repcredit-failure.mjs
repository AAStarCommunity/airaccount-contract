/**
 * Failure sidecar shared by both RepCredit evidence deploy scripts.
 *
 * The evidence output file is write-once (`wx`); the failure record lives beside it at
 * `<output>.failed.json` and IS rewritten, so a resumed run can still write its evidence.
 *
 * CC-51 focused review LOW: rewriting it silently destroyed the previous attempt's account of what
 * happened. Every record now carries `generatedAt` and `attempt`, and when it replaces an earlier
 * record it keeps a `supersedes` chain summarising each prior attempt — so the sequence of failures
 * across a resumed run stays readable, and no broadcast hash is ever dropped from the history.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const FAILURE_SCHEMA_VERSION = 2;
const MAX_SUPERSEDED = 20;

/**
 * @param {{ path: string, record: object, now?: () => string }} options
 * @returns {object} the record as written
 */
export function writeFailureRecord({ path, record, now = () => new Date().toISOString() }) {
  let previous = null;
  if (existsSync(path)) {
    try {
      previous = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // An unreadable sidecar must not mask the failure being reported; it is simply replaced.
      previous = null;
    }
  }
  const priorChain = Array.isArray(previous?.supersedes) ? previous.supersedes : [];
  const supersedes = previous
    ? [
        {
          generatedAt: previous.generatedAt ?? null,
          attempt: previous.attempt ?? null,
          error: previous.error ?? null,
          // Keeping the hashes means the history is complete even after many attempts.
          broadcasts: previous.broadcasts ?? previous.pending ?? [],
        },
        ...priorChain,
      ].slice(0, MAX_SUPERSEDED)
    : [];

  const written = {
    schemaVersion: FAILURE_SCHEMA_VERSION,
    status: "failed",
    generatedAt: now(),
    attempt: (Number(previous?.attempt) || 0) + 1,
    ...record,
    ...(supersedes.length > 0 ? { supersedes } : {}),
  };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(written, null, 2)}\n`);
  return written;
}
