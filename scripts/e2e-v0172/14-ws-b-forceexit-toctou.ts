/**
 * scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts
 *
 * Phase 14 — WS-B: ForceExit TOCTOU re-verify approvers at execute (issues #70, #77).
 *
 * ⚠️ PENDING v0.18 DEPLOY. beta.4 is still live; this script SKIPs (exit 0) until
 *    AIRACCOUNT_V018_* addresses are added to .env.sepolia. See common-v018.ts.
 *
 * What WS-B changed (vs beta.4):
 *   - executeForceExit re-reads the account's LIVE guardian set and counts only
 *     approvers whose snapshot address is still a current guardian
 *     (recorded approvers ∩ current guardians). If that live count drops below
 *     APPROVAL_THRESHOLD (=2) it reverts `ApproverNoLongerGuardian()` — closing
 *     the time-of-check/time-of-use window where a guardian approves, is removed,
 *     and the stale approval still counts at execute (#70).
 *   - `_readGuardians` fails loudly (`IncompatibleAccount`) on a bad/absent
 *     guardians(uint256) getter instead of silently treating it as address(0) (#77).
 *
 * On-chain E2E flow (real txs, costs gas — run after v0.18 deploy):
 *   WSB.1  createAccountWithDefaults (3 guardians: jason[0], bob[1], community[2])
 *   WSB.2  install ForceExitModule (EXECUTOR) via WS-A guardian-nonce sig
 *   WSB.3  account.execute(ForceExit.proposeForceExit(target,0,0x)) — proposal opened
 *   WSB.4  approveForceExit(account, sig=jason)  — approval bit 0
 *   WSB.5  approveForceExit(account, sig=bob)    — approval bit 1 → reaches threshold 2
 *   WSB.6  removeGuardian(index=0 = jason) with 2 guardian sigs — jason leaves the set
 *   WSB.7  executeForceExit(account) — must REVERT ApproverNoLongerGuardian()
 *          (live approvers = {bob} = 1 < threshold 2; jason's stale approval no longer counts)
 *
 * NOTE on prerequisites that the deploy/runner must satisfy:
 *   - `_guardianRemovalNonce` has no public getter; this script assumes a FRESH
 *     account (removal nonce = 0). If the account has had prior removals, set
 *     V018_GUARDIAN_REMOVAL_NONCE in the env.
 *   - WSB.6 removes a guardian (3 → 2). removeGuardian requires guardianCount > 2,
 *     so this MUST run on a 3-guardian account and only once.
 *
 * Run: pnpm tsx scripts/e2e-v0172/14-ws-b-forceexit-toctou.ts
 */

import {
  keccak256, encodePacked, encodeFunctionData, encodeAbiParameters,
  parseAbiParameters, type Hash, type Address,
} from "viem";
import {
  publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests, type TestCase,
  expectRawCallRevert,
} from "./common.js";
import {
  requireV018, guardianOpHashRaw, installOpData,
} from "./common-v018.js";

const PHASE = "14-ws-b-forceexit-toctou";
const A = requireV018(PHASE); // SKIPs (exit 0) if v0.18 not deployed.

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
// v0.20.2: installModule moved to Extension (fallback-routed) — use merged full ABI.
const v7Abi      = loadMergedAbi();
const femAbi     = loadAbi("ForceExitModule");

const MODULE_TYPE_EXECUTOR = 2n;
const L2_TYPE_OPTIMISM = 1; // ForceExitModule.L2_TYPE_OPTIMISM — valid so the bridge path is well-defined
const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 140_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n;
// onInstall(bytes) decodes the module init data as abi.encode(uint8 l2Type). Installing with a
// VALID L2 type means that, IF the TOCTOU guardian check ever passed, executeForceExit would
// reach the bridge dispatch rather than reverting UnsupportedL2Type() — so the ONLY expected
// failure in WSB.7 is the guardian re-check (ApproverNoLongerGuardian), asserted by exact selector.
const MODULE_INIT_DATA = encodeAbiParameters(parseAbiParameters("uint8"), [L2_TYPE_OPTIMISM]);
const MODULE_INIT_HASH = keccak256(MODULE_INIT_DATA);
const REMOVAL_NONCE = BigInt(process.env.V018_GUARDIAN_REMOVAL_NONCE ?? "0");

// Trivial force-exit target: the proposal's value/data is irrelevant because the
// TOCTOU live-approver check fires BEFORE the exit call is dispatched.
const EXIT_TARGET: Address = "0x000000000000000000000000000000000000dEaD";
const EXIT_VALUE = 0n;
const EXIT_DATA: `0x${string}` = "0x";

let account: Address = "0x" as Address;
let proposedAt = 0n;
const communityGuardian = (process.env.COMMUNITY_GUARDIAN_ADDRESS ?? "0x") as Address;

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

// ForceExit proposal hash: keccak256("FORCE_EXIT" || chainId || account || target || value || data || proposedAt)
function proposalHashRaw(at: bigint): `0x${string}` {
  return keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "bytes", "uint256"],
    ["FORCE_EXIT", 11155111n, account, EXIT_TARGET, EXIT_VALUE, EXIT_DATA, at],
  ));
}

