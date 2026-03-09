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
 */

import { ethers } from "ethers";

// ─── Config from environment ─────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) {
    console.error(`Missing env: ${k}`);
    process.exit(1);
  }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY");
const RPC_URL = process.env.SEPOLIA_RPC ?? required("SEPOLIA_RPC");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const FACTORY_ADDRESS = process.env.FACTORY_ADDRESS || "";
const DRY_RUN = !!process.env.DRY_RUN;

// Transfer recipient: if not set, send to self (harmless round-trip)
const RECIPIENT =
  process.env.RECIPIENT || "0x000000000000000000000000000000000000dEaD";
const TRANSFER_AMOUNT = ethers.parseEther("0.001");

// ─── ABIs (inline fragments) ─────────────────────────────────────────────────

const ENTRYPOINT_ABI = [
  "function handleOps(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[],address payable) external",
  "function getUserOpHash(tuple(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)) view returns (bytes32)",
  "function depositTo(address) payable",
  "function balanceOf(address) view returns (uint256)",
  "function getNonce(address,uint192) view returns (uint256)",
];

const FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) external returns (address)",
  "function getAddress(address owner, uint256 salt) view returns (address)",
  "function entryPoint() view returns (address)",
];

const ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function owner() view returns (address)",
  "function entryPoint() view returns (address)",
  "function getDeposit() view returns (uint256)",
  "function addDeposit() payable",
];

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("+===========================================+");
  console.log("|  AirAccount V7 ECDSA E2E Test -- Sepolia  |");
  console.log("+===========================================+\n");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT, ENTRYPOINT_ABI, wallet);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);
  console.log(`Network     : ${network.name} (chainId: ${network.chainId})`);
  console.log(`Signer      : ${wallet.address}`);
  console.log(`Balance     : ${ethers.formatEther(balance)} ETH`);
  console.log(`Recipient   : ${RECIPIENT}`);
  console.log(`Dry-run     : ${DRY_RUN}\n`);

  if (balance < ethers.parseEther("0.01")) {
    console.error(
      "ERROR: Signer balance too low. Need at least 0.01 ETH on Sepolia."
    );
    process.exit(1);
  }

  // ── Step 1: Deploy or reuse Factory ──────────────────────────────────────
  console.log("[ 1 ] Factory setup...");
  let factoryAddr: string;

  if (FACTORY_ADDRESS) {
    factoryAddr = FACTORY_ADDRESS;
    const code = await provider.getCode(factoryAddr);
    if (code === "0x") {
      console.error(
        `  ERROR: No contract at FACTORY_ADDRESS=${factoryAddr}`
      );
      process.exit(1);
    }
    console.log(`  Using existing factory: ${factoryAddr}`);
  } else {
    console.log("  No FACTORY_ADDRESS set, deploying new factory...");
    // Deploy factory -- we need the bytecode. Use getAddress to verify after deploying via forge.
    // For the TS E2E, we deploy using the factory bytecode compiled by Foundry.
    // However, deploying raw bytecode from TS is fragile. Instead, we use forge script.
    // For this E2E test, FACTORY_ADDRESS should be set. If not, we deploy a minimal version.

    // Read compiled bytecode from Foundry artifacts
    const fs = await import("fs");
    const path = await import("path");
    const artifactPath = path.resolve(
      import.meta.dirname ?? ".",
      "../out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json"
    );

    if (!fs.existsSync(artifactPath)) {
      console.error(
        "  ERROR: Foundry artifacts not found. Run 'forge build' first."
      );
      console.error(`  Expected: ${artifactPath}`);
      process.exit(1);
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
    const factoryFactory = new ethers.ContractFactory(
      artifact.abi,
      artifact.bytecode.object,
      wallet
    );

    console.log("  Deploying AAStarAirAccountFactoryV7...");
    const factoryContract = await factoryFactory.deploy(ENTRYPOINT);
    await factoryContract.waitForDeployment();
    factoryAddr = await factoryContract.getAddress();
    console.log(`  Factory deployed at: ${factoryAddr}`);
    console.log(
      `  https://sepolia.etherscan.io/address/${factoryAddr}\n`
    );
    console.log(`  TIP: Set FACTORY_ADDRESS=${factoryAddr} in .env to reuse\n`);
  }

  const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, wallet);

  // ── Step 2: Create account ───────────────────────────────────────────────
  console.log("[ 2 ] Create account via factory...");
  const predictedAddr = await factory.getAddress(wallet.address, 0);
  console.log(`  Predicted address: ${predictedAddr}`);

  const existingCode = await provider.getCode(predictedAddr);
  let accountAddr: string;

  if (existingCode !== "0x") {
    console.log("  Account already deployed (reusing).");
    accountAddr = predictedAddr;
  } else {
    console.log("  Deploying new account...");
    const tx = await factory.createAccount(wallet.address, 0);
    const receipt = await tx.wait();
    accountAddr = predictedAddr;
    console.log(`  Account deployed in tx: ${receipt.hash}`);
    console.log(
      `  https://sepolia.etherscan.io/tx/${receipt.hash}`
    );
  }

  const account = new ethers.Contract(accountAddr, ACCOUNT_ABI, provider);
  const accountOwner = await account.owner();
  console.log(`  Account address : ${accountAddr}`);
  console.log(`  Account owner   : ${accountOwner}`);

  if (accountOwner.toLowerCase() !== wallet.address.toLowerCase()) {
    console.error("  ERROR: Account owner mismatch!");
    process.exit(1);
  }
  console.log("  Owner verified.\n");

  // ── Step 3: Fund EntryPoint deposit ──────────────────────────────────────
  console.log("[ 3 ] EntryPoint deposit...");
  const deposit = await entryPoint.balanceOf(accountAddr);
  const minDeposit = ethers.parseEther("0.005");
  console.log(`  Current deposit: ${ethers.formatEther(deposit)} ETH`);

  if (deposit < minDeposit && !DRY_RUN) {
    const topUp = ethers.parseEther("0.01");
    console.log(`  Topping up with 0.01 ETH...`);
    const tx = await entryPoint.depositTo(accountAddr, { value: topUp });
    const rc = await tx.wait();
    console.log(`  Deposit tx: ${rc.hash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${rc.hash}`);
    const newDeposit = await entryPoint.balanceOf(accountAddr);
    console.log(
      `  New deposit: ${ethers.formatEther(newDeposit)} ETH`
    );
  } else if (deposit < minDeposit) {
    console.log("  (dry-run: skipping deposit top-up)");
  } else {
    console.log("  Deposit sufficient.");
  }

  // Also ensure the account has ETH balance for the 0.001 ETH transfer
  const accountBal = await provider.getBalance(accountAddr);
  console.log(
    `  Account ETH balance: ${ethers.formatEther(accountBal)} ETH`
  );

  if (accountBal < TRANSFER_AMOUNT && !DRY_RUN) {
    console.log("  Funding account with 0.005 ETH for transfer...");
    const tx = await wallet.sendTransaction({
      to: accountAddr,
      value: ethers.parseEther("0.005"),
    });
    const rc = await tx.wait();
    console.log(`  Fund tx: ${rc!.hash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${rc!.hash}`);
  }

  const recipientBalBefore = await provider.getBalance(RECIPIENT);
  console.log(
    `\n  Recipient balance before: ${ethers.formatEther(recipientBalBefore)} ETH\n`
  );

  // ── Step 4: Build UserOp ─────────────────────────────────────────────────
  console.log("[ 4 ] Build UserOp (send 0.001 ETH to recipient)...");
  const nonce = await entryPoint.getNonce(accountAddr, 0);
  const callData = new ethers.Interface(ACCOUNT_ABI).encodeFunctionData(
    "execute",
    [RECIPIENT, TRANSFER_AMOUNT, "0x"]
  );
  const feeData = await provider.getFeeData();
  const maxPri =
    feeData.maxPriorityFeePerGas ?? ethers.parseUnits("2", "gwei");
  const maxFee = feeData.maxFeePerGas ?? ethers.parseUnits("20", "gwei");

  // Pack gas limits: verificationGasLimit (high 128) | callGasLimit (low 128)
  const verificationGasLimit = 500_000n;
  const callGasLimit = 200_000n;
  const accountGasLimits = ethers.toBeHex(
    (verificationGasLimit << 128n) | callGasLimit,
    32
  );

  // Pack gas fees: maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128)
  const gasFees = ethers.toBeHex((maxPri << 128n) | maxFee, 32);

  const userOp = {
    sender: accountAddr,
    nonce: nonce,
    initCode: "0x",
    callData: callData,
    accountGasLimits: accountGasLimits,
    preVerificationGas: 60_000n,
    gasFees: gasFees,
    paymasterAndData: "0x",
    signature: "0x",
  };

  console.log(`  Nonce              : ${nonce}`);
  console.log(`  verificationGasLimit: ${verificationGasLimit}`);
  console.log(`  callGasLimit       : ${callGasLimit}`);
  console.log(`  preVerificationGas : 60000`);
  console.log(
    `  maxPriorityFee     : ${ethers.formatUnits(maxPri, "gwei")} gwei`
  );
  console.log(
    `  maxFeePerGas       : ${ethers.formatUnits(maxFee, "gwei")} gwei\n`
  );

  // ── Step 5: Get userOpHash and sign ──────────────────────────────────────
  console.log("[ 5 ] Compute userOpHash and ECDSA sign...");
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  console.log(`  userOpHash: ${userOpHash}`);

  // Sign the hash using EIP-191 personal sign (toEthSignedMessageHash)
  const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
  console.log(`  Signature : ${signature.slice(0, 22)}...`);
  console.log(`  Sig length: ${ethers.getBytes(signature).length} bytes\n`);

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

  let gasEstimate: bigint;
  try {
    gasEstimate = await entryPoint.handleOps.estimateGas(
      [signedUserOp],
      wallet.address
    );
    console.log(`  Gas estimate: ${gasEstimate}`);
  } catch (e: any) {
    console.error(`  Gas estimation failed: ${e.message}`);
    // Try a static call to get a more detailed error
    try {
      await provider.call({
        to: ENTRYPOINT,
        data: entryPoint.interface.encodeFunctionData("handleOps", [
          [signedUserOp],
          wallet.address,
        ]),
      });
    } catch (se: any) {
      console.error(`  Simulate revert: ${se.message}`);
    }
    process.exit(1);
  }

  const tx = await entryPoint.handleOps([signedUserOp], wallet.address, {
    gasLimit: (gasEstimate * 13n) / 10n, // 30% buffer
  });
  console.log(`  Tx submitted: ${tx.hash}`);
  console.log(`  Waiting for confirmation...`);

  const receipt = await tx.wait();

  console.log("\n+===========================================+");
  console.log("|  UserOp executed successfully!            |");
  console.log("+===========================================+");
  console.log(`  Tx hash  : ${receipt.hash}`);
  console.log(`  Block    : ${receipt.blockNumber}`);
  console.log(`  Gas used : ${receipt.gasUsed}`);
  console.log(
    `  Etherscan: https://sepolia.etherscan.io/tx/${receipt.hash}\n`
  );

  // ── Step 7: Verify result ────────────────────────────────────────────────
  console.log("[ 7 ] Verify result...");
  const recipientBalAfter = await provider.getBalance(RECIPIENT);
  const diff = recipientBalAfter - recipientBalBefore;
  console.log(
    `  Recipient balance after : ${ethers.formatEther(recipientBalAfter)} ETH`
  );
  console.log(
    `  Recipient received      : ${ethers.formatEther(diff)} ETH ${diff >= TRANSFER_AMOUNT ? "OK" : "UNEXPECTED"}`
  );

  const depositAfter = await entryPoint.balanceOf(accountAddr);
  console.log(
    `  Account deposit after   : ${ethers.formatEther(depositAfter)} ETH`
  );
  console.log("\nDone.\n");
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(1);
});
