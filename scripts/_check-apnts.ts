import { config } from "dotenv";
import { resolve } from "path";
import { createPublicClient, createWalletClient, http, formatUnits, parseUnits, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const TOKEN = "0xDf669834F04988BcEE0E3B6013B6b867Bd38778d" as Address;
const ERC20_ABI = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "transfer",  type: "function", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

const ACCOUNTS = [
  { label: "Signer",          addr: "0xb5600060e6de5E11D3636731964218E53caadf0E" as Address },
  { label: "M5 COMBINED_T1", addr: "0x73A7d2Aa0E8F2655F3c580aeCd5F6fcC8C300e32" as Address },
  { label: "M5 ERC20_GUARD", addr: "0xdBF6F82cE4fc710D0d548A131aeD776B0Ab94BdC" as Address },
  { label: "M6",              addr: "0xfab5b2cf392c862b455dcfafac5a414d459b6dcc" as Address },
  { label: "M7",              addr: "0xBe9245282E31E34961F6E867b8B335437a8fF78b" as Address },
];

async function main() {
  const owner = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL!) });
  const walletClient = createWalletClient({ account: owner, chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL!) });

  console.log("aPNTs balances:");
  for (const { label, addr } of ACCOUNTS) {
    const bal = await publicClient.readContract({ address: TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [addr] }) as bigint;
    console.log(`  ${label.padEnd(18)} ${addr}  ${formatUnits(bal, 18)} aPNTs`);
  }

  // Fund each non-signer account with 10 aPNTs if signer has enough
  const signerBal = await publicClient.readContract({ address: TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [owner.address] }) as bigint;
  if (signerBal < parseUnits("40", 18)) {
    console.log(`\nSigner only has ${formatUnits(signerBal, 18)} aPNTs — not enough to fund all accounts`);
    return;
  }

  console.log(`\nFunding each account with 10 aPNTs (signer has ${formatUnits(signerBal, 18)})...`);
  for (const { label, addr } of ACCOUNTS.slice(1)) {
    const bal = await publicClient.readContract({ address: TOKEN, abi: ERC20_ABI, functionName: "balanceOf", args: [addr] }) as bigint;
    if (bal >= parseUnits("1", 18)) { console.log(`  ${label} already funded (${formatUnits(bal, 18)})`); continue; }
    const tx = await walletClient.writeContract({ address: TOKEN, abi: ERC20_ABI, functionName: "transfer", args: [addr, parseUnits("10", 18)] });
    await publicClient.waitForTransactionReceipt({ hash: tx });
    console.log(`  ${label} funded: ${tx}`);
  }
}

main().catch(console.error);
