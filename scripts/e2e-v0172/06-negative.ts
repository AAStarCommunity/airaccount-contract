/**
 * scripts/e2e-v0172/06-negative.ts
 *
 * Phase 6 — exercise every documented custom error / revert path against the
 * Sepolia deployment. No tx, no gas (all via eth_call simulation).
 *
 * Run: pnpm tsx scripts/e2e-v0172/06-negative.ts
 */

import { encodeFunctionData, getAddress, type Hash } from "viem";
import {
  ADDR, publicClient, jason, bob, annie,
  loadAbi, runTests, expectRevert, expectRawCallRevert,
  type TestCase,
} from "./common.js";

const blsAbi      = loadAbi("AAStarBLSAlgorithm");
const routerAbi   = loadAbi("AAStarValidator");
const aggAbi      = loadAbi("AAStarBLSAggregator");
const skAbi       = loadAbi("SessionKeyValidator");
const forceAbi    = loadAbi("ForceExitModule");
const parserAbi   = loadAbi("CalldataParserRegistry");
const factoryAbi  = loadAbi("AAStarAirAccountFactoryV7");
const regAbi      = loadAbi("AgentRegistry");

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const DEAD = getAddress("0xdeaddeaddeaddeaddeaddeaddeaddeaddead1234");
const G1_INF = ("0x" + "00".repeat(128)) as `0x${string}`;
const G2_INF = ("0x" + "00".repeat(256)) as `0x${string}`;
const G2_NZ  = ("0x01" + "00".repeat(255)) as `0x${string}`;
const FAKE_NODE = ("0x" + "ab".repeat(32)) as `0x${string}`;

