/**
 * Fault-injection tests for the RepCredit evidence deploy durability layer (CC-51).
 *
 * These drive the very code the two deploy scripts run on — createJournal / createTxRunner /
 * createLocalSigner / createNodeSigner / reconcilePending — against a scripted chain that can time
 * out, mine late, revert, refuse a broadcast or vanish. The invariants under test:
 *
 *   1. the hash is on disk BEFORE the receipt is awaited (asserted from inside the receipt wait);
 *   2. on the locally-signed path it is on disk before the payload is broadcast at all, so a
 *      SIGKILL between "node accepted it" and "we learned the hash" cannot orphan a transaction
 *      (CC-51 focused review MEDIUM);
 *   3. a receipt timeout never rebroadcasts, on the first transaction or any later one;
 *   4. a failed broadcast is coordinated — mempool, then nonce — and only the byte-identical signed
 *      payload can ever be offered again; a consumed nonce fails closed;
 *   5. a rerun polls the journalled hash, reconciles it, and resumes without resending;
 *   6. a reverted transaction fails closed and is never retried;
 *   7. a journal that does not describe this run — different identity OR different plan — is
 *      refused rather than reused;
 *   8. nothing is discarded while a hash is unsettled, outside the plan, or unvisited.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { keccak256 } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  JournalAuditError,
  JournalNonceConflictError,
  JournalResumeError,
  PendingReceiptTimeoutError,
  createJournal,
  createLocalSigner,
  createNodeSigner,
  createTxRunner,
  planFingerprint,
  reconcilePending,
} from "../lib/repcredit-tx-journal.mjs";

const workdir = mkdtempSync(join(tmpdir(), "repcredit-journal-"));
let seq = 0;
const nextJournal = () => join(workdir, `journal-${seq++}.json`);

// A three-step plan standing in for deploy:WebAuthnLib / deploy:CommitteeBLSLib / deploy:impl.
const PLAN = [
  ["deploy:A", { data: "0xaa" }],
  ["deploy:B", { data: "0xbb" }],
  ["deploy:C", { data: "0xcc" }],
];
const PLAN_LABELS = PLAN.map(([label]) => label);
const fingerprintFor = (labels = PLAN_LABELS, extra = {}) =>
  planFingerprint({ script: "test", chainId: 11155111, salt: "1", labels, ...extra });
const FINGERPRINT = fingerprintFor();

/** viem-shaped errors: the runner keys off `name`, exactly as the real ones set it. */
const timeoutError = (hash) =>
  Object.assign(new Error(`Timed out while waiting for transaction with hash "${hash}" to be confirmed.`), {
    name: "WaitForTransactionReceiptTimeoutError",
  });
const receiptNotFound = (hash) =>
  Object.assign(new Error(`Transaction receipt with hash "${hash}" could not be found.`), {
    name: "TransactionReceiptNotFoundError",
  });
const txNotFound = (hash) =>
  Object.assign(new Error(`Transaction with hash "${hash}" could not be found.`), {
    name: "TransactionNotFoundError",
  });

function receiptFor(hash, overrides = {}) {
  return {
    transactionHash: hash,
    status: "success",
    blockNumber: 100n,
    blockHash: `0xbb${hash.slice(4)}`,
    gasUsed: 21_000n,
    contractAddress: `0xc0${hash.slice(4, 42)}`,
    ...overrides,
  };
}

/**
 * A scripted chain for the node-signed path.
 *
 * `mined` maps hash -> receipt. `stalled` holds hashes that were broadcast but have no receipt:
 * waiting on them times out and polling them reports not-found, which is precisely the Sepolia
 * "still queued after 180 s" case.
 */
function fakeChain({ stallFrom = Infinity, onWait } = {}) {
  const sent = [];
  const mined = new Map();
  const stalled = new Set();
  const chain = {
    sent,
    mined,
    stalled,
    walletClient: {
      async sendTransaction(tx) {
        const hash = `0x${(sent.length + 1).toString(16).padStart(64, "0")}`;
        sent.push({ hash, tx });
        if (sent.length >= stallFrom) stalled.add(hash);
        else mined.set(hash, receiptFor(hash));
        return hash;
      },
    },
    publicClient: {
      async waitForTransactionReceipt({ hash }) {
        await onWait?.(hash);
        if (mined.has(hash)) return mined.get(hash);
        throw timeoutError(hash);
      },
      async getTransactionReceipt({ hash }) {
        if (mined.has(hash)) return mined.get(hash);
        throw receiptNotFound(hash);
      },
      async getTransaction({ hash }) {
        if (stalled.has(hash)) return { hash };
        throw txNotFound(hash);
      },
    },
  };
  return chain;
}

