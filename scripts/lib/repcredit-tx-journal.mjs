/**
 * Durable transaction journal + resumable runner for the RepCredit evidence deploy scripts.
 *
 * CC-51 post-review MEDIUM (transaction-hash durability). The previous scripts recorded a
 * transaction only *after* `waitForTransactionReceipt` resolved:
 *
 *     const receipt = await publicClient.waitForTransactionReceipt({ hash })   // may time out
 *     transactions[label] = { hash, ... }                                      // never reached
 *
 * viem's default receipt timeout is 180 s. If the implementation deploy (~10.4M gas) was still
 * queued when that elapsed, the wait threw, the assignment never ran, and the hash existed
 * nowhere — not in the failure record, not on stdout. The transaction could still mine later,
 * leaving an unrecorded orphan that had already burned gas. On the *first* transaction it was
 * worse: the failure record was guarded by `transactions.length > 0`, so nothing was written at all.
 *
 * This module inverts the order and makes the record survive the process:
 *
 *   1. the hash is written to a journal file on disk, atomically, *before* the receipt is awaited;
 *   2. a receipt timeout NEVER resends — it surfaces as PendingReceiptTimeoutError and the entry
 *      stays `pending`, which is the repo's standing lesson (a timed-out Sepolia transaction must
 *      be polled, never re-broadcast, or the nonce snarls);
 *   3. a rerun loads the journal, polls every pending hash by `eth_getTransactionReceipt`, and
 *      reconciles it to mined / reverted / still-pending before the plan restarts;
 *   4. steps already mined are skipped — their address and receipt come from the journal — so a
 *      resumed run continues where it stopped instead of redeploying the whole stack.
 *
 * The journal is deliberately separate from the evidence output file: the evidence file stays
 * write-once (`wx`), the journal is machine state and is rewritten in place.
 */

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const JOURNAL_KIND = "repcredit-tx-journal";
export const JOURNAL_SCHEMA_VERSION = 1;

/** A sent transaction whose receipt did not arrive in time. The hash is already durable. */
export class PendingReceiptTimeoutError extends Error {
  constructor(label, hash, journalPath) {
    super(
      `${label} was sent as ${hash} but no receipt arrived before the timeout. ` +
      `It was NOT resent — re-run the same command to resume polling this hash ` +
      `(journal: ${journalPath}). Never re-broadcast: the transaction may still mine.`,
    );
    this.name = "PendingReceiptTimeoutError";
    this.label = label;
    this.hash = hash;
    this.journalPath = journalPath;
  }
}

/** The journal on disk does not describe the run being attempted; resuming would be unsafe. */
export class JournalResumeError extends Error {
  constructor(message) {
    super(message);
    this.name = "JournalResumeError";
  }
}

/** A journalled transaction is known to have reverted; the run must not retry it blindly. */
export class JournalRevertedError extends Error {
  constructor(label, hash) {
    super(`${label} reverted on chain as ${hash}; resolve the revert and start a fresh run`);
    this.name = "JournalRevertedError";
    this.label = label;
    this.hash = hash;
  }
}

const sha256 = (value) => `sha256:${createHash("sha256").update(value).digest("hex")}`;

/** Stable digest of the run's identity. A journal from a different plan is refused, not reused. */
export function planFingerprint(parts) {
  return sha256(JSON.stringify(parts, Object.keys(parts).sort()));
}

/** Stable digest of one transaction's intent, so a resumed step cannot silently change target. */
export function requestDigest({ to = null, data = "0x" }) {
  return sha256(JSON.stringify({ to: to ? String(to).toLowerCase() : null, data: String(data).toLowerCase() }));
}

function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, text);
  // rename(2) is atomic within a filesystem: readers see either the old journal or the new one,
  // never a truncated one, even if the process dies mid-write.
  renameSync(tmp, path);
}

/**
 * @param {{ path: string, fingerprint: string }} options
 */
