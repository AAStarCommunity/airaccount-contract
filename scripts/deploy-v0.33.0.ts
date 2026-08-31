/**
 * deploy-v0.33.0.ts — Deploy for v0.33.0 (CC-116 committee-off fail-closed gate on top of the v0.31.0
 * CC-102 weighted-governance hardening + CC-98 account-side per-proposal committee BLS integration).
 * Fresh non-upgradable stack (router is set-once + finalized → new router+impl+factory required).
 *
 * v0.33.0 vs v0.31.0 (v0.31.0 was deployed to Sepolia; this is the next non-upgradable stack):
 *   - CC-116: when a committee validator is mounted but NOT armed (committeeActive() == false), tier-2/3
 *             now FAILS CLOSED at the account layer (_blsAlgMode three-way resolution + `if (committeeOff)`
 *             gate at all three BLS entry points). A TRUE legacy validator (committeeActive() reverts, e.g.
 *             0x539B) is unaffected — whole-set coexistence preserved. Behavior-only; ABI surface unchanged.
 *   Carried from v0.31.0: CC-102 weighted-governance hardening + CC-98 committee BLS framing
 *   (accountId injection + committeeActive mode-gating + requiredQuorum mirror + enrollInCommitteeValidator),
 *   heavy framing externalized to CommitteeBLSLib.
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
 * ── COMMITTEE VALIDATOR: mounted at algId 0x01 of the NEW v0.33.0 router (a fresh set-once router). This
 *    does NOT edit the v0.29.0/v0.31.0 production routers. v0.33.0 is a parallel new stack.
 *    Address = dvt PoP-complete AAStarCommitteeValidator (#163), 0x7ac7E9d471742FA4397Beef0B5b11fbD22D196a9 — set via
 *    env DVT_COMMITTEE_VALIDATOR. Confirmed on Seeder f7810089 (address + keeper #238 + interlock).
 *
 * ── EMPTY-VALIDATOR GUARD (dvt catch): the committee validator must have registered DVT nodes BEFORE
 *    mount — an empty validator (getRegisteredNodeCount()==0) breaks LEGACY whole-set too (no nodes to
 *    verify against → every tier-2/3 op fails), not just committee. This script throws if it is empty.
 *    Rollout: dvt registered 3 staked nodes via registerWithProof (PoP+subgroup) — verified on-chain.
 *
 * ── MIGRATION ORDER (non-upgradable, committee mode OFF at deploy — UNLIKE v0.32.0). The new PoP
 *    validator 0x7ac7E9d4 is deployed committee-OFF (committeeActive()==false, epochLength==0), so the
 *    ORIGINAL interlock ordering applies and MUST be followed:
 *      1. deploy this stack (router 0x01 -> 0x7ac7E9d4)
 *      2. per account: enrollInCommitteeValidator()
 *      3. mount + e2e green
 *      4. ONLY THEN does dvt/owner(Safe) flip setEpochLength to arm committee mode. dvt must NOT flip first.
 *    Until step 4, CC-116 makes tier-2/3 FAIL-CLOSED on these accounts (committeeActive()==false =>
 *    committeeOff), while tier-1 owner-only works — the conservative direction, no floorless window.
 *    The script WARNS (and proceeds) if committeeActive() is already true; for v0.33.0 it should be false.
 *
 * Output env keys: AIRACCOUNT_V0330_*
 * Usage: pnpm tsx scripts/deploy-v0.33.0.ts   (DRY_RUN=1 to validate without broadcasting)
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
// Proven Sepolia fee formula (feedback_sepolia_gas_pricing): maxFee = baseFee*2 + max(tip, 2gwei floor).
// viem's default 1.2× underprovisions → silent mempool drops. Floor raised 1.5→2 gwei to match the
// canonical deploy-v0.18/beta4 fees().
const PRIORITY_FEE_FLOOR = 2_000_000_000n;
const TARGET_VERSION = "0.33.0";
// DRY_RUN=1 → sanity + link-check every artifact (landmine) + estimateGas each deploy, send NOTHING.
const DRY_RUN = process.env.DRY_RUN === "1";

// CC-98: DVT per-proposal COMMITTEE validator (YetAnotherAA-Validator AAStarCommitteeValidator #237),
// mounted at algId 0x01 of the NEW v0.33.0 router (fresh set-once router; v0.29.0/v0.31.0 routers are
// untouched — parallel stacks). 0x7ac7E9d471742FA4397Beef0B5b11fbD22D196a9; set via env
// DVT_COMMITTEE_VALIDATOR (confirmed on Seeder f7810089). Must have registered nodes before mount (guard below).
const DVT_COMMITTEE_VALIDATOR = (process.env.DVT_COMMITTEE_VALIDATOR ?? "") as string;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3].filter(Boolean) as string[];

function v0290(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0290_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0290_${key} not set — v0.33.0 reuses v0.29.0 peripherals`);
  return getAddress(v);
}
// Validate BEFORE privateKeyToAccount() below — else viem throws a cryptic "Cannot read properties of
// undefined (reading 'slice')" that names neither the var nor the fix (pr-daemon #211 Low).
if (!PRIVATE_KEY) throw new Error("PRIVATE_KEY_ANNI (or PRIVATE_KEY) not set in .env.sepolia");
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

async function estimateDeploy(reader: ReturnType<typeof pub>, label: string, artifactName: string, args: unknown[]): Promise<bigint> {
  const art = loadArtifact(artifactName); // links libs → throws on any residual __$ placeholder (landmine check)
  const data = encodeDeployData({ abi: art.abi, bytecode: art.bytecode, args });
  const gas = await reader.estimateGas({ account: deployer.address, data });
  console.log(`  ${label.padEnd(28)} est gas ${gas.toString().padStart(10)}  (bytecode ${((art.bytecode.length - 2) / 2).toString().padStart(6)} B)`);
  return gas;
}

// DRY RUN: sanity + link-check every artifact + estimateGas each deploy. Sends NOTHING. The impl estimate
// runs the ctor (which deploys AirAccountExtension inline), so it validates the 15M limit against the
// grown v0.33.0 bytecode (feedback_impl_gas_limit).
async function dryRun() {
  console.log("\n=== v0.33.0 DRY RUN — no transactions sent ===");
  if (!isAddress(DVT_COMMITTEE_VALIDATOR)) throw new Error("DVT_COMMITTEE_VALIDATOR not set to a valid address");
  const committeeValidator = getAddress(DVT_COMMITTEE_VALIDATOR);
  const reader = pub(RPC_URLS[0]);
  const bal = await reader.getBalance({ address: deployer.address });
  console.log(`Deployer ${deployer.address}  balance ${(Number(bal) / 1e18).toFixed(4)} ETH`);

  const cvCode = await reader.getBytecode({ address: committeeValidator });
  if (!cvCode || cvCode.length <= 2) throw new Error(`committee validator ${committeeValidator} has no code`);
  const active = await reader.readContract({ address: committeeValidator, abi: COMMITTEE_ABI, functionName: "committeeActive" }) as boolean;
  const nodes = await reader.readContract({ address: committeeValidator, abi: COMMITTEE_ABI, functionName: "getRegisteredNodeCount" }) as bigint;
  console.log(`Committee validator ${committeeValidator}: committeeActive=${active} registeredNodes=${nodes}`);
  if (nodes < 3n) throw new Error(`committee validator has ${nodes} registered nodes (<3) — dvt must register >=3 first (f7810089)`);
  if (active) console.warn("  ⚠️  committeeActive() already true — must deploy+enroll BEFORE flip (interlock)");

  const sess = v0290("SESSION_KEY_VALIDATOR"); v0290("FORCE_EXIT_MODULE"); v0290("DELEGATE"); v0290("PARSER_REGISTRY");
  console.log(`Reused v0.29.0 peripherals resolve ✓ (session ${sess})`);

  const DUMMY = "0x000000000000000000000000000000000000dEaD" as Address;
  console.log("\n[0] libraries");
  const gL1 = await estimateDeploy(reader, "WebAuthnLib", "WebAuthnLib", []);
  const gL2 = await estimateDeploy(reader, "CommitteeBLSLib", "CommitteeBLSLib", []);
  // Register dummy lib addrs so impl/extension link (the __$…$__ placeholder resolution = landmine check).
  LIBRARIES["src/utils/WebAuthnLib.sol:WebAuthnLib"] = DUMMY;
  LIBRARIES["src/utils/CommitteeBLSLib.sol:CommitteeBLSLib"] = DUMMY;
  console.log("[1-4] stack (dummy constructor deps for estimation)");
  const gR = await estimateDeploy(reader, "router (AAStarValidator)", "AAStarValidator", []);
  const gI = await estimateDeploy(reader, "impl (AAStarAirAccountV7)", "AAStarAirAccountV7", [DUMMY]);
  const gF = await estimateDeploy(reader, "factory", "AAStarAirAccountFactoryV7", [DUMMY, ENTRYPOINT, COMMUNITY, [], []]);
  const gA = await estimateDeploy(reader, "agentRegistry", "AgentRegistry", []);

  const total = gL1 + gL2 + gR + gI + gF + gA;
  const f = await fees();
  console.log(`\nImpl est gas ${gI} vs 15,000,000 limit → ${gI < 15_000_000n ? "OK ✓" : "⚠️  EXCEEDS — bump impl gas limit"}`);
  console.log(`Total est deploy gas ${total} (+ ~700k for 5 config calls)`);
  console.log(`~Max cost @ ${(Number(f.maxFeePerGas) / 1e9).toFixed(2)} gwei: ${(Number((total + 700_000n) * f.maxFeePerGas) / 1e18).toFixed(4)} ETH`);
  console.log("\n=== DRY RUN OK — all artifacts link, sanity passes, nothing sent ===");
}

async function main() {
  // PRIVATE_KEY is validated at module load (before privateKeyToAccount above).
  if (!COMMUNITY) throw new Error("COMMUNITY_GUARDIAN_ADDRESS not set");
  if (DRY_RUN) { await dryRun(); return; }
  if (!isAddress(DVT_COMMITTEE_VALIDATOR)) {
    throw new Error(
      "DVT_COMMITTEE_VALIDATOR not set to a valid address. Set the FULL checksum of the dvt " +
      "PoP-complete AAStarCommitteeValidator (#163, ~0x7ac7E9d4…) — confirmed by dvt on CC-115.",
    );
  }
  const committeeValidator = getAddress(DVT_COMMITTEE_VALIDATOR);
  console.log(`\n=== v0.33.0 deploy — Sepolia (CC-116 committee-off fail-closed + CC-102 gov + CC-98 committee) ===`);
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
  // Guard matches the script's own >=3 requirement (header + rollout note): a committee validator with
  // <3 nodes can't satisfy quorum and mounting it would break legacy tier-2/3 too — reject BEFORE paying
  // for the whole stack (~0.07 ETH), not after the e2e fails downstream (pr-daemon #211 Low).
  if (nodeCount < 3n) {
    throw new Error(
      `Committee validator ${committeeValidator} has ${nodeCount} registered nodes (<3) — mounting it would ` +
      `break tier-2/3. dvt must register >=3 DVT nodes first (Seeder f7810089), then re-run.`,
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

  console.log("\n=== v0.33.0 Deployment Complete ===");
  console.log("NEXT (migration interlock): per account call enrollInCommitteeValidator(); ONLY THEN does");
  console.log("dvt/owner flip the committee validator's setEpochLength to turn committee mode on.");
  console.log("CC-116: until flip, tier-2/3 on these accounts FAILS CLOSED (tier-1 owner-only still works).\n");
  console.log("Append to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0330_WEBAUTHN_LIB=${webAuthnLib}`);
  console.log(`AIRACCOUNT_V0330_COMMITTEE_BLS_LIB=${committeeLib}`);
  console.log(`AIRACCOUNT_V0330_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0330_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0330_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0330_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0330_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0330_COMMITTEE_VALIDATOR=${committeeValidator}`);
  console.log(`AIRACCOUNT_V0330_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0330_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0330_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0330_PARSER_REGISTRY=${parserRegistry}`);
}
main().catch((err) => { console.error(err); process.exit(1); });
