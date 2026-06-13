/**
 * scripts/e2e-v0172/10-session-key-txns.ts
 *
 * Phase 10 — Session key lifecycle on Sepolia.
 *
 * COSTS GAS. Deploys a fresh account then covers:
 *   SK.1  createAccountWithDefaults (session-key-test account)
 *   SK.2  grantSessionDirect(account, sessionKey1, {no scope restriction}) — owner grants ECDSA session
 *   SK.3  isSessionActive(account, sessionKey1) == true
 *   SK.4  grantSession(account, sessionKey2, {scoped to account.execute}, ownerSig) — DApp flow with sig
 *   SK.5  isSessionActive(account, sessionKey2) == true
 *   SK.6  grantP256SessionDirect(account, P256_X, P256_Y, {P256 passkey session}) — passkey session
 *   SK.7  isP256SessionActive(account, P256_X, P256_Y) == true
 *   SK.8  revokeSession(account, sessionKey1) — owner revokes ECDSA session
 *   SK.9  isSessionActive(account, sessionKey1) == false after revoke
 *   SK.10 revokeP256Session(account, P256_X, P256_Y) — owner revokes P256 session
 *   SK.11 isP256SessionActive == false after revoke
 *
 * Run: pnpm tsx scripts/e2e-v0172/10-session-key-txns.ts
 */

import {
  keccak256, encodePacked, type Hash, type Address,
  toHex, toBytes,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  ADDR, publicClient, wAnnie, annie, jason, bob,
  loadAbi, runTests, type TestCase,
} from "./common.js";

const factoryAbi = loadAbi("AAStarAirAccountFactoryV7");
const baseAbi    = loadAbi("AAStarAirAccountBase");
const skvAbi     = loadAbi("SessionKeyValidator");

const SALT        = BigInt(Math.floor(Date.now() / 1000)) + 10_000n;
const DAILY_LIMIT = 10_000_000_000_000_000n; // 0.01 ETH
const GUARDIAN1   = jason.address;
const GUARDIAN2   = bob.address;

// ECDSA session keys
const sessionKey1Priv = generatePrivateKey();
const sessionKey2Priv = generatePrivateKey();
const sessionKey1     = privateKeyToAccount(sessionKey1Priv);
const sessionKey2     = privateKeyToAccount(sessionKey2Priv);

// P256 test key coordinates (deterministic fake values for testing — not a real curve point,
// but sufficient to test storage/revoke since grantP256SessionDirect does NOT validate the point)
const P256_X = toHex(BigInt("0xdeadbeef01020304050607080910111213141516171819202122232425262728"), { size: 32 }) as `0x${string}`;
const P256_Y = toHex(BigInt("0xbeefdead01020304050607080910111213141516171819202122232425262728"), { size: 32 }) as `0x${string}`;

let account: Address = "0x" as Address;

// execute(address,uint256,bytes) selector for scope restriction
const EXECUTE_SELECTOR = "0xb61d27f6";

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

// Session config type
type SessionConfig = {
  expiry: number;
  contractScope: Address;
  selectorScope: `0x${string}`;
  revoked: boolean;
  velocityLimit: number;
  velocityWindow: number;
  callTargets: Address[];
  selectorAllowlist: `0x${string}`[];
};

function openSessionConfig(): SessionConfig {
  const EXPIRY = Math.floor(Date.now() / 1000) + 86400; // 24h from now
  return {
    expiry: EXPIRY,
    contractScope: "0x0000000000000000000000000000000000000000",
    selectorScope: "0x00000000",
    revoked: false,
    velocityLimit: 0,
    velocityWindow: 0,
    callTargets: [],
    selectorAllowlist: [],
  };
}