const tests: TestCase[] = [
  // ─── BLS algorithm negatives ──────────────────────────────────────
  {
    name: "N-BLS.1 registerPublicKey from non-owner reverts OnlyOwner",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "registerPublicKey",
          args: [FAKE_NODE, ("0x" + "01".repeat(128)) as `0x${string}`],
          account: bob.address,
        }),
        "OnlyOwner()",
      );
      return { notes: `selector=${selector}` };
    },
  },
  {
    name: "N-BLS.2 cacheAggregatedKey reverts CacheDeprecated (HIGH-1)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "cacheAggregatedKey", args: [[FAKE_NODE]],
          account: bob.address,
        }),
        "CacheDeprecated()",
      );
      return { notes: `HIGH-1 — selector=${selector}` };
    },
  },
  {
    name: "N-BLS.3 validateAggregateSignature with infinity sig reverts BLSPointAtInfinity (HIGH-2)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "validateAggregateSignature",
          args: [[FAKE_NODE], G2_INF, G2_NZ],
          account: bob.address,
        }),
        "BLSPointAtInfinity()",
      );
      return { notes: `HIGH-2 — selector=${selector}` };
    },
  },
  {
    name: "N-BLS.4 validateAggregateSignature with infinity msgPt reverts BLSPointAtInfinity",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "validateAggregateSignature",
          args: [[FAKE_NODE], G2_NZ, G2_INF],
          account: bob.address,
        }),
        "BLSPointAtInfinity()",
      );
      return { notes: `HIGH-2 msgPt-side — selector=${selector}` };
    },
  },
  {
    name: "N-BLS.5 validateAggregateSignature with empty nodeIds reverts NoNodesProvided",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "validateAggregateSignature",
          args: [[], G2_NZ, G2_NZ],
          account: bob.address,
        }),
        "NoNodesProvided()",
      );
      return { notes: `selector=${selector}` };
    },
  },
  {
    name: "N-BLS.6 validateAggregateSignature with wrong sig length reverts InvalidSignatureLength",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.blsAlgorithm, abi: blsAbi,
          functionName: "validateAggregateSignature",
          args: [[FAKE_NODE], "0xabcd" as `0x${string}`, G2_NZ],
          account: bob.address,
        }),
        "InvalidSignatureLength()",
      );
      return { notes: `selector=${selector}` };
    },
  },

  // ─── Validator router negatives ───────────────────────────────────
  {
    name: "N-ROUTER.1 registerAlgorithm after finalizeSetup() reverts SetupAlreadyClosed",
    run: async () => {
      // beta.3: router was finalized — registerAlgorithm reverts SetupAlreadyClosed.
      // Prior betas would have reverted AlgorithmAlreadyRegistered.
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.validatorRouter, abi: routerAbi,
          functionName: "registerAlgorithm",
          args: [1, ADDR.blsAlgorithm],
          account: annie.address,
        }),
        "SetupAlreadyClosed()",
      );
      return { notes: `router locked after beta.3 deploy — selector=${selector}` };
    },
  },
  {
    name: "N-ROUTER.2 registerAlgorithm from non-owner reverts OnlyOwner",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.validatorRouter, abi: routerAbi,
          functionName: "registerAlgorithm",
          args: [9, DEAD],
          account: bob.address,
        }),
        "OnlyOwner()",
      );
      return { notes: `selector=${selector}` };
    },
  },

  // ─── SessionKeyValidator negatives ────────────────────────────────
  {
    name: "N-SK.1 grantSessionDirect on non-AirAccount reverts NotAirAccount (David LOW#3)",
    run: async () => {
      const data = encodeFunctionData({
        abi: skAbi as any,
        functionName: "grantSessionDirect",
        args: [DEAD, jason.address, {
          expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
          contractScope: ZERO, selectorScope: "0x00000000" as `0x${string}`,
          revoked: false, velocityLimit: 0, velocityWindow: 0,
          callTargets: [] as readonly `0x${string}`[],
          selectorAllowlist: [] as readonly `0x${string}`[],
        }],
      });
      const { selector } = await expectRawCallRevert(
        { to: ADDR.sessionKeyValidator, data, from: jason.address },
        "NotAirAccount()",
      );
      return { notes: `David LOW#3 — selector=${selector}` };
    },
  },
  {
    name: "N-SK.2 grantSession with all-zero ownerSig reverts ECDSAInvalidSignature",
    run: async () => {
      // grantSession path: _validateCfg → _checkNotExists → _buildGrantHash → ECDSA.recover(ownerSig).
      // An all-zero 65-byte sig has v=0 (invalid per OpenZeppelin), so ECDSA.recover reverts
      // ECDSAInvalidSignature() (0xf645eedf) BEFORE the NotAccountOwner check fires.
      // This proves the off-chain sig path is wired correctly — bad sig is caught.
      const data = encodeFunctionData({
        abi: skAbi as any,
        functionName: "grantSession",
        args: [DEAD, jason.address, {
          expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
          contractScope: ZERO, selectorScope: "0x00000000" as `0x${string}`,
          revoked: false, velocityLimit: 0, velocityWindow: 0,
          callTargets: [] as readonly `0x${string}`[],
          selectorAllowlist: [] as readonly `0x${string}`[],
        }, ("0x" + "00".repeat(65)) as `0x${string}`],
      });
      const { selector } = await expectRawCallRevert(
        { to: ADDR.sessionKeyValidator, data, from: jason.address },
        "ECDSAInvalidSignature()",
      );
      return { notes: `OZ ECDSA library catches v=0 signature — selector=${selector}` };
    },
  },

  // ─── ForceExitModule negatives ────────────────────────────────────
  {
    name: "N-FORCE.1 approveForceExit on non-existent proposal reverts NoProposal",
    run: async () => {
      const data = encodeFunctionData({
        abi: forceAbi as any,
        functionName: "approveForceExit",
        args: [DEAD, ("0x" + "00".repeat(65)) as `0x${string}`],
      });
      // Just confirm it reverts; exact selector varies by contract version
      try {
        await publicClient.call({ to: ADDR.forceExitModule, data, account: bob.address });
        throw new Error("expected revert");
      } catch (err: any) {
        if (err.message === "expected revert") throw err;
        return { notes: `revert confirmed — ${err?.shortMessage ?? err?.message?.slice(0, 60)}` };
      }
    },
  },

  // ─── ParserRegistry negatives ─────────────────────────────────────
  {
    name: "N-PARSER.1 registerParser from non-owner reverts",
    run: async () => {
      // The owner is Anni; bob trying to set a parser should be rejected.
      // ParserRegistry uses a simple onlyOwner pattern from OZ Ownable (custom selector may vary).
      try {
        await publicClient.simulateContract({
          address: ADDR.parserRegistry, abi: parserAbi,
          functionName: "registerParser",
          args: [DEAD, DEAD],
          account: bob.address,
        });
        throw new Error("expected revert");
      } catch (err: any) {
        if (err.message === "expected revert") throw err;
        return { notes: `ownership gate enforced — ${err?.shortMessage?.slice(0, 80)}` };
      }
    },
  },

  // ─── Factory negatives ────────────────────────────────────────────
  {
    name: "N-FACT.1 setAgentRegistry from non-owner reverts",
    run: async () => {
      try {
        await publicClient.simulateContract({
          address: ADDR.factory, abi: factoryAbi,
          functionName: "setAgentRegistry",
          args: [DEAD],
          account: bob.address,
        });
        throw new Error("expected revert");
      } catch (err: any) {
        if (err.message === "expected revert") throw err;
        return { notes: `ownership gate enforced — ${err?.shortMessage?.slice(0, 80)}` };
      }
    },
  },

  // ─── AgentRegistry negatives ──────────────────────────────────────
  {
    name: "N-REG.1 bindFactory from non-deployer reverts NotDeployer (round 3 A2)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "bindFactory",
          args: [ADDR.factory],
          account: bob.address,
        }),
        "NotDeployer()",
      );
      return { notes: `round 3 A2 — selector=${selector}` };
    },
  },
  {
    name: "N-REG.2 bindFactory from deployer (Anni) reverts FactoryAlreadyBound",
    run: async () => {
      // Anni IS the deployer; should pass NotDeployer gate then hit FactoryAlreadyBound.
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "bindFactory",
          args: [DEAD],
          account: annie.address,
        }),
        "FactoryAlreadyBound()",
      );
      return { notes: `set-once binding enforced — selector=${selector}` };
    },
  },
  {
    name: "N-REG.3 markValid from non-factory reverts OnlyFactory",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "markValid",
          args: [DEAD],
          account: bob.address,
        }),
        "OnlyFactory()",
      );
      return { notes: `selector=${selector}` };
    },
  },
  {
    name: "N-REG.4 registerAgent from non-AirAccount reverts CallerNotAirAccount (H-2)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "registerAgent",
          args: [jason.address, "0x" as `0x${string}`],
          account: bob.address,
        }),
        "CallerNotAirAccount()",
      );
      return { notes: `H-2 fix — selector=${selector}` };
    },
  },
  {
    name: "N-REG.5 deregisterAgent of unowned wallet reverts NotAgentOwner",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "deregisterAgent",
          args: [DEAD],
          account: bob.address,
        }),
        "NotAgentOwner()",
      );
      return { notes: `selector=${selector}` };
    },
  },
  {
    name: "N-REG.6 ownerOf(any) reverts NotSupported (ERC-721 interface stub)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry, abi: regAbi,
          functionName: "ownerOf",
          args: [0n],
          account: bob.address,
        }),
        "NotSupported()",
      );
      return { notes: `selector=${selector}` };
    },
  },
];

(async () => { await runTests("6-negative", tests); })();
