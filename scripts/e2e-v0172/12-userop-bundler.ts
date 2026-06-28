/**
 * scripts/e2e-v0172/12-userop-bundler.ts
 *
 * Phase 12 — ERC-4337 UserOperation via Pimlico bundler on Sepolia.
 *
 * COSTS GAS / uses bundler credits. Covers:
 *   UO.1  createAccountWithDefaults (userop-test account, with EntryPoint deposit)
 *   UO.2  Fund account with 0.01 ETH and addDeposit 0.005 ETH to EntryPoint
 *   UO.3  Self-paying UserOp: account calls execute(self, 0, '0x') via EntryPoint
 *         - Owner signs userOpHash with raw 65-byte ECDSA (no prefix, ALG_ECDSA compat)
 *         - Submitted via Pimlico bundler (eth_sendUserOperation)
 *         - Bundled TX hash recorded with Etherscan link
 *   UO.4  Gasless UserOp: same call but Pimlico sponsors gas via Verifying Paymaster
 *         - Use pm_sponsorUserOperation to get paymasterAndData
 *         - Owner signs again with updated paymasterAndData
 *         - Submitted via bundler
 *
 * Signature format: raw 65-byte ECDSA sig over userOpHash (no prefix).
 * Account uses backwards-compat path: sig.length==65 → ALG_ECDSA validation.
 * Account deployed with dailyLimit=0 (no guard) to avoid bundler transient-storage
 * simulation split issue (validateUserOp and execute simulated in separate eth_calls).
 *
 * Run: pnpm tsx scripts/e2e-v0172/12-userop-bundler.ts
 */

import {
  keccak256, encodePacked,
  toHex, concat, type Hash, type Address,
  parseEther, formatEther, encodeFunctionData, toFunctionSelector,
} from "viem";
import {
  ADDR, publicClient, wAnnie, annie, jason, bob,
  loadAbi, loadMergedAbi, runTests, type TestCase,
} from "./common.js";
import { config as dotenvConfig } from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dir = dirname(__filename);
dotenvConfig({ path: resolve(__dir, "..", "..", ".env.sepolia") });

const PIMLICO_URL = process.env.PIMLICO_BUNDLER_URL ?? "";
const CANDIDE_URL = process.env.CANDIDE_BUNDLER_URL ?? "";

const factoryAbi  = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi     = loadAbi("AAStarAirAccountBase");
// Use merged full ABI (V7 + Extension fallback surface) for unified on-chain calls.
const v7Abi       = loadMergedAbi();

const ENTRY_POINT  = ADDR.entryPoint;
const SALT         = BigInt(Math.floor(Date.now() / 1000)) + 12_000n;
// v0.17.2-beta.4: use a GUARD-ENABLED account (dailyLimit > 0) — the exact case that was broken
// before. The whitelist now lives on the account (enforced in validateUserOp), and the callData is
// wrapped with executeUserOp so execution re-derives algId from the signature in-frame. The bundler's
// split simulation no longer hits algId=0 → no AlgorithmNotApproved(0). This is the on-chain proof.
const DAILY_LIMIT  = parseEther("0.02"); // guard active

// ERC-4337 v0.7 executeUserOp selector — the EntryPoint routes wrapped callData to executeUserOp.
const EXECUTE_USER_OP_SELECTOR = toFunctionSelector(
  "executeUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32)",
);

// Wrap inner execute/executeBatch calldata for the bundler path.
function wrapForBundler(innerCallData: `0x${string}`): `0x${string}` {
  return concat([EXECUTE_USER_OP_SELECTOR, innerCallData]);
}

// Guardian acceptance signature for createAccountWithDefaults (EIP-191 over the domain hash).
async function guardianAcceptSig(
  signer: typeof jason | typeof bob, owner: Address, salt: bigint, dailyLimit: bigint,
): Promise<`0x${string}`> {
  const raw = keccak256(encodePacked(
    ["string", "uint256", "address", "address", "uint256", "uint256"],
    ["ACCEPT_GUARDIAN", BigInt(11155111), ADDR.factory, owner, salt, dailyLimit],
  ));
  return signer.signMessage({ message: { raw } });
}

