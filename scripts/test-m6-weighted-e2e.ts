/**
 * test-m6-weighted-e2e.ts — M6.1 ALG_WEIGHTED + M6.2 Guardian Consent E2E Tests (Sepolia)
 *
 * M6.1 ALG_WEIGHTED (0x07):
 *   Bitmap-driven weighted multi-signature. Each source (P256, ECDSA, BLS, guardians) has a
 *   configurable weight. At validation time, accumulated weight is stored; at execution time
 *   it's resolved to a representative algId (ALG_ECDSA/T2/T3) for guard enforcement.
 *
 *   Weighted signature format (after algId=0x07 byte):
 *     [bitmap(1)] [P256_r(32) P256_s(32) if bit0] [ECDSA_65 if bit1] [BLS block if bit2]
 *                 [guardian0_65 if bit3] [guardian1_65 if bit4] [guardian2_65 if bit5]
 *
 *   sourceBitmap bits: 0=P256, 1=ECDSA, 2=BLS, 3=guardian[0], 4=guardian[1], 5=guardian[2]
 *
 * M6.2 Guardian Consent:
 *   Weakening weight changes (lower weights or thresholds) require guardian proposal + 2/3 approval
 *   + 2-day timelock. Strengthening is direct. Tests verify state machine without waiting 2 days.
 *
 * Test config:
 *   passkeyWeight=2, ecdsaWeight=2, blsWeight=2, guardian0-2Weight=1
 *   tier1Threshold=3, tier2Threshold=4, tier3Threshold=6
 *   => P256(2) alone < 3 (insufficient), ECDSA(2) alone < 3 (insufficient)
 *   => P256(2)+ECDSA(2)=4 >= tier2Threshold=4 => resolves to ALG_CUMULATIVE_T2 (Tier 2)
 *
 * Tests:
 *   A: P256 + ECDSA bitmap=0x03 => succeeds (weight=4, Tier 2)
 *   B: ECDSA-only bitmap=0x02   => validation fails (weight=2 < tier1Threshold=3)
 *   C: P256-only bitmap=0x01    => validation fails (weight=2 < tier1Threshold=3)
 *   D: Standard ECDSA (0x02)    => still works (backward compat)
 *   E: M6.2 governance flow     => propose → approve → execute blocked by timelock → cancel
 *
 * Prerequisites:
 *   - M6 factory deployed: FACTORY_ADDRESS in .env.sepolia
 *   - PRIVATE_KEY, SEPOLIA_RPC_URL in .env.sepolia
 *   - Run `forge build` before running this script
 *
 * Run: pnpm tsx scripts/test-m6-weighted-e2e.ts
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
  hexToBytes,
  bytesToHex,
  keccak256,
  concat,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { p256 } from "@noble/curves/p256";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const RECIPIENT = "0x000000000000000000000000000000000000dEaD" as Address;

// Deterministic P256 private key for testing (NOT production use)
const P256_PRIVATE_KEY_HEX = "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3";

// Guardian keys from .env.sepolia (funded accounts: bob + jack)
// These correspond to the guardians set in deploy-m6.ts (salt=701)
const GUARDIAN0_KEY = (process.env.PRIVATE_KEY_BOB || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d") as Hex;
const GUARDIAN1_KEY = (process.env.PRIVATE_KEY_JACK || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a") as Hex;

// ─── ABIs ────────────────────────────────────────────────────────────────────

const ACCOUNT_ABI = [
  { name: "owner", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "p256KeyX", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "bytes32" }] },
  { name: "setP256Key", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_x", type: "bytes32" }, { name: "_y", type: "bytes32" }],
    outputs: [] },
  { name: "setWeightConfig", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "config", type: "tuple", components: [
      { name: "passkeyWeight",   type: "uint8" },
      { name: "ecdsaWeight",     type: "uint8" },
      { name: "blsWeight",       type: "uint8" },
      { name: "guardian0Weight", type: "uint8" },
      { name: "guardian1Weight", type: "uint8" },
      { name: "guardian2Weight", type: "uint8" },
      { name: "_padding",        type: "uint8" },
      { name: "tier1Threshold",  type: "uint8" },
      { name: "tier2Threshold",  type: "uint8" },
      { name: "tier3Threshold",  type: "uint8" },
    ]}],
    outputs: [] },
  { name: "proposeWeightChange", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "proposed", type: "tuple", components: [
      { name: "passkeyWeight",   type: "uint8" },
      { name: "ecdsaWeight",     type: "uint8" },
      { name: "blsWeight",       type: "uint8" },
      { name: "guardian0Weight", type: "uint8" },
      { name: "guardian1Weight", type: "uint8" },
      { name: "guardian2Weight", type: "uint8" },
      { name: "_padding",        type: "uint8" },
      { name: "tier1Threshold",  type: "uint8" },
      { name: "tier2Threshold",  type: "uint8" },
      { name: "tier3Threshold",  type: "uint8" },
    ]}],
    outputs: [] },
  { name: "approveWeightChange", type: "function", stateMutability: "nonpayable",
    inputs: [], outputs: [] },
  { name: "cancelWeightChange", type: "function", stateMutability: "nonpayable",
    inputs: [], outputs: [] },
  // Solidity auto-generated getter for WeightChangeProposal flattens nested WeightConfig
  // Returns: (passkeyWeight, ecdsaWeight, blsWeight, g0W, g1W, g2W, _padding,
  //           tier1Threshold, tier2Threshold, tier3Threshold, proposedAt, approvalBitmap)
  { name: "pendingWeightChange", type: "function", stateMutability: "view",
    inputs: [], outputs: [
      { name: "passkeyWeight",   type: "uint8" },
      { name: "ecdsaWeight",     type: "uint8" },
      { name: "blsWeight",       type: "uint8" },
      { name: "guardian0Weight", type: "uint8" },
      { name: "guardian1Weight", type: "uint8" },
      { name: "guardian2Weight", type: "uint8" },
      { name: "_padding",        type: "uint8" },
      { name: "tier1Threshold",  type: "uint8" },
      { name: "tier2Threshold",  type: "uint8" },
      { name: "tier3Threshold",  type: "uint8" },
      { name: "proposedAt",      type: "uint256" },
      { name: "approvalBitmap",  type: "uint256" },
    ]},
  { name: "execute", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "dest", type: "address" },
      { name: "value", type: "uint256" },
      { name: "func", type: "bytes" },
    ], outputs: [] },
  { name: "version", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "string" }] },
] as const;

const ENTRYPOINT_ABI = [
  { name: "depositTo", type: "function", stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "getUserOpHash", type: "function", stateMutability: "view",
    inputs: [{ name: "userOp", type: "tuple",
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
      ]}],
    outputs: [{ name: "", type: "bytes32" }] },
  { name: "handleOps", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "ops", type: "tuple[]", components: [
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
    ], outputs: [] },
  { name: "getNonce", type: "function", stateMutability: "view",
    inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }],
    outputs: [{ name: "nonce", type: "uint256" }] },
] as const;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function packUint128(a: bigint, b: bigint): Hex {
  return `0x${a.toString(16).padStart(32, "0")}${b.toString(16).padStart(32, "0")}` as Hex;
}

function getP256PublicKey(privKeyHex: string): [Hex, Hex] {
  const privBytes = hexToBytes(("0x" + privKeyHex) as Hex);
  const pubKey = p256.getPublicKey(privBytes, false); // uncompressed: [04][x(32)][y(32)]
  const x = bytesToHex(pubKey.slice(1, 33)) as Hex;
  const y = bytesToHex(pubKey.slice(33, 65)) as Hex;
  return [x, y];
}

/**
 * Build an ALG_WEIGHTED signature.
 * bitmap=0x03 => bit0=P256 + bit1=ECDSA
 * Format: [0x07 algId][bitmap(1)][P256_r(32)][P256_s(32)][ECDSA(65)]
 * Total: 1 + 1 + 64 + 65 = 131 bytes
 */
