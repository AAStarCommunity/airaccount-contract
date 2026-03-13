/**
 * Onboard Step 3: Test ETH Transfer via UserOperation + KMS Signing
 *
 * Flow:
 *   1. Load account + KMS wallet info from .env.wallet / .env.sepolia
 *   2. Build a UserOperation (ETH transfer to a test recipient)
 *   3. Get userOpHash from EntryPoint
 *   4. Sign userOpHash via KMS /SignHash API (TEE-protected EOA key)
 *   5. Submit via bundler eth_sendUserOperation (or direct handleOps)
 *   6. Wait for receipt and verify
 *
 * Usage: npx tsx scripts/onboard-3-test-transfer.ts
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
  hashMessage,
  parseEther,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

// Load env files
config({ path: resolve(import.meta.dirname, "../.env.sepolia") });
config({ path: resolve(import.meta.dirname, "../.env.wallet") });

// ─── Configuration ──────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const BUNDLER_URL = process.env.SEPOLIA_BUNDLER_RPC || RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex; // Funding/beneficiary key
const KMS_BASE_URL = process.env.KMS_BASE_URL || "https://kms.aastar.io";
const KMS_API_KEY = process.env.KMS_API_KEY;

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const TRANSFER_AMOUNT = parseEther("0.001"); // 0.001 ETH test transfer
const RECIPIENT =
  "0x000000000000000000000000000000000000dEaD" as Address; // Burn address

// ─── ABI Fragments ──────────────────────────────────────────────────

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
    name: "deposits",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "depositTo",
    inputs: [{ type: "address", name: "account" }],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

const ACCOUNT_ABI = [
  {
    type: "function",
    name: "execute",
    inputs: [
      { type: "address", name: "dest" },
      { type: "uint256", name: "value" },
      { type: "bytes", name: "func" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "owner",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
] as const;

// ─── KMS API ────────────────────────────────────────────────────────

interface KmsSignHashResponse {
  Signature: string;
}

async function kmsSignHash(
  address: string,
  hash: string
): Promise<KmsSignHashResponse> {
  const formattedHash = hash.startsWith("0x") ? hash : `0x${hash}`;

  const headers: Record<string, string> = {
    "Content-Type": "application/x-amz-json-1.1",
    "x-amz-target": "TrentService.SignHash",
  };
  if (KMS_API_KEY) {
    headers["x-api-key"] = KMS_API_KEY;
  }

  const res = await fetch(`${KMS_BASE_URL}/SignHash`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      Address: address,
      Hash: formattedHash,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`KMS SignHash failed (${res.status}): ${text}`);
  }

  return res.json();
}

// ─── Helpers ────────────────────────────────────────────────────────

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

// ─── Main ───────────────────────────────────────────────────────────

async function main() {
  console.log("=== Onboard Step 3: Test ETH Transfer via UserOp ===\n");

  // ─── Load Config ───────────────────────────────────────────────
  const eoaAddress = process.env.KMS_EOA_ADDRESS as Address;
  const accountAddress = process.env.AIRACCOUNT_ADDRESS as Address;

  if (!eoaAddress) {
    throw new Error("KMS_EOA_ADDRESS not found. Run onboard-1 first.");
  }
  if (!accountAddress) {
    throw new Error("AIRACCOUNT_ADDRESS not found. Run onboard-2 first.");
  }
  if (!PRIVATE_KEY) {
    throw new Error("PRIVATE_KEY not set in .env.sepolia (for gas funding).");
  }

  console.log(`Account      : ${accountAddress}`);
  console.log(`Owner (EOA)  : ${eoaAddress}`);
  console.log(`Recipient    : ${RECIPIENT}`);
  console.log(`Amount       : ${formatEther(TRANSFER_AMOUNT)} ETH`);

  // ─── Setup Clients ─────────────────────────────────────────────
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const funder = privateKeyToAccount(PRIVATE_KEY);
  const walletClient = createWalletClient({
    account: funder,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  // ─── Pre-flight Checks ────────────────────────────────────────
  console.log("\n1. Pre-flight checks...");

  // Verify account is deployed
  const code = await publicClient.getBytecode({ address: accountAddress });
  if (!code || code === "0x") {
    throw new Error("Account not deployed. Run onboard-2 first.");
  }
  console.log("   Account deployed: yes");

  // Verify owner matches KMS EOA
  const onChainOwner = await publicClient.readContract({
    address: accountAddress,
    abi: ACCOUNT_ABI,
    functionName: "owner",
  });
  if ((onChainOwner as string).toLowerCase() !== eoaAddress.toLowerCase()) {
    throw new Error(
      `Owner mismatch: on-chain=${onChainOwner}, expected=${eoaAddress}`
    );
  }
  console.log("   Owner verified: yes");

  // Check account ETH balance
  const accountBalance = await publicClient.getBalance({
    address: accountAddress,
  });
  console.log(`   Account balance: ${formatEther(accountBalance)} ETH`);

  if (accountBalance < TRANSFER_AMOUNT) {
    console.log("\n   Account needs more ETH. Funding...");
    const fundAmount = parseEther("0.005");
    const fundTx = await walletClient.sendTransaction({
      to: accountAddress,
      value: fundAmount,
    });
    console.log(`   Fund tx: ${fundTx}`);
    await publicClient.waitForTransactionReceipt({ hash: fundTx });
    const newBalance = await publicClient.getBalance({
      address: accountAddress,
    });
    console.log(`   New balance: ${formatEther(newBalance)} ETH`);
  }

  // Check EntryPoint deposit for account (needed for gas prefund)
  const epDeposit = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "deposits",
    args: [accountAddress],
  })) as bigint;
  console.log(`   EntryPoint deposit: ${formatEther(epDeposit)} ETH`);

  if (epDeposit < parseEther("0.005")) {
    console.log("   Deposit low, adding 0.01 ETH to EntryPoint...");
    const depositTx = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "depositTo",
      args: [accountAddress],
      value: parseEther("0.01"),
    });
    console.log(`   Deposit tx: ${depositTx}`);
    await publicClient.waitForTransactionReceipt({ hash: depositTx });
  }

  // ─── Build UserOperation ──────────────────────────────────────
  console.log("\n2. Building UserOperation...");

  // Encode execute(dest, value, func) calldata
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI,
    functionName: "execute",
    args: [RECIPIENT, TRANSFER_AMOUNT, "0x"],
  });

  // Get nonce from EntryPoint
  const nonce = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [accountAddress, 0n],
  })) as bigint;
  console.log(`   Nonce: ${nonce}`);

  // Pack gas parameters (v0.7 format)
  const verificationGasLimit = 150000n;
  const callGasLimit = 100000n;
  const maxPriorityFeePerGas = 2000000000n; // 2 gwei
  const maxFeePerGas = 3000000000n; // 3 gwei
  const preVerificationGas = 50000n;

  const accountGasLimits = packUint128(verificationGasLimit, callGasLimit);
  const gasFees = packUint128(maxPriorityFeePerGas, maxFeePerGas);

  const userOp = {
    sender: accountAddress,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits,
    preVerificationGas,
    gasFees,
    paymasterAndData: "0x" as Hex,
    signature: "0x" as Hex,
  };

  console.log(
    `   Gas: verify=${verificationGasLimit}, call=${callGasLimit}, preVerify=${preVerificationGas}`
  );

  // ─── Sign via KMS ─────────────────────────────────────────────
  console.log("\n3. Signing UserOperation via KMS...");

  // Get userOpHash from EntryPoint
  const userOpHash = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  })) as Hex;
  console.log(`   UserOpHash: ${userOpHash}`);

  // AirAccount's _validateECDSA does: toEthSignedMessageHash(userOpHash).recover(sig)
  // So KMS must sign the EIP-191 wrapped hash
  const ethSignedHash = hashMessage({ raw: userOpHash });
  console.log(`   EIP-191 hash: ${ethSignedHash}`);

  // Call KMS /SignHash
  console.log(`   Calling KMS /SignHash for ${eoaAddress}...`);
  const kmsResponse = await kmsSignHash(eoaAddress, ethSignedHash);
  const signature = ("0x" + kmsResponse.Signature) as Hex;
  console.log(
    `   Signature: ${signature.slice(0, 20)}... (${(signature.length - 2) / 2} bytes)`
  );

  // Use raw 65-byte ECDSA signature (backwards compat, no algId prefix needed)
  userOp.signature = signature;

  // ─── Submit to EntryPoint ─────────────────────────────────────
  console.log("\n4. Submitting UserOperation...");

  const recipientBefore = await publicClient.getBalance({
    address: RECIPIENT,
  });

  try {
    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], funder.address],
      gas: 1000000n,
    });

    console.log(`   TX: ${txHash}`);
    console.log(`   https://sepolia.etherscan.io/tx/${txHash}\n`);

    console.log("   Waiting for confirmation...");
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
    });

    if (receipt.status === "success") {
      console.log(`   Confirmed in block ${receipt.blockNumber}`);
      console.log(`   Gas used: ${receipt.gasUsed}`);

      // ─── Verify Results ──────────────────────────────────────
      console.log("\n5. Verifying results...");

      const [accountBalanceAfter, recipientAfter] = await Promise.all([
        publicClient.getBalance({ address: accountAddress }),
        publicClient.getBalance({ address: RECIPIENT }),
      ]);

      const recipientDiff = recipientAfter - recipientBefore;
      console.log(
        `   Account balance: ${formatEther(accountBalance)} -> ${formatEther(accountBalanceAfter)} ETH`
      );
      console.log(`   Recipient received: ${formatEther(recipientDiff)} ETH`);

      if (recipientDiff === TRANSFER_AMOUNT) {
        console.log("\n=== ETH TRANSFER SUCCESSFUL ===");
        console.log(
          "   UserOp signed by KMS (TEE) and executed via EntryPoint."
        );
      } else {
        console.log("\n=== TRANSFER AMOUNT MISMATCH ===");
        console.log(
          `   Expected: ${formatEther(TRANSFER_AMOUNT)}, Got: ${formatEther(recipientDiff)}`
        );
      }
    } else {
      console.error("   Transaction reverted on-chain.");
    }
  } catch (error: any) {
    console.error("\nError:", error.message);

    // Common ERC-4337 error codes
    if (error.message.includes("AA21")) {
      console.error("   -> Account does not exist or not deployed");
    } else if (error.message.includes("AA24")) {
      console.error("   -> Signature validation failed");
      console.error(
        "   Check: Is KMS signing with the correct EOA private key?"
      );
    } else if (error.message.includes("AA25")) {
      console.error("   -> Invalid nonce");
    } else if (error.message.includes("AA10")) {
      console.error("   -> Insufficient sender balance (for gas prefund)");
    } else if (error.message.includes("AA51")) {
      console.error("   -> Prefund insufficient");
    }

    process.exit(1);
  }

  console.log("\n=== Onboard Step 3 Complete ===");
  console.log("Next: npx tsx scripts/onboard-4-gasless-transfer.ts");
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
