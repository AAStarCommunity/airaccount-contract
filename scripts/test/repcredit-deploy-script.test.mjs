/**
 * End-to-end fault injection against the real deploy script (CC-51 post-review).
 *
 * scripts/test/repcredit-tx-journal.test.mjs proves the durability layer in isolation; this file
 * proves the script is actually wired to it, by running scripts/deploy-repcredit-local.ts as a
 * child process against a scripted JSON-RPC stub that can withhold receipts.
 *
 * Requires the forge artifacts in out/ (a full `forge build`, not --skip test).
 *
 * CC-51 focused review MEDIUM: these cases used to *skip* when out/ was missing, so CI stayed green
 * on an incomplete build — precisely the `--skip test` mistake that drops RepCreditCounter. Set
 * REQUIRE_ARTIFACTS=1 (as the workflow does) and a missing artifact is a hard failure instead.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const script = join(repoRoot, "scripts/deploy-repcredit-local.ts");
const sepoliaScript = join(repoRoot, "scripts/deploy-repcredit-sepolia.ts");
const tsx = join(repoRoot, "node_modules/.bin/tsx");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const RPC_SECRET = "SUPERSECRETPROVIDERKEY0123456789";

// Every artifact the scripts actually load. RepCreditCounter is the one a `forge build --skip test`
// silently omits, so it is checked explicitly rather than inferred from the others.
const REQUIRED_ARTIFACTS = [
  "WebAuthnLib",
  "CommitteeBLSLib",
  "AAStarAirAccountV7",
  "AAStarAirAccountFactoryV7",
  "RepCreditCounter",
];
const missingArtifacts = REQUIRED_ARTIFACTS.filter(
  (name) => !existsSync(join(repoRoot, `out/${name}.sol/${name}.json`)),
);
const REQUIRE_ARTIFACTS = process.env.REQUIRE_ARTIFACTS === "1";
if (REQUIRE_ARTIFACTS && missingArtifacts.length > 0) {
  // Fail closed: under REQUIRE_ARTIFACTS=1 a missing artifact must red the gate, never skip it.
  throw new Error(
    `REQUIRE_ARTIFACTS=1 but out/ is missing ${missingArtifacts.join(", ")} — ` +
    `run a full \`forge build\` (not --skip test) before these tests`,
  );
}
const artifactsPresent = missingArtifacts.length === 0;
const skipWithoutArtifacts = artifactsPresent
  ? false
  : `out/ artifacts missing (${missingArtifacts.join(", ")}) — run \`forge build\``;
const workdir = mkdtempSync(join(tmpdir(), "repcredit-script-"));

/**
 * Minimal JSON-RPC stub. `stallFrom` is the 1-based index of the first transaction whose receipt
 * is withheld — the "still queued when the 180 s timeout fires" case. `mined` can be seeded with
 * hashes from a previous attempt, which is how a resumed run sees its pending hash confirm.
 * `tag` keeps each stub's hashes distinct, so a resumed attempt cannot accidentally reissue the
 * previous attempt's hash and mask a rebroadcast.
 */
