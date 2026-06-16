/**
 * v0.19 #42 — Gnosis Safe multisig as a COMMUNITY GUARDIAN in social recovery (Sepolia, live).
 * Recovery is msg.sender-based (_guardianIndex), so a Safe whose address is in the guardian set
 * participates by calling approveRecovery via Safe.execTransaction — NO ERC-1271 needed.
 *
 * Flow: deploy 1-of-1 Safe (owner=Jason) → create AirAccount with guardians [jason, bob, SAFE] →
 *       proposeRecovery (jason EOA) → approveRecovery (SAFE via execTransaction) → 2/3 reached.
 *
 * Run: pnpm tsx scripts/e2e-v019-safe-guardian-recovery.ts
 */
import { createPublicClient, createWalletClient, http, encodeFunctionData, encodeAbiParameters,
  parseAbiParameters, getAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL as string;
const FACTORY = (process.env.AIRACCOUNT_V019_FACTORY ?? process.env.AIRACCOUNT_V018_FACTORY ?? "0x52c5190E7308Ea9B149157FF016cC99B6C6bf984") as Address;
const SAFE_FACTORY = "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67" as Address; // SafeProxyFactory 1.4.1
const SAFE_SINGLETON = "0x41675C099F32341bf84BFc5382aF534df5C7461a" as Address; // Safe 1.4.1

const annie = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex); // account owner
const jason = privateKeyToAccount(process.env.PRIVATE_KEY_JASON as Hex); // guardian[0] + Safe owner + sender
const bob = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);     // guardian[1]
const SALT = BigInt(Math.floor(Date.now() / 1000)) + 990_000n;
const NEW_OWNER = "0x000000000000000000000000000000000000bEEF" as Address;

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC) });
const wJason = createWalletClient({ account: jason, chain: robust, transport: http(RPC) });
const wAnnie = createWalletClient({ account: annie, chain: robust, transport: http(RPC) });

const SAFE_FACTORY_ABI = [{ name: "createProxyWithNonce", type: "function", stateMutability: "nonpayable",
  inputs: [{ name: "_singleton", type: "address" }, { name: "initializer", type: "bytes" }, { name: "saltNonce", type: "uint256" }],
  outputs: [{ name: "proxy", type: "address" }] }] as const;
const SAFE_ABI = [
  { name: "setup", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "_owners", type: "address[]" }, { name: "_threshold", type: "uint256" }, { name: "to", type: "address" },
    { name: "data", type: "bytes" }, { name: "fallbackHandler", type: "address" }, { name: "paymentToken", type: "address" },
    { name: "payment", type: "uint256" }, { name: "paymentReceiver", type: "address" }], outputs: [] },
  { name: "execTransaction", type: "function", stateMutability: "payable", inputs: [
    { name: "to", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" },
    { name: "operation", type: "uint8" }, { name: "safeTxGas", type: "uint256" }, { name: "baseGas", type: "uint256" },
    { name: "gasPrice", type: "uint256" }, { name: "gasToken", type: "address" }, { name: "refundReceiver", type: "address" },
    { name: "signatures", type: "bytes" }], outputs: [{ type: "bool" }] },
] as const;
const FACTORY_ABI = [
  { name: "createAccount", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "owner", type: "address" }, { name: "salt", type: "uint256" }, { name: "config", type: "tuple", components: [
      { name: "guardians", type: "address[3]" }, { name: "dailyLimit", type: "uint256" }, { name: "approvedAlgIds", type: "uint8[]" },
      { name: "minDailyLimit", type: "uint256" }, { name: "initialTokens", type: "address[]" },
      { name: "initialTokenConfigs", type: "tuple[]", components: [
        { name: "tier1Limit", type: "uint128" }, { name: "tier2Limit", type: "uint128" }, { name: "dailyLimit", type: "uint256" }]}]}],
    outputs: [{ type: "address" }] },
  { name: "getAddress", type: "function", stateMutability: "view", inputs: [
    { name: "owner", type: "address" }, { name: "salt", type: "uint256" }, { name: "config", type: "tuple", components: [
      { name: "guardians", type: "address[3]" }, { name: "dailyLimit", type: "uint256" }, { name: "approvedAlgIds", type: "uint8[]" },
      { name: "minDailyLimit", type: "uint256" }, { name: "initialTokens", type: "address[]" },
      { name: "initialTokenConfigs", type: "tuple[]", components: [
        { name: "tier1Limit", type: "uint128" }, { name: "tier2Limit", type: "uint128" }, { name: "dailyLimit", type: "uint256" }]}]}],
    outputs: [{ type: "address" }] },
] as const;
const ACCT_ABI = [
  { name: "proposeRecovery", type: "function", stateMutability: "nonpayable", inputs: [{ name: "_newOwner", type: "address" }], outputs: [] },
  { name: "approveRecovery", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "activeRecovery", type: "function", stateMutability: "view", inputs: [], outputs: [
    { name: "newOwner", type: "address" }, { name: "proposedAt", type: "uint256" }, { name: "approvalBitmap", type: "uint256" }, { name: "cancellationBitmap", type: "uint256" }] },
] as const;

