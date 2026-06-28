/**
 * scripts/e2e-v0172/08-multi-account-types.ts
 *
 * Phase 8 — Multiple account type creation on Sepolia.
 *
 * COSTS GAS. Covers:
 *   AC.1  createAccount (with InitConfig, no guard) — raw owner-controlled account
 *   AC.2  Account bytecode exists at predicted address
 *   AC.3  account.owner() == Annie
 *   AC.4  account.guard() == address(0) (no guard when dailyLimit=0)
 *   AC.5  account.guardianCount() == 2 (jason + bob, no communityGuardian slot)
 *   AC.6  createAgentAccount — agent key + guardian2 consent signatures
 *   AC.7  getAgentAddress matches deployed address
 *   AC.8  AgentRegistry marks agent account valid
 *
 * Run: pnpm tsx scripts/e2e-v0172/08-multi-account-types.ts
 */

import {
  keccak256, encodePacked, toBytes, type Hash, type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  ADDR, publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests, type TestCase,
} from "./common.js";

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");
// Use merged full ABI (V7 + Extension fallback surface) for unified on-chain calls.
const v7Abi      = loadMergedAbi();
const regAbi     = loadAbi("AgentRegistry");

// Unique salt for this run
const SALT_PLAIN = BigInt(Math.floor(Date.now() / 1000)) + 8_000n;

// Agent test: unique agent key per run (keccak256 always returns a valid 32-byte private key)
const AGENT_PRIV = keccak256(encodePacked(
  ["string", "uint256"],
  ["e2e-agent-key-", BigInt(Math.floor(Date.now() / 1000))],
));
const agentWallet = privateKeyToAccount(AGENT_PRIV);
const AGENT_ID    = keccak256(toBytes("e2e-agent-test-" + Math.floor(Date.now() / 1000)));
const DAILY_LIMIT = 1_000_000_000_000_000n; // 0.001 ETH

async function waitTx(hash: Hash): Promise<{ gasUsed: bigint }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
  return { gasUsed: receipt.gasUsed };
}

// Guardian acceptance sig for createAccountWithDefaults: ACCEPT_GUARDIAN
async function guardianAcceptSig(
  signer: typeof jason | typeof bob,
  owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

// Agent key consent sig: ACCEPT_AGENT_KEY
async function agentKeySig(humanOwner: Address, deadline: bigint): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "address", "bytes32", "uint48"],
    ["ACCEPT_AGENT_KEY", BigInt(11155111), ADDR.factory, agentWallet.address, humanOwner, AGENT_ID, Number(deadline)],
  ));
  return agentWallet.signMessage({ message: { raw } });
}

// Guardian2 consent sig for agent account: ACCEPT_AGENT_GUARDIAN (signed by bob = guardian2)
async function agentGuardian2Sig(humanOwner: Address, deadline: bigint): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "address", "bytes32", "uint48"],
    ["ACCEPT_AGENT_GUARDIAN", BigInt(11155111), ADDR.factory, agentWallet.address, humanOwner, AGENT_ID, Number(deadline)],
  ));
  return bob.signMessage({ message: { raw } });
}

let plainAccount: Address = "0x" as Address;
let agentAccount: Address = "0x" as Address;

