/**
 * deploy-v0.24.0.ts — Deploy for v0.24.0 (security-hardening batch).
 *
 * What changed vs v0.23.0 (5 hardening fixes):
 *   - [c] Factory folds guardian1+guardian2 into the createAccountWithDefaults CREATE2 salt.
 *   - [b] AirAccountExtension weight-config subset invariant + _isWeakening direction fix.
 *   - [d] AAStarAirAccountV7 executeFromExecutor rejects self-call (SelfCallForbidden);
 *         SessionKeyValidator.checkSessionScope rejects dest == account.
 *   - [M-C] AAStarAirAccountBase validateUserOp uses tryRecover (revert-free) + owner==0 guard.
 *   - ACCOUNT_VERSION / FACTORY_VERSION bumped to "0.24.0".
 *
 * IMPORTANT (fix d): SessionKeyValidator bytecode changed, and the account resolves it via
 * `router.getAlgorithm(0x08)`. The AAStarValidator router is SET-ONCE per algId, so the v0.23.0
 * router's 0x08 cannot be repointed. Therefore v0.24.0 deploys a NEW SessionKeyValidator AND a NEW
 * router (registering 0x01 → reused BLS algorithm, 0x08 → new SessionKeyValidator, then finalizing),
 * and bakes the new router into the new impl. Existing accounts (old impl/router) are unaffected —
 * non-upgradable, only new accounts get the fixes.
 *
 * Reused from v0.23.0 (unchanged bytecode):
 *   AAStarBLSAlgorithm (+ its Safe-set aggregator), ForceExitModule, AirAccountDelegate,
 *   CalldataParserRegistry
 *
 * Deployed fresh:
 *   SessionKeyValidator (fix d), AAStarValidator (router), AAStarAirAccountV7 (impl, new Extension +
 *   version bump), AAStarAirAccountFactoryV7 (factory), AgentRegistry
 *
 * Router setup: registerAlgorithm(0x01, blsAlgorithm), registerAlgorithm(0x08, sessionKeyValidator),
 * finalizeSetup().  Wiring: agentRegistry.bindFactory(factory); factory.setAgentRegistry(agentRegistry).
 *
 * Output env keys: AIRACCOUNT_V0240_*
 *
 * Usage: pnpm tsx scripts/deploy-v0.24.0.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  getAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const TARGET_VERSION = "0.24.0";

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;

const RPC_URLS = [
  process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3,
].filter(Boolean) as string[];

// ── Reused v0.23.0 singletons (unchanged bytecode) ───────────────────────────
function v0230(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0230_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0230_${key} not set in .env.sepolia — run deploy-v0.23.0.ts first`);
  return getAddress(v);
}

const deployer = privateKeyToAccount(PRIVATE_KEY);

const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "finalizeSetup",     type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "getAlgorithm",      type: "function", stateMutability: "view",       inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const REGISTRY_ABI = [
  { name: "bindFactory",  type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "factory",      type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "agentRegistry",    type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const IMPL_EXT_ABI = [
  { name: "agentExtension",  type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "validatorRouter", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "ACCOUNT_VERSION", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: a.bytecode.object as Hex };
}
function pub(url: string) { return createPublicClient({ chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }
function wal(url: string) { return createWalletClient({ account: deployer, chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }

async function fees() {
  const block = await pub(RPC_URLS[0]).getBlock();
  const base  = block.baseFeePerGas ?? 10_000_000_000n;
  let tip = PRIORITY_FEE_FLOOR;
  try { tip = await pub(RPC_URLS[0]).estimateMaxPriorityFeePerGas(); } catch { /**/ }
  const priority = tip < PRIORITY_FEE_FLOOR ? PRIORITY_FEE_FLOOR : tip;
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}

