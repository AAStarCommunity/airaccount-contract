/**
 * End-to-end fault injection against the real deploy script (CC-51 post-review).
 *
 * scripts/test/repcredit-tx-journal.test.mjs proves the durability layer in isolation; this file
 * proves the script is actually wired to it, by running scripts/deploy-repcredit-local.ts as a
 * child process against a scripted JSON-RPC stub that can withhold receipts.
 *
 * Requires the forge artifacts in out/ (a full `forge build`, not --skip test).
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

const artifactsPresent = existsSync(join(repoRoot, "out/WebAuthnLib.sol/WebAuthnLib.json"));
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

function runScript(env, target = script) {
  return new Promise((done) => {
    execFile(
      tsx,
      [target],
      {
        cwd: repoRoot,
        env: { ...process.env, REPCREDIT_RECEIPT_TIMEOUT_MS: "3000", REPCREDIT_POLL_INTERVAL_MS: "100", ...env },
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

describe("deploy-repcredit-local.ts fault injection", { skip: artifactsPresent ? false : "out/ artifacts missing — run `forge build`" }, () => {
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
    for (const path of [output, journal, failure]) assert.equal(existsSync(path), false, `${path} must not exist`);
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
    for (const path of [output, journal, failure]) assert.equal(existsSync(path), false, `${path} must not exist`);
  });
});
