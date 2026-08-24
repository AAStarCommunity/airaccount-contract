/**
 * Durable transaction journal + resumable runner for the RepCredit evidence deploy scripts.
 *
 * CC-51 post-review MEDIUM (transaction-hash durability). The original scripts recorded a
 * transaction only *after* `waitForTransactionReceipt` resolved:
 *
 *     const receipt = await publicClient.waitForTransactionReceipt({ hash })   // may time out
 *     transactions[label] = { hash, ... }                                      // never reached
 *
 * viem's default receipt timeout is 180 s. If the implementation deploy (~10.4M gas) was still
 * queued when that elapsed, the wait threw, the assignment never ran, and the hash existed
 * nowhere. b1c28d7 inverted that order.
 *
 * CC-51 focused review MEDIUM (the SIGKILL window). Inverting the order was not enough on the
 * Sepolia path, because it still journalled the hash only once `eth_sendTransaction` *returned*:
 *
 *     const hash = await walletClient.sendTransaction(...)   // node already has the tx here
 *     journal.recordPending(label, hash, ...)                // process may die before this
 *
 * A SIGKILL (or a socket reset) between those two lines leaves a transaction the node has
 * accepted and whose hash nobody knows — the exact orphan the journal exists to prevent. For a
 * locally-signed account the window is closable, because the hash is derivable *before* anyone
 * else has seen the transaction:
 *
 *   1. resolve nonce / fees / gas explicitly and sign offline;
 *   2. the hash is keccak256(rawTransaction) — compute it and journal it as `prebroadcast`,
 *      together with `from`, `nonce` and the signed payload, before a single byte is sent;
 *   3. only then `eth_sendRawTransaction`.
 *
 * There is no longer any instant at which the network knows a transaction the journal does not.
 *
 * Broadcast failures are then *coordinated*, never blindly resent (`reconcile`):
 *   - receipt found            → mined / reverted;
 *   - still in the mempool     → pending, keep polling the same hash;
 *   - unknown, nonce consumed  → fail closed (a different transaction took that nonce; this one
 *                                can never mine, and guessing is how nonces snarl);
 *   - unknown, nonce free      → rebroadcast the byte-identical signed payload. Same signature,
 *                                same nonce, same hash: idempotent by construction, so this
 *                                cannot produce a second transaction.
 *
 * CC-51 focused review MEDIUM (`already known`). A re-offer can be answered with "already known" /
 * "known transaction" instead of the hash: the node holds the transaction but `eth_getTransactionByHash`
 * had not shown it, which is routine against a load-balanced RPC pool. That answer is the strongest
 * possible evidence the broadcast landed, so it is normalised into "this exact hash is broadcast"
 * and the run continues into settle. Two guards keep that from becoming an error sink:
 *   - the classifier checks nonce/replacement wording FIRST, so a nonce conflict can never be
 *     swallowed, and anything it does not recognise propagates untouched;
 *   - the hash is then *proved* present by receipt or mempool lookup, cross-checked against the
 *     journalled from/nonce. Unproved "already known" fails closed rather than assuming success.
 *
 * A `pending` entry is reconciled against the nonce too, so an entry whose nonce was consumed by
 * some other transaction ends in a deterministic conflict instead of being polled forever.
 *
 * A receipt timeout NEVER resends — it surfaces as PendingReceiptTimeoutError and the entry stays
 * unsettled, which is the repo's standing lesson (a timed-out Sepolia transaction must be polled,
 * never re-broadcast).
 *
 * Node-signed accounts (the Anvil unlocked deployer in deploy-repcredit-local.ts) cannot close the
 * window: the node signs, so the hash does not exist until the response comes back. That path is
 * marked `signing: "node"` in the journal and is a documented, local-only residual risk.
 *
 * The journal is deliberately separate from the evidence output file: the evidence file stays
 * write-once (`wx`), the journal is machine state and is rewritten in place.
 */

import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { keccak256 } from "viem";

export const JOURNAL_KIND = "repcredit-tx-journal";
// Bumped from 1: entries gained prebroadcast/from/nonce/raw, and the fingerprint now covers the
// ordered plan. A v1 journal cannot be resumed safely, so loading one fails closed.
export const JOURNAL_SCHEMA_VERSION = 2;

