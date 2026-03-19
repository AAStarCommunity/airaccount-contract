/**
 * test-e2e-ecdsa.ts
 *
 * Complete E2E: deploy Factory, create account, build UserOp, sign with ECDSA,
 * submit via EntryPoint v0.7 handleOps on Sepolia.
 *
 * Run via:  bash test-e2e-ecdsa.sh   (from project root)
 *
 * Flow:
 *   1. Connect to Sepolia, check deployer balance
 *   2. Deploy or reuse AAStarAirAccountFactoryV7
 *   3. Create account via factory.createAccount(signer, 0)
 *   4. Fund account's EntryPoint deposit if needed
 *   5. Build UserOp: account.execute(recipient, 0.001 ETH, "0x")
 *   6. Get userOpHash from EntryPoint, ECDSA-sign it
 *   7. Submit handleOps() and verify result
 *
 * Uses viem only (no ethers.js)
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  parseGwei,
  encodeFunctionData,
  encodePacked,
  toHex,
  hexToBytes,
  fromHex,
  keccak256,
  concat,
  getAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { readFileSync, existsSync } from "fs";
import { resolve } from "path";
import { fileURLToPath } from "url";

// ─── Config from environment ─────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) {
    console.error(`Missing env: ${k}`);
    process.exit(1);
  }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY") as `0x${string}`;
const RPC_URL = (process.env.SEPOLIA_RPC ?? required("SEPOLIA_RPC")) as string;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const FACTORY_ADDRESS = process.env.FACTORY_ADDRESS || "";
const DRY_RUN = !!process.env.DRY_RUN;

// Transfer recipient: if not set, send to self (harmless round-trip)
const RECIPIENT =
  process.env.RECIPIENT || "0x000000000000000000000000000000000000dEaD";
const TRANSFER_AMOUNT = parseEther("0.001");

// ─── ABIs (inline fragments) ─────────────────────────────────────────────────

const ENTRYPOINT_ABI = [
  {
    name: "handleOps",
    type: "function",
    stateMutability: "nonpayable",
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
  },
  {
    name: "getUserOpHash",
    type: "function",
    stateMutability: "view",
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
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "getNonce",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "sender", type: "address" },
      { name: "key", type: "uint192" },
    ],
    outputs: [{ name: "nonce", type: "uint256" }],
  },
] as const;

const FACTORY_ABI = [
  {
    name: "createAccount",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
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
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "entryPoint",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
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
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "entryPoint",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "getDeposit",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "addDeposit",
    type: "function",
    stateMutability: "payable",
    inputs: [],
    outputs: [],
  },
] as const;

// ─── Helper Functions ────────────────────────────────────────────────────────

// EIP-191 personal sign: sign keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)
async function signMessageEIP191(account: ReturnType<typeof privateKeyToAccount>, messageHash: `0x${string}`): Promise<`0x${string}`> {
  // messageHash is 32 bytes, so len = 32
  const prefix = `\x19Ethereum Signed Message:\n32`;
  const prefixBytes = new TextEncoder().encode(prefix);
  const messageBytes = hexToBytes(messageHash);
  const fullMessage = concat([prefixBytes, messageBytes]);
  const fullHash = keccak256(fullMessage);
  
  const signature = await account.signMessage({
    message: { raw: hexToBytes(fullHash) },
  });
  
  return signature;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("+===========================================+");
  console.log("|  AirAccount V7 ECDSA E2E Test -- Sepolia  |");
  console.log("+===========================================+\n");

  // Setup viem clients
  const account = privateKeyToAccount(PRIVATE_KEY);
  
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(RPC_URL),
  });
  
  const walletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(RPC_URL),
  });

  const chainId = await publicClient.getChainId();
  const balance = await publicClient.getBalance({ address: account.address });
  
  console.log(`Network     : Sepolia (chainId: ${chainId})`);
  console.log(`Signer      : ${account.address}`);
  console.log(`Balance     : ${formatEther(balance)} ETH`);
  console.log(`Recipient   : ${RECIPIENT}`);
  console.log(`Dry-run     : ${DRY_RUN}\n`);

  if (balance < parseEther("0.01")) {
    console.error(
      "ERROR: Signer balance too low. Need at least 0.01 ETH on Sepolia."
    );
    process.exit(1);
  }

  // ── Step 1: Deploy or reuse Factory ──────────────────────────────────────
  console.log("[ 1 ] Factory setup...");
  let factoryAddr: `0x${string}`;

  if (FACTORY_ADDRESS) {
    factoryAddr = FACTORY_ADDRESS as `0x${string}`;
    const code = await publicClient.getBytecode({ address: factoryAddr });
    if (!code || code === "0x") {
      console.error(
        `  ERROR: No contract at FACTORY_ADDRESS=${factoryAddr}`
      );
      process.exit(1);
    }
    console.log(`  Using existing factory: ${factoryAddr}`);
  } else {
    console.log("  No FACTORY_ADDRESS set, deploying new factory...");

    // Read compiled bytecode from Foundry artifacts
    const __dirname = fileURLToPath(new URL(".", import.meta.url));
    const artifactPath = resolve(
      __dirname,
      "../out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json"
    );

    if (!existsSync(artifactPath)) {
      console.error(
        "  ERROR: Foundry artifacts not found. Run 'forge build' first."
      );
      console.error(`  Expected: ${artifactPath}`);
      process.exit(1);
    }

    const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
    const factoryBytecode = artifact.bytecode.object as `0x${string}`;
    const factoryAbi = artifact.abi;

    console.log("  Deploying AAStarAirAccountFactoryV7...");
    
    // Encode constructor args: entryPoint address
    const constructorArgs = encodePacked(
      ["address"],
      [ENTRYPOINT]
    );
    const deployBytecode = concat([factoryBytecode, constructorArgs]) as `0x${string}`;
    
    const hash = await walletClient.sendTransaction({
      data: deployBytecode,
    });
    
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    factoryAddr = receipt.contractAddress!;
    
    console.log(`  Factory deployed at: ${factoryAddr}`);
    console.log(
      `  https://sepolia.etherscan.io/address/${factoryAddr}\n`
    );
    console.log(`  TIP: Set FACTORY_ADDRESS=${factoryAddr} in .env to reuse\n`);
  }

  // ── Step 2: Create account ───────────────────────────────────────────────
  console.log("[ 2 ] Create account via factory...");
  
  const predictedAddr = await publicClient.readContract({
    address: factoryAddr,
    abi: FACTORY_ABI,
    functionName: "getAddress",
    args: [account.address, 0n],
  });
  
  console.log(`  Predicted address: ${predictedAddr}`);

  const existingCode = await publicClient.getBytecode({ address: predictedAddr });
  let accountAddr: `0x${string}`;

  if (existingCode && existingCode !== "0x") {
    console.log("  Account already deployed (reusing).");
    accountAddr = predictedAddr;
  } else {
    console.log("  Deploying new account...");
    const hash = await walletClient.writeContract({
      address: factoryAddr,
      abi: FACTORY_ABI,
      functionName: "createAccount",
      args: [account.address, 0n],
    });
    
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    accountAddr = predictedAddr;
    console.log(`  Account deployed in tx: ${hash}`);
    console.log(
      `  https://sepolia.etherscan.io/tx/${hash}`
    );
  }

  const accountOwner = await publicClient.readContract({
    address: accountAddr,
    abi: ACCOUNT_ABI,
    functionName: "owner",
  });
  
  console.log(`  Account address : ${accountAddr}`);
  console.log(`  Account owner   : ${accountOwner}`);

  if (accountOwner.toLowerCase() !== account.address.toLowerCase()) {
    console.error("  ERROR: Account owner mismatch!");
    process.exit(1);
  }
  console.log("  Owner verified.\n");

  // ── Step 3: Fund EntryPoint deposit ──────────────────────────────────────
  console.log("[ 3 ] EntryPoint deposit...");
  
  const deposit = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "balanceOf",
    args: [accountAddr],
  });
  
  const minDeposit = parseEther("0.005");
  console.log(`  Current deposit: ${formatEther(deposit)} ETH`);

  if (deposit < minDeposit && !DRY_RUN) {
    const topUp = parseEther("0.01");
    console.log(`  Topping up with 0.01 ETH...`);
    
    const hash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "depositTo",
      args: [accountAddr],
      value: topUp,
    });
    
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Deposit tx: ${hash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${hash}`);
    
    const newDeposit = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "balanceOf",
      args: [accountAddr],
    });
    
    console.log(
      `  New deposit: ${formatEther(newDeposit)} ETH`
    );
  } else if (deposit < minDeposit) {
    console.log("  (dry-run: skipping deposit top-up)");
  } else {
    console.log("  Deposit sufficient.");
  }

  // Also ensure the account has ETH balance for the 0.001 ETH transfer
  const accountBal = await publicClient.getBalance({ address: accountAddr });
  console.log(
    `  Account ETH balance: ${formatEther(accountBal)} ETH`
  );

  if (accountBal < TRANSFER_AMOUNT && !DRY_RUN) {
    console.log("  Funding account with 0.005 ETH for transfer...");
    
    const hash = await walletClient.sendTransaction({
      to: accountAddr,
      value: parseEther("0.005"),
    });
    
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Fund tx: ${hash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${hash}`);
  }

  const recipientBalBefore = await publicClient.getBalance({ 
    address: RECIPIENT as `0x${string}` 
  });
  console.log(
    `\n  Recipient balance before: ${formatEther(recipientBalBefore)} ETH\n`
  );

  // ── Step 4: Build UserOp ─────────────────────────────────────────────────
  console.log("[ 4 ] Build UserOp (send 0.001 ETH to recipient)...");
  
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getNonce",
    args: [accountAddr, 0n],
  });
  
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI,
    functionName: "execute",
    args: [RECIPIENT as `0x${string}`, TRANSFER_AMOUNT, "0x"],
  });

  const feeData = await publicClient.estimateFeesPerGas();
  const maxPri = feeData.maxPriorityFeePerGas ?? parseGwei("2");
  const maxFee = feeData.maxFeePerGas ?? parseGwei("20");

  // Pack gas limits: verificationGasLimit (high 128) | callGasLimit (low 128)
  const verificationGasLimit = 500_000n;
  const callGasLimit = 200_000n;
  const accountGasLimits = toHex(
    (verificationGasLimit << 128n) | callGasLimit,
    { size: 32 }
  );

  // Pack gas fees: maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128)
  const gasFees = toHex((maxPri << 128n) | maxFee, { size: 32 });

  const userOp = {
    sender: accountAddr,
    nonce: nonce,
    initCode: "0x" as `0x${string}`,
    callData: callData,
    accountGasLimits: accountGasLimits,
    preVerificationGas: 60_000n,
    gasFees: gasFees,
    paymasterAndData: "0x" as `0x${string}`,
    signature: "0x" as `0x${string}`,
  };

  console.log(`  Nonce              : ${nonce}`);
  console.log(`  verificationGasLimit: ${verificationGasLimit}`);
  console.log(`  callGasLimit       : ${callGasLimit}`);
  console.log(`  preVerificationGas : 60000`);
  console.log(
    `  maxPriorityFee     : ${Number(maxPri) / 1e9} gwei`
  );
  console.log(
    `  maxFeePerGas       : ${Number(maxFee) / 1e9} gwei\n`
  );

  // ── Step 5: Get userOpHash and sign ──────────────────────────────────────
  console.log("[ 5 ] Compute userOpHash and ECDSA sign...");
  
  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT,
    abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash",
    args: [userOp],
  });
  
  console.log(`  userOpHash: ${userOpHash}`);

  // Sign the hash using EIP-191 personal sign
  const signature = await signMessageEIP191(account, userOpHash);
  
  console.log(`  Signature : ${signature.slice(0, 22)}...`);
  console.log(`  Sig length: ${(signature.length - 2) / 2} bytes\n`);

  // Attach signature to UserOp
  const signedUserOp = { ...userOp, signature };

  if (DRY_RUN) {
    console.log("[ 6 ] DRY RUN -- skipping submission.");
    console.log("  UserOp built and signed successfully.");
    console.log("  Set DRY_RUN='' to submit.\n");
    return;
  }

  // ── Step 6: Submit handleOps ─────────────────────────────────────────────
  console.log("[ 6 ] Submit UserOp via EntryPoint.handleOps()...");

  try {
    // Estimate gas for handleOps
    const gasEstimate = await publicClient.estimateContractGas({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[signedUserOp], account.address],
      account: account.address,
    });
    
    console.log(`  Gas estimate: ${gasEstimate}`);

    const hash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[signedUserOp], account.address],
      gas: (gasEstimate * 130n) / 100n, // 30% buffer
    });
    
    console.log(`  Tx submitted: ${hash}`);
    console.log(`  Waiting for confirmation...`);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    console.log("\n+===========================================+");
    console.log("|  UserOp executed successfully!            |");
    console.log("+===========================================+");
    console.log(`  Tx hash  : ${hash}`);
    console.log(`  Block    : ${receipt.blockNumber}`);
    console.log(`  Gas used : ${receipt.gasUsed}`);
    console.log(
      `  Etherscan: https://sepolia.etherscan.io/tx/${hash}\n`
    );

    // ── Step 7: Verify result ────────────────────────────────────────────────
    console.log("[ 7 ] Verify result...");
    const recipientBalAfter = await publicClient.getBalance({ 
      address: RECIPIENT as `0x${string}` 
    });
    const diff = recipientBalAfter - recipientBalBefore;
    
    console.log(
      `  Recipient balance after : ${formatEther(recipientBalAfter)} ETH`
    );
    console.log(
      `  Recipient received      : ${formatEther(diff)} ETH ${diff >= TRANSFER_AMOUNT ? "OK" : "UNEXPECTED"}`
    );

    const depositAfter = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "balanceOf",
      args: [accountAddr],
    });
    
    console.log(
      `  Account deposit after   : ${formatEther(depositAfter)} ETH`
    );
    console.log("\nDone.\n");
  } catch (e: any) {
    console.error(`  Transaction failed: ${e.message}`);
    
    // Try to simulate for more details
    try {
      await publicClient.simulateContract({
        address: ENTRYPOINT,
        abi: ENTRYPOINT_ABI,
        functionName: "handleOps",
        args: [[signedUserOp], account.address],
        account: account.address,
      });
    } catch (simError: any) {
      console.error(`  Simulation error: ${simError.message}`);
    }
    
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(1);
});
