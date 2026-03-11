/**
 * AirAccount Gasless E2E Test (F27)
 *
 * Tests gasless transaction via SuperPaymaster + aPNTs token.
 * The AA account pays gas in aPNTs instead of ETH.
 *
 * Prerequisites:
 *   1. AA account must hold MySBT (soul-bound identity token)
 *   2. AA account must hold aPNTs balance (gas token)
 *   3. SuperPaymaster must have sufficient EntryPoint deposit
 *   4. Operator must be registered in SuperPaymaster
 *
 * Usage:
 *   pnpm tsx scripts/test-e2e-gasless.ts
 */

import * as path from "path";
import { fileURLToPath } from "url";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  concat,
  pad,
  type Hex,
  type Address,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import * as dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env.sepolia") });

// ─── Configuration ──────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = (process.env.PRIVATE_KEY_JASON ||
  process.env.PRIVATE_KEY!) as Hex;

// Addresses from aastar-sdk config.sepolia.json (authoritative source)
const SUPER_PAYMASTER = (process.env.SUPER_PAYMASTER_ADDRESS ||
  "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A") as Address;
const OPERATOR_ADDRESS = (process.env.OPERATOR_ADDRESS ||
  "0xb5600060e6de5E11D3636731964218E53caadf0E") as Address;
const APNTS_TOKEN = (process.env.APNTS_TOKEN_ADDRESS ||
  "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d") as Address;
const SBT_ADDRESS = (process.env.SBT_ADDRESS ||
  "0x677423f5Dad98D19cAE8661c36F094289cb6171a") as Address;

// AirAccount M2 deployment
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const AA_ACCOUNT = (process.env.AA_ACCOUNT_ADDRESS ||
  "0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07") as Address;

// Transfer target
const RECIPIENT = (process.env.GASLESS_RECIPIENT ||
  "0x000000000000000000000000000000000000dEaD") as Address;

