/**
 * test-railgun-parser-e2e.ts — M7.11 Railgun Privacy Pool Integration E2E (Sepolia)
 *
 * Business scenario: AirAccount guard enforces token tier limits on ALL token movements,
 * including Railgun privacy pool deposits (shield/transact). Without a parser, a Railgun
 * deposit (value=0 ETH, but large token amount) bypasses tier checks. With RailgunParser
 * registered, the guard correctly enforces tier limits on Railgun shields.
 *
 * Tests:
 *   A: Deploy RailgunParser (or reuse RAILGUN_PARSER env var)
 *   B: Register RailgunParser in CalldataParserRegistry for Railgun V3 proxy
 *   C: Registry lookup confirms correct parser stored
 *   D: Parser correctly parses shield() calldata → (USDC, 500e6)
 *   E: Parser correctly parses transact() calldata → (USDT, 1000e18)
 *   F: Parser returns (address(0), 0) for unknown selector
 *   G: Parser returns (address(0), 0) for zero token or zero amount
 *
 * Calldata format (matches RailgunParser._tryDecodeTokenAmount):
 *   transact() 0x00f714ce: [selector(4)] [padding(64)] [token(32)] [amount(32)]
 *   shield()   0x960b850d: [selector(4)] [padding(64)] [token(32)] [amount(32)] [padding(96)]
 *
 * Prerequisites:
 *   - forge build
 *   - .env.sepolia: PRIVATE_KEY, SEPOLIA_RPC_URL
 *   - Optional: CALLDATA_PARSER_REGISTRY, RAILGUN_PARSER
 *
 * Run: pnpm tsx scripts/test-railgun-parser-e2e.ts
 */

import { config } from "dotenv";
import { resolve } from "path";
import { readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  concat,
  pad,
  toHex,
  getAddress,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(import.meta.dirname, "../.env.sepolia") });

// ─── Config ──────────────────────────────────────────────────────────────────

const required = (k: string): string => {
  const v = process.env[k];
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
  return v;
};

const PRIVATE_KEY = required("PRIVATE_KEY") as Hex;
const RPC_URL = process.env.SEPOLIA_RPC_URL ?? required("SEPOLIA_RPC_URL");

// Railgun V3 proxy address on mainnet (used as dest key in registry)
// Sepolia: no official Railgun V3 deployment — use mainnet address as dest key for registry test
const RAILGUN_PROXY = getAddress("0x4025ee6512dbf386f9cf30c7e9a0a37460b3d0b4");

// Test token addresses (mainnet, used as parse targets — no actual transfers)
const USDC = getAddress("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48");
const USDT = getAddress("0xdac17f958d2ee523a2206206994597c13d831ec7");

// Railgun V3 selectors (from RailgunParser.sol)
const SELECTOR_TRANSACT = "0x00f714ce" as Hex;
const SELECTOR_SHIELD   = "0x960b850d" as Hex;

// ─── Load bytecode ────────────────────────────────────────────────────────────

function loadBytecode(name: string): Hex {
  const path = resolve(import.meta.dirname, `../out/${name}.sol/${name}.json`);
  return JSON.parse(readFileSync(path, "utf-8")).bytecode.object as Hex;
}

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const REGISTRY_ABI = [
  { name: "registerParser", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "dest", type: "address" }, { name: "parser", type: "address" }], outputs: [] },
  { name: "getParser", type: "function", stateMutability: "view",
    inputs: [{ name: "dest", type: "address" }], outputs: [{ type: "address" }] },
] as const;

