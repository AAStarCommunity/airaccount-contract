// Real WebAuthn (passkey) assertion generator for Foundry FFI.
//
// Acts as a software P-256 authenticator that produces data BYTE-FOR-BYTE in the same
// format a real Apple/Google passkey returns from navigator.credentials.get():
//   - clientDataJSON = '{"type":"webauthn.get","challenge":"<base64url(challenge)>",...}'
//   - authenticatorData = rpIdHash(32) || flags(1) || signCount(4)
//   - ES256 signature (ECDSA P-256 over authenticatorData || SHA256(clientDataJSON))
//
// The only difference vs a hardware passkey is WHERE the private key lives (here: software,
// so we can run unattended; on a phone: Secure Enclave). The cryptography, the signed message
// construction, and the data structures are identical — which is exactly what we must prove the
// contract accepts.
//
// Usage:  node gen_p256_assertion.mjs <challengeHex32> [flagsHexByte] [--debug]
// Output (default): a single hex string = abi.encode(
//   bytes authenticatorData, bytes clientDataJSONPrefix, bytes clientDataJSONSuffix,
//   bytes32 r, bytes32 s, bytes32 x, bytes32 y)
// consumed by the Foundry test via vm.ffi + abi.decode.

import { webcrypto, createHash } from "node:crypto";
const { subtle } = webcrypto;

// Two fixed test passkeys (P-256). Stable x,y so guardian registration is deterministic.
// Selected by the 3rd CLI arg (key index 0 or 1) — two guardians = a 2-of-2 recovery quorum.
const JWKS = [
  { kty: "EC", crv: "P-256",
    d: "a0m45zAy2KckEAMXRF7yHA4GXNBLYSKWCxoALyho1_E",
    x: "6ORyAOtpOXijhKHS1LqsognJGi_voAToGK6ac0v3KHw",
    y: "bpgI1wGsmi_K2O3mN07T3IGH6q3i8K46Q6AjJEHfMtE", ext: true },
  { kty: "EC", crv: "P-256",
    d: "tQEsWuldWVsmz9hRCVKq2FLHgrP4AONme3BpJLsMJEI",
    x: "YoEOXhyEXKmI8ZBtyNu-ngYM64VSB2_Lw23IhDlQyeU",
    y: "N1GjNIBF0EkHkg11DV0gCh01p6jxHzJffig-qvhuYWs", ext: true },
];

const ORIGIN = "https://airaccount.example";
const RP_ID = "airaccount.example";
const SECP256R1_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

const b64url = (buf) => Buffer.from(buf).toString("base64url"); // no padding
const sha256 = (buf) => createHash("sha256").update(buf).digest();
const hexToBuf = (h) => Buffer.from(h.replace(/^0x/, ""), "hex");
const hex32 = (buf) => "0x" + Buffer.from(buf).toString("hex").padStart(64, "0");

function abiEncode(authData, prefix, suffix, r, s, x, y) {
  // Minimal hand-rolled ABI encoder for (bytes,bytes,bytes,bytes32,bytes32,bytes32,bytes32).
  const word = (n) => BigInt(n).toString(16).padStart(64, "0");
  const dyn = (buf) => {
    const len = word(buf.length);
    const padded = Buffer.concat([buf, Buffer.alloc((32 - (buf.length % 32)) % 32)]);
    return len + padded.toString("hex");
  };
  const head = [];
  const tails = [];
  // 7 head slots: 3 offsets (bytes) + 4 bytes32 inline
  let offset = 7 * 32;
  // authData
  head.push(word(offset)); const t0 = dyn(authData); tails.push(t0); offset += t0.length / 2;
  // prefix
  head.push(word(offset)); const t1 = dyn(prefix); tails.push(t1); offset += t1.length / 2;
  // suffix
  head.push(word(offset)); const t2 = dyn(suffix); tails.push(t2); offset += t2.length / 2;
  // r,s,x,y inline
  head.push(Buffer.from(r).toString("hex"));
  head.push(Buffer.from(s).toString("hex"));
  head.push(Buffer.from(x).toString("hex"));
  head.push(Buffer.from(y).toString("hex"));
  return "0x" + head.join("") + tails.join("");
}

async function main() {
  const args = process.argv.slice(2).filter((a) => a !== "--debug");
  const debug = process.argv.includes("--debug");
  const challenge = hexToBuf(args[0]);
  if (challenge.length !== 32) throw new Error("challenge must be 32 bytes");
  const flags = args[1] ? parseInt(args[1], 16) : 0x05; // default UP|UV (0x01|0x04)
  const keyIdx = args[2] ? parseInt(args[2], 10) : 0;
  const JWK = JWKS[keyIdx];

  // 1. clientDataJSON, split into prefix || base64url(challenge) || suffix (what the contract rebuilds)
  const prefix = Buffer.from('{"type":"webauthn.get","challenge":"');
  const suffix = Buffer.from(`","origin":"${ORIGIN}","crossOrigin":false}`);
  const challengeB64 = b64url(challenge);
  const clientDataJSON = Buffer.concat([prefix, Buffer.from(challengeB64), suffix]);
  const cdHash = sha256(clientDataJSON);

  // 2. authenticatorData = rpIdHash(32) || flags(1) || signCount(4)
  const rpIdHash = sha256(Buffer.from(RP_ID));
  const signCount = Buffer.from([0x00, 0x00, 0x00, 0x2a]);
  const authData = Buffer.concat([rpIdHash, Buffer.from([flags]), signCount]);

  // 3. ES256 sign over authenticatorData || sha256(clientDataJSON)
  const signBase = Buffer.concat([authData, cdHash]);
  const key = await subtle.importKey("jwk", JWK, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const rawSig = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, signBase)); // P1363 r||s
  let r = BigInt("0x" + Buffer.from(rawSig.slice(0, 32)).toString("hex"));
  let s = BigInt("0x" + Buffer.from(rawSig.slice(32, 64)).toString("hex"));

  // 4. low-S normalize (contract rejects s > n/2)
  if (s > SECP256R1_N / 2n) s = SECP256R1_N - s;
  const rBuf = hexToBuf(r.toString(16).padStart(64, "0"));
  const sBuf = hexToBuf(s.toString(16).padStart(64, "0"));

  // pubkey x,y
  const xBuf = hexToBuf(Buffer.from(JWK.x, "base64url").toString("hex"));
  const yBuf = hexToBuf(Buffer.from(JWK.y, "base64url").toString("hex"));

  if (debug) {
    const payloadHash = sha256(signBase); // == what the contract feeds the P-256 verifier
    // self-verify with WebCrypto to confirm the math before it ever reaches Solidity
    const verifyKey = await subtle.importKey(
      "jwk", { kty: "EC", crv: "P-256", x: JWK.x, y: JWK.y, ext: true },
      { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    // re-encode r||s (note: we normalized s, so rebuild for verify)
    const checkSig = Buffer.concat([rBuf, sBuf]);
    const ok = await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifyKey, checkSig, signBase);
    console.error("clientDataJSON =", clientDataJSON.toString());
    console.error("challengeB64   =", challengeB64, "(len", challengeB64.length + ")");
    console.error("authData(hex)  =", authData.toString("hex"));
    console.error("payloadHash    =", hex32(payloadHash));
    console.error("x =", hex32(xBuf), "y =", hex32(yBuf));
    console.error("r =", hex32(rBuf), "s =", hex32(sBuf));
    console.error("WebCrypto self-verify (low-S):", ok);
    return;
  }

  process.stdout.write(abiEncode(authData, prefix, suffix, rBuf, sBuf, xBuf, yBuf));
}

main().catch((e) => { console.error(e); process.exit(1); });
