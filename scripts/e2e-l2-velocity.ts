/**
 * L2 — session-key velocity-limit breach (#57) live on Sepolia.
 * Grant an ECDSA session with velocityLimit=1; the session key's 1st UserOp succeeds, the 2nd in
 * the same window reverts VelocityLimitExceeded (sliding-window velocity limiter).
 *
 * Run: pnpm tsx scripts/e2e-l2-velocity.ts
 */
import { createPublicClient, createWalletClient, http, concat, parseEther, encodeFunctionData,
  type Address, type Hex } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL as string;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const ACCOUNT = "0xc1a3A9AdE4F422508d99323F9Be424F070fb1589" as Address; // Jason-owned beta.2
const SKV = "0xBB79BF812aE239443fF48323dD24860F9bFb2874" as Address;      // SessionKeyValidator
const owner = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);          // Jason
const sessionKey = privateKeyToAccount(generatePrivateKey());

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC), pollingInterval: 3000 });
const w = createWalletClient({ account: owner, chain: robust, transport: http(RPC) });

const ACCT_ABI = [
  { name: "guardApproveAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ name: "algId", type: "uint8" }], outputs: [] },
  { name: "approvedAlgorithms", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "bool" }] },
  { name: "execute", type: "function", stateMutability: "nonpayable", inputs: [{ name: "dest", type: "address" }, { name: "value", type: "uint256" }, { name: "func", type: "bytes" }], outputs: [] },
] as const;
const SKV_ABI = [{
  name: "grantSessionDirect", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "account", type: "address" }, { name: "sessionKey", type: "address" },
    { name: "cfg", type: "tuple", components: [
      { name: "expiry", type: "uint48" }, { name: "contractScope", type: "address" },
      { name: "selectorScope", type: "bytes4" }, { name: "revoked", type: "bool" },
      { name: "velocityLimit", type: "uint16" }, { name: "velocityWindow", type: "uint32" },
      { name: "callTargets", type: "address[]" }, { name: "selectorAllowlist", type: "bytes4[]" },
    ]}], outputs: [] }] as const;
const EP_ABI = [
  { name: "depositTo", type: "function", stateMutability: "payable", inputs: [{ name: "account", type: "address" }], outputs: [] },
  { name: "getNonce", type: "function", stateMutability: "view", inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }] },
  { name: "getUserOpHash", type: "function", stateMutability: "view", inputs: [{ name: "userOp", type: "tuple", components: [
    { name: "sender", type: "address" }, { name: "nonce", type: "uint256" }, { name: "initCode", type: "bytes" },
    { name: "callData", type: "bytes" }, { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
    { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" }, { name: "signature", type: "bytes" },
  ]}], outputs: [{ type: "bytes32" }] },
  { name: "handleOps", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "ops", type: "tuple[]", components: [
      { name: "sender", type: "address" }, { name: "nonce", type: "uint256" }, { name: "initCode", type: "bytes" },
      { name: "callData", type: "bytes" }, { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
      { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" }, { name: "signature", type: "bytes" },
    ]}, { name: "beneficiary", type: "address" }], outputs: [] },
] as const;

const pack = (a: bigint, b: bigint): Hex => ("0x" + a.toString(16).padStart(32, "0") + b.toString(16).padStart(32, "0")) as Hex;

async function buildOp(nonce: bigint): Promise<any> {
  const callData = encodeFunctionData({ abi: ACCT_ABI, functionName: "execute", args: [owner.address, 0n, "0x"] });
  return { sender: ACCOUNT, nonce, initCode: "0x" as Hex, callData,
    accountGasLimits: pack(500000n, 500000n), preVerificationGas: 80000n,
    gasFees: pack(2_000_000_000n, 30_000_000_000n), paymasterAndData: "0x" as Hex, signature: "0x" as Hex };
}
async function sign(op: any): Promise<any> {
  const h = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getUserOpHash", args: [op] }) as Hex;
  const sig = await sessionKey.signMessage({ message: { raw: h } });
  return { ...op, signature: concat(["0x08", ACCOUNT, sessionKey.address, sig]) as Hex };
}
async function send(op: any) {
  return w.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "handleOps", args: [[op], owner.address] });
}

async function main() {
  console.log(`L2 velocity breach — account ${ACCOUNT}, sessionKey ${sessionKey.address}`);
  // 1. approve session algId 0x08 if needed
  const ok = await pub.readContract({ address: ACCOUNT, abi: ACCT_ABI, functionName: "approvedAlgorithms", args: [0x08] }) as boolean;
  if (!ok) { const t = await w.writeContract({ address: ACCOUNT, abi: ACCT_ABI, functionName: "guardApproveAlgorithm", args: [0x08] }); await pub.waitForTransactionReceipt({ hash: t }); console.log("  approved algId 0x08"); }
  // 2. grant session with velocityLimit=1
  const cfg = { expiry: BigInt(Math.floor(Date.now()/1000)+86400), contractScope: "0x0000000000000000000000000000000000000000" as Address,
    selectorScope: "0x00000000" as Hex, revoked: false, velocityLimit: 1, velocityWindow: 3600, callTargets: [] as Address[], selectorAllowlist: [] as Hex[] };
  const gt = await w.writeContract({ address: SKV, abi: SKV_ABI, functionName: "grantSessionDirect", args: [ACCOUNT, sessionKey.address, cfg] });
  await pub.waitForTransactionReceipt({ hash: gt });
  console.log(`  session granted velocityLimit=1 (tx ${gt})`);
  // 3. fund EntryPoint deposit
  const dt = await w.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "depositTo", args: [ACCOUNT], value: parseEther("0.02") });
  await pub.waitForTransactionReceipt({ hash: dt });

  // 4. UserOp #1 — should succeed
  const n1 = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [ACCOUNT, 0n] }) as bigint;
  const op1 = await sign(await buildOp(n1));
  const t1 = await send(op1); const r1 = await pub.waitForTransactionReceipt({ hash: t1 });
  console.log(`  UserOp #1: tx ${t1} status=${r1.status}  (expect success)`);

  // 5. UserOp #2 — same window → velocity breach → revert
  const n2 = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [ACCOUNT, 0n] }) as bigint;
  const op2 = await sign(await buildOp(n2));
  let reverted = false;
  try { const t2 = await send(op2); const r2 = await pub.waitForTransactionReceipt({ hash: t2 }); console.log(`  UserOp #2: tx ${t2} status=${r2.status}`); if (r2.status !== "success") reverted = true; }
  catch { reverted = true; }

  if (r1.status === "success" && reverted) console.log("\nPASS: L2 — 1st session op OK, 2nd op in window REJECTED by velocity limiter (#57).");
  else { console.error(`\nFAIL: op1=${r1.status} op2-reverted=${reverted}`); process.exit(1); }
}
main().catch((e) => { console.error("Fatal:", e?.shortMessage ?? e?.message ?? e); process.exit(1); });