const tests: TestCase[] = [
  {
    name: "WSB.1 createAccountWithDefaults (3 guardians)",
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
      return { txHash: hash, gas: gasUsed, notes: `account = ${account} (g0=jason, g1=bob, g2=community)` };
    },
  },
  {
    name: "WSB.2 installModule(EXECUTOR, ForceExit) via WS-A guardian-nonce sig",
    run: async () => {
      const nonce = (await publicClient.readContract({
        address: account, abi: v7Abi, functionName: "moduleManagementNonce",
      })) as bigint;
      const raw = guardianOpHashRaw(
        account, "INSTALL_MODULE",
        installOpData(MODULE_TYPE_EXECUTOR, A.forceExitModule, MODULE_INIT_HASH, nonce),
      );
      const sig = await jason.signMessage({ message: { raw } });
      // v0.20.2 encoding: abi.encode(uint8[] signerIdxs, bytes[] sigs, bytes moduleInitData)
      // Guardian 0 = jason (order matches createAccountWithDefaults args).
      const initData = encodeAbiParameters(
        parseAbiParameters("uint8[], bytes[], bytes"),
        [[0], [sig], MODULE_INIT_DATA],
      );
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "installModule",
        args: [MODULE_TYPE_EXECUTOR, A.forceExitModule, initData],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "ForceExitModule installed with L2_TYPE_OPTIMISM init data" };
    },
  },
  {
    name: "WSB.3 account.execute(ForceExit.proposeForceExit) — open proposal",
    run: async () => {
      // proposeForceExit checks _initialized[msg.sender]; msg.sender must be the account,
      // so we route it through account.execute(forceExitModule, 0, calldata).
      const inner = encodeFunctionData({
        abi: femAbi, functionName: "proposeForceExit",
        args: [EXIT_TARGET, EXIT_VALUE, EXIT_DATA],
      });
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "execute",
        args: [A.forceExitModule, 0n, inner],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      // Read back proposedAt for the approval hash.
      const pe = (await publicClient.readContract({
        address: A.forceExitModule, abi: femAbi, functionName: "getPendingExit", args: [account],
      })) as readonly unknown[];
      // getPendingExit returns (target, value, data, proposedAt, approvalBitmap, ...) — proposedAt at index 3.
      proposedAt = pe[3] as bigint;
      if (proposedAt === 0n) throw new Error("proposeForceExit did not record proposedAt");
      return { txHash: hash, gas: gasUsed, notes: `proposal opened, proposedAt=${proposedAt}` };
    },
  },
  {
    name: "WSB.4 approveForceExit(sig=jason) — approval bit 0",
    run: async () => {
      const sig = await jason.signMessage({ message: { raw: proposalHashRaw(proposedAt) } });
      const hash = await wAnnie.writeContract({
        address: A.forceExitModule, abi: femAbi, functionName: "approveForceExit",
        args: [account, sig], chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "jason approved (bit 0)" };
    },
  },
  {
    name: "WSB.5 approveForceExit(sig=bob) — reaches threshold 2",
    run: async () => {
      const sig = await bob.signMessage({ message: { raw: proposalHashRaw(proposedAt) } });
      const hash = await wAnnie.writeContract({
        address: A.forceExitModule, abi: femAbi, functionName: "approveForceExit",
        args: [account, sig], chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "bob approved (bit 1) → 2/2 approvals recorded" };
    },
  },
  {
    name: "WSB.6 removeGuardian(index=0 = jason) — jason leaves the set",
    run: async () => {
      // removeGuardian opData (AAStarAirAccountBase.sol:1518):
      //   abi.encode(_guardianRemovalNonce, index, guardianToRemove, remX, remY)
      // Jason is ECDSA → _getP256Key returns (0, 0). Index 0 maps to jason.
      const ZERO_B32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;
      const raw = guardianOpHashRaw(
        account, "REMOVE_GUARDIAN",
        encodeAbiParameters(
          parseAbiParameters("uint256, uint8, address, bytes32, bytes32"),
          [REMOVAL_NONCE, 0, jason.address, ZERO_B32, ZERO_B32],
        ),
      );
      // Two distinct current guardians sign the removal (jason may sign his own removal).
      const sig1 = await jason.signMessage({ message: { raw } });
      const sig2 = await bob.signMessage({ message: { raw } });
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "removeGuardian",
        args: [0, [sig1, sig2]], chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: "jason removed; guardians 3 → 2 (bob, community)" };
    },
  },
  {
    name: "WSB.7 executeForceExit — must REVERT ApproverNoLongerGuardian() (#70)",
    run: async () => {
      // jason was an approver but is no longer a guardian; live approvers = {bob} = 1 < 2.
      // The TOCTOU re-check (ForceExitModule.sol:269) reverts the EXACT error
      // ApproverNoLongerGuardian() BEFORE the bridge dispatch. Because the module was
      // installed with a valid L2 type, a passing guardian check would NOT spuriously
      // revert UnsupportedL2Type() — so any other selector here is a genuine test failure.
      await expectRawCallRevert(
        {
          to: A.forceExitModule,
          data: encodeFunctionData({ abi: femAbi, functionName: "executeForceExit", args: [account] }),
          from: annie.address,
        },
        "ApproverNoLongerGuardian()",
      );
      return { notes: "executeForceExit reverted with exact ApproverNoLongerGuardian() ✓ TOCTOU closed" };
    },
  },
];

void communityGuardian; // documented as guardian[2]; not directly invoked.
(async () => { await runTests(PHASE, tests); })();