async function main() {
  // 1. Deploy a 1-of-1 Safe owned by Jason
  const setupData = encodeFunctionData({ abi: SAFE_ABI, functionName: "setup",
    args: [[jason.address], 1n, "0x0000000000000000000000000000000000000000", "0x",
      "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", 0n, "0x0000000000000000000000000000000000000000"] });
  // simulate to get the deterministic proxy address (return value), then send the real deploy tx
  const sim = await pub.simulateContract({ account: jason, address: SAFE_FACTORY, abi: SAFE_FACTORY_ABI, functionName: "createProxyWithNonce", args: [SAFE_SINGLETON, setupData, SALT] });
  const safeAddr = getAddress(sim.result as Address);
  const safeDeployTx = await wJason.writeContract({ address: SAFE_FACTORY, abi: SAFE_FACTORY_ABI, functionName: "createProxyWithNonce", args: [SAFE_SINGLETON, setupData, SALT] });
  await pub.waitForTransactionReceipt({ hash: safeDeployTx });
  const safeCode = await pub.getBytecode({ address: safeAddr });
  console.log(`[1] Safe deployed (1-of-1, owner Jason): ${safeAddr} (code ${safeCode ? safeCode.length/2-1 : 0}B)  tx ${safeDeployTx}`);

  // 2. Create AirAccount with guardians [jason, bob, SAFE]
  const cfg = { guardians: [jason.address, bob.address, safeAddr] as [Address, Address, Address],
    dailyLimit: 0n, approvedAlgIds: [0x02] as number[], minDailyLimit: 0n, initialTokens: [] as Address[],
    initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[] };
  const account = await pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [annie.address, SALT, cfg] }) as Address;
  const createTx = await wAnnie.writeContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount", args: [annie.address, SALT, cfg] });
  await pub.waitForTransactionReceipt({ hash: createTx });
  console.log(`[2] AirAccount: ${account} (owner Annie, guardians [jason, bob, SAFE])  tx ${createTx}`);

  // 3. proposeRecovery by jason (guardian[0], EOA)
  const propTx = await wJason.writeContract({ address: account, abi: ACCT_ABI, functionName: "proposeRecovery", args: [NEW_OWNER] });
  await pub.waitForTransactionReceipt({ hash: propTx });
  console.log(`[3] proposeRecovery(${NEW_OWNER}) by jason (EOA guardian[0])  tx ${propTx}`);

  // 4. approveRecovery by the SAFE (guardian[2]) via execTransaction (1-of-1, jason=owner=msg.sender → pre-validated sig)
  const approveCall = encodeFunctionData({ abi: ACCT_ABI, functionName: "approveRecovery", args: [] });
  // pre-validated owner signature: r = owner(32), s = 0(32), v = 1
  const preSig = ("0x" + jason.address.slice(2).toLowerCase().padStart(64, "0") + "0".repeat(64) + "01") as Hex;
  const execTx = await wJason.writeContract({ address: safeAddr, abi: SAFE_ABI, functionName: "execTransaction",
    args: [account, 0n, approveCall, 0, 0n, 0n, 0n, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", preSig] });
  const execRcpt = await pub.waitForTransactionReceipt({ hash: execTx });
  console.log(`[4] approveRecovery by SAFE via execTransaction  tx ${execTx}  status=${execRcpt.status}`);

  // 5. verify approvalBitmap has bit0 (jason) + bit2 (safe) = 0b101 = 5
  const rec = await pub.readContract({ address: account, abi: ACCT_ABI, functionName: "activeRecovery" }) as any;
  const bitmap = rec[2] as bigint;
  console.log(`[5] activeRecovery: newOwner=${rec[0]} approvalBitmap=${bitmap} (binary ${bitmap.toString(2)})`);
  const jasonBit = (bitmap & 1n) !== 0n, safeBit = (bitmap & 4n) !== 0n;
  if (execRcpt.status === "success" && rec[0].toLowerCase() === NEW_OWNER.toLowerCase() && jasonBit && safeBit) {
    console.log("\nPASS: #42 — Gnosis Safe community guardian participated in 2-of-3 social recovery (Safe approve via execTransaction, msg.sender-based, no ERC-1271).");
  } else {
    console.error(`\nFAIL: execStatus=${execRcpt.status} newOwner=${rec[0]} jasonBit=${jasonBit} safeBit=${safeBit}`);
    process.exit(1);
  }
}
main().catch((e) => { console.error("Fatal:", e?.shortMessage ?? e?.message ?? e); process.exit(1); });
