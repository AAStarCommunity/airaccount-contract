/**
 * deploy-v0.19.ts — Full v0.19 Sepolia deploy.
 *
 * v0.19 milestone deliverables:
 *   - #42 Safe-multisig community guardian in social recovery (E2E verified by #116)
 *   - #67 KMS cross-version contract-side verification
 *
 * Contract-level change from v0.18: version constants bumped to "0.19.0".
 * All singletons (BLS, validator, session, etc.) are unchanged in logic —
 * this is a full fresh redeploy (same DAG as v0.18) so on-chain versions
 * self-report "0.19.0" per the RELEASE_CHECKLIST Known Oversight #1 fix.
 *
 * Deploy order (same DAG as deploy-v0.18.ts):
 *   1. AAStarBLSAlgorithm
 *   2. AAStarValidator (router)
 *   3. AAStarBLSAggregator
 *   4. SessionKeyValidator
 *   5. ForceExitModule
 *   6. AirAccountDelegate
 *   7. CalldataParserRegistry
 *   8. AAStarAirAccountV7 (impl + Extension)
 *   9. AAStarAirAccountFactoryV7
 *  10. AgentRegistry
 *
 * Usage: pnpm tsx scripts/deploy-v0.19.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  formatEther, parseEther, getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const ALG_BLS = 0x01;
const ALG_SESSION_KEY = 0x08;

const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const PRIORITY_FEE_OVERRIDE = process.env.DEPLOY_PRIORITY_FEE_GWEI
  ? BigInt(Math.round(Number(process.env.DEPLOY_PRIORITY_FEE_GWEI) * 1e9))
  : 0n;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

const BLS_NODES: { nodeId: Hex; pubKey: Hex; label: string }[] = [
  { nodeId: process.env.BLS_TEST_NODE_ID_1 as Hex, pubKey: process.env.BLS_TEST_PUBLIC_KEY_1 as Hex, label: "Node1" },
  { nodeId: process.env.BLS_TEST_NODE_ID_2 as Hex, pubKey: process.env.BLS_TEST_PUBLIC_KEY_2 as Hex, label: "Node2" },
];

const deployer = privateKeyToAccount(PRIVATE_KEY);

const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "algorithms", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const REGISTRY_ABI = [
  { name: "bindFactory", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "factory", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "agentRegistry", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const BLS_ALG_ABI = [
  { name: "registerPublicKey", type: "function", stateMutability: "nonpayable", inputs: [{ type: "bytes32" }, { type: "bytes" }], outputs: [] },
  { name: "isRegistered", type: "function", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bool" }] },
  { name: "setAggregator", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "aggregator", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const ENTRYPOINT_ABI = [
  { name: "addStake", type: "function", stateMutability: "payable", inputs: [{ type: "uint32" }], outputs: [] },
] as const;
const IMPL_EXT_ABI = [
  { name: "agentExtension", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: a.bytecode.object as Hex };
}
function pub(rpcUrl: string) { return createPublicClient({ chain: sepolia, transport: http(rpcUrl, { timeout: 60_000 }) }); }
function wal(rpcUrl: string) { return createWalletClient({ account: deployer, chain: sepolia, transport: http(rpcUrl, { timeout: 60_000 }) }); }
function maxBig(a: bigint, b: bigint): bigint { return a > b ? a : b; }

async function fees(): Promise<{ maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }> {
  const client = pub(RPC_URLS[0]);
  const block = await client.getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
  let suggested = PRIORITY_FEE_FLOOR;
  try { suggested = await client.estimateMaxPriorityFeePerGas(); } catch { /* fall back to floor */ }
  const priority = PRIORITY_FEE_OVERRIDE > 0n ? PRIORITY_FEE_OVERRIDE : maxBig(suggested, PRIORITY_FEE_FLOOR);
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}

