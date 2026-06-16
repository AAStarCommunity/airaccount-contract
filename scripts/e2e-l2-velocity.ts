/**
 * L2 — session-key velocity-limit breach (#57) live on Sepolia.
 * Grant an ECDSA session with velocityLimit=1; the session key's 1st UserOp succeeds, the 2nd in
 * the same window reverts VelocityLimitExceeded (sliding-window velocity limiter).
 *
 * v0.19 update: creates a fresh V019 account each run (setValidator is set-once immutable,
 * so the old beta.2 account can't be retargeted to the V019 validator router).
 *
 * Run: pnpm tsx scripts/e2e-l2-velocity.ts
 */
import { createPublicClient, createWalletClient, http, concat, parseEther, encodeFunctionData,
  keccak256, encodePacked, type Address, type Hex } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL as string;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
// V019 factory + session key validator (created fresh each run)
const FACTORY = (process.env.AIRACCOUNT_V019_FACTORY ?? process.env.AIRACCOUNT_V018_FACTORY) as Address;
const SKV = (process.env.AIRACCOUNT_V019_SESSION_KEY_VALIDATOR ?? process.env.AIRACCOUNT_V018_SESSION_KEY_VALIDATOR) as Address;
const ROUTER = (process.env.AIRACCOUNT_V019_VALIDATOR_ROUTER ?? process.env.AIRACCOUNT_V018_VALIDATOR_ROUTER) as Address;
const CHAIN_ID = 11155111n;
const DAILY_LIMIT = parseEther("1");

const annie = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);   // account owner
const jason = privateKeyToAccount(process.env.PRIVATE_KEY_JASON as Hex);  // guardian 1
const bob = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);      // guardian 2
const sessionKey = privateKeyToAccount(generatePrivateKey());

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC), pollingInterval: 3000 });
const wOwner = createWalletClient({ account: annie, chain: robust, transport: http(RPC) });
const wJason = createWalletClient({ account: jason, chain: robust, transport: http(RPC) });

const FACTORY_ABI = [
  { name: "createAccountWithDefaults", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "owner", type: "address" }, { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" }, { name: "guardian1Sig", type: "bytes" },
      { name: "guardian2", type: "address" }, { name: "guardian2Sig", type: "bytes" },
      { name: "dailyLimit", type: "uint256" }], outputs: [{ type: "address" }] },
  { name: "getAddressWithDefaults", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" }, { name: "guardian2", type: "address" },
      { name: "dailyLimit", type: "uint256" }], outputs: [{ type: "address" }] },
] as const;

const ACCT_ABI = [
  { name: "execute", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "dest", type: "address" }, { name: "value", type: "uint256" }, { name: "func", type: "bytes" }], outputs: [] },
  { name: "setValidator", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "_validator", type: "address" }], outputs: [] },
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
  { name: "getNonce", type: "function", stateMutability: "view",
    inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }] },
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

async function guardianAcceptSig(signer: typeof jason, owner: Address, salt: bigint): Promise<Hex> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", CHAIN_ID, FACTORY, owner, salt, DAILY_LIMIT],
  ));
  return signer.signMessage({ message: { raw } });
}

async function buildOp(account: Address, nonce: bigint): Promise<any> {
  const callData = encodeFunctionData({ abi: ACCT_ABI, functionName: "execute", args: [annie.address, 0n, "0x"] });
  // verificationGasLimit=200k, callGasLimit=100k, preVerificationGas=50k → total 350k × 30gwei = 0.0105 ETH
  return { sender: account, nonce, initCode: "0x" as Hex, callData,
    accountGasLimits: pack(200000n, 100000n), preVerificationGas: 50000n,
    gasFees: pack(2_000_000_000n, 30_000_000_000n), paymasterAndData: "0x" as Hex, signature: "0x" as Hex };
}
async function signWithSession(account: Address, op: any): Promise<any> {
  const h = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getUserOpHash", args: [op] }) as Hex;
  const sig = await sessionKey.signMessage({ message: { raw: h } });
  return { ...op, signature: concat(["0x08", account, sessionKey.address, sig]) as Hex };
}

