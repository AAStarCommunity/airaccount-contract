/**
 * scripts/e2e-v0172/07-beta3-features.ts
 *
 * Phase 7 — beta.3 new feature coverage (read-only + simulations).
 *
 * Tests specific to v0.17.2-beta.3 that are NOT covered in phases 01–06:
 *   VERSION constants: FACTORY_VERSION, MODULE_VERSION (ForceExit + SessionKey)
 *   Router finalized: setupComplete == true (hard assertion — finalizeSetup() was called)
 *   Factory custom errors: typed selector verification for GuardiansRequired etc.
 *   ForceExitModule.IncompatibleAccount: simulate onInstall on an EOA/guardian-less account
 *   AgentRegistry state: fresh beta.3 registry, correct factory binding
 *
 * All tests are read-only or simulation-only — no on-chain state changes.
 *
 * Run: pnpm tsx scripts/e2e-v0172/07-beta3-features.ts
 */

import { encodeFunctionData, zeroAddress } from "viem";
import {
  ADDR,
  publicClient,
  wAnnie,
  jason,
  bob,
  loadAbi,
  runTests,
  expectRevert,
  expectRawCallRevert,
  type TestCase,
} from "./common.js";

const factoryAbi   = loadAbi("AAStarAirAccountFactoryV7");
const implAbi      = loadAbi("AAStarAirAccountV7");
const forceExitAbi = loadAbi("ForceExitModule");
const skAbi        = loadAbi("SessionKeyValidator");
const routerAbi    = loadAbi("AAStarValidator");
const regAbi       = loadAbi("AgentRegistry");

