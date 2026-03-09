/**
 * test-e2e-bls.ts
 *
 * Complete E2E: real ERC-4337 UserOp with 2-node BLS aggregate signature.
 * All config loaded from environment (sourced from .env.sepolia by test-e2e-bls.sh).
 *
 * Run via:  bash test-e2e-bls.sh   (from project root)
 *
 * Flow:
 *   1. Verify both test BLS nodes are registered on-chain
 *   2. Fund EntryPoint deposit if needed
 *   3. Build UserOp: AA account → execute(ANNI_EOA, 0.001 ETH, "")
 *   4. Compute userOpHash and messagePoint = G2.hashToCurve(userOpHash)
 *   5. BLS-sign messagePoint with node 1 + node 2, aggregate signatures
 *   6. ECDSA-sign userOpHash (aaSignature) and keccak256(messagePoint) (messagePointSignature)
 *   7. Pack full 738-byte signature (2 nodes)
 *   8. Dry-run BLS verification on-chain
 *   9. Submit handleOps() → verify beneficiary balance increased
 */

import { ethers } from "ethers";
import { bls12_381 } from "@noble/curves/bls12-381.js";

// ─── BLS helpers (from src/utils/bls.util.ts) ────────────────────────────────

const BLS_DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";
const sigs = bls12_381.longSignatures;

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  const b = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2)
    b[i / 2] = parseInt(clean.slice(i, i + 2), 16);
  return b;
}

/** G2 point → EIP-2537 format: 256 bytes */
function encodeG2Point(point: any): Uint8Array {
  const r = new Uint8Array(256);
  const a = point.toAffine();
  const tb = (h: string) => hexToBytes(h.toString(16).padStart(96, "0"));
  r.set(tb(a.x.c0), 16); r.set(tb(a.x.c1), 80);
  r.set(tb(a.y.c0), 144); r.set(tb(a.y.c1), 208);
  return r;
}

// ─── Config from environment (.env.sepolia via test-e2e-bls.sh) ──────────────

const required = (k: string) => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const RPC_URL        = required("RPC_URL");
const SIGNER_PK      = required("PRIVATE_KEY");
const VALIDATOR_ADDR = required("VALIDATOR_CONTRACT_ADDRESS");
const AA_ACCOUNT     = required("AASTAR_AA_ACCOUNT_ADDRESS");
const ENTRYPOINT     = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const BENEFICIARY    = required("ADDRESS_ANNI_EOA");
const DRY_RUN        = !!process.env.DRY_RUN;

const NODE_ID_1 = required("BLS_TEST_NODE_ID_1");
const SK_1      = hexToBytes(required("BLS_TEST_PRIVATE_KEY_1"));
const NODE_ID_2 = required("BLS_TEST_NODE_ID_2");
const SK_2      = hexToBytes(required("BLS_TEST_PRIVATE_KEY_2"));

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const VALIDATOR_ABI = [
  "function isRegistered(bytes32) view returns (bool)",
  "function getRegisteredNodeCount() view returns (uint256)",
  "function validateAggregateSignature(bytes32[],bytes,bytes) view returns (bool)",
];

const ENTRYPOINT_ABI = [
  "function handleOps(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[],address payable) external",
  "function getUserOpHash(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)) view returns (bytes32)",
  "function depositTo(address) payable",
  "function balanceOf(address) view returns (uint256)",
  "function getNonce(address,uint192) view returns (uint256)",
];

const ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("╔═══════════════════════════════════════════╗");
  console.log("║  YetAnotherAA E2E BLS Test — Sepolia      ║");
  console.log("╚═══════════════════════════════════════════╝\n");

  const provider   = new ethers.JsonRpcProvider(RPC_URL);
  const wallet     = new ethers.Wallet(SIGNER_PK, provider);
  const validator  = new ethers.Contract(VALIDATOR_ADDR, VALIDATOR_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT, ENTRYPOINT_ABI, wallet);

  console.log(`Signer/Bundler : ${wallet.address}`);
  console.log(`AA Account     : ${AA_ACCOUNT}`);
  console.log(`Beneficiary    : ${BENEFICIARY}`);
  console.log(`Dry-run        : ${DRY_RUN}\n`);

  // ── Step 1: Verify nodes registered ────────────────────────────────────────
  console.log("[ 1 ] Verifying BLS nodes on-chain...");
  for (const [id, label] of [[NODE_ID_1, "Node 1"], [NODE_ID_2, "Node 2"]]) {
    const ok = await validator.isRegistered(id);
    if (!ok) { console.error(`  ✗ ${label} not registered: ${id}`); process.exit(1); }
    console.log(`  ✓ ${label}: ${id}`);
  }
  const count = await validator.getRegisteredNodeCount();
  console.log(`  Total registered: ${count}\n`);

  // ── Step 2: Ensure EntryPoint deposit ──────────────────────────────────────
  console.log("[ 2 ] EntryPoint deposit...");
  const deposit    = await entryPoint.balanceOf(AA_ACCOUNT);
  const minDeposit = ethers.parseEther("0.005");
  console.log(`  Current : ${ethers.formatEther(deposit)} ETH`);

  if (deposit < minDeposit && !DRY_RUN) {
    const top = ethers.parseEther("0.01");
    const tx  = await entryPoint.depositTo(AA_ACCOUNT, { value: top });
    const rc  = await tx.wait();
    console.log(`  Topped up 0.01 ETH — tx: ${rc.hash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${rc.hash}`);
  } else if (deposit < minDeposit) {
    console.log("  (dry-run: skipping deposit)");
  } else {
    console.log("  Sufficient ✓");
  }

  const balBefore = await provider.getBalance(BENEFICIARY);
  console.log(`\n  Beneficiary balance before: ${ethers.formatEther(balBefore)} ETH\n`);

  // ── Step 3: Build UserOp ───────────────────────────────────────────────────
  console.log("[ 3 ] Build UserOp (send 0.001 ETH to beneficiary)...");
  const nonce    = await entryPoint.getNonce(AA_ACCOUNT, 0);
  const callData = new ethers.Interface(ACCOUNT_ABI).encodeFunctionData("execute", [
    BENEFICIARY, ethers.parseEther("0.001"), "0x",
  ]);
  const feeData  = await provider.getFeeData();
  const maxPri   = feeData.maxPriorityFeePerGas ?? ethers.parseUnits("1", "gwei");
  const maxFee   = feeData.maxFeePerGas         ?? ethers.parseUnits("10", "gwei");

  const userOpTemplate = {
    sender:             AA_ACCOUNT,
    nonce:              nonce,
    initCode:           "0x",
    callData:           callData,
    accountGasLimits:   ethers.toBeHex((600_000n << 128n) | 100_000n, 32),
    preVerificationGas: 50_000n,
    gasFees:            ethers.toBeHex((maxPri << 128n) | maxFee, 32),
    paymasterAndData:   "0x",
    signature:          "0x",
  };
  console.log(`  Nonce: ${nonce}\n`);

  // ── Step 4: userOpHash & messagePoint ─────────────────────────────────────
  console.log("[ 4 ] Compute userOpHash and messagePoint...");
  const userOpHash   = await entryPoint.getUserOpHash(userOpTemplate);
  const msgCurve     = await bls12_381.G2.hashToCurve(ethers.getBytes(userOpHash), { DST: BLS_DST });
  const msgPointBytes = encodeG2Point(msgCurve); // 256 bytes
  console.log(`  userOpHash   : ${userOpHash}`);
  console.log(`  messagePoint : ${("0x" + Buffer.from(msgPointBytes).toString("hex")).slice(0, 34)}...\n`);

  // ── Step 5: BLS aggregate signature ──────────────────────────────────────
  console.log("[ 5 ] BLS-sign with node 1 + node 2, then aggregate...");
  const sig1Point = await sigs.sign(msgCurve as any, SK_1);
  const sig2Point = await sigs.sign(msgCurve as any, SK_2);
  const aggSig    = sigs.aggregateSignatures([sig1Point, sig2Point]);
  const aggSigBytes = encodeG2Point(aggSig); // 256 bytes
  console.log(`  sig1 ✓  sig2 ✓  aggregated ✓\n`);

  // ── Step 6: Dry-run BLS verification ─────────────────────────────────────
  console.log("[ 6 ] BLS dry-run: validator.validateAggregateSignature()...");
  const blsValid = await validator.validateAggregateSignature(
    [NODE_ID_1, NODE_ID_2], aggSigBytes, msgPointBytes
  );
  console.log(`  Result: ${blsValid ? "✅ VALID" : "❌ INVALID"}`);
  if (!blsValid) { console.error("  BLS verification failed — aborting."); process.exit(1); }

  // ── Step 7: Two ECDSA signatures ─────────────────────────────────────────
  console.log("\n[ 7 ] Two ECDSA signatures from account signer...");
  // aaSignature: signs userOpHash — proves owner authorised this UserOp
  const aaSig  = await wallet.signMessage(ethers.getBytes(userOpHash));
  // messagePointSignature: signs keccak256(messagePoint) — binds messagePoint to owner
  const mpHash = ethers.keccak256(msgPointBytes);
  const mpSig  = await wallet.signMessage(ethers.getBytes(mpHash));
  console.log(`  aaSignature           : ${aaSig.slice(0, 22)}...`);
  console.log(`  messagePointSignature : ${mpSig.slice(0, 22)}...\n`);

  // ── Step 8: Pack full signature ───────────────────────────────────────────
  // Layout: [nodeCount(32)][nodeId1(32)][nodeId2(32)][blsSig(256)][msgPoint(256)][aaSig(65)][mpSig(65)]
  console.log("[ 8 ] Pack signature...");
  const fullSig = ethers.solidityPacked(
    ["uint256", "bytes32", "bytes32", "bytes", "bytes", "bytes", "bytes"],
    [2, NODE_ID_1, NODE_ID_2, aggSigBytes, msgPointBytes, aaSig, mpSig]
  );
  const sigLen = ethers.getBytes(fullSig).length;
  console.log(`  Length: ${sigLen} bytes  (expected: ${32 + 2*32 + 256 + 256 + 65 + 65} = 738)\n`);

  if (DRY_RUN) {
    console.log("[ 9 ] DRY RUN — skipping submission.");
    console.log("  Signature ready. Set DRY_RUN='' to submit.\n");
    return;
  }

  // ── Step 9: Submit handleOps ──────────────────────────────────────────────
  console.log("[ 9 ] Submit UserOp via EntryPoint.handleOps()...");
  const finalUserOp = { ...userOpTemplate, signature: fullSig };

  let gasEstimate: bigint;
  try {
    gasEstimate = await entryPoint.handleOps.estimateGas([finalUserOp], wallet.address);
    console.log(`  Gas estimate: ${gasEstimate}`);
  } catch (e: any) {
    console.error(`  Gas estimation failed: ${e.message}`);
    // Print simulation error
    try {
      await provider.call({ to: ENTRYPOINT, data: entryPoint.interface.encodeFunctionData("handleOps", [[finalUserOp], wallet.address]) });
    } catch (se: any) { console.error(`  Simulate: ${se.message}`); }
    process.exit(1);
  }

  const tx      = await entryPoint.handleOps([finalUserOp], wallet.address, { gasLimit: gasEstimate * 12n / 10n });
  const receipt = await tx.wait();

  console.log("\n╔═══════════════════════════════════════════╗");
  console.log("║  ✅  UserOp executed successfully!         ║");
  console.log("╚═══════════════════════════════════════════╝");
  console.log(`  Tx hash  : ${receipt.hash}`);
  console.log(`  Block    : ${receipt.blockNumber}`);
  console.log(`  Gas used : ${receipt.gasUsed}`);
  console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${receipt.hash}\n`);

  const balAfter = await provider.getBalance(BENEFICIARY);
  const diff     = balAfter - balBefore;
  console.log(`  Beneficiary received: ${ethers.formatEther(diff)} ETH ${diff > 0n ? "✅" : "❌"}`);
}

main().catch(e => { console.error("Fatal:", e); process.exit(1); });
