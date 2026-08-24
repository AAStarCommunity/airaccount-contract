/**
 * Deploy the latest AirAccount stack used by the RepCredit local evidence run.
 *
 * Safety properties:
 * - accepts only chain id 31337;
 * - uses an Anvil unlocked account, so no private key is read or printed;
 * - links both external libraries and fails on any unresolved placeholder;
 * - refuses to overwrite an existing evidence output file;
 * - redacts REPCREDIT_RPC_URL out of every emitted error and never persists it, so pointing the
 *   script at a remote node cannot leak a provider API key (CC-51 MEDIUM-1 / LOW-1 / LOW-2);
 * - journals every transaction hash to disk BEFORE awaiting its receipt, never rebroadcasts on a
 *   receipt timeout, and resumes from the journal on a rerun (CC-51 post-review MEDIUM).
 *
 * If a journalled transaction is genuinely dropped rather than slow, every rerun will keep polling
 * it. That is deliberate — the alternative, an automatic rebroadcast, is what snarls the nonce. The
 * escape is manual and explicit: confirm on a block explorer that the hash will never mine, then
 * remove that entry from the journal file by hand before rerunning.
 *
 * Usage:
 *   REPCREDIT_RPC_URL=http://127.0.0.1:18547 \
 *   REPCREDIT_ENTRYPOINT=0x... \
 *   REPCREDIT_OUTPUT=/absolute/path/airaccount-deployment.json \
 *   pnpm tsx scripts/deploy-repcredit-local.ts
 *
 * Optional: REPCREDIT_JOURNAL, REPCREDIT_RECEIPT_TIMEOUT_MS, REPCREDIT_POLL_INTERVAL_MS.
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
} from "viem";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRedactor } from "./lib/repcredit-redact.mjs";
import {
  createJournal,
  createTxRunner,
  planFingerprint,
  reconcilePending,
} from "./lib/repcredit-tx-journal.mjs";

const CHAIN_ID = 31_337;
const DEFAULT_ANVIL_DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as Address;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
const ZERO_BYTES32 = `0x${"00".repeat(32)}` as Hex;
const SALT = 20_260_823_001n;

const rpcUrl = process.env.REPCREDIT_RPC_URL ?? "http://127.0.0.1:18547";
const entryPointRaw = process.env.REPCREDIT_ENTRYPOINT ?? "";
const outputPath = process.env.REPCREDIT_OUTPUT ?? "";
const deployerRaw = process.env.REPCREDIT_DEPLOYER ?? DEFAULT_ANVIL_DEPLOYER;

if (!isAddress(entryPointRaw)) throw new Error("REPCREDIT_ENTRYPOINT must be a valid address");
if (!isAddress(deployerRaw)) throw new Error("REPCREDIT_DEPLOYER must be a valid address");
if (!outputPath || !outputPath.startsWith("/")) {
  throw new Error("REPCREDIT_OUTPUT must be an absolute path");
}
// The evidence file stays write-once; the journal and the failure record live beside it so a
// resumed run can still write its evidence here.
if (existsSync(outputPath)) throw new Error(`refusing to overwrite ${outputPath}`);

const journalPath = process.env.REPCREDIT_JOURNAL || `${outputPath}.journal.json`;
const failurePath = `${outputPath}.failed.json`;
const receiptTimeoutMs = Number(process.env.REPCREDIT_RECEIPT_TIMEOUT_MS ?? "") || undefined;
const pollingIntervalMs = Number(process.env.REPCREDIT_POLL_INTERVAL_MS ?? "") || undefined;

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
const redact = createRedactor(rpcUrl);

type Artifact = {
  abi: Abi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, unknown>> };
};

const libraries: Record<string, Address> = {};

const journal = createJournal({
  path: journalPath,
  fingerprint: planFingerprint({
    script: "deploy-repcredit-local",
    chainId: CHAIN_ID,
    entryPoint,
    deployer,
    salt: SALT.toString(),
  }),
});

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

const runner = createTxRunner({
  journal,
  publicClient,
  walletClient,
  overrides: async () => ({ account: deployer }),
  confirmations: 1,
  receiptTimeoutMs,
  pollingIntervalMs,
});

async function deploy(name: string, args: readonly unknown[] = []): Promise<Address> {
  const loaded = artifact(name);
  const data = encodeDeployData({ abi: loaded.abi, bytecode: linkedBytecode(name), args });
  const result = await runner.send(`deploy:${name}`, { data });
  const address = result.receipt?.contractAddress ?? result.entry?.contractAddress;
  if (!address) throw new Error(`${name}: missing contract address`);
  if (result.reused) process.stderr.write(`${JSON.stringify({ status: "resumed", step: `deploy:${name}`, address })}\n`);
  return getAddress(address as Address);
}

async function call(
  label: string,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
): Promise<void> {
  const data = encodeFunctionData({ abi, functionName, args });
  const result = await runner.send(label, { to: address, data });
  if (result.reused) process.stderr.write(`${JSON.stringify({ status: "resumed", step: label })}\n`);
}

async function main(): Promise<void> {
  journal.load();
  const chainId = await publicClient.getChainId();
  if (chainId !== CHAIN_ID) throw new Error(`local-only script: expected chain ${CHAIN_ID}, got ${chainId}`);
  if ((await publicClient.getBytecode({ address: entryPoint })) === undefined) {
    throw new Error(`EntryPoint ${entryPoint} has no code`);
  }
  // Reconcile before the plan restarts: a hash that mined while the previous process was dying is
  // adopted here instead of being sent a second time.
  if (journal.resumed) {
    const reconciled = await reconcilePending({ journal, publicClient });
    process.stderr.write(`${JSON.stringify({ status: "resume", journal: journalPath, reconciled })}\n`);
  }

  const webAuthnLib = await deploy("WebAuthnLib");
  libraries["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  const committeeBlsLib = await deploy("CommitteeBLSLib");
  libraries["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = committeeBlsLib;

  // Router address zero is deliberate. The whitelist below is recorded but inert: dailyLimit = 0
  // means the factory deploys no guard, so no algId/tier gate is ever consulted (CC-51 MEDIUM-4).
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
  const account = getAddress(await publicClient.readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getAddress",
    args: [deployer, SALT, config, ZERO_BYTES32, ZERO_BYTES32],
  }) as Address);
  await call("create:AirAccount", factory, factoryAbi, "createAccount", [
    deployer,
    SALT,
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
    transactions: journal.minedTransactions(),
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: "wx" });
  journal.discard();
  process.stdout.write(`${JSON.stringify(output)}\n`);
}

try {
  await main();
} catch (error) {
  const message = redact(error instanceof Error ? (error.stack ?? error.message) : String(error));
  // Guarded on every hash ever broadcast, not just the confirmed ones: a first-transaction timeout
  // used to leave no record at all.
  if (journal.allHashes().length > 0) {
    try {
      const pending = journal.pending().map(([label, entry]) => ({ label, hash: entry.hash, sentAt: entry.sentAt }));
      mkdirSync(dirname(failurePath), { recursive: true });
      writeFileSync(
        failurePath,
        `${JSON.stringify({
          schemaVersion: 1,
          status: "failed",
          chainId: CHAIN_ID,
          entryPoint,
          deployer,
          error: message,
          journal: journalPath,
          libraries,
          transactions: journal.minedTransactions(),
          pending,
          ...(pending.length > 0
            ? { resume: "re-run with the same REPCREDIT_* environment: the pending hashes are polled and reconciled. Never re-broadcast them." }
            : {}),
        }, null, 2)}\n`,
      );
    } catch (writeError) {
      process.stderr.write(`failed to persist partial evidence: ${redact(String(writeError))}\n`);
    }
  }
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}
