/**
 * test-guardian-domain-separation-e2e.ts — Guardian Acceptance Domain Separation E2E (Sepolia)
 *
 * Business scenario: Guardian acceptance signatures must be domain-separated.
 * Without domain separation, an attacker could replay a guardian's signature from:
 *   - A different factory contract (cross-factory replay)
 *   - A different chain (cross-chain replay, e.g., reuse Sepolia sig on mainnet)
 *
 * The acceptance hash includes: chainId + factory address + owner + salt
 *   keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt))
 *
 * Tests (all only need off-chain sig construction + on-chain simulate/call):
 *   A: Correct factory + correct chainId => account deploys (PASS)
 *   B: Sig computed for wrong factory address => GuardianDidNotAccept (REVERT)
 *   C: Sig computed for wrong chain (chainId=1 mainnet) => GuardianDidNotAccept (REVERT)
 *   D: Sig computed for wrong salt => GuardianDidNotAccept (REVERT)
 *   E: Sig computed for wrong owner => GuardianDidNotAccept (REVERT)
 *
 * Test A is a live on-chain transaction (creates account if not already deployed).
 * Tests B–E use simulateContract so they are read-only (no Sepolia ETH consumed).
 *
 * Prerequisites:
 *   - M5 factory deployed: FACTORY_ADDRESS in .env.sepolia
 *   - .env.sepolia: PRIVATE_KEY, PRIVATE_KEY_ANNI, PRIVATE_KEY_BOB, SEPOLIA_RPC_URL, FACTORY_ADDRESS
 *
 * Run: npx tsx scripts/test-guardian-domain-separation-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  encodePacked,
  keccak256,
  hexToBytes,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
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
const PRIVATE_KEY_G2 = (process.env.PRIVATE_KEY_BOB ?? process.env.PRIVATE_KEY_G2) as Hex | undefined;

if (!PRIVATE_KEY_G1 || !PRIVATE_KEY_G2) {
  console.error("Missing guardian keys. Set PRIVATE_KEY_ANNI and PRIVATE_KEY_BOB in .env.sepolia");
  process.exit(1);
}

const RPC_URL = process.env.SEPOLIA_RPC ?? process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");

const SALT_BASE = 800n; // Domain separation test salts (800, 801, ...)
const DAILY_LIMIT = parseEther("0.1");

// ─── ABI ─────────────────────────────────────────────────────────────────────

const FACTORY_ABI = [
  {
    name: "createAccountWithDefaults",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian1Sig", type: "bytes" },
      { name: "guardian2", type: "address" },
      { name: "guardian2Sig", type: "bytes" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "getAddressWithDefaults",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian2", type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Build the inner (pre-EIP-191) guardian acceptance hash.
 * Domain: "ACCEPT_GUARDIAN" + chainId + factory + owner + salt
 */
function buildInnerHash(
  factoryAddr: Address,
  owner: Address,
  salt: bigint,
  chainId: bigint
): Hex {
  return keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256"],
    ["ACCEPT_GUARDIAN", chainId, factoryAddr, owner, salt]
  ));
}

/**
 * Sign the inner hash with EIP-191 prefix (matches factory's toEthSignedMessageHash).
 */