const tests: TestCase[] = [
  {
    name: "SK.1 createAccountWithDefaults (session-key test account)",
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
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `session-test account = ${account}` };
    },
  },
  {
    name: "SK.2 grantSessionDirect(account, sessionKey1, open scope) — owner direct grant",
    run: async () => {
      const cfg = openSessionConfig();
      const hash = await wAnnie.writeContract({
        address: ADDR.sessionKeyValidator,
        abi: skvAbi,
        functionName: "grantSessionDirect",
        args: [account, sessionKey1.address, cfg],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `sessionKey1=${sessionKey1.address.slice(0,10)}… granted (open scope, 24h)` };
    },
  },
  {
    name: "SK.3 isSessionActive(account, sessionKey1) == true",
    run: async () => {
      const active = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "isSessionActive",
        args: [account, sessionKey1.address],
      });
      if (active !== true) throw new Error(`expected true, got ${active}`);
      return { notes: `sessionKey1 is active ✓` };
    },
  },
  {
    name: "SK.4 grantSession(account, sessionKey2, scoped cfg, ownerSig) — DApp flow with sig",
    run: async () => {
      const cfg: SessionConfig = {
        expiry: Math.floor(Date.now() / 1000) + 3600,
        contractScope: account,                     // scoped to this account only
        selectorScope: EXECUTE_SELECTOR as `0x${string}`,  // scoped to execute()
        revoked: false,
        velocityLimit: 10,                          // max 10 calls
        velocityWindow: 3600,                       // per 1-hour window
        callTargets: [],
        selectorAllowlist: [],
      };

      // Build the grant hash using the validator's view function, then sign with Annie
      const grantHash = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "buildGrantHash",
        args: [account, sessionKey2.address, cfg],
      }) as `0x${string}`;

      // _buildGrantHash already applies toEthSignedMessageHash internally,
      // so we sign the raw returned bytes32 directly (NOT using signMessage which would double-prefix).
      const ownerSig = await annie.sign({ hash: grantHash });

      const hash = await wAnnie.writeContract({
        address: ADDR.sessionKeyValidator,
        abi: skvAbi,
        functionName: "grantSession",
        args: [account, sessionKey2.address, cfg, ownerSig],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `sessionKey2 granted (scoped to execute, velocity=10/hr)` };
    },
  },
  {
    name: "SK.5 isSessionActive(account, sessionKey2) == true",
    run: async () => {
      const active = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "isSessionActive",
        args: [account, sessionKey2.address],
      });
      if (active !== true) throw new Error(`expected true, got ${active}`);
      return { notes: `sessionKey2 is active ✓` };
    },
  },
  {
    name: "SK.6 grantP256SessionDirect(account, P256_X, P256_Y, cfg) — passkey session grant",
    run: async () => {
      const cfg = openSessionConfig();
      const hash = await wAnnie.writeContract({
        address: ADDR.sessionKeyValidator,
        abi: skvAbi,
        functionName: "grantP256SessionDirect",
        args: [account, P256_X, P256_Y, cfg],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `P256 passkey session granted (X=${P256_X.slice(0,10)}…)` };
    },
  },
  {
    name: "SK.7 isP256SessionActive(account, P256_X, P256_Y) == true",
    run: async () => {
      const active = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "isP256SessionActive",
        args: [account, P256_X, P256_Y],
      });
      if (active !== true) throw new Error(`expected true, got ${active}`);
      return { notes: `P256 passkey session is active ✓` };
    },
  },
  {
    name: "SK.8 revokeSession(account, sessionKey1) — owner revokes ECDSA session",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: ADDR.sessionKeyValidator,
        abi: skvAbi,
        functionName: "revokeSession",
        args: [account, sessionKey1.address],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `sessionKey1 revoked` };
    },
  },
  {
    name: "SK.9 isSessionActive(account, sessionKey1) == false after revoke",
    run: async () => {
      const active = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "isSessionActive",
        args: [account, sessionKey1.address],
      });
      if (active !== false) throw new Error(`expected false, got ${active}`);
      return { notes: `sessionKey1 is inactive after revoke ✓` };
    },
  },
  {
    name: "SK.10 revokeP256Session(account, P256_X, P256_Y) — owner revokes P256 passkey session",
    run: async () => {
      const hash = await wAnnie.writeContract({
        address: ADDR.sessionKeyValidator,
        abi: skvAbi,
        functionName: "revokeP256Session",
        args: [account, P256_X, P256_Y],
        chain: null,
        account: annie,
      });
      const { gasUsed } = await waitTx(hash);
      return { txHash: hash, gas: gasUsed, notes: `P256 passkey session revoked` };
    },
  },
  {
    name: "SK.11 isP256SessionActive == false after revokeP256Session",
    run: async () => {
      const active = await publicClient.readContract({
        address: ADDR.sessionKeyValidator, abi: skvAbi,
        functionName: "isP256SessionActive",
        args: [account, P256_X, P256_Y],
      });
      if (active !== false) throw new Error(`expected false, got ${active}`);
      return { notes: `P256 passkey session is inactive after revoke ✓` };
    },
  },
];

(async () => { await runTests("10-session-key-txns", tests); })();
