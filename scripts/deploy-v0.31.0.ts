/**
 * deploy-v0.31.0.ts — Deploy for v0.31.0 (CC-102 weighted-governance hardening + CC-98 account-side
 * per-proposal committee BLS integration). Fresh non-upgradable stack (router is set-once + finalized →
 * new router+impl+factory required).
 *
 * v0.31.0 vs v0.29.0 (v0.30.0 was merged but never deployed — main jumped 0.29.0-deployed → 0.31.0):
 *   - CC-102: weighted-governance hardening (addGuardian timelock incl P256 twin, F-W6/8/9/11).
 *   - CC-98:  committee BLS framing (accountId injection + committeeActive mode-gating + requiredQuorum
 *             mirror + enrollInCommitteeValidator), heavy framing externalized to CommitteeBLSLib.
 *
 * Deploys:
 *   [0] WebAuthnLib + CommitteeBLSLib (external libs) → registered in LIBRARIES + linked into impl/extension
 *   [1] AAStarValidator router → 0x01 = DVT COMMITTEE validator, 0x08 = reused SessionKeyValidator, finalize
 *   [2] AAStarAirAccountV7 impl (router baked in, both libs linked) → fresh AirAccountExtension
 *   [3] AAStarAirAccountFactoryV7
 *   [4] AgentRegistry → bindFactory + setAgentRegistry
 *
 * Reused from v0.29.0 (AIRACCOUNT_V0290_*): SessionKeyValidator, ForceExitModule, Delegate, ParserRegistry.
 *
 * ── DEPLOY LANDMINE (#149 + CC-98): WebAuthnLib AND CommitteeBLSLib MUST be deployed + registered in
 *    LIBRARIES BEFORE the impl artifact is loaded. linkBytecode fails CLOSED on any residual `__$…$__`
 *    placeholder, so a partially-linked (broken) account can never be sent on-chain.
 *
 * ── COMMITTEE VALIDATOR: mounted at algId 0x01 of the NEW v0.31.0 router (a fresh set-once router). This
 *    does NOT edit the v0.29.0 production router — that stack (router + whole-set validator 0x539B +
 *    production nodes) is untouched and its accounts keep running. v0.31.0 is a parallel new stack.
 *    Address = dvt AAStarCommitteeValidator (#237), 0x1A8Db639b5d8Bd5742edB083656EDD56f416cd64 — set via
 *    env DVT_COMMITTEE_VALIDATOR. Confirmed on Seeder f7810089 (address + keeper #238 + interlock).
 *
 * ── EMPTY-VALIDATOR GUARD (dvt catch): the committee validator must have registered DVT nodes BEFORE
 *    mount — an empty validator (getRegisteredNodeCount()==0) breaks LEGACY whole-set too (no nodes to
 *    verify against → every tier-2/3 op fails), not just committee. This script throws if it is empty.
 *    Rollout: dvt registers >=3 DVT nodes on 0x1A8Db639 → THEN run this deploy.
 *
 * ── MIGRATION ORDER (non-upgradable, committee mode OFF at deploy): this deploys the stack with the
 *    committee validator mounted but committeeActive() still false (validator epochLength==0) → the
 *    account runs LEGACY whole-set framing byte-identically. Per account: call
 *    enrollInCommitteeValidator() after creation. ONLY AFTER accounts are enrolled does dvt/owner(Safe)
 *    flip the validator's setEpochLength to turn committee mode on. dvt must NOT flip first.
 *
 * Output env keys: AIRACCOUNT_V0310_*
 * Usage: pnpm tsx scripts/deploy-v0.31.0.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  getAddress, keccak256, stringToBytes, isAddress, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const TARGET_VERSION = "0.31.0";

// CC-98: DVT per-proposal COMMITTEE validator (YetAnotherAA-Validator AAStarCommitteeValidator #237),
// mounted at algId 0x01 of the NEW v0.31.0 router (fresh set-once router; v0.29.0 router + 0x539B are
// untouched — parallel stacks). 0x1A8Db639b5d8Bd5742edB083656EDD56f416cd64; set via env
// DVT_COMMITTEE_VALIDATOR (confirmed on Seeder f7810089). Must have registered nodes before mount (guard below).
const DVT_COMMITTEE_VALIDATOR = (process.env.DVT_COMMITTEE_VALIDATOR ?? "") as string;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3].filter(Boolean) as string[];

function v0290(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0290_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0290_${key} not set — v0.31.0 reuses v0.29.0 peripherals`);
  return getAddress(v);
}
const deployer = privateKeyToAccount(PRIVATE_KEY);

// Deployed external-library addresses (fully-qualified name → address). Populated at runtime AFTER each
// library is deployed and BEFORE the impl artifact is loaded.
const LIBRARIES: Record<string, Address> = {};

// Resolve Solidity external-library link placeholders (`__$<34-hex>$__`) in creation bytecode. The impl
// embeds the extension's creation code, so BOTH libraries' references live in the impl's bytecode and are
// patched here. Fails CLOSED: an unregistered library or any residual `__$` placeholder throws.
function linkBytecode(name: string, bytecode: string, linkRefs: Record<string, Record<string, unknown>> | undefined): Hex {
  let out = bytecode;
  for (const [file, libs] of Object.entries(linkRefs ?? {})) {
    for (const lib of Object.keys(libs)) {
      const fq = `${file}:${lib}`;
      const addr = LIBRARIES[fq];
      if (!addr) throw new Error(`${name}: unlinked library ${fq} — deploy it and register in LIBRARIES first`);
      const placeholder = "__$" + keccak256(stringToBytes(fq)).slice(2, 36) + "$__";
      out = out.split(placeholder).join(getAddress(addr).slice(2).toLowerCase());
    }
  }
  if (out.includes("__$")) throw new Error(`${name}: residual unlinked library placeholder after linking`);
  return out as Hex;
}

const ROUTER_ABI = [
  { name: "registerAlgorithm", type: "function", stateMutability: "nonpayable", inputs: [{ type: "uint8" }, { type: "address" }], outputs: [] },
  { name: "finalizeSetup",     type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "getAlgorithm",      type: "function", stateMutability: "view",       inputs: [{ type: "uint8" }], outputs: [{ type: "address" }] },
] as const;
const REGISTRY_ABI = [
  { name: "bindFactory", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "factory",     type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const FACTORY_WIRE_ABI = [
  { name: "setAgentRegistry", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }], outputs: [] },
  { name: "agentRegistry",    type: "function", stateMutability: "view",        inputs: [],                   outputs: [{ type: "address" }] },
] as const;
const IMPL_ABI = [
  { name: "agentExtension",  type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "validatorRouter", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "ACCOUNT_VERSION", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;
// Committee validator sanity: committeeActive() (mode-gating) + getRegisteredNodeCount() (empty-validator
// guard — an empty validator breaks legacy whole-set too, per dvt on f7810089).
const COMMITTEE_ABI = [
  { name: "committeeActive",       type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "getRegisteredNodeCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

function loadArtifact(name: string) {
  const a = JSON.parse(readFileSync(resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`), "utf-8"));
  return { abi: a.abi as unknown[], bytecode: linkBytecode(name, a.bytecode.object as string, a.bytecode.linkReferences) };
}
function pub(url: string) { return createPublicClient({ chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }
function wal(url: string) { return createWalletClient({ account: deployer, chain: sepolia, transport: http(url, { timeout: 60_000 }) }); }

async function fees() {
  const block = await pub(RPC_URLS[0]).getBlock();
  const base = block.baseFeePerGas ?? 10_000_000_000n;
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
        if (r) { if (r.status !== "success") throw new Error(`${label} reverted`); console.log(`  Gas: ${r.gasUsed}  Block: ${r.blockNumber}`); return r; }
      } catch (e: any) { if (String(e.message).includes("reverted")) throw e; }
    }
    await new Promise(r => setTimeout(r, 5_000));
  }
  throw new Error(`${label}: timeout — check ${hash}`);
}
async function deploy(label: string, artifactName: string, args: unknown[], gas: bigint): Promise<Address> {
  const art = loadArtifact(artifactName);
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({ data: encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args }), gas, ...f });
  return getAddress((await waitReceipt(hash, label)).contractAddress!);
}
async function call(label: string, to: Address, abi: unknown[], fn: string, args: unknown[], gas: bigint) {
  const f = await fees();
  const hash = await wal(RPC_URLS[0]).sendTransaction({ to, data: encodeFunctionData({ abi, functionName: fn, args } as any), gas, ...f });
  await waitReceipt(hash, label);
}

async function main() {
  if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY not set");
  if (!COMMUNITY) throw new Error("COMMUNITY_GUARDIAN_ADDRESS not set");
  if (!isAddress(DVT_COMMITTEE_VALIDATOR)) {
    throw new Error(
      "DVT_COMMITTEE_VALIDATOR not set to a valid address. Set the FULL checksum of the dvt " +
      "AAStarCommitteeValidator (#237, ~0x1A8Db639…) — pending dvt confirmation on Seeder f7810089.",
    );
  }
  const committeeValidator = getAddress(DVT_COMMITTEE_VALIDATOR);
  console.log(`\n=== v0.31.0 deploy — Sepolia (CC-102 gov hardening + CC-98 committee BLS) ===`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Committee validator (algId 0x01): ${committeeValidator}\n`);

  const sessionValidator = v0290("SESSION_KEY_VALIDATOR");
  const forceExitModule  = v0290("FORCE_EXIT_MODULE");
  const delegate         = v0290("DELEGATE");
  const parserRegistry   = v0290("PARSER_REGISTRY");
  const reader = pub(RPC_URLS[0]);

  // Sanity: committee validator is deployed + exposes committeeActive() (so mode-gating is real).
  const cvCode = await reader.getBytecode({ address: committeeValidator });
  if (!cvCode || cvCode.length <= 2) throw new Error(`committee validator ${committeeValidator} has no code`);
  const activeAtDeploy = await reader.readContract({ address: committeeValidator, abi: COMMITTEE_ABI, functionName: "committeeActive" }) as boolean;
  const nodeCount = await reader.readContract({ address: committeeValidator, abi: COMMITTEE_ABI, functionName: "getRegisteredNodeCount" }) as bigint;
  console.log(`Committee validator code: ${cvCode.length / 2 - 1} bytes ✓  committeeActive()=${activeAtDeploy}  registeredNodes=${nodeCount}`);
  // EMPTY-VALIDATOR GUARD (dvt catch, f7810089): mounting an empty validator breaks legacy whole-set too —
  // every tier-2/3 op on the new stack would fail. dvt must register >=3 DVT nodes on it before deploy.
  if (nodeCount === 0n) {
    throw new Error(
      `Committee validator ${committeeValidator} has 0 registered nodes — mounting it would break legacy ` +
      `tier-2/3 too. dvt must register the DVT node set first (Seeder f7810089), then re-run.`,
    );
  }
  if (activeAtDeploy) {
    console.warn("  ⚠️  committeeActive() is ALREADY true — migration interlock says the account must be " +
      "deployed + enrolled BEFORE committee mode is flipped on. Confirm with dvt (f7810089) before proceeding.");
  }

  // [0] External libraries — MUST deploy + register BEFORE the impl is loaded (impl+extension link BOTH).
  console.log("\n[0/4] External libraries (WebAuthnLib + CommitteeBLSLib)...");
  const webAuthnLib = await deploy("webAuthnLib", "WebAuthnLib", [], 1_500_000n);
  LIBRARIES["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  console.log(`  WebAuthnLib: ${webAuthnLib}`);
  const committeeLib = await deploy("committeeBLSLib", "CommitteeBLSLib", [], 1_500_000n);
  LIBRARIES["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = committeeLib;
  console.log(`  CommitteeBLSLib: ${committeeLib}`);

  // [1] new router → 0x01 = committee validator, 0x08 = reused session validator, finalize
  console.log("\n[1/4] AAStarValidator router (0x01→committee, 0x08→session)...");
  const router = await deploy("router", "AAStarValidator", [], 2_000_000n);
  console.log(`  Router: ${router}`);
  await call("register-0x01-committee", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x01, committeeValidator], 150_000n);
  await call("register-0x08-session", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x08, sessionValidator], 150_000n);
  await call("finalizeSetup", router, ROUTER_ABI as unknown[], "finalizeSetup", [], 100_000n);
  const r01 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
  const r08 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x08] }) as Address;
  if (r01.toLowerCase() !== committeeValidator.toLowerCase()) throw new Error(`router 0x01 mismatch: ${r01}`);
  if (r08.toLowerCase() !== sessionValidator.toLowerCase()) throw new Error(`router 0x08 mismatch: ${r08}`);
  console.log(`  router 0x01=${r01} (committee) 0x08=${r08} (session) ✓`);

  // [2] new impl (WebAuthnLib + CommitteeBLSLib linked via loadArtifact)
  console.log("\n[2/4] AAStarAirAccountV7 (impl, new router, both libs linked)...");
  const impl = await deploy("impl", "AAStarAirAccountV7", [router], 15_000_000n);
  const extension = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "agentExtension" }) as Address;
  const wiredRouter = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "validatorRouter" }) as Address;
  console.log(`  Impl: ${impl}\n  Extension: ${extension}\n  validatorRouter: ${wiredRouter}`);
  if (wiredRouter.toLowerCase() !== router.toLowerCase()) throw new Error(`validatorRouter mismatch: ${wiredRouter}`);

  // [3] new factory
  console.log("\n[3/4] AAStarAirAccountFactoryV7...");
  const factory = await deploy("factory", "AAStarAirAccountFactoryV7", [impl, ENTRYPOINT, COMMUNITY, [], []], 6_000_000n);
  console.log(`  Factory: ${factory}`);

  // [4] fresh AgentRegistry + wiring
  console.log("\n[4/4] AgentRegistry (fresh)...");
  const agentRegistry = await deploy("agentRegistry", "AgentRegistry", [], 2_000_000n);
  console.log(`  AgentRegistry: ${agentRegistry}`);
  console.log("[Wire] bindFactory + setAgentRegistry...");
  await call("bindFactory", agentRegistry, REGISTRY_ABI as unknown[], "bindFactory", [factory], 200_000n);
  await call("setAgentRegistry", factory, FACTORY_WIRE_ABI as unknown[], "setAgentRegistry", [agentRegistry], 200_000n);

  const ver = await reader.readContract({ address: impl, abi: IMPL_ABI, functionName: "ACCOUNT_VERSION" });
  if (ver !== TARGET_VERSION) throw new Error(`Version mismatch: expected "${TARGET_VERSION}", got "${ver}"`);
  console.log(`\n[Verify] ACCOUNT_VERSION = "${ver}" ✓`);

  console.log("\n=== v0.31.0 Deployment Complete ===");
  console.log("NEXT (migration interlock): per account call enrollInCommitteeValidator(); ONLY THEN does");
  console.log("dvt/owner flip the committee validator's setEpochLength to turn committee mode on.\n");
  console.log("Append to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0310_WEBAUTHN_LIB=${webAuthnLib}`);
  console.log(`AIRACCOUNT_V0310_COMMITTEE_BLS_LIB=${committeeLib}`);
  console.log(`AIRACCOUNT_V0310_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0310_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0310_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0310_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0310_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0310_COMMITTEE_VALIDATOR=${committeeValidator}`);
  console.log(`AIRACCOUNT_V0310_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0310_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0310_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0310_PARSER_REGISTRY=${parserRegistry}`);
}
main().catch((err) => { console.error(err); process.exit(1); });
