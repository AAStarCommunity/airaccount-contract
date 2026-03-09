/**
 * Debug BLS signature scheme to understand the correct signing method.
 * noble/curves bls12-381 has two schemes:
 * - "short" (default bls.sign): signatures in G1 (48 bytes), public keys in G2
 * - "long": signatures in G2 (96 bytes), public keys in G1
 * Our contract uses G1 public keys and G2 signatures, so we need the "long" scheme.
 */

import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { hexToBytes, bytesToHex } from "viem";

const BLS_DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

const sk1hex = process.env.BLS_TEST_PRIVATE_KEY_1!;
const sk2hex = process.env.BLS_TEST_PRIVATE_KEY_2!;
const pk1hex = process.env.BLS_TEST_PUBLIC_KEY_1!;
const pk2hex = process.env.BLS_TEST_PUBLIC_KEY_2!;

const sk1 = BigInt(sk1hex);
const sk2 = BigInt(sk2hex);

// Test message (simulating a userOpHash)
const msg = new Uint8Array(32);
msg[0] = 0xab; msg[1] = 0xcd;

console.log("=== BLS Debug ===\n");

// Method 1: bls.sign() — default "short signatures" (sig in G1, pk in G2)
// This is WRONG for our contract
try {
  const shortSig = bls.sign(msg, sk1);
  console.log("bls.sign() returns:", shortSig.length, "bytes (G1 signature)");
  console.log("This is SHORT scheme — WRONG for our contract\n");
} catch (e: any) {
  console.log("bls.sign() error:", e.message);
}

// Method 2: Manual G2 signing — multiply message point by private key
// This is what our contract expects
console.log("Method 2: Manual G2 signing (correct for our contract)");
const msgPoint = bls.G2.hashToCurve(msg, { DST: BLS_DST });
console.log("G2 hashToCurve: OK");

const sig1 = msgPoint.multiply(sk1);
const sig2 = msgPoint.multiply(sk2);
console.log("G2 signatures computed: OK");

// Aggregate: just add the G2 signature points
const aggSig = sig1.add(sig2);
console.log("Aggregated signature: OK");

// Verify manually: e(G1, aggSig) = e(aggPK, msgPoint)
// In pairing check form: e(G1, aggSig) * e(-aggPK, msgPoint) = 1
const pk1 = bls.G1.ProjectivePoint.BASE.multiply(sk1);
const pk2 = bls.G1.ProjectivePoint.BASE.multiply(sk2);
const aggPK = pk1.add(pk2);

// Encode to EIP-2537
function bigintToBytes48(n: bigint): Uint8Array {
  const hex = n.toString(16).padStart(96, "0");
  return hexToBytes(("0x" + hex) as `0x${string}`);
}

function encodeG2Point(point: typeof bls.G2.ProjectivePoint.BASE): string {
  const aff = point.toAffine();
  const result = new Uint8Array(256);
  result.set(bigintToBytes48(aff.x.c0), 16);
  result.set(bigintToBytes48(aff.x.c1), 80);
  result.set(bigintToBytes48(aff.y.c0), 144);
  result.set(bigintToBytes48(aff.y.c1), 208);
  return bytesToHex(result);
}

function encodeG1Point(point: typeof bls.G1.ProjectivePoint.BASE): string {
  const aff = point.toAffine();
  const result = new Uint8Array(128);
  result.set(bigintToBytes48(aff.x), 16);
  result.set(bigintToBytes48(aff.y), 80);
  return bytesToHex(result);
}

console.log("\nEncoded aggregated signature (G2, 256 bytes):");
console.log(encodeG2Point(aggSig).slice(0, 66) + "...");
console.log("\nEncoded message point (G2, 256 bytes):");
console.log(encodeG2Point(msgPoint).slice(0, 66) + "...");

// Verify the public keys match what's stored
const pk1Encoded = encodeG1Point(pk1);
const pk2Encoded = encodeG1Point(pk2);
console.log("\nPK1 match:", pk1Encoded.toLowerCase() === pk1hex.toLowerCase());
console.log("PK2 match:", pk2Encoded.toLowerCase() === pk2hex.toLowerCase());

// Now verify with noble/curves pairing
// e(G, sig) * e(-aggPK, msgPt) should equal 1
// We can verify using bls.verifyBatch or manual pairing
console.log("\nVerifying signature locally...");

// Use the pairing-based verification
const G1neg = aggPK.negate();
const e1 = bls.pairing(bls.G1.ProjectivePoint.BASE, aggSig);
const e2 = bls.pairing(G1neg, msgPoint);
const product = bls.fields.Fp12.mul(e1, e2);
const isOne = bls.fields.Fp12.eql(product, bls.fields.Fp12.ONE);
console.log("Pairing verification:", isOne ? "VALID" : "INVALID");

console.log("\n=== Summary ===");
console.log("The E2E script was using bls.sign() which produces G1 signatures (short scheme).");
console.log("Our contract expects G2 signatures (long scheme).");
console.log("Fix: Use msgPoint.multiply(sk) instead of bls.sign().");
