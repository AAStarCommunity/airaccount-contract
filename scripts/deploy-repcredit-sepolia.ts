/**
 * Deploy a fresh AirAccount stack for the isolated RepCredit Sepolia run.
 *
 * The private key is accepted only through REPCREDIT_PRIVATE_KEY and is never
 * logged or written. The output contains public addresses and receipts only.
 */

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeDeployData,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  keccak256,
  stringToBytes,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const CHAIN_ID = 11_155_111;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
const ZERO_BYTES32 = `0x${"00".repeat(32)}` as Hex;
const rpcUrl = process.env.REPCREDIT_RPC_URL ?? "";
const privateKey = process.env.REPCREDIT_PRIVATE_KEY as Hex | undefined;
const entryPointRaw = process.env.REPCREDIT_ENTRYPOINT ?? "";
const outputPath = process.env.REPCREDIT_OUTPUT ?? "";

if (!rpcUrl) throw new Error("REPCREDIT_RPC_URL is required");
if (!privateKey || !/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
  throw new Error("REPCREDIT_PRIVATE_KEY must be a 32-byte hex key");
}
if (!isAddress(entryPointRaw)) throw new Error("REPCREDIT_ENTRYPOINT must be a valid address");
if (!outputPath.startsWith("/")) throw new Error("REPCREDIT_OUTPUT must be an absolute path");
if (existsSync(outputPath)) throw new Error(`refusing to overwrite ${outputPath}`);

const account = privateKeyToAccount(privateKey);
const entryPoint = getAddress(entryPointRaw);
const chain = defineChain({
  id: CHAIN_ID,
  name: "RepCredit Sepolia Evidence",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });

type Artifact = {
  abi: Abi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, unknown>> };
};

const libraries: Record<string, Address> = {};
const transactions: Record<string, { hash: Hex; blockNumber: string; blockHash: Hex; gasUsed: string }> = {};

function artifact(name: string): Artifact {
  return JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf8")) as Artifact;
}

function linkedBytecode(name: string): Hex {
  const loaded = artifact(name);
  let bytecode = loaded.bytecode.object;
  for (const [file, refs] of Object.entries(loaded.bytecode.linkReferences ?? {})) {
    for (const libraryName of Object.keys(refs)) {
      const fullyQualifiedName = `${file}:${libraryName}`;
      const address = libraries[fullyQualifiedName];
      if (!address) throw new Error(`${name}: missing linked library ${fullyQualifiedName}`);
      const placeholder = `__$${keccak256(stringToBytes(fullyQualifiedName)).slice(2, 36)}$__`;
      bytecode = bytecode.split(placeholder).join(address.slice(2).toLowerCase());
    }
  }
  if (bytecode.includes("__$")) throw new Error(`${name}: unresolved library placeholder`);
  return (bytecode.startsWith("0x") ? bytecode : `0x${bytecode}`) as Hex;
}

async function record(label: string, hash: Hex): Promise<TransactionReceipt> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1 });
  if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  transactions[label] = {
    hash,
    blockNumber: receipt.blockNumber.toString(),
    blockHash: receipt.blockHash,
    gasUsed: receipt.gasUsed.toString(),
  };
  return receipt;
}

async function deploy(name: string, args: readonly unknown[] = []): Promise<Address> {
  const loaded = artifact(name);
  const data = encodeDeployData({ abi: loaded.abi, bytecode: linkedBytecode(name), args });
  const hash = await (walletClient as any).sendTransaction({ data }) as Hex;
  const receipt = await record(`deploy:${name}`, hash);
  if (!receipt.contractAddress) throw new Error(`${name}: missing contract address`);
  return getAddress(receipt.contractAddress);
}

async function call(
  label: string,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
): Promise<void> {
  const data = encodeFunctionData({ abi, functionName, args });
  await record(label, await (walletClient as any).sendTransaction({ to: address, data }) as Hex);
}

async function main(): Promise<void> {
  if ((await publicClient.getChainId()) !== CHAIN_ID) throw new Error("Sepolia chain-id check failed");
  if ((await publicClient.getBytecode({ address: entryPoint })) === undefined) {
    throw new Error(`EntryPoint ${entryPoint} has no code`);
  }

  const webAuthnLib = await deploy("WebAuthnLib");
  libraries["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  const committeeBlsLib = await deploy("CommitteeBLSLib");
  libraries["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = committeeBlsLib;

  // Router zero is intentional: this evidence account uses explicit ECDSA mode 0x02.
  const implementation = await deploy("AAStarAirAccountV7", [ZERO_ADDRESS]);
  const factory = await deploy("AAStarAirAccountFactoryV7", [
    implementation,
    entryPoint,
    account.address,
    [],
    [],
  ]);
  const counter = await deploy("RepCreditCounter");

  const factoryAbi = artifact("AAStarAirAccountFactoryV7").abi;
  const config = {
    guardians: [ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS],
    guardianP256X: [ZERO_BYTES32, ZERO_BYTES32, ZERO_BYTES32],
    guardianP256Y: [ZERO_BYTES32, ZERO_BYTES32, ZERO_BYTES32],
    dailyLimit: 0n,
    approvedAlgIds: [2],
    minDailyLimit: 0n,
    initialTokens: [],
    initialTokenConfigs: [],
    tier1Limit: 0n,
    tier2Limit: 0n,
  } as const;
  const salt = 20_260_824_001n;
  const airAccount = getAddress(await (publicClient as any).readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getAddress",
    args: [account.address, salt, config, ZERO_BYTES32, ZERO_BYTES32],
  }) as Address);
  await call("create:AirAccount", factory, factoryAbi, "createAccount", [
    account.address,
    salt,
    config,
    ZERO_BYTES32,
    ZERO_BYTES32,
    0n,
    0n,
    "0x",
  ]);
  if ((await publicClient.getBytecode({ address: airAccount })) === undefined) {
    throw new Error(`AirAccount ${airAccount} was not deployed`);
  }

  const version = await (publicClient as any).readContract({
    address: airAccount,
    abi: artifact("AAStarAirAccountV7").abi,
    functionName: "ACCOUNT_VERSION",
  }) as string;

  const output = {
    schemaVersion: 1,
    experimentLabel: "repcredit-e2e-20260824",
    generatedAt: new Date().toISOString(),
    chainId: CHAIN_ID,
    entryPoint,
    deployer: account.address,
    version,
    contracts: { webAuthnLib, committeeBlsLib, implementation, factory, account: airAccount, counter },
    transactions,
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: "wx" });
  process.stdout.write(`${JSON.stringify({ status: "passed", chainId: CHAIN_ID, deployer: account.address, contracts: output.contracts })}\n`);
}

await main();
