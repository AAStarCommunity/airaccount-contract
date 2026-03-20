/**
 * gas-benchmark.ts — Measure actual gas cost for M5/M6/M7 AirAccount on Sepolia
 *
 * Tests each deployed account with:
 *   1. Empty call (base UserOp cost)
 *   2. ETH transfer (0.0001 ETH to 0xdead)
 *   3. ERC20 transfer (1 wei aPNTs to 0xdead)
 *
 * Run: pnpm tsx scripts/gas-benchmark.ts
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
  toHex,
  keccak256,
  concat,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const PRIVATE_KEY  = process.env.PRIVATE_KEY as Hex;
const RPC_URL      = process.env.SEPOLIA_RPC_URL!;
const ENTRYPOINT   = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const RECIPIENT    = "0x000000000000000000000000000000000000dEaD" as Address;
const APNTS_TOKEN  = "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address;

const ACCOUNTS = [
  { label: "M5 (COMBINED_T1)", addr: "0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32" as Address },
  { label: "M5 (ERC20_GUARD)",  addr: "0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC" as Address },
  { label: "M6",                addr: "0xfab5b2cf392c862b455dcfafac5a414d459b6dcc" as Address },
  { label: "M7",                addr: "0xBe9245282E31E34961F6E867b8B335437a8fF78b" as Address },
];

// ─── ABIs ────────────────────────────────────────────────────────────────────

const ENTRYPOINT_ABI = [
  { name: "depositTo",   type: "function", stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "balanceOf",   type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getNonce",    type: "function", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint192" }], outputs: [{ type: "uint256" }] },
  { name: "getUserOpHash", type: "function", stateMutability: "view",
    inputs: [{ name: "userOp", type: "tuple", components: [
      { name: "sender",             type: "address" },
      { name: "nonce",              type: "uint256" },
      { name: "initCode",           type: "bytes" },
      { name: "callData",           type: "bytes" },
      { name: "accountGasLimits",   type: "bytes32" },
      { name: "preVerificationGas", type: "uint256" },
      { name: "gasFees",            type: "bytes32" },
      { name: "paymasterAndData",   type: "bytes" },
      { name: "signature",          type: "bytes" },
    ]}],
    outputs: [{ type: "bytes32" }] },
  { name: "handleOps", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "ops", type: "tuple[]", components: [
        { name: "sender",             type: "address" },
        { name: "nonce",              type: "uint256" },
        { name: "initCode",           type: "bytes" },
        { name: "callData",           type: "bytes" },
        { name: "accountGasLimits",   type: "bytes32" },
        { name: "preVerificationGas", type: "uint256" },
        { name: "gasFees",            type: "bytes32" },
        { name: "paymasterAndData",   type: "bytes" },
        { name: "signature",          type: "bytes" },
      ]},
      { name: "beneficiary", type: "address" },
    ], outputs: [] },
] as const;

const ERC20_ABI = [
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "transfer",  type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ type: "bool" }] },
] as const;

const ACCOUNT_ABI = [
  { name: "execute", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "dest",  type: "address" },
      { name: "value", type: "uint256" },
      { name: "func",  type: "bytes" },
    ], outputs: [] },
] as const;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function packGasLimits(verif: bigint, call: bigint): Hex {
  return toHex(verif << 128n | call, { size: 32 });
}
function packGasFees(maxFee: bigint, maxPrio: bigint): Hex {
  return toHex(maxFee << 128n | maxPrio, { size: 32 });
}

// ─── Core: submit one UserOp, return gas used ─────────────────────────────────

async function submitUserOp(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  owner: ReturnType<typeof privateKeyToAccount>,
  accountAddr: Address,
  callData: Hex,
): Promise<bigint | null> {
  try {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "getNonce", args: [accountAddr, 0n],
    }) as bigint;

    const userOp = {
      sender:             accountAddr,
      nonce,
      initCode:           "0x" as Hex,
      callData,
      accountGasLimits:   packGasLimits(300000n, 100000n),
      preVerificationGas: 60000n,
      gasFees:            packGasFees(parseEther("0.000000003"), parseEther("0.000000001")),
      paymasterAndData:   "0x" as Hex,
      signature:          "0x" as Hex,
    };

    const userOpHash = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "getUserOpHash", args: [userOp],
    }) as Hex;

    const ethHash = keccak256(
      concat([toHex(Buffer.from("\x19Ethereum Signed Message:\n32")), userOpHash])
    );
    const rawSig = await owner.sign({ hash: ethHash });
    userOp.signature = concat(["0x02", rawSig]) as Hex; // algId=0x02 ECDSA

    const txHash = await walletClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], owner.address],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    return receipt.gasUsed;
  } catch (e: any) {
    return null;
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  if (!PRIVATE_KEY) { console.error("Missing PRIVATE_KEY"); process.exit(1); }

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });

  console.log("=== AirAccount Gas Benchmark (Sepolia) ===");
  console.log(`Signer: ${owner.address}\n`);

  type Row = {
    label: string;
    addr: Address;
    emptyCall: bigint | null;
    ethTransfer: bigint | null;
    erc20Transfer: bigint | null;
  };

  const results: Row[] = [];

  for (const { label, addr } of ACCOUNTS) {
    console.log(`\n── ${label}  ${addr} ──`);

    // ── Ensure EntryPoint deposit ──────────────────────────────────────────
    const epBal = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "balanceOf", args: [addr],
    }) as bigint;

    if (epBal < parseEther("0.005")) {
      process.stdout.write("  Depositing 0.01 ETH to EntryPoint... ");
      const tx = await walletClient.writeContract({
        address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
        functionName: "depositTo", args: [addr],
        value: parseEther("0.01"),
      });
      await publicClient.waitForTransactionReceipt({ hash: tx });
      console.log("done");
    } else {
      console.log(`  EntryPoint balance: ${formatEther(epBal)} ETH — OK`);
    }

    // ── Ensure account has ETH for ETH transfer test ───────────────────────
    const accBal = await publicClient.getBalance({ address: addr });
    if (accBal < parseEther("0.001")) {
      process.stdout.write("  Sending 0.005 ETH to account... ");
      const tx = await walletClient.sendTransaction({ to: addr, value: parseEther("0.005") });
      await publicClient.waitForTransactionReceipt({ hash: tx });
      console.log("done");
    }

    // ── Test 1: Empty call ─────────────────────────────────────────────────
    process.stdout.write("  [1/3] Empty call... ");
    const emptyGas = await submitUserOp(publicClient, walletClient, owner, addr, "0x");
    console.log(emptyGas ? `${emptyGas.toLocaleString()} gas` : "FAILED");

    // ── Test 2: ETH transfer ───────────────────────────────────────────────
    process.stdout.write("  [2/3] ETH transfer (0.0001 ETH → 0xdead)... ");
    const ethCallData = encodeFunctionData({
      abi: ACCOUNT_ABI, functionName: "execute",
      args: [RECIPIENT, parseEther("0.0001"), "0x"],
    });
    const ethGas = await submitUserOp(publicClient, walletClient, owner, addr, ethCallData);
    console.log(ethGas ? `${ethGas.toLocaleString()} gas` : "FAILED/skipped");

    // ── Test 3: ERC20 transfer ─────────────────────────────────────────────
    process.stdout.write("  [3/3] ERC20 transfer (1 wei aPNTs → 0xdead)... ");
    const tokenBal = await publicClient.readContract({
      address: APNTS_TOKEN, abi: ERC20_ABI,
      functionName: "balanceOf", args: [addr],
    }) as bigint;

    let erc20Gas: bigint | null = null;
    if (tokenBal > 0n) {
      const erc20Data = encodeFunctionData({
        abi: ERC20_ABI, functionName: "transfer", args: [RECIPIENT, 1n],
      });
      const erc20CallData = encodeFunctionData({
        abi: ACCOUNT_ABI, functionName: "execute",
        args: [APNTS_TOKEN, 0n, erc20Data],
      });
      erc20Gas = await submitUserOp(publicClient, walletClient, owner, addr, erc20CallData);
      console.log(erc20Gas ? `${erc20Gas.toLocaleString()} gas` : "FAILED");
    } else {
      console.log(`no aPNTs balance (${tokenBal}), skipped`);
    }

    results.push({ label, addr, emptyCall: emptyGas, ethTransfer: ethGas, erc20Transfer: erc20Gas });
  }

  // ── Summary table ──────────────────────────────────────────────────────────
  console.log("\n\n═══════════════════════════════════════════════════════════════════════════════");
  console.log("  GAS BENCHMARK RESULTS (Sepolia, ECDSA algId=0x02)");
  console.log("═══════════════════════════════════════════════════════════════════════════════");
  console.log(`  ${"Account".padEnd(20)} ${"Empty Call".padStart(12)} ${"ETH Transfer".padStart(14)} ${"ERC20 Transfer".padStart(16)}`);
  console.log("  " + "─".repeat(66));

  for (const r of results) {
    const fmt = (v: bigint | null) => v ? v.toLocaleString().padStart(13) : "      N/A    ";
    console.log(`  ${r.label.padEnd(20)} ${fmt(r.emptyCall)} ${fmt(r.ethTransfer)} ${fmt(r.erc20Transfer)}`);
  }

  // ── Industry comparison ────────────────────────────────────────────────────
  console.log("\n  Industry comparison (ERC20 transfer, published benchmarks):");
  console.log("  " + "─".repeat(66));
  const industry = [
    { label: "SimpleAccount (Pimlico)", erc20: "~115,000", note: "no guard, no recovery" },
    { label: "LightAccount (Alchemy)",  erc20: "~110,000", note: "lightweight, upgradable" },
    { label: "Kernel (ZeroDev)",        erc20: "~145,000", note: "modular ERC-7579" },
    { label: "Safe (4337 module)",      erc20: "~175,000", note: "proxy + module overhead" },
    { label: "Biconomy v2",             erc20: "~155,000", note: "modular, ECDSA default" },
  ];
  for (const r of industry) {
    console.log(`  ${r.label.padEnd(26)} ${r.erc20.padStart(12)}     ${r.note}`);
  }
  console.log("═══════════════════════════════════════════════════════════════════════════════\n");
}

main().catch((err) => {
  console.error("Fatal:", err.message ?? err);
  process.exit(1);
});