/** One end-to-end attempt of the plan on the node-signed path, as deploy-repcredit-local.ts runs it. */
async function runPlan(journalPath, chain, plan = PLAN, labels = PLAN_LABELS) {
  const journal = createJournal({ path: journalPath, fingerprint: fingerprintFor(labels), plan: labels });
  const steps = [];
  let reconciled = [];
  // load/reconcile are inside the try because refusing to resume is itself an outcome under test.
  try {
    journal.load();
    if (journal.resumed) reconciled = await reconcilePending({ journal, publicClient: chain.publicClient });
    const signer = createNodeSigner({ walletClient: chain.walletClient, from: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    const runner = createTxRunner({ journal, publicClient: chain.publicClient, signer });
    for (const [label, request] of plan) steps.push(await runner.send(label, request));
    return { journal, steps, reconciled, error: null };
  } catch (error) {
    return { journal, steps, reconciled, error };
  }
}

const onDisk = (path) => JSON.parse(readFileSync(path, "utf8"));

describe("hash durability (node-signed path)", () => {
  it("persists the hash to disk before the receipt is awaited", async () => {
    const path = nextJournal();
    const seenDuringWait = [];
    // The assertion lives inside the receipt wait: at that instant the journal must already name
    // this hash. This is the exact ordering the old `await receipt; then record` violated.
    const chain = fakeChain({
      onWait: async (hash) => {
        assert.ok(existsSync(path), "journal must exist before the receipt is awaited");
        const entry = onDisk(path).entries["deploy:A"];
        seenDuringWait.push(entry?.hash);
        assert.equal(entry.hash, hash);
        assert.equal(entry.status, "pending");
        assert.equal(entry.signing, "node");
      },
    });
    const { error } = await runPlan(path, chain, [PLAN[0]], ["deploy:A"]);
    assert.equal(error, null);
    assert.deepEqual(seenDuringWait, [chain.sent[0].hash]);
    assert.equal(onDisk(path).entries["deploy:A"].status, "mined");
  });

  it("records the first transaction even when its receipt never arrives", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 1 });
    const { error } = await runPlan(path, chain, [PLAN[0]], ["deploy:A"]);
    assert.ok(error instanceof PendingReceiptTimeoutError, `expected timeout, got ${error}`);
    assert.match(error.message, /NOT resent/);
    // The regression: the old script guarded its failure record on a *confirmed* transaction, so
    // the very first timeout left the hash nowhere at all.
    const entry = onDisk(path).entries["deploy:A"];
    assert.equal(entry.status, "pending");
    assert.equal(entry.hash, chain.sent[0].hash);
    assert.equal(chain.sent.length, 1, "must not rebroadcast");
  });

  it("records a later transaction's hash and keeps the earlier ones mined", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 3 });
    const { error } = await runPlan(path, chain);
    assert.ok(error instanceof PendingReceiptTimeoutError);
    assert.equal(error.label, "deploy:C");
    const entries = onDisk(path).entries;
    assert.equal(entries["deploy:A"].status, "mined");
    assert.equal(entries["deploy:B"].status, "mined");
    assert.equal(entries["deploy:C"].status, "pending");
    assert.equal(entries["deploy:C"].hash, chain.sent[2].hash);
    assert.equal(chain.sent.length, 3);
  });
});

// ── locally-signed path: the SIGKILL window ──────────────────────────────────────────────────
//
// The node-signed path above can only journal a hash once `eth_sendTransaction` has answered, so a
// kill between "node accepted" and "we learned the hash" orphans a transaction. Signing locally
// makes the hash knowable first; these tests hold that ordering to the letter.

const TEST_ACCOUNT = privateKeyToAccount(`0x${"11".repeat(32)}`);
const FEES = async () => ({ maxFeePerGas: 4_000_000_000n, maxPriorityFeePerGas: 2_000_000_000n });

/**
 * A scripted chain for the locally-signed path.
 *
 * `failBroadcastFrom` makes eth_sendRawTransaction throw from that 1-based broadcast onwards — the
 * "signed, journalled, but the node never confirmed receiving it" case. `swallow` makes the node
 * accept the payload and then lose it (never mined, not in the mempool).
 */
