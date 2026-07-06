/**
 * cc22-ownerauth-e2e-account.ts — Deploy a v0.27.0 e2e_account owning isValidOwnerAuth for CC-22.
 *
 * DVT (YetAnotherAA-Validator v1.9.0) gates owner authorization through the account's
 * isValidOwnerAuth(bytes32,bytes) -> 0xa0cf00cf (issue #159). CC-22 asks airaccount-contract for a
 * Sepolia account implementing it, whose owner is an EOA the DVT node test harness can sign with.
 *
 * We deploy a direct-mode account from the v0.27.0 factory with owner = Jason EOA
 * (0xb5600060… — the same key DVT already uses as its dvt1 operator), then prove on-chain:
 *   1. Positive:  ownerAuth = 0x01 || personal_sign(userOpHash) by Jason -> magic 0xa0cf00cf
 *   2. Negative:  wrong signer -> 0xffffffff
 *   3. Negative:  unknown tag  -> 0xffffffff
 *   4. Negative:  empty        -> 0xffffffff
 *
 * Delivered CC-22 testnet e2e_account (Sepolia, v0.27.0):
 *   account 0x92EA8b02D34A4D5d10f0Db9Ea894e8bC72e292e8  (owner 0xb5600060…, tx 0x086f7951…)
 *
 * ── MAINNET FOLLOW-UP (owed to CC-22 `contracts_mainnet.e2e_account`) ────────────────────────
 * After AAStarAirAccountV7 is deployed to mainnet, mint the mainnet e2e_account the SAME way and
 * post the address to Cooperation-Center CC-22 + DVT community.toml [dvt.contracts_mainnet]:
 *   1. add AIRACCOUNT_MAINNET_FACTORY=<mainnet factory> to .env.sepolia
 *   2. export TARGET_CHAIN=mainnet   (switches viem chain to mainnet + reads MAINNET_RPC_URL)
 *   3. pick the agreed mainnet owner EOA via OWNER_PK_ENV (default PRIVATE_KEY_JASON)
 *   4. pnpm tsx scripts/cc22-ownerauth-e2e-account.ts
 * Same owner-selection rationale: owner must be an EOA whose key the DVT node harness can sign with.
 *
 * Usage (testnet, default): pnpm tsx scripts/cc22-ownerauth-e2e-account.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeFunctionData, keccak256, toBytes,
  getAddress, concat, type Address, type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { sepolia, mainnet } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// Chain-parameterized so the same script mints the mainnet e2e_account owed to CC-22 (see header).
const TARGET_CHAIN = (process.env.TARGET_CHAIN ?? "sepolia").toLowerCase();
const isMainnet = TARGET_CHAIN === "mainnet";
const CHAIN = isMainnet ? mainnet : sepolia;
const EXPLORER = isMainnet ? "https://etherscan.io" : "https://sepolia.etherscan.io";

const OWNER_PK = process.env[process.env.OWNER_PK_ENV ?? "PRIVATE_KEY_JASON"] as Hex; // owner = EOA the DVT harness can sign with
// Dedicated per-chain factory vars (do NOT reuse the generic AIRACCOUNT_FACTORY — it points at an old M4 factory).
const FACTORY  = getAddress((isMainnet ? process.env.AIRACCOUNT_MAINNET_FACTORY : process.env.AIRACCOUNT_V0270_FACTORY) as string);
const RPC_URLS = (isMainnet
  ? [process.env.MAINNET_RPC_URL]
  : [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2]
).filter(Boolean) as string[];
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const MAGIC = "0xa0cf00cf";
const FAIL  = "0xffffffff";

const owner = privateKeyToAccount(OWNER_PK);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC_URLS[0], { timeout: 60_000 }) });
const wal = createWalletClient({ account: owner, chain: CHAIN, transport: http(RPC_URLS[0], { timeout: 60_000 }) });

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
  console.log(`\n=== CC-22 isValidOwnerAuth e2e_account — ${CHAIN.name} ===`);
  console.log(`Factory:  ${FACTORY}`);
  console.log(`Owner:    ${owner.address}  (must be an EOA the DVT node harness can sign with)\n`);

  const salt = 270022n; // CC-22 marker
  const predicted = getAddress(await pub.readContract({
    address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress",
    args: [owner.address, salt, EMPTY_CONFIG, ZERO32, ZERO32],
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
        args: [owner.address, salt, EMPTY_CONFIG, ZERO32, ZERO32, 0n, 0n, "0x"],
      }),
      gas: 3_000_000n, ...f,
    });
    console.log(`  TX(createAccount): ${EXPLORER}/tx/${hash}`);
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error("createAccount reverted");
    console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
  } else {
    console.log("  [reuse] account already deployed");
  }

  const userOpHash = keccak256(toBytes("cc22-ownerauth-e2e-v0.27.0"));
  console.log(`\nuserOpHash: ${userOpHash}\n`);

  // 1. Positive — owner (Jason) personal_sign
  const sigOwner = await owner.signMessage({ message: { raw: userOpHash } }); // EIP-191 personal_sign
  const authOk = concat(["0x01", sigOwner]);
  const outOk = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, authOk],
  }) as string;
  check("owner ECDSA -> magic", outOk, MAGIC);

  // 2. Negative — wrong signer
  const stranger = privateKeyToAccount(generatePrivateKey());
  const sigStranger = await stranger.signMessage({ message: { raw: userOpHash } });
  const outBad = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, concat(["0x01", sigStranger])],
  }) as string;
  check("wrong signer -> fail", outBad, FAIL);

  // 3. Negative — unknown tag
  const outTag = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, concat(["0x03", sigOwner])],
  }) as string;
  check("unknown tag -> fail", outTag, FAIL);

  // 4. Negative — empty ownerAuth
  const outEmpty = await pub.readContract({
    address: predicted, abi: OWNER_AUTH_ABI, functionName: "isValidOwnerAuth", args: [userOpHash, "0x"],
  }) as string;
  check("empty ownerAuth -> fail", outEmpty, FAIL);

  console.log(`\n--- CC-22 deliverable ---`);
  console.log(`e2e_account = ${predicted}`);
  console.log(`owner       = ${owner.address}`);
  console.log(`\n=== Result: ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => { console.error(err); process.exit(1); });