const tests: TestCase[] = [
  // ─── V1: VERSION constants (beta.3 on-chain observability) ──────────────

  {
    name: "V1.a factory.FACTORY_VERSION() == '0.17.2'",
    run: async () => {
      const v = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "FACTORY_VERSION",
      });
      if (v !== "0.17.2") throw new Error(`expected '0.17.2', got '${v}'`);
      return { notes: `FACTORY_VERSION = '${v}'` };
    },
  },

  {
    name: "V1.b impl.ACCOUNT_VERSION() == '0.17.2'",
    run: async () => {
      const v = await publicClient.readContract({
        address: ADDR.impl,
        abi: implAbi,
        functionName: "ACCOUNT_VERSION",
      });
      if (v !== "0.17.2") throw new Error(`expected '0.17.2', got '${v}'`);
      return { notes: `ACCOUNT_VERSION = '${v}'` };
    },
  },

  {
    name: "V1.c forceExitModule.MODULE_VERSION() == '0.17.2'",
    run: async () => {
      const v = await publicClient.readContract({
        address: ADDR.forceExitModule,
        abi: forceExitAbi,
        functionName: "MODULE_VERSION",
      });
      if (v !== "0.17.2") throw new Error(`expected '0.17.2', got '${v}'`);
      return { notes: `ForceExitModule.MODULE_VERSION = '${v}'` };
    },
  },

  {
    name: "V1.d sessionKeyValidator.MODULE_VERSION() == '0.17.2'",
    run: async () => {
      const v = await publicClient.readContract({
        address: ADDR.sessionKeyValidator,
        abi: skAbi,
        functionName: "MODULE_VERSION",
      });
      if (v !== "0.17.2") throw new Error(`expected '0.17.2', got '${v}'`);
      return { notes: `SessionKeyValidator.MODULE_VERSION = '${v}'` };
    },
  },

  // ─── V2: Router finalized — setupComplete must be true ──────────────────

  {
    name: "V2.a router.setupComplete() == true (finalizeSetup was called)",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.validatorRouter,
        abi: routerAbi,
        functionName: "setupComplete",
      });
      if (!ok) throw new Error("setupComplete is false — finalizeSetup() may not have been called");
      return { notes: "Router locked — future algo changes require proposeAlgorithm + 7d timelock" };
    },
  },

  {
    name: "V2.b router.registerAlgorithm after setupComplete reverts SetupAlreadyClosed",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.validatorRouter,
          abi: routerAbi,
          functionName: "registerAlgorithm",
          args: [0x99, zeroAddress],
          account: wAnnie.account!.address,
        }),
        "SetupAlreadyClosed()",
      );
      return { notes: `registerAlgorithm post-finalize blocked — selector ${selector}` };
    },
  },

  // ─── V3: Factory custom errors via createAccountWithDefaults ────────────
  // Signature: (owner, salt, guardian1, guardian1Sig, guardian2, guardian2Sig, dailyLimit)
  // GuardiansRequired / GuardiansMustBeDistinct / DailyLimitRequired all fire BEFORE
  // guardian signature verification, so we can pass empty sigs to reach those checks.

  {
    name: "V3.a factory.createAccountWithDefaults: guardian1==0 reverts GuardiansRequired",
    run: async () => {
      const { selector } = await expectRawCallRevert(
        {
          to: ADDR.factory,
          data: encodeFunctionData({
            abi: factoryAbi,
            functionName: "createAccountWithDefaults",
            args: [
              bob.address,     // owner
              0n,              // salt
              zeroAddress,     // guardian1 = 0x0 → GuardiansRequired
              "0x" as `0x${string}`,
              jason.address,
              "0x" as `0x${string}`,
              1000000000000000n,
            ],
          }),
          from: bob.address,
        },
        "GuardiansRequired()",
      );
      return { notes: `Factory custom error GuardiansRequired — selector ${selector}` };
    },
  },

  {
    name: "V3.b factory.createAccountWithDefaults: guardian1==guardian2 reverts GuardiansMustBeDistinct",
    run: async () => {
      const { selector } = await expectRawCallRevert(
        {
          to: ADDR.factory,
          data: encodeFunctionData({
            abi: factoryAbi,
            functionName: "createAccountWithDefaults",
            args: [
              bob.address,
              0n,
              bob.address,    // guardian1 == guardian2 → GuardiansMustBeDistinct
              "0x" as `0x${string}`,
              bob.address,
              "0x" as `0x${string}`,
              1000000000000000n,
            ],
          }),
          from: bob.address,
        },
        "GuardiansMustBeDistinct()",
      );
      return { notes: `Factory custom error GuardiansMustBeDistinct — selector ${selector}` };
    },
  },

  {
    name: "V3.c factory.createAccountWithDefaults: dailyLimit==0 reverts DailyLimitRequired",
    run: async () => {
      const { selector } = await expectRawCallRevert(
        {
          to: ADDR.factory,
          data: encodeFunctionData({
            abi: factoryAbi,
            functionName: "createAccountWithDefaults",
            args: [
              bob.address,
              0n,
              bob.address,
              "0x" as `0x${string}`,
              jason.address,
              "0x" as `0x${string}`,
              0n,   // dailyLimit = 0 → DailyLimitRequired
            ],
          }),
          from: bob.address,
        },
        "DailyLimitRequired()",
      );
      return { notes: `Factory custom error DailyLimitRequired — selector ${selector}` };
    },
  },

  // ─── V4: ForceExitModule — IncompatibleAccount guard ────────────────────

  {
    name: "V4.a forceExitModule.onInstall from EOA (no guardians()) reverts IncompatibleAccount",
    run: async () => {
      // Bob is a plain EOA — no guardians() getter. onInstall must revert IncompatibleAccount.
      const { selector } = await expectRawCallRevert(
        {
          to: ADDR.forceExitModule,
          data: encodeFunctionData({
            abi: forceExitAbi,
            functionName: "onInstall",
            args: ["0x" as `0x${string}`],
          }),
          from: bob.address,  // msg.sender = bob (EOA, no guardians())
        },
        "IncompatibleAccount()",
      );
      return { notes: `ForceExit rejects guardian-less callers — selector ${selector}` };
    },
  },

  // ─── V5: AgentRegistry state — beta.3 registry fully wired ─────────────

  {
    name: "V5.a agentRegistry.factory() == beta3 factory (not beta.2)",
    run: async () => {
      const f = await publicClient.readContract({
        address: ADDR.agentRegistry,
        abi: regAbi,
        functionName: "factory",
      });
      if ((f as string).toLowerCase() !== ADDR.factory.toLowerCase()) {
        throw new Error(`expected beta3 factory ${ADDR.factory}, got ${f} — wrong registry or missing wiring`);
      }
      return { notes: `AgentRegistry → Factory wiring confirmed (beta.3)` };
    },
  },

  {
    name: "V5.b factory.agentRegistry() == beta3 AgentRegistry",
    run: async () => {
      const r = await publicClient.readContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "agentRegistry",
      });
      if ((r as string).toLowerCase() !== ADDR.agentRegistry.toLowerCase()) {
        throw new Error(`expected beta3 registry ${ADDR.agentRegistry}, got ${r}`);
      }
      return { notes: `Factory → AgentRegistry reverse-wiring confirmed (beta.3)` };
    },
  },

  {
    name: "V5.c agentRegistry.bindFactory(factory) now reverts FactoryAlreadyBound (set-once)",
    run: async () => {
      const { selector } = await expectRevert(
        () => publicClient.simulateContract({
          address: ADDR.agentRegistry,
          abi: regAbi,
          functionName: "bindFactory",
          args: [ADDR.factory],
          account: wAnnie.account!.address,  // Anni is deployer — hits FactoryAlreadyBound first
        }),
        "FactoryAlreadyBound()",
      );
      return { notes: `Set-once bindFactory enforced — selector ${selector}` };
    },
  },
];

(async () => {
  await runTests("7-beta3-features", tests);
})();