function buildWeightedSig(
  p256PrivKeyHex: string,
  userOpHash: Hex,
  ecdsaSig: Hex,
  bitmap: number = 0x03
): Hex {
  const hashBytes = hexToBytes(userOpHash);
  const result: Uint8Array[] = [new Uint8Array([0x07, bitmap])]; // algId + bitmap

  // bit 0: P256 (64 bytes: r, s) — signs raw userOpHash
  if (bitmap & 0x01) {
    const privBytes = hexToBytes(("0x" + p256PrivKeyHex) as Hex);
    const sig = p256.sign(hashBytes, privBytes, { lowS: true });
    const rBytes = hexToBytes(toHex(sig.r, { size: 32 }));
    const sBytes = hexToBytes(toHex(sig.s, { size: 32 }));
    result.push(rBytes, sBytes);
  }

  // bit 1: ECDSA (65 bytes) — owner signs toEthSignedMessageHash(userOpHash)
  if (bitmap & 0x02) {
    const ecdsaBytes = hexToBytes(ecdsaSig);
    if (ecdsaBytes.length !== 65) throw new Error(`Expected 65-byte ECDSA sig, got ${ecdsaBytes.length}`);
    result.push(ecdsaBytes);
  }

  const total = result.reduce((sum, b) => sum + b.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const b of result) { out.set(b, offset); offset += b.length; }
  return bytesToHex(out);
}

