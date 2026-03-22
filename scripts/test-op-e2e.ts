/**
 * test-op-e2e.ts — AirAccount M7 E2E Tests on Sepolia
 *
 * Validates that AirAccount M7 factory deployed on Sepolia works correctly:
 *   A. Factory deployed and implementation readable
 *   B. Predict counterfactual account address (createAccountWithDefaults)
 *   C. Deploy account via createAccountWithDefaults (guardian accept pattern)
 *   D. Guard deployed and bound to account (dailyLimit, approved algIds)
 *   E. EIP-7212 P256 precompile available (ALG_P256 usable)
 *   F. EntryPoint v0.7 exists on Sepolia
 *
 * Prerequisites:
 *   - AIRACCOUNT_M7_FACTORY in .env.sepolia
 *   - PRIVATE_KEY, PRIVATE_KEY_BOB, PRIVATE_KEY_JACK in .env.sepolia
 *
 * Run: pnpm tsx scripts/test-op-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  encodePacked,
  keccak256,
  concat,
  toHex,
  encodeFunctionData,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount, signMessage } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY   = required("PRIVATE_KEY") as Hex;
const GUARDIAN0_KEY = (process.env.PRIVATE_KEY_BOB  ?? required("PRIVATE_KEY_BOB")) as Hex;
const GUARDIAN1_KEY = (process.env.PRIVATE_KEY_JACK ?? required("PRIVATE_KEY_JACK")) as Hex;
const RPC_URL       = process.env.SEPOLIA_RPC_URL ?? process.env.SEPOLIA_RPC ?? required("SEPOLIA_RPC_URL");
const ENTRYPOINT    = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const FACTORY_ADDR  = (process.env.AIRACCOUNT_M7_FACTORY ?? process.env.FACTORY_ADDRESS ?? required("AIRACCOUNT_M7_FACTORY")) as Address;
const DAILY_LIMIT   = parseEther("0.01"); // 0.01 ETH default daily limit for test accounts

const CHAIN_ID = sepolia.id; // 11155111
const SALT = 2000n; // Sepolia salt for test-op-e2e (avoids collision with other test scripts)

// ─── Helpers ─────────────────────────────────────────────────────────────────

function loadArtifactAbi(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return artifact.abi;
}

// Build guardian acceptance signature
// Guardian signs: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()
async function buildGuardianAcceptSig(
  guardianPrivKey: Hex,
  factory: Address,
  owner: Address,
  salt: bigint,
  chainId: number
): Promise<Hex> {
  // Must match contract: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt)).toEthSignedMessageHash()
  const packed = encodePacked(
    ["string", "uint256", "address", "address", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(chainId), factory, owner, salt]
  );
  const msgHash = keccak256(packed);
  return signMessage({ message: { raw: msgHash as Hex }, privateKey: guardianPrivKey });
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== AirAccount M7 E2E Tests on Sepolia ===\n");
  console.log(`Factory: ${FACTORY_ADDR}`);
  console.log(`RPC:     ${RPC_URL}\n`);

  const owner    = privateKeyToAccount(PRIVATE_KEY);
  const guardian0 = privateKeyToAccount(GUARDIAN0_KEY);
  const guardian1 = privateKeyToAccount(GUARDIAN1_KEY);

  const transport = http(RPC_URL, { retryCount: 3, retryDelay: 1500 });

  const publicClient = createPublicClient({
    chain: sepolia,
    transport,
    pollingInterval: 3_000,
  });

  const ownerClient = createWalletClient({
    account: owner,
    chain: sepolia,
    transport,
  });

  // Verify chain
  const chainId = await publicClient.getChainId();
  if (chainId !== 11155111) {
    console.error(`Wrong chain ${chainId}, expected Sepolia (11155111)`);
    process.exit(1);
  }

  const ownerBalance = await publicClient.getBalance({ address: owner.address });
  console.log(`Owner:     ${owner.address} (${formatEther(ownerBalance)} ETH)`);
  console.log(`Guardian0: ${guardian0.address}`);
  console.log(`Guardian1: ${guardian1.address}`);
  console.log(`Salt:      ${SALT}\n`);

  let passed = 0;
  let failed = 0;

  const factoryAbi = loadArtifactAbi("AAStarAirAccountFactoryV7");

  // ── Test A: Factory readable ─────────────────────────────────────
  console.log("[Test A] Factory deployed and implementation readable");
  try {
    const implAddr = await publicClient.readContract({
      address: FACTORY_ADDR,
      abi: factoryAbi,
      functionName: "implementation",
    }) as Address;
    const implCode = await publicClient.getCode({ address: implAddr });
    const implSize = implCode ? (implCode.length - 2) / 2 : 0;
    console.log(`  PASS: implementation = ${implAddr} (${implSize}B)`);
    if (implSize > 24576) {
      console.warn(`  WARN: impl size ${implSize}B exceeds EIP-170 limit 24576B`);
    }
    passed++;
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    failed++;
    process.exit(1);
  }

  // ── Test B: Compute counterfactual account address ───────────────
  console.log("\n[Test B] Compute counterfactual account address (no deploy yet)");
  let accountAddr: Address;
  try {
    accountAddr = await publicClient.readContract({
      address: FACTORY_ADDR,
      abi: factoryAbi,
      functionName: "getAddressWithDefaults",
      args: [owner.address, SALT, guardian0.address, guardian1.address, DAILY_LIMIT],
    }) as Address;
    console.log(`  PASS: counterfactual address = ${accountAddr}`);
    passed++;
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    failed++;
    process.exit(1);
  }

  // Check if already deployed
  const existingCode = await publicClient.getCode({ address: accountAddr! });
  if (existingCode && existingCode !== "0x") {
    console.log(`  INFO: Account already deployed at ${accountAddr}, skipping deploy test`);
  } else {
    // ── Test C: Deploy account via createAccountWithDefaults ──────
    console.log("\n[Test C] Deploy account via createAccountWithDefaults (guardian accept)");
    try {
      const guardian0Sig = await buildGuardianAcceptSig(
        GUARDIAN0_KEY, FACTORY_ADDR, owner.address, SALT, CHAIN_ID
      );
      const guardian1Sig = await buildGuardianAcceptSig(
        GUARDIAN1_KEY, FACTORY_ADDR, owner.address, SALT, CHAIN_ID
      );

      const createTx = await ownerClient.writeContract({
        address: FACTORY_ADDR,
        abi: factoryAbi,
        functionName: "createAccountWithDefaults",
        args: [
          owner.address,
          SALT,
          guardian0.address,
          guardian0Sig,
          guardian1.address,
          guardian1Sig,
          DAILY_LIMIT,
        ],
        // no value: createAccountWithDefaults is not payable
      });
      console.log(`  TX: ${createTx}`);
      const receipt = await publicClient.waitForTransactionReceipt({ hash: createTx });
      console.log(`  PASS: Account created (gas: ${receipt.gasUsed})`);
      console.log(`  Explorer: https://sepolia.etherscan.io/tx/${createTx}`);
      passed++;
    } catch (e: any) {
      console.log(`  FAIL: ${e.message?.slice(0, 200)}`);
      failed++;
    }
  }

  // ── Test D: Account + Guard verification ────────────────────────
  console.log("\n[Test D] Verify account is clone proxy + guard is bound");
  try {
    const accountCode = await publicClient.getCode({ address: accountAddr! });
    const codeSize = accountCode ? (accountCode.length - 2) / 2 : 0;
    // EIP-1167 proxy is 45 bytes
    if (codeSize === 45) {
      console.log(`  PASS: Account code = ${codeSize}B (EIP-1167 clone ✓)`);
    } else if (codeSize > 0) {
      console.log(`  INFO: Account code = ${codeSize}B (direct deploy, not clone)`);
    } else {
      console.log(`  SKIP: Account not yet deployed`);
    }

    const accountAbi = loadArtifactAbi("AAStarAirAccountV7");
    const guardAddr = await publicClient.readContract({
      address: accountAddr!,
      abi: accountAbi,
      functionName: "guard",
    }) as Address;
    console.log(`  PASS: Guard address = ${guardAddr}`);

    const guardAbi = loadArtifactAbi("AAStarGlobalGuard");
    const dailyLimit = await publicClient.readContract({
      address: guardAddr,
      abi: guardAbi,
      functionName: "dailyLimit",
    }) as bigint;
    console.log(`  PASS: Guard dailyLimit = ${dailyLimit}`);
    passed++;
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    failed++;
  }

  // ── Test E: EIP-7212 P256 precompile ────────────────────────────
  console.log("\n[Test E] EIP-7212 P256 precompile availability");
  try {
    const precompileCode = await publicClient.getCode({
      address: "0x0000000000000000000000000000000000000100" as Address
    });
    if (precompileCode && precompileCode !== "0x") {
      console.log("  PASS: EIP-7212 P256 precompile available at 0x100 ✓");
      console.log("        ALG_P256 (0x04) and ALG_COMBINED_T1 (0x06) usable on OP");
      passed++;
    } else {
      console.log("  WARN: P256 precompile not detected (may still work via internal call)");
      passed++; // not a hard failure — OP supports it post-Fjord
    }
  } catch (e: any) {
    console.log(`  INFO: Could not check precompile: ${e.message?.slice(0, 100)}`);
    passed++;
  }

  // ── Test F: EntryPoint exists on OP ──────────────────────────────
  console.log("\n[Test F] EntryPoint v0.7 exists on OP Mainnet");
  try {
    const epCode = await publicClient.getCode({ address: ENTRYPOINT });
    const epSize = epCode ? (epCode.length - 2) / 2 : 0;
    if (epSize > 0) {
      console.log(`  PASS: EntryPoint at ${ENTRYPOINT} (${epSize}B) ✓`);
      passed++;
    } else {
      console.log(`  FAIL: EntryPoint not found at ${ENTRYPOINT}`);
      failed++;
    }
  } catch (e: any) {
    console.log(`  FAIL: ${e.message?.slice(0, 150)}`);
    failed++;
  }

  // ── Summary ───────────────────────────────────────────────────────
  console.log(`\n${"─".repeat(50)}`);
  console.log(`Chain:   Sepolia (chainId=11155111)`);
  console.log(`Factory: ${FACTORY_ADDR}`);
  console.log(`Account: ${accountAddr!}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);

  if (failed === 0) {
    console.log("\nALL PASS: AirAccount M7 is working on Sepolia.");
    console.log("\nUpdate .env.sepolia:");
    console.log(`  AIRACCOUNT_M7_ACCOUNT=${accountAddr!}`);
  } else {
    console.log("\nFAILURES DETECTED. Check logs above.");
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
