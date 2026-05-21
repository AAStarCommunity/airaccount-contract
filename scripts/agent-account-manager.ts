/**
 * agent-account-manager.ts — Create and manage AirAccount instances for autonomous AI agents.
 *
 * An agent account is a full AirAccount where:
 *   - owner     = agentKey (the AI agent's signing EOA)
 *   - guardian1 = humanOwner (msg.sender, the human who creates the account — auto-accepted)
 *   - guardian2 = a separate backup guardian chosen by the human
 *   - salt      = uint256(keccak256(abi.encodePacked(humanOwner, agentId)))
 *
 * The human does NOT need to provide a signature for guardian1 (they are the caller).
 * Only guardian2 must sign the domain-separated acceptance message.
 *
 * Usage:
 *   pnpm tsx scripts/agent-account-manager.ts
 *
 * Required env vars (in scripts/../SuperPaymaster/.env.sepolia or similar):
 *   PRIVATE_KEY_ALICE  — human owner's private key
 *   PRIVATE_KEY_BOB    — guardian2's private key (for signing acceptance)
 *   FACTORY_ADDRESS    — deployed AAStarAirAccountFactoryV7 address
 *   RPC_URL_SEPOLIA    — Sepolia RPC endpoint
 */

import { config } from "dotenv";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  encodePacked,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

config({ path: resolve(__dirname, "../SuperPaymaster/.env.sepolia") });

// ─── ABI (minimal — only the new agent account functions) ──────────────────

