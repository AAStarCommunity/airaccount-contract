// On-chain E2E: real passkey (P-256/WebAuthn) social recovery against the v0.20 Sepolia deployment.
//
// Sepolia HAS the EIP-7212 P-256 precompile (0x100 returns 1 for a valid sig), so the contract's
// on-chain P-256 verification works for real. This script:
//   1. createAccount via the v0.20 factory with TWO P-256 (passkey) guardians,
//   2. proposeRecoveryWithSig — passkey#0 opens a recovery (REAL WebAuthn assertion, verified
//      on-chain by the EIP-7212 precompile),
//   3. approveRecoveryWithSig — passkey#1 approves (2-of-2),
//   4. executeRecovery — attempted; EXPECTED to revert (RECOVERY_TIMELOCK = 2 days not elapsed).
//
// Every P-256 signature is a genuine ES256 WebAuthn assertion from test/webauthn/gen_p256_assertion.mjs.
// Usage: pnpm tsx scripts/e2e-v0.20-onchain-p256-recovery.ts
import { config } from "dotenv";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
  decodeAbiParameters, parseAbiParameters, getAddress, type Address, type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL!;
const FACTORY = getAddress(process.env.AIRACCOUNT_V020_FACTORY as Address);
const PK = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const deployer = privateKeyToAccount(PK.startsWith("0x") ? PK : `0x${PK}` as Hex);

// Two fixed test passkeys (same as test/webauthn/gen_p256_assertion.mjs key 0 and key 1).
const PK0_X = "0xe8e47200eb693978a384a1d2d4baaca209c91a2fefa004e818ae9a734bf7287c" as Hex;
const PK0_Y = "0x6e9808d701ac9a2fcad8ede6374ed3dc8187eaade2f0ae3a43a0232441df32d1" as Hex;
const PK1_X = "0x62810e5e1c845ca988f1906dc8dbbe9e060ceb8552076fcbc36dc8843950c9e5" as Hex;
const PK1_Y = "0x3751a3348045d04907920d750d5d200a1d35a7a8f11f325f7e283eaaf86e616b" as Hex;
const SIG_VERSION = 4;
const NEW_OWNER = "0x1111111111111111111111111111111111111111" as Address;
const SALT = 0x2026_06_20n;

const ZERO = "0x0000000000000000000000000000000000000000" as Address;
const Z32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex;

function loadAbi(name: string): any[] {
  const p = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  return JSON.parse(readFileSync(p, "utf-8")).abi;
}
const FACTORY_ABI = loadAbi("AAStarAirAccountFactoryV7");
// Account calls span V7 (base: activeRecovery/getRecoveryNonce/executeRecovery) and the
// fallback-routed Extension (proposeRecoveryWithSig/approveRecoveryWithSig/getGuardianP256Key).
// Merge both ABIs (dedupe by type+name+arity) so viem can encode any of them against the account.
const _seen = new Set<string>();
const FULL_ABI = [...loadAbi("AAStarAirAccountV7"), ...loadAbi("AirAccountExtension")].filter((e: any) => {
  const k = `${e.type}:${e.name}:${(e.inputs || []).length}`;
  if (_seen.has(k)) return false; _seen.add(k); return true;
});

const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });
const wal = createWalletClient({ account: deployer, chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });

// InitConfig tuple shape for viem encoding.
const INIT_CONFIG = {
  guardians: [ZERO, ZERO, ZERO] as [Address, Address, Address],
  guardianP256X: [PK0_X, PK1_X, Z32] as [Hex, Hex, Hex],
  guardianP256Y: [PK0_Y, PK1_Y, Z32] as [Hex, Hex, Hex],
  dailyLimit: 0n,
  approvedAlgIds: [] as number[],
  minDailyLimit: 0n,
  initialTokens: [] as Address[],
  initialTokenConfigs: [] as unknown[],
};

const CHAIN_ID = BigInt(sepolia.id);

/** Reproduce the contract's P-256 guardian challenge for a given op. */
function challenge(account: Address, opLabel: string, opData: Hex): Hex {
  return keccak256(encodeAbiParameters(
    parseAbiParameters("uint8, uint256, address, string, string, bytes"),
    [SIG_VERSION, CHAIN_ID, account, "P256_GUARDIAN", opLabel, opData],
  ));
}

/** FFI the Node authenticator and return the contract sig blob abi.encode(ad, pre, suf, r, s). */
function realSig(ch: Hex, keyIdx: number): Hex {
  const out = execFileSync("node", [
    resolve(import.meta.dirname, "../test/webauthn/gen_p256_assertion.mjs"), ch, "05", String(keyIdx),
  ]).toString().trim() as Hex;
  const [ad, pre, suf, r, s] = decodeAbiParameters(
    parseAbiParameters("bytes, bytes, bytes, bytes32, bytes32, bytes32, bytes32"), out,
  );
  return encodeAbiParameters(
    parseAbiParameters("bytes, bytes, bytes, bytes32, bytes32"), [ad, pre, suf, r, s],
  );
}