/** Statuses that mean "this transaction has not reached a terminal state yet". */
const UNSETTLED = new Set(["prebroadcast", "pending"]);

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

/**
 * Human-readable summary of an RPC failure.
 *
 * viem's `message` is often a generic wrapper ("An error occurred when sending the transaction.")
 * while the node's actual words — `nonce too low`, `insufficient funds` — sit in `shortMessage` /
 * `details` / the cause chain. Reporting only `message` leaves the operator with no reason at all,
 * so the distinguishing fields are folded in. `metaMessages` is deliberately excluded: that is
 * where viem puts the un-redacted request URL.
 */
function describeError(error, depth = 0) {
  if (error === null || error === undefined) return "unknown error";
  if (typeof error !== "object") return String(error);
  const parts = [];
  for (const key of ["message", "shortMessage", "details", "reason"]) {
    const value = error[key];
    if (typeof value === "string" && value.length > 0 && !parts.includes(value)) parts.push(value);
  }
  if (error.cause && depth < 3) {
    const nested = describeError(error.cause, depth + 1);
    if (nested && !parts.includes(nested)) parts.push(nested);
  }
  return parts.join(" — ") || String(error);
}

/** Signing succeeded, the journal has the hash, but the node refused or never answered. */
export class BroadcastFailedError extends Error {
  constructor(label, hash, journalPath, cause) {
    super(
      `${label} was signed as ${hash} and journalled BEFORE broadcast, but the broadcast failed. ` +
      `It was NOT resent blindly — re-run the same command: the hash is polled, the mempool is ` +
      `checked and the nonce is compared before the identical signed payload is offered again ` +
      `(journal: ${journalPath}). Cause: ${describeError(cause)}`,
    );
    this.name = "BroadcastFailedError";
    this.label = label;
    this.hash = hash;
    this.journalPath = journalPath;
    this.cause = cause;
  }
}

/** A journalled nonce was consumed by some other transaction; the journalled one can never mine. */
export class JournalNonceConflictError extends Error {
  constructor(label, hash, nonce, onchainNonce) {
    super(
      `${label} was signed as ${hash} at nonce ${nonce}, but the account's on-chain nonce is already ` +
      `${onchainNonce} — that nonce was consumed by a different transaction, so this one can never ` +
      `mine. Resolve it on chain deliberately (it is NOT resent automatically) and start a fresh journal.`,
    );
    this.name = "JournalNonceConflictError";
    this.label = label;
    this.hash = hash;
    this.nonce = nonce;
    this.onchainNonce = onchainNonce;
  }
}

/** The node returned a hash that is not the one we signed; two transactions must never be tracked. */
export class JournalHashMismatchError extends Error {
  constructor(label, expected, returned) {
    super(`${label}: node returned ${returned}, expected the signed payload's hash ${expected}`);
    this.name = "JournalHashMismatchError";
    this.label = label;
    this.expected = expected;
    this.returned = returned;
  }
}

/** The node said "already known" but neither a receipt nor the mempool can confirm our hash. */
export class JournalAlreadyKnownUnverifiedError extends Error {
  constructor(label, hash, cause) {
    super(
      `${label}: the node rejected the broadcast as already known, but ${hash} is in neither a receipt ` +
      `nor the mempool, so "already broadcast" could not be proven. Not treated as success and NOT ` +
      `resent — re-run to poll and coordinate again, or resolve the hash on chain. ` +
      `Cause: ${describeError(cause)}`,
    );
    this.name = "JournalAlreadyKnownUnverifiedError";
    this.label = label;
    this.hash = hash;
    this.cause = cause;
  }
}

/** The journal is not in a state that may be discarded: something is unsettled or unaccounted for. */
export class JournalAuditError extends Error {
  constructor(message, details) {
    super(message);
    this.name = "JournalAuditError";
    this.details = details;
  }
}

const sha256 = (value) => `sha256:${createHash("sha256").update(value).digest("hex")}`;

