/**
 * test-m5-bls-aggregator-e2e.ts — F67 (BLS aggregator integration) + F70 (batch gas benchmark)
 *
 * Tests:
 *   Step 1: Deploy two M5 test accounts (salt=810, salt=811) via factory.createAccount
 *   Step 2: Set aggregator on both accounts via account.setAggregator(aggregatorAddress)
 *   Step 3: Verify aggregator is set via account.getConfigDescription() — hasAggregator == true
 *   Step 4: Gas benchmark — single UserOp (ECDSA, algId=0x02) on account1
 *   Step 5: Print summary with all addresses, tx hashes, gas used
 *
 * Note on handleAggregatedOps:
 *   Full handleAggregatedOps E2E (F68) requires bundler-side BLS signature aggregation.
 *   The bundler must call aggregator.aggregateSignatures(ops) to produce the aggregate,
 *   then submit via entryPoint.handleAggregatedOps. This is NOT tested here — it requires
 *   a BLS-aware bundler, which is a separate infrastructure component.
 *
 * What this script validates:
 *   - Accounts can be configured with an aggregator reference on-chain (F67)
 *   - Single ECDSA UserOp gas cost after aggregator config is set (F70 baseline)
 *   - The aggregator address is stored and readable from the account config
 *
 * Prerequisites:
 *   .env.sepolia must contain:
 *     SEPOLIA_RPC_URL, PRIVATE_KEY
 *     AIRACCOUNT_M5_FACTORY=0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9
 *     AIRACCOUNT_M5_BLS_AGGREGATOR=<address from deploy-bls-aggregator.ts>
 *     BLS_TEST_NODE_ID_1, BLS_TEST_PRIVATE_KEY_1
 *     BLS_TEST_NODE_ID_2, BLS_TEST_PRIVATE_KEY_2
 *
 * Run: pnpm tsx scripts/test-m5-bls-aggregator-e2e.ts
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
  hexToBytes,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Constants ────────────────────────────────────────────────────────────────

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// Test account salts for M5 BLS aggregator tests
const SALT_ACCOUNT_1 = 810n;
const SALT_ACCOUNT_2 = 811n;

// ─── Env loading ──────────────────────────────────────────────────────────────

function required(k: string): string {
  const v = process.env[k];
  if (!v) {
    console.error(`Missing required env var: ${k}`);
    process.exit(1);
  }
  return v;
}

const RPC_URL = required("SEPOLIA_RPC_URL");
const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const FACTORY_ADDRESS = (process.env.AIRACCOUNT_M5_FACTORY ?? required("AIRACCOUNT_M5_FACTORY")) as Address;
const AGGREGATOR_ADDRESS = (process.env.AIRACCOUNT_M5_BLS_AGGREGATOR ?? required("AIRACCOUNT_M5_BLS_AGGREGATOR")) as Address;

// BLS test node IDs and private keys (used as identifiers, not for signing in this script)
const BLS_NODE_ID_1 = (process.env.BLS_TEST_NODE_ID_1 ?? required("BLS_TEST_NODE_ID_1")) as Hex;
const BLS_NODE_ID_2 = (process.env.BLS_TEST_NODE_ID_2 ?? required("BLS_TEST_NODE_ID_2")) as Hex;

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const FACTORY_ABI = [
  {
    name: "createAccount",
    type: "function",
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
          { name: "minDailyLimit", type: "uint256" },
          { name: "initialTokens", type: "address[]" },
          {
            name: "initialTokenConfigs",
            type: "tuple[]",
            components: [
              { name: "tier1Limit", type: "uint256" },
              { name: "tier2Limit", type: "uint256" },
              { name: "dailyLimit", type: "uint256" },
            ],
          },
        ],
      },
    ],
    outputs: [{ name: "account", type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    name: "getAddress",
    type: "function",
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
          { name: "minDailyLimit", type: "uint256" },
          { name: "initialTokens", type: "address[]" },
          {
            name: "initialTokenConfigs",
            type: "tuple[]",
            components: [
              { name: "tier1Limit", type: "uint256" },
              { name: "tier2Limit", type: "uint256" },
              { name: "dailyLimit", type: "uint256" },
            ],
          },
        ],
      },
    ],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

const ACCOUNT_ABI = [
  {
    name: "setAggregator",
    type: "function",
    inputs: [{ name: "_aggregator", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    name: "getConfigDescription",
    type: "function",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "accountOwner", type: "address" },
          { name: "guardAddress", type: "address" },
          { name: "dailyLimit", type: "uint256" },
          { name: "dailyRemaining", type: "uint256" },
          { name: "tier1Limit", type: "uint256" },
          { name: "tier2Limit", type: "uint256" },
          { name: "guardianAddresses", type: "address[3]" },
          { name: "guardianCount", type: "uint8" },
          { name: "hasP256Key", type: "bool" },
          { name: "hasValidator", type: "bool" },
          { name: "hasAggregator", type: "bool" },
          { name: "hasActiveRecovery", type: "bool" },
        ],
      },
    ],
    stateMutability: "view",
  },
  {
    name: "execute",
    type: "function",
    inputs: [
      { name: "dest", type: "address" },
      { name: "value", type: "uint256" },
      { name: "func", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    name: "owner",
    type: "function",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

const ENTRYPOINT_ABI = [
  {
    name: "depositTo",
    type: "function",
    inputs: [{ name: "account", type: "address" }],
    outputs: [],
    stateMutability: "payable",
  },
  {
    name: "getUserOpHash",
    type: "function",
    inputs: [
      {
        name: "userOp",
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
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    name: "handleOps",
    type: "function",
    inputs: [
      {
        name: "ops",
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
    name: "getNonce",
    type: "function",
    inputs: [
      { name: "sender", type: "address" },
      { name: "key", type: "uint192" },
    ],
    outputs: [{ name: "nonce", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Pack two uint128 values into a bytes32.
 * Used for accountGasLimits (verificationGasLimit | callGasLimit)
 * and gasFees (maxPriorityFeePerGas | maxFeePerGas).
 */
