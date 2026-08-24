/**
 * Deploy the latest AirAccount stack used by the RepCredit local evidence run.
 *
 * Safety properties:
 * - accepts only chain id 31337;
 * - uses an Anvil unlocked account, so no private key is read or printed;
 * - links both external libraries and fails on any unresolved placeholder;
 * - refuses to overwrite an existing evidence output file;
 * - redacts REPCREDIT_RPC_URL out of every emitted error and never persists it, so pointing the
 *   script at a remote node cannot leak a provider API key (CC-51 MEDIUM-1 / LOW-2);
 * - persists the transactions already mined when a run fails, so nothing becomes an orphan.
 *
 * Usage:
 *   REPCREDIT_RPC_URL=http://127.0.0.1:18547 \
 *   REPCREDIT_ENTRYPOINT=0x... \
 *   REPCREDIT_OUTPUT=/absolute/path/airaccount-deployment.json \
 *   pnpm tsx scripts/deploy-repcredit-local.ts
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
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const CHAIN_ID = 31_337;
const DEFAULT_ANVIL_DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as Address;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
const ZERO_BYTES32 = `0x${"00".repeat(32)}` as Hex;
const RPC_PLACEHOLDER = "<redacted-rpc-url>";

const rpcUrl = process.env.REPCREDIT_RPC_URL ?? "http://127.0.0.1:18547";
const entryPointRaw = process.env.REPCREDIT_ENTRYPOINT ?? "";
const outputPath = process.env.REPCREDIT_OUTPUT ?? "";
const deployerRaw = process.env.REPCREDIT_DEPLOYER ?? DEFAULT_ANVIL_DEPLOYER;

if (!isAddress(entryPointRaw)) throw new Error("REPCREDIT_ENTRYPOINT must be a valid address");
if (!isAddress(deployerRaw)) throw new Error("REPCREDIT_DEPLOYER must be a valid address");
if (!outputPath || !outputPath.startsWith("/")) {
  throw new Error("REPCREDIT_OUTPUT must be an absolute path");
}
if (existsSync(outputPath)) throw new Error(`refusing to overwrite ${outputPath}`);

const entryPoint = getAddress(entryPointRaw);
const deployer = getAddress(deployerRaw);
const localChain = defineChain({
  id: CHAIN_ID,
  name: "RepCredit Anvil Prague",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});
const publicClient = createPublicClient({ chain: localChain, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account: deployer, chain: localChain, transport: http(rpcUrl) });

const rpcOrigin = (() => {
  try {
    return new URL(rpcUrl).origin;
  } catch {
    return "";
  }
})();

/**
 * viem's `getUrl` (viem/_esm/errors/utils.js) is the identity function, so transport errors carry the
 * full RPC URL. Harmless for the 127.0.0.1 default, but REPCREDIT_RPC_URL may be repointed at a
 * remote node whose API key sits in the URL, so redact before anything is emitted.
 */