async function waitReceiptAnyRpc(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  for (let attempt = 0; attempt < 90; attempt++) {
    for (const rpcUrl of RPC_URLS) {
      try {
        const r = await pub(rpcUrl).getTransactionReceipt({ hash });
        if (r) {
          if (r.status !== "success") throw new Error(`${label} reverted (status=${r.status})`);
          console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
          return r;
        }
      } catch (e: any) {
        if (String(e.message ?? "").includes("reverted")) throw e;
      }
    }
    await new Promise((res) => setTimeout(res, 5000));
  }
  throw new Error(`${label}: receipt not found after polling — check ${hash}`);
}

async function deployOnce(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }),
    gas, ...f,
  });
  const r = await waitReceiptAnyRpc(hash, label);
  return getAddress(r.contractAddress!);
}

async function callOnce(label: string, to: Address, abi: unknown[], functionName: string, args: unknown[], gas: bigint, value = 0n) {
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    to, data: encodeFunctionData({ abi, functionName, args } as any), gas, value, ...f,
  });
  await waitReceiptAnyRpc(hash, label);
}

async function deployOrReuse(envKey: string, label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const existing = process.env[envKey];
  if (existing && /^0x[0-9a-fA-F]{40}$/.test(existing)) {
    console.log(`  [reuse] ${label} = ${existing} (from ${envKey})`);
    return getAddress(existing as Address);
  }
  return deployOnce(label, artifactName, args, gas);
}

const GAS = {
  blsAlgorithm: 2_000_000n,
  validatorRouter: 600_000n,
  blsAggregator: 1_100_000n,
  sessionKeyValidator: 2_800_000n,
  forceExitModule: 1_500_000n,
  delegate: 3_000_000n,
  parserRegistry: 300_000n,
  impl: 10_000_000n,
  factory: 6_000_000n,
  agentRegistry: 1_500_000n,
};

