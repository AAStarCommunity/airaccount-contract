/**
 * scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts
 *
 * Phase 15 — WS-C: session-key cap (#83) + sliding-window velocity (#57).
 *
 * ⚠️ PENDING v0.18 DEPLOY. beta.4 is still live; this script SKIPs (exit 0) until
 *    AIRACCOUNT_V018_* addresses are added to .env.sepolia. See common-v018.ts.
 *
 * What WS-C changed (vs beta.4):
 *   - Per-account session-key cap MAX_SESSION_KEYS_PER_ACCOUNT = 50, counting ECDSA
 *     + P256 sessions together. A 51st grant reverts `TooManySessionKeys()`. A revoke
 *     frees a slot. New view: `sessionKeyCount(address)`.
 *   - Velocity limiter is now a sliding window (prev-window count weighted into the
 *     rolling estimate) so a burst straddling the window boundary can't exceed the
 *     limit. `recordCallForVelocity` reverts `VelocityLimitExceeded()` when the
 *     sliding estimate >= velocityLimit. (Documented as APPROXIMATE for weighted keys.)
 *
 * On-chain E2E coverage:
 *   WSC.1  createAccountWithDefaults
 *   WSC.2  sessionKeyCount(account) == 0 on fresh account
 *   WSC.3  grantSessionDirect ×3 → sessionKeyCount increments to 3
 *   WSC.4  revokeSession ×1 → sessionKeyCount decrements to 2 (slot freed)
 *   WSC.5  CAP ENFORCEMENT (heavy; gated behind RUN_FULL_CAP_TEST=1):
 *          grant up to 50 then assert the 51st reverts TooManySessionKeys().
 *          Default run verifies the cap CONSTANT + accounting only (no 50-tx loop).
 *
 * VELOCITY (#57) + EXPIRY are execution-path behaviours: `recordCallForVelocity`
 * only fires when a session-key-signed UserOperation is EXECUTED. There is no public
 * view to probe the sliding estimate. They are therefore covered by the session-key
 * UserOp bundler flow, not by direct calls — see:
 *   - scripts/e2e-v0172/12-userop-bundler.ts (Pimlico UserOp submission harness)
 *   - scripts/test-session-key-userop-e2e.ts (session-signed UserOp construction)
 * TODO(after v0.18 deploy): add WSC.6 (velocity: Nth session UserOp reverts
 * VelocityLimitExceeded) and WSC.7 (expired session UserOp rejected) by wiring a
 * session-key signature into the phase-12 bundler harness against the v0.18 SKV.
 *
 * Run: pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts
 *      RUN_FULL_CAP_TEST=1 pnpm tsx scripts/e2e-v0172/15-ws-c-sessionkey-cap-velocity.ts
 */

import {
  keccak256, encodePacked, encodeFunctionData,
  type Hash, type Address,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  publicClient, wAnnie, annie, jason, bob,
  loadAbi, runTests, type TestCase,
  expectRawCallRevert, recordResult,
} from "./common.js";
import { requireV018, MAX_SESSION_KEYS_PER_ACCOUNT } from "./common-v018.js";

const PHASE = "15-ws-c-sessionkey-cap-velocity";
const A = requireV018(PHASE); // SKIPs (exit 0) if v0.18 not deployed.

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const skvAbi     = loadAbi("SessionKeyValidator");

const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 150_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n;
const RUN_FULL_CAP = process.env.RUN_FULL_CAP_TEST === "1";

type SessionConfig = {
  expiry: number; contractScope: Address; selectorScope: `0x${string}`;
  revoked: boolean; velocityLimit: number; velocityWindow: number;
  callTargets: Address[]; selectorAllowlist: `0x${string}`[];
};
function openCfg(): SessionConfig {
  return {
    expiry: Math.floor(Date.now() / 1000) + 86400,
    contractScope: "0x0000000000000000000000000000000000000000",
    selectorScope: "0x00000000", revoked: false,
    velocityLimit: 0, velocityWindow: 0, callTargets: [], selectorAllowlist: [],
  };
}

