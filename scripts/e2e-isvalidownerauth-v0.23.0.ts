/**
 * e2e-isvalidownerauth-v0.23.0.ts — On-chain E2E for isValidOwnerAuth (issue #159) on Sepolia.
 *
 * Proves the fallback-routed view works end-to-end against the deployed v0.23.0 factory/impl:
 *   1. Deploy (or reuse) a direct-mode account (owner = deployer, no passkey).
 *   2. Positive: ownerAuth = 0x01 || personal_sign(userOpHash) by owner -> magic 0xa0cf00cf.
 *   3. Negative (wrong signer): 0x01 || personal_sign by a throwaway key    -> 0xffffffff.
 *   4. Negative (unknown tag): 0x03 || ...                                   -> 0xffffffff.
 *   5. Negative (empty):       0x                                            -> 0xffffffff.
 *
 * The WebAuthn branch (tag 0x02) is covered by 17 unit tests + fail-closed fuzz; it will be
 * exercised on-chain with a real device passkey in the three-repo SDK integration E2E (#261).
 *
 * Usage: pnpm tsx scripts/e2e-isvalidownerauth-v0.23.0.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeFunctionData, keccak256, toBytes,
  hashMessage, getAddress, concat, type Address, type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const FACTORY     = getAddress(process.env.AIRACCOUNT_V0230_FACTORY as string);
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2].filter(Boolean) as string[];
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const MAGIC = "0xa0cf00cf";
const FAIL  = "0xffffffff";

const deployer = privateKeyToAccount(PRIVATE_KEY);
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URLS[0], { timeout: 60_000 }) });
const wal = createWalletClient({ account: deployer, chain: sepolia, transport: http(RPC_URLS[0], { timeout: 60_000 }) });

function loadAbi(name: string) {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const FACTORY_ABI = loadAbi("AAStarAirAccountFactoryV7");
const OWNER_AUTH_ABI = [{
  name: "isValidOwnerAuth", type: "function", stateMutability: "view",
  inputs: [{ type: "bytes32" }, { type: "bytes" }], outputs: [{ type: "bytes4" }],
}] as const;

const EMPTY_CONFIG = {
  guardians:           [ "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000" ] as const,
  guardianP256X:       [ "0x" + "0".repeat(64), "0x" + "0".repeat(64), "0x" + "0".repeat(64) ] as const,
  guardianP256Y:       [ "0x" + "0".repeat(64), "0x" + "0".repeat(64), "0x" + "0".repeat(64) ] as const,
  dailyLimit:          0n,
  approvedAlgIds:      [] as number[],
  minDailyLimit:       0n,
  initialTokens:       [] as Address[],
  initialTokenConfigs: [] as unknown[],
};
const ZERO32 = ("0x" + "0".repeat(64)) as Hex;

async function fees() {
  const block = await pub.getBlock();
  const base  = block.baseFeePerGas ?? 10_000_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try { tip = await pub.estimateMaxPriorityFeePerGas(); } catch { /**/ }
  const priority = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}

let pass = 0, fail = 0;
function check(name: string, got: string, want: string) {
  const ok = got.toLowerCase() === want.toLowerCase();
  console.log(`  ${ok ? "✅" : "❌"} ${name}: got ${got} (want ${want})`);
  ok ? pass++ : fail++;
}

async function main() {
  console.log(`\n=== isValidOwnerAuth E2E — v0.23.0 Sepolia ===`);
  console.log(`Factory:  ${FACTORY}`);
  console.log(`Owner:    ${deployer.address}\n`);

  const salt = 230001n;
  const predicted = getAddress(await pub.readContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress",
    args: [deployer.address, salt, EMPTY_CONFIG, ZERO32, ZERO32],
  }) as string);
  console.log(`Account (salt=${salt}): ${predicted}`);

  const code = await pub.getBytecode({ address: predicted });
  if (!code || code === "0x") {
    console.log("Deploying account (direct mode, msg.sender = owner)...");
    const f = await fees();
    const hash = await wal.sendTransaction({
      to: FACTORY,
      data: encodeFunctionData({
        abi: FACTORY_ABI, functionName: "createAccount",
        args: [deployer.address, salt, EMPTY_CONFIG, ZERO32, ZERO32, 0n, 0n, "0x"],
      }),
      gas: 3_000_000n, ...f,
    });
    console.log(`  TX(createAccount): https://sepolia.etherscan.io/tx/${hash}`);
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error("createAccount reverted");
    console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
  } else {
    console.log("  [reuse] account already deployed");
  }

  const userOpHash = keccak256(toBytes("e2e-isvalidownerauth-v0.23.0"));
  console.log(`\nuserOpHash: ${userOpHash}\n`);

  // 1. Positive — owner personal_sign
  const sigOwner = await deployer.signMessage({ message: { raw: userOpHash } }); // EIP-191 personal_sign
  const authOk = concat(["0x01", sigOwner]);
  const outOk = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, authOk],
  }) as string;
  check("owner ECDSA -> magic", outOk, MAGIC);

  // 2. Negative — wrong signer
  const stranger = privateKeyToAccount(generatePrivateKey());
  const sigStranger = await stranger.signMessage({ message: { raw: userOpHash } });
  const authBad = concat(["0x01", sigStranger]);
  const outBad = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, authBad],
  }) as string;
  check("wrong signer -> fail", outBad, FAIL);

  // 3. Negative — unknown tag
  const authTag = concat(["0x03", sigOwner]);
  const outTag = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, authTag],
  }) as string;
  check("unknown tag -> fail", outTag, FAIL);

  // 4. Negative — empty ownerAuth
  const outEmpty = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, "0x"],
  }) as string;
  check("empty ownerAuth -> fail", outEmpty, FAIL);

  // Sanity: the reference EIP-191 hash matches viem's hashMessage (documents the prefix convention).
  console.log(`\n  (ref) hashMessage(userOpHash) = ${hashMessage({ raw: userOpHash })}`);

  console.log(`\n=== Result: ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => { console.error(err); process.exit(1); });
