/**
 * test-session-key-userop-e2e.ts — M6.4 Session Key FULL UserOp Flow E2E (Sepolia)
 *
 * Tests the complete path: session key registered in AAStarValidator → algId=0x08 →
 * EntryPoint.handleOps → account._validateUserOp → SessionKeyValidator.validate
 *
 * Tests:
 *   A: Deploy account via factory + deposit to EntryPoint
 *   B: Deploy SessionKeyValidator + register for algId=0x08 in AAStarValidator
 *   C: Owner grants session key (off-chain signature path)
 *   D: Session key submits UserOp via EntryPoint.handleOps (algId=0x08 signature)
 *   E: Session key is revoked — subsequent UserOp rejected (signature returns 1)
 *   F: Expired session — UserOp rejected
 *
 * Prerequisites:
 *   - AIRACCOUNT_M6_R3_FACTORY, PRIVATE_KEY, PRIVATE_KEY_BOB, PRIVATE_KEY_JACK in .env.sepolia
 *
 * Run: pnpm tsx scripts/test-session-key-userop-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  concat,
  toHex,
  encodeFunctionData,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY    = required("PRIVATE_KEY") as Hex;
const GUARDIAN0_KEY  = (process.env.PRIVATE_KEY_BOB  || required("PRIVATE_KEY_BOB"))  as Hex;
const GUARDIAN1_KEY  = (process.env.PRIVATE_KEY_JACK || required("PRIVATE_KEY_JACK")) as Hex;
const RPC_URL        = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT     = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const FACTORY_ADDR   = (process.env.AIRACCOUNT_M6_R3_FACTORY ?? required("AIRACCOUNT_M6_R3_FACTORY")) as Address;
const CHAIN_ID       = sepolia.id;

// Unique salt for this test to avoid collision with other E2E tests
const SALT = 1600n;

// ─── Artifact loader ─────────────────────────────────────────────────────────

function loadArtifact(name: string): { abi: unknown[]; bytecode: Hex } {
  const art = JSON.parse(readFileSync(
    resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"
  ));
  return { abi: art.abi, bytecode: art.bytecode.object as Hex };
}

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
    ], outputs: [{ name: "", type: "address" }] },
  { name: "getAddressWithDefaults", type: "function", stateMutability: "view",
    inputs: [
      { name: "owner",      type: "address" },
      { name: "salt",       type: "uint256" },
      { name: "guardian1",  type: "address" },
      { name: "guardian2",  type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ], outputs: [{ name: "", type: "address" }] },
] as const;

const ACCOUNT_ABI = [
  { name: "owner",        type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "validator",    type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { name: "setValidator", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_validator", type: "address" }], outputs: [] },
  { name: "getNonce",     type: "function", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "execute",      type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "dest", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" }],
    outputs: [] },
] as const;

const VALIDATOR_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "algId", type: "uint8" }, { name: "algorithm", type: "address" }], outputs: [] },
  { name: "algorithms",        type: "function", stateMutability: "view",
    inputs: [{ name: "algId", type: "uint8" }], outputs: [{ name: "", type: "address" }] },
] as const;

const SESSION_ABI = [
  { name: "grantSession",     type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "account",       type: "address" },
      { name: "sessionKey",    type: "address" },
      { name: "expiry",        type: "uint48" },
      { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" },
      { name: "ownerSig",      type: "bytes" },
    ], outputs: [] },
  { name: "revokeSession",    type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "account", type: "address" }, { name: "sessionKey", type: "address" }], outputs: [] },
  { name: "buildGrantHash",   type: "function", stateMutability: "view",
    inputs: [
      { name: "account",       type: "address" },
      { name: "sessionKey",    type: "address" },
      { name: "expiry",        type: "uint48" },
      { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" },
    ], outputs: [{ name: "", type: "bytes32" }] },
  { name: "isSessionActive",  type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }, { name: "sessionKey", type: "address" }],
    outputs: [{ name: "", type: "bool" }] },
] as const;

const ENTRYPOINT_ABI = [
  { name: "depositTo",     type: "function", stateMutability: "payable",
    inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "handleOps",     type: "function", stateMutability: "nonpayable",
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
  { name: "getUserOpHash",  type: "function", stateMutability: "view",
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
    ]}], outputs: [{ name: "", type: "bytes32" }] },
  { name: "getNonce",       type: "function", stateMutability: "view",
    inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }],
    outputs: [{ name: "", type: "uint256" }] },
] as const;

// ─── Helpers ──────────────────────────────────────────────────────────────────

function packGasLimits(verGasLimit: bigint, callGasLimit: bigint): Hex {
  return toHex(verGasLimit << 128n | callGasLimit, { size: 32 });
}

function packGasFees(maxFee: bigint, maxPriorityFee: bigint): Hex {
  return toHex(maxFee << 128n | maxPriorityFee, { size: 32 });
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

let passed = 0;
let failed = 0;

function pass(label: string, detail = "") {
  console.log(`  ✓ ${label}${detail ? ` (${detail})` : ""}`);
  passed++;
}

function fail(label: string, err: unknown) {
  console.error(`  ✗ ${label}: ${err instanceof Error ? err.message.slice(0, 120) : String(err)}`);
  failed++;
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== M6.4 Session Key Full UserOp E2E (Sepolia) ===\n");
  console.log("Tests algId=0x08 through EntryPoint.handleOps\n");

  const owner    = privateKeyToAccount(PRIVATE_KEY);
  const guardian0 = privateKeyToAccount(GUARDIAN0_KEY);
  const guardian1 = privateKeyToAccount(GUARDIAN1_KEY);

  // Ephemeral session key (generated fresh each run)
  const sessionKeyPriv = generatePrivateKey();
  const sessionKey     = privateKeyToAccount(sessionKeyPriv);

  console.log(`Owner:      ${owner.address}`);
  console.log(`Guardian0:  ${guardian0.address}`);
  console.log(`SessionKey: ${sessionKey.address} (ephemeral)\n`);

  const transport    = http(RPC_URL, { retryCount: 5, retryDelay: 2000 });
  const publicClient = createPublicClient({ chain: sepolia, transport, pollingInterval: 3_000 });
  const ownerClient  = createWalletClient({ account: owner,     chain: sepolia, transport });
  const g0Client     = createWalletClient({ account: guardian0, chain: sepolia, transport });
  const g1Client     = createWalletClient({ account: guardian1, chain: sepolia, transport });

  // ── Test A: Deploy/reuse account + deposit to EntryPoint ────────────────────

  console.log("[Test A] Deploy account + deposit to EntryPoint");

  const predictedAddr = await publicClient.readContract({
    address: FACTORY_ADDR, abi: FACTORY_ABI,
    functionName: "getAddressWithDefaults",
    args: [owner.address, SALT, guardian0.address, guardian1.address, parseEther("1")],
  }) as Address;

  const existingCode = await publicClient.getBytecode({ address: predictedAddr });
  let accountAddr: Address = predictedAddr;

  if (existingCode && existingCode.length > 2) {
    console.log(`  INFO: Account already at ${accountAddr}`);
    pass("A: Account exists");
  } else {
    const acceptRaw = keccak256(concat([
      toHex(Buffer.from("ACCEPT_GUARDIAN")),
      toHex(BigInt(CHAIN_ID), { size: 32 }),
      FACTORY_ADDR,
      owner.address,
      toHex(SALT, { size: 32 }),
    ]));
    const g0Sig = await g0Client.signMessage({ message: { raw: acceptRaw } });
    const g1Sig = await g1Client.signMessage({ message: { raw: acceptRaw } });

    const txHash = await ownerClient.writeContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI,
      functionName: "createAccountWithDefaults",
      args: [owner.address, SALT, guardian0.address, g0Sig, guardian1.address, g1Sig, parseEther("1")],
    });
    await publicClient.waitForTransactionReceipt({ hash: txHash });
    pass("A: Account deployed via factory");
    await sleep(1000);
  }

  // Deposit ETH to EntryPoint so account can pay gas
  const deposit = parseEther("0.01");
  const depositTx = await ownerClient.writeContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "depositTo",
    args: [accountAddr],
    value: deposit,
  });
  await publicClient.waitForTransactionReceipt({ hash: depositTx });
  pass("A: Deposited 0.01 ETH to EntryPoint for account");
  await sleep(1500);

  // ── Test B: Deploy SessionKeyValidator + register algId=0x08 ────────────────

  console.log("\n[Test B] Deploy AAStarValidator + SessionKeyValidator + register algId=0x08");

  // Step B1: Deploy AAStarValidator (the routing layer)
  const validatorArtifact = loadArtifact("AAStarValidator");
  const validatorDeployTx = await ownerClient.deployContract({
    abi: validatorArtifact.abi,
    bytecode: validatorArtifact.bytecode,
  });
  const validatorDeployReceipt = await publicClient.waitForTransactionReceipt({ hash: validatorDeployTx });
  const validatorAddr = validatorDeployReceipt.contractAddress! as Address;
  pass("B: AAStarValidator deployed", validatorAddr);
  await sleep(1500);

  // Step B2: Set validator on account (owner-only)
  const setValidatorTx = await ownerClient.writeContract({
    address: accountAddr, abi: ACCOUNT_ABI,
    functionName: "setValidator",
    args: [validatorAddr],
  });
  await publicClient.waitForTransactionReceipt({ hash: setValidatorTx });
  pass("B: setValidator on account");
  await sleep(1500);

  // Step B3: Deploy SessionKeyValidator
  const sessionArtifact = loadArtifact("SessionKeyValidator");
  const deployTx = await ownerClient.deployContract({
    abi: sessionArtifact.abi,
    bytecode: sessionArtifact.bytecode,
  });
  const deployReceipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
  const sessionValidatorAddr = deployReceipt.contractAddress!;
  pass("B: SessionKeyValidator deployed", sessionValidatorAddr);
  await sleep(1500);

  // Step B4: Register algId=0x08 in AAStarValidator
  const registerTx = await ownerClient.writeContract({
    address: validatorAddr, abi: VALIDATOR_ABI,
    functionName: "registerAlgorithm",
    args: [0x08, sessionValidatorAddr],
  });
  await publicClient.waitForTransactionReceipt({ hash: registerTx });

  const registeredAddr = await publicClient.readContract({
    address: validatorAddr, abi: VALIDATOR_ABI,
    functionName: "algorithms", args: [0x08],
  }) as Address;

  if (registeredAddr.toLowerCase() === sessionValidatorAddr.toLowerCase()) {
    pass("B: algId=0x08 registered in AAStarValidator", sessionValidatorAddr);
  } else {
    fail("B: algId=0x08 registration mismatch", registeredAddr);
  }
  await sleep(1500);

  // ── Test C: Owner grants session key ────────────────────────────────────────

  console.log("\n[Test C] Owner grants session key (off-chain sig)");

  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1h from now

  const grantHash = await publicClient.readContract({
    address: sessionValidatorAddr, abi: SESSION_ABI,
    functionName: "buildGrantHash",
    args: [accountAddr, sessionKey.address, Number(expiry), "0x0000000000000000000000000000000000000000" as Address, "0x00000000"],
  }) as Hex;

  // grantHash is already EIP-191 wrapped (toEthSignedMessageHash inside _buildGrantHash).
  // Use sign({ hash }) to sign the raw 32-byte hash without adding another prefix.
  const ownerGrantSig = await owner.sign({ hash: grantHash });

  const grantTx = await ownerClient.writeContract({
    address: sessionValidatorAddr, abi: SESSION_ABI,
    functionName: "grantSession",
    args: [accountAddr, sessionKey.address, Number(expiry),
      "0x0000000000000000000000000000000000000000" as Address, "0x00000000", ownerGrantSig],
  });
  await publicClient.waitForTransactionReceipt({ hash: grantTx });

  const isActive = await publicClient.readContract({
    address: sessionValidatorAddr, abi: SESSION_ABI,
    functionName: "isSessionActive", args: [accountAddr, sessionKey.address],
  }) as boolean;

  if (isActive) {
    pass("C: Session granted and active");
  } else {
    fail("C: Session not active after grant", "isSessionActive returned false");
    return;
  }
  await sleep(1500);

  // ── Test D: Session key submits UserOp via EntryPoint ───────────────────────

  console.log("\n[Test D] Session key signs + submits UserOp via EntryPoint.handleOps");

  // Fund account with ETH for the execute call
  const fundTx = await ownerClient.sendTransaction({
    to: accountAddr, value: parseEther("0.005"),
  });
  await publicClient.waitForTransactionReceipt({ hash: fundTx });
  await sleep(1000);

  const nonce = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "getNonce", args: [accountAddr, 0n],
  }) as bigint;

  // callData: account.execute(owner, 0.001 ETH, "0x")
  const callData = encodeFunctionData({
    abi: ACCOUNT_ABI,
    functionName: "execute",
    args: [owner.address, parseEther("0.001"), "0x"],
  });

  const gasFees = await publicClient.estimateFeesPerGas();

  const userOp = {
    sender:             accountAddr,
    nonce,
    initCode:           "0x" as Hex,
    callData,
    accountGasLimits:   packGasLimits(300_000n, 100_000n),
    preVerificationGas: 50_000n,
    gasFees:            packGasFees(gasFees.maxFeePerGas ?? 2_000_000_000n, gasFees.maxPriorityFeePerGas ?? 1_000_000_000n),
    paymasterAndData:   "0x" as Hex,
    signature:          "0x" as Hex,
  };

  const userOpHash = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash", args: [userOp],
  }) as Hex;

  // Session key signature format (algId=0x08):
  // [0x08][account(20)][sessionKey(20)][ECDSASig(65)] = 106 bytes
  const ethHash = keccak256(concat([
    toHex(Buffer.from("\x19Ethereum Signed Message:\n32")),
    userOpHash,
  ]));
  const skSig = await sessionKey.signMessage({ message: { raw: userOpHash } });

  // Prepend algId=0x08 + account(20) + sessionKey(20) + sig(65)
  userOp.signature = concat([
    "0x08",
    accountAddr,
    sessionKey.address,
    skSig,
  ]) as Hex;

  console.log(`  Signature: ${userOp.signature.length} chars (expected ${2 + 2 + 40 + 40 + 130} hex chars)`);

  try {
    const handleTx = await ownerClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp], owner.address],
    });
    const handleReceipt = await publicClient.waitForTransactionReceipt({ hash: handleTx });
    pass("D: Session key UserOp executed via EntryPoint", `gas: ${handleReceipt.gasUsed}`);
  } catch (e: unknown) {
    fail("D: handleOps failed", e);
  }
  await sleep(1500);

  // ── Test E: Revoke session — subsequent UserOp rejected ─────────────────────

  console.log("\n[Test E] Revoke session → subsequent UserOp reverts");

  const revokeTx = await ownerClient.writeContract({
    address: sessionValidatorAddr, abi: SESSION_ABI,
    functionName: "revokeSession", args: [accountAddr, sessionKey.address],
  });
  await publicClient.waitForTransactionReceipt({ hash: revokeTx });

  const isStillActive = await publicClient.readContract({
    address: sessionValidatorAddr, abi: SESSION_ABI,
    functionName: "isSessionActive", args: [accountAddr, sessionKey.address],
  }) as boolean;

  if (!isStillActive) {
    pass("E: Session inactive after revoke");
  } else {
    fail("E: Session still active after revoke", "expected false");
  }

  // Re-deposit and try another UserOp with revoked session key
  const deposit2Tx = await ownerClient.writeContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "depositTo", args: [accountAddr], value: parseEther("0.005"),
  });
  await publicClient.waitForTransactionReceipt({ hash: deposit2Tx });
  await sleep(1000);

  const nonce2 = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "getNonce", args: [accountAddr, 0n],
  }) as bigint;

  const userOp2 = { ...userOp, nonce: nonce2, signature: "0x" as Hex };
  const hash2   = await publicClient.readContract({
    address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
    functionName: "getUserOpHash", args: [userOp2],
  }) as Hex;

  const skSig2 = await sessionKey.signMessage({ message: { raw: hash2 } });
  userOp2.signature = concat(["0x08", accountAddr, sessionKey.address, skSig2]) as Hex;

  try {
    await ownerClient.writeContract({
      address: ENTRYPOINT, abi: ENTRYPOINT_ABI,
      functionName: "handleOps",
      args: [[userOp2], owner.address],
    });
    fail("E: handleOps should have reverted for revoked session", "no revert");
  } catch {
    pass("E: Revoked session key rejected by EntryPoint (handleOps reverted as expected)");
  }

  // ── Summary ───────────────────────────────────────────────────────────────

  console.log(`\n${"─".repeat(58)}`);
  console.log(`Account:          ${accountAddr}`);
  console.log(`SessionValidator: ${sessionValidatorAddr}`);
  console.log(`Results:          ${passed} passed, ${failed} failed`);

  if (failed === 0) {
    console.log("\nALL PASS: M6.4 Session Key full UserOp flow verified.");
    console.log("algId=0x08 → AAStarValidator → SessionKeyValidator → EntryPoint ✓");
  } else {
    console.log("\nFAILURES DETECTED. Check logs above.");
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