async function send(label: string, to: Address, abi: any[], fn: string, args: unknown[]): Promise<Hex> {
  const { request } = await pub.simulateContract({ account: deployer, address: to, abi, functionName: fn, args });
  const hash = await wal.writeContract(request);
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const r = await pub.waitForTransactionReceipt({ hash });
  console.log(`  status=${r.status} gas=${r.gasUsed} block=${r.blockNumber}`);
  if (r.status !== "success") throw new Error(`${label} reverted`);
  return hash;
}

async function main() {
  console.log("=== v0.20 on-chain P-256 recovery E2E (Sepolia) ===");
  console.log(`Deployer/relayer: ${deployer.address}`);
  console.log(`Factory:          ${FACTORY}`);
  const bal = await pub.getBalance({ address: deployer.address });
  console.log(`Balance:          ${bal} wei\n`);

  // 0. Sanity: confirm the EIP-7212 precompile is live on this chain.
  const probe = await pub.call({ to: "0x0000000000000000000000000000000000000100" as Address,
    data: ("0x" + "33".repeat(160)) as Hex }).catch(() => ({ data: "0x" as Hex }));
  console.log(`EIP-7212 precompile present: ${probe.data && probe.data !== "0x" ? "yes" : "unknown (will fail if absent)"}\n`);

  // 1. Predict + create the account with 2 passkey guardians.
  const account = await pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress",
    args: [deployer.address, SALT, INIT_CONFIG] }) as Address;
  console.log(`Predicted account: ${account}`);
  const code = await pub.getBytecode({ address: account });
  const txs: Record<string, Hex> = {};
  if (!code || code === "0x") {
    txs.createAccount = await send("createAccount", FACTORY, FACTORY_ABI, "createAccount",
      [deployer.address, SALT, INIT_CONFIG]);
  } else {
    console.log("  (account already deployed — reusing)");
  }

  // confirm passkey guardians registered
  const [g0x] = await pub.readContract({ address: account, abi: FULL_ABI, functionName: "getGuardianP256Key", args: [0] }) as [Hex, Hex];
  console.log(`  guardian[0] P-256 x: ${g0x} (expect ${PK0_X})\n`);

  const nonce = await pub.readContract({ address: account, abi: FULL_ABI, functionName: "getRecoveryNonce" }) as bigint;
  const opData = encodeAbiParameters(parseAbiParameters("uint256, address"), [nonce, NEW_OWNER]);

  // 2. passkey#0 proposes recovery — REAL WebAuthn assertion verified on-chain via EIP-7212.
  console.log("[propose] passkey#0 proposeRecoveryWithSig (real assertion, on-chain P-256 verify)...");
  const proposeSig = realSig(challenge(account, "PROPOSE_RECOVERY", opData), 0);
  txs.propose = await send("proposeRecoveryWithSig", account, FULL_ABI, "proposeRecoveryWithSig", [NEW_OWNER, 0, proposeSig]);
  const pending = await pub.readContract({ address: account, abi: FULL_ABI, functionName: "activeRecovery" }) as any[];
  console.log(`  activeRecovery.newOwner = ${pending[0]} (expect ${NEW_OWNER})\n`);

  // 3. passkey#1 approves — 2-of-2.
  console.log("[approve] passkey#1 approveRecoveryWithSig...");
  const approveSig = realSig(challenge(account, "APPROVE_RECOVERY", opData), 1);
  txs.approve = await send("approveRecoveryWithSig", account, FULL_ABI, "approveRecoveryWithSig", [1, approveSig]);
  console.log("  2-of-2 reached.\n");

  // 4. executeRecovery — EXPECTED to revert (2-day timelock not elapsed).
  console.log("[execute] executeRecovery (EXPECTED revert: RECOVERY_TIMELOCK = 2 days)...");
  try {
    await pub.simulateContract({ account: deployer, address: account, abi: FULL_ABI, functionName: "executeRecovery", args: [] });
    console.log("  WARNING: execute did NOT revert — unexpected.");
  } catch (e: any) {
    console.log(`  reverted as expected: ${String(e.shortMessage ?? e.message).split("\n")[0]}`);
  }

  console.log("\n=== E2E tx summary (archive) ===");
  console.log(`account=${account}`);
  for (const [k, v] of Object.entries(txs)) console.log(`${k}=${v}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
