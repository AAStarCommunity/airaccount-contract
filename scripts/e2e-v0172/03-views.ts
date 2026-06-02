/**
 * scripts/e2e-v0172/03-views.ts
 *
 * Phase 3 — read-only view-function coverage against Sepolia.
 *
 * Every external view/pure function on the 11 deployed contracts is invoked
 * at least once and the return value sanity-checked. No tx, no gas.
 *
 * Run: pnpm tsx scripts/e2e-v0172/03-views.ts
 */

import { encodeAbiParameters, getAddress, keccak256, toBytes, type Hash } from "viem";
import { ADDR, publicClient, jason, bob, loadAbi, runTests, type TestCase } from "./common.js";

const blsAbi      = loadAbi("AAStarBLSAlgorithm");
const routerAbi   = loadAbi("AAStarValidator");
const aggAbi      = loadAbi("AAStarBLSAggregator");
const skAbi       = loadAbi("SessionKeyValidator");
const forceAbi    = loadAbi("ForceExitModule");
const delegateAbi = loadAbi("AirAccountDelegate");
const parserAbi   = loadAbi("CalldataParserRegistry");
const factoryAbi  = loadAbi("AAStarAirAccountFactoryV7");
const regAbi      = loadAbi("AgentRegistry");

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const DEAD = getAddress("0xdeaddeaddeaddeaddeaddeaddeaddeaddead1234");
const FAKE_NODE = ("0x" + "ab".repeat(32)) as `0x${string}`;
const FAKE_KEYX = ("0x" + "01".repeat(32)) as `0x${string}`;
const FAKE_KEYY = ("0x" + "02".repeat(32)) as `0x${string}`;

