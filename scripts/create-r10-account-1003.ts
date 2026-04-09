/**
 * Create fresh r10 account with salt=1003 for clean E2E testing.
 * Usage: pnpm tsx scripts/create-r10-account-1003.ts
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

const SALT    = 1003n;
const FACTORY = process.env.AIRACCOUNT_M7_FACTORY as Address;
const PK      = process.env.PRIVATE_KEY as Hex;
const G1_KEY  = process.env.PRIVATE_KEY_BOB as Hex;
const G2_KEY  = process.env.PRIVATE_KEY_JACK as Hex;
const RPC     = process.env.SEPOLIA_RPC_URL!;

const owner = privateKeyToAccount(PK);
const g1    = privateKeyToAccount(G1_KEY);
const g2    = privateKeyToAccount(G2_KEY);
const pub   = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 120_000 }) });
const wal   = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC, { timeout: 120_000 }) });
const fABI  = JSON.parse(readFileSync(resolve(import.meta.dirname, "../out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json"), "utf-8")).abi;

async function main() {
  const initConfig = {
    guardians:          [g1.address, g2.address, "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
    dailyLimit:         0n,
    approvedAlgIds:     [1, 2, 3, 4, 5, 6, 7, 8],
    minDailyLimit:      0n,
    initialTokens:      [] as Address[],
    initialTokenConfigs: [] as { token: Address; dailyLimit: bigint; tier1Limit: bigint; tier2Limit: bigint }[],
  };

  const predicted = await pub.readContract({
    address: FACTORY, abi: fABI, functionName: "getAddress",
    args: [owner.address, SALT, initConfig],
  }) as Address;
  console.log(`Factory:   ${FACTORY}`);
  console.log(`Predicted: ${predicted} (salt=${SALT})`);

  const code = await pub.getBytecode({ address: predicted });
  if (code && code.length > 2) {
    console.log("Already deployed — skipping createAccount");
  } else {
    const h = await wal.writeContract({
      address: FACTORY, abi: fABI, functionName: "createAccount",
      args: [owner.address, SALT, initConfig], gas: 1_200_000n,
    });
    const r = await pub.waitForTransactionReceipt({ hash: h, timeout: 300_000 });
    if (r.status !== "success") throw new Error("createAccount reverted");
    console.log(`Deployed! Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
  }

  const bal = await pub.getBalance({ address: predicted });
  console.log(`Balance: ${formatEther(bal)} ETH`);
  if (bal < parseEther("0.03")) {
    const h = await wal.sendTransaction({ to: predicted, value: parseEther("0.05") });
    await pub.waitForTransactionReceipt({ hash: h, timeout: 180_000 });
    console.log("Funded +0.05 ETH");
  }

  const epH = await wal.writeContract({
    address: "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address,
    abi: [{ name: "depositTo", type: "function", stateMutability: "payable",
      inputs: [{ name: "account", type: "address" }], outputs: [] }],
    functionName: "depositTo", args: [predicted], value: parseEther("0.02"),
  });
  await pub.waitForTransactionReceipt({ hash: epH, timeout: 180_000 });
  console.log("EP deposit +0.02 ETH");

  console.log(`\nAdd to .env.sepolia:`);
  console.log(`AIRACCOUNT_M7_ACCOUNT=${predicted}`);
  console.log(`AIRACCOUNT_M7_R10_ACCOUNT_1003=${predicted}`);
}

main().catch(e => { console.error(e.message); process.exit(1); });