let account: Address = "0x" as Address;
const keys = Array.from({ length: 3 }, () => privateKeyToAccount(generatePrivateKey()));

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
async function readCount(): Promise<bigint> {
  return (await publicClient.readContract({
    address: A.sessionKeyValidator, abi: skvAbi, functionName: "sessionKeyCount", args: [account],
  })) as bigint;
}
async function grant(sessionKey: Address): Promise<Hash> {
  return wAnnie.writeContract({
    address: A.sessionKeyValidator, abi: skvAbi, functionName: "grantSessionDirect",
    args: [account, sessionKey, openCfg()], chain: null, account: annie,
  });
}

const tests: TestCase[] = [
  {
    name: "WSC.1 createAccountWithDefaults (session-cap test account)",
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
    name: "WSC.2 sessionKeyCount(account) == 0 on fresh account",
    run: async () => {
      const c = await readCount();
      if (c !== 0n) throw new Error(`expected 0, got ${c}`);
      return { notes: "fresh account session-key count = 0 ✓" };
    },
  },
  {
    name: "WSC.3 grantSessionDirect ×3 → sessionKeyCount == 3",
    run: async () => {
      let last: Hash = "0x" as Hash;
      for (const k of keys) { last = await grant(k.address); await waitTx(last); }
      const c = await readCount();
      if (c !== 3n) throw new Error(`expected 3, got ${c}`);
      return { txHash: last, notes: "3 grants → count = 3 ✓" };
    },
  },
  {
    name: "WSC.4 revokeSession ×1 → sessionKeyCount == 2 (slot freed)",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: A.sessionKeyValidator, abi: skvAbi, functionName: "revokeSession",
        args: [account, keys[0].address], chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      const c = await readCount();
      if (c !== 2n) throw new Error(`expected 2 after revoke, got ${c}`);
      return { txHash: hash, gas: gasUsed, notes: "revoke freed a slot → count = 2 ✓" };
    },
  },
];

// WSC.5 — CAP ENFORCEMENT (heavy: 50+ txs). Only runs (and only records a result) when
// RUN_FULL_CAP_TEST=1. Otherwise it is recorded as SKIP — NEVER as a trivial PASS, since
// without the loop nothing about the 50/51 boundary was actually exercised.
const capEnforcementTest: TestCase = {
  name: `WSC.5 CAP: 51st grant reverts TooManySessionKeys() (cap=${MAX_SESSION_KEYS_PER_ACCOUNT})`,
  run: async () => {
    // Fill to the cap (we already hold 2 live slots from WSC.3/4), then assert the over-cap grant.
    let granted = await readCount();
    while (granted < BigInt(MAX_SESSION_KEYS_PER_ACCOUNT)) {
      await waitTx(await grant(privateKeyToAccount(generatePrivateKey()).address));
      granted++;
    }
    const after = await readCount();
    if (after !== BigInt(MAX_SESSION_KEYS_PER_ACCOUNT)) {
      throw new Error(`expected count == cap ${MAX_SESSION_KEYS_PER_ACCOUNT} before over-cap grant, got ${after}`);
    }
    // The cap is now reached; the 51st grant MUST revert with the EXACT TooManySessionKeys()
    // selector. expectRawCallRevert throws on any mismatch or on success.
    const overCapKey = privateKeyToAccount(generatePrivateKey()).address;
    await expectRawCallRevert(
      {
        to: A.sessionKeyValidator,
        data: encodeFunctionData({
          abi: skvAbi, functionName: "grantSessionDirect", args: [account, overCapKey, openCfg()],
        }),
        from: annie.address,
      },
      "TooManySessionKeys()",
    );
    return { notes: `cap reached at ${MAX_SESSION_KEYS_PER_ACCOUNT}; 51st grant reverted exact TooManySessionKeys() ✓` };
  },
};

(async () => {
  await runTests(PHASE, RUN_FULL_CAP ? [...tests, capEnforcementTest] : tests);
  if (!RUN_FULL_CAP) {
    const note =
      `cap constant = ${MAX_SESSION_KEYS_PER_ACCOUNT}; accounting verified in WSC.3/4. ` +
      `Full 50-grant enforcement (51st → TooManySessionKeys()) NOT run — set RUN_FULL_CAP_TEST=1 (50+ txs).`;
    console.log(`\n  ${capEnforcementTest.name}  SKIP`);
    console.log(`    ${note}`);
    recordResult({ phase: PHASE, test: capEnforcementTest.name, status: "SKIP", notes: note });
  }
})();
