/**
 * scripts/e2e-v0172/11-guardian-recovery-module.ts
 *
 * Phase 11 — Guardian ops, Social recovery, Module install/uninstall on Sepolia.
 *
 * COSTS GAS. Deploys a fresh account then covers:
 *   GR.1   createAccountWithDefaults (guardian-test account)
 *   GR.2   proposeRecovery(dummyNewOwner) — Jason (guardian[0]) proposes
 *   GR.3   activeRecovery.newOwner != address(0)
 *   GR.4   approveRecovery() — Bob (guardian[1]) approves → 2/3 threshold reached
 *   GR.5   approvalBitmap has 2 bits set
 *   GR.6   cancelRecovery() — Jason votes cancel (1/3)
 *   GR.7   cancelRecovery() — Bob votes cancel → 2/3 reached, recovery cancelled
 *   GR.8   activeRecovery.newOwner == address(0) (recovery cancelled)
 *   GR.9   installModule(MODULE_TYPE_EXECUTOR=2, ForceExitModule, guardianSig+emptyInitData)
 *   GR.10  isModuleInstalled(2, ForceExitModule) == true
 *   GR.11  uninstallModule(2, ForceExitModule, 2×guardianSig) — 2 sigs required
 *   GR.12  isModuleInstalled(2, ForceExitModule) == false after uninstall
 *
 * Key viem v2.47 note: readContract with multiple named outputs returns a PLAIN ARRAY,
 * not a named object. Use r[0], r[1], r[2], r[3] for positional access.
 *
 * Run: pnpm tsx scripts/e2e-v0172/11-guardian-recovery-module.ts
 */

import {
  keccak256, encodePacked, encodeAbiParameters, encodeFunctionData, type Hash, type Address,
} from "viem";
import {
  ADDR, publicClient, wAnnie, wJason, wBob, annie, jason, bob,
  loadAbi, runTests, type TestCase,
} from "./common.js";

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");
const v7Abi      = loadAbi("AAStarAirAccountV7");

const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 11_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n; // 0.01 ETH
const GUARDIAN1   = jason.address;
const GUARDIAN2   = bob.address;

// ForceExitModule is installed as Executor (typeId=2)
const MODULE_TYPE_EXECUTOR = 2n;

// Dummy new owner for recovery test (not current owner, not a guardian)
const DUMMY_NEW_OWNER: Address = "0x1111111111111111111111111111111111111111";

let account: Address = "0x" as Address;

