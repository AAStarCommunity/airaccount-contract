/**
 * e2e-v0.28.0-bundler.ts — REAL on-chain UserOp E2E for v0.28.0 (CRITICAL-1) via Pimlico bundler.
 *
 * Proves, through the actual ERC-4337 validateUserOp→execute path (not just view checks):
 *   B1  createAccountWithDefaults (guard-enabled, dailyLimit>0) on the v0.28.0 factory
 *   B2  fund account + addDeposit to EntryPoint
 *   B3  NO-REGRESSION: self-paying UserOp with EXPLICIT 0x02 ECDSA sig → included on-chain ✓
 *   B4  CRITICAL-1: the SAME UserOp with a RAW 65-byte (no-prefix) owner ECDSA sig → bundler REJECTS.
 *       On v0.24.0 the raw-65 M1 fallback accepted this; v0.28.0 removed it, so validateUserOp returns
 *       SIG_VALIDATION_FAILED and the bundler drops the op. This is the on-chain proof (via the real
 *       bundler simulation) that the raw-65 tier-desync surface is closed.
 *
 * Signature: EXPLICIT [0x02][r][s][v] = 66 bytes (v0.28.0 requires it; raw-65 rejected).
 * Uses PRIVATE_KEY_ANNI (owner), PRIVATE_KEY_JASON + PRIVATE_KEY_BOB (guardians), Pimlico bundler.
 *
 * Run: pnpm tsx scripts/e2e-v0.28.0-bundler.ts
 */

import {
  createPublicClient, createWalletClient, http, keccak256, encodePacked, toHex, concat,
  parseEther, formatEther, encodeFunctionData, toFunctionSelector, getAddress,
  type Address, type Hash, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL!;
const PIMLICO_URL = process.env.PIMLICO_BUNDLER_URL ?? "";
const ENTRY_POINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const FACTORY = getAddress(process.env.AIRACCOUNT_V0280_FACTORY!);
const SALT = BigInt(Math.floor(Date.now() / 1000)) + 25_000n;
const DAILY_LIMIT = parseEther("0.02"); // guard active — the exact bundler case

const annie = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const jason = privateKeyToAccount(process.env.PRIVATE_KEY_JASON as Hex);
const bob   = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);

const pub = createPublicClient({ chain: sepolia, transport: http(RPC) });
const wal = createWalletClient({ account: annie, chain: sepolia, transport: http(RPC) });

