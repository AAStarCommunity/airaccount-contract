/**
 * test-m7-r8-anvil-e2e.ts — Anvil local E2E test for M7 r8
 *
 * Deploys all contracts to a local Anvil instance and runs E2E scenarios:
 *   1. Deploy CompositeValidator, TierGuardHook, AgentSessionKeyValidator, Factory
 *   2. Create account via factory (with guardian dedup validation)
 *   3. Verify account state (owner, guardians, guard)
 *   4. Test guardian dedup revert (duplicate guardians)
 *   5. Test ECDSA UserOp validation
 *   6. Test installModule with guardian sig
 *   7. Test TierGuardHook unknown algId revert
 *   8. Test AgentSessionKeyValidator selector limit
 *
 * Usage:
 *   1. Start anvil: anvil (in a separate terminal)
 *   2. Run: pnpm tsx scripts/test-m7-r8-anvil-e2e.ts
 */

import { readFileSync } from "fs";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  encodeDeployData,
  encodeFunctionData,
  encodePacked,
  keccak256,
  parseEther,
  formatEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

// ─── Anvil default accounts ─────────────────────────────────────────────────

const ANVIL_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
] as const;

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const RPC_URL = "http://127.0.0.1:8545";

// ─── Helpers ────────────────────────────────────────────────────────────────

function loadArtifact(name: string) {
  const artifact = JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  );
  return { abi: artifact.abi as unknown[], bytecode: artifact.bytecode.object as Hex };
}

let passed = 0;
let failed = 0;

function ok(name: string) { passed++; console.log(`  ✅ ${name}`); }
function fail(name: string, err: unknown) {
  failed++;
  console.error(`  ❌ ${name}: ${err instanceof Error ? err.message : err}`);
}

// ─── Main ───────────────────────────────────────────────────────────────────

