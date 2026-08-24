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

import { createHash } from "node:crypto";
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

/** Signing succeeded, the journal has the hash, but the node refused or never answered. */
export class BroadcastFailedError extends Error {
  constructor(label, hash, journalPath, cause) {
    super(
      `${label} was signed as ${hash} and journalled BEFORE broadcast, but the broadcast failed. ` +
      `It was NOT resent blindly — re-run the same command: the hash is polled, the mempool is ` +
      `checked and the nonce is compared before the identical signed payload is offered again ` +
      `(journal: ${journalPath}). Cause: ${cause instanceof Error ? cause.message : String(cause)}`,
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
  const tmp = `${path}.tmp`;
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
      // Broadcast is known to have happened; absence of a receipt just means "not yet".
      state = "pending";
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
 * Resolve a `prebroadcast` entry: signed and journalled, broadcast outcome unknown.
 *
 * Order matters, and every branch is deliberate:
 *   1. in the mempool  → the broadcast did land; just keep polling the same hash;
 *   2. nonce consumed  → fail closed, this transaction can never mine (see JournalNonceConflictError);
 *   3. nonce free      → offer the byte-identical signed payload again. Identical signature ⇒
 *                        identical hash ⇒ idempotent; this is not a blind resend.
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
  const onchainNonce = await publicClient.getTransactionCount({ address: entry.from, blockTag: "latest" });
  if (onchainNonce > entry.nonce) {
    throw new JournalNonceConflictError(label, entry.hash, entry.nonce, onchainNonce);
  }
  const hash = await publicClient.sendRawTransaction({ serializedTransaction: entry.raw });
  if (hash.toLowerCase() !== String(entry.hash).toLowerCase()) {
    // Cannot happen for an unmodified payload; if it ever does, stop rather than track two hashes.
    throw new JournalResumeError(
      `${label}: re-offering the journalled payload produced ${hash}, expected ${entry.hash}`,
    );
  }
  journal.markBroadcast(label);
  return "rebroadcast-identical";
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
        journal.recordPrebroadcast(label, { ...prepared, digest });
        try {
          const hash = await signer.broadcast(prepared);
          if (hash.toLowerCase() !== prepared.hash.toLowerCase()) {
            throw new Error(`node returned ${hash}, expected the signed payload's hash ${prepared.hash}`);
          }
        } catch (error) {
          throw new BroadcastFailedError(label, prepared.hash, journal.path, error);
        }
        journal.markBroadcast(label);
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
