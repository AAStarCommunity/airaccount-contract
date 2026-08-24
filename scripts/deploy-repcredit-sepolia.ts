/**
 * Deploy a fresh AirAccount stack for the isolated RepCredit Sepolia run.
 *
 * The private key is accepted only through REPCREDIT_PRIVATE_KEY and is never
 * logged or written. The output contains public addresses and receipts only.
 *
 * Safety properties (CC-51 review):
 * - every emitted error is passed through redact(), so the provider API key inside
 *   REPCREDIT_RPC_URL can never reach stderr or the evidence file;
 * - the EntryPoint must be the canonical v0.7 singleton unless explicitly overridden,
 *   because initialize() bakes it into a non-upgradable account permanently;
 * - fees follow the repo's proven Sepolia formula instead of viem's 1.2x default;
 * - DRY_RUN=1 links every artifact and estimates gas without sending a transaction;
 * - a failed run still persists the transactions already mined, so nothing becomes an
 *   unrecorded orphan.
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
// ERC-4337 v0.7 canonical EntryPoint, identical on every chain. Hardcoded across this repo
// (scripts/deploy-v0.31.0.ts, bench-tier-gas.ts, deploy-m5.ts) and asserted here because the
// factory bakes the EntryPoint into a non-upgradable account: a wrong one is unrecoverable.
const CANONICAL_ENTRYPOINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
// Proven Sepolia fee formula (deploy-v0.31.0.ts:58-63): maxFee = baseFee*2 + max(tip, 2 gwei).
// viem's default 1.2x underprovisions and the transaction silently drops out of the mempool.
const PRIORITY_FEE_FLOOR = 2_000_000_000n;
const DRY_RUN = process.env.DRY_RUN === "1";
const ALLOW_NONCANONICAL_ENTRYPOINT = process.env.REPCREDIT_ALLOW_NONCANONICAL_ENTRYPOINT === "1";
const RPC_PLACEHOLDER = "<redacted-rpc-url>";
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
// Fail closed on identity, not merely on "has code": any contract passes a code check, and the wrong
// EntryPoint (e.g. the v0.6 singleton) is baked irreversibly into the non-upgradable account by
// initialize(). Checked here, before any RPC call, so a misconfigured run cannot even start.
if (getAddress(entryPointRaw) !== CANONICAL_ENTRYPOINT_V07 && !ALLOW_NONCANONICAL_ENTRYPOINT) {
  throw new Error(
    `REPCREDIT_ENTRYPOINT ${getAddress(entryPointRaw)} is not the canonical v0.7 EntryPoint ` +
    `${CANONICAL_ENTRYPOINT_V07}; set REPCREDIT_ALLOW_NONCANONICAL_ENTRYPOINT=1 to override deliberately`,
  );
}
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

const rpcOrigin = (() => {
  try {
    return new URL(rpcUrl).origin;
  } catch {
    return "";
  }
})();

/**
 * viem embeds the full request URL in transport errors — `getUrl` in viem/_esm/errors/utils.js is
 * the identity function, so nothing is masked. An unhandled RPC fault would therefore print the
 * provider API key carried in REPCREDIT_RPC_URL. Every error string is funnelled through here.
 */
function redact(text: string): string {
  let out = rpcUrl ? text.split(rpcUrl).join(RPC_PLACEHOLDER) : text;
  if (rpcOrigin) {
    const escaped = rpcOrigin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    out = out.replace(new RegExp(`${escaped}[^\\s"']*`, "g"), RPC_PLACEHOLDER);
  }
  // Defence in depth for any URL that reached the text by another route (nested cause, proxy, etc).
  return out.replace(/(https?:\/\/[^\s"']+?)\/(v2|v3)\/[A-Za-z0-9_-]{8,}/g, `$1/$2/${RPC_PLACEHOLDER}`);
}

type Artifact = {
  abi: Abi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, unknown>> };
};

const libraries: Record<string, Address> = {};
const transactions: Record<string, { hash: Hex; blockNumber: string; blockHash: Hex; gasUsed: string }> = {};

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

async function fees(): Promise<{ maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }> {
  const block = await publicClient.getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try {
    tip = await publicClient.estimateMaxPriorityFeePerGas();
  } catch {
    // Provider does not expose the RPC; the floor below is the safe fallback.
  }
  const maxPriorityFeePerGas = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + maxPriorityFeePerGas, maxPriorityFeePerGas };
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
  const hash = await walletClient.sendTransaction({ data, ...(await fees()) });
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
  await record(label, await walletClient.sendTransaction({ to: address, data, ...(await fees()) }));
}

async function preflight(): Promise<void> {
  const chainId = await publicClient.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`Sepolia chain-id check failed: expected ${CHAIN_ID}, got ${chainId}`);
  if ((await publicClient.getBytecode({ address: entryPoint })) === undefined) {
    throw new Error(`EntryPoint ${entryPoint} has no code`);
  }
}

/**
 * DRY_RUN=1: resolve and link every artifact (the unlinked-library landmine from #149/#190),
 * verify chain and EntryPoint identity, estimate deploy gas and quote the fee. Sends nothing and
 * writes no evidence file. Mirrors deploy-v0.31.0.ts:181.
 */
async function dryRun(): Promise<void> {
  await preflight();
  const DUMMY = "0x000000000000000000000000000000000000dEaD" as Address;
  libraries["src/utils/WebAuthnLib.sol:WebAuthnLib"] = DUMMY;
  libraries["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = DUMMY;
  const plan: ReadonlyArray<readonly [string, readonly unknown[]]> = [
    ["WebAuthnLib", []],
    ["CommitteeBLSLib", []],
    ["AAStarAirAccountV7", [ZERO_ADDRESS]],
    ["AAStarAirAccountFactoryV7", [DUMMY, entryPoint, account.address, [], []]],
    ["RepCreditCounter", []],
  ];
  const estimates: Record<string, string> = {};
  let total = 0n;
  for (const [name, args] of plan) {
    const loaded = artifact(name);
    const gas = await publicClient.estimateGas({
      account: account.address,
      data: encodeDeployData({ abi: loaded.abi, bytecode: linkedBytecode(name), args }),
    });
    estimates[name] = gas.toString();
    total += gas;
  }
  const fee = await fees();
  process.stdout.write(`${JSON.stringify({
    status: "dry-run",
    chainId: CHAIN_ID,
    entryPoint,
    deployer: account.address,
    balanceWei: (await publicClient.getBalance({ address: account.address })).toString(),
    estimates,
    estimatedDeployGas: total.toString(),
    maxFeePerGas: fee.maxFeePerGas.toString(),
    maxPriorityFeePerGas: fee.maxPriorityFeePerGas.toString(),
    maxDeployCostWei: (total * fee.maxFeePerGas).toString(),
  })}\n`);
}

async function main(): Promise<void> {
  await preflight();

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

try {
  await (DRY_RUN ? dryRun() : main());
} catch (error) {
  const message = redact(error instanceof Error ? (error.stack ?? error.message) : String(error));
  if (!DRY_RUN && Object.keys(transactions).length > 0) {
    // Persist what already made it on chain so partially deployed contracts are never lost.
    try {
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(
        outputPath,
        `${JSON.stringify({ schemaVersion: 1, status: "failed", chainId: CHAIN_ID, entryPoint, deployer: account.address, error: message, libraries, transactions }, null, 2)}\n`,
        { flag: "wx" },
      );
    } catch (writeError) {
      process.stderr.write(`failed to persist partial evidence: ${redact(String(writeError))}\n`);
    }
  }
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}
