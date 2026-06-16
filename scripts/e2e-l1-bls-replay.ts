/**
 * L1 — BLS aggregate replay binding (#45), proven against the DEPLOYED beta.2 BLS algorithm
 * on Sepolia (real EIP-2537). A real 2-node aggregate signed for userOpHash_A is ACCEPTED for A
 * (validate→0) but REJECTED when submitted for a different userOpHash_B (validate→1), because the
 * contract recomputes messagePoint = hashToG2(hash) on-chain and drops any caller-supplied point.
 *
 * Run: pnpm tsx scripts/e2e-l1-bls-replay.ts
 */
import { createPublicClient, http, encodePacked, concat, toHex, type Address, type Hex } from "viem";
import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = process.env.SEPOLIA_RPC_URL as string;
const BLS_ALG = (process.env.AIRACCOUNT_V018_BLS_ALGORITHM ?? "0xA9EE4f8A59fCE1B56f9da8e153c3f5F38D3C59ED") as Address;
const BLS_DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

const NODE1 = process.env.BLS_TEST_NODE_ID_1 as Hex;
const NODE2 = process.env.BLS_TEST_NODE_ID_2 as Hex;
const SK1 = BigInt("0x" + (process.env.BLS_TEST_PRIVATE_KEY_1 as string).replace(/^0x/, ""));
const SK2 = BigInt("0x" + (process.env.BLS_TEST_PRIVATE_KEY_2 as string).replace(/^0x/, ""));

const HASH_A = "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex;
const HASH_B = "0x2222222222222222222222222222222222222222222222222222222222222222" as Hex;

const pub = createPublicClient({ chain: undefined, transport: http(RPC_URL) });

// 256-byte EIP-2537 G2 encoding: x.c0@16, x.c1@80, y.c0@144, y.c1@208 (matches contract + node).
function encodeG2Point(point: any): Hex {
  const aff = point.toAffine();
  const pad = (v: bigint) => toHex(v, { size: 64 }).slice(2);
  return ("0x" + pad(aff.x.c0) + pad(aff.x.c1) + pad(aff.y.c0) + pad(aff.y.c1)) as Hex;
}

function aggregateFor(hashHex: Hex): Hex {
  const msg = Buffer.from(hashHex.slice(2), "hex");
  const mp = bls.G2.hashToCurve(msg, { DST: BLS_DST }) as any;
  const sig1 = mp.multiply(SK1);
  const sig2 = mp.multiply(SK2);
  const agg = sig1.add(sig2);
  return encodeG2Point(agg);
}

const VALIDATE_ABI = [{
  name: "validate", type: "function", stateMutability: "view",
  inputs: [{ name: "hash", type: "bytes32" }, { name: "signature", type: "bytes" }],
  outputs: [{ type: "uint256" }],
}] as const;

async function validate(hash: Hex, sig: Hex): Promise<bigint> {
  return pub.readContract({ address: BLS_ALG, abi: VALIDATE_ABI, functionName: "validate", args: [hash, sig] }) as Promise<bigint>;
}

async function main() {
  console.log(`L1 — BLS replay binding (#45) vs deployed Sepolia BLS algo ${BLS_ALG}`);
  // aggregate signed for HASH_A; sig wire = [nodeId1][nodeId2][aggSig(256)]
  const aggA = aggregateFor(HASH_A);
  const sig = concat([NODE1, NODE2, aggA]);

  const rA = await validate(HASH_A, sig);
  console.log(`validate(HASH_A, agg_for_A) = ${rA}  (expect 0 = accept)`);
  const rB = await validate(HASH_B, sig);
  console.log(`validate(HASH_B, agg_for_A) = ${rB}  (expect 1 = REJECT — replay defeated, #45)`);

  if (rA === 0n && rB === 1n) {
    console.log("\nPASS: L1 — same aggregate accepted for its own userOpHash, REJECTED on replay to a different hash.");
    console.log("(on-chain proof against the deployed beta.2 contract + real EIP-2537; messagePoint recomputed from hash.)");
  } else {
    console.error(`\nFAIL: expected (0,1) got (${rA},${rB}).`);
    process.exit(1);
  }
}
main().catch((e) => { console.error("Fatal:", e?.shortMessage ?? e?.message ?? e); process.exit(1); });