function fakeRawChain({
  stallFrom = Infinity,
  failBroadcastFrom = Infinity,
  swallow = false,
  onBroadcast,
  startNonce = 0,
} = {}) {
  const broadcasts = [];
  const mined = new Map();
  const mempool = new Set();
  let nonce = startNonce;
  const chain = {
    broadcasts,
    mined,
    mempool,
    get nonce() {
      return nonce;
    },
    set nonce(value) {
      nonce = value;
    },
    publicClient: {
      async getTransactionCount() {
        return nonce;
      },
      async estimateGas() {
        return 100_000n;
      },
      async sendRawTransaction({ serializedTransaction }) {
        const hash = keccak256(serializedTransaction);
        await onBroadcast?.(hash, serializedTransaction);
        if (broadcasts.length + 1 >= failBroadcastFrom) {
          broadcasts.push({ hash, raw: serializedTransaction, accepted: false });
          throw new Error("connection reset by peer");
        }
        broadcasts.push({ hash, raw: serializedTransaction, accepted: true });
        if (swallow) {
          // Accepted and then dropped: neither mined nor in the mempool.
        } else if (broadcasts.length >= stallFrom) {
          mempool.add(hash);
        } else {
          mined.set(hash, receiptFor(hash));
          nonce += 1;
        }
        return hash;
      },
      async waitForTransactionReceipt({ hash }) {
        if (mined.has(hash)) return mined.get(hash);
        throw timeoutError(hash);
      },
      async getTransactionReceipt({ hash }) {
        if (mined.has(hash)) return mined.get(hash);
        throw receiptNotFound(hash);
      },
      async getTransaction({ hash }) {
        if (mempool.has(hash) || mined.has(hash)) return { hash };
        throw txNotFound(hash);
      },
    },
  };
  return chain;
}

async function runRawPlan(journalPath, chain, plan = PLAN, labels = PLAN_LABELS) {
  const journal = createJournal({ path: journalPath, fingerprint: fingerprintFor(labels), plan: labels });
  const steps = [];
  let reconciled = [];
  try {
    journal.load();
    if (journal.resumed) reconciled = await reconcilePending({ journal, publicClient: chain.publicClient });
    const signer = createLocalSigner({
      publicClient: chain.publicClient,
      account: TEST_ACCOUNT,
      chainId: 11155111,
      fees: FEES,
    });
    const runner = createTxRunner({ journal, publicClient: chain.publicClient, signer });
    for (const [label, request] of plan) steps.push(await runner.send(label, request));
    return { journal, steps, reconciled, error: null };
  } catch (error) {
    return { journal, steps, reconciled, error };
  }
}