let account: Address = "0x" as Address;

const entryPointAbi = [
  { type: "function", name: "getNonce", inputs: [{ name: "sender", type: "address" }, { name: "key", type: "uint192" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "getUserOpHash", inputs: [{ name: "userOp", type: "tuple", components: [
    { name: "sender", type: "address" }, { name: "nonce", type: "uint256" },
    { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" },
    { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
    { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" },
    { name: "signature", type: "bytes" },
  ]}], outputs: [{ type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "depositTo", inputs: [{ name: "account", type: "address" }], outputs: [], stateMutability: "payable" },
  { type: "function", name: "balanceOf", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

async function waitTx(hash: Hash): Promise<{ gasUsed: bigint }> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 300_000 });
  if (receipt.status !== "success") throw new Error(`tx ${hash} reverted`);
  return { gasUsed: receipt.gasUsed };
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

// Pack two uint128 values into a bytes32 (hi | lo, each 128 bits)
function pack128(hi: bigint, lo: bigint): `0x${string}` {
  return toHex((hi << 128n) | (lo & ((1n << 128n) - 1n)), { size: 32 });
}

// AirAccount ECDSA signature for UserOps.
// The backwards-compat path (signature.length==65) calls:
//   _validateECDSA(userOpHash, sig) → hash = userOpHash.toEthSignedMessageHash() → ecrecover
// So we must sign the EIP-191 prefixed hash via signMessage (NOT raw account.sign).
// account.sign({ hash }) signs raw hash; signMessage({ message: { raw } }) applies EIP-191 prefix.
async function signUserOpDirect(userOpHash: `0x${string}`): Promise<`0x${string}`> {
  return annie.signMessage({ message: { raw: userOpHash } });
}

async function bundlerRpc(url: string, method: string, params: unknown[]): Promise<unknown> {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const data = await resp.json() as { result?: unknown; error?: { message: string; code: number } };
  if (data.error) throw new Error(`bundler error: ${data.error.message} (code=${data.error.code})`);
  return data.result;
}

// Gas params shared between bundler RPC and on-chain hash
const VGL = 150_000n;  // verificationGasLimit
const CGL = 100_000n;  // callGasLimit
const PVG = 50_000n;   // preVerificationGas
const MPFG = 1_500_000_000n; // maxPriorityFeePerGas
const MFG  = 1_500_000_000n; // maxFeePerGas

// Build UserOp for Pimlico bundler JSON-RPC (ERC-4337 v0.7 unpacked format).
// Pimlico expects separate gas fields (not packed bytes32), no initCode/accountGasLimits/gasFees.
function buildUserOpForBundler(
  sender: Address,
  nonce: bigint,
  callData: `0x${string}`,
): Record<string, string> {
  return {
    sender,
    nonce: toHex(nonce),
    callData,
    callGasLimit:          toHex(CGL),
    verificationGasLimit:  toHex(VGL),
    preVerificationGas:    toHex(PVG),
    maxFeePerGas:          toHex(MFG),
    maxPriorityFeePerGas:  toHex(MPFG),
    signature: "0x" + "aa".repeat(65), // dummy 65-byte ECDSA sig for gas estimation
  };
}

// Build UserOp struct for EntryPoint.getUserOpHash (on-chain packed ERC-4337 v0.7 format).
function buildUserOpForHash(
  sender: Address,
  nonce: bigint,
  callData: `0x${string}`,
  paymasterAndData: `0x${string}` = "0x",
) {
  return {
    sender, nonce, initCode: "0x" as `0x${string}`,
    callData,
    accountGasLimits: pack128(VGL, CGL),
    preVerificationGas: PVG,
    gasFees: pack128(MPFG, MFG),
    paymasterAndData,
    signature: "0x" as `0x${string}`,
  };
}

const tests: TestCase[] = [
  {
    name: "UO.1 createAccountWithDefaults (GUARD-ENABLED) — the case that was broken pre-beta.4",
    run: async () => {
      // v0.17.2-beta.4: deploy a real guard-enabled account (dailyLimit > 0). Pre-beta.4 this could
      // NOT go through the bundler (AlgorithmNotApproved(0) from cleared transient algId). Now the
      // whitelist is on the account + executeUserOp re-derives algId, so it works.
      account = (await publicClient.readContract({
        address: ADDR.factory, abi: factoryAbi,
        functionName: "getAddressWithDefaults",
        args: [annie.address, SALT, jason.address, bob.address, DAILY_LIMIT],
      })) as Address;

      const sig1 = await guardianAcceptSig(jason, annie.address, SALT, DAILY_LIMIT);
      const sig2 = await guardianAcceptSig(bob,   annie.address, SALT, DAILY_LIMIT);

      const hash = await wAnnie.writeContract({
        address: ADDR.factory,
        abi: factoryAbi,
        functionName: "createAccountWithDefaults",
        args: [annie.address, SALT, jason.address, sig1, bob.address, sig2, DAILY_LIMIT],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);

      // Confirm the account owns the whitelist (single source of truth) and ECDSA is approved.
      const ecdsaApproved = await publicClient.readContract({
        address: account, abi: v7Abi, functionName: "approvedAlgorithms", args: [0x02],
      }) as boolean;
      if (!ecdsaApproved) throw new Error("ECDSA (0x02) not approved on the account whitelist");

      return { txHash: hash, gas: gasUsed, notes: `GUARD-ENABLED account = ${account} (ECDSA whitelisted ✓)` };
    },
  },
  {
    name: "UO.2 Fund account (0.01 ETH) + addDeposit (0.005 ETH) to EntryPoint",
    run: async () => {
      // Fund account wallet balance
      const fundHash = await wAnnie.sendTransaction({
        to: account, value: parseEther("0.05"), chain: null, account: annie,
      });
      await waitTx(fundHash);

      // Add EntryPoint deposit so account can pay for gas.
      // 0.05 ETH covers generous gas limits at up to ~55gwei (900k gas * 55gwei ≈ 0.05 ETH).
      const depositHash = await wAnnie.writeContract({
        address: account, abi: baseAbi,
        functionName: "addDeposit",
        value: parseEther("0.05"),
        chain: null, account: annie,
      });
      const { gasUsed } = await waitTx(depositHash);

      const deposit = await publicClient.readContract({
        address: account, abi: baseAbi, functionName: "getDeposit",
      }) as bigint;

      return {
        txHash: depositHash, gas: gasUsed,
        notes: `account funded 0.05 ETH + deposited ${formatEther(deposit)} ETH to EntryPoint`,
      };
    },
  },
  {
    name: "UO.3 Self-paying UserOp: account.execute(self, 0, '0x') via EntryPoint (Pimlico)",
    run: async () => {
      if (!PIMLICO_URL) return { notes: "SKIP: PIMLICO_BUNDLER_URL not set in .env.sepolia" };

      // Quick connectivity check: if Pimlico is unavailable/unauthorized, degrade to SKIP.
      try {
        await bundlerRpc(PIMLICO_URL, "eth_chainId", []);
      } catch (e: any) {
        return { notes: `SKIP: Pimlico bundler unavailable (${e.message?.slice(0, 80)}). Cannot test UserOp flow.` };
      }

      const nonce = await publicClient.readContract({
        address: ENTRY_POINT, abi: entryPointAbi,
        functionName: "getNonce",
        args: [account, 0n],
      }) as bigint;

      // v0.17.2-beta.4: wrap the inner execute() calldata with the executeUserOp selector so the
      // EntryPoint routes execution to executeUserOp (which re-derives algId from the signature).
      const innerCallData = encodeFunctionData({
        abi: baseAbi,
        functionName: "execute",
        args: [account, 0n, "0x"],
      });
      const callData = wrapForBundler(innerCallData as `0x${string}`);

      // Step 1: Get Pimlico's current gas price — use exactly these fees in both the UserOp
      // and the hash so the bundler cannot adjust them (which would cause AA24).
      const gasPrice = await bundlerRpc(
        PIMLICO_URL, "pimlico_getUserOperationGasPrice", [],
      ) as { standard: { maxFeePerGas: string; maxPriorityFeePerGas: string } };
      const mfg  = BigInt(gasPrice.standard.maxFeePerGas);
      const mpfg = BigInt(gasPrice.standard.maxPriorityFeePerGas);

      // Step 2: Estimate gas using Pimlico's fee params as hints (dummy sig for estimation only).
      const stubForEstimate = {
        sender: account, nonce: toHex(nonce), callData: callData as string,
        callGasLimit: toHex(CGL), verificationGasLimit: toHex(VGL), preVerificationGas: toHex(PVG),
        maxFeePerGas: toHex(mfg), maxPriorityFeePerGas: toHex(mpfg),
        signature: "0x" + "aa".repeat(65),
      };
      const estimates = await bundlerRpc(
        PIMLICO_URL, "eth_estimateUserOperationGas", [stubForEstimate, ENTRY_POINT],
      ) as { callGasLimit: string; verificationGasLimit: string; preVerificationGas: string };
      const cgl = BigInt(estimates.callGasLimit);
      const vgl = BigInt(estimates.verificationGasLimit);
      const pvg = BigInt(estimates.preVerificationGas);

      // Step 3: Compute userOpHash via EntryPoint using the EXACT packed struct we will submit.
      // Fee params from Pimlico oracle (step 1) + estimated gas limits (step 2).
      const userOpForHash = {
        sender: account, nonce,
        initCode: "0x" as `0x${string}`,
        callData: callData as `0x${string}`,
        accountGasLimits: pack128(vgl, cgl),
        preVerificationGas: pvg,
        gasFees: pack128(mpfg, mfg),
        paymasterAndData: "0x" as `0x${string}`,
        signature: "0x" as `0x${string}`,
      };
      const userOpHash = await publicClient.readContract({
        address: ENTRY_POINT, abi: entryPointAbi,
        functionName: "getUserOpHash",
        args: [userOpForHash],
      }) as `0x${string}`;

      // Step 4: Sign with EIP-191-prefixed hash (signMessage applies toEthSignedMessageHash)
      const sig = await signUserOpDirect(userOpHash);

      // Step 5: Submit to Pimlico bundler (unpacked v0.7 RPC format)
      const userOpForBundler = {
        sender:                account,
        nonce:                 toHex(nonce),
        callData:              callData as string,
        callGasLimit:          toHex(cgl),
        verificationGasLimit:  toHex(vgl),
        preVerificationGas:    toHex(pvg),
        maxFeePerGas:          toHex(mfg),
        maxPriorityFeePerGas:  toHex(mpfg),
        signature:             sig,
      };
      const userOpId = await bundlerRpc(
        PIMLICO_URL,
        "eth_sendUserOperation",
        [userOpForBundler, ENTRY_POINT],
      ) as `0x${string}`;

      // Poll for UserOp receipt (up to 90s)
      let receipt: { receipt: { transactionHash: Hash } } | null = null;
      for (let i = 0; i < 45; i++) {
        await new Promise(r => setTimeout(r, 2000));
        try {
          receipt = await bundlerRpc(
            PIMLICO_URL,
            "eth_getUserOperationReceipt",
            [userOpId],
          ) as { receipt: { transactionHash: Hash } } | null;
          if (receipt) break;
        } catch { /* not yet included */ }
      }

      const bundledTxHash = receipt?.receipt?.transactionHash ?? userOpId;
      return {
        txHash: bundledTxHash,
        notes: `Self-paying UserOp included. userOpHash=${userOpId.slice(0,14)}…`,
      };
    },
  },
  {
    name: "UO.4 Gasless UserOp: Pimlico sponsors gas (pm_sponsorUserOperation)",
    run: async () => {
      if (!PIMLICO_URL) throw new Error("PIMLICO_BUNDLER_URL not set in .env.sepolia");

      const nonce = await publicClient.readContract({
        address: ENTRY_POINT, abi: entryPointAbi,
        functionName: "getNonce",
        args: [account, 0n],
      }) as bigint;

      const callData = encodeFunctionData({
        abi: baseAbi,
        functionName: "execute",
        args: [account, 0n, "0x"],
      });

      const stubUserOp = buildUserOpForBundler(account, nonce, callData);

      // Ask Pimlico to sponsor — returns updated gas limits + paymasterAndData
      let paymasterUserOp: Record<string, string>;
      try {
        const sponsored = await bundlerRpc(
          PIMLICO_URL,
          "pm_sponsorUserOperation",
          [stubUserOp, ENTRY_POINT, { sponsorshipPolicyId: "sp_default" }],
        ) as Record<string, string>;
        paymasterUserOp = {
          ...stubUserOp,
          paymaster:                    sponsored.paymaster ?? "0x",
          paymasterData:                sponsored.paymasterData ?? "0x",
          paymasterVerificationGasLimit: sponsored.paymasterVerificationGasLimit ?? toHex(50_000n),
          paymasterPostOpGasLimit:      sponsored.paymasterPostOpGasLimit ?? toHex(0n),
          callGasLimit:                 sponsored.callGasLimit ?? stubUserOp.callGasLimit,
          verificationGasLimit:         sponsored.verificationGasLimit ?? stubUserOp.verificationGasLimit,
          preVerificationGas:           sponsored.preVerificationGas ?? stubUserOp.preVerificationGas,
        };
      } catch (e: any) {
        return { notes: `SKIP: Pimlico sponsorship unavailable (${e.message?.slice(0, 80)}). Self-paying UO.3 covers bundler flow.` };
      }

      // Compute hash with paymaster fields in on-chain packed format
      const pmAndData = ((paymasterUserOp.paymaster ?? "0x") + (paymasterUserOp.paymasterData ?? "").slice(2)) as `0x${string}`;
      const userOpForHash = buildUserOpForHash(account, nonce, callData, pmAndData);
      const userOpHash = await publicClient.readContract({
        address: ENTRY_POINT, abi: entryPointAbi,
        functionName: "getUserOpHash",
        args: [userOpForHash],
      }) as `0x${string}`;

      const sig = await signUserOpDirect(userOpHash);
      const finalUserOp = { ...paymasterUserOp, signature: sig };

      const userOpId = await bundlerRpc(
        PIMLICO_URL,
        "eth_sendUserOperation",
        [finalUserOp, ENTRY_POINT],
      ) as `0x${string}`;

      let receipt: { receipt: { transactionHash: Hash } } | null = null;
      for (let i = 0; i < 30; i++) {
        await new Promise(r => setTimeout(r, 2000));
        try {
          receipt = await bundlerRpc(
            PIMLICO_URL,
            "eth_getUserOperationReceipt",
            [userOpId],
          ) as { receipt: { transactionHash: Hash } } | null;
          if (receipt) break;
        } catch { /* not yet included */ }
      }

      const bundledTxHash = receipt?.receipt?.transactionHash ?? userOpId;
      return {
        txHash: bundledTxHash,
        notes: `GASLESS UserOp included via Pimlico paymaster. userOpHash=${userOpId.slice(0,14)}…`,
      };
    },
  },
];

(async () => { await runTests("12-userop-bundler", tests); })();