function rpcStub({ stallFrom = Infinity, mined = new Set(), tag = "aa" } = {}) {
  const sent = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const batch = Array.isArray(request) ? request : [request];
      const responses = batch.map((entry) => ({
        jsonrpc: "2.0",
        id: entry.id,
        result: handle(entry.method, entry.params ?? []),
      }));
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(Array.isArray(request) ? responses : responses[0]));
    });
  });

  function handle(method, params) {
    switch (method) {
      case "eth_chainId":
        return "0x7a69"; // 31337
      case "eth_getCode":
        return "0x60006000"; // the EntryPoint must have code
      case "eth_blockNumber":
        return "0x64";
      case "eth_getBlockByNumber":
        return { number: "0x64", hash: `0x${"b".repeat(64)}`, baseFeePerGas: "0x3b9aca00", timestamp: "0x1", transactions: [] };
      case "eth_maxPriorityFeePerGas":
      case "eth_gasPrice":
        return "0x3b9aca00";
      case "eth_getTransactionCount":
        return `0x${sent.length.toString(16)}`;
      case "eth_estimateGas":
        return "0x1e8480";
      case "eth_accounts":
        return ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"];
      case "eth_sendTransaction":
      case "eth_sendRawTransaction": {
        const hash = `0x${tag}${(sent.length + 1).toString(16).padStart(62, "0")}`;
        sent.push(hash);
        if (sent.length < stallFrom) mined.add(hash);
        return hash;
      }
      case "eth_getTransactionByHash":
        return null;
      case "eth_getTransactionReceipt": {
        const [hash] = params;
        if (!mined.has(hash)) return null;
        return {
          transactionHash: hash,
          transactionIndex: "0x0",
          blockNumber: "0x64",
          blockHash: `0x${"b".repeat(64)}`,
          from: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
          to: null,
          contractAddress: `0x${hash.slice(26)}`,
          cumulativeGasUsed: "0x1e8480",
          gasUsed: "0x1e8480",
          effectiveGasPrice: "0x3b9aca00",
          logs: [],
          logsBloom: `0x${"0".repeat(512)}`,
          status: "0x1",
          type: "0x2",
        };
      }
      default:
        return null;
    }
  }

  return {
    sent,
    mined,
    listen: () =>
      new Promise((done) => {
        server.listen(0, "127.0.0.1", () => done(server.address().port));
      }),
    close: () => new Promise((done) => server.close(done)),
  };
}

// CC-51 focused review LOW: the child used to inherit the whole environment. A developer with
// REPCREDIT_RPC_URL / REPCREDIT_PRIVATE_KEY / REPCREDIT_ENTRYPOINT exported in their shell would
// then run these cases against a real endpoint with a real key — and the outcome would depend on
// their shell rather than on the test. Only what Node itself needs is passed through.
const ENV_ALLOWLIST = ["PATH", "HOME", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "SystemRoot", "ComSpec"];
const baseEnv = () =>
  Object.fromEntries(ENV_ALLOWLIST.filter((key) => process.env[key] !== undefined).map((key) => [key, process.env[key]]));

/** Start the script without waiting for it, so two runs can overlap. */
function startScript(env, target = script) {
  let settle;
  const done = new Promise((resolve) => (settle = resolve));
  const child = execFile(
    tsx,
    [target],
    {
      cwd: repoRoot,
      env: { ...baseEnv(), REPCREDIT_RECEIPT_TIMEOUT_MS: "3000", REPCREDIT_POLL_INTERVAL_MS: "100", ...env },
      timeout: 120_000,
    },
    (error, stdout, stderr) => settle({ code: error?.code ?? 0, stdout, stderr }),
  );
  return { child, done };
}