const tests: TestCase[] = [
  // ─── Plain account via createAccount ─────────────────────────────────────
  {
    name: "AC.1 createAccount with InitConfig (no guard, dailyLimit=0, 2 guardians)",
    run: async () => {
      const ZERO_B32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;
      const config = {
        guardians: [jason.address, bob.address, "0x0000000000000000000000000000000000000000"] as [Address, Address, Address],
        // v0.20.2: guardianP256X/Y for P-256 guardian slots. ECDSA guardians use zeros.
        guardianP256X: [ZERO_B32, ZERO_B32, ZERO_B32] as [typeof ZERO_B32, typeof ZERO_B32, typeof ZERO_B32],
        guardianP256Y: [ZERO_B32, ZERO_B32, ZERO_B32] as [typeof ZERO_B32, typeof ZERO_B32, typeof ZERO_B32],
        dailyLimit: 0n,
        approvedAlgIds: [] as number[],
        minDailyLimit: 0n,
        initialTokens: [] as Address[],
        initialTokenConfigs: [] as { tier1Limit: bigint; tier2Limit: bigint; dailyLimit: bigint }[],
      };

      // Predict address
      plainAccount = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddress",
        args: [annie.address, SALT_PLAIN, config],
      })) as Address;

      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAccount",
        args: [annie.address, SALT_PLAIN, config],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `plain account at ${plainAccount}, salt=${SALT_PLAIN}` };
    },
  },
  {
    name: "AC.2 plain account has bytecode",
    run: async () => {
      const code = await publicClient.getCode({ address: plainAccount });
      if (!code || code === "0x") throw new Error(`no code at ${plainAccount}`);
      return { notes: `${(code.length - 2) / 2} bytes at ${plainAccount}` };
    },
  },
  {
    name: "AC.3 plain account owner == Annie",
    run: async () => {
      const o = await publicClient.readContract({ address: plainAccount, abi: baseAbi, functionName: "owner" }) as string;
      if (o.toLowerCase() !== annie.address.toLowerCase()) throw new Error(`owner=${o}`);
      return { notes: `owner = Anni ✓` };
    },
  },
  {
    name: "AC.4 plain account has no guard (dailyLimit=0)",
    run: async () => {
      const g = await publicClient.readContract({ address: plainAccount, abi: v7Abi, functionName: "guard" }) as string;
      if (g !== "0x0000000000000000000000000000000000000000") throw new Error(`guard=${g} expected zero`);
      return { notes: `guard = address(0) ✓ (no guard when dailyLimit=0)` };
    },
  },
  {
    name: "AC.5 plain account guardianCount == 2 (jason + bob)",
    run: async () => {
      const n = await publicClient.readContract({ address: plainAccount, abi: baseAbi, functionName: "guardianCount" }) as bigint;
      if (Number(n) !== 2) throw new Error(`expected 2, got ${n}`);
      return { notes: `guardianCount = 2 ✓` };
    },
  },

  // ─── Agent account via createAgentAccount ────────────────────────────────
  {
    name: "AC.6 createAgentAccount (agentKey + guardian2 consent sigs)",
    run: async () => {
      const currentBlock = await publicClient.getBlock();
      const deadline = BigInt(Number(currentBlock.timestamp) + 1800); // 30min from now

      const akSig = await agentKeySig(annie.address, deadline);
      const g2Sig = await agentGuardian2Sig(annie.address, deadline);

      // annie = humanOwner (msg.sender), bob = guardian2
      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAgentAccount",
        args: [agentWallet.address, AGENT_ID, bob.address, g2Sig, akSig, Number(deadline), DAILY_LIMIT],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);

      agentAccount = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAgentAddress",
        args: [annie.address, agentWallet.address, AGENT_ID],
      })) as Address;

      return { txHash: hash, gas: gasUsed, notes: `agent account at ${agentAccount}, agentKey=${agentWallet.address.slice(0,10)}…` };
    },
  },
  {
    name: "AC.7 getAgentAddress matches deployed agent account",
    run: async () => {
      const predicted = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAgentAddress",
        args: [annie.address, agentWallet.address, AGENT_ID],
      })) as Address;
      const code = await publicClient.getCode({ address: predicted });
      if (!code || code === "0x") throw new Error(`no code at predicted ${predicted}`);
      return { notes: `predicted = deployed = ${predicted}` };
    },
  },
  {
    name: "AC.8 AgentRegistry.isValidAccount(agentAccount) == true",
    run: async () => {
      const ok = await publicClient.readContract({
        address: ADDR.agentRegistry, abi: regAbi,
        functionName: "isValidAccount", args: [agentAccount],
      });
      if (ok !== true) throw new Error(`expected true, got ${ok}`);
      return { notes: `agent account is registry-valid ✓` };
    },
  },
];

(async () => { await runTests("8-multi-account-types", tests); })();