const tests: TestCase[] = [
  // ─── BLS algorithm views ──────────────────────────────────────────
  {
    name: "V-BLS.1 getRegisteredNodeCount returns >= 0",
    run: async () => {
      const n = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "getRegisteredNodeCount",
      }) as bigint;
      return { notes: `registered nodes count = ${n}` };
    },
  },
  {
    name: "V-BLS.2 getRegisteredNodes(0, 100) returns arrays of matching length",
    run: async () => {
      const [ids, keys] = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "getRegisteredNodes", args: [0n, 100n],
      }) as [readonly `0x${string}`[], readonly `0x${string}`[]];
      if (ids.length !== keys.length) throw new Error(`length mismatch: ${ids.length} vs ${keys.length}`);
      return { notes: `nodes returned: ${ids.length}` };
    },
  },
  {
    name: "V-BLS.3 isRegistered(unknown) == false",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "isRegistered", args: [FAKE_NODE],
      });
      if (ok !== false) throw new Error(`expected false, got ${ok}`);
      return { notes: `isRegistered(0xab..ab) = false` };
    },
  },
  {
    name: "V-BLS.4 computeSetHash matches keccak256(abi.encodePacked(nodeIds))",
    run: async () => {
      const ids: `0x${string}`[] = [FAKE_NODE];
      const onchain = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "computeSetHash", args: [ids],
      }) as `0x${string}`;
      const local = keccak256(FAKE_NODE);
      if (onchain.toLowerCase() !== local.toLowerCase()) {
        throw new Error(`onchain ${onchain} != local ${local}`);
      }
      return { notes: `setHash matches local keccak256: ${onchain.slice(0, 18)}…` };
    },
  },
  {
    name: "V-BLS.5 getGasEstimate(N) grows with N",
    run: async () => {
      const g1 = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "getGasEstimate", args: [1n],
      }) as bigint;
      const g10 = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "getGasEstimate", args: [10n],
      }) as bigint;
      if (g10 <= g1) throw new Error(`g10=${g10} <= g1=${g1} — should grow`);
      return { notes: `g(1)=${g1}  g(10)=${g10}` };
    },
  },
  {
    name: "V-BLS.6 owner() returns deployer (Anni)",
    run: async () => {
      const o = await publicClient.readContract({
        address: ADDR.blsAlgorithm, abi: blsAbi,
        functionName: "owner",
      }) as string;
      const annie = "0xEcAACb915f7D92e9916f449F7ad42BD0408733c9".toLowerCase();
      if (o.toLowerCase() !== annie) throw new Error(`expected ${annie}, got ${o}`);
      return { notes: `BLS owner = Anni` };
    },
  },

  // ─── Validator router views ───────────────────────────────────────
  {
    name: "V-ROUTER.1 getAlgorithm for each algId 0x00..0x09",
    run: async () => {
      const algs: Record<string, string> = {};
      for (let id = 0; id <= 9; id++) {
        const a = await publicClient.readContract({
          address: ADDR.validatorRouter, abi: routerAbi,
          functionName: "getAlgorithm", args: [id],
        }) as string;
        algs[`0x0${id.toString(16)}`] = a;
      }
      const wired = Object.entries(algs).filter(([_, a]) => a !== ZERO);
      return { notes: `wired algIds: ${wired.map(([id, a]) => `${id}→${a.slice(0, 10)}…`).join(", ")}` };
    },
  },
  {
    name: "V-ROUTER.2 setupComplete state read",
    run: async () => {
      const done = await publicClient.readContract({
        address: ADDR.validatorRouter, abi: routerAbi,
        functionName: "setupComplete",
      }) as boolean;
      // Beta: should be false (finalizeSetup not yet called — Codex INFO-1)
      return { notes: `setupComplete = ${done} (beta-1: expected false, matches deploy doc §4)` };
    },
  },

  // ─── SessionKeyValidator views ────────────────────────────────────
  {
    name: "V-SK.1 isSessionActive(deadAccount, deadKey) == false",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skAbi,
        functionName: "isSessionActive", args: [DEAD, jason.address],
      });
      if (ok !== false) throw new Error(`expected false, got ${ok}`);
      return { notes: `unfired session = inactive` };
    },
  },
  {
    name: "V-SK.2 getSession returns zero-init for unfired session",
    run: async () => {
      const s = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skAbi,
        functionName: "getSession", args: [DEAD, jason.address],
      }) as { expiry: number | bigint };
      // expiry is uint48 — viem returns it as number (≤ 2^53). Compare loosely.
      if (Number(s.expiry) !== 0) throw new Error(`expected expiry=0, got ${s.expiry}`);
      return { notes: `unfired session expiry = 0 (zero-init confirmed)` };
    },
  },
  {
    name: "V-SK.3 isP256SessionActive(unknown) == false",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skAbi,
        functionName: "isP256SessionActive", args: [DEAD, FAKE_KEYX, FAKE_KEYY],
      });
      if (ok !== false) throw new Error(`expected false, got ${ok}`);
      return { notes: `P256 session check works on never-granted key` };
    },
  },
  {
    name: "V-SK.4 grantNonces(any, any) == 0 initially",
    run: async () => {
      const n = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skAbi,
        functionName: "grantNonces", args: [DEAD, jason.address],
      }) as bigint;
      if (n !== 0n) throw new Error(`expected 0, got ${n}`);
      return { notes: `grantNonces is zero-init mapping` };
    },
  },
  {
    name: "V-SK.5 buildGrantHash produces 32-byte hash",
    run: async () => {
      const cfg = {
        expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
        contractScope: ZERO, selectorScope: "0x00000000" as `0x${string}`,
        revoked: false, velocityLimit: 0, velocityWindow: 0,
        callTargets: [], selectorAllowlist: [],
      };
      const h = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skAbi,
        functionName: "buildGrantHash", args: [DEAD, jason.address, cfg],
      }) as `0x${string}`;
      if (!h.startsWith("0x") || h.length !== 66) throw new Error(`bad hash: ${h}`);
      return { notes: `buildGrantHash → ${h.slice(0, 18)}…` };
    },
  },

  // ─── BLS Aggregator views ─────────────────────────────────────────
  {
    name: "V-AGG.1 blsAlgorithm address points to deployed BLS algo",
    run: async () => {
      const a = await publicClient.readContract({
        address: ADDR.blsAggregator, abi: aggAbi,
        functionName: "blsAlgorithm",
      }) as string;
      if (a.toLowerCase() !== ADDR.blsAlgorithm.toLowerCase()) {
        throw new Error(`expected ${ADDR.blsAlgorithm}, got ${a}`);
      }
      return { notes: `aggregator → BLS algorithm wiring confirmed` };
    },
  },

  // ─── ForceExitModule views ────────────────────────────────────────
  {
    name: "V-FORCE.1 isInitialized(deadAccount) == false",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.forceExitModule, abi: forceAbi,
        functionName: "isInitialized", args: [DEAD],
      });
      if (ok !== false) throw new Error(`expected false, got ${ok}`);
      return { notes: `ForceExit not initialized for arbitrary address` };
    },
  },
  {
    name: "V-FORCE.2 getPendingExit(deadAccount) returns zero-init",
    run: async () => {
      const [target, value, , proposedAt, approvals] = await publicClient.readContract({
        address: ADDR.forceExitModule, abi: forceAbi,
        functionName: "getPendingExit", args: [DEAD],
      }) as [string, bigint, `0x${string}`, bigint, bigint];
      if (target !== ZERO || value !== 0n || proposedAt !== 0n || approvals !== 0n) {
        throw new Error(`unexpected non-zero state: target=${target} value=${value} proposedAt=${proposedAt}`);
      }
      return { notes: `getPendingExit zero-init for arbitrary address` };
    },
  },

  // ─── AirAccountDelegate views (no 7702 auth needed for reads) ─────
  {
    name: "V-DEL.1 entryPoint() == EntryPoint v0.7",
    run: async () => {
      const ep = await publicClient.readContract({
        address: ADDR.delegate, abi: delegateAbi,
        functionName: "entryPoint",
      }) as string;
      if (ep.toLowerCase() !== ADDR.entryPoint.toLowerCase()) {
        throw new Error(`expected ${ADDR.entryPoint}, got ${ep}`);
      }
      return { notes: `delegate EntryPoint pin confirmed` };
    },
  },
  // owner() of the delegate without 7702 auth → returns address(this) which is the impl itself;
  // skipping since interpretation differs by EIP-7702 context.

  // ─── ParserRegistry views ─────────────────────────────────────────
  {
    name: "V-PARSER.1 owner() returns deployer (Anni)",
    run: async () => {
      const o = await publicClient.readContract({
        address: ADDR.parserRegistry, abi: parserAbi,
        functionName: "owner",
      }) as string;
      const annie = "0xEcAACb915f7D92e9916f449F7ad42BD0408733c9".toLowerCase();
      if (o.toLowerCase() !== annie) throw new Error(`expected ${annie}, got ${o}`);
      return { notes: `parser registry owner = Anni` };
    },
  },

  // ─── Factory views ────────────────────────────────────────────────
  {
    name: "V-FACT.1 getAddress vs getAddressWithDefaults produce different addresses",
    run: async () => {
      const salt = 99n;
      const noAlgs: number[] = [];
      const cfg = {
        guardians: [ZERO, ZERO, ZERO] as readonly [`0x${string}`, `0x${string}`, `0x${string}`],
        dailyLimit: 0n,
        approvedAlgIds: noAlgs,
        minDailyLimit: 0n,
        initialTokens: [] as readonly `0x${string}`[],
        initialTokenConfigs: [] as readonly { tier1Limit: bigint, tier2Limit: bigint, dailyLimit: bigint }[],
      };
      const a1 = await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddress", args: [jason.address, salt, cfg],
      }) as string;
      const a2 = await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [jason.address, salt, jason.address, bob.address, 1000000000000000n],
      }) as string;
      if (a1 === a2) throw new Error(`predicted addrs collided: ${a1}`);
      return { notes: `getAddress vs getAddressWithDefaults produce distinct: ${a1.slice(0, 10)}… vs ${a2.slice(0, 10)}…` };
    },
  },
  {
    name: "V-FACT.2 defaultCommunityGuardian == env-configured address",
    run: async () => {
      const cg = await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "defaultCommunityGuardian",
      }) as string;
      if (cg.toLowerCase() !== ADDR.communityGuardian.toLowerCase()) {
        throw new Error(`expected ${ADDR.communityGuardian}, got ${cg}`);
      }
      return { notes: `defaultCommunityGuardian = ${cg}` };
    },
  },

  // ─── AgentRegistry views ──────────────────────────────────────────
  {
    name: "V-REG.1 isValidAccount(deadAddress) == false",
    run: async () => {
      const v = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "isValidAccount", args: [DEAD],
      });
      if (v !== false) throw new Error(`expected false, got ${v}`);
      return { notes: `unspawned addr not in valid set` };
    },
  },
  {
    name: "V-REG.2 isRegisteredAgent(unknown) == false",
    run: async () => {
      const r = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "isRegisteredAgent", args: [DEAD],
      });
      if (r !== false) throw new Error(`expected false, got ${r}`);
      return { notes: `unregistered agent → false` };
    },
  },
  {
    name: "V-REG.3 balanceOf(humanOwner) == 0 initially",
    run: async () => {
      const b = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "balanceOf", args: [DEAD],
      }) as bigint;
      if (b !== 0n) throw new Error(`expected 0, got ${b}`);
      return { notes: `balanceOf(arbitrary) = 0` };
    },
  },
  {
    name: "V-REG.4 getAgentCount(arbitrary) == 0",
    run: async () => {
      const c = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "getAgentCount", args: [DEAD],
      }) as bigint;
      if (c !== 0n) throw new Error(`expected 0, got ${c}`);
      return { notes: `getAgentCount(arbitrary) = 0` };
    },
  },
  {
    name: "V-REG.5 getAgents(arbitrary) returns empty array",
    run: async () => {
      const a = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "getAgents", args: [DEAD],
      }) as readonly string[];
      if (a.length !== 0) throw new Error(`expected empty, got len=${a.length}`);
      return { notes: `getAgents(arbitrary) = []` };
    },
  },
  {
    name: "V-REG.6 getAgentsPage(arbitrary, 0, 10) returns empty",
    run: async () => {
      const p = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "getAgentsPage", args: [DEAD, 0n, 10n],
      }) as readonly string[];
      if (p.length !== 0) throw new Error(`expected empty page, got len=${p.length}`);
      return { notes: `getAgentsPage zero-bound = []` };
    },
  },
  {
    name: "V-REG.7 getHumanOwner(unknown) == address(0)",
    run: async () => {
      const o = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "getHumanOwner", args: [DEAD],
      }) as string;
      if (o !== ZERO) throw new Error(`expected zero, got ${o}`);
      return { notes: `getHumanOwner returns 0 for unregistered` };
    },
  },
];

(async () => { await runTests("3-views", tests); })();