async function waitReceipt(hash: Hex, label: string) {
  console.log(`  TX(${label}): https://sepolia.etherscan.io/tx/${hash}`);
  for (let i = 0; i < 90; i++) {
    for (const url of RPC_URLS) {
      try {
        const r = await pub(url).getTransactionReceipt({ hash });
        if (r) {
          if (r.status !== "success") throw new Error(`${label} reverted`);
          console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`);
          return r;
        }
      } catch (e: any) { if (String(e.message).includes("reverted")) throw e; }
    }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`${label}: timeout — check ${hash}`);
}

async function deploy(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f   = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }),
    gas, ...f,
  });
  const r = await waitReceipt(hash, label);
  return getAddress(r.contractAddress!);
}

async function call(label: string, to: Address, abi: unknown[], fn: string, args: unknown[], gas: bigint) {
  const f    = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({
    to, data: encodeFunctionData({ abi, functionName: fn, args } as any), gas, ...f,
  });
  await waitReceipt(hash, label);
}

async function main() {
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY or PRIVATE_KEY_ANNI not set");
  if (!COMMUNITY)   throw new Error("COMMUNITY_GUARDIAN_ADDRESS not set");
  console.log(`\n=== v0.24.0 deploy — Sepolia (security hardening) ===`);
  console.log(`Deployer: ${deployer.address}\n`);

  // ── Reused v0.23.0 singletons ──────────────────────────────────────────────
  const blsAlgorithm   = v0230("BLS_ALGORITHM");
  const blsAggregator  = v0230("BLS_AGGREGATOR");
  const forceExitModule = v0230("FORCE_EXIT_MODULE");
  const delegate       = v0230("DELEGATE");
  const parserRegistry = v0230("PARSER_REGISTRY");
  console.log("Reusing v0.23.0 singletons:");
  console.log(`  BLS Algorithm:   ${blsAlgorithm}`);
  console.log(`  BLS Aggregator:  ${blsAggregator}`);
  console.log(`  ForceExitModule: ${forceExitModule}`);
  console.log(`  Delegate:        ${delegate}`);
  console.log(`  ParserRegistry:  ${parserRegistry}\n`);

  const reader = pub(RPC_URLS[0]);

  // ── [1] SessionKeyValidator (fix d) ─────────────────────────────────────────
  console.log("[1/5] SessionKeyValidator (fix d — dest==account rejected)...");
  const sessionKeyValidator = await deploy("sessionKeyValidator", "SessionKeyValidator", [], 2_500_000n);
  console.log(`  SessionKeyValidator: ${sessionKeyValidator}`);

  // ── [2] AAStarValidator router (new — 0x08 set-once forces a fresh router) ───
  console.log("\n[2/5] AAStarValidator router (fresh)...");
  const router = await deploy("router", "AAStarValidator", [], 1_500_000n);
  console.log(`  Router: ${router}`);
  console.log("  register 0x01 → reused BLS algorithm...");
  await call("register-0x01", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x01, blsAlgorithm], 150_000n);
  console.log("  register 0x08 → new SessionKeyValidator...");
  await call("register-0x08", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x08, sessionKeyValidator], 150_000n);
  console.log("  finalizeSetup (lock direct registration)...");
  await call("finalizeSetup", router, ROUTER_ABI as unknown[], "finalizeSetup", [], 100_000n);
  // Verify registrations
  const r01 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
  const r08 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x08] }) as Address;
  if (r01.toLowerCase() !== blsAlgorithm.toLowerCase()) throw new Error(`router 0x01 mismatch: ${r01}`);
  if (r08.toLowerCase() !== sessionKeyValidator.toLowerCase()) throw new Error(`router 0x08 mismatch: ${r08}`);
  console.log(`  router 0x01=${r01} 0x08=${r08} ✓`);

  // ── [3] impl (new router baked in as immutable) ─────────────────────────────
  console.log("\n[3/5] AAStarAirAccountV7 (impl, validatorRouter = new router)...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [router], 15_000_000n);
  const extension = await reader.readContract({ address: impl, abi: IMPL_EXT_ABI, functionName: "agentExtension" }) as Address;
  const wiredRouter = await reader.readContract({ address: impl, abi: IMPL_EXT_ABI, functionName: "validatorRouter" }) as Address;
  console.log(`  Impl:            ${impl}`);
  console.log(`  Extension:       ${extension}`);
  console.log(`  validatorRouter: ${wiredRouter}`);
  if (wiredRouter.toLowerCase() !== router.toLowerCase()) throw new Error(`validatorRouter mismatch on impl: ${wiredRouter}`);

  // ── [4] factory (→ new impl) ────────────────────────────────────────────────
  console.log("\n[4/5] AAStarAirAccountFactoryV7 (→ new impl)...");
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // ── [5] AgentRegistry (fresh — bindFactory is set-once) ─────────────────────
  console.log("\n[5/5] AgentRegistry (fresh)...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 1_500_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);

  // ── Wiring ────────────────────────────────────────────────────────────────────
  console.log("\n[Wire 1/2] agentRegistry.bindFactory(factory)...");
  const bound = await reader.readContract({ address: agentRegistry, abi: REGISTRY_ABI, functionName: "factory" }) as Address;
  if (bound.toLowerCase() === factory.toLowerCase()) console.log("  [skip] already bound");
  else await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);

  console.log("[Wire 2/2] factory.setAgentRegistry(agentRegistry)...");
  const setReg = await reader.readContract({ address: factory, abi: FACTORY_WIRE_ABI, functionName: "agentRegistry" }) as Address;
  if (setReg.toLowerCase() === agentRegistry.toLowerCase()) console.log("  [skip] already set");
  else await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  // ── On-chain version verification ─────────────────────────────────────────────
  console.log("\n[Verify] ACCOUNT_VERSION on-chain...");
  const ver = await reader.readContract({ address: impl, abi: IMPL_EXT_ABI, functionName: "ACCOUNT_VERSION" });
  console.log(`  ACCOUNT_VERSION = "${ver}"`);
  if (ver !== TARGET_VERSION) throw new Error(`Version mismatch: expected "${TARGET_VERSION}", got "${ver}"`);
  console.log(`  v${TARGET_VERSION} confirmed\n`);

  // ── Summary ───────────────────────────────────────────────────────────────────
  console.log("=== v0.24.0 Deployment Complete ===");
  console.log("Append to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0240_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0240_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0240_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0240_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0240_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0240_SESSION_KEY_VALIDATOR=${sessionKeyValidator}`);
  console.log(`AIRACCOUNT_V0240_BLS_ALGORITHM=${blsAlgorithm}`);
  console.log(`AIRACCOUNT_V0240_BLS_AGGREGATOR=${blsAggregator}`);
  console.log(`AIRACCOUNT_V0240_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0240_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0240_PARSER_REGISTRY=${parserRegistry}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
