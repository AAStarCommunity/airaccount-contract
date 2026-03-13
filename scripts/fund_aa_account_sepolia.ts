/**
 * fund_aa_account_sepolia.ts — Fund a target AA account on Sepolia testnet
 *
 * Sends to a specified address:
 *   1. GToken  (governance token, skip if balance >= threshold)
 *   2. SBT     (via Registry.safeMintForRole, skip if already held)
 *   3. aPNTs   (gas token for PaymasterV4 / SuperPaymaster, skip if >= threshold)
 *
 * Contract addresses from aastar-sdk config.sepolia.json (authoritative source).
 *
 * Usage:
 *   # Default target (our AA account)
 *   pnpm tsx scripts/fund_aa_account_sepolia.ts
 *
 *   # Specify target address
 *   pnpm tsx scripts/fund_aa_account_sepolia.ts --target=0xABCD...
 *
 *   # Custom amounts
 *   pnpm tsx scripts/fund_aa_account_sepolia.ts --target=0x... --gtoken=500 --apnts=5000
 */

import * as path from "path";
import { fileURLToPath } from "url";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  formatEther,
  parseAbi,
  encodeAbiParameters,
  keccak256,
  toBytes,
  type Address,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import * as dotenv from "dotenv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, "../.env.sepolia") });

// ─── CLI args ────────────────────────────────────────────────────────────────

function arg(name: string): string | undefined {
  return process.argv.find((a) => a.startsWith(`--${name}=`))?.split("=")[1];
}

// Default: our AirAccount AA wallet on Sepolia
const DEFAULT_TARGET =
  "0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07" as Address;

const TARGET_ADDRESS = (arg("target") || DEFAULT_TARGET) as Address;
const GTOKEN_AMOUNT = parseEther(arg("gtoken") || "100");
const APNTS_AMOUNT = parseEther(arg("apnts") || "100");

// ─── Contract addresses (aastar-sdk config.sepolia.json) ─────────────────────

const CONTRACTS = {
  GTOKEN: "0x9ceDeC089921652D050819ca5BE53765fc05aa9E" as Address,
  APNTS: "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address,
  SBT: "0x677423f5Dad98D19cAE8661c36F094289cb6171a" as Address,
  REGISTRY: "0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788" as Address,
  SUPER_PAYMASTER: "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A" as Address,
  PAYMASTER_V4: "0x67a70a578E142b950987081e7016906ae4F56Df4" as Address,
  ENTRY_POINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address,
};

// ─── ABIs ────────────────────────────────────────────────────────────────────

const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function mint(address to, uint256 amount)",
  "function transfer(address to, uint256 amount) returns (bool)",
]);

const SBT_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function mint(address to)",
]);