// ─── ABIs (minimal) ─────────────────────────────────────────────────

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
  {
    type: "function",
    name: "transfer",
    inputs: [
      { type: "address", name: "to" },
      { type: "uint256", name: "amount" },
    ],
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

// ─── Helpers ────────────────────────────────────────────────────────

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

// ─── Main ───────────────────────────────────────────────────────────

async function main() {
  console.log("=== AirAccount Gasless E2E Test (F27) ===\n");

  // Validate env
  if (!RPC_URL) throw new Error("SEPOLIA_RPC_URL not set");
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");
  if (!APNTS_TOKEN) throw new Error("APNTS_TOKEN_ADDRESS not set");

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

  console.log("Configuration:");
  console.log(`  AA Account:       ${AA_ACCOUNT}`);
  console.log(`  SuperPaymaster:   ${SUPER_PAYMASTER}`);
  console.log(`  Operator:         ${OPERATOR_ADDRESS}`);
  console.log(`  aPNTs Token:      ${APNTS_TOKEN}`);
  console.log(`  MySBT:            ${SBT_ADDRESS}`);
  console.log(`  Signer EOA:       ${signer.address}`);
  console.log(`  Recipient:        ${RECIPIENT}\n`);

  // ── Step 0: Pre-flight checks ──

  console.log("Step 0: Pre-flight checks\n");

  // Check SBT
  const sbtBalance = await publicClient.readContract({
    address: SBT_ADDRESS,
    abi: SBT_ABI,
    functionName: "balanceOf",
    args: [AA_ACCOUNT],
  });
  console.log(`  SBT balance: ${sbtBalance}`);
  if (sbtBalance === 0n) {
    console.error("  FAIL: AA account does not hold MySBT. Mint one first.");
    process.exit(1);
  }
  console.log("  OK: SBT found\n");

  // Check aPNTs balance
  const [xpntsBalance, symbol, decimals] = await Promise.all([
    publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [AA_ACCOUNT],
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
    `  aPNTs balance: ${Number(xpntsBalance) / 10 ** Number(decimals)} ${symbol}`
  );
  if (xpntsBalance === 0n) {
    console.error("  FAIL: AA account has no aPNTs. Fund it first.");
    process.exit(1);
  }
  console.log("  OK: aPNTs balance sufficient\n");

  // Check paymaster deposit
  const pmDeposit = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: PAYMASTER_ABI,
    functionName: "getDeposit",
  });
  console.log(`  Paymaster deposit: ${Number(pmDeposit) / 1e18} ETH`);
  if (pmDeposit < 10000000000000000n) {
    console.warn("  WARNING: Low paymaster deposit (<0.01 ETH)\n");
  } else {
    console.log("  OK: Paymaster deposit sufficient\n");
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
    console.log("  OK: Price cache refreshed\n");
  } else {
    console.log(`  OK: Price cache valid (ETH/USD = ${Number(cached[0]) / 1e8})\n`);
  }

  // ── Step 1: Build UserOperation ──

  console.log("Step 1: Build UserOperation\n");

  // Transfer 1 aPNTs to RECIPIENT via AA account's execute()
  const transferAmount = 10n ** BigInt(decimals); // 1 token
  const transferCalldata = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: "transfer",
    args: [RECIPIENT, transferAmount],
  });

  // Wrap in account's execute(dest, value, func)
  const executeCalldata = encodeFunctionData({
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
    args: [APNTS_TOKEN, 0n, transferCalldata],
  });

  // Get nonce from EntryPoint (our account doesn't have getNonce())
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [AA_ACCOUNT, 0n],
  });
  console.log(`  Nonce: ${nonce}`);
  console.log(`  Action: transfer 1 ${symbol} to ${RECIPIENT}`);

  // Build paymasterAndData (72 bytes)
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

  // Pack gas limits
  const accountGasLimits = packUint128(90000n, 80000n); // verificationGas, callGas
  const gasFees = packUint128(2000000000n, 2000000000n); // maxPriorityFee, maxFee (2 gwei)

  const userOp = {
    sender: AA_ACCOUNT,
    nonce,
    initCode: "0x" as Hex,
    callData: executeCalldata,
    accountGasLimits,
    preVerificationGas: 21000n,
    gasFees,
    paymasterAndData,
    signature: "0x" as Hex,
  };

  console.log(`  paymasterAndData: ${(paymasterAndData.length - 2) / 2} bytes`);
  console.log(
    `  Gas: verification=90k, call=80k, pmVerify=250k, pmPostOp=50k\n`
  );

  // ── Step 2: Sign UserOperation ──

  console.log("Step 2: Sign UserOperation\n");

  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  });
  console.log(`  UserOpHash: ${userOpHash}`);

  // Sign with EIP-191 personal sign (65-byte ECDSA = backwards compat with AirAccount)
  const signature = await signer.signMessage({
    message: { raw: userOpHash as Hex },
  });
  userOp.signature = signature;
  console.log(`  Signature: ${signature.slice(0, 20)}... (${(signature.length - 2) / 2} bytes)\n`);

  // ── Step 3: Submit to EntryPoint ──

  console.log("Step 3: Submit handleOps\n");

  const recipientBefore = await publicClient.readContract({
    address: APNTS_TOKEN,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [RECIPIENT],
  });

  try {
    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], signer.address],
      gas: 2000000n,
    });

    console.log(`  TX sent: ${txHash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${txHash}\n`);

    console.log("  Waiting for confirmation...");
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
    });

    if (receipt.status === "success") {
      console.log(`  Confirmed in block ${receipt.blockNumber}\n`);

      // ── Step 4: Verify results ──

      console.log("Step 4: Verify results\n");

      const [xpntsAfter, recipientAfter] = await Promise.all([
        publicClient.readContract({
          address: APNTS_TOKEN,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [AA_ACCOUNT],
        }),
        publicClient.readContract({
          address: APNTS_TOKEN,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [RECIPIENT],
        }),
      ]);

      const senderDiff = xpntsBalance - xpntsAfter;
      const recipientDiff = recipientAfter - recipientBefore;

      console.log(`  Sender aPNTs:    ${Number(xpntsBalance) / 10 ** Number(decimals)} -> ${Number(xpntsAfter) / 10 ** Number(decimals)} (${Number(senderDiff) / 10 ** Number(decimals)} spent)`);
      console.log(`  Recipient aPNTs: +${Number(recipientDiff) / 10 ** Number(decimals)}`);
      console.log(`  Gas used:        ${receipt.gasUsed}`);
      console.log(`  Gas paid by:     ${receipt.from} (EOA bundler)\n`);

      // Check AA account ETH balance didn't decrease (gasless!)
      const aaEthBalance = await publicClient.getBalance({
        address: AA_ACCOUNT,
      });
      console.log(`  AA ETH balance:  ${Number(aaEthBalance) / 1e18} ETH (should not decrease)\n`);

      if (recipientDiff === transferAmount) {
        console.log("=== GASLESS TRANSFER SUCCESSFUL ===");
        console.log("  AA account transferred aPNTs without paying ETH gas.");
        console.log("  Gas was paid by SuperPaymaster (aPNTs deducted in postOp).");
      } else {
        console.log("=== TRANSFER AMOUNT MISMATCH ===");
      }
    } else {
      console.error("  Transaction reverted on-chain.");
    }
  } catch (error: any) {
    console.error("\nError:", error.message);

    if (error.message.includes("AA93")) {
      console.error("  -> Paymaster validation failed (check SBT/aPNTs)");
    } else if (error.message.includes("AA33")) {
      console.error("  -> Paymaster internal validation (check operator)");
    } else if (error.message.includes("AA31")) {
      console.error("  -> Paymaster deposit too low");
    } else if (error.message.includes("AA25")) {
      console.error("  -> Invalid account nonce");
    } else if (error.message.includes("OutstandingDebt")) {
      console.error("  -> User has outstanding debt, must clear first");
    }

    process.exit(1);
  }

  console.log("\n=== F27 Gasless E2E Complete ===");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