describe("SIGKILL window (locally-signed path)", () => {
  it("journals the hash, from and nonce BEFORE the payload is broadcast", async () => {
    const path = nextJournal();
    const seen = [];
    // The assertion runs inside eth_sendRawTransaction — i.e. at the first instant anything outside
    // this process could possibly know about the transaction. The journal must already name it.
    const chain = fakeRawChain({
      startNonce: 4,
      onBroadcast: async (hash, raw) => {
        assert.ok(existsSync(path), "journal must exist before the payload is broadcast");
        const entry = onDisk(path).entries["deploy:A"];
        assert.equal(entry.status, "prebroadcast", "status must be prebroadcast at broadcast time");
        assert.equal(entry.hash, hash, "the journalled hash must equal keccak256(rawTransaction)");
        assert.equal(entry.raw, raw, "the signed payload is durable, so it can be re-offered verbatim");
        assert.equal(entry.from, TEST_ACCOUNT.address);
        assert.equal(entry.nonce, 4);
        assert.equal(entry.signing, "local");
        assert.ok(entry.prebroadcastAt, "prebroadcast is timestamped");
        seen.push(hash);
      },
    });
    const { error } = await runRawPlan(path, chain, [PLAN[0]], ["deploy:A"]);
    assert.equal(error, null);
    assert.deepEqual(seen, [chain.broadcasts[0].hash]);
    const entry = onDisk(path).entries["deploy:A"];
    assert.equal(entry.status, "mined");
    assert.ok(entry.broadcastAt && entry.settledAt, "the lifecycle is timestamped end to end");
  });

  it("keeps the hash when the broadcast itself fails, and does not resend in-run", async () => {
    const path = nextJournal();
    const chain = fakeRawChain({ failBroadcastFrom: 1 });
    const { error } = await runRawPlan(path, chain, [PLAN[0]], ["deploy:A"]);

    assert.equal(error.name, "BroadcastFailedError");
    assert.match(error.message, /NOT resent blindly/);
    assert.equal(chain.broadcasts.length, 1, "one attempt, no in-run retry");
    const entry = onDisk(path).entries["deploy:A"];
    assert.equal(entry.status, "prebroadcast");
    assert.equal(entry.hash, chain.broadcasts[0].hash, "the hash survives a failed broadcast");
  });

  it("adopts a prebroadcast transaction that actually mined (the SIGKILL case)", async () => {
    const path = nextJournal();
    const first = fakeRawChain({ failBroadcastFrom: 1 });
    await runRawPlan(path, first, [PLAN[0]], ["deploy:A"]);
    const orphanHash = first.broadcasts[0].hash;

    // The node had it all along and it mined — exactly what a kill between send and response hides.
    const second = fakeRawChain({ startNonce: 1 });
    second.mined.set(orphanHash, receiptFor(orphanHash));
    const resumed = await runRawPlan(path, second, [PLAN[0]], ["deploy:A"]);

    assert.equal(resumed.error, null);
    assert.deepEqual(resumed.reconciled, [{ label: "deploy:A", hash: orphanHash, state: "mined" }]);
    assert.equal(second.broadcasts.length, 0, "nothing is broadcast for a transaction already mined");
    assert.equal(onDisk(path).entries["deploy:A"].status, "mined");
  });

  it("keeps polling a prebroadcast transaction that is sitting in the mempool", async () => {
    const path = nextJournal();
    const first = fakeRawChain({ failBroadcastFrom: 1 });
    await runRawPlan(path, first, [PLAN[0]], ["deploy:A"]);
    const hash = first.broadcasts[0].hash;

    const second = fakeRawChain();
    second.mempool.add(hash);
    const resumed = await runRawPlan(path, second, [PLAN[0]], ["deploy:A"]);

    assert.ok(resumed.error instanceof PendingReceiptTimeoutError);
    assert.deepEqual(resumed.reconciled, [{ label: "deploy:A", hash, state: "pending" }]);
    assert.equal(second.broadcasts.length, 0, "a transaction in the mempool is polled, never re-sent");
    assert.equal(onDisk(path).entries["deploy:A"].status, "pending");
  });

  it("re-offers the byte-identical payload when the node never got it and the nonce is free", async () => {
    const path = nextJournal();
    const first = fakeRawChain({ failBroadcastFrom: 1 });
    await runRawPlan(path, first, [PLAN[0]], ["deploy:A"]);
    const hash = first.broadcasts[0].hash;
    const raw = onDisk(path).entries["deploy:A"].raw;

    // Unknown to the chain, nonce still free: the same signed bytes are offered again. Same
    // signature ⇒ same hash ⇒ idempotent. This is a re-offer, not a fresh blind resend.
    const second = fakeRawChain({ startNonce: 0 });
    const resumed = await runRawPlan(path, second, [PLAN[0]], ["deploy:A"]);

    assert.equal(resumed.error, null);
    assert.deepEqual(resumed.reconciled, [{ label: "deploy:A", hash, state: "rebroadcast-identical" }]);
    assert.equal(second.broadcasts.length, 1);
    assert.equal(second.broadcasts[0].raw, raw, "the very same bytes, not a re-signed transaction");
    assert.equal(second.broadcasts[0].hash, hash, "and therefore the very same hash");
  });

  it("fails closed when the nonce was consumed by a different transaction", async () => {
    const path = nextJournal();
    const first = fakeRawChain({ failBroadcastFrom: 1, startNonce: 0 });
    await runRawPlan(path, first, [PLAN[0]], ["deploy:A"]);
    const hash = first.broadcasts[0].hash;

    // Someone/something else used nonce 0. The journalled transaction can never mine; guessing is
    // what snarls a nonce, so this stops rather than re-offering anything.
    const second = fakeRawChain({ startNonce: 1 });
    const resumed = await runRawPlan(path, second, [PLAN[0]], ["deploy:A"]);

    assert.ok(resumed.error instanceof JournalNonceConflictError, `got ${resumed.error}`);
    assert.equal(resumed.error.hash, hash);
    assert.equal(resumed.error.nonce, 0);
    assert.equal(second.broadcasts.length, 0, "nothing is broadcast once the nonce conflicts");
    assert.equal(onDisk(path).entries["deploy:A"].status, "prebroadcast", "the hash is preserved for investigation");
  });

  it("resumes the rest of the plan after a mid-plan broadcast failure", async () => {
    const path = nextJournal();
    const first = fakeRawChain({ failBroadcastFrom: 3 });
    const failed = await runRawPlan(path, first);
    assert.equal(failed.error.name, "BroadcastFailedError");
    assert.equal(first.broadcasts.length, 3);

    const second = fakeRawChain({ startNonce: 2 });
    for (const [hash, receipt] of first.mined) second.mined.set(hash, receipt);
    const resumed = await runRawPlan(path, second);

    assert.equal(resumed.error, null);
    // Only the third step is re-offered; the two mined ones are served from the journal.
    assert.equal(second.broadcasts.length, 1);
    assert.equal(second.broadcasts[0].hash, first.broadcasts[2].hash, "identical payload, identical hash");
    assert.equal(Object.keys(resumed.journal.minedTransactions()).length, 3);
  });
});