const REGISTRY_ABI = parseAbi([
  "function ROLE_ENDUSER() view returns (bytes32)",
  "function hasRole(bytes32 roleId, address user) view returns (bool)",
  "function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external returns (uint256)",
]);

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const privateKey = (process.env.PRIVATE_KEY_JASON ||
    process.env.PRIVATE_KEY) as Hex;
  if (!privateKey) throw new Error("PRIVATE_KEY or PRIVATE_KEY_JASON not set");

  const rpcUrl = process.env.SEPOLIA_RPC_URL || process.env.RPC_URL;
  if (!rpcUrl) throw new Error("SEPOLIA_RPC_URL not set");

  const account = privateKeyToAccount(privateKey);
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(rpcUrl),
  });
  const wallet = createWalletClient({
    account,
    chain: sepolia,
    transport: http(rpcUrl),
  });

  console.log(`\nAirAccount AA Account Funder (Sepolia)`);
  console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
  console.log(`Target:  ${TARGET_ADDRESS}`);
  console.log(`Network: Sepolia`);
  console.log(`Signer:  ${account.address}`);
  console.log(`GToken:  ${formatEther(GTOKEN_AMOUNT)} (skip if >= 150)`);
  console.log(`aPNTs:   ${formatEther(APNTS_AMOUNT)} (skip if >= 10000)`);

  // ── Step 1: GToken ─────────────────────────────────────────────────────────
  console.log(`\nStep 1: GToken (governance token)`);
  const gBal = await publicClient.readContract({
    address: CONTRACTS.GTOKEN,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [TARGET_ADDRESS],
  });
  console.log(`  Current balance: ${formatEther(gBal)} GToken`);

  if (gBal >= parseEther("150")) {
    console.log(`  OK: Balance >= 150, skipping.`);
  } else {
    let gHash: Hex;
    try {
      gHash = await wallet.writeContract({
        address: CONTRACTS.GTOKEN,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [TARGET_ADDRESS, GTOKEN_AMOUNT],
      });
    } catch {
      console.log(`  mint() unavailable, trying transfer()`);
      gHash = await wallet.writeContract({
        address: CONTRACTS.GTOKEN,
        abi: ERC20_ABI,
        functionName: "transfer",
        args: [TARGET_ADDRESS, GTOKEN_AMOUNT],
      });
    }
    console.log(`  tx: ${gHash}`);
    await publicClient.waitForTransactionReceipt({ hash: gHash });
    const gAfter = await publicClient.readContract({
      address: CONTRACTS.GTOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [TARGET_ADDRESS],
    });
    console.log(`  New balance: ${formatEther(gAfter)} GToken`);
  }

  // ── Step 2: SBT ────────────────────────────────────────────────────────────
  console.log(`\nStep 2: SBT (role registration)`);
  const sbtBal = await publicClient.readContract({
    address: CONTRACTS.SBT,
    abi: SBT_ABI,
    functionName: "balanceOf",
    args: [TARGET_ADDRESS],
  });
  console.log(`  Current balance: ${sbtBal}`);

  if (sbtBal > 0n) {
    console.log(`  OK: Already holds SBT. Skipping.`);
  } else {
    let regOk = false;
    try {
      const roleId = keccak256(toBytes("ENDUSER"));
      const roleData = encodeAbiParameters(
        [
          {
            type: "tuple",
            components: [
              { type: "address", name: "account" },
              { type: "address", name: "community" },
              { type: "string", name: "avatar" },
              { type: "string", name: "ens" },
              { type: "uint256", name: "stake" },
            ],
          },
        ],
        [[TARGET_ADDRESS, account.address, "", "", parseEther("0.3")]]
      );
      const hash = await wallet.writeContract({
        address: CONTRACTS.REGISTRY,
        abi: REGISTRY_ABI,
        functionName: "safeMintForRole",
        args: [roleId, TARGET_ADDRESS, roleData],
      });
      console.log(`  tx: ${hash}`);
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(`  Role registered (SBT minted via Registry)`);
      regOk = true;
    } catch (e: any) {
      console.log(
        `  safeMintForRole() failed: ${e.shortMessage || e.message?.split("\n")[0]}`
      );
    }

    if (!regOk) {
      console.log(`  Trying MySBT.mint() fallback...`);
      try {
        const hash = await wallet.writeContract({
          address: CONTRACTS.SBT,
          abi: SBT_ABI,
          functionName: "mint",
          args: [TARGET_ADDRESS],
        });
        console.log(`  tx: ${hash}`);
        await publicClient.waitForTransactionReceipt({ hash });
        console.log(`  SBT minted directly`);
      } catch (e: any) {
        console.log(
          `  FAIL MySBT.mint(): ${e.shortMessage || e.message?.split("\n")[0]}`
        );
      }
    }
  }

  // ── Step 3: aPNTs ──────────────────────────────────────────────────────────
  console.log(`\nStep 3: aPNTs (gas token for paymaster)`);
  const aBal = await publicClient.readContract({
    address: CONTRACTS.APNTS,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [TARGET_ADDRESS],
  });
  console.log(`  Current balance: ${formatEther(aBal)} aPNTs`);

  if (aBal >= parseEther("10000")) {
    console.log(`  OK: Balance >= 10000, skipping.`);
  } else {
    let aHash: Hex;
    try {
      aHash = await wallet.writeContract({
        address: CONTRACTS.APNTS,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [TARGET_ADDRESS, APNTS_AMOUNT],
      });
    } catch {
      console.log(`  mint() unavailable, trying transfer()`);
      aHash = await wallet.writeContract({
        address: CONTRACTS.APNTS,
        abi: ERC20_ABI,
        functionName: "transfer",
        args: [TARGET_ADDRESS, APNTS_AMOUNT],
      });
    }
    console.log(`  tx: ${aHash}`);
    await publicClient.waitForTransactionReceipt({ hash: aHash });
    const aAfter = await publicClient.readContract({
      address: CONTRACTS.APNTS,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [TARGET_ADDRESS],
    });
    console.log(`  New balance: ${formatEther(aAfter)} aPNTs`);
  }

  // ── Final summary ──────────────────────────────────────────────────────────
  console.log(`\nComplete. Final balances for ${TARGET_ADDRESS}:`);
  const [gF, aF, sF] = await Promise.all([
    publicClient.readContract({
      address: CONTRACTS.GTOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [TARGET_ADDRESS],
    }),
    publicClient.readContract({
      address: CONTRACTS.APNTS,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [TARGET_ADDRESS],
    }),
    publicClient.readContract({
      address: CONTRACTS.SBT,
      abi: SBT_ABI,
      functionName: "balanceOf",
      args: [TARGET_ADDRESS],
    }),
  ]);
  console.log(`  GToken: ${formatEther(gF)}`);
  console.log(`  aPNTs:  ${formatEther(aF)}`);
  console.log(`  SBT:    ${sF > 0n ? "held" : "none"}`);

  console.log(`\nPaymaster addresses (for gasless E2E):`);
  console.log(`  SuperPaymaster: ${CONTRACTS.SUPER_PAYMASTER}`);
  console.log(`  PaymasterV4:    ${CONTRACTS.PAYMASTER_V4}`);
  console.log(`  aPNTs token:    ${CONTRACTS.APNTS}`);
}

main().catch((err) => {
  console.error("\nFatal error:", err.shortMessage || err.message || err);
  process.exit(1);
});
