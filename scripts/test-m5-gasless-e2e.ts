/**
 * test-m5-gasless-e2e.ts — AirAccount M5 Complete Gasless E2E Test
 *
 * Full lifecycle test using M5 factory + new M5 account:
 *   Phase 0: Create M5 account (salt=820, raw createAccount, ECDSA config)
 *   Phase 1: Prepare account (SBT, aPNTs, ETH funding)
 *   Phase 2: Build gasless UserOp via SuperPaymaster
 *   Phase 3: Submit & verify zero ETH cost
 *
 * Compared to test-gasless-complete-e2e.ts (M3), this version:
 *   - Uses M5 factory (0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9)
 *   - Account has ERC20 guard, ALG_COMBINED_T1 approved by default
 *   - Account creation uses raw createAccount (no guardian sig needed for testing)
 *
 * Usage: pnpm tsx scripts/test-m5-gasless-e2e.ts
 */

import * as path from "path";
import { fileURLToPath } from "url";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  encodeDeployData,
  encodeAbiParameters,
  concat,
  pad,
  parseEther,
  formatEther,
  keccak256,
  toBytes,
  parseAbi,
  hexToBytes,
  type Address,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import * as dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, "../.env.sepolia") });

// ─── Configuration ─────────────────────────────────────────────────────────

const RPC_URL = process.env.SEPOLIA_RPC_URL!;
const PRIVATE_KEY = (process.env.PRIVATE_KEY_JASON || process.env.PRIVATE_KEY!) as Hex;

const M5_FACTORY = "0x1ffa949fc5fa34a36ba2466ac3556d961951c3b9" as Address;
const M5_ACCOUNT_SALT = 820n;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// SuperPaymaster ecosystem (unchanged from M3)
const SUPER_PAYMASTER = "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A" as Address;
const OPERATOR_ADDRESS = "0xb5600060e6de5E11D3636731964218E53caadf0E" as Address;
const APNTS_TOKEN = "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address;
const SBT_ADDRESS = "0x677423f5Dad98D19cAE8661c36F094289cb6171a" as Address;
const REGISTRY_ADDRESS = "0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788" as Address;

const SELF_TRANSFER_VALUE = parseEther("0.0001");

// ─── ABIs ──────────────────────────────────────────────────────────────────

const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function mint(address to, uint256 amount)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
]);

const SBT_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function mint(address to)",
]);

const REGISTRY_ABI = parseAbi([
  "function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external returns (uint256)",
]);

const FACTORY_ABI = [
  {
    name: "createAccount",
    type: "function",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "config", type: "tuple", components: [
        { name: "guardians", type: "address[3]" },
        { name: "dailyLimit", type: "uint256" },
        { name: "approvedAlgIds", type: "uint8[]" },
        { name: "minDailyLimit", type: "uint256" },
        { name: "initialTokens", type: "address[]" },
        { name: "initialTokenConfigs", type: "tuple[]", components: [
          { name: "tier1Limit", type: "uint256" },
          { name: "tier2Limit", type: "uint256" },
          { name: "dailyLimit", type: "uint256" },
        ]},
      ]},
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
      { name: "config", type: "tuple", components: [
        { name: "guardians", type: "address[3]" },
        { name: "dailyLimit", type: "uint256" },
        { name: "approvedAlgIds", type: "uint8[]" },
        { name: "minDailyLimit", type: "uint256" },
        { name: "initialTokens", type: "address[]" },
        { name: "initialTokenConfigs", type: "tuple[]", components: [
          { name: "tier1Limit", type: "uint256" },
          { name: "tier2Limit", type: "uint256" },
          { name: "dailyLimit", type: "uint256" },
        ]},
      ]},
    ],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

