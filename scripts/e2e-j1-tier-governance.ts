/**
 * J1 — modifyTierLimitsWithGuardians (guardian-gated tier-limit change) live on Sepolia.
 * Uses the tiered DVT account (owner Jason, guardians Anni/Bob/Charlie, tier limits initialized).
 *
 * Run: pnpm tsx scripts/e2e-j1-tier-governance.ts
 */
import { createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
  parseAbiParameters, encodePacked, parseEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = process.env.SEPOLIA_RPC_URL as string;
const ACCOUNT = "0x45Dfe3D5938fDf5a8D30641C3FDA9c9fb1F31ba9" as Address; // tiered DVT account
const GUARDIAN_SIG_VERSION = 4;
const CHAIN_ID = 11155111n;

const owner = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);     // Jason
const anni = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI as Hex);
const bob = privateKeyToAccount(process.env.PRIVATE_KEY_BOB as Hex);

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
const wOwner = createWalletClient({ account: owner, chain: robust, transport: http(RPC_URL) });

const ABI = [
  { name: "tier1Limit", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "tier2Limit", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "_tierLimitNonce", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "guardians", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
  { name: "modifyTierLimitsWithGuardians", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "_tier1", type: "uint256" }, { name: "_tier2", type: "uint256" },
      { name: "deadline", type: "uint256" }, { name: "guardianSigs", type: "bytes[]" },
    ], outputs: [] },
] as const;

// _tierLimitNonce has no public getter on some builds; read via a raw call fallback if needed.
async function tierNonce(): Promise<bigint> {
  try {
    return await pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "_tierLimitNonce" }) as bigint;
  } catch {
    return 0n; // first modify
  }
}

async function guardianSig(signer: typeof anni, changeHashRaw: Hex): Promise<Hex> {
  // contract recovers from EIP-191 personal-sign of the raw guardian-op hash
  return signer.signMessage({ message: { raw: changeHashRaw } });
}

async function main() {
  const [t1Before, t2Before] = await Promise.all([
    pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "tier1Limit" }) as Promise<bigint>,
    pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "tier2Limit" }) as Promise<bigint>,
  ]);
  const nonce = await tierNonce();
  console.log(`Account: ${ACCOUNT}`);
  console.log(`Before: tier1=${t1Before} tier2=${t2Before} nonce=${nonce}`);

  // New limits (tighten tier1 a bit; must satisfy tier1<=tier2)
  const newT1 = parseEther("0.02");
  const newT2 = parseEther("0.2");
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const opData = encodeAbiParameters(parseAbiParameters("uint256, uint256, uint256, uint256"), [nonce, newT1, newT2, deadline]);
  const changeHash = keccak256(encodeAbiParameters(
    parseAbiParameters("uint8, uint256, address, string, bytes"),
    [GUARDIAN_SIG_VERSION, CHAIN_ID, ACCOUNT, "MODIFY_TIER_LIMITS", opData],
  ));
  const sigs = [await guardianSig(anni, changeHash), await guardianSig(bob, changeHash)];
  console.log(`Guardian sigs: Anni + Bob (2-of-3) over MODIFY_TIER_LIMITS hash ${changeHash.slice(0, 14)}…`);

  const hash = await wOwner.writeContract({
    address: ACCOUNT, abi: ABI, functionName: "modifyTierLimitsWithGuardians",
    args: [newT1, newT2, deadline, sigs],
  });
  const r = await pub.waitForTransactionReceipt({ hash });
  console.log(`TX: ${hash}  status=${r.status}`);
  console.log(`Etherscan: https://sepolia.etherscan.io/tx/${hash}`);

  const [t1After, t2After] = await Promise.all([
    pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "tier1Limit" }) as Promise<bigint>,
    pub.readContract({ address: ACCOUNT, abi: ABI, functionName: "tier2Limit" }) as Promise<bigint>,
  ]);
  console.log(`After: tier1=${t1After} tier2=${t2After}`);
  if (t1After === newT1 && t2After === newT2 && r.status === "success") {
    console.log("\nPASS: J1 modifyTierLimitsWithGuardians — tier limits changed via 2-of-3 guardian consensus.");
  } else {
    console.error("\nFAIL: tier limits did not update as expected.");
    process.exit(1);
  }
}
main().catch((e) => { console.error("Fatal:", e?.shortMessage ?? e?.message ?? e); process.exit(1); });