/**
 * Stable digest of the run's identity *and its plan*.
 *
 * CC-51 focused review MEDIUM: the fingerprint used to cover only chain / EntryPoint / deployer /
 * salt. Renaming or deleting a step therefore left the old entry in a journal the new run happily
 * adopted; the run never visited that label, so its hash was silently dropped when the evidence
 * file was written and `discard()` deleted the journal. Folding the ordered label list and a plan
 * schema version into the fingerprint makes any such edit refuse to resume instead.
 *
 * @param {{ labels: readonly string[] } & Record<string, unknown>} parts
 */
export function planFingerprint(parts) {
  if (!Array.isArray(parts?.labels) || parts.labels.length === 0) {
    throw new Error("planFingerprint requires the ordered plan labels");
  }
  // JSON-encoded rather than joined: no separator can appear inside a label, so two different
  // label lists can never collapse to the same fingerprint input.
  const normalised = { ...parts, labels: JSON.stringify(parts.labels) };
  return sha256(JSON.stringify(normalised, Object.keys(normalised).sort()));
}

/** Stable digest of one transaction's intent, so a resumed step cannot silently change target. */
export function requestDigest({ to = null, data = "0x" }) {
  return sha256(JSON.stringify({ to: to ? String(to).toLowerCase() : null, data: String(data).toLowerCase() }));
}

function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  // The scratch name carries pid + a random suffix. Concurrent writers are refused by the journal
  // lock, but a shared `${path}.tmp` would let two of them interleave a half-written file into the
  // rename below, so the temporary is never shared either (CC-51 focused review LOW-2).
  const tmp = `${path}.${process.pid}.${randomUUID().slice(0, 8)}.tmp`;
  writeFileSync(tmp, text);
  // rename(2) is atomic within a filesystem: readers see either the old journal or the new one,
  // never a truncated one, even if the process dies mid-write.
  renameSync(tmp, path);
}

/**
 * @param {{ path: string, fingerprint: string, plan: readonly string[], now?: () => string }} options
 */
