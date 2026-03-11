/**
 * Collect all on-chain data for M3 test report
 */
import { createPublicClient, http, parseAbi, formatEther, type Address } from "viem";
import { sepolia } from "viem/chains";
import * as dotenv from "dotenv";
dotenv.config({ path: ".env.sepolia" });

const client = createPublicClient({
  chain: sepolia,
  transport: http(process.env.SEPOLIA_RPC_URL),
});

// ─── Known addresses ─────────────────────────────────────────────────────────

const DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E" as Address;
const AA_ACCOUNT = "0xc278a671Fc80Fe8AaC1b0ac6f122bc58C4b1AA07" as Address;

// AirAccount contracts (M1/M2)
const VALIDATOR = "0xF780Cc3FB161F8df8C076f86E89CE8B685985395" as Address;
const FACTORY = "0x26a0B9B6119b9292a6105B7cEDc58E54767D0B31" as Address;
const IMPLEMENTATION = "0xab7d9A8Ab9e835c5C7D82829E32C10868558E0F8" as Address;

// AAStar ecosystem (from aastar-sdk config.sepolia.json)
const SUPER_PAYMASTER = "0x16cE0c7d846f9446bbBeb9C5a84A4D140fAeD94A" as Address;
const PAYMASTER_V4 = "0x67a70a578E142b950987081e7016906ae4F56Df4" as Address;
const APNTS = "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address;
const GTOKEN = "0x9ceDeC089921652D050819ca5BE53765fc05aa9E" as Address;
const SBT = "0x677423f5Dad98D19cAE8661c36F094289cb6171a" as Address;
const REGISTRY = "0x7Ba70C5bFDb3A4d0cBd220534f3BE177fefc1788" as Address;
const XPNTS_FACTORY = "0x6EafdA3477F3eec1F848505e1c06dFB5532395b6" as Address;
const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;

// ABIs
const ERC20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)"]);
const SBT_ABI = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const PM_ABI = parseAbi([
  "function operators(address) view returns (uint128 aPNTsBalance, uint96 exchangeRate, bool isConfigured, bool isPaused, address xPNTsToken, uint32 reputation, uint48 minTxInterval, address treasury)",
  "function sbtHolders(address) view returns (bool)",
  "function getDeposit() view returns (uint256)",
  "function cachedPrice() view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals)",
]);
const EP_ABI = parseAbi(["function getNonce(address,uint192) view returns (uint256)"]);

async function main() {
  console.log("=== M3 Report Data Collection ===\n");

  // 1. Verify all contract addresses have code
  console.log("--- Contract Verification ---");
  const contracts: [string, Address][] = [
    ["Validator", VALIDATOR],
    ["Factory", FACTORY],
    ["Implementation", IMPLEMENTATION],
    ["AA Account", AA_ACCOUNT],
    ["SuperPaymaster", SUPER_PAYMASTER],
    ["PaymasterV4", PAYMASTER_V4],
    ["aPNTs Token", APNTS],
    ["GToken", GTOKEN],
    ["MySBT", SBT],
    ["Registry", REGISTRY],
    ["xPNTs Factory", XPNTS_FACTORY],
    ["EntryPoint", ENTRYPOINT],
  ];

  for (const [name, addr] of contracts) {
    const code = await client.getCode({ address: addr });
    const hasCode = code && code.length > 2;
    console.log(`  ${name}: ${addr} [${hasCode ? "OK" : "NO CODE"}]`);
  }

  // 2. AA Account state
  console.log("\n--- AA Account State ---");
  const aaEth = await client.getBalance({ address: AA_ACCOUNT });
  const aaNonce = await client.readContract({ address: ENTRYPOINT, abi: EP_ABI, functionName: "getNonce", args: [AA_ACCOUNT, 0n] });
  const aaApnts = await client.readContract({ address: APNTS, abi: ERC20, functionName: "balanceOf", args: [AA_ACCOUNT] });
  const aaGtoken = await client.readContract({ address: GTOKEN, abi: ERC20, functionName: "balanceOf", args: [AA_ACCOUNT] });
  const aaSbt = await client.readContract({ address: SBT, abi: SBT_ABI, functionName: "balanceOf", args: [AA_ACCOUNT] });
  const aaSbtInPM = await client.readContract({ address: SUPER_PAYMASTER, abi: PM_ABI, functionName: "sbtHolders", args: [AA_ACCOUNT] });

  console.log(`  ETH balance:    ${formatEther(aaEth)}`);
  console.log(`  EP nonce:       ${aaNonce} (= ${aaNonce} successful UserOps)`);
  console.log(`  aPNTs balance:  ${formatEther(aaApnts)}`);
  console.log(`  GToken balance: ${formatEther(aaGtoken)}`);
  console.log(`  SBT held:       ${aaSbt > 0n}`);
  console.log(`  sbtHolders[AA]: ${aaSbtInPM}`);

  // 3. Operator state
  console.log("\n--- Operator State ---");
  const opConfig = await client.readContract({ address: SUPER_PAYMASTER, abi: PM_ABI, functionName: "operators", args: [DEPLOYER] });
  console.log(`  isConfigured:   ${opConfig[2]}`);
  console.log(`  aPNTsBalance:   ${formatEther(opConfig[0])}`);
  console.log(`  exchangeRate:   ${opConfig[1]}`);
  console.log(`  xPNTsToken:     ${opConfig[4]}`);
  console.log(`  treasury:       ${opConfig[7]}`);

  // 4. SuperPaymaster state
  console.log("\n--- SuperPaymaster State ---");
  const pmDeposit = await client.readContract({ address: SUPER_PAYMASTER, abi: PM_ABI, functionName: "getDeposit" });
  const cached = await client.readContract({ address: SUPER_PAYMASTER, abi: PM_ABI, functionName: "cachedPrice" });
  console.log(`  EntryPoint deposit: ${formatEther(pmDeposit)} ETH`);
  console.log(`  ETH/USD price:      ${Number(cached[0]) / 1e8}`);
  console.log(`  Price updatedAt:    ${new Date(Number(cached[1]) * 1000).toISOString()}`);

  // 5. Deployer balances
  console.log("\n--- Deployer State ---");
  const depEth = await client.getBalance({ address: DEPLOYER });
  const depApnts = await client.readContract({ address: APNTS, abi: ERC20, functionName: "balanceOf", args: [DEPLOYER] });
  console.log(`  ETH balance:    ${formatEther(depEth)}`);
  console.log(`  aPNTs balance:  ${formatEther(depApnts)}`);
}

main();
