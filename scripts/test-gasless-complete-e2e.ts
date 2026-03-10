/**
 * AirAccount M3 Complete Gasless E2E Test
 *
 * Full lifecycle test:
 *   Phase 1: Prepare account (SBT, aPNTs, ETH funding)
 *   Phase 2: Build gasless UserOp via SuperPaymaster
 *   Phase 3: Submit & verify zero ETH cost
 *
 * The M3 account executes a tiny self-transfer (0.0001 ETH) to prove
 * execution works, while gas is paid entirely in aPNTs via SuperPaymaster.
 *
 * Usage:
 *   pnpm tsx scripts/test-gasless-complete-e2e.ts
 */

import * as path from "path";
import { fileURLToPath } from "url";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  encodeAbiParameters,
  concat,
  pad,
  parseEther,
  formatEther,
  keccak256,
  toBytes,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import * as dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env.sepolia") });

// ─── Configuration ──────────────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = (process.env.PRIVATE_KEY_JASON ||
  process.env.PRIVATE_KEY!) as Hex;

// M3 deployment
const M3_ACCOUNT = "0x4bFf3539b73CA3a29d89C00C8c511b884211E31B" as Address;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// SuperPaymaster ecosystem
const SUPER_PAYMASTER =
  "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A" as Address;
const OPERATOR_ADDRESS =
  "0xb5600060e6de5E11D3636731964218E53caadf0E" as Address;
const APNTS_TOKEN =
  "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address;
const SBT_ADDRESS =
  "0x677423f5Dad98D19cAE8661c36F094289cb6171a" as Address;
const GTOKEN_ADDRESS =
  "0x9ceDeC089921652D050819ca5BE53765fc05aa9E" as Address;
const REGISTRY_ADDRESS =
  "0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788" as Address;

// Self-transfer amount (just to prove execution)
const SELF_TRANSFER_VALUE = parseEther("0.0001");

// ─── ABIs ────────────────────────────────────────────────────────────────────

const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function mint(address to, uint256 amount)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

const SBT_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function mint(address to)",
]);

const REGISTRY_ABI = parseAbi([
  "function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external returns (uint256)",
]);

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

// ─── Helpers ────────────────────────────────────────────────────────────────

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

