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
  loadAbi, runTests, type TestCase, ADDR,
} from "./common.js";
import { requireV018, SECP256R1_N_OVER_2 } from "./common-v018.js";

const PHASE = "16-ws-g-p256-low-s";
const A = requireV018(PHASE); // SKIPs (exit 0) if v0.18 not deployed.

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const v7Abi      = loadAbi("AAStarAirAccountV7");

const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 160_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n;
const N = p256.CURVE.n; // secp256r1 group order

// Deterministic P256 keypair for this test (private key fixed so reruns are reproducible).
const P256_PRIV = new Uint8Array(32).fill(0); P256_PRIV[31] = 0x42;
const P256_PUB = p256.getPublicKey(P256_PRIV, false); // 0x04 || X(32) || Y(32)
const P256_X = toHex(P256_PUB.slice(1, 33)) as Hex;
const P256_Y = toHex(P256_PUB.slice(33, 65)) as Hex;

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
    ["ACCEPT_GUARDIAN", 11155111n, A.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

// Build a PackedUserOperation (v0.7) carrying a P256 (0x03) signature over `userOpHash`.
function buildP256Sig(userOpHash: Hex, highS: boolean): Hex {
  const sig = p256.sign(userOpHash.slice(2), P256_PRIV, { lowS: true, prehash: false });
  let r = sig.r;
  let s = sig.s; // noble returns low-S
  if (highS) s = N - s; // malleate to the high-S form (r, n-s) — same validity to the precompile
  const rHex = toHex(r, { size: 32 });
  const sHex = toHex(s, { size: 32 });
  return concat(["0x03", rHex, sHex]) as Hex;
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
async function callValidate(userOp: ReturnType<typeof buildUserOp>, userOpHash: Hex): Promise<bigint> {
  const res = await publicClient.call({
    to: account,
    from: ADDR.entryPoint, // pass onlyEntryPoint gate
    data: encodeFunctionData({
      abi: v7Abi, functionName: "validateUserOp", args: [userOp, userOpHash, 0n],
    }),
  } as any);
  return BigInt(res.data ?? "0x0");
}

const tests: TestCase[] = [
  {
    name: "WSG.1 createAccountWithDefaults (P256 low-S test account)",
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
      // Fixed userOpHash so the signature is deterministic; the account verifies P256 over it.
      const userOpHash = keccak256(toHex("ws-g-p256-low-s-probe")) as Hex;
      const sig = buildP256Sig(userOpHash, /*highS=*/false);
      // sanity: s must be <= N/2
      const sLow = BigInt("0x" + sig.slice(68, 132));
      if (sLow > SECP256R1_N_OVER_2) throw new Error("expected low-S sample, got high-S");
      const vd = await callValidate(buildUserOp(sig), userOpHash);
      if (vd !== 0n) throw new Error(`expected validationData 0 (valid) for low-S, got ${vd}`);
      return { notes: "canonical low-S P256 signature accepted (validationData=0) ✓" };
    },
  },
  {
    name: "WSG.4 HIGH-S P256 signature → validateUserOp returns 1 (rejected by guard) #78",
    run: async () => {
      const userOpHash = keccak256(toHex("ws-g-p256-low-s-probe")) as Hex;
      const sig = buildP256Sig(userOpHash, /*highS=*/true);
      const sHigh = BigInt("0x" + sig.slice(68, 132));
      if (sHigh <= SECP256R1_N_OVER_2) throw new Error("expected high-S sample, got low-S");
      const vd = await callValidate(buildUserOp(sig), userOpHash);
      if (vd !== 1n) {
        throw new Error(
          `expected validationData 1 (SIG_VALIDATION_FAILED) for high-S, got ${vd}. ` +
          `The low-S guard should reject the malleable (r, n-s) form even though the ` +
          `precompile would accept it.`,
        );
      }
      return { notes: "malleable high-S P256 signature rejected (validationData=1) ✓ low-S guard fires" };
    },
  },
];

(async () => { await runTests(PHASE, tests); })();
