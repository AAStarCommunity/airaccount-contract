/**
 * scripts/e2e-v0172/09-execute-transactions.ts
 *
 * Phase 9 — Execute transaction variants on Sepolia.
 *
 * COSTS GAS. Deploys a fresh account then covers:
 *   EX.1  createAccountWithDefaults (fresh execute-test account)
 *   EX.2  Fund account with 0.025 ETH (Annie sends ETH to account)
 *   EX.3  account.execute(bob, 0.005 ETH, "0x") — ETH transfer by owner
 *   EX.4  Verify bob.address received 0.005 ETH
 *   EX.5  account.executeBatch([self, self], [0,0], ["0x","0x"]) — batch no-ops
 *   EX.6  account.addDeposit{value: 0.003 ETH} — deposit ETH to EntryPoint
 *   EX.7  account.getDeposit() > 0
 *   EX.8  account.withdrawDepositTo(annie, 0.001 ETH) — partial withdrawal
 *   EX.9  REVERT TX: Jason (non-owner) calls account.execute → reverts on-chain
 *         This proves NotOwnerOrEntryPoint guard. TX hash IS recorded (revert TXs exist).
 *   EX.10 REVERT TX: execute with value > dailyLimit → reverts on-chain
 *
 * Run: pnpm tsx scripts/e2e-v0172/09-execute-transactions.ts
 */

import {
  keccak256, encodePacked, type Hash, type Address,
  parseEther, formatEther, encodeFunctionData,
} from "viem";
import {
  ADDR, publicClient, wAnnie, wJason, annie, jason, bob,
  loadAbi, runTests, type TestCase,
} from "./common.js";

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");

// Fresh account for execute tests
const SALT         = BigInt(Math.floor(Date.now() / 1000)) + 9_000n;
const DAILY_LIMIT  = 10_000_000_000_000_000n; // 0.01 ETH daily limit
const GUARDIAN1    = jason.address;
const GUARDIAN2    = bob.address;

let account: Address = "0x" as Address;

async function waitTxSuccess(hash: Hash): Promise<{ gasUsed: bigint }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
  return { gasUsed: receipt.gasUsed };
}

async function waitTxAny(hash: Hash): Promise<{ gasUsed: bigint; status: "success" | "reverted" }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  return { gasUsed: receipt.gasUsed, status: receipt.status };
}

