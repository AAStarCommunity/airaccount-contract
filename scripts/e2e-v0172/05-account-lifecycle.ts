/**
 * scripts/e2e-v0172/05-account-lifecycle.ts
 *
 * Phase 5 — full per-account lifecycle on Sepolia.
 *
 * COSTS GAS. Estimated: ~0.02 ETH total. Anni is deployer + funder.
 *
 *   AL.1  Predict account address via factory.getAddressWithDefaults
 *   AL.2  factory.createAccountWithDefaults — deploy a real account (with guardian sigs)
 *   AL.3  Account exists at predicted address (code.length > 0)
 *   AL.4  account.owner() returns Anni
 *   AL.5  account.guardianCount() == 3
 *   AL.6  factory marked account valid in AgentRegistry (round 3 markValid)
 *   AL.7  account.execute(self, 0, "") — owner direct call works
 *
 * Run: pnpm tsx scripts/e2e-v0172/05-account-lifecycle.ts
 */

import { encodeAbiParameters, keccak256, type Hash, type Address } from "viem";
import {
  ADDR, publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests,
  type TestCase,
} from "./common.js";

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");
// Use merged full ABI (V7 + Extension fallback surface) for unified on-chain calls.
const v7Abi      = loadMergedAbi();
const regAbi     = loadAbi("AgentRegistry");

// Unique salt per run — use timestamp so we never collide on existing account
const SALT = BigInt(Math.floor(Date.now() / 1000));
const DAILY_LIMIT = 1_000_000_000_000_000n; // 0.001 ETH

// Guardian set: jason + bob (the two non-deployer EOAs in .env)
const GUARDIAN1 = jason.address;
const GUARDIAN2 = bob.address;

let predicted: Address = "0x" as Address;

async function waitTx(hash: Hash): Promise<{ gasUsed: bigint }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
  return { gasUsed: receipt.gasUsed };
}

/**
 * Build the guardian acceptance signature.
 * Mirrors `AAStarAirAccountFactoryV7._guardianAcceptanceHash`:
 *   keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt, dailyLimit))
 *   then toEthSignedMessageHash().
 */
import { signMessage } from "viem/accounts";
import { encodePacked, hashMessage } from "viem";

async function guardianSig(
  signer: typeof jason,
  owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  // Sign as a raw message — viem's `signMessage({ message: { raw }})` applies EIP-191 prefix.
  return await signMessage({ message: { raw }, privateKey: signer.source as any });
}

// signMessage expects either a viem Account or a `privateKey` directly. Easier path:
// reconstruct using jason / bob accounts directly.
async function guardianSigByAccount(
  account: typeof jason | typeof bob,
  owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  // account.signMessage handles EIP-191 packing automatically.
  return await account.signMessage({ message: { raw } });
}

const tests: TestCase[] = [
  {
    name: "AL.1 Predict account address via factory.getAddressWithDefaults",
    run: async () => {
      predicted = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, GUARDIAN2, DAILY_LIMIT],
      })) as Address;
      if (!predicted || predicted.length !== 42) throw new Error(`bad predicted: ${predicted}`);
      return { notes: `predicted = ${predicted}` };
    },
  },
  {
    name: "AL.2 factory.createAccountWithDefaults broadcasts (Anni as owner)",
    run: async () => {
      // Get guardian acceptance sigs
      const sig1 = await guardianSigByAccount(jason, annie.address, SALT, DAILY_LIMIT);
      const sig2 = await guardianSigByAccount(bob,   annie.address, SALT, DAILY_LIMIT);

      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, sig1, GUARDIAN2, sig2, DAILY_LIMIT],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `salt=${SALT}, dailyLimit=${DAILY_LIMIT}` };
    },
  },
  {
    name: "AL.3 predicted account has bytecode after createAccount",
    run: async () => {
      const code = await publicClient.getCode({ address: predicted });
      if (!code || code === "0x") throw new Error(`no code at ${predicted}`);
      return { notes: `code.length = ${(code.length - 2) / 2} bytes` };
    },
  },
  {
    name: "AL.4 account.owner() == Anni",
    run: async () => {
      const o = await publicClient.readContract({
        address: predicted, abi: baseAbi,
        functionName: "owner",
      }) as string;
      if (o.toLowerCase() !== annie.address.toLowerCase()) {
        throw new Error(`expected ${annie.address}, got ${o}`);
      }
      return { notes: `owner = Anni` };
    },
  },
  {
    name: "AL.5 account.guardianCount() == 3",
    run: async () => {
      const n = await publicClient.readContract({
        address: predicted, abi: baseAbi,
        functionName: "guardianCount",
      }) as number;
      if (Number(n) !== 3) throw new Error(`expected 3, got ${n}`);
      return { notes: `guardians: ${GUARDIAN1.slice(0, 10)}…, ${GUARDIAN2.slice(0, 10)}…, communityGuardian` };
    },
  },
  {
    name: "AL.6 AgentRegistry.isValidAccount(account) == true (markValid fired during createAccount)",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "isValidAccount", args: [predicted],
      });
      if (ok !== true) throw new Error(`expected true, got ${ok}`);
      return { notes: `Round 3 markValid loud-fail success: account in factory-provenance set` };
    },
  },
  {
    name: "AL.7 account.accountId() starts with 'airaccount.v7@'",
    run: async () => {
      const id = await publicClient.readContract({
        address: predicted, abi: v7Abi,
        functionName: "accountId",
      }) as string;
      if (!id.startsWith("airaccount.v7@")) throw new Error(`expected accountId starting with 'airaccount.v7@', got "${id}"`);
      return { notes: `accountId = "${id}"` };
    },
  },
  {
    name: "AL.8 account.execute(self, 0, '') — owner direct call passes guard",
    run: async () => {
      // Owner calling execute(self, 0, "") is a no-op that exercises:
      //  - onlyOwnerOrEntryPoint modifier
      //  - _enforceGuard with value=0 (no daily limit consumed)
      //  - _call(dest, 0, "") which just returns ok
      const hash = await wAnnie.writeContract({
        address: predicted,
        abi: baseAbi,
        functionName: "execute",
        args: [predicted, 0n, "0x" as `0x${string}`],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `execute(self, 0, "") succeeded` };
    },
  },
];

(async () => { await runTests("5-lifecycle", tests); })();