/** Poll until `predicate()` holds, so an overlap test does not depend on sleep guesswork. */
async function waitFor(predicate, { timeoutMs = 20_000, intervalMs = 25 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error("timed out waiting for a condition");
}

function runScript(env, target = script) {
  return new Promise((done) => {
    execFile(
      tsx,
      [target],
      {
        cwd: repoRoot,
        env: { ...baseEnv(), REPCREDIT_RECEIPT_TIMEOUT_MS: "3000", REPCREDIT_POLL_INTERVAL_MS: "100", ...env },
        timeout: 120_000,
      },
      (error, stdout, stderr) => done({ code: error?.code ?? 0, stdout, stderr }),
    );
  });
}

let caseId = 0;
const paths = () => {
  const output = join(workdir, `case-${caseId++}`, "deployment.json");
  return { output, journal: `${output}.journal.json`, failure: `${output}.failed.json` };
};
const read = (path) => JSON.parse(readFileSync(path, "utf8"));

describe("deploy-repcredit-local.ts fault injection", { skip: skipWithoutArtifacts }, () => {
  let stub;
  after(async () => {
    await stub?.close();
  });

  it("journals the first transaction's hash when its receipt never arrives, and does not resend", async () => {
    stub = rpcStub({ stallFrom: 1, tag: "a1" });
    const port = await stub.listen();
    const { output, journal, failure } = paths();
    // The credential sits in the URL userinfo — the shape the origin-based redactor used to miss.
    const rpcUrl = `http://ops:${RPC_SECRET}@127.0.0.1:${port}`;

    const run = await runScript({
      REPCREDIT_RPC_URL: rpcUrl,
      REPCREDIT_ENTRYPOINT: ENTRYPOINT,
      REPCREDIT_OUTPUT: output,
    });
    await stub.close();

    assert.equal(run.code, 1, run.stderr);
    assert.match(run.stderr, /NOT resent/);
    assert.equal(stub.sent.length, 1, "exactly one broadcast, never a retry");

    // The hash is durable even though no receipt ever came back.
    assert.ok(existsSync(journal), "journal must exist");
    const entry = read(journal).entries["deploy:WebAuthnLib"];
    assert.equal(entry.status, "pending");
    assert.equal(entry.hash, stub.sent[0]);

    // ...and the human-readable failure record now exists for a first-transaction timeout too.
    assert.ok(existsSync(failure), "failure record must be written on the very first timeout");
    const record = read(failure);
    assert.equal(record.status, "failed");
    assert.deepEqual(record.pending.map((p) => p.hash), [stub.sent[0]]);
    assert.match(record.resume, /Never re-broadcast/);
    assert.equal(existsSync(output), false, "the write-once evidence file stays free for the resumed run");

    // Redaction: the provider credential appears nowhere, in any channel.
    for (const [name, text] of [
      ["stdout", run.stdout],
      ["stderr", run.stderr],
      ["failure record", readFileSync(failure, "utf8")],
      ["journal", readFileSync(journal, "utf8")],
    ]) {
      assert.equal(text.includes(RPC_SECRET), false, `${RPC_SECRET} leaked into ${name}`);
      assert.equal(text.includes(rpcUrl), false, `the raw RPC URL leaked into ${name}`);
    }
  });

  it("resumes from the journal: the stalled hash is adopted and only the remaining steps are sent", async () => {
    const first = rpcStub({ stallFrom: 1, tag: "b1" });
    const firstPort = await first.listen();
    const { output, journal } = paths();
    const env = { REPCREDIT_ENTRYPOINT: ENTRYPOINT, REPCREDIT_OUTPUT: output };

    const failedRun = await runScript({ ...env, REPCREDIT_RPC_URL: `http://127.0.0.1:${firstPort}` });
    await first.close();
    assert.equal(failedRun.code, 1);
    const stalledHash = read(journal).entries["deploy:WebAuthnLib"].hash;

    // Second attempt: the stalled transaction has since mined, and the next one stalls in turn.
    stub = rpcStub({ stallFrom: 1, mined: new Set([stalledHash]), tag: "b2" });
    const port = await stub.listen();
    const resumed = await runScript({ ...env, REPCREDIT_RPC_URL: `http://127.0.0.1:${port}` });
    await stub.close();

    assert.equal(resumed.code, 1, resumed.stderr);
    assert.match(resumed.stderr, /"status":"resume"/, "the rerun reconciles before it sends");
    assert.match(resumed.stderr, /"state":"mined"/, "the stalled hash is polled and found mined");
    assert.match(resumed.stderr, /"status":"resumed","step":"deploy:WebAuthnLib"/);

    const entries = read(journal).entries;
    assert.equal(entries["deploy:WebAuthnLib"].status, "mined");
    assert.equal(entries["deploy:WebAuthnLib"].hash, stalledHash, "the original hash is kept");
    assert.ok(entries["deploy:WebAuthnLib"].contractAddress, "its address is recovered from the receipt");
    // The resumed run broadcast the NEXT step only — the mined one was never sent again.
    assert.equal(stub.sent.length, 1);
    assert.equal(entries["deploy:CommitteeBLSLib"].status, "pending");
    assert.equal(entries["deploy:CommitteeBLSLib"].hash, stub.sent[0]);
  });

  it("refuses to resume a journal that belongs to a different run", async () => {
    stub = rpcStub({ stallFrom: 1, tag: "c1" });
    const port = await stub.listen();
    const { output } = paths();
    const rpc = `http://127.0.0.1:${port}`;

    const first = await runScript({ REPCREDIT_RPC_URL: rpc, REPCREDIT_ENTRYPOINT: ENTRYPOINT, REPCREDIT_OUTPUT: output });
    assert.equal(first.code, 1);
    const before = stub.sent.length;

    // Same journal, different deployer: resuming would adopt contracts owned by someone else.
    const second = await runScript({
      REPCREDIT_RPC_URL: rpc,
      REPCREDIT_ENTRYPOINT: ENTRYPOINT,
      REPCREDIT_OUTPUT: output,
      REPCREDIT_DEPLOYER: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    });
    await stub.close();

    assert.equal(second.code, 1);
    assert.match(second.stderr, /belongs to a different run/);
    assert.equal(stub.sent.length, before, "nothing is broadcast once resume is refused");
  });
});

describe("deploy-repcredit-sepolia.ts fail-closed guards", () => {
  // A key that exists only here; the script must never echo it, and these cases never send.
  const FAKE_KEY = `0x${"11".repeat(32)}`;
  const V06_ENTRYPOINT = "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789";

  it("rejects a non-canonical EntryPoint before any RPC call and writes nothing", async () => {
    const { output, journal, failure } = paths();
    const run = await runScript(
      {
        // Port 1 is unreachable: if the guard ever moved after the first RPC call, this would hang
        // or report a connection error instead of the EntryPoint message.
        REPCREDIT_RPC_URL: "http://127.0.0.1:1",
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: V06_ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    assert.equal(run.code, 1);
    assert.match(run.stderr, /is not the canonical v0.7 EntryPoint/);
    assert.match(run.stderr, /REPCREDIT_ALLOW_NONCANONICAL_ENTRYPOINT/);
    assert.equal(run.stderr.includes(FAKE_KEY), false, "the private key must never be echoed");
    for (const path of [output, journal, failure, `${journal}.lock`]) {
      assert.equal(existsSync(path), false, `${path} must not exist`);
    }
  });

  it("writes no journal, evidence or failure record in DRY_RUN", async () => {
    const { output, journal, failure } = paths();
    const run = await runScript(
      {
        DRY_RUN: "1",
        REPCREDIT_RPC_URL: `http://ops:${RPC_SECRET}@127.0.0.1:1`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    // The dead endpoint makes preflight fail — the point is what is NOT written, and NOT leaked.
    assert.equal(run.code, 1);
    assert.equal(run.stderr.includes(RPC_SECRET), false, "the RPC credential leaked in DRY_RUN");
    assert.equal(run.stderr.includes(FAKE_KEY), false);
    // The mutex is journal state too: a dry run takes no lock and so cannot block a real run.
    for (const path of [output, journal, failure, `${journal}.lock`]) {
      assert.equal(existsSync(path), false, `${path} must not exist`);
    }
  });
});

// ── Sepolia path: the SIGKILL window, proven through the real script ─────────────────────────
//
// deploy-repcredit-sepolia.ts signs locally and journals keccak256(rawTransaction) before it
// broadcasts. These cases run the actual script against a stub that stalls, and check what is on
// disk at the moment the run gives up — the hash must be there, derived from the signed payload,
// with the from/nonce needed to coordinate a rerun.

const keccak = async (hex) => {
  const { keccak256 } = await import("viem");
  return keccak256(hex);
};

// The stub has to answer eth_getTransactionByHash with the *real* sender: the durability layer
// cross-checks from/nonce before it believes a node that says "already known".
const { privateKeyToAccount } = await import("viem/accounts");
const SEPOLIA_KEY = `0x${"22".repeat(32)}`;
const SEPOLIA_DEPLOYER = privateKeyToAccount(SEPOLIA_KEY).address;

/**
 * A Sepolia-shaped JSON-RPC stub.
 *
 * `honestHash: false` makes eth_sendRawTransaction answer with a hash that is not the payload's —
 * the script must notice rather than adopt whatever the node claims.
 */
function sepoliaStub({ honestHash = true, stall = true, sendError = null, visibleAfterError = false } = {}) {
  const raws = [];
  const mined = new Map();
  const mempool = new Set();
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
      const request = JSON.parse(body);
      const batch = Array.isArray(request) ? request : [request];
      const responses = [];
      for (const entry of batch) {
        const result = await handle(entry.method, entry.params ?? []);
        // A node rejecting a broadcast answers with a JSON-RPC error, not a result — that shape is
        // what viem turns into the wrapped error the classifier has to read.
        responses.push(
          result?.__rpcError
            ? { jsonrpc: "2.0", id: entry.id, error: { code: -32000, message: result.__rpcError } }
            : { jsonrpc: "2.0", id: entry.id, result },
        );
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(Array.isArray(request) ? responses : responses[0]));
    });
  });

  async function handle(method, params) {
    switch (method) {
      case "eth_chainId":
        return "0xaa36a7"; // 11155111
      case "eth_getCode":
        return "0x60006000";
      case "eth_blockNumber":
        return "0x64";
      case "eth_getBlockByNumber":
        return { number: "0x64", hash: `0x${"b".repeat(64)}`, baseFeePerGas: "0x3b9aca00", timestamp: "0x1", transactions: [] };
      case "eth_maxPriorityFeePerGas":
      case "eth_gasPrice":
        return "0x77359400";
      case "eth_getBalance":
        return "0xde0b6b3a7640000";
      case "eth_getTransactionCount":
        return `0x${mined.size.toString(16)}`;
      case "eth_estimateGas":
        return "0x1e8480";
      case "eth_sendRawTransaction": {
        const [raw] = params;
        const real = await keccak(raw);
        raws.push({ raw, hash: real });
        if (!stall) mined.set(real, real);
        // `already known` means the node kept the payload and is telling us so through an error.
        if (sendError) {
          if (visibleAfterError) mempool.add(real);
          return { __rpcError: sendError };
        }
        return honestHash ? real : `0x${"f".repeat(64)}`;
      }
      case "eth_getTransactionByHash": {
        const [hash] = params;
        if (!mempool.has(hash)) return null;
        return {
          hash,
          from: SEPOLIA_DEPLOYER,
          nonce: "0x0",
          blockHash: null,
          blockNumber: null,
          to: null,
          value: "0x0",
          gas: "0x1e8480",
          input: "0x",
          type: "0x2",
        };
      }
      case "eth_getTransactionReceipt":
        return null;
      default:
        return null;
    }
  }

  return {
    raws,
    listen: () => new Promise((done) => server.listen(0, "127.0.0.1", () => done(server.address().port))),
    close: () => new Promise((done) => server.close(done)),
  };
}

describe("deploy-repcredit-sepolia.ts closes the broadcast window", { skip: skipWithoutArtifacts }, () => {
  const FAKE_KEY = SEPOLIA_KEY;

  it("journals the locally-derived hash, from and nonce, and never resends on a stall", async () => {
    const stub = sepoliaStub();
    const port = await stub.listen();
    const { output, journal, failure } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: `http://ops:${RPC_SECRET}@127.0.0.1:${port}`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    await stub.close();

    assert.equal(run.code, 1, run.stderr);
    assert.match(run.stderr, /NOT resent/);
    assert.equal(stub.raws.length, 1, "exactly one broadcast, never a retry");

    const entry = read(journal).entries["deploy:WebAuthnLib"];
    assert.equal(entry.signing, "local", "the Sepolia path signs locally");
    assert.equal(entry.status, "pending");
    // The hash in the journal is keccak256 of the payload this process signed — it does not come
    // from the node's response, which is what makes a SIGKILL before that response survivable.
    assert.equal(entry.hash, stub.raws[0].hash);
    assert.equal(entry.raw, stub.raws[0].raw, "the signed payload is durable for an identical re-offer");
    assert.equal(entry.nonce, 0);
    assert.ok(entry.from, "the sender is recorded so the nonce can be checked on a rerun");
    assert.ok(entry.prebroadcastAt && entry.broadcastAt);
    // Independence check: the stub keccak-hashes the bytes it *received*, the script hashes the
    // bytes it *signed*. They agree, so the journalled hash was derived locally rather than copied
    // from the response — the property the SIGKILL window turns on.

    const record = read(failure);
    assert.equal(record.status, "failed");
    assert.ok(Date.parse(record.generatedAt) > 0, "the sidecar is timestamped");
    assert.equal(record.attempt, 1);
    assert.deepEqual(record.broadcasts.map((b) => b.hash), [entry.hash], "every hash is in the evidence sidecar");
    assert.deepEqual(record.plan.labels[0], "deploy:WebAuthnLib");
    assert.equal(existsSync(output), false, "the write-once evidence path stays free for the rerun");

    for (const [name, text] of [
      ["stdout", run.stdout],
      ["stderr", run.stderr],
      ["failure record", readFileSync(failure, "utf8")],
      ["journal", readFileSync(journal, "utf8")],
    ]) {
      assert.equal(text.includes(RPC_SECRET), false, `${RPC_SECRET} leaked into ${name}`);
      assert.equal(text.includes(FAKE_KEY), false, `the private key leaked into ${name}`);
    }
  });

  it("refuses a hash the node invented instead of adopting it", async () => {
    const stub = sepoliaStub({ honestHash: false });
    const port = await stub.listen();
    const { output, journal } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: `http://127.0.0.1:${port}`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    await stub.close();

    assert.equal(run.code, 1);
    assert.match(run.stderr, /expected the signed payload's hash/);
    assert.equal(stub.raws.length, 1, "a disagreement stops the run; it does not resend");
    // The journalled hash is the one this process derived, not the node's fiction.
    const entry = read(journal).entries["deploy:WebAuthnLib"];
    assert.equal(entry.hash, stub.raws[0].hash);
    assert.equal(entry.status, "prebroadcast");
  });

  it("treats `already known` as proof the payload is broadcast, not as a reason to abort", async () => {
    // A load-balanced RPC pool routinely answers the broadcast with "already known" while the
    // read backend still shows nothing by hash. Aborting there strands a transaction that landed.
    const stub = sepoliaStub({ sendError: "already known", visibleAfterError: true });
    const port = await stub.listen();
    const { output, journal, failure } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: `http://ops:${RPC_SECRET}@127.0.0.1:${port}`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    await stub.close();

    assert.equal(run.code, 1);
    // The run went *through* the error into the ordinary polling path, and said so.
    assert.match(run.stderr, /"status":"already-known"/);
    assert.match(run.stderr, /NOT resent/, "it ends as a durable pending, not as a broadcast failure");
    assert.equal(run.stderr.includes("but the broadcast failed"), false, "no abort on a known transaction");
    assert.equal(stub.raws.length, 1, "normalising is not retrying");

    const entry = read(journal).entries["deploy:WebAuthnLib"];
    assert.equal(entry.status, "pending", "`already known` + mempool proof ⇒ broadcast");
    assert.equal(entry.hash, stub.raws[0].hash, "and it is still the locally-derived hash");
    assert.deepEqual(read(failure).broadcasts.map((b) => b.hash), [entry.hash]);
    for (const [name, text] of [["stdout", run.stdout], ["stderr", run.stderr]]) {
      assert.equal(text.includes(RPC_SECRET), false, `${RPC_SECRET} leaked into ${name}`);
    }
  });

  it("fails closed when `already known` cannot be proven on chain", async () => {
    // Same wording, but nothing confirms the hash. Believing the node here would be a swallowed
    // error dressed up as success.
    const stub = sepoliaStub({ sendError: "already known", visibleAfterError: false });
    const port = await stub.listen();
    const { output, journal } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: `http://127.0.0.1:${port}`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    await stub.close();

    assert.equal(run.code, 1);
    assert.match(run.stderr, /could not be proven/);
    assert.equal(stub.raws.length, 1);
    assert.equal(read(journal).entries["deploy:WebAuthnLib"].status, "prebroadcast");
  });

  it("does not swallow a nonce conflict wearing the same clothes", async () => {
    const stub = sepoliaStub({ sendError: "already known: replacement transaction underpriced", visibleAfterError: true });
    const port = await stub.listen();
    const { output, journal } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: `http://127.0.0.1:${port}`,
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
      },
      sepoliaScript,
    );
    await stub.close();

    assert.equal(run.code, 1);
    // Nonce wording wins over already-known wording: the run stops with the node's own reason.
    assert.match(run.stderr, /replacement transaction underpriced/);
    assert.equal(run.stderr.includes('"status":"already-known"'), false);
    assert.equal(read(journal).entries["deploy:WebAuthnLib"].status, "prebroadcast");
  });

  it("rejects a malformed receipt timeout instead of silently using the default", async () => {
    const { output, journal, failure } = paths();
    const run = await runScript(
      {
        REPCREDIT_RPC_URL: "http://127.0.0.1:1",
        REPCREDIT_PRIVATE_KEY: FAKE_KEY,
        REPCREDIT_ENTRYPOINT: ENTRYPOINT,
        REPCREDIT_OUTPUT: output,
        REPCREDIT_RECEIPT_TIMEOUT_MS: "30s",
      },
      sepoliaScript,
    );
    assert.equal(run.code, 1);
    assert.match(run.stderr, /REPCREDIT_RECEIPT_TIMEOUT_MS must be a positive integer/);
    for (const path of [output, journal, failure]) assert.equal(existsSync(path), false, `${path} must not exist`);
  });
});