describe("resume", () => {
  it("adopts a hash that mined after the timeout, without resending", async () => {
    const path = nextJournal();
    const first = fakeChain({ stallFrom: 3 });
    const failed = await runPlan(path, first);
    assert.ok(failed.error instanceof PendingReceiptTimeoutError);
    const stalledHash = first.sent[2].hash;

    // The stalled transaction confirms while nothing is watching — the orphan scenario.
    const second = fakeChain();
    for (const { hash } of first.sent) second.mined.set(hash, receiptFor(hash));
    const resumed = await runPlan(path, second);

    assert.equal(resumed.error, null);
    assert.equal(second.sent.length, 0, "a resumed run must broadcast nothing that is already on chain");
    assert.deepEqual(
      resumed.reconciled,
      [{ label: "deploy:C", hash: stalledHash, state: "mined" }],
      "the pending hash is polled and reconciled before the plan restarts",
    );
    assert.deepEqual(resumed.steps.map((s) => s.hash), first.sent.map((s) => s.hash));
    assert.ok(resumed.steps.every((s) => s.reused), "every step is served from the journal");
    assert.equal(Object.keys(resumed.journal.minedTransactions()).length, 3);
    // The contract address survives the crash: it is recovered from the receipt, not re-derived.
    assert.equal(resumed.journal.minedTransactions()["deploy:C"].contractAddress, `0xc0${stalledHash.slice(4, 42)}`);
  });

  it("keeps polling the same hash when it is still pending, and still never resends", async () => {
    const path = nextJournal();
    const first = fakeChain({ stallFrom: 2 });
    await runPlan(path, first);
    const stalledHash = first.sent[1].hash;

    const second = fakeChain();
    second.mined.set(first.sent[0].hash, receiptFor(first.sent[0].hash));
    const retry = await runPlan(path, second);

    assert.ok(retry.error instanceof PendingReceiptTimeoutError);
    assert.equal(retry.error.hash, stalledHash, "the rerun waits on the original hash");
    assert.deepEqual(retry.reconciled, [{ label: "deploy:B", hash: stalledHash, state: "pending" }]);
    assert.equal(second.sent.length, 0, "an unresolved pending hash is polled, never rebroadcast");
    assert.equal(onDisk(path).entries["deploy:B"].status, "pending");

    // Third attempt: it finally mines. The run completes from the same journal.
    const third = fakeChain();
    for (const { hash } of first.sent) third.mined.set(hash, receiptFor(hash));
    const done = await runPlan(path, third);
    assert.equal(done.error, null);
    assert.equal(third.sent.length, 1, "only the step never broadcast before is sent");
    assert.equal(third.sent[0].tx.data, "0xcc");
  });

  it("continues the plan from where it stopped rather than redeploying the stack", async () => {
    const path = nextJournal();
    // First attempt dies after two steps for a non-timeout reason (RPC fault on the third wait).
    const first = fakeChain();
    first.publicClient.waitForTransactionReceipt = (() => {
      const original = first.publicClient.waitForTransactionReceipt;
      let calls = 0;
      return async (args) => {
        calls += 1;
        if (calls === 3) throw new Error("connection reset");
        return original(args);
      };
    })();
    const partial = await runPlan(path, first);
    assert.match(partial.error.message, /connection reset/);
    assert.equal(first.sent.length, 3);

    const second = fakeChain();
    for (const { hash } of first.sent) second.mined.set(hash, receiptFor(hash));
    const resumed = await runPlan(path, second);
    assert.equal(resumed.error, null);
    assert.equal(second.sent.length, 0);
  });
});