async function main() {
  if (!PRIVATE_KEY) { console.error("ERROR: PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set"); process.exit(1); }
  if (!COMMUNITY) { console.error("ERROR: COMMUNITY_GUARDIAN_ADDRESS not set"); process.exit(1); }
  if (RPC_URLS.length === 0) { console.error("ERROR: no SEPOLIA_RPC_URL set"); process.exit(1); }
  for (const n of BLS_NODES) {
    if (!n.nodeId || !n.pubKey) {
      console.error(`ERROR: BLS DVT node key missing (${n.label}). Set BLS_TEST_NODE_ID_* / BLS_TEST_PUBLIC_KEY_* in .env.sepolia`);
      process.exit(1);
    }
  }

  console.log("=== Deploy AirAccount v0.19 (Sepolia) ===");
  console.log(`Deployer:   ${deployer.address}`);
  console.log(`Community:  ${COMMUNITY}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const bal = await pub(RPC_URLS[0]).getBalance({ address: deployer.address });
  console.log(`Balance:    ${formatEther(bal)} ETH`);
  if (bal < parseEther("0.05")) {
    console.error(`ERROR: balance ${formatEther(bal)} ETH below 0.05 ETH floor — fund the deployer first.`);
    process.exit(1);
  }

  const totalGasBudget = Object.values(GAS).reduce((a, b) => a + b, 0n);
  const { maxFeePerGas } = await fees();
  console.log(`Gas budget: ${totalGasBudget} gas`);
  console.log(`Worst-case: ~${formatEther(totalGasBudget * maxFeePerGas)} ETH\n`);

  console.log("[1/10] AAStarBLSAlgorithm...");
  const blsAlgorithm = await deployOrReuse("AIRACCOUNT_V019_BLS_ALGORITHM", "AAStarBLSAlgorithm", "AAStarBLSAlgorithm", [], GAS.blsAlgorithm);

  console.log("[2/10] AAStarValidator (router)...");
  const validatorRouter = await deployOrReuse("AIRACCOUNT_V019_VALIDATOR_ROUTER", "AAStarValidator", "AAStarValidator", [], GAS.validatorRouter);

  console.log("[3/10] AAStarBLSAggregator...");
  const blsAggregator = await deployOrReuse("AIRACCOUNT_V019_BLS_AGGREGATOR", "AAStarBLSAggregator", "AAStarBLSAggregator", [blsAlgorithm, ENTRYPOINT], GAS.blsAggregator);

  console.log("[4/10] SessionKeyValidator...");
  const sessionKeyValidator = await deployOrReuse("AIRACCOUNT_V019_SESSION_KEY_VALIDATOR", "SessionKeyValidator", "SessionKeyValidator", [], GAS.sessionKeyValidator);

  console.log("[5/10] ForceExitModule...");
  const forceExitModule = await deployOrReuse("AIRACCOUNT_V019_FORCE_EXIT_MODULE", "ForceExitModule", "ForceExitModule", [], GAS.forceExitModule);

  console.log("[6/10] AirAccountDelegate...");
  const delegate = await deployOrReuse("AIRACCOUNT_V019_DELEGATE", "AirAccountDelegate", "AirAccountDelegate", [], GAS.delegate);

  console.log("[7/10] CalldataParserRegistry...");
  const parserRegistry = await deployOrReuse("AIRACCOUNT_V019_PARSER_REGISTRY", "CalldataParserRegistry", "CalldataParserRegistry", [], GAS.parserRegistry);

  console.log("[8/10] AAStarAirAccountV7 (impl + Extension)...");
  const impl = await deployOrReuse("AIRACCOUNT_V019_IMPL", "AAStarAirAccountV7", "AAStarAirAccountV7", [], GAS.impl);

  console.log("[9/10] AAStarAirAccountFactoryV7...");
  const factory = await deployOrReuse("AIRACCOUNT_V019_FACTORY", "AAStarAirAccountFactoryV7", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], GAS.factory);

  console.log("[10/10] AgentRegistry...");
  const agentRegistry = await deployOrReuse("AIRACCOUNT_V019_AGENT_REGISTRY", "AgentRegistry", "AgentRegistry", [], GAS.agentRegistry);

  const extension = await pub(RPC_URLS[0]).readContract({
    address: impl, abi: IMPL_EXT_ABI, functionName: "agentExtension",
  }).catch(() => "0x0000000000000000000000000000000000000000") as Address;

  console.log("\n=== Deployed ===");
  console.log(`  BLS Algorithm:   ${blsAlgorithm}`);
  console.log(`  Validator Router:${validatorRouter}`);
  console.log(`  BLS Aggregator:  ${blsAggregator}`);
  console.log(`  SessionKey:      ${sessionKeyValidator}`);
  console.log(`  ForceExit:       ${forceExitModule}`);
  console.log(`  Delegate:        ${delegate}`);
  console.log(`  Parser Registry: ${parserRegistry}`);
  console.log(`  Impl:            ${impl}`);
  console.log(`  Extension:       ${extension}`);
  console.log(`  Factory:         ${factory}`);
  console.log(`  Agent Registry:  ${agentRegistry}\n`);

  const reader = pub(RPC_URLS[0]);

  console.log("[Wire 1/6] router.registerAlgorithm(0x01, blsAlgorithm)...");
  const algBls = await reader.readContract({ address: validatorRouter, abi: ROUTER_ABI, functionName: "algorithms", args: [ALG_BLS] }) as Address;
  if (algBls.toLowerCase() === blsAlgorithm.toLowerCase()) console.log("  [skip] already registered");
  else if (algBls !== "0x0000000000000000000000000000000000000000") throw new Error(`router[0x01] already points elsewhere: ${algBls}`);
  else await callOnce("registerAlgorithm(BLS)", validatorRouter, ROUTER_ABI as unknown[], "registerAlgorithm", [ALG_BLS, blsAlgorithm], 200_000n);

  console.log("[Wire 2/6] router.registerAlgorithm(0x08, sessionKeyValidator)...");
  const algSk = await reader.readContract({ address: validatorRouter, abi: ROUTER_ABI, functionName: "algorithms", args: [ALG_SESSION_KEY] }) as Address;
  if (algSk.toLowerCase() === sessionKeyValidator.toLowerCase()) console.log("  [skip] already registered");
  else if (algSk !== "0x0000000000000000000000000000000000000000") throw new Error(`router[0x08] already points elsewhere: ${algSk}`);
  else await callOnce("registerAlgorithm(SessionKey)", validatorRouter, ROUTER_ABI as unknown[], "registerAlgorithm", [ALG_SESSION_KEY, sessionKeyValidator], 200_000n);

  console.log("[Wire 3/6] agentRegistry.bindFactory(factory)...");
  const boundFactory = await reader.readContract({ address: agentRegistry, abi: REGISTRY_ABI, functionName: "factory" }) as Address;
  if (boundFactory.toLowerCase() === factory.toLowerCase()) console.log("  [skip] already bound");
  else if (boundFactory !== "0x0000000000000000000000000000000000000000") throw new Error(`registry already bound to ${boundFactory}`);
  else await callOnce("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);

  console.log("[Wire 4/6] factory.setAgentRegistry(agentRegistry)...");
  const setReg = await reader.readContract({ address: factory, abi: FACTORY_WIRE_ABI, functionName: "agentRegistry" }) as Address;
  if (setReg.toLowerCase() === agentRegistry.toLowerCase()) console.log("  [skip] already set");
  else if (setReg !== "0x0000000000000000000000000000000000000000") throw new Error(`factory.agentRegistry already set to ${setReg}`);
  else await callOnce("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  console.log("[Wire 5/6 & 6/6] register DVT BLS node public keys...");
  for (const n of BLS_NODES) {
    const isReg = await reader.readContract({ address: blsAlgorithm, abi: BLS_ALG_ABI, functionName: "isRegistered", args: [n.nodeId] }) as boolean;
    if (isReg) { console.log(`  [skip] ${n.label} (${n.nodeId}) already registered`); continue; }
    await callOnce(`registerPublicKey(${n.label})`, blsAlgorithm, BLS_ALG_ABI as unknown[], "registerPublicKey", [n.nodeId, n.pubKey], 300_000n);
  }

  if (process.env.DEPLOY_SET_AGGREGATOR === "1") {
    console.log("[Opt] blsAlgorithm.setAggregator(blsAggregator)...");
    const cur = await reader.readContract({ address: blsAlgorithm, abi: BLS_ALG_ABI, functionName: "aggregator" }) as Address;
    if (cur.toLowerCase() === blsAggregator.toLowerCase()) console.log("  [skip] already set");
    else await callOnce("setAggregator", blsAlgorithm, BLS_ALG_ABI as unknown[], "setAggregator", [blsAggregator], 100_000n);
  } else {
    console.log("[Opt] setAggregator SKIPPED (set DEPLOY_SET_AGGREGATOR=1 to enable batch BLS path)");
  }

  if (process.env.DEPLOY_ADD_STAKE_ETH) {
    const stakeEth = process.env.DEPLOY_ADD_STAKE_ETH;
    const unstakeDelay = Number(process.env.DEPLOY_STAKE_DELAY_SEC ?? "86400");
    console.log(`[Opt] entryPoint.addStake(${unstakeDelay}s) value=${stakeEth} ETH...`);
    await callOnce("addStake", ENTRYPOINT, ENTRYPOINT_ABI as unknown[], "addStake", [unstakeDelay], 150_000n, parseEther(stakeEth));
  } else {
    console.log("[Opt] addStake SKIPPED (set DEPLOY_ADD_STAKE_ETH=<n> to stake on EntryPoint)");
  }

  console.log("\n=== v0.19 Deployment Summary — append to .env.sepolia ===");
  console.log(`AIRACCOUNT_V019_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V019_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V019_SESSION_KEY_VALIDATOR=${sessionKeyValidator}`);
  console.log(`AIRACCOUNT_V019_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V019_VALIDATOR_ROUTER=${validatorRouter}`);
  console.log(`AIRACCOUNT_V019_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V019_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V019_BLS_ALGORITHM=${blsAlgorithm}`);
  console.log(`AIRACCOUNT_V019_BLS_AGGREGATOR=${blsAggregator}`);
  console.log(`AIRACCOUNT_V019_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V019_PARSER_REGISTRY=${parserRegistry}`);
  console.log("\nDone. Verify on-chain: ACCOUNT_VERSION + FACTORY_VERSION should return '0.19.0'.");
}

main().catch((err) => { console.error(err); process.exit(1); });
