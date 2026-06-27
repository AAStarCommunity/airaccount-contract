/**
 * scripts/e2e-v0172/16-ws-g-p256-low-s.ts
 *
 * Phase 16 — WS-G: P256 (secp256r1) low-S canonicality guard (issue #78).
 *
 * ⚠️ PENDING v0.18 DEPLOY. beta.4 is still live; this script SKIPs (exit 0) until
 *    AIRACCOUNT_V018_* addresses are added to .env.sepolia. See common-v018.ts.
 *
 * What WS-G changed (vs beta.4):
 *   - `_validateP256` now rejects high-S P256 signatures (s > SECP256R1_N_OVER_2)
 *     BEFORE calling the EIP-7212 precompile. EIP-7212 / RIP-7696 accept BOTH (r,s)
 *     and (r, n-s), so without this guard a malleable high-S signature would pass.
 *     This mirrors the EIP-2 low-S check already applied to secp256k1 ECDSA.
 *
 * Precompile note: the secp256r1 precompile at 0x100 IS active on Sepolia (verified
 * via RIP-7212 test vector), so BOTH directions are observable on-chain:
 *   - low-S  signature → validateUserOp returns 0 (valid)
 *   - high-S signature → validateUserOp returns 1 (SIG_VALIDATION_FAILED) — guard fires
 *
 * P256 sig layout the account expects (ALG_P256 = 0x03): [0x03][r(32)][s(32)] = 65 bytes;
 * _validateP256 verifies P256VERIFY(userOpHash, r, s, p256KeyX, p256KeyY).
 *
 * On-chain E2E flow (real txs for setup; signature checks are read-only eth_call):
 *   WSG.1  createAccountWithDefaults
 *   WSG.2  setP256Key(x, y) — install a real secp256r1 passkey on the account
 *   WSG.3  LOW-S: eth_call validateUserOp(from=EntryPoint) with a canonical low-S
 *          P256 signature → returns 0 (valid)
 *   WSG.4  HIGH-S: eth_call validateUserOp with the malleable (r, n-s) form
 *          → returns 1 (rejected by the low-S guard) — proves #78
 *
 * Run: pnpm tsx scripts/e2e-v0172/16-ws-g-p256-low-s.ts
 */

import {
  keccak256, encodePacked, encodeFunctionData, toHex, concat,
  type Hash, type Address, type Hex,
} from "viem";
import { p256 } from "@noble/curves/p256";
import {
  publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests, type TestCase, ADDR,
} from "./common.js";
import { v018Addr, printPendingBanner, SECP256R1_N_OVER_2 } from "./common-v018.js";

const PHASE = "16-ws-g-p256-low-s";
// NOTE: unlike phases 13–15, this script does NOT exit early on a missing v0.18 deploy.
// The precompile-malleability proof (WSG.P1/P2) runs NOW on Sepolia regardless; only the
// account-bound validateUserOp tests (WSG.1–4) require the v0.18 deploy.
const A = v018Addr(); // may be null until v0.18 is deployed

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
// Use merged full ABI (V7 + Extension fallback surface) for unified on-chain calls.
const v7Abi      = loadMergedAbi();

const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 160_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n;
const N = p256.CURVE.n; // secp256r1 group order
const P256_VERIFIER = "0x0000000000000000000000000000000000000100" as Address; // EIP-7212 / RIP-7696

// Deterministic P256 keypair for this test (private key fixed so reruns are reproducible).
const P256_PRIV = new Uint8Array(32).fill(0); P256_PRIV[31] = 0x42;
const P256_PUB = p256.getPublicKey(P256_PRIV, false); // 0x04 || X(32) || Y(32)
const P256_X = toHex(P256_PUB.slice(1, 33)) as Hex;
const P256_Y = toHex(P256_PUB.slice(33, 65)) as Hex;

// Fixed probe digest used by both the precompile proof and the validateUserOp tests.
const PROBE_HASH = keccak256(toHex("ws-g-p256-low-s-probe")) as Hex;