export function createJournal({ path, fingerprint }) {
  let state = {
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    kind: JOURNAL_KIND,
    fingerprint,
    entries: {},
  };
  let resumed = false;

  const flush = () => writeAtomic(path, `${JSON.stringify(state, null, 2)}\n`);

  return {
    path,
    /** True when this run adopted an existing journal. */
    get resumed() {
      return resumed;
    },
    /** Load a previous run's journal, refusing anything that does not match this plan. */
    load() {
      if (!existsSync(path)) return false;
      let parsed;
      try {
        parsed = JSON.parse(readFileSync(path, "utf8"));
      } catch (error) {
        throw new JournalResumeError(`journal ${path} is not readable JSON: ${String(error)}`);
      }
      if (parsed?.kind !== JOURNAL_KIND) {
        throw new JournalResumeError(`journal ${path} is not a ${JOURNAL_KIND} file`);
      }
      if (parsed.schemaVersion !== JOURNAL_SCHEMA_VERSION) {
        throw new JournalResumeError(
          `journal ${path} has schemaVersion ${parsed.schemaVersion}, expected ${JOURNAL_SCHEMA_VERSION}`,
        );
      }
      if (parsed.fingerprint !== fingerprint) {
        // Fail closed: a journal written for a different chain / EntryPoint / deployer / salt
        // would resume onto contracts that do not belong to this run.
        throw new JournalResumeError(
          `journal ${path} belongs to a different run (fingerprint ${parsed.fingerprint} != ${fingerprint}); ` +
          `point REPCREDIT_JOURNAL somewhere else or remove the stale journal deliberately`,
        );
      }
      state = {
        schemaVersion: JOURNAL_SCHEMA_VERSION,
        kind: JOURNAL_KIND,
        fingerprint,
        entries: { ...(parsed.entries ?? {}) },
      };
      resumed = true;
      return true;
    },
    entry(label) {
      return state.entries[label];
    },
    /** Persist a sent transaction BEFORE its receipt is awaited. Synchronous by design. */
    recordPending(label, hash, digest, sentAt) {
      state.entries[label] = { hash, digest, status: "pending", sentAt: sentAt ?? new Date().toISOString() };
      flush();
      return state.entries[label];
    },
    /** Move an entry to its terminal state once a receipt is in hand. */
    settle(label, receipt, status) {
      const previous = state.entries[label] ?? {};
      state.entries[label] = {
        ...previous,
        hash: receipt.transactionHash ?? previous.hash,
        status,
        blockNumber: receipt.blockNumber?.toString(),
        blockHash: receipt.blockHash,
        gasUsed: receipt.gasUsed?.toString(),
        ...(receipt.contractAddress ? { contractAddress: receipt.contractAddress } : {}),
      };
      flush();
      return state.entries[label];
    },
    /** [label, entry] pairs still awaiting a receipt. */
    pending() {
      return Object.entries(state.entries).filter(([, entry]) => entry.status === "pending");
    },
    /** Every hash this run has broadcast, whatever its state — nothing is ever lost. */
    allHashes() {
      return Object.entries(state.entries).map(([label, entry]) => ({
        label,
        hash: entry.hash,
        status: entry.status,
      }));
    },
    /** Mined transactions in the evidence-file shape. */
    minedTransactions() {
      const out = {};
      for (const [label, entry] of Object.entries(state.entries)) {
        if (entry.status !== "mined") continue;
        out[label] = {
          hash: entry.hash,
          blockNumber: entry.blockNumber,
          blockHash: entry.blockHash,
          gasUsed: entry.gasUsed,
          ...(entry.contractAddress ? { contractAddress: entry.contractAddress } : {}),
        };
      }
      return out;
    },
    snapshot() {
      return JSON.parse(JSON.stringify(state));
    },
    /** Remove the journal once the evidence file has been written successfully. */
    discard() {
      try {
        if (existsSync(path)) unlinkSync(path);
      } catch {
        // A leftover journal is harmless: the next run refuses to overwrite the evidence file.
      }
    },
  };
}