describe("fail-closed reconciliation", () => {
  it("marks a reverted pending transaction and refuses to retry it", async () => {
    const path = nextJournal();
    const first = fakeChain({ stallFrom: 2 });
    await runPlan(path, first);
    const stalledHash = first.sent[1].hash;

    const second = fakeChain();
    second.mined.set(first.sent[0].hash, receiptFor(first.sent[0].hash));
    second.mined.set(stalledHash, receiptFor(stalledHash, { status: "reverted" }));
    const resumed = await runPlan(path, second);

    assert.deepEqual(resumed.reconciled, [{ label: "deploy:B", hash: stalledHash, state: "reverted" }]);
    assert.equal(resumed.error.name, "JournalRevertedError");
    assert.equal(second.sent.length, 0, "a reverted step is never blindly resent");
    assert.equal(onDisk(path).entries["deploy:B"].status, "reverted");
    // The hash stays in the journal, so the revert can be investigated on chain.
    assert.equal(onDisk(path).entries["deploy:B"].hash, stalledHash);
  });

  it("fails a transaction that reverts in the same run and keeps the hash", async () => {
    const path = nextJournal();
    const chain = fakeChain();
    chain.walletClient = {
      async sendTransaction(tx) {
        const hash = `0x${(chain.sent.length + 1).toString(16).padStart(64, "0")}`;
        chain.sent.push({ hash, tx });
        chain.mined.set(hash, receiptFor(hash, { status: "reverted" }));
        return hash;
      },
    };
    const { error } = await runPlan(path, chain, [PLAN[0]], ["deploy:A"]);
    assert.equal(error.name, "JournalRevertedError");
    assert.equal(onDisk(path).entries["deploy:A"].status, "reverted");
    assert.equal(onDisk(path).entries["deploy:A"].hash, chain.sent[0].hash);
  });
});

