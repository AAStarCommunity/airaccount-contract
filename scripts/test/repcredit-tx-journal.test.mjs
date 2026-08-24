/**
 * Fault-injection tests for the RepCredit evidence deploy durability layer (CC-51 post-review).
 *
 * These drive the very code the two deploy scripts run on — createJournal / createTxRunner /
 * reconcilePending — against a scripted chain that can time out, mine late, revert or vanish.
 * The invariants under test are the ones the reviewer's MEDIUM turns on:
 *
 *   1. the hash is on disk BEFORE the receipt is awaited (asserted from inside the receipt wait);
 *   2. a receipt timeout never rebroadcasts, on the first transaction or any later one;
 *   3. a rerun polls the journalled hash, reconciles it, and resumes without resending;
 *   4. a reverted transaction fails closed and is never retried;
 *   5. a journal that does not describe this run is refused rather than reused.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";

import {
  JournalResumeError,
  PendingReceiptTimeoutError,
  createJournal,
  createTxRunner,
  planFingerprint,
  reconcilePending,
} from "../lib/repcredit-tx-journal.mjs";

const workdir = mkdtempSync(join(tmpdir(), "repcredit-journal-"));
let seq = 0;
const nextJournal = () => join(workdir, `journal-${seq++}.json`);

const FINGERPRINT = planFingerprint({ script: "test", chainId: 11155111, salt: "1" });
// A three-step plan standing in for deploy:WebAuthnLib / deploy:CommitteeBLSLib / deploy:impl.
const PLAN = [
  ["deploy:A", { data: "0xaa" }],
  ["deploy:B", { data: "0xbb" }],
  ["deploy:C", { data: "0xcc" }],
];

/** viem-shaped errors: the runner keys off `name`, exactly as the real ones set it. */
const timeoutError = (hash) =>
  Object.assign(new Error(`Timed out while waiting for transaction with hash "${hash}" to be confirmed.`), {
    name: "WaitForTransactionReceiptTimeoutError",
  });
const notFoundError = (hash) =>
  Object.assign(new Error(`Transaction receipt with hash "${hash}" could not be found.`), {
    name: "TransactionReceiptNotFoundError",
  });

/**
 * A scripted chain.
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
    /** Promote a stalled hash to mined, i.e. it confirmed while the previous process was dying. */
    mineStalled(hash, overrides = {}) {
      stalled.delete(hash);
      mined.set(hash, receiptFor(hash, overrides));
    },
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
        throw notFoundError(hash);
      },
    },
  };
  return chain;
}

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

/** One end-to-end attempt of the plan, exactly as the deploy scripts sequence it. */
async function runPlan(journalPath, chain, plan = PLAN) {
  const journal = createJournal({ path: journalPath, fingerprint: FINGERPRINT });
  journal.load();
  let reconciled = [];
  if (journal.resumed) reconciled = await reconcilePending({ journal, publicClient: chain.publicClient });
  const runner = createTxRunner({ journal, publicClient: chain.publicClient, walletClient: chain.walletClient });
  const steps = [];
  try {
    for (const [label, request] of plan) steps.push(await runner.send(label, request));
    return { journal, steps, reconciled, error: null };
  } catch (error) {
    return { journal, steps, reconciled, error };
  }
}

const onDisk = (path) => JSON.parse(readFileSync(path, "utf8"));

after(() => {
  // tmpdir cleanup is the OS's job; leaving the fixtures aids post-mortem on a failing run.
});

describe("hash durability", () => {
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
      },
    });
    const { error } = await runPlan(path, chain, [PLAN[0]]);
    assert.equal(error, null);
    assert.deepEqual(seenDuringWait, [chain.sent[0].hash]);
    assert.equal(onDisk(path).entries["deploy:A"].status, "mined");
  });

  it("records the first transaction even when its receipt never arrives", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 1 });
    const { error } = await runPlan(path, chain, [PLAN[0]]);
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
    const { error } = await runPlan(path, chain, [PLAN[0]]);
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

    const foreign = createJournal({ path, fingerprint: planFingerprint({ script: "other", chainId: 1, salt: "9" }) });
    assert.throws(() => foreign.load(), (error) => {
      assert.ok(error instanceof JournalResumeError);
      assert.match(error.message, /different run/);
      return true;
    });
  });

  it("refuses to reuse a step whose calldata changed", async () => {
    const path = nextJournal();
    const first = fakeChain({ stallFrom: 2 });
    await runPlan(path, first);

    const second = fakeChain();
    second.mined.set(first.sent[0].hash, receiptFor(first.sent[0].hash));
    // Same label, recompiled artifact: resuming would send different bytecode under a mined hash.
    const { error } = await runPlan(path, second, [["deploy:A", { data: "0xdeadbeef" }]]);
    assert.ok(error instanceof JournalResumeError);
    assert.match(error.message, /different calldata/);
    assert.equal(second.sent.length, 0);
  });

  it("rejects a corrupt or foreign journal file instead of ignoring it", async () => {
    const path = nextJournal();
    writeFileSync(path, "{not json");
    assert.throws(() => createJournal({ path, fingerprint: FINGERPRINT }).load(), /not readable JSON/);

    const other = nextJournal();
    writeFileSync(other, JSON.stringify({ kind: "something-else" }));
    assert.throws(() => createJournal({ path: other, fingerprint: FINGERPRINT }).load(), /not a repcredit-tx-journal/);
  });

  it("exposes every broadcast hash, mined or not, so nothing is stranded", async () => {
    const path = nextJournal();
    const chain = fakeChain({ stallFrom: 2 });
    const { journal } = await runPlan(path, chain);
    assert.deepEqual(journal.allHashes(), [
      { label: "deploy:A", hash: chain.sent[0].hash, status: "mined" },
      { label: "deploy:B", hash: chain.sent[1].hash, status: "pending" },
    ]);
  });

  it("discards the journal once the evidence file is written", async () => {
    const path = nextJournal();
    const chain = fakeChain();
    const { journal, error } = await runPlan(path, chain);
    assert.equal(error, null);
    assert.ok(existsSync(path));
    journal.discard();
    assert.equal(existsSync(path), false);
  });
});
