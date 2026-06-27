/**
 * scripts/e2e-v0172/13-ws-a-module-nonce.ts
 *
 * Phase 13 — WS-A: module-management nonce replay protection (issues #75, #84).
 *
 * ⚠️ PENDING v0.18 DEPLOY. beta.4 is still live; this script SKIPs (exit 0) until
 *    AIRACCOUNT_V018_* addresses are added to .env.sepolia. See common-v018.ts.
 *
 * What WS-A changed (vs beta.4):
 *   - installModule / uninstallModule guardian signatures now fold in
 *     GUARDIAN_SIG_VERSION (=4, #84) and a monotonic `_moduleManagementNonce` (#75)
 *     via `_guardianOpHash(...)` = keccak256(abi.encode(version, chainId, account,
 *     opLabel, opData)).toEthSignedMessageHash().
 *   - The nonce increments on BOTH install AND uninstall, so a guardian signature
 *     captured for one install can NOT be replayed to silently reinstall the module
 *     after an uninstall.
 *   - New view: `moduleManagementNonce()`.
 *
 * On-chain E2E flow (real txs, costs gas — run after v0.18 deploy):
 *   WSA.1  createAccountWithDefaults (2 guardians: jason, bob)
 *   WSA.2  moduleManagementNonce() == 0 on a fresh account
 *   WSA.3  installModule(EXECUTOR, ForceExit, sig@nonce0) — succeeds; capture sig0
 *   WSA.4  moduleManagementNonce() == 1 after install
 *   WSA.5  uninstallModule(EXECUTOR, ForceExit, sigs@nonce1) — succeeds
 *   WSA.6  moduleManagementNonce() == 2 after uninstall
 *   WSA.7  REPLAY: installModule using the stale sig0 (signed @nonce0) — must REVERT
 *          (InvalidGuardianSig) because the live nonce is now 2.
 *   WSA.8  installModule with a FRESH sig @nonce2 — succeeds (proves the path still works).
 *
 * Run: pnpm tsx scripts/e2e-v0172/13-ws-a-module-nonce.ts
 */

import {
  keccak256, encodePacked, encodeFunctionData, encodeAbiParameters, parseAbiParameters,
  type Hash, type Address,
} from "viem";
import {
  publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests, type TestCase,
  expectRawCallRevert,
} from "./common.js";
import {
  requireV018, guardianOpHashRaw, installOpData, uninstallOpData,
} from "./common-v018.js";

const PHASE = "13-ws-a-module-nonce";
const A = requireV018(PHASE); // SKIPs (exit 0) if v0.18/v0.20.x not deployed.

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
// v0.20.2: installModule/uninstallModule moved to Extension (fallback-routed).
// Use the merged full ABI so viem can encode the call correctly.
const v7Abi      = loadMergedAbi();

const MODULE_TYPE_EXECUTOR = 2n;
const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 130_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n; // 0.01 ETH
const EMPTY_INIT_HASH = keccak256(new Uint8Array(0)); // keccak256("") — module init data is empty

let account: Address = "0x" as Address;
let staleInstallSig0: `0x${string}` = "0x"; // sig captured @nonce0, later replayed

async function waitTx(hash: Hash): Promise<{ gasUsed: bigint }> {
  const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (r.status !== "success") throw new Error(`tx ${hash} reverted`);
  return { gasUsed: r.gasUsed };
}