const PARSER_ABI = [
  { name: "parseTokenTransfer", type: "function", stateMutability: "pure",
    inputs: [{ name: "data", type: "bytes" }],
    outputs: [{ name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" }] },
] as const;

// ─── Calldata builders ────────────────────────────────────────────────────────

/**
 * Build synthetic Railgun transact() calldata.
 * Layout: [selector(4)] [padding(64)] [token(32)] [amount(32)]
 * Total: 132 bytes minimum.
 */
function buildTransactCalldata(token: Address, amount: bigint): Hex {
  const tokenPadded = pad(token, { size: 32 });
  const amountHex   = pad(toHex(amount), { size: 32 });
  const padding     = pad("0x", { size: 64 });
  return concat([SELECTOR_TRANSACT, padding, tokenPadded, amountHex]);
}

/**
 * Build synthetic Railgun shield() calldata.
 * Layout: [selector(4)] [padding(64)] [token(32)] [amount(32)] [padding(96)]
 * Total: 228 bytes — satisfies _parseShield's data[4:].length >= 224 check.
 */
function buildShieldCalldata(token: Address, amount: bigint): Hex {
  const tokenPadded  = pad(token, { size: 32 });
  const amountHex    = pad(toHex(amount), { size: 32 });
  const padding64    = pad("0x", { size: 64 });
  const padding96    = pad("0x", { size: 96 });
  return concat([SELECTOR_SHIELD, padding64, tokenPadded, amountHex, padding96]);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

function ok(label: string, msg: string) {
  passed++;
  console.log(`  PASS [${label}]: ${msg}`);
}
function fail(label: string, msg: string) {
  failed++;
  console.error(`  FAIL [${label}]: ${msg}`);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("\n=== M7.11 Railgun Privacy Pool Integration E2E (Sepolia) ===\n");
  console.log("Verifies RailgunParser correctly extracts (token, amount) from Railgun");
  console.log("shield/transact calldata for AirAccount guard tier enforcement.\n");

  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const owner = privateKeyToAccount(PRIVATE_KEY);
  const ownerClient = createWalletClient({ account: owner, chain: sepolia, transport: http(RPC_URL) });

  console.log(`Deployer:       ${owner.address}`);
  console.log(`Railgun proxy:  ${RAILGUN_PROXY}`);

  // ── Test A: Deploy RailgunParser ──────────────────────────────────────────

  console.log("\n[A] Deploy RailgunParser");

  let parserAddr: Address;
  const existingParser = process.env.RAILGUN_PARSER as Address | undefined;

  if (existingParser) {
    const code = await publicClient.getBytecode({ address: existingParser });
    if (code && code.length > 2) {
      parserAddr = existingParser;
      console.log(`  Reusing: ${parserAddr}`);
      ok("A", `RailgunParser reused at ${parserAddr}`);
    } else {
      parserAddr = await deployParser();
    }
  } else {
    parserAddr = await deployParser();
  }

  async function deployParser(): Promise<Address> {
    const tx = await ownerClient.deployContract({
      abi: PARSER_ABI,
      bytecode: loadBytecode("RailgunParser"),
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
    if (!receipt.contractAddress) throw new Error("Deploy failed");
    ok("A", `RailgunParser deployed at ${receipt.contractAddress}`);
    return receipt.contractAddress;
  }

  // ── Test B: Register in CalldataParserRegistry ────────────────────────────

  console.log("\n[B] Register RailgunParser in CalldataParserRegistry");

  let registryAddr: Address;
  const existingRegistry = process.env.CALLDATA_PARSER_REGISTRY as Address | undefined;

  if (existingRegistry) {
    const code = await publicClient.getBytecode({ address: existingRegistry });
    if (code && code.length > 2) {
      registryAddr = existingRegistry;
      console.log(`  Reusing registry: ${registryAddr}`);
    } else {
      registryAddr = await deployRegistry();
    }
  } else {
    registryAddr = await deployRegistry();
  }

  async function deployRegistry(): Promise<Address> {
    const registryBytecode = loadBytecode("CalldataParserRegistry");
    const tx = await ownerClient.deployContract({ abi: REGISTRY_ABI, bytecode: registryBytecode });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
    if (!receipt.contractAddress) throw new Error("Registry deploy failed");
    console.log(`  Deployed new registry: ${receipt.contractAddress}`);
    return receipt.contractAddress;
  }

  // Check if already registered (registry is only-add, can't re-register)
  const existingParserInRegistry = await publicClient.readContract({
    address: registryAddr, abi: REGISTRY_ABI,
    functionName: "getParser", args: [RAILGUN_PROXY],
  }) as Address;

  if (existingParserInRegistry !== "0x0000000000000000000000000000000000000000") {
    console.log(`  Already registered: ${existingParserInRegistry}`);
    ok("B", `RailgunParser already registered for ${RAILGUN_PROXY}`);
  } else {
    try {
      const tx = await ownerClient.writeContract({
        address: registryAddr, abi: REGISTRY_ABI,
        functionName: "registerParser", args: [RAILGUN_PROXY, parserAddr],
      });
      await publicClient.waitForTransactionReceipt({ hash: tx });
      ok("B", `Registered RailgunParser for ${RAILGUN_PROXY} (tx: ${tx.slice(0, 20)}...)`);
    } catch (e: any) {
      fail("B", e.message?.slice(0, 150));
    }
  }

  // ── Test C: Registry lookup ───────────────────────────────────────────────

  console.log("\n[C] Registry lookup");

  const storedParser = await publicClient.readContract({
    address: registryAddr, abi: REGISTRY_ABI,
    functionName: "getParser", args: [RAILGUN_PROXY],
  }) as Address;

  if (storedParser.toLowerCase() === parserAddr.toLowerCase()) {
    ok("C", `getParser(${RAILGUN_PROXY}) = ${storedParser} ✓`);
  } else {
    fail("C", `Expected ${parserAddr}, got ${storedParser}`);
  }

  // Unknown dest returns address(0)
  const noParser = await publicClient.readContract({
    address: registryAddr, abi: REGISTRY_ABI,
    functionName: "getParser", args: ["0x0000000000000000000000000000000000009999" as Address],
  }) as Address;
  if (noParser === "0x0000000000000000000000000000000000000000") {
    ok("C2", "getParser for unknown address returns address(0)");
  } else {
    fail("C2", `Expected address(0), got ${noParser}`);
  }

  // ── Test D: shield() parsing ──────────────────────────────────────────────

  console.log("\n[D] RailgunParser.parseTokenTransfer: shield() → (USDC, 500e6)");

  try {
    const shieldCalldata = buildShieldCalldata(USDC, 500_000_000n); // 500 USDC
    const [tok, amt] = await publicClient.readContract({
      address: parserAddr, abi: PARSER_ABI,
      functionName: "parseTokenTransfer", args: [shieldCalldata],
    }) as [Address, bigint];

    if (tok.toLowerCase() === USDC.toLowerCase() && amt === 500_000_000n) {
      ok("D", `shield() → token=${tok} (USDC), amount=${amt} (500 USDC) ✓`);
    } else {
      fail("D", `Expected (USDC, 500e6), got (${tok}, ${amt})`);
    }
  } catch (e: any) {
    fail("D", e.message?.slice(0, 150));
  }

  // ── Test E: transact() parsing ────────────────────────────────────────────

  console.log("\n[E] RailgunParser.parseTokenTransfer: transact() → (USDT, 1000e18)");

  try {
    const transactCalldata = buildTransactCalldata(USDT, 1000n * 10n ** 18n); // 1000 USDT (18dec)
    const [tok, amt] = await publicClient.readContract({
      address: parserAddr, abi: PARSER_ABI,
      functionName: "parseTokenTransfer", args: [transactCalldata],
    }) as [Address, bigint];

    const expected = 1000n * 10n ** 18n;
    if (tok.toLowerCase() === USDT.toLowerCase() && amt === expected) {
      ok("E", `transact() → token=${tok} (USDT), amount=${amt} ✓`);
    } else {
      fail("E", `Expected (USDT, 1000e18), got (${tok}, ${amt})`);
    }
  } catch (e: any) {
    fail("E", e.message?.slice(0, 150));
  }

  // ── Test F: unknown selector ──────────────────────────────────────────────

  console.log("\n[F] Unknown selector returns (address(0), 0)");

  try {
    const unknownCalldata = concat(["0xDEADBEEF" as Hex, pad("0x", { size: 128 })]);
    const [tok, amt] = await publicClient.readContract({
      address: parserAddr, abi: PARSER_ABI,
      functionName: "parseTokenTransfer", args: [unknownCalldata],
    }) as [Address, bigint];

    if (tok === "0x0000000000000000000000000000000000000000" && amt === 0n) {
      ok("F", "Unknown selector → (address(0), 0) — guard falls back to native ERC20 parsing ✓");
    } else {
      fail("F", `Expected (address(0), 0), got (${tok}, ${amt})`);
    }
  } catch (e: any) {
    fail("F", e.message?.slice(0, 150));
  }

  // ── Test G: zero token / zero amount ─────────────────────────────────────

  console.log("\n[G] Edge cases: zero token or zero amount return (address(0), 0)");

  try {
    // Zero token
    const zeroTokenCalldata = buildTransactCalldata("0x0000000000000000000000000000000000000000" as Address, 1000n);
    const [tok1, amt1] = await publicClient.readContract({
      address: parserAddr, abi: PARSER_ABI,
      functionName: "parseTokenTransfer", args: [zeroTokenCalldata],
    }) as [Address, bigint];

    if (tok1 === "0x0000000000000000000000000000000000000000" && amt1 === 0n) {
      ok("G1", "Zero token → (address(0), 0) ✓");
    } else {
      fail("G1", `Expected (address(0), 0), got (${tok1}, ${amt1})`);
    }

    // Zero amount
    const zeroAmountCalldata = buildTransactCalldata(USDC, 0n);
    const [tok2, amt2] = await publicClient.readContract({
      address: parserAddr, abi: PARSER_ABI,
      functionName: "parseTokenTransfer", args: [zeroAmountCalldata],
    }) as [Address, bigint];

    if (tok2 === "0x0000000000000000000000000000000000000000" && amt2 === 0n) {
      ok("G2", "Zero amount → (address(0), 0) ✓");
    } else {
      fail("G2", `Expected (address(0), 0), got (${tok2}, ${amt2})`);
    }
  } catch (e: any) {
    fail("G", e.message?.slice(0, 150));
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  console.log(`\n${"═".repeat(50)}`);
  console.log(` M7.11 Railgun Parser E2E Summary`);
  console.log(`${"═".repeat(50)}\n`);
  console.log(`  RailgunParser:          ${parserAddr}`);
  console.log(`  CalldataParserRegistry: ${registryAddr}`);
  console.log(`  Railgun proxy dest:     ${RAILGUN_PROXY}`);
  console.log();
  console.log(`  Results: ${passed} passed, ${failed} failed\n`);

  if (failed === 0) {
    console.log("ALL PASS ✓  M7.11 Railgun Privacy Pool Integration verified.\n");
    console.log("What this proves:");
    console.log("  - RailgunParser correctly identifies Railgun shield/transact calldata");
    console.log("  - Extracts (tokenIn, amountIn) for guard tier enforcement");
    console.log("  - Unknown selectors safely return (address(0), 0) — no false positives");
    console.log("  - Registry wiring: CalldataParserRegistry → RailgunParser confirmed");
    console.log();
    console.log("Guard enforcement flow:");
    console.log("  User shields 5000 USDC to Railgun");
    console.log("  → guard.checkTransaction(value=0, algId) with Railgun calldata");
    console.log("  → registry.getParser(railgunProxy) returns RailgunParser");
    console.log("  → parser.parseTokenTransfer(calldata) → (USDC, 5000e6)");
    console.log("  → guard enforces USDC tier limit (Tier2/Tier3 if > dailyLimit)");
    console.log();
    console.log("Set in .env.sepolia:");
    console.log(`  RAILGUN_PARSER=${parserAddr}`);
    if (!existingRegistry) {
      console.log(`  CALLDATA_PARSER_REGISTRY=${registryAddr}`);
    }
  } else {
    console.error(`${failed} test(s) FAILED`);
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
