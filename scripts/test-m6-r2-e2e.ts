/**
 * test-m6-r2-e2e.ts — M6 r2 E2E Tests: Factory clone pattern + guard externalization (Sepolia)
 *
 * Tests M7 EIP-170 compliance fix:
 *   1. Deploy account via createAccountWithDefaults (factory is now EIP-170 compliant)
 *   2. Verify account is a clone (45-byte proxy) with correctly attached guard
 *   3. Verify guard has dailyLimit, approved algorithms, bound to account address
 *   4. Run standard ECDSA UserOp (backward compat)
 *   5. Run ALG_WEIGHTED P256+ECDSA (M6.1 feature still works via factory)
 *
 * Prerequisites:
<<<<<<< HEAD
 *   - pnpm tsx scripts/deploy-m6-r2.ts (set AIRACCOUNT_M6_R3_FACTORY in .env.sepolia)
=======
 *   - pnpm tsx scripts/deploy-m6-r2.ts (set AIRACCOUNT_M6_R4_FACTORY in .env.sepolia)
>>>>>>> main
 *   - PRIVATE_KEY, PRIVATE_KEY_BOB, PRIVATE_KEY_JACK in .env.sepolia
 *
 * Run: pnpm tsx scripts/test-m6-r2-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  concat,
  toHex,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { sepolia } from "viem/chains";
import { p256 } from "@noble/curves/p256";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY    = required("PRIVATE_KEY") as Hex;
const GUARDIAN0_KEY  = (process.env.PRIVATE_KEY_BOB  || required("PRIVATE_KEY_BOB")) as Hex;
const GUARDIAN1_KEY  = (process.env.PRIVATE_KEY_JACK || required("PRIVATE_KEY_JACK")) as Hex;
const RPC_URL        = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT     = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
<<<<<<< HEAD
const FACTORY_ADDR   = (process.env.AIRACCOUNT_M6_R3_FACTORY ?? required("AIRACCOUNT_M6_R3_FACTORY")) as Address;
=======
const FACTORY_ADDR   = (process.env.AIRACCOUNT_M6_R4_FACTORY ?? required("AIRACCOUNT_M6_R4_FACTORY")) as Address;
>>>>>>> main

const CHAIN_ID = sepolia.id; // 11155111

// Deterministic P256 private key for testing (NOT production use)
const P256_PRIVATE_KEY_HEX = "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3";

const SALT = 800n; // M6 r2 test salt

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const FACTORY_ABI = [
  { name: "createAccountWithDefaults", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "owner",        type: "address" },
      { name: "salt",         type: "uint256" },
      { name: "guardian1",    type: "address" },
      { name: "guardian1Sig", type: "bytes" },
      { name: "guardian2",    type: "address" },
      { name: "guardian2Sig", type: "bytes" },
      { name: "dailyLimit",   type: "uint256" },
    ], outputs: [{ name: "account", type: "address" }] },
  { name: "getAddressWithDefaults", type: "function", stateMutability: "view",
    inputs: [
      { name: "owner",      type: "address" },
      { name: "salt",       type: "uint256" },
      { name: "guardian1",  type: "address" },
      { name: "guardian2",  type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ], outputs: [{ name: "", type: "address" }] },
  { name: "implementation", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address" }] },
] as const;

const ACCOUNT_ABI = [
  { name: "owner",    type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "guard",    type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "guardians", type: "function", stateMutability: "view",
    inputs: [{ name: "i", type: "uint256" }], outputs: [{ name: "", type: "address" }] },
  { name: "version",  type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "string" }] },
  { name: "p256KeyX", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "bytes32" }] },
  { name: "setP256Key", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_x", type: "bytes32" }, { name: "_y", type: "bytes32" }], outputs: [] },
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
    ]}], outputs: [] },
] as const;

const GUARD_ABI = [
  { name: "account",    type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "dailyLimit", type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "approvedAlgorithms", type: "function", stateMutability: "view",
    inputs: [{ name: "algId", type: "uint8" }], outputs: [{ name: "", type: "bool" }] },
] as const;

const ENTRYPOINT_ABI = [
  { name: "depositTo", type: "function", stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "handleOps", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "ops", type: "tuple[]", components: [
        { name: "sender", type: "address" }, { name: "nonce", type: "uint256" },
        { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" },
        { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
        { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" },
        { name: "signature", type: "bytes" },
      ]},
      { name: "beneficiary", type: "address" },
    ], outputs: [] },
  { name: "getUserOpHash", type: "function", stateMutability: "view",
    inputs: [{ name: "userOp", type: "tuple", components: [
      { name: "sender", type: "address" }, { name: "nonce", type: "uint256" },
      { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" },
      { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
      { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" },
      { name: "signature", type: "bytes" },
    ]}], outputs: [{ name: "", type: "bytes32" }] },
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getP256PublicKey(privKeyHex: string): [Hex, Hex] {
  const privKeyBytes = Uint8Array.from(Buffer.from(privKeyHex, "hex"));
  const pubKey = p256.getPublicKey(privKeyBytes, false); // uncompressed
  const x = toHex(pubKey.slice(1, 33)) as Hex;
  const y = toHex(pubKey.slice(33, 65)) as Hex;
  return [x, y];
}

function signP256(msgHash: Uint8Array, privKeyHex: string): { r: Hex; s: Hex } {
  const privKeyBytes = Uint8Array.from(Buffer.from(privKeyHex, "hex"));
  const sig = p256.sign(msgHash, privKeyBytes, { lowS: true });
  return {
    r: toHex(sig.r, { size: 32 }),
    s: toHex(sig.s, { size: 32 }),
  };
}

function packGasLimits(verificationGasLimit: bigint, callGasLimit: bigint): Hex {
  return toHex(BigInt(verificationGasLimit) << 128n | BigInt(callGasLimit), { size: 32 });
}

function packGasFees(maxFeePerGas: bigint, maxPriorityFeePerGas: bigint): Hex {
  return toHex(BigInt(maxFeePerGas) << 128n | BigInt(maxPriorityFeePerGas), { size: 32 });
}

let testsPassed = 0;
let testsFailed = 0;

function pass(label: string, detail: string = "") {
  console.log(`  ✓ ${label}${detail ? ` (${detail})` : ""}`);
  testsPassed++;
}

function fail(label: string, err: unknown) {
  console.error(`  ✗ ${label}: ${err instanceof Error ? err.message : String(err)}`);
  testsFailed++;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== M6 r2 E2E Tests: Clone Factory + Guard Externalization (Sepolia) ===\n");

  const owner    = privateKeyToAccount(PRIVATE_KEY);
  const guardian0 = privateKeyToAccount(GUARDIAN0_KEY);
  const guardian1 = privateKeyToAccount(GUARDIAN1_KEY);

  console.log(`Factory:   ${FACTORY_ADDR}`);
  console.log(`Owner:     ${owner.address}`);
  console.log(`Guardian0: ${guardian0.address}`);
  console.log(`Guardian1: ${guardian1.address}\n`);

  // pollingInterval: 3s avoids Alchemy "in-flight limit" errors on free tier
  const transport = http(RPC_URL, { retryCount: 3, retryDelay: 1500 });
  const publicClient = createPublicClient({ chain: sepolia, transport, pollingInterval: 3_000 });
  const walletClient = createWalletClient({ account: owner, chain: sepolia, transport });
  const g0Client = createWalletClient({ account: guardian0, chain: sepolia, transport });
  const g1Client = createWalletClient({ account: guardian1, chain: sepolia, transport });

  // ── Test A: Deploy account via factory ────────────────────────────────────

  console.log("── Test A: Deploy account via createAccountWithDefaults ────");

  // Predict address
  const predictedAddr = await publicClient.readContract({
    address: FACTORY_ADDR,
    abi: FACTORY_ABI,
    functionName: "getAddressWithDefaults",
    args: [owner.address, SALT, guardian0.address, guardian1.address, parseEther("1")],
  }) as Address;
  console.log(`  Predicted address: ${predictedAddr}`);

  const existingCode = await publicClient.getBytecode({ address: predictedAddr });
  let accountAddr: Address;

  if (existingCode && existingCode.length > 2) {
    console.log(`  Account already deployed (${existingCode.length / 2 - 1} bytes)`);
    accountAddr = predictedAddr;
    pass("A: Account already exists at predicted address");
  } else {
    // Build guardian acceptance signatures
    // Hash: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", block.chainid, factory, owner, salt)).toEthSignedMessageHash()
    const acceptRaw = keccak256(
      concat([
        toHex(Buffer.from("ACCEPT_GUARDIAN")),
        toHex(BigInt(CHAIN_ID), { size: 32 }),
        FACTORY_ADDR,
        owner.address,
        toHex(SALT, { size: 32 }),
      ])
    );
    const ethPrefixedHash = keccak256(
      concat([
        toHex(Buffer.from("\x19Ethereum Signed Message:\n32")),
        acceptRaw,
      ])
    );

    const g0Sig = await g0Client.signMessage({ message: { raw: acceptRaw } });
    const g1Sig = await g1Client.signMessage({ message: { raw: acceptRaw } });

    const txHash = await walletClient.writeContract({
      address: FACTORY_ADDR,
      abi: FACTORY_ABI,
      functionName: "createAccountWithDefaults",
      args: [owner.address, SALT, guardian0.address, g0Sig, guardian1.address, g1Sig, parseEther("1")],
    });
    console.log(`  TX: ${txHash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    accountAddr = predictedAddr;
    console.log(`  Account deployed: ${accountAddr} (gas: ${receipt.gasUsed})`);
    pass("A: Account deployed via factory", `gas: ${receipt.gasUsed}`);
  }

  // Verify it's a clone (runtime = 45 bytes for EIP-1167 minimal proxy)
  const code = await publicClient.getBytecode({ address: accountAddr });
  const codeLen = code ? code.length / 2 - 1 : 0;
  if (codeLen === 45) {
    pass("A: Account is EIP-1167 minimal proxy (45 bytes)");
  } else {
    fail("A: Expected 45-byte clone", `got ${codeLen} bytes`);
  }

  // ── Test B: Verify account state ──────────────────────────────────────────

  console.log("\n── Test B: Verify account state ────────────────────────────");

  try {
    const [accOwner, guardAddr, g0, g1, g2, ver] = await Promise.all([
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "owner" }),
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "guard" }),
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "guardians", args: [0n] }),
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "guardians", args: [1n] }),
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "guardians", args: [2n] }),
      publicClient.readContract({ address: accountAddr, abi: ACCOUNT_ABI, functionName: "version" }),
    ]);

    console.log(`  Owner:    ${accOwner}`);
    console.log(`  Guard:    ${guardAddr}`);
    console.log(`  Guardian0: ${g0}`);
    console.log(`  Guardian1: ${g1}`);
    console.log(`  Guardian2: ${g2}`);
    console.log(`  Version:  ${ver}`);

    if (accOwner.toLowerCase() === owner.address.toLowerCase()) pass("B: owner correct");
    else fail("B: owner mismatch", `expected ${owner.address}, got ${accOwner}`);

    if (guardAddr !== "0x0000000000000000000000000000000000000000") pass("B: guard deployed");
    else fail("B: guard not deployed", "address(0)");

    if (g0.toLowerCase() === guardian0.address.toLowerCase()) pass("B: guardian0 correct");
    else fail("B: guardian0 mismatch", `expected ${guardian0.address}, got ${g0}`);

    if (g1.toLowerCase() === guardian1.address.toLowerCase()) pass("B: guardian1 correct");
    else fail("B: guardian1 mismatch", `expected ${guardian1.address}, got ${g1}`);

    // ── Verify guard state ──────────────────────────────────────────────────
    const [guardAccount, guardLimit, alg02Approved, alg07Approved] = await Promise.all([
      publicClient.readContract({ address: guardAddr as Address, abi: GUARD_ABI, functionName: "account" }),
      publicClient.readContract({ address: guardAddr as Address, abi: GUARD_ABI, functionName: "dailyLimit" }),
      publicClient.readContract({ address: guardAddr as Address, abi: GUARD_ABI, functionName: "approvedAlgorithms", args: [0x02] }),
      publicClient.readContract({ address: guardAddr as Address, abi: GUARD_ABI, functionName: "approvedAlgorithms", args: [0x07] }),
    ]);

    console.log(`  Guard.account:    ${guardAccount}`);
    console.log(`  Guard.dailyLimit: ${formatEther(guardLimit as bigint)} ETH`);
    console.log(`  Guard.alg02:      ${alg02Approved}`);
    console.log(`  Guard.alg07:      ${alg07Approved}`);

    if ((guardAccount as string).toLowerCase() === accountAddr.toLowerCase()) pass("B: guard bound to account");
    else fail("B: guard.account mismatch", `expected ${accountAddr}, got ${guardAccount}`);

    if (guardLimit === parseEther("1")) pass("B: guard dailyLimit = 1 ETH");
    else fail("B: guard dailyLimit wrong", `${formatEther(guardLimit as bigint)} ETH`);

    if (alg02Approved) pass("B: guard approves ALG_ECDSA (0x02)");
    else fail("B: ALG_ECDSA not approved", "");

    if (alg07Approved) pass("B: guard approves ALG_WEIGHTED (0x07)");
    else fail("B: ALG_WEIGHTED not approved", "");

  } catch (e) {
    fail("B: state verification", e);
  }

  // ── Test C: Standard ECDSA UserOp ─────────────────────────────────────────

  console.log("\n── Test C: Standard ECDSA E2E ──────────────────────────────");

  try {
    // Fund account
    const accBalance = await publicClient.getBalance({ address: accountAddr });
    if (accBalance < parseEther("0.01")) {
      const fundTx = await walletClient.sendTransaction({
        to: accountAddr,
        value: parseEther("0.02"),
      });
      await publicClient.waitForTransactionReceipt({ hash: fundTx });
      console.log(`  Funded account with 0.02 ETH`);
    }

    // Deposit to EntryPoint
    const epBalance = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
        inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }],
      functionName: "balanceOf",
      args: [accountAddr],
    }) as bigint;

    if (epBalance < parseEther("0.005")) {
      const depTx = await walletClient.writeContract({
        address: ENTRYPOINT,
        abi: ENTRYPOINT_ABI,
        functionName: "depositTo",
        args: [accountAddr],
        value: parseEther("0.01"),
      });
      await publicClient.waitForTransactionReceipt({ hash: depTx });
      console.log(`  Deposited 0.01 ETH to EntryPoint`);
    }

    // Build UserOp (ECDSA, algId=0x02)
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: [{ name: "getNonce", type: "function", stateMutability: "view",
        inputs: [{ type: "address" }, { type: "uint192" }], outputs: [{ type: "uint256" }] }],
      functionName: "getNonce",
      args: [accountAddr, 0n],
    }) as bigint;

    const callData = "0x"; // empty call
    const userOp = {
      sender: accountAddr,
      nonce,
      initCode: "0x" as Hex,
      callData: callData as Hex,
      accountGasLimits: packGasLimits(200000n, 50000n),
      preVerificationGas: 50000n,
      gasFees: packGasFees(parseEther("0.000000002"), parseEther("0.000000001")),
      paymasterAndData: "0x" as Hex,
      signature: "0x" as Hex,
    };

    const userOpHash = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "getUserOpHash",
      args: [userOp],
    }) as Hex;

    // Sign with ECDSA (explicit algId=0x02 prefix)
    const ethHash = keccak256(
      concat([toHex(Buffer.from("\x19Ethereum Signed Message:\n32")), userOpHash])
    );
    const rawSig = await owner.sign({ hash: ethHash });
    // rawSig is 65 bytes: r(32) + s(32) + v(1). Prepend algId=0x02
    const sig = concat(["0x02", rawSig]) as Hex;

    userOp.signature = sig;

    const handleTx = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], owner.address],
    });
    const handleReceipt = await publicClient.waitForTransactionReceipt({ hash: handleTx });
    pass("C: ECDSA UserOp executed", `gas: ${handleReceipt.gasUsed}`);
    console.log(`  TX: ${handleTx}`);

  } catch (e) {
    fail("C: ECDSA E2E", e);
  }

  // ── Test D: ALG_WEIGHTED P256+ECDSA ───────────────────────────────────────

  console.log("\n── Test D: ALG_WEIGHTED P256+ECDSA ────────────────────────");

  try {
    // Set P256 key if not set
    const storedKeyX = await publicClient.readContract({
      address: accountAddr, abi: ACCOUNT_ABI, functionName: "p256KeyX",
    });

    if (storedKeyX === "0x0000000000000000000000000000000000000000000000000000000000000000") {
      const [px, py] = getP256PublicKey(P256_PRIVATE_KEY_HEX);
      const setKeyTx = await walletClient.writeContract({
        address: accountAddr, abi: ACCOUNT_ABI, functionName: "setP256Key", args: [px, py],
      });
      await publicClient.waitForTransactionReceipt({ hash: setKeyTx });
      console.log(`  P256 key registered`);
    } else {
      console.log(`  P256 key already set`);
    }

    // Set weight config (no single source reaches tier1Threshold)
    const safeConfig = {
      passkeyWeight: 2, ecdsaWeight: 2, blsWeight: 2,
      guardian0Weight: 1, guardian1Weight: 1, guardian2Weight: 1,
      _padding: 0,
      tier1Threshold: 3, tier2Threshold: 4, tier3Threshold: 6,
    };

    try {
      const cfgTx = await walletClient.writeContract({
        address: accountAddr, abi: ACCOUNT_ABI, functionName: "setWeightConfig", args: [safeConfig],
      });
      await publicClient.waitForTransactionReceipt({ hash: cfgTx });
      console.log(`  Weight config set`);
    } catch {
      console.log(`  Weight config already set (or setWeightConfig failed — skipping)`);
    }

    // Build ALG_WEIGHTED UserOp: bitmap=0x03 (P256 + ECDSA), accumulated weight=4 ≥ tier2Threshold
    const nonce = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: [{ name: "getNonce", type: "function", stateMutability: "view",
        inputs: [{ type: "address" }, { type: "uint192" }], outputs: [{ type: "uint256" }] }],
      functionName: "getNonce",
      args: [accountAddr, 0n],
    }) as bigint;

    const userOp = {
      sender: accountAddr,
      nonce,
      initCode: "0x" as Hex,
      callData: "0x" as Hex,
      accountGasLimits: packGasLimits(200000n, 50000n),
      preVerificationGas: 50000n,
      gasFees: packGasFees(parseEther("0.000000002"), parseEther("0.000000001")),
      paymasterAndData: "0x" as Hex,
      signature: "0x" as Hex,
    };

    const userOpHash = await publicClient.readContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "getUserOpHash",
      args: [userOp],
    }) as Hex;

    const hashBytes = Uint8Array.from(Buffer.from(userOpHash.slice(2), "hex"));

    // P256 component: [r(32)][s(32)] = 64 bytes
    const p256Sig = signP256(hashBytes, P256_PRIVATE_KEY_HEX);

    // ECDSA component: owner signs with EIP-191 prefix, 65 bytes
    const ethHash = keccak256(
      concat([toHex(Buffer.from("\x19Ethereum Signed Message:\n32")), userOpHash])
    );
    const ecdsaRawSig = await owner.sign({ hash: ethHash });

    // Full weighted sig: [algId=0x07][bitmap=0x03][P256_r][P256_s][ECDSA_65]
    const weightedSig = concat([
      "0x07",           // ALG_WEIGHTED
      "0x03",           // bitmap: bit0=P256, bit1=ECDSA
      p256Sig.r,        // P256 r (32 bytes)
      p256Sig.s,        // P256 s (32 bytes)
      ecdsaRawSig,      // ECDSA 65 bytes
    ]) as Hex;

    userOp.signature = weightedSig;

    const handleTx = await walletClient.writeContract({
      address: ENTRYPOINT,
      abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], owner.address],
    });
    const handleReceipt = await publicClient.waitForTransactionReceipt({ hash: handleTx });
    pass("D: ALG_WEIGHTED P256+ECDSA (bitmap=0x03)", `gas: ${handleReceipt.gasUsed}`);
    console.log(`  TX: ${handleTx}`);

  } catch (e) {
    fail("D: ALG_WEIGHTED", e);
  }

  // ── Summary ───────────────────────────────────────────────────────────────

  console.log("\n═══════════════════════════════════════");
  console.log(`M6 r2 E2E Results: ${testsPassed} pass, ${testsFailed} fail`);
  console.log(`Account: ${predictedAddr}`);
  console.log(`Factory: ${FACTORY_ADDR}`);
  console.log("═══════════════════════════════════════");

  if (testsFailed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("Fatal error:", err.message ?? err);
  process.exit(1);
});
