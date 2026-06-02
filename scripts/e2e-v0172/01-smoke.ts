/**
 * scripts/e2e-v0172/01-smoke.ts
 *
 * Phase 1 — smoke test for v0.17.2-beta.1 Sepolia deployment.
 *
 * Mirrors `docs/DEPLOYMENT-v0.17.2-beta.1.md` §6 ("Post-deploy Smoke Test").
 * All 8 checks are read-only or low-cost — no per-account deploys here (those
 * are in Phase 5). Goal: confirm the deployed contracts respond correctly and
 * the round-3/4/5/6 access-control hardening is live on-chain.
 *
 * Run: pnpm tsx scripts/e2e-v0172/01-smoke.ts
 */

import { encodeFunctionData, getAddress, type Hash } from "viem";
import { ADDR, publicClient, wAnnie, wJason, jason, bob, loadAbi, runTests, expectRevert, type TestCase } from "./common.js";

// ABI handles
const blsAbi      = loadAbi("AAStarBLSAlgorithm");
const routerAbi   = loadAbi("AAStarValidator");
const aggAbi      = loadAbi("AAStarBLSAggregator");
const skAbi       = loadAbi("SessionKeyValidator");
const parserRegAbi = loadAbi("CalldataParserRegistry");
const factoryAbi  = loadAbi("AAStarAirAccountFactoryV7");
const regAbi      = loadAbi("AgentRegistry");

