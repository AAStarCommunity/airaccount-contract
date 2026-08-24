/**
 * Deploy a fresh AirAccount stack for the isolated RepCredit Sepolia run.
 *
 * The private key is accepted only through REPCREDIT_PRIVATE_KEY and is never
 * logged or written. The output contains public addresses and receipts only.
 *
 * Safety properties (CC-51 review):
 * - every emitted error is passed through the shared redactor, so any credential inside
 *   REPCREDIT_RPC_URL — path key, query key or `user:pass@` userinfo — can never reach
 *   stderr or the evidence files;
 * - the EntryPoint must be the canonical v0.7 singleton unless explicitly overridden,
 *   because initialize() bakes it into a non-upgradable account permanently;
 * - fees follow the repo's proven Sepolia formula instead of viem's 1.2x default;
 * - DRY_RUN=1 links every artifact and estimates gas without sending a transaction;
 * - every transaction hash is journalled to disk BEFORE its receipt is awaited, a receipt
 *   timeout never rebroadcasts, and a rerun polls the journalled hashes and resumes from
 *   where the previous attempt stopped (CC-51 post-review MEDIUM).
 *
 * If a journalled transaction is genuinely dropped rather than slow, every rerun will keep polling
 * it. That is deliberate — the alternative, an automatic rebroadcast, is what snarls the nonce. The
 * escape is manual and explicit: confirm on a block explorer that the hash will never mine, then
 * remove that entry from the journal file by hand before rerunning.
 *
 * Environment:
 *   REPCREDIT_RPC_URL, REPCREDIT_PRIVATE_KEY, REPCREDIT_ENTRYPOINT, REPCREDIT_OUTPUT (required)
 *   REPCREDIT_JOURNAL              resume journal path (default: <REPCREDIT_OUTPUT>.journal.json)
 *   REPCREDIT_RECEIPT_TIMEOUT_MS   per-transaction receipt wait (default: viem's 180000)
 *   REPCREDIT_POLL_INTERVAL_MS     receipt poll interval (default: viem's client polling interval)
 *   DRY_RUN=1                      estimate only, send nothing, write nothing
 *   REPCREDIT_ALLOW_NONCANONICAL_ENTRYPOINT=1   deliberate escape hatch, see above
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
import { privateKeyToAccount } from "viem/accounts";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createRedactor } from "./lib/repcredit-redact.mjs";
import {
  createJournal,
  createTxRunner,
  planFingerprint,
  reconcilePending,
} from "./lib/repcredit-tx-journal.mjs";

const CHAIN_ID = 11_155_111;
// ERC-4337 v0.7 canonical EntryPoint, identical on every chain. Hardcoded across this repo
// (scripts/deploy-v0.31.0.ts, bench-tier-gas.ts, deploy-m5.ts) and asserted here because the
// factory bakes the EntryPoint into a non-upgradable account: a wrong one is unrecoverable.
const CANONICAL_ENTRYPOINT_V07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
// Proven Sepolia fee formula (deploy-v0.31.0.ts:58-63): maxFee = baseFee*2 + max(tip, 2 gwei).
// viem's default 1.2x underprovisions and the transaction silently drops out of the mempool.
const PRIORITY_FEE_FLOOR = 2_000_000_000n;
const SALT = 20_260_824_001n;
const DRY_RUN = process.env.DRY_RUN === "1";
const ALLOW_NONCANONICAL_ENTRYPOINT = process.env.REPCREDIT_ALLOW_NONCANONICAL_ENTRYPOINT === "1";
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
// The evidence file stays write-once. The journal and the failure record are separate paths so a
// resumed run can still write its evidence here.
if (existsSync(outputPath)) throw new Error(`refusing to overwrite ${outputPath}`);

const journalPath = process.env.REPCREDIT_JOURNAL || `${outputPath}.journal.json`;
const failurePath = `${outputPath}.failed.json`;
const receiptTimeoutMs = Number(process.env.REPCREDIT_RECEIPT_TIMEOUT_MS ?? "") || undefined;
const pollingIntervalMs = Number(process.env.REPCREDIT_POLL_INTERVAL_MS ?? "") || undefined;

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
const redact = createRedactor(rpcUrl);

type Artifact = {
  abi: Abi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, unknown>> };
};

const libraries: Record<string, Address> = {};

const journal = createJournal({
  path: journalPath,
  fingerprint: planFingerprint({
    script: "deploy-repcredit-sepolia",
    chainId: CHAIN_ID,
    entryPoint,
    deployer: account.address,
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

const runner = createTxRunner({
  journal,
  publicClient,
  walletClient,
  overrides: fees,
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
 * writes no evidence file or journal. Mirrors deploy-v0.31.0.ts:181.
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
  // Adopt a previous attempt's journal (fingerprint-gated) before anything is sent, then poll every
  // hash it left pending. Reconciliation runs first so a transaction that mined while the previous
  // process was dying is recognised instead of being sent a second time.
  journal.load();
  await preflight();
  if (journal.resumed) {
    const reconciled = await reconcilePending({ journal, publicClient });
    process.stderr.write(`${JSON.stringify({ status: "resume", journal: journalPath, reconciled })}\n`);
  }

  const webAuthnLib = await deploy("WebAuthnLib");
  libraries["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  const committeeBlsLib = await deploy("CommitteeBLSLib");
  libraries["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = committeeBlsLib;

  // Router zero is intentional. Note the whitelist below is recorded but inert: dailyLimit = 0 means
  // the factory deploys no guard, so no algId/tier gate is ever consulted (CC-51 MEDIUM-4 / LOW-4).
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
  const airAccount = getAddress(await publicClient.readContract({
    address: factory,
    abi: factoryAbi,
    functionName: "getAddress",
    args: [account.address, SALT, config, ZERO_BYTES32, ZERO_BYTES32],
  }) as Address);
  await call("create:AirAccount", factory, factoryAbi, "createAccount", [
    account.address,
    SALT,
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

  const version = await publicClient.readContract({
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
    transactions: journal.minedTransactions(),
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: "wx" });
  // The evidence file is now the record of truth; the resume journal has served its purpose.
  journal.discard();
  process.stdout.write(`${JSON.stringify({ status: "passed", chainId: CHAIN_ID, deployer: account.address, contracts: output.contracts })}\n`);
}

try {
  await (DRY_RUN ? dryRun() : main());
} catch (error) {
  const message = redact(error instanceof Error ? (error.stack ?? error.message) : String(error));
  // Guarded on every hash ever broadcast, not just the confirmed ones: a first-transaction timeout
  // used to leave no record at all, which is exactly the case that stranded gas.
  if (!DRY_RUN && journal.allHashes().length > 0) {
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
          deployer: account.address,
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
