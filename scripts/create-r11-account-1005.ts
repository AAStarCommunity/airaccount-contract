/**
 * create-r11-account-1005.ts — Create salt=1005 account against r11 contracts.
 *
 * Reuses r11 Factory (already deployed). Creates a fresh account with the
 * correct 3-guardian design:
 *   guardian[0] = trusted contact (g1 / Bob)
 *   guardian[1] = user device    (g2 / Jack)
 *   guardian[2] = community Safe guardian (COMMUNITY_GUARDIAN_ADDRESS)
 *
 * Usage:
 *   pnpm tsx scripts/create-r11-account-1005.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http,
  parseEther, formatEther, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const SALT      = 1005n;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const FACTORY   = process.env.AIRACCOUNT_M7_R11_FACTORY as Address;
const PK        = process.env.PRIVATE_KEY as Hex;
const G1_KEY    = process.env.PRIVATE_KEY_BOB  as Hex;
const G2_KEY    = process.env.PRIVATE_KEY_JACK as Hex;
const COMMUNITY = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL,
  process.env.SEPOLIA_RPC_URL2,
  process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

function loadABI(name: string) {
  return JSON.parse(
    readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")
  ).abi;
}

async function waitTx(
  pub: ReturnType<typeof createPublicClient>,
  hash: Hex,
  label: string
) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (r.status !== "success") throw new Error(`${label} reverted`);
  console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
  return r;
}

async function main() {
  if (!FACTORY)   { console.error("Missing AIRACCOUNT_M7_R11_FACTORY"); process.exit(1); }
  if (!COMMUNITY) { console.error("Missing COMMUNITY_GUARDIAN_ADDRESS"); process.exit(1); }
  if (!G1_KEY)    { console.error("Missing PRIVATE_KEY_BOB"); process.exit(1); }
  if (!G2_KEY)    { console.error("Missing PRIVATE_KEY_JACK"); process.exit(1); }

  const owner = privateKeyToAccount(PK);
  const g1    = privateKeyToAccount(G1_KEY);
  const g2    = privateKeyToAccount(G2_KEY);
  const fABI  = loadABI("AAStarAirAccountFactoryV7");

  const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URLS[0], { timeout: 120_000 }) });
  const wal = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URLS[0], { timeout: 120_000 }) });

  console.log("=== Create r11 account salt=1005 (3-guardian design) ===");
  console.log(`Owner:     ${owner.address}`);
  console.log(`g1 (Bob):  ${g1.address}`);
  console.log(`g2 (Jack): ${g2.address}`);
  console.log(`Community: ${COMMUNITY}`);
  console.log(`Factory:   ${FACTORY}\n`);

  // 3-guardian initConfig — matches createAccountWithDefaults production path
  const initConfig = {
    // guardian[0] = trusted contact, guardian[1] = user device, guardian[2] = community Safe guardian
    guardians:           [g1.address, g2.address, COMMUNITY] as [Address, Address, Address],
    dailyLimit:          0n,
    approvedAlgIds:      [1, 2, 3, 4, 5, 6, 7, 8],
    minDailyLimit:       0n,
    initialTokens:       [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predicted = await pub.readContract({
    address: FACTORY, abi: fABI, functionName: "getAddress",
    args: [owner.address, SALT, initConfig],
  }) as Address;
  console.log(`Predicted: ${predicted} (salt=${SALT})`);

  const code = await pub.getBytecode({ address: predicted });
  if (code && code.length > 2) {
    console.log("Already deployed — skipping createAccount");
  } else {
    let deployed = false;
    for (const rpcUrl of RPC_URLS) {
      try {
        const p = createPublicClient({ chain: sepolia, transport: http(rpcUrl, { timeout: 120_000 }) });
        const w = createWalletClient({ account: owner, chain: sepolia, transport: http(rpcUrl, { timeout: 120_000 }) });
        const h = await w.writeContract({
          address: FACTORY, abi: fABI, functionName: "createAccount",
          args: [owner.address, SALT, initConfig], gas: 1_200_000n,
        });
        await waitTx(p, h, "createAccount");
        deployed = true;
        break;
      } catch (e: any) {
        console.warn(`  createAccount failed on ${rpcUrl.slice(0, 60)}: ${e.message?.slice(0, 80)}`);
      }
    }
    if (!deployed) throw new Error("createAccount failed on all RPCs");
  }

  // Fund account
  const bal = await pub.getBalance({ address: predicted });
  console.log(`\nETH balance: ${formatEther(bal)} ETH`);
  if (bal < parseEther("0.03")) {
    const h = await wal.sendTransaction({ to: predicted, value: parseEther("0.05") });
    await waitTx(pub, h, "fund");
    console.log("Funded +0.05 ETH");
  } else {
    console.log("Sufficient ETH, skipping fund.");
  }

  // EP deposit
  const epH = await wal.writeContract({
    address: ENTRYPOINT,
    abi: [{ name: "depositTo", type: "function", stateMutability: "payable",
      inputs: [{ name: "account", type: "address" }], outputs: [] }],
    functionName: "depositTo", args: [predicted], value: parseEther("0.02"),
  });
  await waitTx(pub, epH, "depositToEntryPoint");
  console.log("EP deposit +0.02 ETH");

  console.log("\n═══════════════════════════════════════════════════════════════");
  console.log(" Done — 3-guardian account deployed");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("\nAdd to .env.sepolia:\n");
  console.log(`# r11 salt=1005 — 3-guardian account for E2E validation`);
  console.log(`AIRACCOUNT_M7_R11_ACCOUNT_1005=${predicted}`);
  console.log(`\n# Update canonical M7 account pointer to 3-guardian account:`);
  console.log(`AIRACCOUNT_M7_ACCOUNT=${predicted}`);
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