export function createJournal({ path, fingerprint, plan, now = () => new Date().toISOString() }) {
  if (!Array.isArray(plan) || plan.length === 0) throw new Error("createJournal requires the plan labels");
  const planLabels = [...plan];
  const planSet = new Set(planLabels);
  let state = {
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    kind: JOURNAL_KIND,
    fingerprint,
    plan: planLabels,
    entries: {},
  };
  let resumed = false;
  // Labels this *process* touched. An entry nobody visited must never be dropped silently.
  const visited = new Set();

  const flush = () => writeAtomic(path, `${JSON.stringify(state, null, 2)}\n`);
  const patch = (label, fields) => {
    state.entries[label] = { ...(state.entries[label] ?? {}), ...fields };
    flush();
    return state.entries[label];
  };

  return {
    path,
    plan: planLabels,
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
        // Fail closed: a journal written for a different chain / EntryPoint / deployer / salt — or
        // for a different ordered plan — would resume onto steps that do not belong to this run.
        throw new JournalResumeError(
          `journal ${path} belongs to a different run (fingerprint ${parsed.fingerprint} != ${fingerprint}); ` +
          `point REPCREDIT_JOURNAL somewhere else or remove the stale journal deliberately`,
        );
      }
      const entries = { ...(parsed.entries ?? {}) };
      // Defence in depth behind the fingerprint: an entry outside the plan cannot be settled by
      // this run, so adopting it would strand its hash.
      const unknown = Object.keys(entries).filter((label) => !planSet.has(label));
      if (unknown.length > 0) {
        throw new JournalResumeError(
          `journal ${path} holds entries outside this run's plan (${unknown.join(", ")}); ` +
          `their hashes would be stranded — resolve them on chain before rerunning`,
        );
      }
      state = {
        schemaVersion: JOURNAL_SCHEMA_VERSION,
        kind: JOURNAL_KIND,
        fingerprint,
        plan: planLabels,
        entries,
      };
      resumed = true;
      return true;
    },
    entry(label) {
      return state.entries[label];
    },
    /** Mark a plan label as reached by this process, whether it sent or reused. */
    markVisited(label) {
      visited.add(label);
    },
    visited() {
      return [...visited];
    },
    /**
     * Persist a signed-but-not-yet-broadcast transaction. Synchronous by design: it must be on
     * disk before the payload reaches the network, so no orphan can outlive a SIGKILL.
     */
    recordPrebroadcast(label, { hash, digest, from: sender, nonce, raw, gas, maxFeePerGas, maxPriorityFeePerGas }) {
      return patch(label, {
        hash,
        digest,
        status: "prebroadcast",
        signing: "local",
        from: sender,
        nonce,
        raw,
        ...(gas !== undefined ? { gas: String(gas) } : {}),
        ...(maxFeePerGas !== undefined ? { maxFeePerGas: String(maxFeePerGas) } : {}),
        ...(maxPriorityFeePerGas !== undefined ? { maxPriorityFeePerGas: String(maxPriorityFeePerGas) } : {}),
        prebroadcastAt: now(),
      });
    },
    /** The signed payload reached the node. */
    markBroadcast(label) {
      return patch(label, { status: "pending", broadcastAt: now() });
    },
    /**
     * Persist a transaction the *node* signed and broadcast in one step (unlocked account).
     * The hash cannot exist any earlier on this path — see the module header.
     */
    recordPending(label, hash, digest, { from: sender, nonce } = {}) {
      return patch(label, {
        hash,
        digest,
        status: "pending",
        signing: "node",
        ...(sender ? { from: sender } : {}),
        ...(nonce !== undefined ? { nonce } : {}),
        sentAt: now(),
        broadcastAt: now(),
      });
    },
    /** Move an entry to its terminal state once a receipt is in hand. */
    settle(label, receipt, status) {
      const previous = state.entries[label] ?? {};
      return patch(label, {
        hash: receipt.transactionHash ?? previous.hash,
        status,
        blockNumber: receipt.blockNumber?.toString(),
        blockHash: receipt.blockHash,
        gasUsed: receipt.gasUsed?.toString(),
        settledAt: now(),
        ...(receipt.contractAddress ? { contractAddress: receipt.contractAddress } : {}),
      });
    },
    /** [label, entry] pairs that have not reached a terminal state (prebroadcast or pending). */
    unsettled() {
      return Object.entries(state.entries).filter(([, entry]) => UNSETTLED.has(entry.status));
    },
    /** Every hash this run has signed or broadcast, whatever its state — nothing is ever lost. */
    allHashes() {
      return Object.entries(state.entries).map(([label, entry]) => ({
        label,
        hash: entry.hash,
        status: entry.status,
        signing: entry.signing,
        ...(entry.from ? { from: entry.from } : {}),
        ...(entry.nonce !== undefined ? { nonce: entry.nonce } : {}),
        ...(entry.prebroadcastAt ? { prebroadcastAt: entry.prebroadcastAt } : {}),
        ...(entry.broadcastAt ? { broadcastAt: entry.broadcastAt } : {}),
        ...(entry.settledAt ? { settledAt: entry.settledAt } : {}),
      }));
    },
    /** Mined transactions in the evidence-file shape. */
    minedTransactions() {
      const out = {};
      for (const [label, entry] of Object.entries(state.entries)) {
        if (entry.status !== "mined") continue;
        out[label] = {
          hash: entry.hash,
          from: entry.from,
          nonce: entry.nonce,
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
    /**
     * Gate before the evidence file is written and the journal deleted.
     *
     * CC-51 focused review MEDIUM: `discard()` used to unlink unconditionally, so any entry the run
     * had not settled — one left pending, or one belonging to a renamed step — took its hash to the
     * grave. Nothing may be discarded while a hash is unaccounted for.
     *
     * @throws {JournalAuditError}
     */
    assertFullyAccounted() {
      const unsettled = this.unsettled().map(([label, entry]) => ({ label, hash: entry.hash, status: entry.status }));
      const unknown = Object.keys(state.entries).filter((label) => !planSet.has(label));
      const unvisited = Object.keys(state.entries).filter((label) => !visited.has(label));
      if (unsettled.length === 0 && unknown.length === 0 && unvisited.length === 0) return;
      const details = { unsettled, unknown, unvisited, journal: path };
      throw new JournalAuditError(
        `refusing to finalise: the journal still holds transactions this run cannot account for — ` +
        `unsettled=[${unsettled.map((e) => `${e.label}:${e.status}`).join(", ")}] ` +
        `outside-plan=[${unknown.join(", ")}] not-visited=[${unvisited.join(", ")}]. ` +
        `Their hashes are preserved in ${path}; resolve them on chain before finalising.`,
        details,
      );
    },
    /**
     * Remove the journal once the evidence file has been written successfully.
     * Refuses unless every hash is accounted for.
     */
    discard() {
      this.assertFullyAccounted();
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

const isNotFound = (error) =>
  error?.name === "TransactionReceiptNotFoundError" ||
  error?.name === "TransactionNotFoundError" ||
  /could not be found/i.test(error?.message ?? "");

async function maybe(promise) {
  try {
    return await promise;
  } catch (error) {
    if (isNotFound(error)) return null;
    throw error;
  }
}

const sameHash = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

/**
 * Flatten everything an RPC error carries into one searchable string.
 *
 * viem wraps the node's reply several layers deep (`shortMessage`, `details`, `metaMessages`, and a
 * `cause` chain), and different clients word the same condition differently, so classification must
 * look at the whole thing rather than `error.message` alone.
 */
function errorText(error, depth = 0) {
  if (error === null || error === undefined || depth > 5) return "";
  if (typeof error === "string") return error;
  if (typeof error !== "object") return String(error);
  const parts = [];
  for (const key of ["name", "message", "shortMessage", "details", "reason", "code"]) {
    const value = error[key];
    if (typeof value === "string" || typeof value === "number") parts.push(String(value));
  }
  if (Array.isArray(error.metaMessages)) {
    parts.push(error.metaMessages.filter((m) => typeof m === "string").join(" "));
  }
  if (error.cause) parts.push(errorText(error.cause, depth + 1));
  return parts.join(" | ");
}

// Checked FIRST and never normalised: these mean a *different* transaction owns the nonce, which is
// the one thing that must never be mistaken for "ours is already in the pool".
const NONCE_CONFLICT_RE =
  /nonce too low|nonce too high|invalid nonce|nonce has already been used|replacement transaction underpriced|OldNonce|INVALID_PARAMS: nonce/i;
// geth / erigon / nethermind / besu / reth wordings for "this exact transaction is already in the pool".
const ALREADY_KNOWN_RE =
  /already known|known transaction|ALREADY_EXISTS|AlreadyKnown|transaction already exists|already imported|already in the (?:mempool|pool|transaction pool)/i;

/**
 * Classify a failed `eth_sendRawTransaction`.
 *
 * @returns {"nonce-conflict"|"already-known"|"other"} — only `already-known` may be normalised, and
 * even then only after the hash is proven present on the node (see `locateTransaction`).
 */
export function classifyBroadcastError(error) {
  const text = errorText(error);
  if (NONCE_CONFLICT_RE.test(text)) return "nonce-conflict";
  if (ALREADY_KNOWN_RE.test(text)) return "already-known";
  return "other";
}

/**
 * Prove the node holds *this* transaction: receipt first, then the mempool.
 *
 * The lookup is by hash, so identity is implied — but a provider that echoes back a transaction
 * whose hash/from/nonce disagree with what we journalled is not evidence of anything, so every
 * field we hold is cross-checked. Returns null when nothing could be proven.
 *
 * @returns {Promise<{state: "mined"|"reverted"|"pending", receipt?: object, tx?: object}|null>}
 */
async function locateTransaction({ publicClient, hash, from, nonce }) {
  const receipt = await maybe(publicClient.getTransactionReceipt({ hash }));
  if (receipt) {
    if (receipt.transactionHash && !sameHash(receipt.transactionHash, hash)) return null;
    return { state: receipt.status === "success" ? "mined" : "reverted", receipt };
  }
  const tx = await maybe(publicClient.getTransaction({ hash }));
  if (!tx) return null;
  if (tx.hash && !sameHash(tx.hash, hash)) return null;
  if (from !== undefined && tx.from && String(tx.from).toLowerCase() !== String(from).toLowerCase()) return null;
  if (nonce !== undefined && tx.nonce !== undefined && Number(tx.nonce) !== Number(nonce)) return null;
  return { state: "pending", tx };
}

/**
 * Offer an already-signed payload to the node once, and interpret the answer.
 *
 * The only outcome other than "the node took it" that counts as success is a *proven* "already
 * known": recognised by wording that is not a nonce conflict, and then confirmed by receipt or
 * mempool. Everything else — including every error this does not recognise — propagates.
 *
 * @returns {Promise<"broadcast"|"already-known-pending"|"already-known-mined"|"already-known-reverted">}
 */
async function offerSignedPayload({ journal, publicClient, label, entry, broadcast }) {
  try {
    const returned = await broadcast();
    if (!sameHash(returned, entry.hash)) throw new JournalHashMismatchError(label, entry.hash, returned);
    journal.markBroadcast(label);
    return "broadcast";
  } catch (error) {
    // Never wrapped, never normalised: tracking two hashes for one label is unrecoverable.
    if (error instanceof JournalHashMismatchError) throw error;
    if (classifyBroadcastError(error) !== "already-known") throw error;
    const located = await locateTransaction({
      publicClient,
      hash: entry.hash,
      from: entry.from,
      nonce: entry.nonce,
    });
    if (!located) throw new JournalAlreadyKnownUnverifiedError(label, entry.hash, error);
    if (located.state === "pending") {
      journal.markBroadcast(label);
      return "already-known-pending";
    }
    // The node had it and it already reached a block: settle straight from the receipt. A revert is
    // recorded, not thrown here — the caller's normal reverted-entry path fails the run closed.
    journal.settle(label, located.receipt, located.state);
    return located.state === "mined" ? "already-known-mined" : "already-known-reverted";
  }
}

/**
 * Has `entry`'s nonce been taken by a different transaction?
 *
 * Re-checks the receipt before declaring a conflict: between the earlier receipt lookup and the
 * nonce read, our own transaction may have mined — and that bump is *our* bump. Reporting a
 * conflict there would fail a run that actually succeeded.
 *
 * @returns {Promise<{state: "mined"|"reverted"|"pending"}|null>} what the late lookup found, or
 * null when the nonce is still free. Throws JournalNonceConflictError on a genuine conflict.
 */
async function checkNonceConsumed({ journal, publicClient, label, entry }) {
  if (entry.from === undefined || entry.nonce === undefined) return null;
  const onchainNonce = await publicClient.getTransactionCount({ address: entry.from, blockTag: "latest" });
  if (!(onchainNonce > entry.nonce)) return null;
  const late = await locateTransaction({ publicClient, hash: entry.hash, from: entry.from, nonce: entry.nonce });
  if (late?.receipt) {
    journal.settle(label, late.receipt, late.state);
    return { state: late.state };
  }
  // Turned up in the pool between the two lookups: it can still mine, so poll rather than guess.
  if (late?.state === "pending") return { state: "pending" };
  throw new JournalNonceConflictError(label, entry.hash, entry.nonce, onchainNonce);
}

/**
 * Poll every unsettled hash once and reconcile it to mined / reverted / still-pending.
 *
 * Called before the deploy plan restarts, so a rerun never re-broadcasts a transaction that
 * already mined while the previous process was dying, and a `prebroadcast` entry — signed and
 * journalled, but whose broadcast outcome is unknown — is resolved deliberately rather than guessed.
 */
export async function reconcilePending({ journal, publicClient, onResult }) {
  const results = [];
  for (const [label, entry] of journal.unsettled()) {
    const receipt = await maybe(publicClient.getTransactionReceipt({ hash: entry.hash }));
    let state;
    if (receipt) {
      state = receipt.status === "success" ? "mined" : "reverted";
      journal.settle(label, receipt, state);
    } else if (entry.status === "pending") {
      state = await coordinatePending({ journal, publicClient, label, entry });
    } else {
      state = await coordinatePrebroadcast({ journal, publicClient, label, entry });
    }
    const result = { label, hash: entry.hash, state };
    results.push(result);
    onResult?.(result);
  }
  return results;
}

/**
 * Resolve a `pending` entry with no receipt: broadcast is known to have happened, so the question
 * is only whether it can still mine.
 *
 * CC-51 focused review LOW-1: `pending` used to short-circuit to "not yet" forever. If the nonce
 * had meanwhile been consumed by some other transaction (a hand-sent replacement, a fee bump), the
 * journalled hash could never mine and every rerun simply polled it again with no diagnosis. The
 * nonce is now part of reconciling a pending entry, so that case ends in a determinate conflict.
 *
 * Entries without a journalled nonce — the node-signed local path, where the node picks it — keep
 * the old behaviour, because there is nothing to compare against.
 */
async function coordinatePending({ journal, publicClient, label, entry }) {
  const tx = await maybe(publicClient.getTransaction({ hash: entry.hash }));
  if (tx) return "pending"; // in the pool: absence of a receipt just means "not yet"
  // Neither mined nor in any mempool this endpoint can see. Throws on a genuine conflict.
  const late = await checkNonceConsumed({ journal, publicClient, label, entry });
  return late?.state ?? "pending";
}

/**
 * Resolve a `prebroadcast` entry: signed and journalled, broadcast outcome unknown.
 *
 * Order matters, and every branch is deliberate:
 *   1. in the mempool  → the broadcast did land; just keep polling the same hash;
 *   2. nonce consumed  → fail closed, this transaction can never mine (see JournalNonceConflictError);
 *   3. nonce free      → offer the byte-identical signed payload again. Identical signature ⇒
 *                        identical hash ⇒ idempotent; this is not a blind resend. A node that
 *                        answers "already known" is telling us the payload is already in its pool,
 *                        which `offerSignedPayload` proves and folds into the same pending state.
 */
async function coordinatePrebroadcast({ journal, publicClient, label, entry }) {
  const tx = await maybe(publicClient.getTransaction({ hash: entry.hash }));
  if (tx) {
    journal.markBroadcast(label);
    return "pending";
  }
  if (!entry.raw || entry.from === undefined || entry.nonce === undefined) {
    // Node-signed entries never reach `prebroadcast`; a hand-edited one might.
    throw new JournalResumeError(
      `${label} is journalled as prebroadcast (${entry.hash}) but carries no signed payload, so it ` +
      `cannot be re-offered safely; resolve the hash on chain and start a fresh journal`,
    );
  }
  const late = await checkNonceConsumed({ journal, publicClient, label, entry });
  if (late?.state === "pending") {
    journal.markBroadcast(label);
    return "pending";
  }
  if (late) return late.state;
  const outcome = await offerSignedPayload({
    journal,
    publicClient,
    label,
    entry,
    broadcast: () => publicClient.sendRawTransaction({ serializedTransaction: entry.raw }),
  });
  if (outcome === "broadcast") return "rebroadcast-identical";
  if (outcome === "already-known-pending") return "already-known";
  return outcome === "already-known-mined" ? "mined" : "reverted";
}

/**
 * Local-key signer: closes the SIGKILL window by deriving the hash before the network sees anything.
 *
 * Signing goes straight to the account, not through a wallet client: `walletClient.signTransaction`
 * round-trips `eth_chainId` to the node first, which would both add a failure mode and (more to the
 * point) make "signed before anything left the process" untrue.
 *
 * @param {{ publicClient: any, account: any, chainId: number,
 *           fees: () => Promise<{maxFeePerGas: bigint, maxPriorityFeePerGas: bigint}>,
 *           gasBufferPercent?: number }} options
 */
export function createLocalSigner({ publicClient, account, chainId, fees, gasBufferPercent = 25 }) {
  return {
    mode: "local",
    async prepare(request) {
      const [nonce, fee] = await Promise.all([
        publicClient.getTransactionCount({ address: account.address, blockTag: "pending" }),
        fees(),
      ]);
      const estimated = await publicClient.estimateGas({
        account: account.address,
        ...(request.to ? { to: request.to } : {}),
        data: request.data,
      });
      // Signing pins the gas limit, so it cannot be re-estimated later; a margin keeps a resumed
      // payload valid across small state changes.
      const gas = (estimated * BigInt(100 + gasBufferPercent)) / 100n;
      const raw = await account.signTransaction({
        chainId,
        type: "eip1559",
        ...(request.to ? { to: request.to } : {}),
        data: request.data,
        value: 0n,
        gas,
        nonce,
        maxFeePerGas: fee.maxFeePerGas,
        maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
      });
      return {
        raw,
        hash: keccak256(raw),
        from: account.address,
        nonce,
        gas,
        maxFeePerGas: fee.maxFeePerGas,
        maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
      };
    },
    async broadcast(prepared) {
      return await publicClient.sendRawTransaction({ serializedTransaction: prepared.raw });
    },
  };
}

/**
 * Node signer (unlocked account). The hash only exists once the node answers, so the
 * signed-before-broadcast guarantee is unavailable here — local-only, documented residual risk.
 *
 * @param {{ walletClient: any, from: string, overrides?: () => Promise<object> }} options
 */
export function createNodeSigner({ walletClient, from: sender, overrides = async () => ({}) }) {
  return {
    mode: "node",
    from: sender,
    async prepare(request) {
      return { request: { ...request, account: sender, ...(await overrides()) }, from: sender };
    },
    async broadcast(prepared) {
      return await walletClient.sendTransaction(prepared.request);
    },
  };
}

/**
 * Build the send-and-settle helper the deploy plans run on.
 *
 * @param {{
 *   journal: ReturnType<typeof createJournal>,
 *   publicClient: any,
 *   signer: { mode: string, prepare: Function, broadcast: Function },
 *   confirmations?: number,
 *   receiptTimeoutMs?: number,
 *   pollingIntervalMs?: number,
 *   onEvent?: (event: object) => void,
 * }} options
 */
export function createTxRunner({
  journal,
  publicClient,
  signer,
  confirmations = 1,
  receiptTimeoutMs,
  pollingIntervalMs,
  onEvent,
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
     * Send one transaction, or adopt the journalled one. Never broadcasts a *different*
     * transaction for a label; a byte-identical re-offer of an already-signed payload is the only
     * repeat that can happen, and only after the mempool and the nonce have been checked.
     *
     * @param {string} label stable step name, e.g. `deploy:WebAuthnLib`
     * @param {{ to?: string, data: string }} request
     */
    async send(label, request) {
      if (!journal.plan.includes(label)) {
        // The plan is folded into the journal fingerprint; a label outside it would produce an
        // entry no audit could account for.
        throw new Error(`${label} is not part of the declared plan [${journal.plan.join(", ")}]`);
      }
      journal.markVisited(label);
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
        if (existing.status === "prebroadcast") {
          // Reconciliation normally handles this at startup; reaching it here means the entry was
          // written by this very process (a broadcast that failed mid-run). Same coordination.
          const state = await coordinatePrebroadcast({ journal, publicClient, label, entry: existing });
          onEvent?.({ status: "coordinated", step: label, hash: existing.hash, state });
        }
        // pending (or just coordinated into pending): resume polling the SAME hash. Never resend.
        return await settle(label, existing.hash);
      }

      if (signer.mode === "local") {
        const prepared = await signer.prepare(request);
        // Durability point: the hash is on disk before the payload exists anywhere but this process.
        const entry = journal.recordPrebroadcast(label, { ...prepared, digest });
        let outcome;
        try {
          outcome = await offerSignedPayload({
            journal,
            publicClient,
            label,
            entry,
            broadcast: () => signer.broadcast(prepared),
          });
        } catch (error) {
          // A hash mismatch is never wrapped — it is not a transport failure, it is two
          // transactions, and the message must survive intact to the operator.
          if (error instanceof JournalHashMismatchError) throw error;
          throw new BroadcastFailedError(label, prepared.hash, journal.path, error);
        }
        if (outcome !== "broadcast") {
          onEvent?.({ status: "already-known", step: label, hash: prepared.hash, outcome });
        }
        return await settle(label, prepared.hash);
      }

      // Node-signed: the window between "node has it" and "we know the hash" is irreducible here.
      const prepared = await signer.prepare(request);
      const hash = await signer.broadcast(prepared);
      journal.recordPending(label, hash, digest, { from: prepared.from });
      return await settle(label, hash);
    },
  };
}