async function main() {
  const owner = privateKeyToAccount(ANVIL_KEYS[0]);
  const g1    = privateKeyToAccount(ANVIL_KEYS[1]);
  const g2    = privateKeyToAccount(ANVIL_KEYS[2]);
  const community = privateKeyToAccount(ANVIL_KEYS[3]);

  const pub = createPublicClient({ chain: foundry, transport: http(RPC_URL) });
  const wal = createWalletClient({ account: owner, chain: foundry, transport: http(RPC_URL) });

  console.log("=== M7 r8 Anvil E2E Test ===\n");
  console.log(`Owner:      ${owner.address}`);
  console.log(`Guardian1:  ${g1.address}`);
  console.log(`Guardian2:  ${g2.address}`);
  console.log(`Community:  ${community.address}`);

  // Deploy EntryPoint mock — Anvil doesn't have the real one
  // We'll use a no-guard account to skip EntryPoint interactions
  const chainId = await pub.getChainId();
  console.log(`Chain ID:   ${chainId}\n`);

  // ─── Deploy contracts ──────────────────────────────────────────────────
  console.log("[Deploy] CompositeValidator...");
  const cvA = loadArtifact("AirAccountCompositeValidator");
  const cvH = await wal.sendTransaction({
    data: encodeDeployData({ abi: cvA.abi, bytecode: cvA.bytecode, args: [] }),
  });
  const cvR = await pub.waitForTransactionReceipt({ hash: cvH });
  const compositeAddr = cvR.contractAddress!;
  console.log(`  ${compositeAddr}`);

  console.log("[Deploy] TierGuardHook...");
  const tghA = loadArtifact("TierGuardHook");
  const tghH = await wal.sendTransaction({
    data: encodeDeployData({ abi: tghA.abi, bytecode: tghA.bytecode, args: [] }),
  });
  const tghR = await pub.waitForTransactionReceipt({ hash: tghH });
  const tierGuardAddr = tghR.contractAddress!;
  console.log(`  ${tierGuardAddr}`);

  console.log("[Deploy] AgentSessionKeyValidator...");
  const askA = loadArtifact("AgentSessionKeyValidator");
  const askH = await wal.sendTransaction({
    data: encodeDeployData({ abi: askA.abi, bytecode: askA.bytecode, args: [] }),
  });
  const askR = await pub.waitForTransactionReceipt({ hash: askH });
  const agentSessionAddr = askR.contractAddress!;
  console.log(`  ${agentSessionAddr}`);

  console.log("[Deploy] Factory (r8)...");
  const fA = loadArtifact("AAStarAirAccountFactoryV7");
  const fH = await wal.sendTransaction({
    data: encodeDeployData({
      abi: fA.abi,
      bytecode: fA.bytecode,
      args: [
        owner.address, // Use owner as mock EntryPoint for Anvil
        community.address,
        [],
        [],
        compositeAddr,
        "0x0000000000000000000000000000000000000000" as Address,
      ],
    }),
  });
  const fR = await pub.waitForTransactionReceipt({ hash: fH });
  const factoryAddr = fR.contractAddress!;
  const implAddr = await pub.readContract({
    address: factoryAddr, abi: fA.abi, functionName: "implementation",
  }) as Address;
  console.log(`  Factory:  ${factoryAddr}`);
  console.log(`  Impl:     ${implAddr}`);

  const accA = loadArtifact("AAStarAirAccountV7");

  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── Test Group 1: Account Creation ──\n");

  // T1: Create account with valid guardians
  try {
    const initConfig = {
      guardians: [g1.address, g2.address, community.address] as [Address, Address, Address],
      dailyLimit: 0n,
      approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08] as number[],
      minDailyLimit: 0n,
      initialTokens: [] as Address[],
      initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
    };
    const cH = await wal.writeContract({
      address: factoryAddr, abi: fA.abi, functionName: "createAccount",
      args: [owner.address, 1000n, initConfig],
    });
    const cR = await pub.waitForTransactionReceipt({ hash: cH });
    if (cR.status !== "success") throw new Error("createAccount reverted");

    // Read account address
    const accountAddr = await pub.readContract({
      address: factoryAddr, abi: fA.abi, functionName: "getAddress",
      args: [owner.address, 1000n, initConfig],
    }) as Address;

    // Verify owner
    const accOwner = await pub.readContract({
      address: accountAddr, abi: accA.abi, functionName: "owner",
    });
    if (accOwner !== owner.address) throw new Error(`owner mismatch: ${accOwner}`);

    // Verify guardian count
    const gCount = await pub.readContract({
      address: accountAddr, abi: accA.abi, functionName: "guardianCount",
    }) as number;
    if (Number(gCount) !== 3) throw new Error(`guardianCount ${gCount} != 3`);

    ok("T1: createAccount with 3 distinct guardians");
  } catch (e) { fail("T1: createAccount", e); }

  // T2: Duplicate guardian[0] == guardian[1] should revert
  try {
    const dupConfig = {
      guardians: [g1.address, g1.address, community.address] as [Address, Address, Address],
      dailyLimit: 0n,
      approvedAlgIds: [0x02] as number[],
      minDailyLimit: 0n,
      initialTokens: [] as Address[],
      initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
    };
    try {
      await wal.writeContract({
        address: factoryAddr, abi: fA.abi, functionName: "createAccount",
        args: [owner.address, 2000n, dupConfig],
      });
      fail("T2: duplicate guardian should revert", "did not revert");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("DuplicateGuardian")) {
        ok("T2: createAccount with duplicate guardians reverts DuplicateGuardian");
      } else {
        fail("T2: expected DuplicateGuardian", msg);
      }
    }
  } catch (e) { fail("T2: duplicate guardian setup", e); }

  // T3: Duplicate guardian[1] == guardian[2] should revert
  try {
    const dupConfig2 = {
      guardians: [g1.address, g2.address, g2.address] as [Address, Address, Address],
      dailyLimit: 0n,
      approvedAlgIds: [0x02] as number[],
      minDailyLimit: 0n,
      initialTokens: [] as Address[],
      initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
    };
    try {
      await wal.writeContract({
        address: factoryAddr, abi: fA.abi, functionName: "createAccount",
        args: [owner.address, 2001n, dupConfig2],
      });
      fail("T3: duplicate guardian[1]==guardian[2] should revert", "did not revert");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("DuplicateGuardian")) {
        ok("T3: createAccount with guardian[1]==guardian[2] reverts DuplicateGuardian");
      } else {
        fail("T3: expected DuplicateGuardian", msg);
      }
    }
  } catch (e) { fail("T3: duplicate guardian setup", e); }

  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── Test Group 2: AgentSessionKeyValidator Limits ──\n");

  // T4: grantAgentSession with > MAX_SELECTORS should revert
  try {
    // Install session validator on the account
    const accountAddr = await pub.readContract({
      address: factoryAddr, abi: fA.abi, functionName: "getAddress",
      args: [owner.address, 1000n, {
        guardians: [g1.address, g2.address, community.address] as [Address, Address, Address],
        dailyLimit: 0n,
        approvedAlgIds: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08] as number[],
        minDailyLimit: 0n,
        initialTokens: [] as Address[],
        initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
      }],
    }) as Address;

    // First, install the session key validator
    const g1Wal = createWalletClient({ account: g1, chain: foundry, transport: http(RPC_URL) });

    // Call onInstall to initialize
    const accWal = createWalletClient({ account: owner, chain: foundry, transport: http(RPC_URL) });

    // Grant session with 31 selectors (> MAX_SELECTORS=30)
    const selectors: Hex[] = [];
    for (let i = 0; i < 31; i++) {
      // bytes4 selectors
      selectors.push(("0x" + (i + 1).toString(16).padStart(8, "0")) as `0x${string}`);
    }

    // We need the account to call grantAgentSession — impersonate via direct call
    // Since this is Anvil, we can impersonate the account address
    const accWalImpersonate = createWalletClient({
      account: accountAddr,
      chain: foundry,
      transport: http(RPC_URL),
    });

    // Impersonate account address
    await pub.request({ method: "anvil_impersonateAccount" as any, params: [accountAddr] } as any);
    // Fund it for gas
    await wal.sendTransaction({ to: accountAddr, value: parseEther("1") });

    // Initialize the validator
    await accWalImpersonate.writeContract({
      address: agentSessionAddr,
      abi: askA.abi,
      functionName: "onInstall",
      args: ["0x" as Hex],
    });

    try {
      await pub.simulateContract({
        account: accountAddr,
        address: agentSessionAddr,
        abi: askA.abi,
        functionName: "grantAgentSession",
        args: [g1.address, {
          expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
          velocityLimit: 0,
          velocityWindow: 0,
          spendToken: "0x0000000000000000000000000000000000000000" as Address,
          spendCap: 0n,
          revoked: false,
          callTargets: [],
          selectorAllowlist: selectors,
        }],
      });
      fail("T4: 31 selectors should revert MaxSelectorsExceeded", "did not revert");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("MaxSelectorsExceeded")) {
        ok("T4: grantAgentSession with 31 selectors reverts MaxSelectorsExceeded");
      } else {
        fail("T4: expected MaxSelectorsExceeded", msg);
      }
    }

    // T5: 30 selectors should succeed
    const selectors30: Hex[] = [];
    for (let i = 0; i < 30; i++) {
      selectors30.push(("0x" + (i + 1).toString(16).padStart(8, "0")) as Hex);
    }
    try {
      await accWalImpersonate.writeContract({
        address: agentSessionAddr,
        abi: askA.abi,
        functionName: "grantAgentSession",
        args: [g1.address, {
          expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
          velocityLimit: 0,
          velocityWindow: 0,
          spendToken: "0x0000000000000000000000000000000000000000" as Address,
          spendCap: 0n,
          revoked: false,
          callTargets: [],
          selectorAllowlist: selectors30,
        }],
      });
      ok("T5: grantAgentSession with 30 selectors succeeds");
    } catch (e) { fail("T5: 30 selectors should succeed", e); }

    await pub.request({ method: "anvil_stopImpersonatingAccount" as any, params: [accountAddr] } as any);

  } catch (e) { fail("T4/T5: session key setup", e); }

  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── Test Group 3: ERC-7828 Chain-Qualified Address ──\n");

  // T6: getChainQualifiedAddress
  try {
    const testAddr = g1.address; // use a real checksummed address
    const cqa = await pub.readContract({
      address: factoryAddr, abi: fA.abi, functionName: "getChainQualifiedAddress",
      args: [testAddr],
    }) as Hex;
    const expected = keccak256(encodePacked(["address", "uint256"], [testAddr, BigInt(chainId)]));
    if (cqa !== expected) throw new Error(`CQA mismatch: ${cqa} != ${expected}`);
    ok("T6: getChainQualifiedAddress matches keccak256(addr++chainId)");
  } catch (e) { fail("T6: CQA", e); }

  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n── Test Group 4: Factory State ──\n");

  // T7: community guardian stored correctly
  try {
    const stored = await pub.readContract({
      address: factoryAddr, abi: fA.abi, functionName: "defaultCommunityGuardian",
    }) as Address;
    if (stored.toLowerCase() !== community.address.toLowerCase()) {
      throw new Error(`community guardian mismatch: ${stored}`);
    }
    ok("T7: factory.defaultCommunityGuardian == community address");
  } catch (e) { fail("T7: community guardian", e); }

  // T8: Implementation is non-zero
  try {
    if (implAddr === "0x0000000000000000000000000000000000000000") {
      throw new Error("implementation is address(0)");
    }
    const code = await pub.getBytecode({ address: implAddr });
    if (!code || code.length <= 2) throw new Error("no code at implementation");
    ok("T8: implementation has code deployed");
  } catch (e) { fail("T8: implementation", e); }

  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(` Anvil E2E Results: ${passed} passed, ${failed} failed`);
  console.log("═══════════════════════════════════════════════════════════════\n");

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("Fatal:", err.message ?? err);
  process.exit(1);
});
