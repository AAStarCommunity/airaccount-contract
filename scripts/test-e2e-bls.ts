/**
 * test-e2e-bls.ts (M2)
 *
 * Full E2E: deploy account with BLS validator, register nodes,
 * build triple-signature UserOp (ECDSA×2 + BLS aggregate), submit via handleOps.
 *
 * Uses viem + @noble/curves (NOT ethers.js)
 *
 * Run via: bash test-e2e-bls.sh (from project root)
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  encodeFunctionData,
  toHex,
  hexToBytes,
  bytesToHex,
  keccak256,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { bls12_381 as bls } from "@noble/curves/bls12-381";

// ─── Config ──────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

const BLS_ALGORITHM_ADDR = (process.env.BLS_ALGORITHM_ADDRESS || "0xc2096E8D04beb3C337bb388F5352710d62De0287") as Address;
const VALIDATOR_ROUTER_ADDR = (process.env.VALIDATOR_ROUTER_ADDRESS || "0x730a162Ce3202b94cC5B74181B75b11eBB3045B1") as Address;
const FACTORY_ADDR = (process.env.FACTORY_ADDRESS || "0x5Ba18c50E0375Fb84d6D521366069FE9140Afe04") as Address;

const BLS_NODE_ID_1 = required("BLS_TEST_NODE_ID_1") as Hex;
const BLS_PRIVATE_KEY_1 = required("BLS_TEST_PRIVATE_KEY_1");
const BLS_PUBLIC_KEY_1 = required("BLS_TEST_PUBLIC_KEY_1") as Hex;
const BLS_NODE_ID_2 = required("BLS_TEST_NODE_ID_2") as Hex;
const BLS_PRIVATE_KEY_2 = required("BLS_TEST_PRIVATE_KEY_2");
const BLS_PUBLIC_KEY_2 = required("BLS_TEST_PUBLIC_KEY_2") as Hex;

const RECIPIENT = "0x000000000000000000000000000000000000dEaD" as Address;
const TRANSFER_AMOUNT = parseEther("0.001");
const DRY_RUN = !!process.env.DRY_RUN;

// ─── ABIs ────────────────────────────────────────────────────────────

const userOpTupleComponents = [
  { name: "sender", type: "address" },
  { name: "nonce", type: "uint256" },
  { name: "initCode", type: "bytes" },
  { name: "callData", type: "bytes" },
  { name: "accountGasLimits", type: "bytes32" },
  { name: "preVerificationGas", type: "uint256" },
  { name: "gasFees", type: "bytes32" },
  { name: "paymasterAndData", type: "bytes" },
  { name: "signature", type: "bytes" },
] as const;

const ENTRYPOINT_ABI = [
  { name: "handleOps", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "ops", type: "tuple[]", components: userOpTupleComponents }, { name: "beneficiary", type: "address" }], outputs: [] },
  { name: "getUserOpHash", type: "function", stateMutability: "view",
    inputs: [{ name: "userOp", type: "tuple", components: userOpTupleComponents }], outputs: [{ type: "bytes32" }] },
  { name: "depositTo", type: "function", stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getNonce", type: "function", stateMutability: "view",
    inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }] },
] as const;

const FACTORY_ABI = [
  { name: "createAccount", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "owner", type: "address" }, { name: "salt", type: "uint256" }], outputs: [{ name: "account", type: "address" }] },
  { name: "getAddress", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "salt", type: "uint256" }], outputs: [{ type: "address" }] },
] as const;

const ACCOUNT_ABI = [
  { name: "execute", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "dest", type: "address" }, { name: "value", type: "uint256" }, { name: "func", type: "bytes" }], outputs: [] },
  { name: "owner", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "setValidator", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_validator", type: "address" }], outputs: [] },
  { name: "validator", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const BLS_ALG_ABI = [
  { name: "registerPublicKey", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "nodeId", type: "bytes32" }, { name: "publicKey", type: "bytes" }], outputs: [] },
  { name: "isRegistered", type: "function", stateMutability: "view",
    inputs: [{ name: "nodeId", type: "bytes32" }], outputs: [{ type: "bool" }] },
  { name: "getRegisteredNodeCount", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { name: "validateAggregateSignature", type: "function", stateMutability: "view",
    inputs: [{ name: "nodeIds", type: "bytes32[]" }, { name: "signature", type: "bytes" }, { name: "messagePoint", type: "bytes" }],
    outputs: [{ type: "bool" }] },
] as const;

// ─── BLS Helpers ─────────────────────────────────────────────────────

const BLS_DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

function bigintToBytes48(n: bigint): Uint8Array {
  const hex = n.toString(16).padStart(96, "0");
  return hexToBytes(("0x" + hex) as Hex);
}

function encodeG2Point(point: typeof bls.G2.ProjectivePoint.BASE): Hex {
  const aff = point.toAffine();
  const result = new Uint8Array(256);
  result.set(bigintToBytes48(aff.x.c0), 16);
  result.set(bigintToBytes48(aff.x.c1), 80);
  result.set(bigintToBytes48(aff.y.c0), 144);
  result.set(bigintToBytes48(aff.y.c1), 208);
  return bytesToHex(result);
}

function blsPrivateKeyFromHex(hex: string): bigint {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  return BigInt("0x" + clean);
}

// ─── Main ────────────────────────────────────────────────────────────

async function main() {
  console.log("+==============================================+");
  console.log("|  AirAccount M2 BLS Triple-Sig E2E -- Sepolia |");
  console.log("+==============================================+\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: signer, chain: sepolia, transport: http(RPC_URL) });

  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Signer  : ${signer.address}`);
  console.log(`Balance : ${formatEther(balance)} ETH`);
  console.log(`Dry-run : ${DRY_RUN}\n`);

  if (balance < parseEther("0.01")) {
    console.error("ERROR: Need at least 0.01 ETH."); process.exit(1);
  }

  // ── Step 1: Register BLS nodes ──────────────────────────────────

  console.log("[ 1 ] Register BLS test nodes...");
  for (const [nodeId, pubKey, label] of [
    [BLS_NODE_ID_1, BLS_PUBLIC_KEY_1, "Node1"],
    [BLS_NODE_ID_2, BLS_PUBLIC_KEY_2, "Node2"],
  ] as [Hex, Hex, string][]) {
    const registered = await publicClient.readContract({
      address: BLS_ALGORITHM_ADDR, abi: BLS_ALG_ABI, functionName: "isRegistered", args: [nodeId],
    });
    if (registered) {
      console.log(`  ${label} already registered.`);
    } else {
      console.log(`  Registering ${label}...`);
      const hash = await walletClient.writeContract({
        address: BLS_ALGORITHM_ADDR, abi: BLS_ALG_ABI, functionName: "registerPublicKey", args: [nodeId, pubKey],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(`  ${label} registered: ${hash}`);
    }
  }
  const nodeCount = await publicClient.readContract({
    address: BLS_ALGORITHM_ADDR, abi: BLS_ALG_ABI, functionName: "getRegisteredNodeCount",
  });
  console.log(`  Total nodes: ${nodeCount}\n`);

  // ── Step 2: Create account ──────────────────────────────────────

  console.log("[ 2 ] Create account (salt=1)...");
  const salt = 1n;
  const predictedAddr = await publicClient.readContract({
    address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "getAddress", args: [signer.address, salt],
  });
  console.log(`  Predicted: ${predictedAddr}`);

  const code = await publicClient.getCode({ address: predictedAddr });
  if (code && code !== "0x") {
    console.log("  Already deployed.");
  } else {
    const hash = await walletClient.writeContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccount", args: [signer.address, salt],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Deployed: ${hash}`);
  }

  const accountAddr = predictedAddr;
  const accountOwner = await publicClient.readContract({
    address: accountAddr, abi: ACCOUNT_ABI, functionName: "owner",
  });
  if (accountOwner.toLowerCase() !== signer.address.toLowerCase()) {
    console.error("  Owner mismatch!"); process.exit(1);
  }
  console.log(`  Account: ${accountAddr}, Owner verified.\n`);

  // ── Step 3: Set validator ───────────────────────────────────────

  console.log("[ 3 ] Configure validator...");
  const currentValidator = await publicClient.readContract({
    address: accountAddr, abi: ACCOUNT_ABI, functionName: "validator",
  });
  if (currentValidator.toLowerCase() === VALIDATOR_ROUTER_ADDR.toLowerCase()) {
    console.log("  Already set.\n");
  } else {
    const hash = await walletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "setValidator", args: [VALIDATOR_ROUTER_ADDR],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Set: ${hash}\n`);
  }

  // ── Step 4: Fund ────────────────────────────────────────────────

  console.log("[ 4 ] Fund account...");
  const deposit = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "balanceOf", args: [accountAddr],
  });
  console.log(`  EP deposit: ${formatEther(deposit)} ETH`);

  if (deposit < parseEther("0.005") && !DRY_RUN) {
    const hash = await walletClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "depositTo", args: [accountAddr], value: parseEther("0.01"),
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Deposit: ${hash}`);
  }

  const accountBal = await publicClient.getBalance({ address: accountAddr });
  if (accountBal < TRANSFER_AMOUNT && !DRY_RUN) {
    const hash = await walletClient.sendTransaction({ to: accountAddr, value: parseEther("0.005") });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Funded: ${hash}`);
  }
  console.log("");

  // ── Step 5: Build UserOp ────────────────────────────────────────

  console.log("[ 5 ] Build UserOp...");
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce", args: [accountAddr, 0n],
  });
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI, functionName: "execute", args: [RECIPIENT, TRANSFER_AMOUNT, "0x"],
  });
  const feeData = await publicClient.estimateFeesPerGas();
  const maxPri = feeData.maxPriorityFeePerGas ?? 2_000_000_000n;
  const maxFee = feeData.maxFeePerGas ?? 20_000_000_000n;
  const verificationGasLimit = 800_000n;
  const callGasLimit = 200_000n;

  const userOp = {
    sender: accountAddr,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: toHex((verificationGasLimit << 128n) | callGasLimit, { size: 32 }) as Hex,
    preVerificationGas: 80_000n,
    gasFees: toHex((maxPri << 128n) | maxFee, { size: 32 }) as Hex,
    paymasterAndData: "0x" as Hex,
    signature: "0x" as Hex,
  };
  console.log(`  Nonce: ${nonce}`);

  // ── Step 6: Triple signature ────────────────────────────────────

  console.log("\n[ 6 ] Build triple signature (ECDSA×2 + BLS)...");
  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getUserOpHash", args: [userOp],
  });
  console.log(`  userOpHash: ${userOpHash}`);

  // BLS signing — use "long signature" scheme: G2 signatures, G1 public keys
  // bls.sign() uses "short" (G1 sig) which is WRONG for our contract.
  // Our contract expects G2 signatures: multiply message point by private key.
  const msgBytes = hexToBytes(userOpHash);
  const messagePoint = bls.G2.hashToCurve(msgBytes, { DST: BLS_DST });

  const sk1 = blsPrivateKeyFromHex(BLS_PRIVATE_KEY_1);
  const sk2 = blsPrivateKeyFromHex(BLS_PRIVATE_KEY_2);
  const sig1 = messagePoint.multiply(sk1);
  const sig2 = messagePoint.multiply(sk2);
  const aggSigPoint = sig1.add(sig2);

  const msgPointEncoded = encodeG2Point(messagePoint);
  const aggSigEncoded = encodeG2Point(aggSigPoint);

  console.log(`  BLS aggregate: ${aggSigEncoded.slice(0, 42)}...`);
  console.log(`  MessagePoint: ${msgPointEncoded.slice(0, 42)}...`);

  // Dry-run BLS verification
  console.log("  Dry-run BLS verification on-chain...");
  try {
    const blsValid = await publicClient.readContract({
      address: BLS_ALGORITHM_ADDR, abi: BLS_ALG_ABI, functionName: "validateAggregateSignature",
      args: [[BLS_NODE_ID_1, BLS_NODE_ID_2], aggSigEncoded, msgPointEncoded],
    });
    console.log(`  BLS result: ${blsValid ? "VALID" : "INVALID"}`);
    if (!blsValid) { console.error("  BLS verification failed!"); process.exit(1); }
  } catch (e: any) {
    console.error(`  BLS dry-run failed (EIP-2537 precompile may not be available): ${e.message?.slice(0, 150)}`);
    console.log("  Continuing with signature construction...\n");
  }

  // M2-format triple signature: algId(1) + nodeIdsLength(32) + nodeIds(2×32) + blsSig(256) + messagePoint(256)
  // The M2 validator at 0x730a162Ce3202b94cC5B74181B75b11eBB3045B1 expects exactly 609 bytes (no aaSig/mpSig).
  // M5.2+ added aaSig+mpSig binding but this test uses the deployed M2 account + validator.
  const tripleSignature = (
    "0x01" +
    toHex(2n, { size: 32 }).slice(2) +
    BLS_NODE_ID_1.slice(2) +
    BLS_NODE_ID_2.slice(2) +
    aggSigEncoded.slice(2) +
    msgPointEncoded.slice(2)
  ) as Hex;

  const sigLen = (tripleSignature.length - 2) / 2;
  console.log(`  Signature: ${sigLen} bytes (expected: ${1 + 32 + 64 + 256 + 256} = 609)\n`);

  const signedUserOp = { ...userOp, signature: tripleSignature };

  if (DRY_RUN) {
    console.log("[ 7 ] DRY RUN -- done.");
    console.log("  Triple signature built OK.");
    return;
  }

  // ── Step 7: Submit handleOps ────────────────────────────────────

  console.log("[ 7 ] Submit handleOps()...");
  try {
    const gasEstimate = await publicClient.estimateContractGas({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
      args: [[signedUserOp], signer.address], account: signer.address,
    });
    console.log(`  Gas estimate: ${gasEstimate}`);

    const hash = await walletClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
      args: [[signedUserOp], signer.address], gas: (gasEstimate * 13n) / 10n,
    });
    console.log(`  Tx: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    console.log("\n+==============================================+");
    console.log("|  BLS Triple-Sig UserOp executed!             |");
    console.log("+==============================================+");
    console.log(`  Tx      : ${receipt.transactionHash}`);
    console.log(`  Block   : ${receipt.blockNumber}`);
    console.log(`  Gas     : ${receipt.gasUsed}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${receipt.transactionHash}\n`);
  } catch (e: any) {
    console.error(`  handleOps failed: ${e.message?.slice(0, 300)}`);
    console.log("\n  NOTE: EIP-2537 BLS precompiles are active on Sepolia (Pectra/Prague fork).");
    console.log("  If validation fails, check BLS node registration and signature format.");
    process.exit(1);
  }

  console.log("Done.\n");
}

main().catch((e) => { console.error("Fatal:", e); process.exit(1); });
