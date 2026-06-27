/**
 * finalize-router.ts — Call finalizeSetup() on ValidatorRouter to lock algorithm registration.
 * Must be run from the router owner's account (Anni).
 */
import { createPublicClient, createWalletClient, http } from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { config } from "dotenv";

config({ path: "/Users/jason/Dev/aastar/airaccount-contract/.env.sepolia" });

const ROUTER = process.env.AIRACCOUNT_V0202_VALIDATOR_ROUTER! as `0x${string}`;
const annie = privateKeyToAccount(process.env.PRIVATE_KEY_ANNI! as `0x${string}`);

const pub = createPublicClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL!) });
const wal = createWalletClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL!), account: annie });

const abi = [
  { type: "function", name: "finalizeSetup", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "setupComplete", inputs: [], outputs: [{ type: "bool" }], stateMutability: "view" },
  { type: "function", name: "owner", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
] as const;

(async () => {
  const owner = await pub.readContract({ address: ROUTER, abi, functionName: "owner" });
  const sc = await pub.readContract({ address: ROUTER, abi, functionName: "setupComplete" });
  console.log("Router:", ROUTER);
  console.log("Owner:", owner, "| Signer:", annie.address);
  console.log("setupComplete (before):", sc);

  if (sc) {
    console.log("Already finalized — nothing to do.");
    process.exit(0);
  }

  const feeData = await pub.estimateFeesPerGas();
  const tip = 2_000_000_000n;
  const maxFee = feeData.maxFeePerGas * 2n + tip;

  const hash = await wal.writeContract({
    address: ROUTER, abi,
    functionName: "finalizeSetup",
    maxFeePerGas: maxFee,
    maxPriorityFeePerGas: tip,
    gas: 80_000n,
  });
  console.log("TX:", hash);

  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  console.log("Status:", receipt.status, "| Gas:", receipt.gasUsed.toString());

  const after = await pub.readContract({ address: ROUTER, abi, functionName: "setupComplete" });
  console.log("setupComplete (after):", after);
})();
