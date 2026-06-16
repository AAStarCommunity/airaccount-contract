/**
 * Create a fresh beta.2 account owned by PRIVATE_KEY (Jason), no guardians, no P256 key,
 * for the remaining E2E scenarios (C6 weighted / J governance / L6 weight-config) that
 * require a pre-existing AIRACCOUNT_M6_ACCOUNT. Prints the address (set it as env + reuse).
 *
 * Run: FACTORY_ADDRESS=0x1b694Aa55fBe2953e724037d2449905d531C1e65 pnpm tsx scripts/e2e-create-test-account.ts
 */
import { createPublicClient, createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { resolve } from "node:path";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const RPC_URL = (process.env.SEPOLIA_RPC_URL as string);
const FACTORY = (process.env.FACTORY_ADDRESS ?? "0x1b694Aa55fBe2953e724037d2449905d531C1e65") as Address;
const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
const SALT = BigInt(Math.floor(Date.now() / 1000)) + 900_000n;

const FACTORY_ABI = [
  { name: "createAccount", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "config", type: "tuple", components: [
        { name: "guardians", type: "address[3]" },
        { name: "dailyLimit", type: "uint256" },
        { name: "approvedAlgIds", type: "uint8[]" },
        { name: "minDailyLimit", type: "uint256" },
        { name: "initialTokens", type: "address[]" },
        { name: "initialTokenConfigs", type: "tuple[]", components: [
          { name: "tier1Limit", type: "uint128" },
          { name: "tier2Limit", type: "uint128" },
          { name: "dailyLimit", type: "uint256" },
        ]},
      ]},
    ], outputs: [{ name: "account", type: "address" }] },
  { name: "getAddress", type: "function", stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "config", type: "tuple", components: [
        { name: "guardians", type: "address[3]" },
        { name: "dailyLimit", type: "uint256" },
        { name: "approvedAlgIds", type: "uint8[]" },
        { name: "minDailyLimit", type: "uint256" },
        { name: "initialTokens", type: "address[]" },
        { name: "initialTokenConfigs", type: "tuple[]", components: [
          { name: "tier1Limit", type: "uint128" },
          { name: "tier2Limit", type: "uint128" },
          { name: "dailyLimit", type: "uint256" },
        ]},
      ]},
    ], outputs: [{ name: "account", type: "address" }] },
] as const;

const robust = { ...sepolia, fees: { baseFeeMultiplier: 2, maxPriorityFeePerGas: 2_000_000_000n } } as const;
const pub = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
const wallet = createWalletClient({ account, chain: robust, transport: http(RPC_URL) });

// Approve the algIds the remaining scenarios need: ECDSA(0x02), P256(0x03), combined(0x06),
// weighted(0x07), cumulative T2/T3 (0x04/0x05). Guardians empty (scenarios use owner/P256/ECDSA).
const cfg = {
  guardians: ["0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
  dailyLimit: 0n,
  approvedAlgIds: [0x02, 0x03, 0x04, 0x05, 0x06, 0x07] as number[],
  minDailyLimit: 0n,
  initialTokens: [] as Address[],
  initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
};

const predicted = await pub.readContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "getAddress", args: [account.address, SALT, cfg] });
const hash = await wallet.writeContract({ address: FACTORY, abi: FACTORY_ABI, functionName: "createAccount", args: [account.address, SALT, cfg] });
await pub.waitForTransactionReceipt({ hash });
console.log(`ACCOUNT=${predicted}`);
console.log(`OWNER=${account.address}`);
console.log(`SALT=${SALT}`);
console.log(`TX=${hash}`);