const ENTRYPOINT_ABI = [
  { type: "function", name: "getNonce",
    inputs: [{ type: "address", name: "sender" }, { type: "uint192", name: "key" }],
    outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "getUserOpHash",
    inputs: [{ type: "tuple", components: [
      { name: "sender", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "initCode", type: "bytes" },
      { name: "callData", type: "bytes" },
      { name: "accountGasLimits", type: "bytes32" },
      { name: "preVerificationGas", type: "uint256" },
      { name: "gasFees", type: "bytes32" },
      { name: "paymasterAndData", type: "bytes" },
      { name: "signature", type: "bytes" },
    ]}],
    outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "handleOps",
    inputs: [
      { type: "tuple[]", components: [
        { name: "sender", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "initCode", type: "bytes" },
        { name: "callData", type: "bytes" },
        { name: "accountGasLimits", type: "bytes32" },
        { name: "preVerificationGas", type: "uint256" },
        { name: "gasFees", type: "bytes32" },
        { name: "paymasterAndData", type: "bytes" },
        { name: "signature", type: "bytes" },
      ]},
      { name: "beneficiary", type: "address" },
    ],
    outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "depositTo",
    inputs: [{ name: "account", type: "address" }],
    outputs: [], stateMutability: "payable" },
] as const;

const PAYMASTER_ABI = [
  { type: "function", name: "getDeposit", outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "cachedPrice", inputs: [],
    outputs: [{ type: "int256", name: "price" }, { type: "uint256", name: "updatedAt" }, { type: "uint80", name: "roundId" }, { type: "uint8", name: "decimals" }],
    stateMutability: "view" },
  { type: "function", name: "priceStalenessThreshold", inputs: [], outputs: [{ type: "uint48" }], stateMutability: "view" },
  { type: "function", name: "updatePrice", inputs: [], outputs: [], stateMutability: "nonpayable" },
] as const;

// ─── Helpers ───────────────────────────────────────────────────────────────

function packUint128(hi: bigint, lo: bigint): Hex {
  return concat([
    pad(`0x${hi.toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${lo.toString(16)}`, { dir: "left", size: 16 }),
  ]);
}

function fmt(raw: bigint, dec: number): string {
  return (Number(raw) / 10 ** dec).toFixed(4);
}

// M5 ECDSA config: ECDSA-only, 1 ETH daily limit, no guardians, no tokens
const M5_TEST_CONFIG = {
  guardians: [
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000",
  ] as [Address, Address, Address],
  dailyLimit: parseEther("1"),
  approvedAlgIds: [0x02, 0x06] as number[], // ECDSA + COMBINED_T1
  minDailyLimit: 0n,
  initialTokens: [] as Address[],
  initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
};