async function main() {
  console.log(`FACTORY=${FACTORY} SKV=${SKV}`);
  // 0. Create fresh V019 account (Annie owner, Jason+Bob guardians)
  const salt = BigInt(Math.floor(Date.now() / 1000));
  const s1 = await guardianAcceptSig(jason, annie.address, salt);
  const s2 = await guardianAcceptSig(bob, annie.address, salt);
  const ACCOUNT = await pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddressWithDefaults",
    args: [annie.address, salt, jason.address, bob.address, DAILY_LIMIT] }) as Address;
  const ct = await wOwner.writeContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "createAccountWithDefaults",
    args: [annie.address, salt, jason.address, s1, bob.address, s2, DAILY_LIMIT] });
  await pub.waitForTransactionReceipt({ hash: ct });
  console.log(`  created V019 account: ${ACCOUNT} (tx ${ct})`);

  // 0b. Wire validator router (set-once — must be done before any session key UserOps)
  const vt = await wOwner.writeContract({ address: ACCOUNT, abi: ACCT_ABI, functionName: "setValidator", args: [ROUTER] });
  await pub.waitForTransactionReceipt({ hash: vt });
  console.log(`  validator router set: ${ROUTER} (tx ${vt})`);

  // 1. grant session with velocityLimit=1 (from owner Annie)
  const cfg = { expiry: BigInt(Math.floor(Date.now()/1000)+86400),
    contractScope: "0x0000000000000000000000000000000000000000" as Address,
    selectorScope: "0x00000000" as Hex, revoked: false,
    velocityLimit: 1, velocityWindow: 3600, callTargets: [] as Address[], selectorAllowlist: [] as Hex[] };
  const gt = await wOwner.writeContract({ address: SKV, abi: SKV_ABI, functionName: "grantSessionDirect",
    args: [ACCOUNT, sessionKey.address, cfg] });
  await pub.waitForTransactionReceipt({ hash: gt });
  console.log(`  session granted velocityLimit=1 (tx ${gt})`);

  // 2. fund EntryPoint deposit
  const dt = await wJason.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "depositTo",
    args: [ACCOUNT], value: parseEther("0.05") });
  await pub.waitForTransactionReceipt({ hash: dt });
  console.log(`L2 velocity breach — account ${ACCOUNT}, sessionKey ${sessionKey.address}`);

  // 3. UserOp #1 — should succeed
  const n1 = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [ACCOUNT, 0n] }) as bigint;
  const op1 = await signWithSession(ACCOUNT, await buildOp(ACCOUNT, n1));
  const t1 = await wJason.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "handleOps", args: [[op1], jason.address] });
  const r1 = await pub.waitForTransactionReceipt({ hash: t1 });
  console.log(`  UserOp #1: tx ${t1} status=${r1.status}  (expect success)`);

  // 4. UserOp #2 — same window → velocity breach → revert
  const n2 = await pub.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [ACCOUNT, 0n] }) as bigint;
  const op2 = await signWithSession(ACCOUNT, await buildOp(ACCOUNT, n2));
  let reverted = false;
  try {
    const t2 = await wJason.writeContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "handleOps", args: [[op2], jason.address] });
    const r2 = await pub.waitForTransactionReceipt({ hash: t2 });
    console.log(`  UserOp #2: tx ${t2} status=${r2.status}`);
    if (r2.status !== "success") reverted = true;
  } catch { reverted = true; }

  if (r1.status === "success" && reverted) {
    console.log("\nPASS: L2 — 1st session op OK, 2nd op in window REJECTED by velocity limiter (#57).");
  } else {
    console.error(`\nFAIL: op1=${r1.status} op2-reverted=${reverted}`);
    process.exit(1);
  }
}
main().catch((e) => { console.error("Fatal:", e?.shortMessage ?? e?.message ?? e); process.exit(1); });