async function acceptGuardianSig(
  signer: typeof jason | typeof bob, owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", 11155111n, A.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

// v0.20.2 encoding: installModule initData = abi.encode(uint8[] signerIdxs, bytes[] sigs, bytes moduleInitData)
// Guardian 0 = jason, guardian 1 = bob (order matches createAccountWithDefaults args).
async function installSig(signer: typeof jason | typeof bob, nonce: bigint, guardianIdx: number = 0): Promise<`0x${string}`> {
  const raw = guardianOpHashRaw(
    account, "INSTALL_MODULE",
    installOpData(MODULE_TYPE_EXECUTOR, A.forceExitModule, EMPTY_INIT_HASH, nonce),
  );
  const sig = await signer.signMessage({ message: { raw } });
  return encodeAbiParameters(
    parseAbiParameters("uint8[], bytes[], bytes"),
    [[guardianIdx], [sig], "0x"],
  );
}

// v0.20.2 encoding: uninstallModule deInitData = abi.encode(uint8[] signerIdxs, bytes[] sigs)
async function uninstallSigs(nonce: bigint): Promise<`0x${string}`> {
  const raw = guardianOpHashRaw(
    account, "UNINSTALL_MODULE",
    uninstallOpData(MODULE_TYPE_EXECUTOR, A.forceExitModule, nonce),
  );
  const s1 = await jason.signMessage({ message: { raw } });
  const s2 = await bob.signMessage({ message: { raw } });
  return encodeAbiParameters(
    parseAbiParameters("uint8[], bytes[]"),
    [[0, 1], [s1, s2]],
  );
}

async function readNonce(): Promise<bigint> {
  return (await publicClient.readContract({
    address: account, abi: v7Abi, functionName: "moduleManagementNonce",
  })) as bigint;
}

const tests: TestCase[] = [
  {
    name: "WSA.1 createAccountWithDefaults (2 guardians)",
    run: async () => {
      account = (await publicClient.readContract({
        address: A.factory, abi: factoryAbi, functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, jason.address, bob.address, DAILY_LIMIT],
      })) as Address;
      const s1 = await acceptGuardianSig(jason, annie.address, SALT, DAILY_LIMIT);
      const s2 = await acceptGuardianSig(bob,   annie.address, SALT, DAILY_LIMIT);
      const hash = await wAnnie.writeContract({
        address: A.factory, abi: factoryAbi, functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, jason.address, s1, bob.address, s2, DAILY_LIMIT],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `account = ${account}` };
    },
  },
  {
    name: "WSA.2 moduleManagementNonce() == 0 on fresh account",
    run: async () => {
      const n = await readNonce();
      if (n !== 0n) throw new Error(`expected nonce 0, got ${n}`);
      return { notes: "fresh account nonce = 0 ✓" };
    },
  },
  {
    name: "WSA.3 installModule(EXECUTOR, ForceExit, sig@nonce0) — succeeds",
    run: async () => {
      staleInstallSig0 = await installSig(jason, 0n); // capture for the replay attempt later
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "installModule",
        args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, staleInstallSig0],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "installed @nonce0; sig0 captured for replay" };
    },
  },
  {
    name: "WSA.4 moduleManagementNonce() == 1 after install",
    run: async () => {
      const n = await readNonce();
      if (n !== 1n) throw new Error(`expected nonce 1, got ${n}`);
      return { notes: "install advanced nonce 0 → 1 ✓" };
    },
  },
  {
    name: "WSA.5 uninstallModule(EXECUTOR, ForceExit, sigs@nonce1) — succeeds",
    run: async () => {
      const deInit = await uninstallSigs(1n);
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "uninstallModule",
        args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, deInit],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "uninstalled @nonce1" };
    },
  },
  {
    name: "WSA.6 moduleManagementNonce() == 2 after uninstall",
    run: async () => {
      const n = await readNonce();
      if (n !== 2n) throw new Error(`expected nonce 2, got ${n}`);
      return { notes: "uninstall advanced nonce 1 → 2 ✓" };
    },
  },
  {
    name: "WSA.7 REPLAY stale sig0 (signed @nonce0) — must REVERT NotGuardian() (#75)",
    run: async () => {
      // Precondition: the module must actually be uninstalled, so this is a genuine
      // re-install attempt (not a no-op blocked by ModuleAlreadyInstalled). Confirm first.
      const stillInstalled = await publicClient.readContract({
        address: account, abi: v7Abi, functionName: "isModuleInstalled",
        args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, "0x"],
      });
      if (stillInstalled !== false) {
        throw new Error("expected ForceExitModule uninstalled before replay test, but it is still installed");
      }

      // The live nonce is 2; sig0 was encoded with nonce 0. installModule recomputes the
      // guardian op hash with the CURRENT nonce, so the stale sig fails _verifyGuardianSigByIdx
      // and reverts with InstallModuleUnauthorized() (v0.20.2: _checkGuardianSigsMixed path).
      await expectRawCallRevert(
        {
          to: account,
          data: encodeFunctionData({
            abi: v7Abi, functionName: "installModule",
            args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, staleInstallSig0],
          }),
          from: annie.address, // owner — passes onlyOwnerOrEntryPoint so we reach the sig check
        },
        "InvalidGuardianSignature()",
      );
      return { notes: "stale-nonce install rejected with InvalidGuardianSignature() ✓ (replay defeated)" };
    },
  },
  {
    name: "WSA.8 installModule with FRESH sig@nonce2 — succeeds",
    run: async () => {
      const freshSig = await installSig(jason, 2n);
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "installModule",
        args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, freshSig],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      const n = await readNonce();
      if (n !== 3n) throw new Error(`expected nonce 3 after reinstall, got ${n}`);
      return { txHash: hash, gas: gasUsed, notes: "fresh-nonce reinstall works; nonce 2 → 3 ✓" };
    },
  },
];

(async () => { await runTests(PHASE, tests); })();
