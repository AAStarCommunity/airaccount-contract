/**
 * Onboard Step 4: Gasless ETH Transfer via SuperPaymaster (F40)
 *
 * Proves gasless transaction flow: the AA account transfers 0.0001 ETH
 * to itself, with gas paid entirely by SuperPaymaster (aPNTs deducted).
 *
 * Flow:
 *   1. Load account from .env.wallet (AIRACCOUNT_ADDRESS) + .env.sepolia
 *   2. Build UserOp for ETH self-transfer (0.0001 ETH to self)
 *   3. Add paymasterAndData with SuperPaymaster address
 *   4. Sign userOpHash via KMS /SignHash API (TEE-protected EOA key)
 *   5. Submit handleOps and verify account ETH balance didn't decrease
 *
 * Prerequisites:
 *   - AA account must hold MySBT (soul-bound identity token)
 *   - AA account must hold aPNTs balance (gas token for paymaster)
 *   - SuperPaymaster must have sufficient EntryPoint deposit
 *   - Operator must be registered in SuperPaymaster
 *
 * Usage: pnpm tsx scripts/onboard-4-gasless-transfer.ts
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
const PRIVATE_KEY = process.env.PRIVATE_KEY as Hex; // Funding/beneficiary EOA key
const KMS_BASE_URL = process.env.KMS_BASE_URL || "https://kms.aastar.io";
const KMS_API_KEY = process.env.KMS_API_KEY;

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const SELF_TRANSFER_AMOUNT = parseEther("0.0001"); // 0.0001 ETH to self

// SuperPaymaster ecosystem addresses
const SUPER_PAYMASTER = (process.env.SUPER_PAYMASTER_ADDRESS ||
  "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A") as Address;
const OPERATOR_ADDRESS = (process.env.OPERATOR_ADDRESS ||
  "0xb5600060e6de5E11D3636731964218E53caadf0E") as Address;
const APNTS_TOKEN = (process.env.APNTS_TOKEN_ADDRESS ||
  "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d") as Address;
const SBT_ADDRESS = (process.env.SBT_ADDRESS ||
  "0x677423f5Dad98D19cAE8661c36F094289cb6171a") as Address;

// ─── ABI Fragments ──────────────────────────────────────────────────

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
] as const;

const SBT_ABI = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

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

const PAYMASTER_ABI = [
  {
    type: "function",
    name: "getDeposit",
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "cachedPrice",
    inputs: [],
    outputs: [
      { type: "int256", name: "price" },
      { type: "uint256", name: "updatedAt" },
      { type: "uint80", name: "roundId" },
      { type: "uint8", name: "decimals" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "priceStalenessThreshold",
    inputs: [],
    outputs: [{ type: "uint48" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "updatePrice",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
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
  console.log("=== Onboard Step 4: Gasless ETH Transfer via SuperPaymaster (F40) ===\n");

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
    throw new Error("PRIVATE_KEY not set in .env.sepolia (for bundler gas funding).");
  }

  const funder = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account: funder,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  console.log("Configuration:");
  console.log(`  AA Account:       ${accountAddress}`);
  console.log(`  Owner (EOA):      ${eoaAddress}`);
  console.log(`  SuperPaymaster:   ${SUPER_PAYMASTER}`);
  console.log(`  Operator:         ${OPERATOR_ADDRESS}`);
  console.log(`  aPNTs Token:      ${APNTS_TOKEN}`);
  console.log(`  MySBT:            ${SBT_ADDRESS}`);
  console.log(`  Bundler EOA:      ${funder.address}`);
  console.log(`  Self-transfer:    ${formatEther(SELF_TRANSFER_AMOUNT)} ETH\n`);

  // ─── Step 0: Pre-flight Checks ─────────────────────────────────

  console.log("Step 0: Pre-flight checks\n");

  // Verify account is deployed
  const code = await publicClient.getBytecode({ address: accountAddress });
  if (!code || code === "0x") {
    throw new Error("Account not deployed. Run onboard-2 first.");
  }
  console.log("  Account deployed: yes");

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
  console.log("  Owner verified: yes");

  // Check SBT
  const sbtBalance = await publicClient.readContract({
    address: SBT_ADDRESS,
    abi: SBT_ABI,
    functionName: "balanceOf",
    args: [accountAddress],
  });
  console.log(`  SBT balance: ${sbtBalance}`);
  if (sbtBalance === 0n) {
    console.error("  FAIL: AA account does not hold MySBT. Mint one first.");
    process.exit(1);
  }
  console.log("  OK: SBT found");

  // Check aPNTs balance
  const [apntsBalance, symbol, decimals] = await Promise.all([
    publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [accountAddress],
    }),
    publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "symbol",
    }),
    publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "decimals",
    }),
  ]);
  console.log(
    `  aPNTs balance: ${Number(apntsBalance) / 10 ** Number(decimals)} ${symbol}`
  );
  if (apntsBalance === 0n) {
    console.error("  FAIL: AA account has no aPNTs. Fund it first.");
    process.exit(1);
  }
  console.log("  OK: aPNTs balance sufficient");

  // Check ETH balance (needs enough for the self-transfer value)
  const ethBalanceBefore = await publicClient.getBalance({
    address: accountAddress,
  });
  console.log(`  ETH balance: ${formatEther(ethBalanceBefore)} ETH`);
  if (ethBalanceBefore < SELF_TRANSFER_AMOUNT) {
    console.error(
      `  FAIL: AA account needs at least ${formatEther(SELF_TRANSFER_AMOUNT)} ETH for self-transfer.`
    );
    process.exit(1);
  }
  console.log("  OK: ETH balance sufficient for self-transfer");

  // Check paymaster deposit
  const pmDeposit = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: PAYMASTER_ABI,
    functionName: "getDeposit",
  });
  console.log(`  Paymaster deposit: ${Number(pmDeposit) / 1e18} ETH`);
  if (pmDeposit < 10000000000000000n) {
    console.warn("  WARNING: Low paymaster deposit (<0.01 ETH)");
  } else {
    console.log("  OK: Paymaster deposit sufficient");
  }

  // Check price cache staleness (auto-refresh if stale)
  const [cached, threshold] = await Promise.all([
    publicClient.readContract({
      address: SUPER_PAYMASTER,
      abi: PAYMASTER_ABI,
      functionName: "cachedPrice",
    }),
    publicClient.readContract({
      address: SUPER_PAYMASTER,
      abi: PAYMASTER_ABI,
      functionName: "priceStalenessThreshold",
    }),
  ]);
  const validUntil = BigInt(cached[1]) + BigInt(threshold);
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  if (nowSec > validUntil) {
    console.log("  Price cache STALE, refreshing...");
    const refreshHash = await walletClient.writeContract({
      address: SUPER_PAYMASTER,
      abi: PAYMASTER_ABI,
      functionName: "updatePrice",
    });
    await publicClient.waitForTransactionReceipt({ hash: refreshHash });
    console.log("  OK: Price cache refreshed");
  } else {
    console.log(`  OK: Price cache valid (ETH/USD = ${Number(cached[0]) / 1e8})`);
  }

  console.log();

  // ─── Step 1: Build UserOperation ───────────────────────────────

  console.log("Step 1: Build UserOperation\n");

  // ETH self-transfer: execute(self, 0.0001 ETH, 0x)
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI,
    functionName: "execute",
    args: [accountAddress, SELF_TRANSFER_AMOUNT, "0x"],
  });

  // Get nonce from EntryPoint
  const nonce = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [accountAddress, 0n],
  })) as bigint;
  console.log(`  Nonce: ${nonce}`);
  console.log(`  Action: self-transfer ${formatEther(SELF_TRANSFER_AMOUNT)} ETH`);

  // Build paymasterAndData (72 bytes):
  // [0:20]  paymaster address
  // [20:36] paymasterVerificationGasLimit (uint128) - 16 bytes
  // [36:52] paymasterPostOpGasLimit (uint128) - 16 bytes
  // [52:72] operator address - 20 bytes
  const paymasterVerificationGas = 250000n;
  const paymasterPostOpGas = 50000n;

  const paymasterAndData: Hex = concat([
    SUPER_PAYMASTER,
    pad(`0x${paymasterVerificationGas.toString(16)}`, {
      dir: "left",
      size: 16,
    }),
    pad(`0x${paymasterPostOpGas.toString(16)}`, { dir: "left", size: 16 }),
    OPERATOR_ADDRESS,
  ]);

  // Pack gas limits (v0.7 format)
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
    paymasterAndData,
    signature: "0x" as Hex,
  };

  console.log(`  paymasterAndData: ${(paymasterAndData.length - 2) / 2} bytes`);
  console.log(
    `  Gas: verify=${verificationGasLimit}, call=${callGasLimit}, pmVerify=${paymasterVerificationGas}, pmPostOp=${paymasterPostOpGas}\n`
  );

  // ─── Step 2: Sign via KMS ─────────────────────────────────────

  console.log("Step 2: Sign UserOperation via KMS\n");

  // Get userOpHash from EntryPoint
  const userOpHash = (await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  })) as Hex;
  console.log(`  UserOpHash: ${userOpHash}`);

  // AirAccount's _validateECDSA does: toEthSignedMessageHash(userOpHash).recover(sig)
  // So KMS must sign the EIP-191 wrapped hash
  const ethSignedHash = hashMessage({ raw: userOpHash });
  console.log(`  EIP-191 hash: ${ethSignedHash}`);

  // Call KMS /SignHash
  console.log(`  Calling KMS /SignHash for ${eoaAddress}...`);
  const kmsResponse = await kmsSignHash(eoaAddress, ethSignedHash);
  const signature = ("0x" + kmsResponse.Signature) as Hex;
  console.log(
    `  Signature: ${signature.slice(0, 20)}... (${(signature.length - 2) / 2} bytes)\n`
  );

  // Use raw 65-byte ECDSA signature (backwards compat, no algId prefix needed)
  userOp.signature = signature;

  // ─── Step 3: Submit to EntryPoint ──────────────────────────────

  console.log("Step 3: Submit handleOps\n");

  try {
    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], funder.address],
      gas: 2000000n,
    });

    console.log(`  TX sent: ${txHash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${txHash}\n`);

    console.log("  Waiting for confirmation...");
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
    });

    if (receipt.status === "success") {
      console.log(`  Confirmed in block ${receipt.blockNumber}`);
      console.log(`  Gas used: ${receipt.gasUsed}\n`);

      // ─── Step 4: Verify Gasless ──────────────────────────────

      console.log("Step 4: Verify gasless execution\n");

      const [ethBalanceAfter, apntsAfter] = await Promise.all([
        publicClient.getBalance({ address: accountAddress }),
        publicClient.readContract({
          address: APNTS_TOKEN,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [accountAddress],
        }),
      ]);

      const ethDiff = ethBalanceBefore - ethBalanceAfter;
      const apntsDiff = apntsBalance - apntsAfter;

      console.log(
        `  ETH before:  ${formatEther(ethBalanceBefore)} ETH`
      );
      console.log(
        `  ETH after:   ${formatEther(ethBalanceAfter)} ETH`
      );
      console.log(
        `  ETH diff:    ${formatEther(ethDiff)} ETH (should be 0 for self-transfer)`
      );
      console.log(
        `  aPNTs before: ${Number(apntsBalance) / 10 ** Number(decimals)} ${symbol}`
      );
      console.log(
        `  aPNTs after:  ${Number(apntsAfter) / 10 ** Number(decimals)} ${symbol}`
      );
      console.log(
        `  aPNTs spent:  ${Number(apntsDiff) / 10 ** Number(decimals)} ${symbol} (gas fee in tokens)`
      );
      console.log(`  Gas paid by:  ${receipt.from} (EOA bundler)\n`);

      // Verify: ETH balance should NOT decrease (self-transfer + gasless)
      if (ethBalanceAfter >= ethBalanceBefore) {
        console.log("=== GASLESS SELF-TRANSFER SUCCESSFUL ===");
        console.log("  ETH balance did NOT decrease.");
        console.log("  Gas was paid by SuperPaymaster (aPNTs deducted in postOp).");
      } else {
        // Self-transfer to self: ETH balance should stay the same
        // (value sent = value received, and gas is paid by paymaster)
        console.log("=== WARNING: ETH balance decreased ===");
        console.log(
          `  Unexpected ETH decrease of ${formatEther(ethDiff)} ETH.`
        );
        console.log("  This may indicate the paymaster did not cover gas.");
      }
    } else {
      console.error("  Transaction reverted on-chain.");
    }
  } catch (error: any) {
    console.error("\nError:", error.message);

    // Common ERC-4337 + paymaster error codes
    if (error.message.includes("AA24")) {
      console.error("  -> Signature validation failed");
      console.error("  Check: Is KMS signing with the correct EOA private key?");
    } else if (error.message.includes("AA25")) {
      console.error("  -> Invalid account nonce");
    } else if (error.message.includes("AA93")) {
      console.error("  -> Paymaster validation failed (check SBT/aPNTs)");
    } else if (error.message.includes("AA33")) {
      console.error("  -> Paymaster internal validation (check operator)");
    } else if (error.message.includes("AA31")) {
      console.error("  -> Paymaster deposit too low");
    } else if (error.message.includes("OutstandingDebt")) {
      console.error("  -> User has outstanding debt, must clear first");
    }

    process.exit(1);
  }

  console.log("\n=== Onboard Step 4 (F40) Complete ===");
}

main().catch((err) => {
  console.error("Error:", err.message);
  process.exit(1);
});
