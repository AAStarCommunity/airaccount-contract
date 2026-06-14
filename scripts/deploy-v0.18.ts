/**
 * deploy-v0.18.ts — Full v0.18 Sepolia deploy (WS-A/B/C/E/G changed singletons).
 *
 * Unlike beta.4 (which only redeployed impl/factory/delegate/agentRegistry and REUSED the
 * BLS/validator/session/forceexit singletons), v0.18 changed those singletons, so this script
 * redeploys the FULL set and re-wires everything from scratch — mirroring the canonical
 * `script/DeployV0172Beta.s.sol` DAG, but in TS+viem with beta.4's send-once-then-poll robustness.
 *
 * Deploy order (DAG):
 *   1. AAStarBLSAlgorithm           (no-arg; owner = deployer; DVT node registry + setAggregator)
 *   2. AAStarValidator              (no-arg; algId → algorithm router; owner = deployer)
 *   3. AAStarBLSAggregator          (blsAlgorithm, entryPoint)
 *   4. SessionKeyValidator          (no-arg; router algId 0x08)
 *   5. ForceExitModule              (no-arg; v0.18.0)
 *   6. AirAccountDelegate           (no-arg; EIP-7702 singleton)
 *   7. CalldataParserRegistry       (no-arg; stub — parsers disabled)
 *   8. AAStarAirAccountV7 (impl)    (no-arg; its ctor also deploys the singleton AirAccountExtension)
 *   9. AAStarAirAccountFactoryV7    (impl, entryPoint, communityGuardian, defaultTokens[], defaultConfigs[])
 *  10. AgentRegistry               (no-arg; per-factory; bindFactory is set-once)
 *
 * NOT deployed (intentionally — same as the Solidity script):
 *   - EntryPoint v0.7 (canonical, already on-chain), EIP-7212 P256 precompile (0x100, chain-native),
 *   - AirAccountExtension (auto, inside V7 impl ctor),
 *   - AAStarGlobalGuard (deployed per-account by the factory on createAccount*),
 *   - RailgunParser / UniswapV3Parser (KI-14, disabled).
 *
 * Wiring (post-deploy, ordered):
 *   W1. router.registerAlgorithm(0x01, blsAlgorithm)
 *   W2. router.registerAlgorithm(0x08, sessionKeyValidator)
 *   W3. agentRegistry.bindFactory(factory)         (caller must be registry deployer)
 *   W4. factory.setAgentRegistry(agentRegistry)    (caller must be factoryAdmin)
 *   W5. blsAlgorithm.registerPublicKey(NODE_ID_1, PUBKEY_1)  (DVT dev node 1)
 *   W6. blsAlgorithm.registerPublicKey(NODE_ID_2, PUBKEY_2)  (DVT dev node 2)
 *
 * Opt-in post-deploy ops (FLAGS — off by default; do them manually or via env after review):
 *   - DEPLOY_SET_AGGREGATOR=1  → blsAlgorithm.setAggregator(blsAggregator) (enables batch BLS path)
 *   - DEPLOY_ADD_STAKE_ETH=<n> → entryPoint.addStake on the BLS aggregator (ERC-4337 staking)
 *   - transferOwnership of AAStarBLSAlgorithm to a protocol Safe — NOT done here. On Sepolia testnet
 *     there is no Safe; owner stays the deployer EOA. (Mainnet GA: two-step transfer to the Safe.)
 *
 * IDEMPOTENT-ish: every AIRACCOUNT_V018_* env var that is already set is REUSED (skip-deploy).
 * Within a single run nothing is deployed twice. Wiring calls are guarded by an on-chain read
 * (algorithms[id] / agentRegistry / factory / isRegistered) so a re-run does not re-send a
 * set-once tx that would revert.
 *
 * THIS SCRIPT DOES NOT BROADCAST UNLESS RUN. Build/dry-validate is in deploy-v0.18.check.ts.
 *
 * Usage: pnpm tsx scripts/deploy-v0.18.ts
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

// algId constants (mirror AAStarAirAccountBase). Only externally-routed algs need router registration;
// 0x02 (ECDSA) / 0x03 (P256) are inlined in the account and are NOT router-registered.
const ALG_BLS = 0x01;
const ALG_SESSION_KEY = 0x08;

// ── Priority fee (adaptive: max(network-suggested, floor); env-overridable) ──
const PRIORITY_FEE_FLOOR = 1_500_000_000n; // 1.5 gwei
const PRIORITY_FEE_OVERRIDE = process.env.DEPLOY_PRIORITY_FEE_GWEI
  ? BigInt(Math.round(Number(process.env.DEPLOY_PRIORITY_FEE_GWEI) * 1e9))
  : 0n;

// Same deployer resolution as beta.4: PRIVATE_KEY_ANNI first, else PRIVATE_KEY.
const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

// Canonical DVT dev node keys (BLS E2E node set — see test-e2e-bls.ts). Registered into
// AAStarBLSAlgorithm so Tier 2/3 cumulative signatures resolve on the new singleton.
const BLS_NODES: { nodeId: Hex; pubKey: Hex; label: string }[] = [
  {
    nodeId: process.env.BLS_TEST_NODE_ID_1 as Hex,
    pubKey: process.env.BLS_TEST_PUBLIC_KEY_1 as Hex,
    label: "Node1",
  },
  {
    nodeId: process.env.BLS_TEST_NODE_ID_2 as Hex,
    pubKey: process.env.BLS_TEST_PUBLIC_KEY_2 as Hex,
    label: "Node2",
  },
];

const deployer = privateKeyToAccount(PRIVATE_KEY);

// ── Minimal ABIs for wiring + reads ──
const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable",
    inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "algorithms", type: "function", stateMutability: "view",
    inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
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
  { name: "registerPublicKey", type: "function", stateMutability: "nonpayable",
    inputs: [{ type: "bytes32" }, { type: "bytes" }], outputs: [] },
  { name: "isRegistered", type: "function", stateMutability: "view",
    inputs: [{ type: "bytes32" }], outputs: [{ type: "bool" }] },
  { name: "setAggregator", type: "function", stateMutability: "nonpayable",
    inputs: [{ type: "address" }], outputs: [] },
  { name: "aggregator", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;
const ENTRYPOINT_ABI = [
  { name: "addStake", type: "function", stateMutability: "payable",
    inputs: [{ type: "uint32" }], outputs: [] },
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

/** Poll the receipt across ALL RPCs without ever re-sending the tx (beta.4 robustness). */
async function waitReceiptAnyRpc(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  for (let attempt = 0; attempt < 90; attempt++) { // ~7.5 min
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

/** Reuse an env-supplied address if set (skip-if-set idempotence), else deploy. */
async function deployOrReuse(envKey: string, label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const existing = process.env[envKey];
  if (existing && /^0x[0-9a-fA-F]{40}$/.test(existing)) {
    console.log(`  [reuse] ${label} = ${existing} (from ${envKey})`);
    return getAddress(existing as Address);
  }
  return deployOnce(label, artifactName, args, gas);
}

// Per-contract creation-gas budgets (generous; from --sizes initcode + a buffer).
const GAS = {
  blsAlgorithm: 2_000_000n,
  validatorRouter: 600_000n,
  blsAggregator: 1_100_000n,
  sessionKeyValidator: 2_800_000n,
  forceExitModule: 1_500_000n,
  delegate: 3_000_000n,
  parserRegistry: 300_000n,
  impl: 10_000_000n,      // impl ctor also deploys AirAccountExtension
  factory: 6_000_000n,
  agentRegistry: 1_500_000n,
};

/** DRY-CHECK: encode every deploy's calldata against its artifact ABI (throws on ctor mismatch),
 *  print the deployer balance + cost estimate, confirm no tx is sent. */
async function dryCheck() {
  console.log("=== DRY-CHECK (no broadcast) — v0.18 deploy ===");
  console.log(`Deployer: ${deployer.address}`);

  const PLACEHOLDER = "0x000000000000000000000000000000000000dEaD" as Address;
  // [envKey, label, artifact, ctor args] — placeholders for cross-contract addrs (dry-only).
  const specs: [string, string, unknown[]][] = [
    ["AAStarBLSAlgorithm", "AAStarBLSAlgorithm", []],
    ["AAStarValidator", "AAStarValidator", []],
    ["AAStarBLSAggregator", "AAStarBLSAggregator", [PLACEHOLDER, ENTRYPOINT]],
    ["SessionKeyValidator", "SessionKeyValidator", []],
    ["ForceExitModule", "ForceExitModule", []],
    ["AirAccountDelegate", "AirAccountDelegate", []],
    ["CalldataParserRegistry", "CalldataParserRegistry", []],
    ["AAStarAirAccountV7", "AAStarAirAccountV7", []],
    ["AAStarAirAccountFactoryV7", "AAStarAirAccountFactoryV7", [PLACEHOLDER, ENTRYPOINT, COMMUNITY ?? PLACEHOLDER, [], []]],
    ["AgentRegistry", "AgentRegistry", []],
  ];
  let ok = 0;
  for (const [label, artifact, args] of specs) {
    const art = loadArtifact(artifact);
    // encodeDeployData throws on arity / type mismatch vs the artifact's constructor ABI.
    encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args });
    console.log(`  ok: ${label.padEnd(28)} ctor args=${JSON.stringify(args.map(a => Array.isArray(a) ? "[]" : String(a)))}`);
    ok++;
  }
  console.log(`\nAll ${ok} ctor-arg arrays match their artifact ABIs.`);

  if (RPC_URLS.length > 0) {
    const bal = await pub(RPC_URLS[0]).getBalance({ address: deployer.address });
    const { maxFeePerGas } = await fees();
    const totalGasBudget = Object.values(GAS).reduce((a, b) => a + b, 0n);
    console.log(`\nBalance:     ${formatEther(bal)} ETH`);
    console.log(`Gas budget:  ${totalGasBudget} gas (sum of creation caps; actual far lower)`);
    console.log(`maxFeePerGas:${maxFeePerGas} wei`);
    console.log(`Worst-case:  ~${formatEther(totalGasBudget * maxFeePerGas)} ETH`);
    console.log(`Sufficient:  ${bal >= parseEther("0.05") ? "YES (>0.05 ETH floor)" : "NO — fund first"}`);
  }
  console.log("\nDRY-CHECK complete — NO transaction was sent.");
}

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

  // DRY-CHECK mode (no broadcast): validate every ctor-arg array against its artifact ABI by
  // encoding the deploy calldata (encodeDeployData throws on a type/arity mismatch), confirm the
  // deployer balance, then exit 0. Used by the build/dry-validate gate. Enable with DEPLOY_DRY_CHECK=1.
  if (process.env.DEPLOY_DRY_CHECK === "1") { await dryCheck(); return; }

  console.log("=== Deploy AirAccount v0.18 (Sepolia) ===");
  console.log(`Deployer:   ${deployer.address}`);
  console.log(`Community:  ${COMMUNITY}`);
  console.log(`EntryPoint: ${ENTRYPOINT}\n`);

  const bal = await pub(RPC_URLS[0]).getBalance({ address: deployer.address });
  console.log(`Balance:    ${formatEther(bal)} ETH`);

  // Early abort if balance is clearly insufficient. Total creation gas ≈ 28.8M (sum of GAS budgets,
  // excluding addStake value). At a generous 30 gwei effective price that's ≈ 0.87 ETH; require 0.05
  // ETH as a hard floor (deploy gas budgets are over-provisioned; actual usage is far lower — the
  // beta.4 full set used well under 0.05 ETH at typical Sepolia base fees).
  const MIN_BALANCE = parseEther("0.05");
  if (bal < MIN_BALANCE) {
    console.error(`ERROR: balance ${formatEther(bal)} ETH below 0.05 ETH floor — fund the deployer first.`);
    process.exit(1);
  }

  // Adaptive cost estimate (informational): sum(GAS budgets) × current maxFeePerGas.
  const totalGasBudget = Object.values(GAS).reduce((a, b) => a + b, 0n);
  const { maxFeePerGas } = await fees();
  const worstCaseCost = totalGasBudget * maxFeePerGas;
  console.log(`Gas budget (sum of creation caps): ${totalGasBudget} gas`);
  console.log(`Worst-case cost @ maxFeePerGas ${maxFeePerGas} wei: ~${formatEther(worstCaseCost)} ETH`);
  console.log(`(Actual usage is far lower — caps are over-provisioned.)\n`);

  // ── Deploys (DAG order) ──────────────────────────────────────────────
  console.log("[1/10] AAStarBLSAlgorithm...");
  const blsAlgorithm = await deployOrReuse("AIRACCOUNT_V018_BLS_ALGORITHM", "AAStarBLSAlgorithm", "AAStarBLSAlgorithm", [], GAS.blsAlgorithm);

  console.log("[2/10] AAStarValidator (router)...");
  const validatorRouter = await deployOrReuse("AIRACCOUNT_V018_VALIDATOR_ROUTER", "AAStarValidator", "AAStarValidator", [], GAS.validatorRouter);

  console.log("[3/10] AAStarBLSAggregator(blsAlgorithm, entryPoint)...");
  const blsAggregator = await deployOrReuse("AIRACCOUNT_V018_BLS_AGGREGATOR", "AAStarBLSAggregator", "AAStarBLSAggregator", [blsAlgorithm, ENTRYPOINT], GAS.blsAggregator);

  console.log("[4/10] SessionKeyValidator...");
  const sessionKeyValidator = await deployOrReuse("AIRACCOUNT_V018_SESSION_KEY_VALIDATOR", "SessionKeyValidator", "SessionKeyValidator", [], GAS.sessionKeyValidator);

  console.log("[5/10] ForceExitModule...");
  const forceExitModule = await deployOrReuse("AIRACCOUNT_V018_FORCE_EXIT_MODULE", "ForceExitModule", "ForceExitModule", [], GAS.forceExitModule);

  console.log("[6/10] AirAccountDelegate...");
  const delegate = await deployOrReuse("AIRACCOUNT_V018_DELEGATE", "AirAccountDelegate", "AirAccountDelegate", [], GAS.delegate);

  console.log("[7/10] CalldataParserRegistry...");
  const parserRegistry = await deployOrReuse("AIRACCOUNT_V018_PARSER_REGISTRY", "CalldataParserRegistry", "CalldataParserRegistry", [], GAS.parserRegistry);

  console.log("[8/10] AAStarAirAccountV7 (impl + Extension)...");
  const impl = await deployOrReuse("AIRACCOUNT_V018_IMPL", "AAStarAirAccountV7", "AAStarAirAccountV7", [], GAS.impl);

  console.log("[9/10] AAStarAirAccountFactoryV7(impl, entryPoint, community, [], [])...");
  const factory = await deployOrReuse("AIRACCOUNT_V018_FACTORY", "AAStarAirAccountFactoryV7", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], GAS.factory);

  console.log("[10/10] AgentRegistry...");
  const agentRegistry = await deployOrReuse("AIRACCOUNT_V018_AGENT_REGISTRY", "AgentRegistry", "AgentRegistry", [], GAS.agentRegistry);

  // Resolve the auto-deployed AirAccountExtension off the impl.
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

  // ── Wiring (guarded reads make each call safe to re-run) ─────────────
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

  // ── Opt-in post-deploy ops (flag-gated; off by default) ──────────────
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
    const unstakeDelay = Number(process.env.DEPLOY_STAKE_DELAY_SEC ?? "86400"); // 1 day default
    console.log(`[Opt] entryPoint.addStake(${unstakeDelay}s) value=${stakeEth} ETH for aggregator...`);
    // NOTE: addStake stakes the CALLER (deployer EOA) on the EntryPoint, not the aggregator. For the
    // aggregator to be staked it must call addStake itself; the aggregator exposes no such path here,
    // so this stakes the deployer. Left as a flag for the operator to decide — typically not needed
    // on Sepolia. Review before enabling.
    await callOnce("addStake", ENTRYPOINT, ENTRYPOINT_ABI as unknown[], "addStake", [unstakeDelay], 150_000n, parseEther(stakeEth));
  } else {
    console.log("[Opt] addStake SKIPPED (set DEPLOY_ADD_STAKE_ETH=<n> to stake on EntryPoint)");
  }

  // ── Final .env.sepolia block (keys WS-F E2E scripts 13-16 read via common-v018.ts) ──
  console.log("\n=== v0.18 Deployment Summary — append to .env.sepolia ===");
  console.log(`AIRACCOUNT_V018_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V018_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V018_SESSION_KEY_VALIDATOR=${sessionKeyValidator}`);
  console.log(`AIRACCOUNT_V018_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V018_VALIDATOR_ROUTER=${validatorRouter}`);
  console.log(`AIRACCOUNT_V018_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V018_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V018_BLS_ALGORITHM=${blsAlgorithm}`);
  console.log(`AIRACCOUNT_V018_BLS_AGGREGATOR=${blsAggregator}`);
  console.log(`AIRACCOUNT_V018_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V018_PARSER_REGISTRY=${parserRegistry}`);
  console.log("\nDone. Owner of AAStarBLSAlgorithm + AAStarValidator = deployer EOA (no Safe on testnet).");
  console.log("Mainnet GA TODO: two-step transferOwnership(blsAlgorithm) to the protocol Safe after key registration.");
}

main().catch((err) => { console.error(err); process.exit(1); });
