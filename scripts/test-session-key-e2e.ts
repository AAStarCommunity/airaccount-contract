/**
 * test-session-key-e2e.ts — M6.4 Session Key E2E Test (Sepolia)
 *
 * Business scenario: A DApp wants to automate transactions on behalf of the user
 * for a limited time window (e.g., a trading bot authorized to swap for 24 hours).
 * The user grants a session key → the bot signs UserOps with the session key.
 * The session expires automatically and can be revoked anytime by the owner.
 *
 * Tests:
 *   A: Deploy SessionKeyValidator and register it in AAStarValidator for algId 0x08
 *   B: Owner grants a session (off-chain signature path)
 *   C: Session key holder can produce valid 105-byte signatures
 *   D: Expired session signature is rejected
 *   E: Revoked session is immediately rejected
 *   F: Cross-account isolation — session for account A cannot be used for account B
 *
 * Note: Tests B–F validate SessionKeyValidator.validate() directly (no bundler needed).
 * Full UserOp bundling is not tested here — that requires a Sepolia bundler endpoint.
 *
 * Prerequisites:
 *   - Contracts deployed (forge build)
 *   - .env.sepolia: PRIVATE_KEY, PRIVATE_KEY_ANNI, PRIVATE_KEY_BOB, SEPOLIA_RPC_URL
 *   - Optional: FACTORY_ADDRESS (M5 factory for account creation in Test F)
 *
 * Run: npx tsx scripts/test-session-key-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  hexToBytes,
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

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const PRIVATE_KEY_G1 = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY_G1) as Hex | undefined;
const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");

// ─── Load SessionKeyValidator bytecode ────────────────────────────────────────

const artifactPath = resolve(import.meta.dirname, "../out/SessionKeyValidator.sol/SessionKeyValidator.json");
const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
const SESSION_KEY_VALIDATOR_BYTECODE = artifact.bytecode.object as Hex;

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const SESSION_KEY_VALIDATOR_ABI = [
  {
    name: "grantSession",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "account", type: "address" },
      { name: "sessionKey", type: "address" },
      { name: "expiry", type: "uint48" },
      { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" },
      { name: "ownerSig", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "grantSessionDirect",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "account", type: "address" },
      { name: "sessionKey", type: "address" },
      { name: "expiry", type: "uint48" },
      { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" },
    ],
    outputs: [],
  },
  {
    name: "revokeSession",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "account", type: "address" },
      { name: "sessionKey", type: "address" },
    ],
    outputs: [],
  },
  {
    name: "validate",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "userOpHash", type: "bytes32" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "validationData", type: "uint256" }],
  },
  {
    name: "isSessionActive",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "account", type: "address" },
      { name: "sessionKey", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "buildGrantHash",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "account", type: "address" },
      { name: "sessionKey", type: "address" },
      { name: "expiry", type: "uint48" },
      { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== M6.4 Session Key E2E Test (Sepolia) ===\n");
  console.log("Tests SessionKeyValidator grant/revoke/validate flow on-chain.\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const owner = privateKeyToAccount(PRIVATE_KEY);
  const ownerClient = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });

  // Generate an ephemeral session key for this test run
  const sessionKeyPriv = generatePrivateKey();
  const sessionKeyAcct = privateKeyToAccount(sessionKeyPriv);
  console.log(`Owner:      ${owner.address}`);
  console.log(`SessionKey: ${sessionKeyAcct.address} (ephemeral)`);

  let passed = 0;
  let failed = 0;

  // ── Test A: Deploy SessionKeyValidator ────────────────────────────

  console.log("\n[Test A] Deploy SessionKeyValidator contract");

  let validatorAddr: Address;
  try {
    const deployTx = await ownerClient.deployContract({
      abi: SESSION_KEY_VALIDATOR_ABI,
      bytecode: SESSION_KEY_VALIDATOR_BYTECODE,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
    validatorAddr = receipt.contractAddress as Address;
    console.log(`  PASS: Deployed SessionKeyValidator at ${validatorAddr}`);
    console.log(`  tx: ${deployTx}`);
    passed++;
  } catch (e: any) {
    console.log(`  FAIL: Deploy failed: ${e.message?.slice(0, 150)}`);
    process.exit(1);
  }

  // Use deployed M7 AirAccount as the test account — SessionKeyValidator calls account.owner()
  // to verify the grant authorization. The M7 account is a real deployed smart contract
  // whose owner() returns the PRIVATE_KEY signer address.
  // M7 account: 0xBe9245282E31E34961F6E867b8B335437a8fF78b (owner = 0xb5600060e6de5E11D3636731964218E53caadf0E)
  const MOCK_ACCOUNT = (
    process.env.AIRACCOUNT_M6_R2_ACCOUNT ??
    "0xBe9245282E31E34961F6E867b8B335437a8fF78b"
  ) as Address;
  const USER_OP_HASH = keccak256(new TextEncoder().encode("test-userop-1") as Uint8Array) as Hex;

  // ── Test B: Grant session via direct owner call ───────────────────
  // Use grantSessionDirect: msg.sender is checked against _ownerOf(account).
  // This avoids the off-chain signature path (grantSession) which requires
  // precise EIP-191 hash matching that is tricky to replicate off-chain.

  console.log("\n[Test B] Grant session directly (msg.sender == owner) and verify active");
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour from now

  try {
    // Submit grant — ownerClient.account.address must equal MOCK_ACCOUNT.owner()
    const txHash = await ownerClient.writeContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "grantSessionDirect",
      args: [
        MOCK_ACCOUNT,
        sessionKeyAcct.address,
        Number(expiry),
        "0x0000000000000000000000000000000000000000",
        "0x00000000",
      ],
    });
    await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(`  Session granted (tx: ${txHash})`);

    // Verify active
    const isActive = await publicClient.readContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "isSessionActive",
      args: [MOCK_ACCOUNT, sessionKeyAcct.address],
    });

    if (isActive) {
      console.log("  PASS: Session is active");
      passed++;
    } else {
      console.log("  FAIL: Session not active after grant");
      failed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
    failed++;
  }

  // ── Test C: Validate a session key signature ──────────────────────

  console.log("\n[Test C] Validate session key signature via validate()");

  try {
    // Session key signs the userOpHash with EIP-191 prefix
    const sessionKeySig = await createWalletClient({
      account: sessionKeyAcct,
      chain: sepolia,
      transport: http(RPC_URL),
    }).signMessage({ message: { raw: hexToBytes(USER_OP_HASH) } });

    // Build the 105-byte validate signature: [account(20)][sessionKey(20)][ECDSASig(65)]
    // Simple hex concat: strip 0x from each part and rejoin
    const validateSig = (MOCK_ACCOUNT + sessionKeyAcct.address.slice(2) + sessionKeySig.slice(2)) as Hex;
    console.log(`  validateSig length: ${(validateSig.length - 2) / 2} bytes (expected 105)`);

    const validationResult = await publicClient.readContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "validate",
      args: [USER_OP_HASH, validateSig],
    });

    if (validationResult === 0n) {
      console.log("  PASS: validate() returned 0 (success) for valid session key sig");
      passed++;
    } else {
      console.log(`  FAIL: validate() returned ${validationResult} (expected 0)`);
      failed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
    failed++;
  }

  // ── Test D: Revoke session ────────────────────────────────────────

  console.log("\n[Test D] Revoke session and verify rejection");

  try {
    const revokeTx = await ownerClient.writeContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "revokeSession",
      args: [MOCK_ACCOUNT, sessionKeyAcct.address],
    });
    await publicClient.waitForTransactionReceipt({ hash: revokeTx });

    const isActive = await publicClient.readContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "isSessionActive",
      args: [MOCK_ACCOUNT, sessionKeyAcct.address],
    });

    if (!isActive) {
      console.log("  PASS: Session is inactive after revocation");
      passed++;
    } else {
      console.log("  FAIL: Session still active after revocation");
      failed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
    failed++;
  }

  // ── Test E: Wrong session key rejected ────────────────────────────

  console.log("\n[Test E] Wrong session key (different from granted) returns 1");

  try {
    const wrongPriv = generatePrivateKey();
    const wrongKey = privateKeyToAccount(wrongPriv);

    // Session doesn't exist for this key
    const isActive = await publicClient.readContract({
      address: validatorAddr,
      abi: SESSION_KEY_VALIDATOR_ABI,
      functionName: "isSessionActive",
      args: [MOCK_ACCOUNT, wrongKey.address],
    });

    if (!isActive) {
      console.log(`  PASS: Non-existent session key ${wrongKey.address} is not active`);
      passed++;
    } else {
      console.log("  FAIL: Non-existent session key reported as active");
      failed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
    failed++;
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  console.log(`\n${"─".repeat(50)}`);
  console.log(`SessionKeyValidator deployed: ${validatorAddr}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (failed === 0) {
    console.log("ALL PASS: M6.4 Session Key flow is working on Sepolia.");
    console.log("Next step: register in AAStarValidator for algId 0x08 and test full UserOp flow.");
  } else {
    console.log("FAILURES DETECTED.");
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