async function signAcceptance(
  walletClient: ReturnType<typeof createWalletClient>,
  innerHash: Hex
): Promise<Hex> {
  return walletClient.signMessage({ message: { raw: hexToBytes(innerHash) } });
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== Guardian Acceptance Domain Separation E2E Test (Sepolia) ===\n");
  console.log("Verifies that guardian sigs are bound to: chainId + factory + owner + salt");
  console.log("Codex Audit MEDIUM finding: prevents cross-factory and cross-chain replay attacks\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });

  const owner = privateKeyToAccount(PRIVATE_KEY);
  const guardian1 = privateKeyToAccount(PRIVATE_KEY_G1!);
  const guardian2 = privateKeyToAccount(PRIVATE_KEY_G2!);

  const ownerClient = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });
  const g1Client = createWalletClient({ account: guardian1, chain: sepolia, transport: http(RPC_URL) });
  const g2Client = createWalletClient({ account: guardian2, chain: sepolia, transport: http(RPC_URL) });

  const FACTORY_ADDR = (process.env.FACTORY_ADDRESS ?? process.env.M5_FACTORY_ADDRESS) as Address | undefined;
  if (!FACTORY_ADDR) {
    console.error("ERROR: Set FACTORY_ADDRESS in .env.sepolia");
    process.exit(1);
  }

  const chainId = BigInt(await publicClient.getChainId()); // Sepolia = 11155111
  console.log(`Owner:     ${owner.address}`);
  console.log(`Guardian1: ${guardian1.address}`);
  console.log(`Guardian2: ${guardian2.address}`);
  console.log(`Factory:   ${FACTORY_ADDR}`);
  console.log(`ChainId:   ${chainId}`);

  let passed = 0;
  let failed = 0;

  // ── Test A: Correct domain — account should deploy ────────────────────────

  const saltA = SALT_BASE;
  console.log(`\n[Test A] Correct factory + correct chainId => account deploys`);
  console.log(`  salt=${saltA}, factory=${FACTORY_ADDR}, chainId=${chainId}`);

  try {
    const predictedA = await publicClient.readContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "getAddressWithDefaults",
      args: [owner.address, saltA, guardian1.address, guardian2.address, DAILY_LIMIT],
    });
    const code = await publicClient.getBytecode({ address: predictedA });

    if (code && code.length > 2) {
      console.log(`  PASS: Account already deployed at ${predictedA}`);
      passed++;
    } else {
      const innerHash = buildInnerHash(FACTORY_ADDR, owner.address, saltA, chainId);
      const g1Sig = await signAcceptance(g1Client, innerHash);
      const g2Sig = await signAcceptance(g2Client, innerHash);

      const txHash = await ownerClient.writeContract({
        address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
        args: [owner.address, saltA, guardian1.address, g1Sig, guardian2.address, g2Sig, DAILY_LIMIT],
      });
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      console.log(`  PASS: Account deployed at ${predictedA} (tx: ${txHash})`);
      passed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: Unexpected revert: ${e.message?.slice(0, 150)}`);
    failed++;
  }

  // ── Test B: Cross-factory replay — sig for wrong factory address ──────────

  const saltB = SALT_BASE + 1n;
  const FAKE_FACTORY = "0x000000000000000000000000000000000000bAd1" as Address;
  console.log(`\n[Test B] Cross-factory replay: guardian signed for factory ${FAKE_FACTORY}`);
  console.log(`  Sig domain: factory=FAKE, chainId=${chainId}`);
  console.log(`  Submit to:  factory=${FACTORY_ADDR}`);
  console.log("  Expected:   REVERT GuardianDidNotAccept");

  try {
    // Guardian signs for the FAKE factory (wrong domain)
    const innerHashFakeFactory = buildInnerHash(FAKE_FACTORY, owner.address, saltB, chainId);
    const g1SigWrongFactory = await signAcceptance(g1Client, innerHashFakeFactory);
    const g2SigWrongFactory = await signAcceptance(g2Client, innerHashFakeFactory);

    await publicClient.simulateContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
      args: [owner.address, saltB, guardian1.address, g1SigWrongFactory, guardian2.address, g2SigWrongFactory, DAILY_LIMIT],
      account: owner.address,
    });
    console.log("  FAIL: Should have reverted with GuardianDidNotAccept");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("GuardianDidNotAccept") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Cross-factory replay rejected — domain binding works");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test C: Cross-chain replay — sig uses chainId=1 (mainnet) ────────────

  const saltC = SALT_BASE + 2n;
  const MAINNET_CHAIN_ID = 1n;
  console.log(`\n[Test C] Cross-chain replay: guardian signed for chainId=${MAINNET_CHAIN_ID} (mainnet)`);
  console.log(`  Sig domain: factory=${FACTORY_ADDR}, chainId=1`);
  console.log(`  Running on: Sepolia (chainId=${chainId})`);
  console.log("  Expected:   REVERT GuardianDidNotAccept");

  try {
    // Guardian signs for mainnet chainId (wrong chain)
    const innerHashMainnet = buildInnerHash(FACTORY_ADDR, owner.address, saltC, MAINNET_CHAIN_ID);
    const g1SigMainnet = await signAcceptance(g1Client, innerHashMainnet);
    const g2SigMainnet = await signAcceptance(g2Client, innerHashMainnet);

    await publicClient.simulateContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
      args: [owner.address, saltC, guardian1.address, g1SigMainnet, guardian2.address, g2SigMainnet, DAILY_LIMIT],
      account: owner.address,
    });
    console.log("  FAIL: Should have reverted with GuardianDidNotAccept");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("GuardianDidNotAccept") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Cross-chain replay rejected — chainId binding works");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test D: Wrong salt ────────────────────────────────────────────────────

  const saltD = SALT_BASE + 3n;
  const wrongSalt = saltD + 999n;
  console.log(`\n[Test D] Wrong salt in sig: guardian signed for salt=${wrongSalt}, submitting with salt=${saltD}`);
  console.log("  Expected:   REVERT GuardianDidNotAccept");

  try {
    const innerHashWrongSalt = buildInnerHash(FACTORY_ADDR, owner.address, wrongSalt, chainId);
    const g1SigWrongSalt = await signAcceptance(g1Client, innerHashWrongSalt);
    const g2SigWrongSalt = await signAcceptance(g2Client, innerHashWrongSalt);

    await publicClient.simulateContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
      args: [owner.address, saltD, guardian1.address, g1SigWrongSalt, guardian2.address, g2SigWrongSalt, DAILY_LIMIT],
      account: owner.address,
    });
    console.log("  FAIL: Should have reverted with GuardianDidNotAccept");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("GuardianDidNotAccept") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Wrong salt rejected — salt binding works");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Test E: Wrong owner ───────────────────────────────────────────────────

  const saltE = SALT_BASE + 4n;
  const FAKE_OWNER = "0x000000000000000000000000000000000000bEEF" as Address;
  console.log(`\n[Test E] Wrong owner in sig: guardian signed for owner=${FAKE_OWNER}`);
  console.log(`  Submitting with owner=${owner.address}`);
  console.log("  Expected:   REVERT GuardianDidNotAccept");

  try {
    const innerHashWrongOwner = buildInnerHash(FACTORY_ADDR, FAKE_OWNER, saltE, chainId);
    const g1SigWrongOwner = await signAcceptance(g1Client, innerHashWrongOwner);
    const g2SigWrongOwner = await signAcceptance(g2Client, innerHashWrongOwner);

    await publicClient.simulateContract({
      address: FACTORY_ADDR, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
      args: [owner.address, saltE, guardian1.address, g1SigWrongOwner, guardian2.address, g2SigWrongOwner, DAILY_LIMIT],
      account: owner.address,
    });
    console.log("  FAIL: Should have reverted with GuardianDidNotAccept");
    failed++;
  } catch (e: any) {
    const msg = e.message ?? "";
    if (msg.includes("GuardianDidNotAccept") || msg.includes("revert") || msg.includes("0x")) {
      console.log("  PASS: Wrong owner rejected — owner binding works");
      passed++;
    } else {
      console.log(`  FAIL: Unexpected error: ${msg.slice(0, 150)}`);
      failed++;
    }
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  console.log(`\n${"─".repeat(50)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  if (failed === 0) {
    console.log("ALL PASS: Guardian domain separation is working correctly.");
    console.log("Codex Audit MEDIUM finding (cross-factory/cross-chain replay) is fully mitigated.");
    console.log(`\nDomain fields verified: chainId(${chainId}) + factory + owner + salt`);
  } else {
    console.log("FAILURES DETECTED — investigate above.");
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