// ── two processes, one journal path ──────────────────────────────────────────────────────────
//
// CC-51 focused review LOW-2, proven through the real script rather than the library alone: a
// second evidence run pointed at the same output would previously adopt the same journal and
// overwrite it, dropping a hash that was already on the network.

describe("deploy-repcredit-local.ts refuses a concurrent run on the same journal", { skip: skipWithoutArtifacts }, () => {
  it("admits one process, fails the second closed, and keeps the first run's hash", async () => {
    const stub = rpcStub({ stallFrom: 1, tag: "e1" });
    const port = await stub.listen();
    const { output, journal } = paths();
    const env = {
      REPCREDIT_RPC_URL: `http://127.0.0.1:${port}`,
      REPCREDIT_ENTRYPOINT: ENTRYPOINT,
      REPCREDIT_OUTPUT: output,
    };

    // The first run holds the lock while it waits out a receipt that never comes.
    const first = startScript(env);
    await waitFor(() => existsSync(`${journal}.lock`));
    const holder = JSON.parse(readFileSync(`${journal}.lock`, "utf8"));
    assert.equal(holder.kind, "repcredit-journal-lock");

    const second = await runScript(env);
    assert.equal(second.code, 1, "a concurrent run must not proceed");
    assert.match(second.stderr, /is held/);
    assert.match(second.stderr, /pid \d+ .* is still running/);
    assert.equal(stub.sent.length, 1, "the refused run broadcast nothing");
    // It also must not have written the loser's view of the journal over the holder's.
    assert.equal(JSON.parse(readFileSync(`${journal}.lock`, "utf8")).token, holder.token);

    const firstResult = await first.done;
    await stub.close();
    assert.equal(firstResult.code, 1, "the holder still ends on its own receipt timeout");
    assert.match(firstResult.stderr, /NOT resent/);

    // The decisive check: the first run's hash survived the concurrent attempt.
    const entry = read(journal).entries["deploy:WebAuthnLib"];
    assert.equal(entry.hash, stub.sent[0]);
    assert.equal(entry.status, "pending");
    assert.equal(existsSync(`${journal}.lock`), false, "the holder released the lock on exit");
  });

  it("lets the run resume once the lock is free", async () => {
    // Same journal, sequentially: the lock is released, so the rerun resumes normally rather than
    // being blocked by its own predecessor's leftover.
    const first = rpcStub({ stallFrom: 1, tag: "f1" });
    const firstPort = await first.listen();
    const { output, journal } = paths();
    const env = { REPCREDIT_ENTRYPOINT: ENTRYPOINT, REPCREDIT_OUTPUT: output };

    const failed = await runScript({ ...env, REPCREDIT_RPC_URL: `http://127.0.0.1:${firstPort}` });
    await first.close();
    assert.equal(failed.code, 1);
    assert.equal(existsSync(`${journal}.lock`), false, "no leftover lock after a clean failure");

    const stalledHash = read(journal).entries["deploy:WebAuthnLib"].hash;
    const second = rpcStub({ stallFrom: 2, tag: "f2", mined: new Set([stalledHash]) });
    const secondPort = await second.listen();
    const resumed = await runScript({ ...env, REPCREDIT_RPC_URL: `http://127.0.0.1:${secondPort}` });
    await second.close();

    assert.match(resumed.stderr, /"status":"resume"/);
    assert.equal(read(journal).entries["deploy:WebAuthnLib"].status, "mined");
    assert.equal(second.sent.includes(stalledHash), false, "the resumed run never re-sent it");
  });
});