function redact(text: string): string {
  let out = rpcUrl ? text.split(rpcUrl).join(RPC_PLACEHOLDER) : text;
  if (rpcOrigin) {
    const escaped = rpcOrigin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    out = out.replace(new RegExp(`${escaped}[^\\s"']*`, "g"), RPC_PLACEHOLDER);
  }
  return out.replace(/(https?:\/\/[^\s"']+?)\/(v2|v3)\/[A-Za-z0-9_-]{8,}/g, `$1/$2/${RPC_PLACEHOLDER}`);
}

type Artifact = {
  abi: Abi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, unknown>> };
};

const libraries: Record<string, Address> = {};
const transactions: Record<string, { hash: Hex; blockNumber: string; gasUsed: string }> = {};

function artifact(name: string): Artifact {
  const path = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  if (!existsSync(path)) {
    // RepCreditCounter lives in test/mocks/, so `forge build --skip test` does not produce it.
    throw new Error(`missing artifact for ${name} at out/${name}.sol/${name}.json — run \`forge build\` (a full build, not --skip test)`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as Artifact;
}

function linkedBytecode(name: string): Hex {
  const loaded = artifact(name);
  let out = loaded.bytecode.object;
  for (const [file, refs] of Object.entries(loaded.bytecode.linkReferences ?? {})) {
    for (const libraryName of Object.keys(refs)) {
      const fullyQualifiedName = `${file}:${libraryName}`;
      const address = libraries[fullyQualifiedName];
      if (!address) throw new Error(`${name}: missing linked library ${fullyQualifiedName}`);
      const placeholder = `__$${keccak256(stringToBytes(fullyQualifiedName)).slice(2, 36)}$__`;
      out = out.split(placeholder).join(address.slice(2).toLowerCase());
    }
  }
  if (out.includes("__$")) throw new Error(`${name}: unresolved library placeholder`);
  return (out.startsWith("0x") ? out : `0x${out}`) as Hex;
}

async function record(label: string, hash: Hex): Promise<TransactionReceipt> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  transactions[label] = {
    hash,
    blockNumber: receipt.blockNumber.toString(),
    gasUsed: receipt.gasUsed.toString(),
  };
  return receipt;
}

async function deploy(name: string, args: readonly unknown[] = []): Promise<Address> {
  const loaded = artifact(name);
  const data = encodeDeployData({ abi: loaded.abi, bytecode: linkedBytecode(name), args });
  const hash = await walletClient.sendTransaction({ account: deployer, data });
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
  const hash = await walletClient.sendTransaction({ account: deployer, to: address, data });
  await record(label, hash);
}

async function main(): Promise<void> {
  const chainId = await publicClient.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`local-only script: expected chain ${CHAIN_ID}, got ${chainId}`);
  if ((await publicClient.getBytecode({ address: entryPoint })) === undefined) {
    throw new Error(`EntryPoint ${entryPoint} has no code`);
  }

  const webAuthnLib = await deploy("WebAuthnLib");
  libraries["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  const committeeBlsLib = await deploy("CommitteeBLSLib");
  libraries["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = committeeBlsLib;

  // Router address zero is deliberate: this evidence account uses explicit ECDSA [0x02] only.
  const implementation = await deploy("AAStarAirAccountV7", [ZERO_ADDRESS]);
  const factory = await deploy("AAStarAirAccountFactoryV7", [
    implementation,
    entryPoint,
    deployer,
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
  const salt = 20_260_823_001n;
  const account = getAddress(await publicClient.readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getAddress",
    args: [deployer, salt, config, ZERO_BYTES32, ZERO_BYTES32],
  }) as Address);
  await call("create:AirAccount", factory, factoryAbi, "createAccount", [
    deployer,
    salt,
    config,
    ZERO_BYTES32,
    ZERO_BYTES32,
    0n,
    0n,
    "0x",
  ]);
  if ((await publicClient.getBytecode({ address: account })) === undefined) {
    throw new Error(`AirAccount ${account} was not deployed`);
  }

  const accountAbi = artifact("AAStarAirAccountV7").abi;
  const version = await publicClient.readContract({
    address: account,
    abi: accountAbi,
    functionName: "ACCOUNT_VERSION",
  }) as string;

  const output = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    chainId,
    entryPoint,
    deployer,
    version,
    contracts: { webAuthnLib, committeeBlsLib, implementation, factory, account, counter },
    transactions,
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: "wx" });
  process.stdout.write(`${JSON.stringify(output)}\n`);
}

try {
  await main();
} catch (error) {
  const message = redact(error instanceof Error ? (error.stack ?? error.message) : String(error));
  if (Object.keys(transactions).length > 0) {
    // Persist what already made it on chain so partially deployed contracts are never lost.
    try {
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(
        outputPath,
        `${JSON.stringify({ schemaVersion: 1, status: "failed", chainId: CHAIN_ID, entryPoint, deployer, error: message, libraries, transactions }, null, 2)}\n`,
        { flag: "wx" },
      );
    } catch (writeError) {
      process.stderr.write(`failed to persist partial evidence: ${redact(String(writeError))}\n`);
    }
  }
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}