const isReceiptTimeout = (error) =>
  error?.name === "WaitForTransactionReceiptTimeoutError" ||
  /Timed out while waiting for transaction/i.test(error?.message ?? "");

const isReceiptNotFound = (error) =>
  error?.name === "TransactionReceiptNotFoundError" ||
  /could not be found/i.test(error?.message ?? "");

/**
 * Poll every pending hash once and reconcile it to mined / reverted / still-pending.
 *
 * Called before the deploy plan restarts, so a rerun never re-broadcasts a transaction that
 * already mined while the previous process was dying.
 */
export async function reconcilePending({ journal, publicClient, onResult }) {
  const results = [];
  for (const [label, entry] of journal.pending()) {
    let receipt = null;
    try {
      receipt = await publicClient.getTransactionReceipt({ hash: entry.hash });
    } catch (error) {
      if (!isReceiptNotFound(error)) throw error;
    }
    let state = "pending";
    if (receipt) {
      state = receipt.status === "success" ? "mined" : "reverted";
      journal.settle(label, receipt, state);
    }
    const result = { label, hash: entry.hash, state };
    results.push(result);
    onResult?.(result);
  }
  return results;
}

/**
 * Build the send-and-settle helper the deploy plans run on.
 *
 * @param {{
 *   journal: ReturnType<typeof createJournal>,
 *   publicClient: any,
 *   walletClient: any,
 *   overrides?: () => Promise<object>,  // per-transaction params, e.g. the fee triple
 *   confirmations?: number,
 *   receiptTimeoutMs?: number,
 *   pollingIntervalMs?: number,
 * }} options
 */
export function createTxRunner({
  journal,
  publicClient,
  walletClient,
  overrides = async () => ({}),
  confirmations = 1,
  receiptTimeoutMs,
  pollingIntervalMs,
}) {
  async function settle(label, hash) {
    let receipt;
    try {
      receipt = await publicClient.waitForTransactionReceipt({
        hash,
        confirmations,
        ...(receiptTimeoutMs ? { timeout: receiptTimeoutMs } : {}),
        ...(pollingIntervalMs ? { pollingInterval: pollingIntervalMs } : {}),
      });
    } catch (error) {
      // The hash is already durable, so the only correct move is to stop and let a rerun poll.
      if (isReceiptTimeout(error)) throw new PendingReceiptTimeoutError(label, hash, journal.path);
      throw error;
    }
    if (receipt.status !== "success") {
      journal.settle(label, receipt, "reverted");
      throw new JournalRevertedError(label, hash);
    }
    const entry = journal.settle(label, receipt, "mined");
    return { label, hash, receipt, entry, reused: false };
  }

  return {
    /**
     * Send one transaction, or adopt the journalled one. Never broadcasts twice for a label.
     *
     * @param {string} label stable step name, e.g. `deploy:WebAuthnLib`
     * @param {{ to?: string, data: string }} request
     */
    async send(label, request) {
      const digest = requestDigest(request);
      const existing = journal.entry(label);
      if (existing) {
        if (existing.digest !== digest) {
          throw new JournalResumeError(
            `${label} in the journal was sent with different calldata (${existing.digest} != ${digest}); ` +
            `the artifacts or configuration changed since that run — start a fresh journal`,
          );
        }
        if (existing.status === "reverted") throw new JournalRevertedError(label, existing.hash);
        if (existing.status === "mined") {
          return { label, hash: existing.hash, receipt: null, entry: existing, reused: true };
        }
        // status === "pending": resume polling the SAME hash. Never resend.
        return await settle(label, existing.hash);
      }
      const hash = await walletClient.sendTransaction({ ...request, ...(await overrides()) });
      // Durability point: on disk before a single await on the receipt.
      journal.recordPending(label, hash, digest);
      return await settle(label, hash);
    },
  };
}