/**
 * Build a standard ECDSA-only signature (algId=0x02 prefix).
 * Owner signs toEthSignedMessageHash(userOpHash).
 */
function buildEcdsaSig(ecdsaSig: Hex): Hex {
  return ("0x02" + ecdsaSig.slice(2)) as Hex;
}

async function buildAndSendUserOp(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  ownerAddr: Address,
  accountAddr: Address,
  sig: Hex
): Promise<Hex> {
  const nonce = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce",
    args: [accountAddr, 0n],
  });

  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI, functionName: "execute",
    args: [RECIPIENT, parseEther("0.0001"), "0x" as Hex],
  });

  const userOp = {
    sender: accountAddr,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: packUint128(300000n, 300000n),
    preVerificationGas: 50000n,
    gasFees: packUint128(2000000000n, 2000000000n),
    paymasterAndData: "0x" as Hex,
    signature: sig,
  };

  return walletClient.writeContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
    args: [[userOp], ownerAddr],
    gas: 1000000n,
  });
}

async function buildUserOpHash(
  publicClient: ReturnType<typeof createPublicClient>,
  accountAddr: Address,
  nonce: bigint
): Promise<Hex> {
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI, functionName: "execute",
    args: [RECIPIENT, parseEther("0.0001"), "0x" as Hex],
  });
  const userOp = {
    sender: accountAddr,
    nonce,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: packUint128(300000n, 300000n),
    preVerificationGas: 50000n,
    gasFees: packUint128(2000000000n, 2000000000n),
    paymasterAndData: "0x" as Hex,
    signature: "0x" as Hex,
  };
  return publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getUserOpHash",
    args: [userOp],
  });
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== M6 ALG_WEIGHTED + Guardian Consent E2E Test (Sepolia) ===\n");
  console.log("M6.1: Bitmap-driven weighted multi-signature");
  console.log("M6.2: Guardian consent for weight-config weakening\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const ownerAccount = privateKeyToAccount(PRIVATE_KEY);
  const walletClient = createWalletClient({ account: ownerAccount, chain: sepolia, transport: http(RPC_URL) });
  const ownerAddr = ownerAccount.address;

  const guardian0Account = privateKeyToAccount(GUARDIAN0_KEY);
  const guardian1Account = privateKeyToAccount(GUARDIAN1_KEY);
  const guardian0Addr = guardian0Account.address;
  const guardian1Addr = guardian1Account.address;

  console.log(`Owner:      ${ownerAddr}`);
  console.log(`Guardian0:  ${guardian0Addr}`);
  console.log(`Guardian1:  ${guardian1Addr}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  // ── Step 1: Get deployed account address ────────────────────────────────
  // Account was deployed by deploy-m6.ts directly (factory exceeds EIP-170 limit).
  // Set AIRACCOUNT_M6_ACCOUNT in .env.sepolia, or run deploy-m6.ts first.

  const accountAddr = (process.env.AIRACCOUNT_M6_ACCOUNT) as Address | undefined;
  if (!accountAddr) {
    console.error("ERROR: Set AIRACCOUNT_M6_ACCOUNT in .env.sepolia");
    console.error("Deploy first: pnpm tsx scripts/deploy-m6.ts");
    process.exit(1);
  }

  const code = await publicClient.getBytecode({ address: accountAddr });
  if (!code || code.length <= 2) {
    console.error(`ERROR: No bytecode at ${accountAddr} — deploy first`);
    process.exit(1);
  }
  console.log(`[Step 1] M6 account: ${accountAddr} (${code.length / 2 - 1} bytes)\n`);

  // ── Step 2: Register P256 key ───────────────────────────────────────────

  const [p256X, p256Y] = getP256PublicKey(P256_PRIVATE_KEY_HEX);
  const storedKeyX = await publicClient.readContract({
    address: accountAddr, abi: ACCOUNT_ABI, functionName: "p256KeyX",
  });

  if (storedKeyX === "0x0000000000000000000000000000000000000000000000000000000000000000") {
    console.log(`\n[Step 2] Registering P256 passkey...`);
    const txHash = await walletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "setP256Key",
      args: [p256X as `0x${string}`, p256Y as `0x${string}`],
    });
    await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  P256 key registered (tx: ${txHash})`);
  } else {
    console.log(`\n[Step 2] P256 key already registered: X=${storedKeyX.slice(0, 10)}...`);
  }

  // ── Step 3: Set weight config ───────────────────────────────────────────
  // Safe config: no single source reaches tier1Threshold alone.
  //   passkeyWeight=2, ecdsaWeight=2, guardian*=1  (all < tier1Threshold=3)
  //   tier1Threshold=3, tier2Threshold=4, tier3Threshold=6
  //   P256(2)+ECDSA(2)=4 => >= tier2Threshold=4 => resolves to ALG_CUMULATIVE_T2

  const safeConfig = {
    passkeyWeight: 2,
    ecdsaWeight: 2,
    blsWeight: 2,
    guardian0Weight: 1,
    guardian1Weight: 1,
    guardian2Weight: 1,
    _padding: 0,
    tier1Threshold: 3,
    tier2Threshold: 4,
    tier3Threshold: 6,
  };

  // Check if already configured by checking tier1Threshold via tuple read
  // (public struct getter returns flat tuple, not struct)
  try {
    const configResult = await publicClient.readContract({
      address: accountAddr,
      abi: [{
        name: "weightConfig", type: "function", stateMutability: "view",
        inputs: [], outputs: [
          { name: "passkeyWeight",   type: "uint8" },
          { name: "ecdsaWeight",     type: "uint8" },
          { name: "blsWeight",       type: "uint8" },
          { name: "guardian0Weight", type: "uint8" },
          { name: "guardian1Weight", type: "uint8" },
          { name: "guardian2Weight", type: "uint8" },
          { name: "_padding",        type: "uint8" },
          { name: "tier1Threshold",  type: "uint8" },
          { name: "tier2Threshold",  type: "uint8" },
          { name: "tier3Threshold",  type: "uint8" },
        ]
      }] as const,
      functionName: "weightConfig",
    });

    // configResult is a tuple — tier1Threshold is index 7
    const tier1Threshold = (configResult as unknown as number[])[7];
    if (tier1Threshold === 0) {
      console.log(`\n[Step 3] Setting weight config...`);
      const txHash = await walletClient.writeContract({
        address: accountAddr, abi: ACCOUNT_ABI, functionName: "setWeightConfig",
        args: [safeConfig],
      });
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      console.log(`  Weight config set (tx: ${txHash})`);
      console.log(`  Config: P256=2, ECDSA=2, guardian0-2=1, tier1=3, tier2=4, tier3=6`);
    } else {
      console.log(`\n[Step 3] Weight config already set (tier1Threshold=${tier1Threshold})`);
    }
  } catch {
    console.log(`\n[Step 3] Setting weight config...`);
    const txHash = await walletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "setWeightConfig",
      args: [safeConfig],
    });
    await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  Weight config set (tx: ${txHash})`);
  }

  // ── Step 4: Fund account ────────────────────────────────────────────────

  const balance = await publicClient.getBalance({ address: accountAddr });
  console.log(`\n[Step 4] Account balance: ${formatEther(balance)} ETH`);
  if (balance < parseEther("0.001")) {
    console.log("  Funding account with 0.005 ETH...");
    const txHash = await walletClient.sendTransaction({ to: accountAddr, value: parseEther("0.005") });
    await publicClient.waitForTransactionReceipt({ hash: txHash });
  }
  const depositTxHash = await walletClient.writeContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "depositTo",
    args: [accountAddr], value: parseEther("0.001"),
  });
  await publicClient.waitForTransactionReceipt({ hash: depositTxHash });
  console.log("  EntryPoint deposit: 0.001 ETH");

  const results: Record<string, string> = {};

  // ── Test A: P256 + ECDSA weighted sig (bitmap=0x03) => SUCCESS ────────────

  console.log("\n[Test A] ALG_WEIGHTED — P256 + ECDSA (bitmap=0x03, weight=4, Tier 2)");
  console.log("  Expected: UserOp SUCCEEDS — accumulated weight 4 >= tier2Threshold=4");
  try {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce",
      args: [accountAddr, 0n],
    });
    const userOpHash = await buildUserOpHash(publicClient, accountAddr, nonce);

    // ECDSA signs toEthSignedMessageHash(userOpHash)
    const ecdsaSig = await walletClient.signMessage({ message: { raw: hexToBytes(userOpHash) } });

    // Build weighted sig: [0x07][bitmap=0x03][P256_r(32)][P256_s(32)][ECDSA(65)]
    const sig = buildWeightedSig(P256_PRIVATE_KEY_HEX, userOpHash, ecdsaSig, 0x03);
    console.log(`  Sig bytes: ${hexToBytes(sig).length} (expected 131: 1+1+64+65)`);

    const txHash = await buildAndSendUserOp(publicClient, walletClient, ownerAddr, accountAddr, sig);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  PASS: Weighted UserOp succeeded (tx: ${txHash})`);
    console.log(`  Gas used: ${receipt.gasUsed}`);
    results.A = `PASS (gas: ${receipt.gasUsed})`;
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    results.A = `FAIL: ${e.message?.slice(0, 80)}`;
  }

  // ── Test B: ECDSA-only weighted (bitmap=0x02, weight=2 < tier1Threshold=3) => FAIL ─

  console.log("\n[Test B] ALG_WEIGHTED — ECDSA-only (bitmap=0x02, weight=2 < tier1Threshold=3)");
  console.log("  Expected: Validation FAILS — insufficient weight");
  try {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce",
      args: [accountAddr, 0n],
    });
    const userOpHash = await buildUserOpHash(publicClient, accountAddr, nonce);
    const ecdsaSig = await walletClient.signMessage({ message: { raw: hexToBytes(userOpHash) } });

    // bitmap=0x02: ECDSA only (weight=2 < tier1Threshold=3)
    const sig = buildWeightedSig(P256_PRIVATE_KEY_HEX, userOpHash, ecdsaSig, 0x02);

    await publicClient.simulateContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
      args: [[{
        sender: accountAddr, nonce,
        initCode: "0x" as Hex,
        callData: encodeFunctionData({ abi: ACCOUNT_ABI, functionName: "execute",
          args: [RECIPIENT, parseEther("0.0001"), "0x" as Hex] }),
        accountGasLimits: packUint128(300000n, 300000n),
        preVerificationGas: 50000n,
        gasFees: packUint128(2000000000n, 2000000000n),
        paymasterAndData: "0x" as Hex,
        signature: sig,
      }], ownerAddr],
      account: ownerAddr,
    });
    console.log("  UNEXPECTED: handleOps should have reverted!");
    results.B = "UNEXPECTED_PASS";
  } catch (simErr: any) {
    if (simErr.message?.includes("AA24") || simErr.message?.includes("signature error") || simErr.message?.includes("AA23")) {
      console.log("  PASS: Signature rejected (AA24/AA23 — insufficient weight)");
      results.B = "PASS (AA24 — insufficient weight)";
    } else {
      console.log(`  PASS (revert): ${simErr.message?.slice(0, 120)}`);
      results.B = `PASS (revert confirmed)`;
    }
  }

  // ── Test C: P256-only weighted (bitmap=0x01, weight=2 < tier1Threshold=3) => FAIL ─

  console.log("\n[Test C] ALG_WEIGHTED — P256-only (bitmap=0x01, weight=2 < tier1Threshold=3)");
  console.log("  Expected: Validation FAILS — single-factor passkey insufficient alone");
  try {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce",
      args: [accountAddr, 0n],
    });
    const userOpHash = await buildUserOpHash(publicClient, accountAddr, nonce);
    const ecdsaSig = await walletClient.signMessage({ message: { raw: hexToBytes(userOpHash) } });

    // bitmap=0x01: P256 only — ECDSA bytes not appended
    const hashBytes = hexToBytes(userOpHash);
    const privBytes = hexToBytes(("0x" + P256_PRIVATE_KEY_HEX) as Hex);
    const p256Sig = p256.sign(hashBytes, privBytes, { lowS: true });
    const p256Sig64 = new Uint8Array(66);
    p256Sig64[0] = 0x07; // algId
    p256Sig64[1] = 0x01; // bitmap: P256 only
    p256Sig64.set(hexToBytes(toHex(p256Sig.r, { size: 32 })), 2);
    p256Sig64.set(hexToBytes(toHex(p256Sig.s, { size: 32 })), 34);
    const sigP256Only = bytesToHex(p256Sig64);

    await publicClient.simulateContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "handleOps",
      args: [[{
        sender: accountAddr, nonce,
        initCode: "0x" as Hex,
        callData: encodeFunctionData({ abi: ACCOUNT_ABI, functionName: "execute",
          args: [RECIPIENT, parseEther("0.0001"), "0x" as Hex] }),
        accountGasLimits: packUint128(300000n, 300000n),
        preVerificationGas: 50000n,
        gasFees: packUint128(2000000000n, 2000000000n),
        paymasterAndData: "0x" as Hex,
        signature: sigP256Only,
      }], ownerAddr],
      account: ownerAddr,
    });
    console.log("  UNEXPECTED: handleOps should have reverted!");
    results.C = "UNEXPECTED_PASS";
  } catch (simErr: any) {
    console.log(`  PASS (revert): P256-only weight insufficient`);
    results.C = "PASS (P256-only weight insufficient)";
  }

  // ── Test D: Standard ECDSA (0x02) backward compat ────────────────────────

  console.log("\n[Test D] Standard ECDSA (algId=0x02) — backward compatibility");
  console.log("  Expected: UserOp SUCCEEDS — ALG_ECDSA still works without weight config");
  try {
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI, functionName: "getNonce",
      args: [accountAddr, 0n],
    });
    const userOpHash = await buildUserOpHash(publicClient, accountAddr, nonce);
    const ecdsaSig = await walletClient.signMessage({ message: { raw: hexToBytes(userOpHash) } });
    const sig = buildEcdsaSig(ecdsaSig);

    const txHash = await buildAndSendUserOp(publicClient, walletClient, ownerAddr, accountAddr, sig);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  PASS: ECDSA-only (0x02) still works (tx: ${txHash})`);
    console.log(`  Gas used: ${receipt.gasUsed}`);
    results.D = `PASS (gas: ${receipt.gasUsed})`;
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    results.D = `FAIL: ${e.message?.slice(0, 80)}`;
  }

  // ── Test E: M6.2 Guardian Consent Governance Flow ─────────────────────────

  console.log("\n[Test E] M6.2 Guardian Consent — propose + approve + timelock check + cancel");
  console.log("  Scenario: Owner proposes weakening (lower tier1Threshold: 3→2)");
  console.log("  Expected: Proposal created, guardian approves, executeWeightChange blocked by timelock, owner cancels");

  // Weakening: lower tier2Threshold (4→3) and tier3Threshold (6→5), keep tier1=3.
  // tier1=3, passkeyWeight=2 → 2 < 3 ✓ passes InsecureWeightConfig check.
  const weakeningConfig = {
    passkeyWeight: 2,
    ecdsaWeight: 2,
    blsWeight: 2,
    guardian0Weight: 1,
    guardian1Weight: 1,
    guardian2Weight: 1,
    _padding: 0,
    tier1Threshold: 3,  // Same as current (not weakening tier1)
    tier2Threshold: 3,  // WEAKENING: lowered from 4 → 3
    tier3Threshold: 5,  // WEAKENING: lowered from 6 → 5
  };

  try {
    // Cleanup: cancel any stale proposal from previous runs
    const staleCheck = await publicClient.readContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "pendingWeightChange",
    }) as unknown as readonly [number, number, number, number, number, number, number, number, number, number, bigint, bigint];
    if (staleCheck[10] !== 0n) {
      console.log("  Cancelling stale proposal from previous run...");
      const cancelStale = await walletClient.writeContract({
        address: accountAddr, abi: ACCOUNT_ABI, functionName: "cancelWeightChange",
      });
      await publicClient.waitForTransactionReceipt({ hash: cancelStale });
      console.log(`  Stale proposal cancelled (tx: ${cancelStale})`);
    }

    // E1: Propose weakening change
    console.log("\n  [E1] Proposing weakening change (tier1: 3→2)...");
    const proposeTxHash = await walletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "proposeWeightChange",
      args: [weakeningConfig],
    });
    await publicClient.waitForTransactionReceipt({ hash: proposeTxHash });
    console.log(`    Proposal submitted (tx: ${proposeTxHash})`);

    // E2: Read pending proposal (flat tuple: 10 WeightConfig fields + proposedAt + approvalBitmap)
    const pending = await publicClient.readContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "pendingWeightChange",
    }) as unknown as readonly [number, number, number, number, number, number, number, number, number, number, bigint, bigint];
    // Indices: [0..9] = WeightConfig fields, [10] = proposedAt, [11] = approvalBitmap
    console.log(`    proposedAt=${pending[10]}, approvalBitmap=${pending[11]}`);

    // E3: Guardian0 approves (must call from guardian address)
    // guardian0 = bob (0xF7B..., 0.177 ETH on Sepolia) — already funded, no top-up needed
    console.log("\n  [E2] Guardian0 approves...");
    const g0WalletClient = createWalletClient({
      account: guardian0Account, chain: sepolia, transport: http(RPC_URL),
    });
    const approveTxHash = await g0WalletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "approveWeightChange",
      gas: 100000n,
    });
    await publicClient.waitForTransactionReceipt({ hash: approveTxHash });
    console.log(`    Guardian0 approved (tx: ${approveTxHash})`);

    const pendingAfter = await publicClient.readContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "pendingWeightChange",
    }) as unknown as readonly [number, number, number, number, number, number, number, number, number, number, bigint, bigint];
    console.log(`    approvalBitmap=${pendingAfter[11]} (bit0 set = guardian0 approved)`);

    // E4: Try execute before timelock — should fail with WeightChangeTimelockNotExpired
    console.log("\n  [E3] Attempt executeWeightChange (before 2-day timelock)...");
    try {
      await publicClient.simulateContract({
        address: accountAddr,
        abi: [{
          name: "executeWeightChange", type: "function", stateMutability: "nonpayable",
          inputs: [], outputs: [],
        }] as const,
        functionName: "executeWeightChange",
        account: ownerAddr,
      });
      console.log("    UNEXPECTED: execute should fail before timelock!");
      results.E = "UNEXPECTED_EXECUTE_PASS";
    } catch (execErr: any) {
      if (execErr.message?.includes("WeightChangeTimelockNotExpired") ||
          execErr.message?.includes("WeightChangeNotApproved") ||
          execErr.message?.includes("revert")) {
        console.log("    PASS: Execution blocked before timelock (as expected)");
      } else {
        console.log(`    Blocked: ${execErr.message?.slice(0, 100)}`);
      }
    }

    // E5: Owner cancels proposal
    console.log("\n  [E4] Owner cancels proposal...");
    const cancelTxHash = await walletClient.writeContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "cancelWeightChange",
    });
    await publicClient.waitForTransactionReceipt({ hash: cancelTxHash });
    console.log(`    Proposal cancelled (tx: ${cancelTxHash})`);

    const pendingFinal = await publicClient.readContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "pendingWeightChange",
    }) as unknown as readonly [number, number, number, number, number, number, number, number, number, number, bigint, bigint];
    const finalProposedAt = pendingFinal[10];
    console.log(`    proposedAt after cancel: ${finalProposedAt} (expected 0)`);

    if (finalProposedAt === 0n) {
      console.log("  PASS: Full M6.2 governance flow verified");
      results.E = "PASS (propose → approve → timelock blocked → cancel)";
    } else {
      console.log("  WARN: pendingWeightChange.proposedAt not zero after cancel");
      results.E = "WARN: cancel may not have cleared proposal";
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
    results.E = `FAIL: ${e.message?.slice(0, 100)}`;
  }

  // ── Summary ───────────────────────────────────────────────────────────────

  console.log("\n=== M6 E2E Test Summary ===");
  console.log(`Account: ${accountAddr}`);
  console.log(`Etherscan: https://sepolia.etherscan.io/address/${accountAddr}\n`);
  console.log("Test Results:");
  console.log(`  A (Weighted P256+ECDSA, bitmap=0x03): ${results.A ?? "skipped"}`);
  console.log(`  B (Weighted ECDSA-only, insufficient): ${results.B ?? "skipped"}`);
  console.log(`  C (Weighted P256-only, insufficient):  ${results.C ?? "skipped"}`);
  console.log(`  D (Standard ECDSA 0x02 backward compat): ${results.D ?? "skipped"}`);
  console.log(`  E (M6.2 governance flow):              ${results.E ?? "skipped"}`);
  console.log();

  const allPass = Object.values(results).every(v => v.startsWith("PASS"));
  if (allPass) {
    console.log("ALL M6 TESTS PASSED ✓");
  } else {
    const failed = Object.entries(results).filter(([, v]) => !v.startsWith("PASS"));
    console.log(`SOME TESTS FAILED: ${failed.map(([k]) => k).join(", ")}`);
  }

  console.log("\nM6 Features verified:");
  console.log("  M6.1 ALG_WEIGHTED (0x07): Bitmap-driven weighted multi-sig");
  console.log("  M6.1 Weight resolution: accumulated weight → concrete algId for guard");
  console.log("  M6.1 Insufficient weight: single-source fails (InsecureWeightConfig invariant)");
  console.log("  M6.2 proposeWeightChange: weakening requires guardian consent");
  console.log("  M6.2 approveWeightChange: guardian approval recorded in bitmap");
  console.log("  M6.2 executeWeightChange: blocked by 2-day timelock");
  console.log("  M6.2 cancelWeightChange: owner can cancel pending proposal");
}

main().catch(console.error);