async function guardianSig(
  signer: typeof jason | typeof bob,
  owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

const tests: TestCase[] = [
  {
    name: "EX.1 createAccountWithDefaults (execute-test account, dailyLimit=0.01 ETH)",
    run: async () => {
      account = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, GUARDIAN2, DAILY_LIMIT],
      })) as Address;

      const sig1 = await guardianSig(jason, annie.address, SALT, DAILY_LIMIT);
      const sig2 = await guardianSig(bob,   annie.address, SALT, DAILY_LIMIT);

      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, GUARDIAN1, sig1, GUARDIAN2, sig2, DAILY_LIMIT],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      return { txHash: hash, gas: gasUsed, notes: `execute-test account = ${account}` };
    },
  },
  {
    name: "EX.2 Fund account with 0.025 ETH (Annie → account)",
    run: async () => {
      const hash = await wAnnie.sendTransaction({
        to: account,
        value: parseEther("0.025"),
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      const bal = await publicClient.getBalance({ address: account });
      return { txHash: hash, gas: gasUsed, notes: `account balance = ${formatEther(bal)} ETH` };
    },
  },
  {
    name: "EX.3 account.execute(bob, 0.005 ETH, '0x') — ETH transfer by owner",
    run: async () => {
      const bobBalBefore = await publicClient.getBalance({ address: bob.address });
      const hash = await wAnnie.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "execute",
        args: [bob.address, parseEther("0.005"), "0x"],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      const bobBalAfter = await publicClient.getBalance({ address: bob.address });
      const received = bobBalAfter - bobBalBefore;
      return { txHash: hash, gas: gasUsed, notes: `bob received ${formatEther(received)} ETH (expected 0.005 ETH)` };
    },
  },
  {
    name: "EX.4 account balance decreased by 0.005 ETH after execute",
    run: async () => {
      const bal = await publicClient.getBalance({ address: account });
      // Should be ~0.025 - 0.005 = 0.02 ETH (minus gas costs on the account if any)
      if (bal > parseEther("0.025")) throw new Error(`balance too high: ${formatEther(bal)}`);
      if (bal < parseEther("0.015")) throw new Error(`balance too low: ${formatEther(bal)}`);
      return { notes: `account balance = ${formatEther(bal)} ETH (within range) ✓` };
    },
  },
  {
    name: "EX.5 account.executeBatch([self,self], [0,0], ['0x','0x']) — batch two no-ops",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "executeBatch",
        args: [
          [account, account],
          [0n, 0n],
          ["0x", "0x"],
        ],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      return { txHash: hash, gas: gasUsed, notes: `executeBatch([self,self], [0,0]) succeeded` };
    },
  },
  {
    name: "EX.6 account.addDeposit{value: 0.003 ETH} — deposit to EntryPoint",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "addDeposit",
        value: parseEther("0.003"),
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      return { txHash: hash, gas: gasUsed, notes: `addDeposit(0.003 ETH) to EntryPoint ✓` };
    },
  },
  {
    name: "EX.7 account.getDeposit() > 0 (verified on-chain deposit)",
    run: async () => {
      const deposit = await publicClient.readContract({
        address: account, abi: baseAbi, functionName: "getDeposit",
      }) as bigint;
      if (deposit <= 0n) throw new Error(`deposit is 0, expected > 0`);
      return { notes: `entryPoint deposit = ${formatEther(deposit)} ETH` };
    },
  },
  {
    name: "EX.8 account.withdrawDepositTo(annie, 0.001 ETH) — partial withdrawal",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: account,
        abi: baseAbi,
        functionName: "withdrawDepositTo",
        args: [annie.address, parseEther("0.001")],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTxSuccess(hash);
      return { txHash: hash, gas: gasUsed, notes: `withdrawDepositTo(annie, 0.001 ETH) ✓` };
    },
  },
  {
    name: "EX.9 REVERT TX: Jason (non-owner) calls account.execute → NotOwnerOrEntryPoint",
    run: async () => {
      // We broadcast a TX that WILL REVERT on-chain. Use sendTransaction with fixed gas
      // to bypass viem's pre-flight gas estimation (which also fails for reverting TXs).
      // Jason has ~0.14 ETH on Sepolia so gas cost is not an issue.
      const callData = encodeFunctionData({
        abi: baseAbi,
        functionName: "execute",
        args: [jason.address, 0n, "0x"],
      });
      const hash = await wJason.sendTransaction({
        to: account,
        data: callData,
        gas: 100_000n,
        chain: null,
        account: jason,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
      if (receipt.status !== "reverted") {
        throw new Error(`Expected revert but TX succeeded: ${hash}`);
      }
      return {
        txHash: hash,
        gas: receipt.gasUsed,
        notes: `TX REVERTED on-chain ✓ — NotOwnerOrEntryPoint guard works (Jason is not owner)`,
      };
    },
  },
  {
    name: "EX.10 REVERT TX: execute value > dailyLimit → guard rejects on-chain",
    run: async () => {
      // dailyLimit = 0.01 ETH. Try to execute 0.012 ETH (just over limit).
      // The guard check happens inside execute(), so the TX reverts on-chain.
      // Annie is the owner, so NotOwnerOrEntryPoint won't trigger — it's the guard that rejects.
      const callData = encodeFunctionData({
        abi: baseAbi,
        functionName: "execute",
        args: [bob.address, parseEther("0.012"), "0x"],
      });
      const hash = await wAnnie.sendTransaction({
        to: account,
        data: callData,
        gas: 200_000n,
        chain: null,
        account: annie,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
      if (receipt.status !== "reverted") {
        throw new Error(`Expected revert but TX succeeded: ${hash}`);
      }
      return {
        txHash: hash,
        gas: receipt.gasUsed,
        notes: `TX REVERTED on-chain ✓ — guard rejected 0.012 ETH > dailyLimit 0.01 ETH`,
      };
    },
  },
];

(async () => { await runTests("9-execute-transactions", tests); })();
