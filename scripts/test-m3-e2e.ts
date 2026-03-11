/**
 * Quick M3 E2E test: ETH transfer via UserOp with local ECDSA signing
 * Tests the newly deployed M3 account before KMS integration.
 *
 * Usage: npx tsx scripts/test-m3-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  concat,
  pad,
  parseEther,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// M3 deployment
const M3_ACCOUNT = "0x4bFf3539b73CA3a29d89C00C8c511b884211E31B" as Address;
const RECIPIENT = "0x000000000000000000000000000000000000dEaD" as Address;
const TRANSFER_AMOUNT = parseEther("0.001");

const ENTRYPOINT_ABI = [
  {
    type: "function",
    name: "getNonce",
    inputs: [
      { type: "address", name: "sender" },
      { type: "uint192", name: "key" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getUserOpHash",
    inputs: [
      {
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "handleOps",
    inputs: [
      {
        type: "tuple[]",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
      { name: "beneficiary", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "depositTo",
    inputs: [{ type: "address", name: "account" }],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

async function main() {
  console.log("=== M3 E2E Test: ETH Transfer via UserOp ===\n");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });
  const walletClient = createWalletClient({
    account: signer,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  // Fund account
  console.log("1. Funding M3 account...");
  const balance = await publicClient.getBalance({ address: M3_ACCOUNT });
  if (balance < parseEther("0.005")) {
    const fundTx = await walletClient.sendTransaction({
      to: M3_ACCOUNT,
      value: parseEther("0.01"),
    });
    await publicClient.waitForTransactionReceipt({ hash: fundTx });
    console.log(`   Funded: ${fundTx}`);
  }

  // Deposit to EntryPoint
  console.log("2. Depositing to EntryPoint...");
  const depositTx = await walletClient.writeContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "depositTo",
    args: [M3_ACCOUNT],
    value: parseEther("0.01"),
  });
  await publicClient.waitForTransactionReceipt({ hash: depositTx });
  console.log(`   Deposited: ${depositTx}`);

  // Build UserOp
  console.log("3. Building UserOperation...");
  const callData = encodeFunctionData({
    abi: [
      {
        type: "function",
        name: "execute",
        inputs: [
          { type: "address" },
          { type: "uint256" },
          { type: "bytes" },
        ],
      },
    ],
    functionName: "execute",
    args: [RECIPIENT, TRANSFER_AMOUNT, "0x"],
  });

  const nonce = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [M3_ACCOUNT, 0n],
  })) as bigint;

  const userOp = {
    sender: M3_ACCOUNT,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: packUint128(150000n, 100000n),
    preVerificationGas: 50000n,
    gasFees: packUint128(2000000000n, 3000000000n),
    paymasterAndData: "0x" as Hex,
    signature: "0x" as Hex,
  };

  // Sign
  console.log("4. Signing...");
  const userOpHash = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  })) as Hex;

  const signature = await signer.signMessage({
    message: { raw: userOpHash },
  });
  userOp.signature = signature;
  console.log(`   UserOpHash: ${userOpHash}`);
  console.log(`   Sig: ${signature.slice(0, 20)}...`);

  // Submit
  console.log("5. Submitting handleOps...");
  const recipientBefore = await publicClient.getBalance({
    address: RECIPIENT,
  });

  const txHash = await walletClient.writeContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "handleOps",
    args: [[userOp], signer.address],
    gas: 1000000n,
  });

  console.log(`   TX: ${txHash}`);
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });

  console.log(`   Status: ${receipt.status}`);
  console.log(`   Gas used: ${receipt.gasUsed}`);

  const recipientAfter = await publicClient.getBalance({
    address: RECIPIENT,
  });
  const diff = recipientAfter - recipientBefore;
  console.log(`   Recipient received: ${formatEther(diff)} ETH`);

  if (diff === TRANSFER_AMOUNT) {
    console.log("\n=== M3 E2E SUCCESS ===");
    console.log(`TX: https://sepolia.etherscan.io/tx/${txHash}`);
  } else {
    console.log("\n=== TRANSFER MISMATCH ===");
  }
}

main().catch((err) => {
  console.error("Error:", err.message || err);
  process.exit(1);
});
