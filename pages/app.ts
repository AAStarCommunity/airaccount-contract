/**
 * AirAccount Onboarding — single-page 4-step flow
 *
 * Step 1: Connect wallet + create WebAuthn P-256 passkey
 * Step 2: Choose config template, adjust limits
 * Step 3: Deploy account via factory (CREATE2)
 * Step 4: Send a test transaction
 */

import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  parseEther,
  formatEther,
  encodeFunctionData,
  type Address,
  type Hash,
} from "viem";
import { sepolia } from "viem/chains";

// ─── Constants ──────────────────────────────────────────────────────

const ENTRYPOINT: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const FACTORY: Address = "0xce4231da69015273819b6aab78d840d62cf206c1"; // M3 factory

// ABI fragments (only what we need)
const factoryAbi = [
  {
    name: "createAccountWithDefaults",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "owner", type: "address" },
      { name: "salt", type: "uint256" },
      { name: "guardian1", type: "address" },
      { name: "guardian2", type: "address" },
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

const accountExecuteAbi = [
  {
    name: "execute",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dest", type: "address" },
      { name: "value", type: "uint256" },
      { name: "func", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

// ─── Clients ────────────────────────────────────────────────────────

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(),
});

// ─── State ──────────────────────────────────────────────────────────

interface AppState {
  ownerAddress: Address | null;
  p256PubKeyX: string | null;
  p256PubKeyY: string | null;
  credentialId: ArrayBuffer | null;
  dailyLimit: bigint;
  salt: bigint;
  predictedAddress: Address | null;
  deployedAddress: Address | null;
  currentStep: number;
}

const state: AppState = {
  ownerAddress: null,
  p256PubKeyX: null,
  p256PubKeyY: null,
  credentialId: null,
  dailyLimit: parseEther("1"),
  salt: BigInt(Math.floor(Math.random() * 1_000_000)),
  predictedAddress: null,
  deployedAddress: null,
  currentStep: 0,
};

// Config templates (loaded from ../configs/)
interface ConfigTemplate {
  name: string;
  description: string;
  dailyLimit: string;
  dailyLimitDisplay: string;
  tier1Limit: string;
  tier1LimitDisplay: string;
  tier2Limit: string;
  tier2LimitDisplay: string;
  tier3Note: string;
}

let currentConfig: ConfigTemplate | null = null;

// ─── DOM Helpers ────────────────────────────────────────────────────

function $(id: string): HTMLElement {
  return document.getElementById(id)!;
}

function showStep(step: number): void {
  state.currentStep = step;
  for (let i = 0; i < 4; i++) {
    const panel = $(`step-${i}`);
    const ind = $(`ind-${i}`);
    panel.classList.toggle("visible", i === step);
    ind.classList.toggle("active", i === step);
    ind.classList.toggle("done", i < step);
  }
}

function statusHtml(label: string, value: string, isError = false): string {
  const cls = isError ? "status-box error" : "status-box";
  return `<div class="${cls}"><span class="label">${label}</span><br/><span class="value">${value}</span></div>`;
}

function loadingHtml(msg: string): string {
  return `<div class="status-box"><span class="spinner"></span>${msg}</div>`;
}

// ─── Step 0: Connect Wallet + Create Passkey ────────────────────────

async function connectWallet(): Promise<void> {
  if (typeof window.ethereum === "undefined") {
    $("passkey-result").innerHTML = statusHtml("Error", "No browser wallet found. Install MetaMask or similar.", true);
    return;
  }

  try {
    const walletClient = createWalletClient({
      chain: sepolia,
      transport: custom(window.ethereum),
    });

    const [address] = await walletClient.requestAddresses();
    state.ownerAddress = address;

    // Show wallet banner
    $("wallet-banner").style.display = "block";
    $("wallet-addr").textContent = `${address.slice(0, 6)}...${address.slice(-4)}`;

    // Enable passkey button
    (document.getElementById("btn-passkey") as HTMLButtonElement).disabled = false;

    $("passkey-result").innerHTML = statusHtml("Wallet Connected", address);
  } catch (err: any) {
    $("passkey-result").innerHTML = statusHtml("Error", err.message || String(err), true);
  }
}

async function createPasskey(): Promise<void> {
  $("passkey-result").innerHTML = loadingHtml("Creating passkey...");

  try {
    const credential = (await navigator.credentials.create({
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rp: { name: "AirAccount" },
        user: {
          id: crypto.getRandomValues(new Uint8Array(16)),
          name: "user@airaccount",
          displayName: "AirAccount User",
        },
        pubKeyCredParams: [{ alg: -7, type: "public-key" }], // ES256 = P-256
        authenticatorSelection: {
          authenticatorAttachment: "platform",
          userVerification: "required",
        },
      },
    })) as PublicKeyCredential | null;

    if (!credential) {
      $("passkey-result").innerHTML = statusHtml("Error", "Passkey creation cancelled", true);
      return;
    }

    // Extract P-256 public key from attestation
    const attestation = credential.response as AuthenticatorAttestationResponse;
    const pubKeyBytes = extractP256PubKey(attestation);

    if (!pubKeyBytes) {
      $("passkey-result").innerHTML = statusHtml("Error", "Could not extract P-256 public key from attestation", true);
      return;
    }

    // P-256 uncompressed key: 0x04 || x (32 bytes) || y (32 bytes)
    const x = bytesToHex(pubKeyBytes.slice(0, 32));
    const y = bytesToHex(pubKeyBytes.slice(32, 64));

    state.p256PubKeyX = x;
    state.p256PubKeyY = y;
    state.credentialId = credential.rawId;

    $("passkey-result").innerHTML = statusHtml(
      "Passkey Created",
      `Credential ID: ${bytesToHex(new Uint8Array(credential.rawId)).slice(0, 24)}...\nP-256 X: ${x.slice(0, 18)}...\nP-256 Y: ${y.slice(0, 18)}...`
    );

    // Auto-advance after short delay
    setTimeout(() => showStep(1), 800);
  } catch (err: any) {
    $("passkey-result").innerHTML = statusHtml("Error", err.message || String(err), true);
  }
}

/**
 * Extract raw P-256 public key (x, y) from the attestation response.
 * Parses the CBOR-encoded attestation object to find the COSE key.
 */
function extractP256PubKey(attestation: AuthenticatorAttestationResponse): Uint8Array | null {
  // Try the standard getPublicKey() method first (available in modern browsers)
  if ("getPublicKey" in attestation && typeof attestation.getPublicKey === "function") {
    const spkiDer = attestation.getPublicKey();
    if (spkiDer) {
      const spki = new Uint8Array(spkiDer);
      // SPKI for P-256: last 65 bytes are 0x04 || x || y
      if (spki.length >= 65) {
        const uncompressed = spki.slice(spki.length - 65);
        if (uncompressed[0] === 0x04) {
          return uncompressed.slice(1); // 64 bytes: x || y
        }
      }
    }
  }

  // Fallback: parse CBOR from attestationObject to extract COSE key
  // This is a simplified parser for the common case
  try {
    const attObj = new Uint8Array(attestation.attestationObject);
    // Find authData in the CBOR structure
    // authData contains: rpIdHash(32) + flags(1) + signCount(4) + [attestedCredData]
    // attestedCredData: aaguid(16) + credIdLen(2) + credId(N) + credentialPublicKey(CBOR)

    // Simple approach: scan for the uncompressed point marker 0x04 followed by 64 bytes
    // that could be x and y coordinates (non-zero, reasonable values)
    for (let i = 0; i < attObj.length - 65; i++) {
      if (attObj[i] === 0x04) {
        const candidate = attObj.slice(i + 1, i + 65);
        // Basic sanity: neither x nor y should be all zeros
        const xPart = candidate.slice(0, 32);
        const yPart = candidate.slice(32, 64);
        if (!xPart.every((b) => b === 0) && !yPart.every((b) => b === 0)) {
          return candidate;
        }
      }
    }
  } catch {
    // CBOR parse failed
  }

  return null;
}

// ─── Step 1: Configure Account ──────────────────────────────────────

async function loadConfig(templateName: string): Promise<void> {
  try {
    const resp = await fetch(`../configs/${templateName}.json`);
    if (!resp.ok) throw new Error(`Config not found: ${templateName}`);
    currentConfig = (await resp.json()) as ConfigTemplate;
    applyConfigToForm();
    updateConfigPreview();
  } catch (err: any) {
    console.error("Failed to load config:", err);
  }
}

function applyConfigToForm(): void {
  if (!currentConfig) return;
  (document.getElementById("daily-limit") as HTMLInputElement).value = currentConfig.dailyLimitDisplay.split(" ")[0];
  (document.getElementById("tier1-limit") as HTMLInputElement).value = currentConfig.tier1LimitDisplay.split(" ")[0];
  (document.getElementById("tier2-limit") as HTMLInputElement).value = currentConfig.tier2LimitDisplay.split(" ")[0];
}

function updateConfigPreview(): void {
  if (!currentConfig) return;
  const daily = (document.getElementById("daily-limit") as HTMLInputElement).value;
  const t1 = (document.getElementById("tier1-limit") as HTMLInputElement).value;
  const t2 = (document.getElementById("tier2-limit") as HTMLInputElement).value;

  $("config-preview").innerHTML = `
    <tr><td>Template</td><td>${currentConfig.name}</td></tr>
    <tr><td>Daily Limit</td><td>${daily} ETH</td></tr>
    <tr><td>Tier 1 (Passkey)</td><td>&le; ${t1} ETH</td></tr>
    <tr><td>Tier 2 (Passkey+BLS)</td><td>&le; ${t2} ETH</td></tr>
    <tr><td>Tier 3</td><td>${currentConfig.tier3Note}</td></tr>
    <tr><td>Recovery</td><td>${currentConfig.recoveryThreshold} (${currentConfig.recoveryTimelock} timelock)</td></tr>
  `;
}

// ─── Step 2: Create Account ─────────────────────────────────────────

async function predictAddress(): Promise<void> {
  if (!state.ownerAddress) return;

  const dailyLimitEth = (document.getElementById("daily-limit") as HTMLInputElement).value;
  state.dailyLimit = dailyLimitEth === "0" || dailyLimitEth === "Unlimited"
    ? 0n
    : parseEther(dailyLimitEth);

  try {
    const predicted = await publicClient.readContract({
      address: FACTORY,
      abi: factoryAbi,
      functionName: "getAddressWithDefaults",
      args: [
        state.ownerAddress,
        state.salt,
        "0x0000000000000000000000000000000000000000" as Address, // guardian1 (none for demo)
        "0x0000000000000000000000000000000000000000" as Address, // guardian2 (none for demo)
        state.dailyLimit,
      ],
    });

    state.predictedAddress = predicted;

    $("predicted-addr").innerHTML = statusHtml(
      "Predicted Address (CREATE2)",
      `${predicted}\n\nSalt: ${state.salt}\nDaily Limit: ${state.dailyLimit === 0n ? "Unlimited" : formatEther(state.dailyLimit) + " ETH"}`
    );
  } catch (err: any) {
    $("predicted-addr").innerHTML = statusHtml(
      "Prediction Failed",
      `${err.message || String(err)}\n\nFactory: ${FACTORY}\nThis may mean the factory is not deployed on Sepolia yet.`,
      true
    );
  }
}

async function deployAccount(): Promise<void> {
  if (!state.ownerAddress) return;

  $("deploy-result").innerHTML = loadingHtml("Deploying account via factory...");

  try {
    const walletClient = createWalletClient({
      chain: sepolia,
      transport: custom(window.ethereum),
    });

    const hash = await walletClient.writeContract({
      account: state.ownerAddress,
      address: FACTORY,
      abi: factoryAbi,
      functionName: "createAccountWithDefaults",
      args: [
        state.ownerAddress,
        state.salt,
        "0x0000000000000000000000000000000000000000" as Address,
        "0x0000000000000000000000000000000000000000" as Address,
        state.dailyLimit,
      ],
    });

    $("deploy-result").innerHTML = loadingHtml(`Tx submitted: ${hash.slice(0, 18)}... Waiting for confirmation...`);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    state.deployedAddress = state.predictedAddress;

    $("deploy-result").innerHTML = statusHtml(
      "Account Deployed",
      `Address: ${state.predictedAddress}\nTx: ${hash}\nBlock: ${receipt.blockNumber}\nGas Used: ${receipt.gasUsed}\n\n<a href="https://sepolia.etherscan.io/tx/${hash}" target="_blank">View on Etherscan</a>`
    );

    // Auto-advance
    setTimeout(() => {
      showStep(3);
      // Pre-fill recipient with owner address for convenience
      (document.getElementById("test-recipient") as HTMLInputElement).value = state.ownerAddress!;
    }, 800);
  } catch (err: any) {
    $("deploy-result").innerHTML = statusHtml("Deployment Failed", err.message || String(err), true);
  }
}

// ─── Step 3: Test Transaction ───────────────────────────────────────

async function sendTestTransaction(): Promise<void> {
  if (!state.deployedAddress || !state.ownerAddress) return;

  const recipient = (document.getElementById("test-recipient") as HTMLInputElement).value as Address;
  if (!recipient || !recipient.startsWith("0x")) {
    $("send-result").innerHTML = statusHtml("Error", "Please enter a valid recipient address", true);
    return;
  }

  $("send-result").innerHTML = loadingHtml("Sending 0.001 ETH from smart wallet...");

  try {
    const walletClient = createWalletClient({
      chain: sepolia,
      transport: custom(window.ethereum),
    });

    // Call execute() on the deployed account directly (owner can call)
    const callData = encodeFunctionData({
      abi: accountExecuteAbi,
      functionName: "execute",
      args: [recipient, parseEther("0.001"), "0x"],
    });

    const hash = await walletClient.sendTransaction({
      account: state.ownerAddress,
      to: state.deployedAddress,
      data: callData,
    });

    $("send-result").innerHTML = loadingHtml(`Tx submitted: ${hash.slice(0, 18)}... Waiting...`);

    const receipt = await publicClient.waitForTransactionReceipt({ hash });

    $("send-result").innerHTML = statusHtml(
      "Transaction Successful",
      `From: ${state.deployedAddress}\nTo: ${recipient}\nAmount: 0.001 ETH\nTx: ${hash}\nGas Used: ${receipt.gasUsed}\n\n<a href="https://sepolia.etherscan.io/tx/${hash}" target="_blank">View on Etherscan</a>`
    );
  } catch (err: any) {
    $("send-result").innerHTML = statusHtml("Transaction Failed", err.message || String(err), true);
  }
}

// ─── Utility ────────────────────────────────────────────────────────

function bytesToHex(bytes: Uint8Array): string {
  return "0x" + Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ─── Event Wiring ───────────────────────────────────────────────────

// Declare window.ethereum for TypeScript
declare global {
  interface Window {
    ethereum?: any;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  // Initial state
  showStep(0);
  loadConfig("default-personal");

  // Step 0
  $("btn-connect").addEventListener("click", connectWallet);
  $("btn-passkey").addEventListener("click", createPasskey);

  // Step 1
  $("config-select").addEventListener("change", (e) => {
    loadConfig((e.target as HTMLSelectElement).value);
  });
  $("daily-limit").addEventListener("input", updateConfigPreview);
  $("tier1-limit").addEventListener("input", updateConfigPreview);
  $("tier2-limit").addEventListener("input", updateConfigPreview);
  $("btn-back-1").addEventListener("click", () => showStep(0));
  $("btn-next-1").addEventListener("click", () => {
    showStep(2);
    predictAddress();
  });

  // Step 2
  $("btn-back-2").addEventListener("click", () => showStep(1));
  $("btn-deploy").addEventListener("click", deployAccount);

  // Step 3
  $("btn-back-3").addEventListener("click", () => showStep(2));
  $("btn-send").addEventListener("click", sendTestTransaction);
});