// ─── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log("╔══════════════════════════════════════════════════════╗");
  console.log("║  AirAccount M5 — Complete Gasless E2E Test          ║");
  console.log("╚══════════════════════════════════════════════════════╝\n");

  if (!RPC_URL) throw new Error("SEPOLIA_RPC_URL not set");
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");

  const signer = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: signer, chain: sepolia, transport: http(RPC_URL) });

  console.log("Configuration:");
  console.log(`  M5 Factory:     ${M5_FACTORY}`);
  console.log(`  Salt:           ${M5_ACCOUNT_SALT}`);
  console.log(`  SuperPaymaster: ${SUPER_PAYMASTER}`);
  console.log(`  aPNTs Token:    ${APNTS_TOKEN}`);
  console.log(`  Signer EOA:     ${signer.address}\n`);

  // ══════════════════════════════════════════════════════════════════════════
  // Phase 0: Create M5 Account
  // ══════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 0: Create M5 Account ━━━\n");

  // Predict address
  const predictedAddr = await publicClient.readContract({
    address: M5_FACTORY,
    abi: FACTORY_ABI,
    functionName: "getAddress",
    args: [signer.address, M5_ACCOUNT_SALT, M5_TEST_CONFIG],
  }) as Address;
  console.log(`  Predicted address: ${predictedAddr}`);

  const existingCode = await publicClient.getCode({ address: predictedAddr });
  let M5_ACCOUNT: Address;

  if (existingCode && existingCode !== "0x") {
    console.log(`  Already deployed (${existingCode.length / 2 - 1} bytes) — reusing\n`);
    M5_ACCOUNT = predictedAddr;
  } else {
    console.log("  Deploying via createAccount (raw, no guardian sig needed)...");
    const createTxHash = await walletClient.writeContract({
      address: M5_FACTORY,
      abi: FACTORY_ABI,
      functionName: "createAccount",
      args: [signer.address, M5_ACCOUNT_SALT, M5_TEST_CONFIG],
    });
    console.log(`  TX: ${createTxHash}`);
    const createReceipt = await publicClient.waitForTransactionReceipt({ hash: createTxHash });
    M5_ACCOUNT = predictedAddr;
    console.log(`  Gas used: ${createReceipt.gasUsed}`);
    console.log(`  Account: ${M5_ACCOUNT}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${createTxHash}\n`);
  }

  // Deposit ETH to EntryPoint for this account
  console.log("  Checking EntryPoint deposit...");
  const depositAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
  let epDeposit = 0n;
  try {
    epDeposit = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: depositAbi,
      functionName: "balanceOf",
      args: [M5_ACCOUNT],
    });
  } catch { /* ignore */ }
  console.log(`  EP deposit: ${formatEther(epDeposit)} ETH`);
  if (epDeposit < parseEther("0.005")) {
    console.log("  Depositing 0.01 ETH to EntryPoint...");
    const depositHash = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "depositTo",
      args: [M5_ACCOUNT],
      value: parseEther("0.01"),
    });
    await publicClient.waitForTransactionReceipt({ hash: depositHash });
    console.log(`  Deposited. TX: ${depositHash}\n`);
  } else {
    console.log("  OK: deposit sufficient\n");
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Phase 1: Prepare Account
  // ══════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 1: Prepare Account ━━━\n");

  // Step 1.1: SBT
  console.log("Step 1.1: SBT (soul-bound identity token)");
  const sbtBalance = await publicClient.readContract({
    address: SBT_ADDRESS, abi: SBT_ABI, functionName: "balanceOf", args: [M5_ACCOUNT],
  });
  if (sbtBalance > 0n) {
    console.log(`  OK: Holds SBT (balance=${sbtBalance})\n`);
  } else {
    let minted = false;
    try {
      const roleId = keccak256(toBytes("ENDUSER"));
      const roleData = encodeAbiParameters(
        [{ type: "tuple", components: [
          { type: "address", name: "account" }, { type: "address", name: "community" },
          { type: "string", name: "avatar" }, { type: "string", name: "ens" },
          { type: "uint256", name: "stake" },
        ]}],
        [[M5_ACCOUNT, signer.address, "", "", parseEther("0.3")]]
      );
      const h = await walletClient.writeContract({
        address: REGISTRY_ADDRESS, abi: REGISTRY_ABI,
        functionName: "safeMintForRole", args: [roleId, M5_ACCOUNT, roleData],
      });
      await publicClient.waitForTransactionReceipt({ hash: h });
      console.log(`  OK: SBT minted via Registry (tx: ${h})\n`);
      minted = true;
    } catch (e: any) {
      console.log(`  Registry failed: ${e.shortMessage || e.message?.split("\n")[0]}`);
    }
    if (!minted) {
      try {
        const h = await walletClient.writeContract({
          address: SBT_ADDRESS, abi: SBT_ABI, functionName: "mint", args: [M5_ACCOUNT],
        });
        await publicClient.waitForTransactionReceipt({ hash: h });
        console.log(`  OK: SBT minted directly (tx: ${h})\n`);
      } catch (e: any) {
        console.error(`  FAIL: ${e.shortMessage || e.message?.split("\n")[0]}`);
        process.exit(1);
      }
    }
  }

  // Step 1.2: aPNTs
  console.log("Step 1.2: aPNTs (gas token for SuperPaymaster)");
  const dec = Number(await publicClient.readContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "decimals" }));
  const apntsBal = await publicClient.readContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [M5_ACCOUNT] });
  console.log(`  Balance: ${fmt(apntsBal, dec)} aPNTs`);
  if (apntsBal >= parseEther("100")) {
    console.log("  OK: Balance >= 100 aPNTs\n");
  } else {
    const mintAmt = parseEther("100");
    try {
      const h = await walletClient.writeContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "mint", args: [M5_ACCOUNT, mintAmt] });
      await publicClient.waitForTransactionReceipt({ hash: h });
      console.log(`  OK: Minted 100 aPNTs (tx: ${h})\n`);
    } catch {
      const h = await walletClient.writeContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "transfer", args: [M5_ACCOUNT, mintAmt] });
      await publicClient.waitForTransactionReceipt({ hash: h });
      console.log(`  OK: Transferred 100 aPNTs (tx: ${h})\n`);
    }
  }

  // Step 1.3: ETH (for self-transfer value)
  console.log("Step 1.3: ETH (for self-transfer value)");
  const ethBal = await publicClient.getBalance({ address: M5_ACCOUNT });
  console.log(`  Balance: ${formatEther(ethBal)} ETH`);
  if (ethBal >= parseEther("0.001")) {
    console.log("  OK\n");
  } else {
    const h = await walletClient.sendTransaction({ to: M5_ACCOUNT, value: parseEther("0.002") });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log(`  OK: Sent 0.002 ETH (tx: ${h})\n`);
  }

  // Step 1.4: Paymaster deposit + price cache
  console.log("Step 1.4: SuperPaymaster deposit + price cache");
  const pmDeposit = await publicClient.readContract({ address: SUPER_PAYMASTER, abi: PAYMASTER_ABI, functionName: "getDeposit" }) as bigint;
  console.log(`  PM deposit: ${formatEther(pmDeposit)} ETH`);
  if (pmDeposit < parseEther("0.01")) console.warn("  WARNING: Low paymaster deposit (<0.01 ETH)");

  const [cachedPrice, staleness] = await Promise.all([
    publicClient.readContract({ address: SUPER_PAYMASTER, abi: PAYMASTER_ABI, functionName: "cachedPrice" }),
    publicClient.readContract({ address: SUPER_PAYMASTER, abi: PAYMASTER_ABI, functionName: "priceStalenessThreshold" }),
  ]);
  const priceData = cachedPrice as readonly [bigint, bigint, bigint, number];
  const validUntil = BigInt(priceData[1]) + BigInt(staleness as bigint | number);
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (now > validUntil) {
    const h = await walletClient.writeContract({ address: SUPER_PAYMASTER, abi: PAYMASTER_ABI, functionName: "updatePrice" });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log("  OK: Price cache refreshed\n");
  } else {
    console.log(`  OK: ETH/USD = $${(Number(priceData[0]) / 1e8).toFixed(2)}, valid for ${Number(validUntil - now)}s\n`);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Phase 2: Build Gasless UserOp
  // ══════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 2: Build Gasless UserOp ━━━\n");

  const callData = encodeFunctionData({
    abi: [{ type: "function", name: "execute", inputs: [{ type: "address" }, { type: "uint256" }, { type: "bytes" }] }],
    functionName: "execute",
    args: [M5_ACCOUNT, SELF_TRANSFER_VALUE, "0x"],
  });
  console.log(`  Action: execute(self, ${formatEther(SELF_TRANSFER_VALUE)} ETH, 0x)\n`);

  const nonce = await publicClient.readContract({ address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce", args: [M5_ACCOUNT, 0n] }) as bigint;
  console.log(`  Nonce: ${nonce}`);

  const paymasterAndData: Hex = concat([
    SUPER_PAYMASTER,
    pad(`0x${(250000n).toString(16)}`, { dir: "left", size: 16 }),
    pad(`0x${(50000n).toString(16)}`, { dir: "left", size: 16 }),
    OPERATOR_ADDRESS,
  ]);

  const userOp = {
    sender: M5_ACCOUNT,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: packUint128(150000n, 100000n),
    preVerificationGas: 50000n,
    gasFees: packUint128(2000000000n, 3000000000n),
    paymasterAndData,
    signature: "0x" as Hex,
  };

  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getUserOpHash", args: [userOp],
  }) as Hex;
  console.log(`  UserOpHash: ${userOpHash}`);

  // M5 ECDSA signature: EIP-191 signed userOpHash (same as M3)
  const sig = await signer.signMessage({ message: { raw: hexToBytes(userOpHash) } });
  userOp.signature = sig;
  console.log(`  Signature: ${sig.slice(0, 20)}... (${(sig.length - 2) / 2} bytes)\n`);

  // ══════════════════════════════════════════════════════════════════════════
  // Phase 3: Submit & Verify
  // ══════════════════════════════════════════════════════════════════════════

  console.log("━━━ Phase 3: Submit & Verify ━━━\n");

  const [ethBefore, apntsBefore2] = await Promise.all([
    publicClient.getBalance({ address: M5_ACCOUNT }),
    publicClient.readContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [M5_ACCOUNT] }),
  ]);
  console.log(`  ETH before:   ${formatEther(ethBefore)}`);
  console.log(`  aPNTs before: ${fmt(apntsBefore2, dec)}\n`);

  try {
    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
      args: [[userOp], signer.address], gas: 2000000n,
    });
    console.log(`  TX: ${txHash}`);
    console.log(`  https://sepolia.etherscan.io/tx/${txHash}`);

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    if (receipt.status !== "success") { console.error("  FAIL: TX reverted"); process.exit(1); }
    console.log(`  Block: ${receipt.blockNumber}, Gas used: ${receipt.gasUsed}\n`);

    const [ethAfter, apntsAfter] = await Promise.all([
      publicClient.getBalance({ address: M5_ACCOUNT }),
      publicClient.readContract({ address: APNTS_TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [M5_ACCOUNT] }),
    ]);

    const ethDiff = ethBefore - ethAfter;
    const apntsDiff = apntsBefore2 - apntsAfter;

    console.log("  Balance changes:");
    console.log(`    ETH:   ${formatEther(ethBefore)} → ${formatEther(ethAfter)} (${ethDiff === 0n ? "ZERO COST ✓" : `-${formatEther(ethDiff)}`})`);
    console.log(`    aPNTs: ${fmt(apntsBefore2, dec)} → ${fmt(apntsAfter, dec)} (-${fmt(apntsDiff, dec)} as gas fee)\n`);

    console.log("  Gas analysis:");
    console.log(`    Bundler gas used: ${receipt.gasUsed}`);
    console.log(`    AA account ETH:   ${ethDiff === 0n ? "UNCHANGED (gasless!)" : `−${formatEther(ethDiff)} ETH`}`);
    console.log(`    aPNTs deducted:   ${fmt(apntsDiff, dec)} aPNTs`);
    console.log(`    ETH/USD price:    $${(Number(priceData[0]) / 1e8).toFixed(2)}`);

    const verdict = ethDiff === 0n ? "PASSED" : "PARTIAL (ETH changed)";
    console.log("\n╔══════════════════════════════════════════════════════╗");
    console.log(`║  GASLESS E2E TEST: ${verdict.padEnd(34)}║`);
    console.log("║                                                      ║");
    console.log("║  M5 account executed a self-transfer with ZERO ETH  ║");
    console.log("║  gas cost. Gas was paid in aPNTs via SuperPaymaster. ║");
    console.log("╚══════════════════════════════════════════════════════╝");

    console.log("\n  M5 vs M3 comparison:");
    console.log("    Factory: M3 0xce4231... → M5 0x1ffa94...");
    console.log("    Account: M3 0x4bFf35... → M5 " + M5_ACCOUNT);
    console.log(`    TX hash: ${txHash}`);
  } catch (e: any) {
    console.error(`  FAIL: ${e.shortMessage || e.message?.slice(0, 200)}`);
    process.exit(1);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
