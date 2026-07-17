/**
 * deploy-v0.29.0.ts — Deploy for v0.29.0 (security hardening + WebAuthnLib + native tiers + P256 dedup).
 *
 * Fresh non-upgradable stack (router is set-once + finalized, so a NEW router+impl+factory is required).
 * v0.29.0 vs v0.28.0: #161 native-ETH tiers, #149 WebAuthnLib external lib, #191 P256 dedup, #135 Safe
 * deploy governance, #194 security fixes (H1/H2 + M2/M1/H3/H4). Deploys:
 *   [0] WebAuthnLib (NEW external library — #149) → registered in LIBRARIES + linked into impl/extension
 *   [1] AAStarValidator router → 0x01 = DVT validator, 0x08 = reused SessionKeyValidator, finalize
 *   [2] AAStarAirAccountV7 impl (router baked in, WebAuthnLib linked) → fresh AirAccountExtension
 *   [3] AAStarAirAccountFactoryV7
 *   [4] AgentRegistry → bindFactory + setAgentRegistry
 *
 * Reused from v0.28.0 (AIRACCOUNT_V0280_*): SessionKeyValidator, ForceExitModule, Delegate, ParserRegistry,
 * DVT validator 0x539B. #149 DEPLOY REQUIREMENT: WebAuthnLib MUST be deployed + linked into the impl
 * BEFORE deploying the impl (linkBytecode fails closed on any residual `__$…$__` placeholder).
 *
 * Output env keys: AIRACCOUNT_V0290_*
 * Usage: pnpm tsx scripts/deploy-v0.29.0.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient, createWalletClient, http, encodeDeployData, encodeFunctionData,
  getAddress, keccak256, stringToBytes, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const PRIORITY_FEE_FLOOR = 1_500_000_000n;
const TARGET_VERSION = "0.29.0";
// DVT authoritative BLS validator (YetAnotherAA-Validator, Sepolia) — mounted at algId 0x01.
const DVT_VALIDATOR = "0x539B9681aFd5BFbCaa655Fe4c6BdcFe1fa7864bC" as Address;

const PRIVATE_KEY = (process.env.PRIVATE_KEY_ANNI ?? process.env.PRIVATE_KEY) as Hex;
const COMMUNITY   = process.env.COMMUNITY_GUARDIAN_ADDRESS as Address;
const RPC_URLS = [process.env.SEPOLIA_RPC_URL, process.env.SEPOLIA_RPC_URL2, process.env.SEPOLIA_RPC_URL3].filter(Boolean) as string[];

function v0280(key: string): Address {
  const v = process.env[`AIRACCOUNT_V0280_${key}`];
  if (!v) throw new Error(`AIRACCOUNT_V0280_${key} not set — run deploy-v0.28.0.ts first`);
  return getAddress(v);
}
const deployer = privateKeyToAccount(PRIVATE_KEY);

// #149: deployed external-library addresses (fully-qualified name → address). Populated at runtime
// AFTER WebAuthnLib is deployed and BEFORE the impl artifact is loaded.
const LIBRARIES: Record<string, Address> = {};

// #149: resolve Solidity external-library link placeholders (`__$<34-hex>$__`) in creation bytecode.
// The impl embeds the extension's creation code, so both WebAuthnLib references live in the impl's
// bytecode and are patched here. Fails CLOSED: an unregistered library or any residual `__$` placeholder
// throws, so unlinked bytecode (= a broken account whose WebAuthn verify jumps to a garbage address)
// can never be sent on-chain.
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
  console.log(`\n=== v0.29.0 deploy — Sepolia (security hardening + WebAuthnLib + native tiers) ===`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`DVT validator (algId 0x01): ${DVT_VALIDATOR}\n`);

  const sessionValidator = v0280("SESSION_KEY_VALIDATOR");
  const forceExitModule  = v0280("FORCE_EXIT_MODULE");
  const delegate         = v0280("DELEGATE");
  const parserRegistry   = v0280("PARSER_REGISTRY");
  const reader = pub(RPC_URLS[0]);

  // Sanity: DVT validator is deployed + exposes validate().
  const dvtCode = await reader.getBytecode({ address: DVT_VALIDATOR });
  if (!dvtCode || dvtCode.length <= 2) throw new Error(`DVT validator ${DVT_VALIDATOR} has no code`);
  console.log(`DVT validator code: ${dvtCode.length / 2 - 1} bytes ✓`);

  // [0] WebAuthnLib (#149) — MUST deploy + register BEFORE the impl is loaded (impl+extension link it).
  console.log("\n[0/4] WebAuthnLib (external library)...");
  const webAuthnLib = await deploy("webAuthnLib", "WebAuthnLib", [], 1_500_000n);
  LIBRARIES["src/utils/WebAuthnLib.sol:WebAuthnLib"] = webAuthnLib;
  console.log(`  WebAuthnLib: ${webAuthnLib}`);

  // [1] new router → 0x01 = DVT validator, 0x08 = reused session validator, finalize
  console.log("\n[1/4] AAStarValidator router (0x01→DVT, 0x08→session)...");
  const router = await deploy("router", "AAStarValidator", [], 2_000_000n);
  console.log(`  Router: ${router}`);
  await call("register-0x01-DVT", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x01, DVT_VALIDATOR], 150_000n);
  await call("register-0x08-session", router, ROUTER_ABI as unknown[], "registerAlgorithm", [0x08, sessionValidator], 150_000n);
  await call("finalizeSetup", router, ROUTER_ABI as unknown[], "finalizeSetup", [], 100_000n);
  const r01 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x01] }) as Address;
  const r08 = await reader.readContract({ address: router, abi: ROUTER_ABI, functionName: "getAlgorithm", args: [0x08] }) as Address;
  if (r01.toLowerCase() !== DVT_VALIDATOR.toLowerCase()) throw new Error(`router 0x01 mismatch: ${r01}`);
  if (r08.toLowerCase() !== sessionValidator.toLowerCase()) throw new Error(`router 0x08 mismatch: ${r08}`);
  console.log(`  router 0x01=${r01} (DVT) 0x08=${r08} (session) ✓`);

  // [2] new impl (WebAuthnLib linked via loadArtifact)
  console.log("\n[2/4] AAStarAirAccountV7 (impl, new router, WebAuthnLib linked)...");
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

  console.log("\n=== v0.29.0 Deployment Complete ===\nAppend to .env.sepolia:\n");
  console.log(`AIRACCOUNT_V0290_WEBAUTHN_LIB=${webAuthnLib}`);
  console.log(`AIRACCOUNT_V0290_IMPL=${impl}`);
  console.log(`AIRACCOUNT_V0290_EXTENSION=${extension}`);
  console.log(`AIRACCOUNT_V0290_FACTORY=${factory}`);
  console.log(`AIRACCOUNT_V0290_AGENT_REGISTRY=${agentRegistry}`);
  console.log(`AIRACCOUNT_V0290_VALIDATOR_ROUTER=${router}`);
  console.log(`AIRACCOUNT_V0290_DVT_VALIDATOR=${DVT_VALIDATOR}`);
  console.log(`AIRACCOUNT_V0290_SESSION_KEY_VALIDATOR=${sessionValidator}`);
  console.log(`AIRACCOUNT_V0290_FORCE_EXIT_MODULE=${forceExitModule}`);
  console.log(`AIRACCOUNT_V0290_DELEGATE=${delegate}`);
  console.log(`AIRACCOUNT_V0290_PARSER_REGISTRY=${parserRegistry}`);
}
main().catch((err) => { console.error(err); process.exit(1); });