function formatTokenAmount(raw: bigint, decimals: number): string {
  return (Number(raw) / 10 ** decimals).toFixed(4);
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("╔══════════════════════════════════════════════════════╗");
  console.log("║  AirAccount M3 — Complete Gasless E2E Test          ║");
  console.log("╚══════════════════════════════════════════════════════╝\n");

  // Validate environment
  if (!RPC_URL) throw new Error("SEPOLIA_RPC_URL not set in .env.sepolia");
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY or PRIVATE_KEY_JASON not set in .env.sepolia");

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
  console.log(`  M3 Account:       ${M3_ACCOUNT}`);
  console.log(`  SuperPaymaster:   ${SUPER_PAYMASTER}`);
  console.log(`  Operator:         ${OPERATOR_ADDRESS}`);
  console.log(`  aPNTs Token:      ${APNTS_TOKEN}`);
  console.log(`  SBT:              ${SBT_ADDRESS}`);
  console.log(`  Signer EOA:       ${signer.address}`);
  console.log(`  Self-transfer:    ${formatEther(SELF_TRANSFER_VALUE)} ETH\n`);

  // ════════════════════════════════════════════════════════════════════════════
  // Phase 1: Prepare Account
  // ════════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 1: Prepare Account ━━━\n");

  // Step 1.1: Check if M3 account is deployed
  console.log("Step 1.1: Check M3 account deployment");
  const accountCode = await publicClient.getCode({ address: M3_ACCOUNT });
  if (!accountCode || accountCode === "0x") {
    console.error("  FAIL: M3 account not deployed. Deploy it first.");
    process.exit(1);
  }
  console.log(`  OK: Account deployed (${accountCode.length / 2 - 1} bytes)\n`);

  // Step 1.2: Fund with SBT if not held
  console.log("Step 1.2: SBT (soul-bound identity token)");
  const sbtBalance = await publicClient.readContract({
    address: SBT_ADDRESS,
    abi: SBT_ABI,
    functionName: "balanceOf",
    args: [M3_ACCOUNT],
  });
  console.log(`  Current balance: ${sbtBalance}`);

  if (sbtBalance > 0n) {
    console.log("  OK: Already holds SBT\n");
  } else {
    console.log("  Minting SBT...");
    let sbtMinted = false;

    // Try Registry.safeMintForRole first
    try {
      const roleId = keccak256(toBytes("ENDUSER"));
      const roleData = encodeAbiParameters(
        [
          {
            type: "tuple",
            components: [
              { type: "address", name: "account" },
              { type: "address", name: "community" },
              { type: "string", name: "avatar" },
              { type: "string", name: "ens" },
              { type: "uint256", name: "stake" },
            ],
          },
        ],
        [[M3_ACCOUNT, signer.address, "", "", parseEther("0.3")]]
      );
      const hash = await walletClient.writeContract({
        address: REGISTRY_ADDRESS,
        abi: REGISTRY_ABI,
        functionName: "safeMintForRole",
        args: [roleId, M3_ACCOUNT, roleData],
      });
      console.log(`  tx (Registry): ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
      console.log("  OK: SBT minted via Registry\n");
      sbtMinted = true;
    } catch (e: any) {
      console.log(
        `  Registry.safeMintForRole() failed: ${e.shortMessage || e.message?.split("\n")[0]}`
      );
    }

    // Fallback: direct SBT.mint()
    if (!sbtMinted) {
      try {
        const hash = await walletClient.writeContract({
          address: SBT_ADDRESS,
          abi: SBT_ABI,
          functionName: "mint",
          args: [M3_ACCOUNT],
        });
        console.log(`  tx (direct): ${hash}`);
        await publicClient.waitForTransactionReceipt({ hash });
        console.log("  OK: SBT minted directly\n");
      } catch (e: any) {
        console.error(
          `  FAIL: Could not mint SBT: ${e.shortMessage || e.message?.split("\n")[0]}`
        );
        process.exit(1);
      }
    }
  }

  // Step 1.3: Fund with aPNTs if balance < 100
  console.log("Step 1.3: aPNTs (gas token for SuperPaymaster)");
  const apntsBalance = await publicClient.readContract({
    address: APNTS_TOKEN,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [M3_ACCOUNT],
  });
  const apntsDecimals = Number(
    await publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "decimals",
    })
  );
  console.log(
    `  Current balance: ${formatTokenAmount(apntsBalance, apntsDecimals)} aPNTs`
  );

  if (apntsBalance >= parseEther("100")) {
    console.log("  OK: Balance >= 100 aPNTs\n");
  } else {
    const mintAmount = parseEther("100");
    console.log("  Minting 100 aPNTs...");
    try {
      const hash = await walletClient.writeContract({
        address: APNTS_TOKEN,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [M3_ACCOUNT, mintAmount],
      });
      console.log(`  tx: ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
      const newBal = await publicClient.readContract({
        address: APNTS_TOKEN,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [M3_ACCOUNT],
      });
      console.log(
        `  OK: New balance: ${formatTokenAmount(newBal, apntsDecimals)} aPNTs\n`
      );
    } catch {
      console.log("  mint() unavailable, trying transfer()...");
      const hash = await walletClient.writeContract({
        address: APNTS_TOKEN,
        abi: ERC20_ABI,
        functionName: "transfer",
        args: [M3_ACCOUNT, mintAmount],
      });
      console.log(`  tx: ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
      console.log("  OK: aPNTs transferred\n");
    }
  }

  // Step 1.4: Fund with ETH if balance < 0.001
  console.log("Step 1.4: ETH (for self-transfer value)");
  const ethBalance = await publicClient.getBalance({ address: M3_ACCOUNT });
  console.log(`  Current balance: ${formatEther(ethBalance)} ETH`);

  if (ethBalance >= parseEther("0.001")) {
    console.log("  OK: Balance >= 0.001 ETH\n");
  } else {
    console.log("  Sending 0.002 ETH...");
    const hash = await walletClient.sendTransaction({
      to: M3_ACCOUNT,
      value: parseEther("0.002"),
    });
    console.log(`  tx: ${hash}`);
    await publicClient.waitForTransactionReceipt({ hash });
    const newEth = await publicClient.getBalance({ address: M3_ACCOUNT });
    console.log(`  OK: New balance: ${formatEther(newEth)} ETH\n`);
  }

  // Step 1.5: Check paymaster deposit
  console.log("Step 1.5: SuperPaymaster EntryPoint deposit");
  const pmDeposit = await publicClient.readContract({
    address: SUPER_PAYMASTER,
    abi: PAYMASTER_ABI,
    functionName: "getDeposit",
  });
  console.log(`  Deposit: ${formatEther(pmDeposit as bigint)} ETH`);
  if ((pmDeposit as bigint) < parseEther("0.01")) {
    console.warn("  WARNING: Low paymaster deposit (<0.01 ETH)");
    console.warn("  The gasless UserOp may fail with AA31.\n");
  } else {
    console.log("  OK: Deposit sufficient\n");
  }

  // Step 1.6: Check/refresh price cache
  console.log("Step 1.6: Price cache freshness");
  const [cachedPrice, stalenessThreshold] = await Promise.all([
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
  const priceData = cachedPrice as readonly [bigint, bigint, bigint, number];
  const threshold = BigInt(stalenessThreshold as bigint | number);
  const validUntil = BigInt(priceData[1]) + threshold;
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
    const ethUsd = Number(priceData[0]) / 1e8;
    const remainingSec = Number(validUntil - nowSec);
    console.log(
      `  OK: ETH/USD = $${ethUsd.toFixed(2)}, valid for ${remainingSec}s\n`
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Phase 2: Build Gasless UserOp
  // ════════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 2: Build Gasless UserOp ━━━\n");

  // Build execute(self, 0.0001 ETH, 0x) — self-transfer to prove execution
  console.log("Step 2.1: Build callData");
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
    args: [M3_ACCOUNT, SELF_TRANSFER_VALUE, "0x"],
  });
  console.log(`  Action: execute(self, ${formatEther(SELF_TRANSFER_VALUE)} ETH, 0x)`);
  console.log(`  callData: ${executeCalldata.slice(0, 20)}... (${(executeCalldata.length - 2) / 2} bytes)\n`);

  // Get nonce
  console.log("Step 2.2: Get nonce");
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [M3_ACCOUNT, 0n],
  });
  console.log(`  Nonce: ${nonce}\n`);

  // Build paymasterAndData (72 bytes)
  // [0:20]  SuperPaymaster address
  // [20:36] paymasterVerificationGasLimit (uint128) = 250,000
  // [36:52] paymasterPostOpGasLimit (uint128) = 50,000
  // [52:72] Operator address
  console.log("Step 2.3: Build paymasterAndData");
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
  console.log(`  Length: ${(paymasterAndData.length - 2) / 2} bytes`);
  console.log(`  Paymaster: ${SUPER_PAYMASTER}`);
  console.log(`  PM verify gas: ${paymasterVerificationGas}`);
  console.log(`  PM postOp gas: ${paymasterPostOpGas}`);
  console.log(`  Operator: ${OPERATOR_ADDRESS}\n`);

  // Pack gas limits
  const verificationGasLimit = 150000n;
  const callGasLimit = 100000n;
  const maxPriorityFeePerGas = 2000000000n; // 2 gwei
  const maxFeePerGas = 3000000000n; // 3 gwei

  const accountGasLimits = packUint128(verificationGasLimit, callGasLimit);
  const gasFees = packUint128(maxPriorityFeePerGas, maxFeePerGas);

  console.log("Step 2.4: Gas parameters");
  console.log(`  verificationGasLimit: ${verificationGasLimit}`);
  console.log(`  callGasLimit: ${callGasLimit}`);
  console.log(`  preVerificationGas: 50000`);
  console.log(`  maxPriorityFee: ${maxPriorityFeePerGas / 1000000000n} gwei`);
  console.log(`  maxFee: ${maxFeePerGas / 1000000000n} gwei\n`);

  const userOp = {
    sender: M3_ACCOUNT,
    nonce,
    initCode: "0x" as Hex,
    callData: executeCalldata,
    accountGasLimits,
    preVerificationGas: 50000n,
    gasFees,
    paymasterAndData,
    signature: "0x" as Hex,
  };

  // Sign UserOperation
  console.log("Step 2.5: Sign UserOperation");
  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  });
  console.log(`  UserOpHash: ${userOpHash}`);

  const signature = await signer.signMessage({
    message: { raw: userOpHash as Hex },
  });
  userOp.signature = signature;
  console.log(
    `  Signature: ${signature.slice(0, 20)}... (${(signature.length - 2) / 2} bytes)\n`
  );

  // ════════════════════════════════════════════════════════════════════════════
  // Phase 3: Submit & Verify
  // ════════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 3: Submit & Verify ━━━\n");

  // Record balances before
  console.log("Step 3.1: Record balances before");
  const [ethBefore, apntsBefore] = await Promise.all([
    publicClient.getBalance({ address: M3_ACCOUNT }),
    publicClient.readContract({
      address: APNTS_TOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [M3_ACCOUNT],
    }),
  ]);
  console.log(`  ETH:   ${formatEther(ethBefore)}`);
  console.log(`  aPNTs: ${formatTokenAmount(apntsBefore, apntsDecimals)}\n`);

  // Submit handleOps
  console.log("Step 3.2: Submit handleOps");
  try {
    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], signer.address],
      gas: 2000000n,
    });

    console.log(`  TX: ${txHash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${txHash}\n`);
    console.log("  Waiting for confirmation...");

    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
    });

    if (receipt.status !== "success") {
      console.error("  FAIL: Transaction reverted on-chain.");
      process.exit(1);
    }

    console.log(`  Confirmed in block ${receipt.blockNumber}`);
    console.log(`  Gas used (bundler): ${receipt.gasUsed}\n`);

    // Record balances after
    console.log("Step 3.3: Verify balances after");
    const [ethAfter, apntsAfter] = await Promise.all([
      publicClient.getBalance({ address: M3_ACCOUNT }),
      publicClient.readContract({
        address: APNTS_TOKEN,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [M3_ACCOUNT],
      }),
    ]);

    const ethDiff = ethBefore - ethAfter;
    const apntsDiff = apntsBefore - apntsAfter;

    console.log(`  ETH before:   ${formatEther(ethBefore)}`);
    console.log(`  ETH after:    ${formatEther(ethAfter)}`);
    console.log(`  ETH change:   ${ethDiff === 0n ? "0 (ZERO COST)" : formatEther(ethDiff)}`);
    console.log();
    console.log(`  aPNTs before: ${formatTokenAmount(apntsBefore, apntsDecimals)}`);
    console.log(`  aPNTs after:  ${formatTokenAmount(apntsAfter, apntsDecimals)}`);
    console.log(
      `  aPNTs cost:   ${formatTokenAmount(apntsDiff, apntsDecimals)} aPNTs (gas fee)\n`
    );

    // Verify: ETH balance should be unchanged (self-transfer is net zero)
    // The self-transfer sends 0.0001 ETH to itself, so net ETH change = 0
    console.log("Step 3.4: Gas analysis");
    console.log(`  Bundler gas used: ${receipt.gasUsed}`);
    console.log(`  Gas paid by:      ${receipt.from} (EOA bundler)`);
    console.log(`  AA account ETH:   ${ethDiff === 0n ? "UNCHANGED (gasless!)" : `decreased by ${formatEther(ethDiff)} ETH`}`);

    if (apntsDiff > 0n) {
      // Estimate equivalent ETH cost from price feed
      const priceNow = await publicClient.readContract({
        address: SUPER_PAYMASTER,
        abi: PAYMASTER_ABI,
        functionName: "cachedPrice",
      });
      const priceArr = priceNow as [bigint, bigint, bigint, number];
      const ethUsd = Number(priceArr[0]) / 1e8;
      // aPNTs is pegged 1:1 to USD conceptually
      const apntsCostUsd = Number(apntsDiff) / 10 ** apntsDecimals;
      const equivalentEth = apntsCostUsd / ethUsd;
      console.log(`  aPNTs deducted:   ${formatTokenAmount(apntsDiff, apntsDecimals)}`);
      console.log(`  ETH/USD price:    $${ethUsd.toFixed(2)}`);
      console.log(`  Equivalent ETH:   ~${equivalentEth.toFixed(6)} ETH`);
    }

    // Final verdict
    console.log();
    if (ethDiff === 0n) {
      console.log("╔══════════════════════════════════════════════════════╗");
      console.log("║  GASLESS E2E TEST: PASSED                          ║");
      console.log("║                                                      ║");
      console.log("║  M3 account executed a self-transfer with ZERO ETH  ║");
      console.log("║  gas cost. Gas was paid in aPNTs via SuperPaymaster. ║");
      console.log("╚══════════════════════════════════════════════════════╝");
    } else {
      console.log("╔══════════════════════════════════════════════════════╗");
      console.log("║  GASLESS E2E TEST: PARTIAL                          ║");
      console.log("║                                                      ║");
      console.log(`║  ETH changed by ${formatEther(ethDiff).padEnd(38)}║`);
      console.log("║  This may indicate paymaster didn't cover all gas.   ║");
      console.log("╚══════════════════════════════════════════════════════╝");
    }

    console.log(`\nTX: https://sepolia.etherscan.io/tx/${txHash}`);
  } catch (error: any) {
    console.error("\nUserOp FAILED\n");
    const msg = error.message || String(error);

    // AA error code explanations
    if (msg.includes("AA93")) {
      console.error("Error: AA93 — Paymaster validation failed");
      console.error("  Possible causes:");
      console.error("  - AA account does not hold MySBT");
      console.error("  - AA account has insufficient aPNTs balance");
      console.error("  - aPNTs allowance not set for SuperPaymaster");
    } else if (msg.includes("AA33")) {
      console.error("Error: AA33 — Paymaster internal validation failed");
      console.error("  Possible causes:");
      console.error("  - Operator address not registered in SuperPaymaster");
      console.error("  - Operator suspended or revoked");
    } else if (msg.includes("AA31")) {
      console.error("Error: AA31 — Paymaster deposit too low");
      console.error("  The SuperPaymaster needs more ETH deposited in EntryPoint.");
      console.error(`  Current deposit: ${formatEther(pmDeposit as bigint)} ETH`);
    } else if (msg.includes("AA25")) {
      console.error("Error: AA25 — Invalid account nonce");
      console.error(`  Expected nonce: ${nonce}`);
      console.error("  The account may have a pending UserOp or nonce mismatch.");
    } else if (msg.includes("OutstandingDebt")) {
      console.error("Error: Outstanding debt — user must clear debt first");
    } else {
      console.error("Error:", msg.slice(0, 500));
    }

    process.exit(1);
  }

  console.log("\n=== Complete Gasless E2E Test Finished ===");
}

main().catch((err) => {
  console.error("\nFatal error:", err.shortMessage || err.message || err);
  process.exit(1);
});
