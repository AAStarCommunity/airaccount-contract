/**
 * test-tiered-e2e.ts (M3)
 *
 * Comprehensive E2E test for ALL THREE signature tiers on Sepolia.
 * Deploys a fully configured M3 account and tests each tier:
 *   - Tier 1: Small transfer with ECDSA only
 *   - Tier 2: Medium transfer with P256 + BLS (algId 0x04)
 *   - Tier 3: Large transfer with P256 + BLS + Guardian ECDSA (algId 0x05)
 *   - Negative: Medium with only ECDSA → InsufficientTier
 *   - Negative: Large with only P256+BLS → InsufficientTier
 *
 * Uses viem + @noble/curves (NOT ethers.js)
 *
 * Run: npx tsx scripts/test-tiered-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  encodeFunctionData,
  encodeAbiParameters,
  toHex,
  hexToBytes,
  bytesToHex,
  keccak256,
  concat,
  pad,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { p256 } from "@noble/curves/p256";
import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { randomBytes } from "crypto";

// ─── Load Environment ─────────────────────────────────────────────────

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) {
    console.error(`Missing env: ${k}`);
    process.exit(1);
  }
  return v;
};

// ─── Config ───────────────────────────────────────────────────────────

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const RPC_URL =
  process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

const FACTORY_ADDR = "0x914db0a849f55e68a726c72fd02b7114b1176d88" as Address;
const BLS_ALGORITHM_ADDR = "0xc2096E8D04beb3C337bb388F5352710d62De0287" as Address;
const VALIDATOR_ROUTER_ADDR = "0x730a162Ce3202b94cC5B74181B75b11eBB3045B1" as Address;

const PRIVATE_KEY_ANNI = required("PRIVATE_KEY_ANNI") as Hex;
const PRIVATE_KEY_BOB = required("PRIVATE_KEY_BOB") as Hex;
const PRIVATE_KEY_CHARLIE = required("PRIVATE_KEY_CHARLIE") as Hex;

const BLS_NODE_ID_1 = required("BLS_TEST_NODE_ID_1") as Hex;
const BLS_PRIVATE_KEY_1 = required("BLS_TEST_PRIVATE_KEY_1");
const BLS_PUBLIC_KEY_1 = required("BLS_TEST_PUBLIC_KEY_1") as Hex;
const BLS_NODE_ID_2 = required("BLS_TEST_NODE_ID_2") as Hex;
const BLS_PRIVATE_KEY_2 = required("BLS_TEST_PRIVATE_KEY_2");
const BLS_PUBLIC_KEY_2 = required("BLS_TEST_PUBLIC_KEY_2") as Hex;

const RECIPIENT = "0x000000000000000000000000000000000000dEaD" as Address;
const SALT = 400n;

// Tier limits
const TIER1_LIMIT = parseEther("0.01"); // ≤ 0.01 ETH: ECDSA only
const TIER2_LIMIT = parseEther("0.1"); // ≤ 0.1 ETH: P256 + BLS

// Transfer amounts per tier
const TIER1_AMOUNT = parseEther("0.005"); // 0.005 ETH (under tier1)
const TIER2_AMOUNT = parseEther("0.05"); // 0.05 ETH (above tier1, under tier2)
const TIER3_AMOUNT = parseEther("0.15"); // 0.15 ETH (above tier2)

// ─── ABIs ─────────────────────────────────────────────────────────────

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
  {
    name: "handleOps",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ops", type: "tuple[]", components: userOpTupleComponents },
      { name: "beneficiary", type: "address" },
    ],
    outputs: [],
  },
  {
    name: "getUserOpHash",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "userOp", type: "tuple", components: userOpTupleComponents }],
    outputs: [{ type: "bytes32" }],
  },
  {
    name: "depositTo",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }],
    outputs: [],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "getNonce",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "sender", type: "address" },
      { name: "key", type: "uint192" },
    ],
    outputs: [{ type: "uint256" }],
  },
] as const;

// InitConfig struct: (address[3] guardians, uint256 dailyLimit, uint8[] approvedAlgIds)
const FACTORY_ABI = [
  {
    name: "createAccount",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "guardians", type: "address[3]" },
          { name: "dailyLimit", type: "uint256" },
          { name: "approvedAlgIds", type: "uint8[]" },
        ],
      },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "getAddress",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "guardians", type: "address[3]" },
          { name: "dailyLimit", type: "uint256" },
          { name: "approvedAlgIds", type: "uint8[]" },
        ],
      },
    ],
    outputs: [{ type: "address" }],
  },
] as const;

const ACCOUNT_ABI = [
  {
    name: "execute",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dest", type: "address" },
      { name: "value", type: "uint256" },
      { name: "func", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "owner",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    name: "setValidator",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_validator", type: "address" }],
    outputs: [],
  },
  {
    name: "setP256Key",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_x", type: "bytes32" },
      { name: "_y", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    name: "setTierLimits",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_tier1", type: "uint256" },
      { name: "_tier2", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "validator",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    name: "p256KeyX",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  {
    name: "tier1Limit",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "tier2Limit",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "guardianCount",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
] as const;

const BLS_ALG_ABI = [
  {
    name: "registerPublicKey",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "nodeId", type: "bytes32" },
      { name: "publicKey", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "isRegistered",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "nodeId", type: "bytes32" }],
    outputs: [{ type: "bool" }],
  },
] as const;

// ─── BLS Helpers ──────────────────────────────────────────────────────

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

// ─── UserOp Helpers ───────────────────────────────────────────────────

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

// ─── Main ─────────────────────────────────────────────────────────────

async function main() {
  console.log("+=======================================================+");
  console.log("|  AirAccount M3 Tiered Verification E2E -- Sepolia      |");
  console.log("|  Tests: Tier 1 (ECDSA), Tier 2 (P256+BLS),            |");
  console.log("|         Tier 3 (P256+BLS+Guardian), Negative cases     |");
  console.log("+=======================================================+\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  const anniSigner = privateKeyToAccount(PRIVATE_KEY_ANNI);
  const bobSigner = privateKeyToAccount(PRIVATE_KEY_BOB);
  const charlieSigner = privateKeyToAccount(PRIVATE_KEY_CHARLIE);

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({
    account: signer,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const balance = await publicClient.getBalance({ address: signer.address });
  console.log(`Signer     : ${signer.address}`);
  console.log(`Balance    : ${formatEther(balance)} ETH`);
  console.log(`Guardian 1 : ${anniSigner.address} (ANNI)`);
  console.log(`Guardian 2 : ${bobSigner.address} (BOB)`);
  console.log(`Guardian 3 : ${charlieSigner.address} (CHARLIE)\n`);

  if (balance < parseEther("0.5")) {
    console.error("ERROR: Need at least 0.5 ETH for tiered E2E tests.");
    process.exit(1);
  }

  // ── Generate P256 keypair ───────────────────────────────────────────

  console.log("[ 0 ] Generate P256 keypair...");
  const p256PrivKey = randomBytes(32);
  const p256PubKeyUncompressed = p256.getPublicKey(p256PrivKey, false); // 65 bytes (0x04 + x + y)
  const p256X = bytesToHex(p256PubKeyUncompressed.slice(1, 33)) as Hex;
  const p256Y = bytesToHex(p256PubKeyUncompressed.slice(33, 65)) as Hex;
  console.log(`  P256 X: ${p256X}`);
  console.log(`  P256 Y: ${p256Y}\n`);

  // ── Step 1: Register BLS nodes ──────────────────────────────────────

  console.log("[ 1 ] Register BLS test nodes...");
  for (const [nodeId, pubKey, label] of [
    [BLS_NODE_ID_1, BLS_PUBLIC_KEY_1, "Node1"],
    [BLS_NODE_ID_2, BLS_PUBLIC_KEY_2, "Node2"],
  ] as [Hex, Hex, string][]) {
    const registered = await publicClient.readContract({
      address: BLS_ALGORITHM_ADDR,
      abi: BLS_ALG_ABI,
      functionName: "isRegistered",
      args: [nodeId],
    });
    if (registered) {
      console.log(`  ${label} already registered.`);
    } else {
      console.log(`  Registering ${label}...`);
      const hash = await walletClient.writeContract({
        address: BLS_ALGORITHM_ADDR,
        abi: BLS_ALG_ABI,
        functionName: "registerPublicKey",
        args: [nodeId, pubKey],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(`  ${label} registered: ${hash}`);
    }
  }
  console.log("");

  // ── Step 2: Deploy account via M3 Factory ───────────────────────────

  console.log("[ 2 ] Deploy account via M3 Factory (salt=100)...");

  const initConfig = {
    guardians: [anniSigner.address, bobSigner.address, charlieSigner.address] as readonly [
      Address,
      Address,
      Address,
    ],
    dailyLimit: parseEther("10"), // 10 ETH daily limit
    approvedAlgIds: [1, 2, 3, 4, 5], // All algorithms: BLS, ECDSA, P256, Cumulative T2, T3
  };

  const predictedAddr = await publicClient.readContract({
    address: FACTORY_ADDR,
    abi: FACTORY_ABI,
    functionName: "getAddress",
    args: [signer.address, SALT, initConfig],
  });
  console.log(`  Predicted: ${predictedAddr}`);

  const code = await publicClient.getCode({ address: predictedAddr });
  if (code && code !== "0x") {
    console.log("  Already deployed.");
  } else {
    const hash = await walletClient.writeContract({
      address: FACTORY_ADDR,
      abi: FACTORY_ABI,
      functionName: "createAccount",
      args: [signer.address, SALT, initConfig],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Deployed: ${hash}`);
    console.log(`  Gas: ${receipt.gasUsed}`);
  }

  const accountAddr = predictedAddr;

  // Verify owner
  const accountOwner = await publicClient.readContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "owner",
  });
  if (accountOwner.toLowerCase() !== signer.address.toLowerCase()) {
    console.error("  Owner mismatch!");
    process.exit(1);
  }
  console.log(`  Account: ${accountAddr}, Owner verified.`);

  // Verify guardians
  const gCount = await publicClient.readContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "guardianCount",
  });
  console.log(`  Guardians: ${gCount}\n`);

  // ── Step 3: Configure validator router ──────────────────────────────

  console.log("[ 3 ] Set validator router...");
  const currentValidator = await publicClient.readContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "validator",
  });
  if (currentValidator.toLowerCase() === VALIDATOR_ROUTER_ADDR.toLowerCase()) {
    console.log("  Already set.\n");
  } else {
    const hash = await walletClient.writeContract({
      address: accountAddr,
      abi: ACCOUNT_ABI,
      functionName: "setValidator",
      args: [VALIDATOR_ROUTER_ADDR],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Set: ${hash}\n`);
  }

  // ── Step 4: Set P256 key ────────────────────────────────────────────

  console.log("[ 4 ] Set P256 key on account...");
  const currentP256X = await publicClient.readContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "p256KeyX",
  });
  // Always set the new key (since we generate a fresh one each run)
  const hash4 = await walletClient.writeContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "setP256Key",
    args: [p256X as Hex, p256Y as Hex],
  });
  await publicClient.waitForTransactionReceipt({ hash: hash4 });
  console.log(`  Set P256 key: ${hash4}\n`);

  // ── Step 5: Set tier limits ─────────────────────────────────────────

  console.log("[ 5 ] Set tier limits...");
  console.log(`  Tier 1 limit: ${formatEther(TIER1_LIMIT)} ETH`);
  console.log(`  Tier 2 limit: ${formatEther(TIER2_LIMIT)} ETH`);
  const hash5 = await walletClient.writeContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "setTierLimits",
    args: [TIER1_LIMIT, TIER2_LIMIT],
  });
  await publicClient.waitForTransactionReceipt({ hash: hash5 });
  console.log(`  Set: ${hash5}\n`);

  // ── Step 6: Fund account + EntryPoint deposit ───────────────────────

  console.log("[ 6 ] Fund account...");
  // Fund account with enough ETH for all tests
  const totalNeeded = TIER1_AMOUNT + TIER2_AMOUNT + TIER3_AMOUNT + parseEther("0.05"); // buffer
  const accountBal = await publicClient.getBalance({ address: accountAddr });
  if (accountBal < totalNeeded) {
    const fundAmount = totalNeeded - accountBal + parseEther("0.01");
    const hash = await walletClient.sendTransaction({
      to: accountAddr,
      value: fundAmount,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Funded with ${formatEther(fundAmount)} ETH: ${hash}`);
  } else {
    console.log(`  Account balance sufficient: ${formatEther(accountBal)} ETH`);
  }

  // EntryPoint deposit
  const deposit = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "balanceOf",
    args: [accountAddr],
  });
  if (deposit < parseEther("0.05")) {
    const hash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "depositTo",
      args: [accountAddr],
      value: parseEther("0.1"),
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  EP deposit: ${hash}`);
  } else {
    console.log(`  EP deposit sufficient: ${formatEther(deposit)} ETH`);
  }
  console.log("");

  // ────────────────────────────────────────────────────────────────────
  // Helper: build a UserOp for a given transfer amount
  // ────────────────────────────────────────────────────────────────────

  async function buildUserOp(amount: bigint) {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "getNonce",
      args: [accountAddr, 0n],
    });

    const callData = encodeFunctionData({
      abi: ACCOUNT_ABI,
      functionName: "execute",
      args: [RECIPIENT, amount, "0x"],
    });

    const feeData = await publicClient.estimateFeesPerGas();
    const maxPri = feeData.maxPriorityFeePerGas ?? 2_000_000_000n;
    const maxFee = feeData.maxFeePerGas ?? 20_000_000_000n;

    return {
      sender: accountAddr,
      nonce,
      initCode: "0x" as Hex,
      callData,
      accountGasLimits: packUint128(800_000n, 200_000n),
      preVerificationGas: 80_000n,
      gasFees: packUint128(maxPri, maxFee),
      paymasterAndData: "0x" as Hex,
      signature: "0x" as Hex,
    };
  }

  async function getUserOpHash(userOp: any): Promise<Hex> {
    return (await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "getUserOpHash",
      args: [userOp],
    })) as Hex;
  }

  // ────────────────────────────────────────────────────────────────────
  // Helper: BLS signing (aggregate G2 signatures)
  // ────────────────────────────────────────────────────────────────────

  function buildBlsComponents(userOpHash: Hex) {
    const msgBytes = hexToBytes(userOpHash);
    const messagePoint = bls.G2.hashToCurve(msgBytes, { DST: BLS_DST });

    const sk1 = blsPrivateKeyFromHex(BLS_PRIVATE_KEY_1);
    const sk2 = blsPrivateKeyFromHex(BLS_PRIVATE_KEY_2);
    const sig1 = messagePoint.multiply(sk1);
    const sig2 = messagePoint.multiply(sk2);
    const aggSigPoint = sig1.add(sig2);

    const msgPointEncoded = encodeG2Point(messagePoint);
    const aggSigEncoded = encodeG2Point(aggSigPoint);

    return { msgPointEncoded, aggSigEncoded };
  }

  // ────────────────────────────────────────────────────────────────────
  // Helper: P256 signing (raw hash, NOT EIP-191 wrapped)
  // ────────────────────────────────────────────────────────────────────

  function buildP256Signature(userOpHash: Hex): Hex {
    // P256 signs the raw userOpHash (32 bytes), the contract uses P256VERIFIER(hash, r, s, x, y)
    const hashBytes = hexToBytes(userOpHash);
    const sigObj = p256.sign(hashBytes, p256PrivKey, { lowS: true });
    const r = toHex(sigObj.r, { size: 32 });
    const s = toHex(sigObj.s, { size: 32 });
    return (r + s.slice(2)) as Hex; // 64 bytes: [r(32)][s(32)]
  }

  // ────────────────────────────────────────────────────────────────────
  // Helper: submit handleOps and report result
  // ────────────────────────────────────────────────────────────────────

  // UserOperationEvent topic0 for detecting inner execution success/failure
  const USER_OP_EVENT_TOPIC =
    "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f" as Hex;

  async function submitUserOp(
    signedUserOp: any,
    label: string
  ): Promise<{ success: boolean; innerSuccess: boolean; gasUsed?: bigint; txHash?: Hex }> {
    try {
      const gasEstimate = await publicClient.estimateContractGas({
        address: ENTRYPOINT,
        abi: ENTRYPOINT_ABI,
        functionName: "handleOps",
        args: [[signedUserOp], signer.address],
        account: signer.address,
      });
      console.log(`  Gas estimate: ${gasEstimate}`);

      const hash = await walletClient.writeContract({
        address: ENTRYPOINT,
        abi: ENTRYPOINT_ABI,
        functionName: "handleOps",
        args: [[signedUserOp], signer.address],
        gas: (gasEstimate * 15n) / 10n,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });

      console.log(`  TX     : ${receipt.transactionHash}`);
      console.log(`  Gas    : ${receipt.gasUsed}`);
      console.log(`  Status : ${receipt.status}`);
      console.log(
        `  Etherscan: https://sepolia.etherscan.io/tx/${receipt.transactionHash}`
      );

      // Check UserOperationEvent for inner execution success
      // Event: UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)
      // success is NOT indexed — it's in the data field (2nd word: offset 32..64)
      const uoEvent = receipt.logs.find(
        (log: any) => log.topics[0] === USER_OP_EVENT_TOPIC
      );
      let innerSuccess = true;
      if (uoEvent && uoEvent.data && uoEvent.data.length >= 130) {
        // data layout: nonce(32) + success(32) + actualGasCost(32) + actualGasUsed(32)
        // success is at bytes offset 32..64 → hex chars 66..130 (after 0x prefix)
        const successWord = "0x" + uoEvent.data.slice(66, 130);
        innerSuccess = BigInt(successWord) === 1n;
        console.log(`  Inner  : ${innerSuccess ? "SUCCESS" : "REVERTED (inner execution failed)"}`);
      }

      return { success: true, innerSuccess, gasUsed: receipt.gasUsed, txHash: receipt.transactionHash };
    } catch (e: any) {
      console.log(`  Result: REVERTED (handleOps failed — likely invalid signature)`);
      console.log(`  Error : ${e.message?.slice(0, 200)}`);
      return { success: false, innerSuccess: false };
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // TEST 1: Tier 1 — Small Transfer with ECDSA only (0.005 ETH)
  // ════════════════════════════════════════════════════════════════════

  console.log("================================================================");
  console.log("  TEST 1: Tier 1 — ECDSA only (0.005 ETH ≤ tier1Limit 0.01 ETH)");
  console.log("================================================================\n");

  const userOp1 = await buildUserOp(TIER1_AMOUNT);
  const hash1 = await getUserOpHash(userOp1);
  console.log(`  UserOpHash: ${hash1}`);

  // Raw 65-byte ECDSA signature (backwards-compat format, no algId prefix)
  const ecdsaSig1 = await signer.signMessage({ message: { raw: hexToBytes(hash1) } });
  userOp1.signature = ecdsaSig1;
  console.log(`  Signature : ECDSA raw 65-byte (${(ecdsaSig1.length - 2) / 2} bytes)`);

  const result1 = await submitUserOp(userOp1, "Tier 1 ECDSA");
  if (!result1.success || !result1.innerSuccess) {
    console.error("\n  FAIL: Tier 1 should have succeeded!");
    process.exit(1);
  }
  console.log("\n  PASS: Tier 1 ECDSA transfer succeeded.\n");

  // ════════════════════════════════════════════════════════════════════
  // TEST 2: Tier 2 — Medium Transfer with P256 + BLS (algId 0x04)
  // ════════════════════════════════════════════════════════════════════

  console.log("================================================================");
  console.log("  TEST 2: Tier 2 — P256 + BLS, algId 0x04 (0.05 ETH)");
  console.log("================================================================\n");

  const userOp2 = await buildUserOp(TIER2_AMOUNT);
  const hash2 = await getUserOpHash(userOp2);
  console.log(`  UserOpHash: ${hash2}`);

  // Build P256 signature (signs raw hash, 64 bytes)
  const p256Sig2 = buildP256Signature(hash2);
  console.log(`  P256 sig  : ${p256Sig2.slice(0, 42)}... (64 bytes)`);

  // Build BLS components
  const bls2 = buildBlsComponents(hash2);
  console.log(`  BLS agg   : ${bls2.aggSigEncoded.slice(0, 42)}...`);
  console.log(`  MsgPoint  : ${bls2.msgPointEncoded.slice(0, 42)}...`);

  // MessagePoint signature: owner ECDSA sign of keccak256(messagePoint)
  const mpHash2 = keccak256(bls2.msgPointEncoded);
  const mpSig2 = await signer.signMessage({ message: { raw: hexToBytes(mpHash2) } });

  // Pack cumulative T2 signature:
  // [0x04][P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N*32)][blsSig(256)][messagePoint(256)][messagePointSig(65)]
  const tier2Sig = (
    "0x04" +
    p256Sig2.slice(2) + // P256 r(32) + s(32) = 64 bytes
    toHex(2n, { size: 32 }).slice(2) + // nodeIdsLength = 2
    BLS_NODE_ID_1.slice(2) + // nodeId1 (32 bytes)
    BLS_NODE_ID_2.slice(2) + // nodeId2 (32 bytes)
    bls2.aggSigEncoded.slice(2) + // blsSig (256 bytes)
    bls2.msgPointEncoded.slice(2) + // messagePoint (256 bytes)
    mpSig2.slice(2) // messagePointSig (65 bytes)
  ) as Hex;

  const tier2SigLen = (tier2Sig.length - 2) / 2;
  const expectedT2Len = 1 + 64 + 32 + 64 + 256 + 256 + 65;
  console.log(`  Signature : ${tier2SigLen} bytes (expected: ${expectedT2Len})`);

  userOp2.signature = tier2Sig;
  const result2 = await submitUserOp(userOp2, "Tier 2 P256+BLS");
  if (!result2.success || !result2.innerSuccess) {
    console.error("\n  FAIL: Tier 2 should have succeeded!");
    console.log("  NOTE: EIP-7212 (P256) and EIP-2537 (BLS) precompiles required.\n");
    process.exit(1);
  }
  console.log("\n  PASS: Tier 2 P256+BLS transfer succeeded.\n");

  // ════════════════════════════════════════════════════════════════════
  // TEST 3: Tier 3 — Large Transfer with P256 + BLS + Guardian (algId 0x05)
  // ════════════════════════════════════════════════════════════════════

  console.log("================================================================");
  console.log("  TEST 3: Tier 3 — P256 + BLS + Guardian, algId 0x05 (0.15 ETH)");
  console.log("================================================================\n");

  const userOp3 = await buildUserOp(TIER3_AMOUNT);
  const hash3 = await getUserOpHash(userOp3);
  console.log(`  UserOpHash: ${hash3}`);

  // Build P256 signature
  const p256Sig3 = buildP256Signature(hash3);
  console.log(`  P256 sig  : ${p256Sig3.slice(0, 42)}... (64 bytes)`);

  // Build BLS components
  const bls3 = buildBlsComponents(hash3);
  console.log(`  BLS agg   : ${bls3.aggSigEncoded.slice(0, 42)}...`);

  // MessagePoint signature
  const mpHash3 = keccak256(bls3.msgPointEncoded);
  const mpSig3 = await signer.signMessage({ message: { raw: hexToBytes(mpHash3) } });

  // Guardian ECDSA signature: ANNI signs the userOpHash with EIP-191 personal sign
  const guardianSig3 = await anniSigner.signMessage({
    message: { raw: hexToBytes(hash3) },
  });
  console.log(`  Guardian  : ANNI (${anniSigner.address})`);
  console.log(`  Guard sig : ${guardianSig3.slice(0, 22)}...`);

  // Pack cumulative T3 signature:
  // [0x05][P256 r(32)][P256 s(32)][nodeIdsLength(32)][nodeIds(N*32)][blsSig(256)][messagePoint(256)][messagePointSig(65)][guardianECDSA(65)]
  const tier3Sig = (
    "0x05" +
    p256Sig3.slice(2) + // P256 r(32) + s(32) = 64 bytes
    toHex(2n, { size: 32 }).slice(2) + // nodeIdsLength = 2
    BLS_NODE_ID_1.slice(2) + // nodeId1 (32 bytes)
    BLS_NODE_ID_2.slice(2) + // nodeId2 (32 bytes)
    bls3.aggSigEncoded.slice(2) + // blsSig (256 bytes)
    bls3.msgPointEncoded.slice(2) + // messagePoint (256 bytes)
    mpSig3.slice(2) + // messagePointSig (65 bytes)
    guardianSig3.slice(2) // guardianECDSA (65 bytes)
  ) as Hex;

  const tier3SigLen = (tier3Sig.length - 2) / 2;
  const expectedT3Len = 1 + 64 + 32 + 64 + 256 + 256 + 65 + 65;
  console.log(`  Signature : ${tier3SigLen} bytes (expected: ${expectedT3Len})`);

  userOp3.signature = tier3Sig;
  const result3 = await submitUserOp(userOp3, "Tier 3 P256+BLS+Guardian");
  if (!result3.success || !result3.innerSuccess) {
    console.error("\n  FAIL: Tier 3 should have succeeded!");
    console.log("  NOTE: EIP-7212 (P256) and EIP-2537 (BLS) precompiles required.\n");
    process.exit(1);
  }
  console.log("\n  PASS: Tier 3 P256+BLS+Guardian transfer succeeded.\n");

  // ════════════════════════════════════════════════════════════════════
  // TEST 4 (Negative): Medium transfer with only ECDSA → InsufficientTier
  // ════════════════════════════════════════════════════════════════════

  console.log("================================================================");
  console.log("  TEST 4 (Negative): Medium amount + ECDSA only → REVERT");
  console.log("================================================================\n");

  const userOp4 = await buildUserOp(TIER2_AMOUNT);
  const hash4neg = await getUserOpHash(userOp4);
  console.log(`  UserOpHash: ${hash4neg}`);
  console.log(`  Amount    : ${formatEther(TIER2_AMOUNT)} ETH (requires tier 2)`);
  console.log(`  Signature : ECDSA only (provides tier 1)`);

  // Sign with only ECDSA (raw 65-byte)
  const ecdsaSig4 = await signer.signMessage({ message: { raw: hexToBytes(hash4neg) } });
  userOp4.signature = ecdsaSig4;

  const result4 = await submitUserOp(userOp4, "Negative: ECDSA for tier 2 amount");
  if (result4.innerSuccess) {
    console.error("\n  FAIL: Inner execution should have reverted with InsufficientTier!");
    process.exit(1);
  }
  console.log("\n  PASS: Inner execution correctly reverted (ECDSA insufficient for medium transfer).\n");

  // ════════════════════════════════════════════════════════════════════
  // TEST 5 (Negative): Large transfer with P256+BLS (algId 0x04) → InsufficientTier
  // ════════════════════════════════════════════════════════════════════

  console.log("================================================================");
  console.log("  TEST 5 (Negative): Large amount + P256+BLS only → REVERT");
  console.log("================================================================\n");

  const userOp5 = await buildUserOp(TIER3_AMOUNT);
  const hash5neg = await getUserOpHash(userOp5);
  console.log(`  UserOpHash: ${hash5neg}`);
  console.log(`  Amount    : ${formatEther(TIER3_AMOUNT)} ETH (requires tier 3)`);
  console.log(`  Signature : algId 0x04 P256+BLS (provides tier 2)`);

  // Build P256 + BLS signature (tier 2 only, no guardian)
  const p256Sig5 = buildP256Signature(hash5neg);
  const bls5 = buildBlsComponents(hash5neg);
  const mpHash5 = keccak256(bls5.msgPointEncoded);
  const mpSig5 = await signer.signMessage({ message: { raw: hexToBytes(mpHash5) } });

  const tier2OnlySig = (
    "0x04" +
    p256Sig5.slice(2) +
    toHex(2n, { size: 32 }).slice(2) +
    BLS_NODE_ID_1.slice(2) +
    BLS_NODE_ID_2.slice(2) +
    bls5.aggSigEncoded.slice(2) +
    bls5.msgPointEncoded.slice(2) +
    mpSig5.slice(2)
  ) as Hex;

  userOp5.signature = tier2OnlySig;
  const result5 = await submitUserOp(userOp5, "Negative: P256+BLS for tier 3 amount");
  if (result5.innerSuccess) {
    console.error("\n  FAIL: Inner execution should have reverted with InsufficientTier!");
    process.exit(1);
  }
  console.log("\n  PASS: Inner execution correctly reverted (P256+BLS insufficient for large transfer).\n");

  // ════════════════════════════════════════════════════════════════════
  // Summary
  // ════════════════════════════════════════════════════════════════════

  console.log("+=======================================================+");
  console.log("|  ALL 5 TESTS PASSED                                    |");
  console.log("+=======================================================+");
  console.log(`  Account    : ${accountAddr}`);
  console.log(`  Tier1 Limit: ${formatEther(TIER1_LIMIT)} ETH`);
  console.log(`  Tier2 Limit: ${formatEther(TIER2_LIMIT)} ETH`);
  console.log("");
  console.log("  Test 1 (Tier 1): ECDSA 0.005 ETH         — PASS");
  if (result1.gasUsed) console.log(`    Gas: ${result1.gasUsed}`);
  console.log("  Test 2 (Tier 2): P256+BLS 0.05 ETH       — PASS");
  if (result2.gasUsed) console.log(`    Gas: ${result2.gasUsed}`);
  console.log("  Test 3 (Tier 3): P256+BLS+Guard 0.15 ETH — PASS");
  if (result3.gasUsed) console.log(`    Gas: ${result3.gasUsed}`);
  console.log("  Test 4 (Neg)   : ECDSA → tier 2 amount   — REVERTED (correct)");
  console.log("  Test 5 (Neg)   : P256+BLS → tier 3 amount— REVERTED (correct)");
  console.log("");
  console.log("Done.\n");
}

main().catch((e) => {
  console.error("Fatal:", e.message || e);
  process.exit(1);
});