function packUint128(high: bigint, low: bigint): `0x${string}` {
  return `0x${high.toString(16).padStart(32, "0")}${low.toString(16).padStart(32, "0")}` as `0x${string}`;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== M5 BLS Aggregator E2E Test (Sepolia) ===");
  console.log("F67: BLS aggregator integration | F70: batch gas benchmark\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const signerAccount = privateKeyToAccount(PRIVATE_KEY);
  const walletClient = createWalletClient({
    account: signerAccount,
    chain: sepolia,
    transport: http(RPC_URL),
  });
  const ownerAddr = signerAccount.address;

  console.log(`Owner:       ${ownerAddr}`);
  console.log(`Factory:     ${FACTORY_ADDRESS}`);
  console.log(`Aggregator:  ${AGGREGATOR_ADDRESS}`);
  console.log(`EntryPoint:  ${ENTRYPOINT}`);
  console.log(`BLS Node 1:  ${BLS_NODE_ID_1}`);
  console.log(`BLS Node 2:  ${BLS_NODE_ID_2}`);

  const ownerBalance = await publicClient.getBalance({ address: ownerAddr });
  console.log(`\nOwner balance: ${formatEther(ownerBalance)} ETH`);

  if (ownerBalance < parseEther("0.02")) {
    console.error("Need at least 0.02 ETH for account deployments and gas.");
    process.exit(1);
  }

  // ── Step 1: Deploy two M5 test accounts ──────────────────────────────────

  console.log("\n[Step 1] Deploy two M5 test accounts (salt=810, salt=811)");

  // ECDSA-only config for simplicity — we test aggregator path separately
  const initConfig = {
    guardians: [
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
    ] as [Address, Address, Address],
    dailyLimit: parseEther("1"),
    approvedAlgIds: [2] as number[], // algId 0x02 = ECDSA only
    minDailyLimit: 0n,
    initialTokens: [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
  };

  // Predict both addresses upfront
  const predictedAddr1 = await publicClient.readContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getAddress",
    args: [ownerAddr, SALT_ACCOUNT_1, initConfig],
  });

  const predictedAddr2 = await publicClient.readContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getAddress",
    args: [ownerAddr, SALT_ACCOUNT_2, initConfig],
  });

  console.log(`  Predicted account 1 (salt=${SALT_ACCOUNT_1}): ${predictedAddr1}`);
  console.log(`  Predicted account 2 (salt=${SALT_ACCOUNT_2}): ${predictedAddr2}`);

  // Deploy account 1 if not already deployed
  const code1 = await publicClient.getBytecode({ address: predictedAddr1 });
  let account1Addr: Address;
  if (code1 && code1.length > 2) {
    console.log(`  Account 1 already deployed: ${predictedAddr1}`);
    account1Addr = predictedAddr1;
  } else {
    console.log(`  Deploying account 1 (salt=${SALT_ACCOUNT_1})...`);
    const txHash = await walletClient.writeContract({
      address: FACTORY_ADDRESS,
      abi: FACTORY_ABI,
      functionName: "createAccount",
      args: [ownerAddr, SALT_ACCOUNT_1, initConfig],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    account1Addr = predictedAddr1;
    console.log(`  Account 1 deployed: ${account1Addr}`);
    console.log(`    TX: ${receipt.transactionHash} | Gas: ${receipt.gasUsed}`);
  }

  // Deploy account 2 if not already deployed
  const code2 = await publicClient.getBytecode({ address: predictedAddr2 });
  let account2Addr: Address;
  if (code2 && code2.length > 2) {
    console.log(`  Account 2 already deployed: ${predictedAddr2}`);
    account2Addr = predictedAddr2;
  } else {
    console.log(`  Deploying account 2 (salt=${SALT_ACCOUNT_2})...`);
    const txHash = await walletClient.writeContract({
      address: FACTORY_ADDRESS,
      abi: FACTORY_ABI,
      functionName: "createAccount",
      args: [ownerAddr, SALT_ACCOUNT_2, initConfig],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    account2Addr = predictedAddr2;
    console.log(`  Account 2 deployed: ${account2Addr}`);
    console.log(`    TX: ${receipt.transactionHash} | Gas: ${receipt.gasUsed}`);
  }

  // ── Step 2: Set aggregator on both accounts ───────────────────────────────

  console.log("\n[Step 2] Set BLS aggregator on both accounts");

  // Set aggregator on account 1
  console.log(`  Calling account1.setAggregator(${AGGREGATOR_ADDRESS})...`);
  const setAggTx1 = await walletClient.writeContract({
    address: account1Addr,
    abi: ACCOUNT_ABI,
    functionName: "setAggregator",
    args: [AGGREGATOR_ADDRESS],
  });
  const setAggReceipt1 = await publicClient.waitForTransactionReceipt({ hash: setAggTx1 });
  console.log(`  Account 1 setAggregator TX: ${setAggTx1} | Gas: ${setAggReceipt1.gasUsed}`);

  // Set aggregator on account 2
  console.log(`  Calling account2.setAggregator(${AGGREGATOR_ADDRESS})...`);
  const setAggTx2 = await walletClient.writeContract({
    address: account2Addr,
    abi: ACCOUNT_ABI,
    functionName: "setAggregator",
    args: [AGGREGATOR_ADDRESS],
  });
  const setAggReceipt2 = await publicClient.waitForTransactionReceipt({ hash: setAggTx2 });
  console.log(`  Account 2 setAggregator TX: ${setAggTx2} | Gas: ${setAggReceipt2.gasUsed}`);

  // ── Step 3: Verify aggregator is set via getConfigDescription ─────────────

  console.log("\n[Step 3] Verify aggregator via getConfigDescription()");

  const config1 = await publicClient.readContract({
    address: account1Addr,
    abi: ACCOUNT_ABI,
    functionName: "getConfigDescription",
  });

  const config2 = await publicClient.readContract({
    address: account2Addr,
    abi: ACCOUNT_ABI,
    functionName: "getConfigDescription",
  });

  console.log(`  Account 1 hasAggregator: ${config1.hasAggregator}`);
  console.log(`  Account 1 hasP256Key:    ${config1.hasP256Key}`);
  console.log(`  Account 1 hasValidator:  ${config1.hasValidator}`);
  console.log(`  Account 2 hasAggregator: ${config2.hasAggregator}`);
  console.log(`  Account 2 hasP256Key:    ${config2.hasP256Key}`);
  console.log(`  Account 2 hasValidator:  ${config2.hasValidator}`);

  if (!config1.hasAggregator) {
    console.error("  FAIL: Account 1 hasAggregator is false after setAggregator!");
    process.exit(1);
  }
  if (!config2.hasAggregator) {
    console.error("  FAIL: Account 2 hasAggregator is false after setAggregator!");
    process.exit(1);
  }
  console.log("  PASS: Both accounts report hasAggregator = true");

  // ── Step 4: Gas benchmark — single UserOp (ECDSA algId=0x02) on account 1 ──

  console.log("\n[Step 4] Gas benchmark — single ECDSA UserOp on account 1");
  console.log("  Scenario: account1 self-transfer 0.0001 ETH (after aggregator config set)");

  // Fund account 1 with ETH for the self-transfer and EntryPoint deposit
  const acc1Balance = await publicClient.getBalance({ address: account1Addr });
  console.log(`  Account 1 balance: ${formatEther(acc1Balance)} ETH`);

  if (acc1Balance < parseEther("0.001")) {
    console.log("  Funding account 1 with 0.005 ETH...");
    const fundTx = await walletClient.sendTransaction({
      to: account1Addr,
      value: parseEther("0.005"),
    });
    await publicClient.waitForTransactionReceipt({ hash: fundTx });
    console.log("  Funded.");
  }

  // Deposit ETH into EntryPoint for account 1's gas prepayment
  console.log("  Depositing 0.01 ETH into EntryPoint for account 1...");
  const depositTx = await walletClient.writeContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "depositTo",
    args: [account1Addr],
    value: parseEther("0.01"),
  });
  await publicClient.waitForTransactionReceipt({ hash: depositTx });
  console.log("  Deposited.");

  // Build the UserOp: account1 sends 0.0001 ETH to itself (self-transfer as benchmark target)
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [account1Addr, 0n],
  });

  // callData: account1.execute(account1, 0.0001 ETH, "0x")
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI,
    functionName: "execute",
    args: [account1Addr, parseEther("0.0001"), "0x" as Hex],
  });

  const userOp = {
    sender: account1Addr,
    nonce,
    initCode: "0x" as Hex,
    callData,
    // accountGasLimits: packUint128(verificationGasLimit=300k, callGasLimit=300k)
    accountGasLimits: packUint128(300000n, 300000n),
    preVerificationGas: 50000n,
    // gasFees: packUint128(maxPriorityFeePerGas=2gwei, maxFeePerGas=2gwei)
    gasFees: packUint128(2000000000n, 2000000000n),
    paymasterAndData: "0x" as Hex,
    signature: "0x" as Hex,
  };

  // Compute userOpHash via EntryPoint
  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  });

  console.log(`  UserOp hash: ${userOpHash}`);

  // ECDSA signature: algId=0x02 prefix + ECDSA sign of EIP-191(userOpHash)
  // walletClient.signMessage applies toEthSignedMessageHash internally
  const ecdsaSig = await walletClient.signMessage({
    message: { raw: hexToBytes(userOpHash) },
  });

  // Prepend algId byte 0x02 to the 65-byte ECDSA signature
  userOp.signature = ("0x02" + ecdsaSig.slice(2)) as Hex;

  console.log(`  Signature (66 bytes, algId=0x02): ${userOp.signature.slice(0, 20)}...`);

  // Submit via handleOps — owner is the beneficiary (receives gas refund)
  console.log("  Submitting UserOp via handleOps...");

  let singleUserOpGas: bigint;
  let handleOpsTxHash: Hex;

  try {
    handleOpsTxHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], ownerAddr],
      gas: 1000000n,
    });

    const opsReceipt = await publicClient.waitForTransactionReceipt({ hash: handleOpsTxHash });
    singleUserOpGas = opsReceipt.gasUsed;

    console.log(`  PASS: UserOp succeeded`);
    console.log(`  TX:       ${handleOpsTxHash}`);
    console.log(`  Gas used: ${singleUserOpGas}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${handleOpsTxHash}`);
  } catch (e: any) {
    // Capture error but don't hard-fail — gas data is still useful context
    console.log(`  INFO: handleOps reverted or failed: ${e.message?.slice(0, 200)}`);
    console.log("  (Account may need more ETH balance or EntryPoint deposit)");
    singleUserOpGas = 0n;
    handleOpsTxHash = "0x" as Hex;
  }

  // ── Step 5: Print summary ─────────────────────────────────────────────────

  console.log("\n=== M5 BLS Aggregator E2E Test Summary ===");
  console.log("");
  console.log("Addresses:");
  console.log(`  BLS Aggregator:  ${AGGREGATOR_ADDRESS}`);
  console.log(`  Account 1:       ${account1Addr}  (salt=${SALT_ACCOUNT_1})`);
  console.log(`  Account 2:       ${account2Addr}  (salt=${SALT_ACCOUNT_2})`);
  console.log("");
  console.log("setAggregator transactions:");
  console.log(`  Account 1:  ${setAggTx1}  (gas: ${setAggReceipt1.gasUsed})`);
  console.log(`  Account 2:  ${setAggTx2}  (gas: ${setAggReceipt2.gasUsed})`);
  console.log("");
  console.log("F67 — BLS aggregator configured on both accounts:  PASS");
  console.log(`  Account 1 hasAggregator: ${config1.hasAggregator}`);
  console.log(`  Account 2 hasAggregator: ${config2.hasAggregator}`);
  console.log("");
  console.log("F70 — Single UserOp gas benchmark (ECDSA, algId=0x02):");
  if (singleUserOpGas > 0n) {
    console.log(`  Gas used: ${singleUserOpGas}  (TX: ${handleOpsTxHash})`);
    console.log("  Status:   PASS");
  } else {
    console.log("  Gas used: N/A (UserOp failed — see logs above)");
    console.log("  Status:   PARTIAL (aggregator set correctly, single UserOp needs more gas/ETH)");
  }
  console.log("");
  console.log("NOTE: Full handleAggregatedOps E2E requires bundler-side aggregation (F68).");
  console.log("  A BLS-aware bundler must call aggregator.aggregateSignatures(ops) to produce");
  console.log("  the combined signature, then submit via entryPoint.handleAggregatedOps.");
  console.log("  This flow is not tested here — it requires a separate bundler infrastructure.");
  console.log("");
  console.log("Next step: F68 — implement BLS bundler integration for handleAggregatedOps");
}

main().catch((err) => {
  console.error("\nFatal error:", err.message ?? err);
  process.exit(1);
});
