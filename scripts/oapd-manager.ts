/**
 * OAPDManager — One Account Per DApp Manager (M6.6a)
 *
 * Business scenario: Instead of one account address exposed to all DApps,
 * OAPD creates an isolated account per DApp. Each DApp sees a different
 * on-chain address, making cross-DApp correlation impossible.
 *
 * Key insight: AirAccount factory already supports arbitrary salt values.
 * For OAPD we derive a deterministic salt from (owner address + dappId).
 * Same owner + same dapp always produces the same salt → same account address.
 * Same owner + different dapps produce different salts → different addresses.
 *
 * All OAPD accounts share:
 *   - Same owner key pair
 *   - Same guardian pair (and therefore same social recovery path)
 *   - Same factory (deterministic deployment via CREATE2)
 *
 * The DApp never learns that account[uniswap] and account[opensea] belong to the same person.
 *
 * Architecture:
 *   OAPDManager.saltForDapp(dappId)     → deterministic bigint salt
 *   OAPDManager.getOrCreateAccount(...) → deploy + cache account address
 *   OAPDManager.listDapps()             → all managed dapp IDs
 *   OAPDManager.exportMappings()        → JSON-serializable mapping
 *
 * Persistence: mappings are stored in-memory during a session. For production,
 * serialize/deserialize via exportMappings() / fromMappings().
 *
 * Usage:
 *   import { OAPDManager } from './oapd-manager.js';
 *
 *   const manager = new OAPDManager({ ownerAddress, factoryAddress, guardians, dailyLimit });
 *   const uniswapAccount = await manager.getOrCreateAccount('uniswap', publicClient, walletClient, g1Client, g2Client);
 *   const aaveAccount    = await manager.getOrCreateAccount('aave',    publicClient, walletClient, g1Client, g2Client);
 *
 *   // Same owner, different addresses per DApp
 *   assert(uniswapAccount !== aaveAccount);
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  encodePacked,
  keccak256,
  hexToBytes,
  type Hex,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";

// ─── Types ────────────────────────────────────────────────────────────────────

export interface OAPDManagerOptions {
  ownerAddress: Address;
  factoryAddress: Address;
  guardian1Address: Address;
  guardian2Address: Address;
  dailyLimit: bigint;
}

export interface DappMapping {
  dappId: string;
  salt: bigint;
  accountAddress: Address | null;
  deployedAt?: number; // block number
}

// ─── Factory ABI (subset) ─────────────────────────────────────────────────────

const FACTORY_ABI = [
  {
    name: "createAccountWithDefaults",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian1Sig", type: "bytes" },
      { name: "guardian2", type: "address" },
      { name: "guardian2Sig", type: "bytes" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    name: "getAddressWithDefaults",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian2", type: "address" },
      { name: "dailyLimit", type: "uint256" },
    ],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

// ─── OAPDManager class ────────────────────────────────────────────────────────

export class OAPDManager {
  private readonly options: OAPDManagerOptions;
  private readonly mappings: Map<string, DappMapping>;

  constructor(options: OAPDManagerOptions) {
    this.options = options;
    this.mappings = new Map();
  }

  /**
   * Derive a deterministic salt for a given dappId.
   * Formula: keccak256(ownerAddress + dappId) truncated to uint256
   *
   * Same owner + same dapp → same salt always (idempotent).
   * Different dapps → different salts → different account addresses.
   * Different owners with same dapp → different salts.
   */
  saltForDapp(dappId: string): bigint {
    const packed = encodePacked(
      ["address", "string"],
      [this.options.ownerAddress, dappId]
    );
    const hash = keccak256(packed);
    return BigInt(hash);
  }

  /**
   * Predict the counterfactual account address for a dappId (no deployment).
   * Uses the factory's CREATE2 prediction — no on-chain call needed for address calculation,
   * but does require a public client for the factory call.
   */
  async predictAddress(dappId: string, publicClient: PublicClient): Promise<Address> {
    const salt = this.saltForDapp(dappId);
    return await publicClient.readContract({
      address: this.options.factoryAddress,
      abi: FACTORY_ABI,
      functionName: "getAddressWithDefaults",
      args: [
        this.options.ownerAddress,
        salt,
        this.options.guardian1Address,
        this.options.guardian2Address,
        this.options.dailyLimit,
      ],
    });
  }

  /**
   * Get or create the account for a dappId.
   * If already deployed: returns cached address immediately.
   * If not deployed: deploys via factory, caches the result.
   *
   * @param dappId        Unique identifier for the DApp (e.g., "uniswap", "aave", "opensea")
   * @param publicClient  Read-only client
   * @param ownerClient   Wallet client for the account owner (signs the create tx)
   * @param g1Client      Wallet client for guardian1 (signs acceptance)
   * @param g2Client      Wallet client for guardian2 (signs acceptance)
   */
  async getOrCreateAccount(
    dappId: string,
    publicClient: PublicClient,
    ownerClient: WalletClient,
    g1Client: WalletClient,
    g2Client: WalletClient,
  ): Promise<Address> {
    // Check in-memory cache first
    const cached = this.mappings.get(dappId);
    if (cached?.accountAddress) {
      return cached.accountAddress;
    }

    const salt = this.saltForDapp(dappId);
    const predicted = await this.predictAddress(dappId, publicClient);

    // Check if already deployed on-chain
    const code = await publicClient.getBytecode({ address: predicted });
    if (code && code.length > 2) {
      const mapping: DappMapping = { dappId, salt, accountAddress: predicted };
      this.mappings.set(dappId, mapping);
      return predicted;
    }

    // Deploy via factory
    const chainId = BigInt(await publicClient.getChainId());
    const g1Sig = await this._buildGuardianSig(g1Client, salt, chainId);
    const g2Sig = await this._buildGuardianSig(g2Client, salt, chainId);

    const txHash = await ownerClient.writeContract({
      address: this.options.factoryAddress,
      abi: FACTORY_ABI,
      functionName: "createAccountWithDefaults",
      args: [
        this.options.ownerAddress,
        salt,
        this.options.guardian1Address,
        g1Sig,
        this.options.guardian2Address,
        g2Sig,
        this.options.dailyLimit,
      ],
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    const mapping: DappMapping = {
      dappId,
      salt,
      accountAddress: predicted,
      deployedAt: receipt.blockNumber ? Number(receipt.blockNumber) : undefined,
    };
    this.mappings.set(dappId, mapping);
    return predicted;
  }

  /** List all managed dapp IDs (both cached and undeployed). */
  listDapps(): string[] {
    return Array.from(this.mappings.keys());
  }

  /** Check if a dapp's account is deployed (cached). */
  isDeployed(dappId: string): boolean {
    return this.mappings.get(dappId)?.accountAddress !== null &&
           this.mappings.get(dappId)?.accountAddress !== undefined;
  }

  /** Export all mappings as plain objects (for serialization/persistence). */
  exportMappings(): DappMapping[] {
    return Array.from(this.mappings.values()).map(m => ({
      ...m,
      salt: m.salt, // Note: bigint serialization may need special handling (e.g., toString())
    }));
  }

  /** Load mappings from a previous export (restore session state). */
  static fromMappings(options: OAPDManagerOptions, mappings: Array<Omit<DappMapping, 'salt'> & { salt: string | bigint }>): OAPDManager {
    const mgr = new OAPDManager(options);
    for (const m of mappings) {
      mgr.mappings.set(m.dappId, {
        ...m,
        salt: typeof m.salt === "string" ? BigInt(m.salt) : m.salt,
      });
    }
    return mgr;
  }

  // ─── Internal ──────────────────────────────────────────────────────

  /**
   * Build guardian acceptance signature for OAPD account creation.
   * Domain: keccak256(abi.encodePacked("ACCEPT_GUARDIAN", chainId, factory, owner, salt))
   */
  private async _buildGuardianSig(
    guardianClient: WalletClient,
    salt: bigint,
    chainId: bigint,
  ): Promise<Hex> {
    const innerHash = keccak256(encodePacked(
      ["string", "uint256", "address", "address", "uint256"],
      ["ACCEPT_GUARDIAN", chainId, this.options.factoryAddress, this.options.ownerAddress, salt]
    ));
    return guardianClient.signMessage({ message: { raw: hexToBytes(innerHash) } });
  }
}