function loadAbi(name: string): any[] {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");

const entryPointAbi = [
  { type: "function", name: "getNonce", inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "getUserOpHash", inputs: [{ name: "userOp", type: "tuple", components: [
    { name: "sender", type: "address" }, { name: "nonce", type: "uint256" }, { name: "initCode", type: "bytes" },
    { name: "callData", type: "bytes" }, { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
    { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" }, { name: "signature", type: "bytes" },
  ]}], outputs: [{ type: "bytes32" }], stateMutability: "view" },
] as const;

const EXECUTE_USER_OP_SELECTOR = toFunctionSelector(
  "executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)",
);
const wrapForBundler = (inner: Hex): Hex => concat([EXECUTE_USER_OP_SELECTOR, inner]);
const pack128 = (hi: bigint, lo: bigint): Hex => toHex((hi << 128n) | (lo & ((1n << 128n) - 1n)), { size: 32 });

async function guardianAcceptSig(signer: typeof jason, owner: Address, salt: bigint, dailyLimit: bigint): Promise<Hex> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", 11155111n, FACTORY, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}
async function bundlerRpc(method: string, params: unknown[]): Promise<any> {
  const resp = await fetch(PIMLICO_URL, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const data = await resp.json() as { result?: any; error?: { message: string; code: number } };
  if (data.error) throw new Error(`${data.error.message} (code=${data.error.code})`);
  return data.result;
}
async function waitTx(hash: Hash) {
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (r.status !== "success") throw new Error(`tx ${hash} reverted`);
  return r;
}
// EXPLICIT 0x02 ECDSA sig (66 bytes) over EIP-191(userOpHash) — v0.28.0 requires the prefix.
async function sign0x02(userOpHash: Hex): Promise<Hex> {
  const raw65 = await annie.signMessage({ message: { raw: userOpHash } });
  return concat(["0x02", raw65]);
}

const VGL = 200_000n, CGL = 120_000n, PVG = 60_000n;
let pass = 0, fail = 0;
const ok = (m: string) => { console.log(`  [PASS] ${m}`); pass++; };
const bad = (m: string) => { console.log(`  [FAIL] ${m}`); fail++; };

async function buildAndSubmit(account: Address, sign: (h: Hex) => Promise<Hex>) {
  const nonce = await pub.readContract({ address: ENTRY_POINT, abi: entryPointAbi, functionName: "getNonce", args: [account, 0n] }) as bigint;
  const inner = encodeFunctionData({ abi: baseAbi, functionName: "execute", args: [account, 0n, "0x"] }) as Hex;
  const callData = wrapForBundler(inner);
  const gp = await bundlerRpc("pimlico_getUserOperationGasPrice", []) as { standard: { maxFeePerGas: string; maxPriorityFeePerGas: string } };
  const mfg = BigInt(gp.standard.maxFeePerGas), mpfg = BigInt(gp.standard.maxPriorityFeePerGas);
  const est = await bundlerRpc("eth_estimateUserOperationGas", [{
    sender: account, nonce: toHex(nonce), callData, callGasLimit: toHex(CGL), verificationGasLimit: toHex(VGL),
    preVerificationGas: toHex(PVG), maxFeePerGas: toHex(mfg), maxPriorityFeePerGas: toHex(mpfg), signature: "0x" + "aa".repeat(65),
  }, ENTRY_POINT]) as { callGasLimit: string; verificationGasLimit: string; preVerificationGas: string };
  const cgl = BigInt(est.callGasLimit), vgl = BigInt(est.verificationGasLimit), pvg = BigInt(est.preVerificationGas);
  const userOpHash = await pub.readContract({ address: ENTRY_POINT, abi: entryPointAbi, functionName: "getUserOpHash", args: [{
    sender: account, nonce, initCode: "0x", callData, accountGasLimits: pack128(vgl, cgl), preVerificationGas: pvg,
    gasFees: pack128(mpfg, mfg), paymasterAndData: "0x", signature: "0x",
  }] }) as Hex;
  const signature = await sign(userOpHash);
  const userOpId = await bundlerRpc("eth_sendUserOperation", [{
    sender: account, nonce: toHex(nonce), callData, callGasLimit: toHex(cgl), verificationGasLimit: toHex(vgl),
    preVerificationGas: toHex(pvg), maxFeePerGas: toHex(mfg), maxPriorityFeePerGas: toHex(mpfg), signature,
  }, ENTRY_POINT]) as Hex;
  return userOpId;
}

async function main() {
  console.log(`\n=== v0.28.0 REAL UserOp E2E (Pimlico) — factory ${FACTORY} ===\n`);
  if (!PIMLICO_URL) { console.log("PIMLICO_BUNDLER_URL not set — cannot run."); process.exit(1); }
  try { await bundlerRpc("eth_chainId", []); } catch (e: any) { console.log("Pimlico unavailable:", e.message); process.exit(1); }

  // B1 — create guard-enabled account
  console.log("[B1] createAccountWithDefaults (guard-enabled)...");
  const account = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "getAddressWithDefaults",
    args: [annie.address, SALT, jason.address, bob.address, DAILY_LIMIT] }) as Address;
  const s1 = await guardianAcceptSig(jason, annie.address, SALT, DAILY_LIMIT);
  const s2 = await guardianAcceptSig(bob, annie.address, SALT, DAILY_LIMIT);
  const h = await wal.writeContract({ address: FACTORY, abi: factoryAbi, functionName: "createAccountWithDefaults",
    args: [annie.address, SALT, jason.address, s1, bob.address, s2, DAILY_LIMIT], chain: null, account: annie });
  await waitTx(h);
  const ecdsaOk = await pub.readContract({ address: account, abi: baseAbi, functionName: "approvedAlgorithms", args: [0x02] }) as boolean;
  if (ecdsaOk) ok(`account ${account} created, 0x02 whitelisted ✓`); else bad("0x02 not whitelisted");

  // B2 — fund + deposit
  console.log("[B2] fund 0.03 ETH + addDeposit 0.03 ETH...");
  await waitTx(await wal.sendTransaction({ to: account, value: parseEther("0.03"), chain: null, account: annie }));
  await waitTx(await wal.writeContract({ address: account, abi: baseAbi, functionName: "addDeposit", value: parseEther("0.03"), chain: null, account: annie }));
  const dep = await pub.readContract({ address: account, abi: baseAbi, functionName: "getDeposit" }) as bigint;
  ok(`deposited ${formatEther(dep)} ETH to EntryPoint ✓`);

  // B3 — NO-REGRESSION: explicit 0x02 UserOp is included on-chain
  console.log("[B3] NO-REGRESSION: self-paying UserOp with explicit 0x02 sig...");
  try {
    const id = await buildAndSubmit(account, sign0x02);
    let rec: any = null;
    for (let i = 0; i < 45; i++) { await new Promise(r => setTimeout(r, 2000)); try { rec = await bundlerRpc("eth_getUserOperationReceipt", [id]); if (rec) break; } catch {} }
    if (rec?.receipt?.transactionHash) ok(`0x02 UserOp included: ${rec.receipt.transactionHash.slice(0, 18)}… ✓`);
    else bad(`0x02 UserOp not included in time (id ${id.slice(0, 14)}…)`);
  } catch (e: any) { bad(`0x02 UserOp rejected (regression!): ${e.message?.slice(0, 90)}`); }

  // B4 — CRITICAL-1: raw 65-byte (no-prefix) sig must be REJECTED by the bundler for a SIGNATURE/
  // VALIDATION reason (NOT an unrelated gas/nonce/funds error). Combined with B3 (the SAME op with a
  // 0x02 prefix succeeded), the only variable is the sig format — so a validation-phase rejection here
  // proves the raw-65 fallback is gone (not a vacuous catch-all pass).
  //
  // Two valid rejection mechanisms (both are CRITICAL-1 proofs — the raw-65 sig is what fails):
  //   • AA24 / SIG_VALIDATION_FAILED — validateUserOp returned 1 (soft signature failure), OR
  //   • AA23 reverted — the raw-65's FIRST byte (a random ECDSA r-byte, no 0x02 prefix) is read as the
  //     algId; whichever validator it routes to (e.g. weighted 0x07 → WeightConfigNotInitialized) reverts
  //     during validation. This is nondeterministic per userOpHash, so a run may land on either code.
  // ONLY AA21 (funds), AA25 (nonce), or a gas-estimation error would be an INVALID (non-signature) reason.
  console.log("[B4] CRITICAL-1: same UserOp with RAW 65-byte sig → must be REJECTED (AA23/AA24 validation)...");
  try {
    await buildAndSubmit(account, (uoh) => annie.signMessage({ message: { raw: uoh } })); // raw 65, no 0x02
    bad("raw-65 UserOp was ACCEPTED — CRITICAL-1 fallback still present!");
  } catch (e: any) {
    const msg = String(e.message ?? "");
    const invalidReason = /AA21|AA25|didn't pay|nonce|prefund|out of gas|preVerificationGas/i.test(msg);
    const validationReject = /AA24|AA23|signature error|SIG_VALIDATION|validateUserOp|reverted/i.test(msg);
    if (validationReject && !invalidReason)
      ok(`raw-65 rejected in VALIDATION (AA23/AA24) ✓ — raw-65 fallback removed (${msg.slice(0, 70)})`);
    else
      bad(`raw-65 rejected but for the WRONG reason (not a signature/validation failure): ${msg.slice(0, 90)}`);
  }

  console.log(`\n=== Bundler E2E: ${pass} passed, ${fail} failed ===`);
  console.log(`Account: https://sepolia.etherscan.io/address/${account}`);
  if (fail > 0) { console.error("FAILED"); process.exit(1); }
  console.log("All REAL UserOp checks PASSED — v0.28.0 verified end-to-end on-chain.");
}
main().catch((e) => { console.error(e); process.exit(1); });