describe("journal safety", () => {
  it("refuses a journal written for a different run", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 1 });
    await runPlan(path, chain);

    const foreign = createJournal({
      path,
      plan: PLAN_LABELS,
      fingerprint: planFingerprint({ script: "other", chainId: 1, salt: "9", labels: PLAN_LABELS }),
    });
    assert.throws(() => foreign.load(), (error) => {
      assert.ok(error instanceof JournalResumeError);
      assert.match(error.message, /different run/);
      return true;
    });
  });

  it("refuses a journal whose plan differs — a renamed step must not strand its hash", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 3 });
    await runPlan(path, chain);
    const strandedHash = chain.sent[2].hash;

    // deploy:C renamed to deploy:C2. Before the plan was folded into the fingerprint, this journal
    // was adopted happily, deploy:C was never visited, and its pending hash was deleted with the
    // journal the moment the evidence file was written.
    const renamed = ["deploy:A", "deploy:B", "deploy:C2"];
    const second = fakeChain();
    for (const { hash } of chain.sent) second.mined.set(hash, receiptFor(hash));
    const resumed = await runPlan(path, second, [PLAN[0], PLAN[1], ["deploy:C2", { data: "0xcc" }]], renamed);

    assert.ok(resumed.error instanceof JournalResumeError, `got ${resumed.error}`);
    assert.match(resumed.error.message, /different run/);
    assert.equal(second.sent.length, 0);
    assert.equal(onDisk(path).entries["deploy:C"].hash, strandedHash, "the hash is still on disk, not lost");
  });

  it("refuses an entry outside the declared plan even at the same fingerprint", async () => {
    const path = nextJournal();
    writeFileSync(path, JSON.stringify({
      kind: "repcredit-tx-journal",
      schemaVersion: 2,
      fingerprint: FINGERPRINT,
      plan: PLAN_LABELS,
      entries: { "deploy:GHOST": { hash: `0x${"ee".repeat(32)}`, status: "pending" } },
    }));
    const journal = createJournal({ path, fingerprint: FINGERPRINT, plan: PLAN_LABELS });
    assert.throws(() => journal.load(), /outside this run's plan/);
  });

  it("refuses to reuse a step whose calldata changed", async () => {
    const path = nextJournal();
    const first = fakeChain({ stallFrom: 2 });
    await runPlan(path, first);

    const second = fakeChain();
    second.mined.set(first.sent[0].hash, receiptFor(first.sent[0].hash));
    // Same label, recompiled artifact: resuming would send different bytecode under a mined hash.
    const { error } = await runPlan(path, second, [["deploy:A", { data: "0xdeadbeef" }]], PLAN_LABELS);
    assert.ok(error instanceof JournalResumeError);
    assert.match(error.message, /different calldata/);
    assert.equal(second.sent.length, 0);
  });

  it("rejects a corrupt, foreign or outdated journal file instead of ignoring it", async () => {
    const path = nextJournal();
    writeFileSync(path, "{not json");
    const make = (p) => createJournal({ path: p, fingerprint: FINGERPRINT, plan: PLAN_LABELS });
    assert.throws(() => make(path).load(), /not readable JSON/);

    const other = nextJournal();
    writeFileSync(other, JSON.stringify({ kind: "something-else" }));
    assert.throws(() => make(other).load(), /not a repcredit-tx-journal/);

    // A v1 journal predates prebroadcast/from/nonce/raw, so it cannot be resumed safely.
    const old = nextJournal();
    writeFileSync(old, JSON.stringify({ kind: "repcredit-tx-journal", schemaVersion: 1, fingerprint: FINGERPRINT, entries: {} }));
    assert.throws(() => make(old).load(), /schemaVersion 1, expected 2/);
  });

  it("refuses to build a fingerprint or a journal without the ordered plan", () => {
    assert.throws(() => planFingerprint({ script: "x", chainId: 1 }), /ordered plan labels/);
    assert.throws(() => createJournal({ path: nextJournal(), fingerprint: FINGERPRINT, plan: [] }), /plan labels/);
  });

  it("refuses a step that is not part of the declared plan", async () => {
    const path = nextJournal();
    const chain = fakeChain();
    const { error } = await runPlan(path, chain, [["deploy:ROGUE", { data: "0x01" }]], PLAN_LABELS);
    assert.match(error.message, /not part of the declared plan/);
    assert.equal(chain.sent.length, 0, "an undeclared label never reaches the network");
  });

  it("exposes every broadcast hash, mined or not, so nothing is stranded", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 2 });
    const { journal } = await runPlan(path, chain);
    const hashes = journal.allHashes();
    assert.deepEqual(
      hashes.map(({ label, hash, status }) => ({ label, hash, status })),
      [
        { label: "deploy:A", hash: chain.sent[0].hash, status: "mined" },
        { label: "deploy:B", hash: chain.sent[1].hash, status: "pending" },
      ],
    );
    assert.ok(hashes.every((h) => h.signing === "node" && h.from), "provenance travels with each hash");
  });
});

describe("finalisation audit", () => {
  it("discards the journal once every step is settled", async () => {
    const path = nextJournal();
    const chain = fakeChain();
    const { journal, error } = await runPlan(path, chain);
    assert.equal(error, null);
    assert.ok(existsSync(path));
    journal.assertFullyAccounted();
    journal.discard();
    assert.equal(existsSync(path), false);
  });

  it("refuses to discard while a transaction is still unsettled", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 3 });
    const { journal } = await runPlan(path, chain);
    assert.throws(() => journal.discard(), (error) => {
      assert.ok(error instanceof JournalAuditError);
      assert.match(error.message, /refusing to finalise/);
      assert.deepEqual(error.details.unsettled.map((e) => e.label), ["deploy:C"]);
      return true;
    });
    assert.ok(existsSync(path), "the journal — and the hash in it — survives the refusal");
  });

  it("refuses to discard while an entry belongs to a step this run never reached", async () => {
    const path = nextJournal();
    // Every step mined, but the run only walked the first two labels: deploy:C was never visited,
    // so discarding would delete a settled-but-unaccounted entry from the record.
    const first = fakeChain();
    await runPlan(path, first);
    const second = fakeChain();
    for (const { hash } of first.sent) second.mined.set(hash, receiptFor(hash));
    const partial = await runPlan(path, second, [PLAN[0], PLAN[1]], PLAN_LABELS);

    assert.equal(partial.error, null);
    assert.throws(() => partial.journal.discard(), (error) => {
      assert.ok(error instanceof JournalAuditError);
      assert.deepEqual(error.details.unvisited, ["deploy:C"]);
      return true;
    });
    assert.ok(existsSync(path));
  });
});