const factoryAbi = [
  {
    name: "createAgentAccount",
    type: "function",
    inputs: [
      { name: "agentKey",    type: "address" },
      { name: "agentId",     type: "bytes32" },
      { name: "guardian2",   type: "address" },
      { name: "guardian2Sig",type: "bytes"   },
      { name: "dailyLimit",  type: "uint256" },
    ],
    outputs: [{ name: "account", type: "address" }],
    stateMutability: "nonpayable",
  },
  {
    name: "getAgentAddress",
    type: "function",
    inputs: [
      { name: "humanOwner", type: "address" },
      { name: "agentKey",   type: "address" },
      { name: "agentId",    type: "bytes32" },
    ],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

// ─── Guardian2 acceptance signature ────────────────────────────────────────

/**
 * Build the domain-separated guardian2 acceptance hash.
 *
 * Hash = keccak256("ACCEPT_GUARDIAN" ++ chainId ++ factory ++ agentKey ++ salt)
 * where salt = uint256(keccak256(abi.encodePacked(humanOwner, agentId)))
 *
 * Then sign with toEthSignedMessageHash (prefix "\x19Ethereum Signed Message:\n32").
 */
async function buildGuardian2Sig(params: {
  guardian2: ReturnType<typeof privateKeyToAccount>;
  humanOwner: Address;
  agentKey: Address;
  agentId: Hex;
  factory: Address;
  chainId: number;
}): Promise<Hex> {
  const { guardian2, humanOwner, agentKey, agentId, factory, chainId } = params;

  // Derive salt the same way the factory does
  const salt = BigInt(
    keccak256(encodePacked(["address", "bytes32"], [humanOwner, agentId]))
  );

  // Build acceptance raw hash
  const rawHash = keccak256(
    encodePacked(
      ["string", "uint256", "address", "address", "uint256"],
      ["ACCEPT_GUARDIAN", BigInt(chainId), factory, agentKey, salt]
    )
  );

  // Sign with Ethereum personal_sign prefix
  const signature = await guardian2.signMessage({ message: { raw: rawHash } });
  return signature;
}

// ─── Main demo ─────────────────────────────────────────────────────────────

async function main() {
  console.log("Agent Account Manager — AirAccount for Autonomous AI Agents");
  console.log("=".repeat(60));

  // ── Validate env ──
  const rpcUrl      = process.env.RPC_URL_SEPOLIA;
  const factoryAddr = process.env.FACTORY_ADDRESS as Address | undefined;
  const humanPk     = process.env.PRIVATE_KEY_ALICE as Hex | undefined;
  const guardian2Pk = process.env.PRIVATE_KEY_BOB   as Hex | undefined;

  if (!rpcUrl || !factoryAddr || !humanPk || !guardian2Pk) {
    console.log("\nRequired env vars: RPC_URL_SEPOLIA, FACTORY_ADDRESS, PRIVATE_KEY_ALICE, PRIVATE_KEY_BOB");
    console.log("\nDemo: showing address prediction (no on-chain calls)");
    console.log("\nTo create an agent account:");
    console.log("  1. Guardian2 signs the acceptance message:");
    console.log("     hash = keccak256('ACCEPT_GUARDIAN' ++ chainId ++ factory ++ agentKey ++ salt)");
    console.log("     where salt = uint256(keccak256(humanOwner ++ agentId))");
    console.log("  2. Call factory.createAgentAccount(agentKey, agentId, guardian2, sig, dailyLimit)");
    console.log("  3. Agent uses the returned account address as its AirAccount");
    console.log("\nSecurity notes:");
    console.log("  - agentKey becomes the account OWNER (agent's signing key)");
    console.log("  - humanOwner (msg.sender) becomes guardian1 (auto-accepted)");
    console.log("  - agentKey MUST NOT equal guardian2 (dedup enforced by factory)");
    console.log("  - agentKey MUST NOT equal humanOwner (would violate owner!=guardian invariant)");
    return;
  }

  // ── Set up clients ──
  const publicClient = createPublicClient({ chain: sepolia, transport: http(rpcUrl) });
  const humanAccount = privateKeyToAccount(humanPk);
  const guardian2Account = privateKeyToAccount(guardian2Pk);
  const walletClient = createWalletClient({
    account: humanAccount,
    chain: sepolia,
    transport: http(rpcUrl),
  });

  console.log(`\nHuman (caller/guardian1): ${humanAccount.address}`);
  console.log(`Guardian2:               ${guardian2Account.address}`);
  console.log(`Factory:                 ${factoryAddr}`);

  // ── Demo: use a fixed agentKey and agentId ──
  // In production, agentKey would be a secure server-side key for the AI agent.
  // agentId identifies this particular agent instance (e.g. role + version).
  const agentKey = "0x000000000000000000000000000000000000DEAD" as Address;
  const agentId  = keccak256(encodePacked(["string"], ["my-agent-v1"])) as Hex;
  const dailyLimit = parseEther("0.01");

  console.log(`\nAgent key: ${agentKey}`);
  console.log(`Agent ID:  ${agentId}`);

  // ── Predict address before deployment ──
  const predicted = await publicClient.readContract({
    address: factoryAddr,
    abi: factoryAbi,
    functionName: "getAgentAddress",
    args: [humanAccount.address, agentKey, agentId],
  });
  console.log(`\nPredicted agent account address: ${predicted}`);

  // ── Build guardian2 acceptance signature ──
  const chainId = await publicClient.getChainId();
  const guardian2Sig = await buildGuardian2Sig({
    guardian2: guardian2Account,
    humanOwner: humanAccount.address,
    agentKey,
    agentId,
    factory: factoryAddr,
    chainId,
  });
  console.log(`Guardian2 acceptance sig: ${guardian2Sig.slice(0, 20)}...`);

  // ── Deploy agent account ──
  console.log("\nDeploying agent account...");
  const txHash = await walletClient.writeContract({
    address: factoryAddr,
    abi: factoryAbi,
    functionName: "createAgentAccount",
    args: [agentKey, agentId, guardian2Account.address, guardian2Sig, dailyLimit],
  });
  console.log(`Transaction: ${txHash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`Status: ${receipt.status}`);

  // ── Verify deployed address matches prediction ──
  const deployed = await publicClient.readContract({
    address: factoryAddr,
    abi: factoryAbi,
    functionName: "getAgentAddress",
    args: [humanAccount.address, agentKey, agentId],
  });
  console.log(`\nDeployed agent account: ${deployed}`);
  console.log(`Address match:          ${deployed === predicted}`);
}

main().catch(console.error);
