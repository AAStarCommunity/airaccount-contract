/**
 * setup_operator_sepolia.ts — Register operator in SuperPaymaster on Sepolia
 *
 * Steps:
 *   1. Check/deploy xPNTs token via xPNTsFactory (if not exists)
 *   2. Approve GToken → GTokenStaking, register ROLE_PAYMASTER_SUPER
 *   3. Configure operator in SuperPaymaster (xPNTsToken, treasury, exchangeRate)
 *   4. Approve aPNTs → SuperPaymaster, deposit aPNTs collateral
 *
 * Usage:
 *   pnpm tsx scripts/setup_operator_sepolia.ts
 *   pnpm tsx scripts/setup_operator_sepolia.ts --deposit=5000
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
  keccak256,
  toBytes,
  encodeAbiParameters,
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

const DEPOSIT_AMOUNT = parseEther(arg("deposit") || "5000");

// ─── Contract addresses (aastar-sdk config.sepolia.json) ─────────────────────

const CONTRACTS = {
  GTOKEN: "0x9ceDeC089921652D050819ca5BE53765fc05aa9E" as Address,
  GTOKEN_STAKING: "0x1118eAf2427a5B9e488e28D35338d22EaCBc37fC" as Address,
  APNTS: "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address,
  REGISTRY: "0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788" as Address,
  SUPER_PAYMASTER: "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A" as Address,
  XPNTS_FACTORY: "0x6EafdA3477F3eec1F848505e1c06dFB5532395b6" as Address,
};

// ─── ABIs ────────────────────────────────────────────────────────────────────

const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function mint(address to, uint256 amount)",
]);

const REGISTRY_ABI = parseAbi([
  "function ROLE_PAYMASTER_SUPER() view returns (bytes32)",
  "function ROLE_COMMUNITY() view returns (bytes32)",
  "function hasRole(bytes32 roleId, address user) view returns (bool)",
  "function registerRoleSelf(bytes32 roleId, bytes calldata roleData) returns (uint256)",
]);

const SUPER_PM_ABI = parseAbi([
  "function operators(address) view returns (uint128 aPNTsBalance, uint96 exchangeRate, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury)",
  "function configureOperator(address xPNTsToken, address _opTreasury, uint256 exchangeRate)",
  "function deposit(uint256 amount)",
  "function getDeposit() view returns (uint256)",
  "function sbtHolders(address) view returns (bool)",
]);

const XPNTS_FACTORY_ABI = parseAbi([
  "function getTokenAddress(address community) view returns (address)",
  "function createToken(string name, string symbol, address community) returns (address)",
]);

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const privateKey = (process.env.PRIVATE_KEY_JASON ||
    process.env.PRIVATE_KEY) as Hex;
  if (!privateKey) throw new Error("PRIVATE_KEY not set");

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

  console.log(`\nSuperPaymaster Operator Setup (Sepolia)`);
  console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
  console.log(`Operator:        ${account.address}`);
  console.log(`SuperPaymaster:  ${CONTRACTS.SUPER_PAYMASTER}`);
  console.log(`aPNTs deposit:   ${formatEther(DEPOSIT_AMOUNT)}`);

  // ── Step 1: Check/deploy xPNTs token ───────────────────────────────────────
  console.log(`\nStep 1: Check xPNTs token`);
  let xPNTsToken = await publicClient.readContract({
    address: CONTRACTS.XPNTS_FACTORY,
    abi: XPNTS_FACTORY_ABI,
    functionName: "getTokenAddress",
    args: [account.address],
  });

  if (
    !xPNTsToken ||
    xPNTsToken === "0x0000000000000000000000000000000000000000"
  ) {
    console.log(`  No xPNTs token found, deploying...`);
    const hash = await wallet.writeContract({
      address: CONTRACTS.XPNTS_FACTORY,
      abi: XPNTS_FACTORY_ABI,
      functionName: "createToken",
      args: ["AirAccount PNTs", "airPNTs", account.address],
    });
    console.log(`  tx: ${hash}`);
    await publicClient.waitForTransactionReceipt({ hash });
    xPNTsToken = await publicClient.readContract({
      address: CONTRACTS.XPNTS_FACTORY,
      abi: XPNTS_FACTORY_ABI,
      functionName: "getTokenAddress",
      args: [account.address],
    });
    console.log(`  Deployed xPNTs: ${xPNTsToken}`);
  } else {
    console.log(`  xPNTs token: ${xPNTsToken}`);
  }

  // ── Step 2: Register ROLE_PAYMASTER_SUPER ──────────────────────────────────
  console.log(`\nStep 2: Register ROLE_PAYMASTER_SUPER`);
  const rolePMSuper = await publicClient.readContract({
    address: CONTRACTS.REGISTRY,
    abi: REGISTRY_ABI,
    functionName: "ROLE_PAYMASTER_SUPER",
  });

  const hasPMRole = await publicClient.readContract({
    address: CONTRACTS.REGISTRY,
    abi: REGISTRY_ABI,
    functionName: "hasRole",
    args: [rolePMSuper, account.address],
  });

  if (hasPMRole) {
    console.log(`  Already has ROLE_PAYMASTER_SUPER`);
  } else {
    // Need 50 GToken staked. Check balance and approve.
    const stakeAmount = parseEther("50");
    const gBal = await publicClient.readContract({
      address: CONTRACTS.GTOKEN,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [account.address],
    });
    console.log(`  GToken balance: ${formatEther(gBal)}`);

    if (gBal < stakeAmount) {
      console.log(`  Minting GToken (need 50 for stake)...`);
      const mintHash = await wallet.writeContract({
        address: CONTRACTS.GTOKEN,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [account.address, stakeAmount - gBal + parseEther("10")],
      });
      await publicClient.waitForTransactionReceipt({ hash: mintHash });
    }

    // Approve GToken to GTokenStaking
    const allowance = await publicClient.readContract({
      address: CONTRACTS.GTOKEN,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [account.address, CONTRACTS.GTOKEN_STAKING],
    });
    if (allowance < stakeAmount) {
      console.log(`  Approving GToken to GTokenStaking...`);
      const appHash = await wallet.writeContract({
        address: CONTRACTS.GTOKEN,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [CONTRACTS.GTOKEN_STAKING, stakeAmount * 2n],
      });
      await publicClient.waitForTransactionReceipt({ hash: appHash });
    }

    // Register role with stake encoded as roleData
    const roleData = encodeAbiParameters(
      [{ type: "uint256" }],
      [stakeAmount]
    );
    console.log(`  Registering ROLE_PAYMASTER_SUPER (50 GToken stake)...`);
    const regHash = await wallet.writeContract({
      address: CONTRACTS.REGISTRY,
      abi: REGISTRY_ABI,
      functionName: "registerRoleSelf",
      args: [rolePMSuper, roleData],
    });
    console.log(`  tx: ${regHash}`);
    await publicClient.waitForTransactionReceipt({ hash: regHash });
    console.log(`  ROLE_PAYMASTER_SUPER registered`);
  }

  // ── Step 3: Configure operator in SuperPaymaster ───────────────────────────
  console.log(`\nStep 3: Configure operator`);
  const opConfig = await publicClient.readContract({
    address: CONTRACTS.SUPER_PAYMASTER,
    abi: SUPER_PM_ABI,
    functionName: "operators",
    args: [account.address],
  });

  if (opConfig[2]) {
    // isConfigured
    console.log(`  Already configured`);
    console.log(`  xPNTsToken: ${opConfig[4]}`);
    console.log(`  exchangeRate: ${opConfig[1]}`);
  } else {
    console.log(`  Configuring operator...`);
    const confHash = await wallet.writeContract({
      address: CONTRACTS.SUPER_PAYMASTER,
      abi: SUPER_PM_ABI,
      functionName: "configureOperator",
      args: [xPNTsToken, account.address, parseEther("1")], // 1:1 rate
    });
    console.log(`  tx: ${confHash}`);
    await publicClient.waitForTransactionReceipt({ hash: confHash });
    console.log(`  Operator configured (xPNTs=${xPNTsToken}, rate=1:1)`);
  }

  // ── Step 4: Deposit aPNTs ──────────────────────────────────────────────────
  console.log(`\nStep 4: Deposit aPNTs collateral`);
  const opConfigAfter = await publicClient.readContract({
    address: CONTRACTS.SUPER_PAYMASTER,
    abi: SUPER_PM_ABI,
    functionName: "operators",
    args: [account.address],
  });
  const currentBalance = opConfigAfter[0]; // aPNTsBalance

  if (currentBalance >= DEPOSIT_AMOUNT) {
    console.log(
      `  Balance already sufficient: ${formatEther(currentBalance)} aPNTs`
    );
  } else {
    // Mint aPNTs if needed
    const aPNTsBal = await publicClient.readContract({
      address: CONTRACTS.APNTS,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [account.address],
    });

    if (aPNTsBal < DEPOSIT_AMOUNT) {
      console.log(`  Minting aPNTs (need ${formatEther(DEPOSIT_AMOUNT)})...`);
      const mintHash = await wallet.writeContract({
        address: CONTRACTS.APNTS,
        abi: ERC20_ABI,
        functionName: "mint",
        args: [account.address, DEPOSIT_AMOUNT - aPNTsBal + parseEther("100")],
      });
      await publicClient.waitForTransactionReceipt({ hash: mintHash });
    }

    // Approve aPNTs to SuperPaymaster
    const aPNTsAllowance = await publicClient.readContract({
      address: CONTRACTS.APNTS,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [account.address, CONTRACTS.SUPER_PAYMASTER],
    });
    if (aPNTsAllowance < DEPOSIT_AMOUNT) {
      console.log(`  Approving aPNTs to SuperPaymaster...`);
      const appHash = await wallet.writeContract({
        address: CONTRACTS.APNTS,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [CONTRACTS.SUPER_PAYMASTER, DEPOSIT_AMOUNT * 2n],
      });
      await publicClient.waitForTransactionReceipt({ hash: appHash });
    }

    // Deposit
    console.log(`  Depositing ${formatEther(DEPOSIT_AMOUNT)} aPNTs...`);
    const depHash = await wallet.writeContract({
      address: CONTRACTS.SUPER_PAYMASTER,
      abi: SUPER_PM_ABI,
      functionName: "deposit",
      args: [DEPOSIT_AMOUNT],
    });
    console.log(`  tx: ${depHash}`);
    await publicClient.waitForTransactionReceipt({ hash: depHash });
    console.log(`  Deposited ${formatEther(DEPOSIT_AMOUNT)} aPNTs`);
  }

  // ── Final status ───────────────────────────────────────────────────────────
  console.log(`\n=== Final Status ===`);
  const finalConfig = await publicClient.readContract({
    address: CONTRACTS.SUPER_PAYMASTER,
    abi: SUPER_PM_ABI,
    functionName: "operators",
    args: [account.address],
  });
  console.log(`  isConfigured:  ${finalConfig[2]}`);
  console.log(`  aPNTsBalance:  ${formatEther(finalConfig[0])} aPNTs`);
  console.log(`  exchangeRate:  ${finalConfig[1]}`);
  console.log(`  xPNTsToken:    ${finalConfig[4]}`);
  console.log(`  treasury:      ${finalConfig[7]}`);

  const pmDeposit = await publicClient.readContract({
    address: CONTRACTS.SUPER_PAYMASTER,
    abi: SUPER_PM_ABI,
    functionName: "getDeposit",
  });
  console.log(`  EntryPoint deposit: ${formatEther(pmDeposit)} ETH`);

  console.log(`\nOperator setup complete. Ready for gasless E2E test.`);
}

main().catch((err) => {
  console.error("\nFatal error:", err.shortMessage || err.message || err);
  process.exit(1);
});