let account: Address = "0x" as Address;

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
    ["ACCEPT_GUARDIAN", 11155111n, A!.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

// Raw (r, s) over `userOpHash`; noble returns canonical low-S.
function signRS(userOpHash: Hex): { r: bigint; s: bigint } {
  const sig = p256.sign(userOpHash.slice(2), P256_PRIV, { lowS: true, prehash: false });
  return { r: sig.r, s: sig.s };
}

// Build a P256 (0x03) account signature [0x03][r(32)][s(32)] over `userOpHash`.
function buildP256Sig(userOpHash: Hex, highS: boolean): Hex {
  const { r, s } = signRS(userOpHash);
  const sFinal = highS ? N - s : s; // malleate to the high-S form (r, n-s)
  return concat(["0x03", toHex(r, { size: 32 }), toHex(sFinal, { size: 32 })]) as Hex;
}

// Directly call the secp256r1 precompile at 0x100: P256VERIFY(hash, r, s, x, y) → 1 if valid.
async function precompileVerify(hash: Hex, r: bigint, s: bigint): Promise<bigint> {
  const input = concat([
    hash, toHex(r, { size: 32 }), toHex(s, { size: 32 }), P256_X, P256_Y,
  ]);
  const res = await publicClient.call({ to: P256_VERIFIER, data: input });
  return BigInt(res.data ?? "0x0");
}

function buildUserOp(sig: Hex) {
  // callData = execute(account, 0, 0x) → value 0 → tier 0 (single-factor P256 suffices)
  const callData = encodeFunctionData({
    abi: v7Abi, functionName: "execute", args: [account, 0n, "0x"],
  });
  return {
    sender: account,
    nonce: 0n,
    initCode: "0x" as Hex,
    callData,
    accountGasLimits: ("0x" + "00".repeat(32)) as Hex,
    preVerificationGas: 0n,
    gasFees: ("0x" + "00".repeat(32)) as Hex,
    paymasterAndData: "0x" as Hex,
    signature: sig,
  };
}

// eth_call validateUserOp impersonating the EntryPoint; returns the packed validationData.
// IMPORTANT: viem's publicClient.call sets the call's msg.sender via the `account` option,
// NOT `from`. validateUserOp is onlyEntryPoint, so we must pass `account: ADDR.entryPoint`
// — using `from` leaves msg.sender = address(0) and the call reverts NotEntryPoint() (0xd663742a)
// before ever reaching the P256 path.
async function callValidate(userOp: ReturnType<typeof buildUserOp>, userOpHash: Hex): Promise<bigint> {
  const res = await publicClient.call({
    to: account,
    account: ADDR.entryPoint, // sets msg.sender = EntryPoint → passes onlyEntryPoint
    data: encodeFunctionData({
      abi: v7Abi, functionName: "validateUserOp", args: [userOp, userOpHash, 0n],
    }),
  } as any);
  return BigInt(res.data ?? "0x0");
}

// ── Precompile-malleability proof — RUNS NOW on Sepolia (no v0.18 deploy needed) ──
// Establishes that the raw secp256r1 precompile accepts BOTH (r,s) and (r, n-s). This is
// the load-bearing premise of WSG.4: since the precompile itself does NOT reject high-S,
// any rejection of a high-S sig by validateUserOp is attributable SOLELY to the contract's
// low-S guard (#78), not to the precompile.
const precompileTests: TestCase[] = [
  {
    name: "WSG.P1 secp256r1 precompile accepts canonical LOW-S (r, s) → 1",
    run: async () => {
      const { r, s } = signRS(PROBE_HASH);
      if (s > SECP256R1_N_OVER_2) throw new Error("expected low-S sample, got high-S");
      const ok = await precompileVerify(PROBE_HASH, r, s);
      if (ok !== 1n) throw new Error(`precompile rejected a valid low-S sig (got ${ok})`);
      return { notes: "precompile accepts low-S ✓" };
    },
  },
  {
    name: "WSG.P2 secp256r1 precompile ALSO accepts malleated HIGH-S (r, n-s) → 1",
    run: async () => {
      const { r, s } = signRS(PROBE_HASH);
      const sHigh = N - s;
      if (sHigh <= SECP256R1_N_OVER_2) throw new Error("expected high-S sample, got low-S");
      const ok = await precompileVerify(PROBE_HASH, r, sHigh);
      if (ok !== 1n) {
        throw new Error(
          `precompile rejected the malleated high-S sig (got ${ok}); the malleability premise ` +
          `for WSG.4 would not hold — investigate before trusting the low-S-guard attribution`,
        );
      }
      return { notes: "precompile accepts high-S too → high-S rejection by the account is the guard, not the precompile ✓" };
    },
  },
];

// ── Account-bound validateUserOp tests — require the v0.18 deploy ──
const tests: TestCase[] = [
  {
    name: "WSG.1 createAccountWithDefaults (P256 low-S test account)",
    run: async () => {
      account = (await publicClient.readContract({
        address: A!.factory, abi: factoryAbi, functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, jason.address, bob.address, DAILY_LIMIT],
      })) as Address;
      const s1 = await acceptGuardianSig(jason, annie.address, SALT, DAILY_LIMIT);
      const s2 = await acceptGuardianSig(bob,   annie.address, SALT, DAILY_LIMIT);
      const hash = await wAnnie.writeContract({
        address: A!.factory, abi: factoryAbi, functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, jason.address, s1, bob.address, s2, DAILY_LIMIT],
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `account = ${account}` };
    },
  },
  {
    name: "WSG.2 setP256Key(x, y) — install secp256r1 passkey",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: account, abi: v7Abi, functionName: "setP256Key",
        args: [P256_X, P256_Y], chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `P256 key set (x=${P256_X.slice(0, 12)}…)` };
    },
  },
  {
    name: "WSG.3 LOW-S P256 signature → validateUserOp returns 0 (valid)",
    run: async () => {
      const sig = buildP256Sig(PROBE_HASH, /*highS=*/false);
      const sLow = BigInt("0x" + sig.slice(68, 132));
      if (sLow > SECP256R1_N_OVER_2) throw new Error("expected low-S sample, got high-S");
      const vd = await callValidate(buildUserOp(sig), PROBE_HASH);
      if (vd !== 0n) throw new Error(`expected validationData 0 (valid) for low-S, got ${vd}`);
      return { notes: "canonical low-S P256 signature accepted (validationData=0) ✓" };
    },
  },
  {
    name: "WSG.4 HIGH-S P256 signature → validateUserOp returns 1 (rejected by guard) #78",
    run: async () => {
      const sig = buildP256Sig(PROBE_HASH, /*highS=*/true);
      const sHigh = BigInt("0x" + sig.slice(68, 132));
      if (sHigh <= SECP256R1_N_OVER_2) throw new Error("expected high-S sample, got low-S");
      const vd = await callValidate(buildUserOp(sig), PROBE_HASH);
      if (vd !== 1n) {
        throw new Error(
          `expected validationData 1 (SIG_VALIDATION_FAILED) for high-S, got ${vd}. ` +
          `WSG.P2 proved the precompile accepts this same (r, n-s), so a non-1 result means the ` +
          `contract low-S guard (#78) did NOT fire.`,
        );
      }
      return { notes: "malleable high-S P256 signature rejected (validationData=1) ✓ low-S guard fires (precompile accepts it per WSG.P2)" };
    },
  },
];

(async () => {
  // The precompile-malleability proof runs unconditionally (works on Sepolia today).
  await runTests(`${PHASE}-precompile`, precompileTests);

  // runTests signals failure by setting process.exitCode = 1 (it does NOT throw). If the
  // precompile proof (WSG.P1/P2) failed, surface that immediately — a non-zero exit must
  // NOT be masked by the clean skip-exit on the v0.18-not-deployed path below.
  if (process.exitCode) process.exit(process.exitCode);

  // The account-bound tests (WSG.1–4) need the v0.18 deploy.
  if (!A) { printPendingBanner(PHASE); process.exit(process.exitCode || 0); }
  await runTests(PHASE, tests);
})();