async function waitTx(hash: Hash): Promise<{ gasUsed: bigint }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted (status=${receipt.status})`);
  return { gasUsed: receipt.gasUsed };
}

async function sendTxDirect(
  wallet: typeof wJason | typeof wBob | typeof wAnnie,
  from: typeof jason | typeof bob | typeof annie,
  abi: readonly unknown[],
  functionName: string,
  args: unknown[] = [],
): Promise<Hash> {
  // Use sendTransaction with explicit gas to bypass viem's pre-flight simulation.
  // This is necessary when simulateContract raises spurious "Missing or invalid parameters"
  // for functions that do succeed on-chain (timing race with pending TXs, etc.)
  const callData = encodeFunctionData({ abi, functionName, args } as any);
  return wallet.sendTransaction({
    to: account,
    data: callData,
    gas: 150_000n,
    chain: null,
    account: from,
  });
}

async function guardianAcceptSig(
  signer: typeof jason | typeof bob,
  owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

// GUARDIAN_SIG_VERSION must match the contract constant (AAStarAirAccountBase.sol line 84).
// The contract uses abi.encode (not encodePacked) for the outer hash — see _guardianOpHash().
const GUARDIAN_SIG_VERSION = 4;
const CHAIN_ID = BigInt(11155111);

// Build the guardian op hash exactly as the contract does:
//   keccak256(abi.encode(GUARDIAN_SIG_VERSION, chainId, account, opLabel, opData))
// then signMessage adds the EIP-191 prefix, matching .toEthSignedMessageHash().
function buildGuardianOpHash(acct: Address, opLabel: string, opData: `0x${string}`): `0x${string}` {
  return keccak256(encodeAbiParameters(
    [{ type: "uint8" }, { type: "uint256" }, { type: "address" }, { type: "string" }, { type: "bytes" }],
    [GUARDIAN_SIG_VERSION, CHAIN_ID, acct, opLabel, opData],
  ));
}

// Guardian sig for installModule.
// opData = abi.encode(moduleTypeId, module, keccak256(moduleInitData), moduleManagementNonce)
// nonce must be read from the account before signing (increments after each install/uninstall).
async function buildInstallModuleSig(
  signer: typeof jason | typeof bob,
  acct: Address,
  moduleTypeId: bigint,
  module: Address,
  moduleInitData: `0x${string}`,
  nonce: bigint,
): Promise<`0x${string}`> {
  const moduleInitDataHash = keccak256(moduleInitData === "0x" ? "0x" : moduleInitData);
  const opData = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "bytes32" }, { type: "uint256" }],
    [moduleTypeId, module, moduleInitDataHash, nonce],
  );
  const raw = buildGuardianOpHash(acct, "INSTALL_MODULE", opData);
  return signer.signMessage({ message: { raw } });
}

// Guardian sigs for uninstallModule — min(guardianCount, 2) sigs concatenated.
// opData = abi.encode(moduleTypeId, module, moduleManagementNonce)
// nonce must be read from the account before signing.
async function buildUninstallModuleSigs(
  acct: Address,
  moduleTypeId: bigint,
  module: Address,
  nonce: bigint,
): Promise<`0x${string}`> {
  const opData = encodeAbiParameters(
    [{ type: "uint256" }, { type: "address" }, { type: "uint256" }],
    [moduleTypeId, module, nonce],
  );
  const raw = buildGuardianOpHash(acct, "UNINSTALL_MODULE", opData);
  const sig1 = await jason.signMessage({ message: { raw } }); // guardian[0]
  const sig2 = await bob.signMessage({ message: { raw } });   // guardian[1]
  return (sig1 + sig2.slice(2)) as `0x${string}`;
}

function popcount(n: bigint): number {
  let c = 0;
  while (n > 0n) { c += Number(n & 1n); n >>= 1n; }
  return c;
}

// viem v2.47 returns multi-output functions as PLAIN ARRAYS (not named objects).
// Use positional indexing: r[0]=newOwner, r[1]=proposedAt, r[2]=approvalBitmap, r[3]=cancellationBitmap
async function readActiveRecovery(): Promise<{
  newOwner: Address; proposedAt: bigint; approvalBitmap: bigint; cancellationBitmap: bigint;
}> {
  const r = await publicClient.readContract({
    address: account, abi: baseAbi, functionName: "activeRecovery",
  }) as readonly [Address, bigint, bigint, bigint];
  return {
    newOwner: r[0],
    proposedAt: r[1],
    approvalBitmap: r[2],
    cancellationBitmap: r[3],
  };
}

const tests: TestCase[] = [
  {
    name: "GR.1 createAccountWithDefaults (guardian-recovery-module test account)",
    run: async () => {
      account = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, GUARDIAN2, DAILY_LIMIT],
      })) as Address;

      const sig1 = await guardianAcceptSig(jason, annie.address, SALT, DAILY_LIMIT);
      const sig2 = await guardianAcceptSig(bob,   annie.address, SALT, DAILY_LIMIT);

      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, sig1, GUARDIAN2, sig2, DAILY_LIMIT],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `guardian-test account = ${account}` };
    },
  },

  // ─── Social Recovery: propose → approve → cancel ──────────────────────
  {
    name: "GR.2 proposeRecovery(dummyNewOwner) — Jason (guardian[0]) proposes",
    run: async () => {
      const hash = await wJason.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "proposeRecovery",
        args: [DUMMY_NEW_OWNER],
        chain: null,
        account: jason,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `Jason proposed recovery to ${DUMMY_NEW_OWNER}` };
    },
  },
  {
    name: "GR.3 activeRecovery.newOwner != address(0) after proposal",
    run: async () => {
      const r = await readActiveRecovery();
      if (r.newOwner === "0x0000000000000000000000000000000000000000") {
        throw new Error(`activeRecovery.newOwner is zero — proposal failed`);
      }
      return { notes: `activeRecovery.newOwner = ${r.newOwner}, approvalBitmap=${r.approvalBitmap}` };
    },
  },
  {
    name: "GR.4 approveRecovery() — Bob (guardian[1]) approves → 2/3 threshold",
    run: async () => {
      const hash = await wBob.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "approveRecovery",
        args: [],
        chain: null,
        account: bob,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `Bob approved — 2/3 approvals reached` };
    },
  },
  {
    name: "GR.5 approvalBitmap has 2 bits set (guardian[0]+guardian[1])",
    run: async () => {
      const r = await readActiveRecovery();
      const approvals = popcount(r.approvalBitmap);
      if (approvals < 2) throw new Error(`expected ≥2 approvals, got ${approvals} (bitmap=${r.approvalBitmap})`);
      return { notes: `approvalBitmap=${r.approvalBitmap} (${approvals} approvals) ✓` };
    },
  },
  {
    name: "GR.6 cancelRecovery() — Jason votes cancel (1/3)",
    run: async () => {
      // Use sendTransaction + explicit gas to bypass viem's simulateContract pre-flight,
      // which can emit "Missing or invalid parameters" on some RPC nodes for this function.
      const hash = await sendTxDirect(wJason, jason, baseAbi, "cancelRecovery");
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `Jason cancel-voted (1/3)` };
    },
  },
  {
    name: "GR.7 cancelRecovery() — Bob votes cancel → 2/3, recovery cancelled",
    run: async () => {
      const hash = await sendTxDirect(wBob, bob, baseAbi, "cancelRecovery");
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `Bob cancel-voted (2/3) → recovery cancelled` };
    },
  },
  {
    name: "GR.8 activeRecovery cleared (recovery successfully cancelled)",
    run: async () => {
      const r = await readActiveRecovery();
      if (r.newOwner !== "0x0000000000000000000000000000000000000000") {
        throw new Error(`expected activeRecovery cleared, newOwner=${r.newOwner}`);
      }
      return { notes: `activeRecovery.newOwner = address(0) ✓ (cancelled via 2/3 guardian votes)` };
    },
  },

  // ─── Module: install → verify → uninstall ForceExitModule ──────────────
  {
    name: "GR.9 installModule(EXECUTOR=2, ForceExitModule, guardianSig+emptyInitData)",
    run: async () => {
      const moduleInitData: `0x${string}` = "0x";
      // Read current nonce from account before signing — it increments after each install/uninstall.
      const nonce = await publicClient.readContract({
        address: account, abi: v7Abi, functionName: "moduleManagementNonce",
      }) as bigint;
      const guardSig = await buildInstallModuleSig(
        jason, account, MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, moduleInitData, nonce,
      );
      // initData layout: [sig (65 bytes)] [moduleInitData (empty)]
      const initData = guardSig;

      const hash = await wAnnie.writeContract({
        address: account,
        abi: v7Abi,
        functionName: "installModule",
        args: [MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, initData],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `ForceExitModule installed (typeId=2), nonce was ${nonce}` };
    },
  },
  {
    name: "GR.10 isModuleInstalled(EXECUTOR=2, ForceExitModule) == true",
    run: async () => {
      const ok = await publicClient.readContract({
        address: account, abi: v7Abi,
        functionName: "isModuleInstalled",
        args: [MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, "0x"],
      });
      if (ok !== true) throw new Error(`expected true, got ${ok}`);
      return { notes: `ForceExitModule is installed ✓` };
    },
  },
  {
    name: "GR.11 uninstallModule(EXECUTOR=2, ForceExitModule, 2×guardianSig) — min(guardianCount,2) sigs",
    run: async () => {
      // uninstallModule requires min(guardianCount, 2) guardian sigs concatenated in deInitData.
      // With guardianCount=2: need sig[0] || sig[1] (130 bytes total).
      // Read nonce AFTER the installModule in GR.9 (nonce was incremented by that tx).
      const nonce = await publicClient.readContract({
        address: account, abi: v7Abi, functionName: "moduleManagementNonce",
      }) as bigint;
      const deInitData = await buildUninstallModuleSigs(account, MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, nonce);

      const hash = await wAnnie.writeContract({
        address: account,
        abi: v7Abi,
        functionName: "uninstallModule",
        args: [MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, deInitData],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `ForceExitModule uninstalled, nonce was ${nonce}` };
    },
  },
  {
    name: "GR.12 isModuleInstalled(EXECUTOR=2, ForceExitModule) == false after uninstall",
    run: async () => {
      const ok = await publicClient.readContract({
        address: account, abi: v7Abi,
        functionName: "isModuleInstalled",
        args: [MODULE_TYPE_EXECUTOR, ADDR.forceExitModule, "0x"],
      });
      if (ok !== false) throw new Error(`expected false, got ${ok}`);
      return { notes: `ForceExitModule is uninstalled ✓` };
    },
  },
];

(async () => { await runTests("11-guardian-recovery-module", tests); })();
