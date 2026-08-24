/**
 * Redaction tests for the RepCredit evidence deploy scripts (CC-51 MEDIUM-1 / post-review LOW-1).
 *
 * The regression under test: the previous redactor built its host rule from `new URL(url).origin`,
 * and `origin` strips the userinfo section. `https://ops:KEY@host/x` was therefore masked only by
 * the exact-string pass, so the moment viem rewrote the URL — adding the default `:443`, say —
 * the credential reached stderr and the evidence file intact.
 *
 * Run: node --test scripts/test/
 */

import { strict as assert } from "node:assert";
import { describe, it } from "node:test";

import { CREDENTIAL_PLACEHOLDER, RPC_PLACEHOLDER, createRedactor } from "../lib/repcredit-redact.mjs";

const SECRET = "SUPERSECRETPROVIDERKEY0123456789";

describe("createRedactor", () => {
  it("masks the exact configured URL", () => {
    const url = `https://eth-sepolia.g.alchemy.com/v2/${SECRET}`;
    const out = createRedactor(url)(`HttpRequestError: HTTP request failed.\nURL: ${url}`);
    assert.equal(out.includes(SECRET), false);
    assert.match(out, new RegExp(RPC_PLACEHOLDER));
  });

  it("masks userinfo credentials after the URL is rewritten (the origin-rule blind spot)", () => {
    const url = `https://ops:${SECRET}@rpc.example.io/path`;
    const redact = createRedactor(url);
    // viem normalising the URL — default port added — used to defeat the exact-string pass.
    for (const rewritten of [
      `URL: https://ops:${SECRET}@rpc.example.io:443/path`,
      `URL: https://ops:${SECRET}@rpc.example.io/path?x=1`,
      `Details: connect ECONNREFUSED https://ops:${SECRET}@rpc.example.io`,
    ]) {
      const out = redact(rewritten);
      assert.equal(out.includes(SECRET), false, `leaked in: ${rewritten}`);
    }
  });

  it("masks userinfo on a URL that reached the text by another route", () => {
    // Different host entirely: a proxy or nested cause, not the configured endpoint.
    const out = createRedactor("http://127.0.0.1:8545")(`proxied via https://ops:${SECRET}@other.example.io/rpc`);
    assert.equal(out.includes(SECRET), false);
    assert.match(out, new RegExp(CREDENTIAL_PLACEHOLDER));
  });

  it("masks provider keys carried in a path or a query string on a foreign URL", () => {
    const redact = createRedactor("http://127.0.0.1:8545");
    assert.equal(redact(`upstream https://eth-mainnet.g.alchemy.com/v2/${SECRET}`).includes(SECRET), false);
    assert.equal(redact(`upstream https://rpc.example.io/eth?apiKey=${SECRET}`).includes(SECRET), false);
    assert.equal(redact(`upstream https://rpc.example.io/eth?token=${SECRET}&x=1`).includes(SECRET), false);
  });

  it("masks the configured credential as a bare literal", () => {
    // A provider that echoes the key back in a JSON body never passes through the URL rules.
    const out = createRedactor(`https://ops:${SECRET}@rpc.example.io`)(`{"error":"unknown key ${SECRET}"}`);
    assert.equal(out.includes(SECRET), false);
  });

  it("masks a percent-encoded credential in either form", () => {
    const encoded = "p%40ssword-with-symbols";
    const decoded = "p@ssword-with-symbols";
    const redact = createRedactor(`https://ops:${encoded}@rpc.example.io`);
    assert.equal(redact(`body mentions ${decoded}`).includes(decoded), false);
    assert.equal(redact(`body mentions ${encoded}`).includes(encoded), false);
  });

  it("leaves unrelated text alone", () => {
    const redact = createRedactor("http://127.0.0.1:8545");
    // The host is regex-escaped: dots are literal, so a lookalike host is not swallowed.
    assert.equal(redact("see http://127x0y0z1:8545/rpc"), "see http://127x0y0z1:8545/rpc");
    assert.equal(redact("AA23 reverted (or OOG)"), "AA23 reverted (or OOG)");
    // Short usernames are never masked as literals — that would shred ordinary output.
    assert.equal(createRedactor("https://ops:x@rpc.example.io")("ops runbook"), "ops runbook");
  });

  it("survives an empty or malformed RPC URL without mangling the text", () => {
    // `"".split("")` would explode the string into characters; the guard must hold.
    assert.equal(createRedactor("")("deployment failed"), "deployment failed");
    assert.equal(createRedactor(undefined)("deployment failed"), "deployment failed");
    assert.equal(createRedactor("not a url")("deployment failed"), "deployment failed");
  });

  it("accepts non-string input", () => {
    assert.equal(createRedactor("http://127.0.0.1:8545")(new Error("boom").message), "boom");
    assert.equal(createRedactor("http://127.0.0.1:8545")(42), "42");
  });
});
