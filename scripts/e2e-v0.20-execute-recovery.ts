// Completes the on-chain passkey-recovery E2E by sending executeRecovery once the 2-day
// RECOVERY_TIMELOCK has elapsed. executeRecovery is PERMISSIONLESS (any funded account can
// trigger it after the timelock + threshold are met), so the signer here only pays gas.
//
// Env (from .env.sepolia or process env):
//   SEPOLIA_RPC_URL, and a signer key (EXECUTE_SIGNER_KEY > PRIVATE_KEY_ANNI > PRIVATE_KEY)
//   E2E_ACCOUNT (default: the recovery test account from the propose/approve run)
//
// Usage: pnpm tsx scripts/e2e-v0.20-execute-recovery.ts
import { config } from "dotenv";
import { resolve } from "node:path";
import { readFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, getAddress, type Address, type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC = process.env.SEPOLIA_RPC_URL!;
const ACCOUNT = getAddress((process.env.E2E_ACCOUNT ?? "0x3Da6B869eFD2b07c6Ed8D83ec469902700444ECE") as Address);
const PK = (process.env.EXECUTE_SIGNER_KEY ?? process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const RECOVERY_TIMELOCK = 2n * 24n * 60n * 60n; // 2 days

const _seen = new Set<string>();
function loadAbi(name: string): any[] {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8")).abi;
}
const ABI = [...loadAbi("AAStarAirAccountV7"), ...loadAbi("AirAccountExtension")].filter((e: any) => {
  const k = `${e.type}:${e.name}:${(e.inputs || []).length}`;
  if (_seen.has(k)) return false; _seen.add(k); return true;
});

async function main() {
  if (!PK) throw new Error("no signer key (EXECUTE_SIGNER_KEY / PRIVATE_KEY_ANNI / PRIVATE_KEY)");
  const signer = privateKeyToAccount(PK.startsWith("0x") ? PK : `0x${PK}` as Hex);
  const pub = createPublicClient({ chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });
  const wal = createWalletClient({ account: signer, chain: sepolia, transport: http(RPC, { timeout: 60_000 }) });

  console.log("=== executeRecovery (complete the on-chain passkey recovery E2E) ===");
  console.log(`account: ${ACCOUNT}`);
  console.log(`signer:  ${signer.address}`);

  const [newOwner, proposedAt, approvalBitmap] = await pub.readContract({
    address: ACCOUNT, abi: ABI, functionName: "activeRecovery" }) as [Address, bigint, bigint, bigint];
  const ownerBefore = await pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "owner" }) as Address;
  const now = (await pub.getBlock()).timestamp;
  const readyAt = proposedAt + RECOVERY_TIMELOCK;
  console.log(`activeRecovery.newOwner=${newOwner} approvalBitmap=${approvalBitmap} ownerBefore=${ownerBefore}`);
  console.log(`proposedAt=${proposedAt} now=${now} readyAt=${readyAt}`);

  if (newOwner === "0x0000000000000000000000000000000000000000") {
    console.log("No active recovery — nothing to execute (already executed or cancelled)."); return;
  }
  if (now < readyAt) {
    console.log(`Timelock NOT elapsed yet — ${readyAt - now}s remaining. Aborting (re-run after readyAt).`);
    process.exit(2);
  }

  const { request } = await pub.simulateContract({ account: signer, address: ACCOUNT, abi: ABI, functionName: "executeRecovery", args: [] });
  const hash = await wal.writeContract(request);
  console.log(`  TX(executeRecovery): https://sepolia.etherscan.io/tx/${hash}`);
  const r = await pub.waitForTransactionReceipt({ hash });
  console.log(`  status=${r.status} gas=${r.gasUsed} block=${r.blockNumber}`);

  const ownerAfter = await pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "owner" }) as Address;
  console.log(`ownerAfter=${ownerAfter} (expected ${newOwner})`);
  console.log(ownerAfter.toLowerCase() === newOwner.toLowerCase() ? "✅ recovery complete" : "⚠️ owner did not change");
  console.log(`\n=== archive ===\nexecuteRecovery=${hash}\nowner: ${ownerBefore} → ${ownerAfter}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
