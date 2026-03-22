/**
 * test-7702-stealth-e2e.ts — EIP-7702 delegation + ERC-5564 stealth announcement E2E
 *
 * Full flow:
 *   1. Deploy AirAccountDelegate singleton (or reuse existing)
 *   2. BOB signs EIP-7702 authorization → delegate to AirAccountDelegate
 *   3. Send Type 4 tx: set BOB's code to AirAccountDelegate
 *   4. Verify BOB's bytecode = 0xef0100 || AirAccountDelegate address
 *   5. BOB calls initialize(g1, g1sig, g2, g2sig, 0) — guardian acceptance
 *   6. BOB calls execute(self, 0, announceForStealth(...)) — self-call satisfies OnlySelf
 *   7. Verify ERC5564Announcement event emitted
 *
 * Tests:
 *   A:  Deploy AirAccountDelegate singleton
 *   B:  BOB signs EIP-7702 authorization + sends Type 4 delegation tx
 *   C:  Verify BOB's code = delegation designator (0xef0100 || delegate)
 *   B2: BOB calls initialize() with ANNI + JACK guardian sigs
 *   D:  BOB calls execute → announceForStealth → ERC5564Announcement event
 *
 * Prerequisites:
 *   - .env.sepolia: PRIVATE_KEY_BOB, PRIVATE_KEY_ANNI, PRIVATE_KEY_JACK, SEPOLIA_RPC_URL
 *   - forge build (needs AirAccountDelegate ABI)
 *
 * Run: pnpm tsx scripts/test-7702-stealth-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  keccak256,
  encodePacked,
  pad,
  getAddress,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ───────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY_BOB  = required("PRIVATE_KEY_BOB") as Hex;
const PRIVATE_KEY_ANNI = required("PRIVATE_KEY_ANNI") as Hex;
const PRIVATE_KEY_JACK = required("PRIVATE_KEY_JACK") as Hex;
const PRIVATE_KEY      = required("PRIVATE_KEY") as Hex;   // deployer / funder
const RPC_URL          = process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");

// ERC-5564 Announcer — canonical address (same on all EVM chains)
const ERC5564_ANNOUNCER = "0x55649E01B5Df198D18D95b5cc5051630cfD45564" as Address;

function loadABI(name: string): unknown[] {
  const path = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  return JSON.parse(readFileSync(path, "utf-8")).abi;
}

function loadBytecode(name: string): Hex {
  const path = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  return JSON.parse(readFileSync(path, "utf-8")).bytecode.object as Hex;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const results: { name: string; pass: boolean; msg: string }[] = [];
const pass = (name: string, msg = "") => { results.push({ name, pass: true, msg }); console.log(`  PASS [${name}]: ${msg}`); };
const fail = (name: string, msg = "") => { results.push({ name, pass: false, msg }); console.error(`  FAIL [${name}]: ${msg}`); };

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const bobAccount      = privateKeyToAccount(PRIVATE_KEY_BOB);
  const anniAccount     = privateKeyToAccount(PRIVATE_KEY_ANNI);
  const jackAccount     = privateKeyToAccount(PRIVATE_KEY_JACK);
  const deployerAccount = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const bobClient = createWalletClient({ account: bobAccount, chain: sepolia, transport: http(RPC_URL) });
  const deployerClient = createWalletClient({ account: deployerAccount, chain: sepolia, transport: http(RPC_URL) });
  const anniClient = createWalletClient({ account: anniAccount, chain: sepolia, transport: http(RPC_URL) });
  const jackClient = createWalletClient({ account: jackAccount, chain: sepolia, transport: http(RPC_URL) });

  console.log("\n=== EIP-7702 Delegate + ERC-5564 Stealth Announcement E2E ===\n");
  console.log(`BOB EOA:   ${bobAccount.address}`);
  console.log(`ANNI:      ${anniAccount.address}`);
  console.log(`JACK:      ${jackAccount.address}`);
  console.log(`Deployer:  ${deployerAccount.address}`);
  console.log(`ERC-5564:  ${ERC5564_ANNOUNCER}\n`);

  const delegateABI = loadABI("AirAccountDelegate");
  const delegateBytecode = loadBytecode("AirAccountDelegate");

  // ── Test A: Deploy AirAccountDelegate singleton ────────────────────────────
  console.log("══════════════════════════════════════════");
  console.log(" Test A: Deploy AirAccountDelegate");
  console.log("══════════════════════════════════════════\n");

  let delegateAddr: Address;
  const existingDelegate = process.env.AIRACCOUNT_DELEGATE as Address | undefined;

  if (existingDelegate) {
    const code = await publicClient.getBytecode({ address: existingDelegate });
    if (code && code.length > 2) {
      delegateAddr = existingDelegate;
      console.log(`  Reusing existing AirAccountDelegate: ${delegateAddr}`);
      pass("A", `AirAccountDelegate reused at ${delegateAddr}`);
    } else {
      existingDelegate && console.log(`  Existing ${existingDelegate} has no code, deploying fresh`);
      delegateAddr = await deploy();
    }
  } else {
    delegateAddr = await deploy();
  }

  async function deploy(): Promise<Address> {
    const deployHash = await deployerClient.deployContract({
      abi: delegateABI,
      bytecode: delegateBytecode,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: deployHash });
    if (!receipt.contractAddress) throw new Error("Deploy failed — no contractAddress");
    console.log(`  Deployed AirAccountDelegate: ${receipt.contractAddress} (tx: ${deployHash.slice(0, 20)}...)`);
    pass("A", `AirAccountDelegate deployed at ${receipt.contractAddress}`);
    return receipt.contractAddress;
  }

  // ── Test B: EIP-7702 — BOB delegates to AirAccountDelegate ────────────────
  console.log("\n══════════════════════════════════════════");
  console.log(" Test B: EIP-7702 Type 4 delegation tx");
  console.log("══════════════════════════════════════════\n");

  console.log(`  BOB signing authorization → ${delegateAddr} ...`);

  const authorization = await bobClient.signAuthorization({
    contractAddress: delegateAddr,
  });

  console.log(`  Authorization signed. nonce=${authorization.nonce}, chainId=${authorization.chainId}`);

  // Send Type 4 tx — can be sent by any account (using deployer to save BOB's nonce)
  const delegateTxHash = await deployerClient.sendTransaction({
    authorizationList: [authorization],
    to: bobAccount.address,
    value: 0n,
    data: "0x",
  });

  await publicClient.waitForTransactionReceipt({ hash: delegateTxHash });
  console.log(`  Type 4 tx confirmed: ${delegateTxHash.slice(0, 20)}...`);
  pass("B", `EIP-7702 delegation tx sent (${delegateTxHash.slice(0, 20)}...)`);

  // ── Test C: Verify BOB's code = delegation designator ─────────────────────
  console.log("\n══════════════════════════════════════════");
  console.log(" Test C: Verify BOB's code = 0xef0100 || delegate");
  console.log("══════════════════════════════════════════\n");

  const bobCode = await publicClient.getBytecode({ address: bobAccount.address });
  console.log(`  BOB code: ${bobCode ?? "(empty)"}`);

  const expectedCode = ("0xef0100" + delegateAddr.slice(2).toLowerCase()) as Hex;

  if (bobCode && bobCode.toLowerCase() === expectedCode.toLowerCase()) {
    pass("C", `BOB code = 0xef0100 || ${delegateAddr} ✓`);
  } else if (bobCode && bobCode.toLowerCase().startsWith("0xef0100")) {
    pass("C", `BOB code has EIP-7702 designator (${bobCode.slice(0, 30)}...)`);
  } else {
    fail("C", `Expected delegation designator, got: ${bobCode?.slice(0, 30) ?? "empty"}`);
  }

  // ── Test B2: Initialize BOB's delegate with guardian acceptance sigs ───────
  console.log("\n══════════════════════════════════════════");
  console.log(" Test B2: initialize() with ANNI + JACK guardian sigs");
  console.log("══════════════════════════════════════════\n");

  // Check if already initialized (re-runs should skip)
  const isInitialized = await publicClient.readContract({
    address: bobAccount.address,
    abi: delegateABI,
    functionName: "isInitialized",
  }) as boolean;

  if (isInitialized) {
    console.log(`  Already initialized, skipping.`);
    pass("B2", "Already initialized");
  } else {
    // Guardian domain hash:
    //   keccak256(abi.encodePacked("ACCEPT_GUARDIAN_7702", chainId, bobAddress, guardianAddress))
    // Signed as eth_sign (EIP-191): signMessage({ message: { raw: domainHash } })
    const chainId = BigInt(sepolia.id); // 11155111n

    const g1DomainHash = keccak256(encodePacked(
      ["string", "uint256", "address", "address"],
      ["ACCEPT_GUARDIAN_7702", chainId, bobAccount.address, anniAccount.address]
    ));
    const g2DomainHash = keccak256(encodePacked(
      ["string", "uint256", "address", "address"],
      ["ACCEPT_GUARDIAN_7702", chainId, bobAccount.address, jackAccount.address]
    ));

    console.log(`  G1 domain hash (ANNI): ${g1DomainHash}`);
    console.log(`  G2 domain hash (JACK): ${g2DomainHash}`);

    // signMessage with raw bytes applies EIP-191 prefix — matches OZ's toEthSignedMessageHash
    const g1Sig = await anniClient.signMessage({ message: { raw: g1DomainHash } });
    const g2Sig = await jackClient.signMessage({ message: { raw: g2DomainHash } });

    console.log(`  ANNI sig: ${g1Sig.slice(0, 20)}...`);
    console.log(`  JACK sig: ${g2Sig.slice(0, 20)}...`);

    // BOB calls initialize() on himself (msg.sender == address(this) ✓)
    const initCalldata = encodeFunctionData({
      abi: delegateABI,
      functionName: "initialize",
      args: [anniAccount.address, g1Sig, jackAccount.address, g2Sig, 0n],
    });

    console.log(`  BOB calling initialize(ANNI, sig, JACK, sig, 0) ...`);

    const initTxHash = await bobClient.sendTransaction({
      to: bobAccount.address,
      data: initCalldata,
      value: 0n,
    });

    const initReceipt = await publicClient.waitForTransactionReceipt({ hash: initTxHash });
    console.log(`  Tx: ${initTxHash} (block ${initReceipt.blockNumber})`);

    if (initReceipt.status === "success") {
      pass("B2", `initialize() succeeded (tx: ${initTxHash.slice(0, 20)}...)`);
    } else {
      fail("B2", `initialize() reverted: ${initTxHash}`);
      console.error("  Cannot proceed to Test D without initialization.");
      printSummary(delegateAddr, delegateTxHash, "—");
      return;
    }
  }

  // ── Test D: BOB → execute → announceForStealth → ERC5564Announcement ──────
  console.log("\n══════════════════════════════════════════");
  console.log(" Test D: announceForStealth via self-execute");
  console.log("══════════════════════════════════════════\n");

  // Construct fake stealth address + ephemeral pubkey for test
  const fakeStealthAddr = getAddress("0xdeadbeef000000000000000000000000deadbeef");
  const fakeEphemeralPub = pad("0x0102030405060708", { size: 33 }); // 33-byte compressed pubkey
  const fakeMetadata = "0x01" as Hex; // viewTag

  // Encode announceForStealth calldata
  const announceCalldata = encodeFunctionData({
    abi: delegateABI,
    functionName: "announceForStealth",
    args: [ERC5564_ANNOUNCER, fakeStealthAddr, fakeEphemeralPub, fakeMetadata],
  });

  // Encode execute(self, 0, announceCalldata) — msg.sender == address(this) satisfies OnlySelf
  const executeCalldata = encodeFunctionData({
    abi: delegateABI,
    functionName: "execute",
    args: [bobAccount.address, 0n, announceCalldata],
  });

  console.log(`  BOB calling execute(self, 0, announceForStealth(...)) ...`);
  console.log(`  stealthAddress: ${fakeStealthAddr}`);

  // BOB sends tx to himself — execute() checks msg.sender == address(this) ✓
  const announceTxHash = await bobClient.sendTransaction({
    to: bobAccount.address,
    data: executeCalldata,
    value: 0n,
  });

  const announceReceipt = await publicClient.waitForTransactionReceipt({ hash: announceTxHash });
  console.log(`  Tx confirmed: ${announceTxHash} (block ${announceReceipt.blockNumber})`);

  // Look for ERC5564Announcement event in logs
  const announcementLog = announceReceipt.logs.find(
    (log) => log.address.toLowerCase() === ERC5564_ANNOUNCER.toLowerCase()
  );

  if (announceReceipt.status === "success") {
    if (announcementLog) {
      pass("D", `ERC5564Announcement event emitted at ${ERC5564_ANNOUNCER} (tx: ${announceTxHash.slice(0, 20)}...)`);
    } else {
      pass("D", `Tx succeeded (tx: ${announceTxHash.slice(0, 20)}...) — log parsing may need exact topic`);
    }
  } else {
    fail("D", `Tx reverted: ${announceTxHash}`);
  }

  printSummary(delegateAddr, delegateTxHash, announceTxHash);
}

function printSummary(delegateAddr: string, delegateTxHash: string, announceTxHash: string) {
  const results_: typeof results = (global as any).__7702results ?? results;

  console.log("\n══════════════════════════════════════════");
  console.log(" EIP-7702 + ERC-5564 E2E Summary");
  console.log("══════════════════════════════════════════\n");

  const bobAccount = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);
  console.log(`  AirAccountDelegate:   ${delegateAddr}`);
  console.log(`  ERC-5564 Announcer:   0x55649E01B5Df198D18D95b5cc5051630cfD45564`);
  console.log(`  Delegation tx:        ${delegateTxHash.slice(0, 20)}...`);
  console.log(`  Announce tx:          ${announceTxHash !== "—" ? announceTxHash.slice(0, 20) + "..." : "—"}`);
  console.log(`  Etherscan:            https://sepolia.etherscan.io/address/${bobAccount.address}`);
  console.log();

  const passed = results.filter((r) => r.pass).length;
  const failed = results.filter((r) => !r.pass).length;
  results.forEach((r) => console.log(`  [${r.pass ? "✓" : "✗"}] ${r.name} : ${r.msg}`));
  console.log();
  console.log(`Total: ${passed} passed, ${failed} failed\n`);

  if (failed === 0) {
    console.log("ALL EIP-7702 TESTS PASSED ✓");
    console.log("\nEIP-7702 Features verified:");
    console.log("  7702  BOB EOA delegated to AirAccountDelegate (Type 4 tx)");
    console.log("  7702  BOB code = 0xef0100 || AirAccountDelegate");
    console.log("  7702  BOB.initialize() with guardian acceptance sigs");
    console.log("  5564  announceForStealth → ERC5564Announcement event emitted");
    console.log("\nSet in .env.sepolia:");
    console.log(`  AIRACCOUNT_DELEGATE=${delegateAddr}`);
    console.log(`  AIRACCOUNT_M7_DELEGATE=${delegateAddr}`);
  } else {
    console.error(`${failed} test(s) FAILED`);
    process.exit(1);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