const tests: TestCase[] = [
  // ─── S1: router has correct algorithm wirings ─────────────────────────
  {
    name: "S1.a router.getAlgorithm(0x01) == blsAlgorithm",
    run: async () => {
      const algo = await publicClient.readContract({
        address: ADDR.validatorRouter,
        abi: routerAbi,
        functionName: "getAlgorithm",
        args: [0x01],
      });
      if ((algo as string).toLowerCase() !== ADDR.blsAlgorithm.toLowerCase()) {
        throw new Error(`expected ${ADDR.blsAlgorithm}, got ${algo}`);
      }
      return { notes: `BLS algo wired at algId 0x01` };
    },
  },
  {
    name: "S1.b router.getAlgorithm(0x08) == sessionKeyValidator",
    run: async () => {
      const algo = await publicClient.readContract({
        address: ADDR.validatorRouter,
        abi: routerAbi,
        functionName: "getAlgorithm",
        args: [0x08],
      });
      if ((algo as string).toLowerCase() !== ADDR.sessionKeyValidator.toLowerCase()) {
        throw new Error(`expected ${ADDR.sessionKeyValidator}, got ${algo}`);
      }
      return { notes: `SessionKey validator wired at algId 0x08` };
    },
  },
  {
    name: "S1.c router.getAlgorithm(0x02) == address(0) (inline-handled)",
    run: async () => {
      const algo = await publicClient.readContract({
        address: ADDR.validatorRouter,
        abi: routerAbi,
        functionName: "getAlgorithm",
        args: [0x02],
      });
      if ((algo as string).toLowerCase() !== "0x0000000000000000000000000000000000000000") {
        throw new Error(`expected 0x0, got ${algo} — ECDSA must be inline-only`);
      }
      return { notes: `ECDSA inline-handled (router returns 0)` };
    },
  },

  // ─── S2: AgentRegistry bound to factory + immutable deployer ─────────
  {
    name: "S2.a agentRegistry.factory() == factory",
    run: async () => {
      const f = await publicClient.readContract({
        address: ADDR.agentRegistry,
        abi: regAbi,
        functionName: "factory",
      });
      if ((f as string).toLowerCase() !== ADDR.factory.toLowerCase()) {
        throw new Error(`expected ${ADDR.factory}, got ${f}`);
      }
      return { notes: `Factory ${ADDR.factory} bound to AgentRegistry` };
    },
  },
  {
    name: "S2.b agentRegistry.deployer() == Anni (round 3 A2 immutable)",
    run: async () => {
      const d = await publicClient.readContract({
        address: ADDR.agentRegistry,
        abi: regAbi,
        functionName: "deployer",
      });
      const expected = wAnnie.account!.address;
      if ((d as string).toLowerCase() !== expected.toLowerCase()) {
        throw new Error(`expected ${expected}, got ${d}`);
      }
      return { notes: `deployer = ${expected} (Anni; captured at construction)` };
    },
  },
  {
    name: "S2.c factory.agentRegistry() == agentRegistry",
    run: async () => {
      const r = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "agentRegistry",
      });
      if ((r as string).toLowerCase() !== ADDR.agentRegistry.toLowerCase()) {
        throw new Error(`expected ${ADDR.agentRegistry}, got ${r}`);
      }
      return { notes: `factory ↔ agentRegistry mutual binding confirmed` };
    },
  },

  // ─── S3: factory metadata sanity ─────────────────────────────────────
  {
    name: "S3.a factory.entryPoint() == EntryPoint v0.7",
    run: async () => {
      const ep = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "entryPoint",
      });
      if ((ep as string).toLowerCase() !== ADDR.entryPoint.toLowerCase()) {
        throw new Error(`expected ${ADDR.entryPoint}, got ${ep}`);
      }
      return { notes: `EntryPoint = ${ep}` };
    },
  },
  {
    name: "S3.b factory.implementation() == V7 impl",
    run: async () => {
      const i = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "implementation",
      });
      if ((i as string).toLowerCase() !== ADDR.impl.toLowerCase()) {
        throw new Error(`expected ${ADDR.impl}, got ${i}`);
      }
      return { notes: `V7 implementation = ${i}` };
    },
  },

  // ─── S4: parserRegistry stub deployed, no parsers registered (KI-14) ─
  {
    name: "S4 parserRegistry.getParser(random) == 0 (no opt-in default)",
    run: async () => {
      const target = getAddress("0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001");
      const p = await publicClient.readContract({
        address: ADDR.parserRegistry,
        abi: parserRegAbi,
        functionName: "getParser",
        args: [target],
      });
      if ((p as string).toLowerCase() !== "0x0000000000000000000000000000000000000000") {
        throw new Error(`expected 0x0, got ${p} — parsers should be stub-only in beta.1`);
      }
      return { notes: `KI-14: parsers disabled, registry stub returns 0` };
    },
  },

  // ─── S5: round 5 HIGH-1 CacheDeprecated — cacheAggregatedKey reverts ─
  {
    name: "S5 BLS cacheAggregatedKey reverts CacheDeprecated (round 5 HIGH-1)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm,
          abi: blsAbi,
          functionName: "cacheAggregatedKey",
          args: [[`0x${"00".repeat(32)}` as `0x${string}`]],
          account: bob.address,
        }),
        "CacheDeprecated()",
      );
      return { notes: `Round 5 HIGH-1 confirmed on-chain — selector ${selector}` };
    },
  },

  // ─── S6: round 3 A2 bindFactory access control — non-deployer reverts ─
  {
    name: "S6 agentRegistry.bindFactory(any) from non-deployer reverts NotDeployer",
    run: async () => {
      // Try bindFactory from bob (NOT the deployer). The deployer check (NotDeployer) fires
      // BEFORE the FactoryAlreadyBound check, so this should always be NotDeployer.
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry,
          abi: regAbi,
          functionName: "bindFactory",
          args: [ADDR.factory],
          account: bob.address,
        }),
        "NotDeployer()",
      );
      return { notes: `Round 3 A2: deployer-only bindFactory enforced — selector ${selector}` };
    },
  },

  // ─── S7: factory.createAccountWithDefaults predictability ────────────
  {
    name: "S7 factory.getAddressWithDefaults predicts CREATE2 address",
    run: async () => {
      const salt = 0n;
      const dailyLimit = 1000000000000000n; // 0.001 ETH
      const g1 = bob.address;
      const g2 = jason.address;

      const predicted = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [bob.address, salt, g1, g2, dailyLimit],
      });
      if (!predicted || (predicted as string).length !== 42) {
        throw new Error(`bad predicted address: ${predicted}`);
      }
      return { notes: `Predicted account addr: ${predicted}` };
    },
  },

  // ─── S8: H-2 fix evidence — registerAgent from non-AirAccount reverts ─
  {
    name: "S8 registerAgent from non-factory-spawned address reverts CallerNotAirAccount",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry,
          abi: regAbi,
          functionName: "registerAgent",
          args: [jason.address, "0x" as `0x${string}`],
          account: bob.address,   // bob is just an EOA, not factory-spawned
        }),
        "CallerNotAirAccount()",
      );
      return { notes: `H-2 fix: factory-provenance whitelist enforced — selector ${selector}` };
    },
  },
];

(async () => {
  await runTests("1-smoke", tests);
})();
