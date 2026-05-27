#!/bin/bash
# =============================================================================
# deploy-v0.17.0.sh — One-click deploy of the full AirAccount v0.17.0 contract set
#                     via forge script (script/DeployAirAccountV017.s.sol).
#
# Usage:
#   ./deploy-v0.17.0.sh                 # Sepolia (default), env private key
#   ./deploy-v0.17.0.sh sepolia
#   ./deploy-v0.17.0.sh op-sepolia
#   ./deploy-v0.17.0.sh op-mainnet      # OP Mainnet — cast wallet keystore (password prompt)
#   ./deploy-v0.17.0.sh sepolia --simulate    # dry-run, no broadcast
#   ./deploy-v0.17.0.sh sepolia --verify       # also verify on Etherscan
#
# Env file (auto-detected): ./.env.sepolia  (falls back to ../SuperPaymaster/.env.<net>)
# Needs: PRIVATE_KEY (testnet) or a cast-wallet keystore (mainnet),
#        an RPC url, COMMUNITY_GUARDIAN_ADDRESS (optional), ETHERSCAN_API_KEY (for --verify).
#
# Signer:
#   sepolia / op-sepolia → --private-key $PRIVATE_KEY  (plaintext, testnet only)
#   op-mainnet           → --account $DEPLOYER_ACCOUNT (encrypted keystore, manual password)
# =============================================================================
set -euo pipefail

NET="${1:-sepolia}"
SIMULATE=false; VERIFY=false
[[ "$*" == *"--simulate"* ]] && SIMULATE=true
[[ "$*" == *"--verify"*   ]] && VERIFY=true

SCRIPT="script/DeployAirAccountV017.s.sol:DeployAirAccountV017"
ENTRYPOINT_DEFAULT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"

# ── Locate + load env file ────────────────────────────────────────────────────
pick_env() {
  case "$NET" in
    sepolia)     for f in ./.env.sepolia ../SuperPaymaster/.env.sepolia; do [ -f "$f" ] && { echo "$f"; return; }; done ;;
    op-sepolia)  for f in ./.env.op-sepolia ./.env.sepolia ../SuperPaymaster/.env.op-sepolia; do [ -f "$f" ] && { echo "$f"; return; }; done ;;
    op-mainnet)  for f in ./.env.op-mainnet ../SuperPaymaster/.env.op-mainnet ../SuperPaymaster/.env.optimism; do [ -f "$f" ] && { echo "$f"; return; }; done ;;
  esac
}
ENV_FILE="$(pick_env || true)"
[ -z "${ENV_FILE:-}" ] && { echo "❌ No env file found for '$NET'"; exit 1; }
echo "📂 env: $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# ── Resolve a REACHABLE RPC (auto-skip dead endpoints like the old URL1) ────────
reachable() { [ -n "${1:-}" ] && [ "$(cast chain-id --rpc-url "$1" 2>/dev/null)" != "" ]; }
RPC=""
case "$NET" in
  sepolia)
    for u in "${RPC_URL_OVERRIDE:-}" "${SEPOLIA_RPC_URL2:-}" "${SEPOLIA_RPC_URL3:-}" "${SEPOLIA_RPC_URL:-}"; do
      if reachable "$u"; then RPC="$u"; break; fi
    done ;;
  op-sepolia)
    for u in "${RPC_URL_OVERRIDE:-}" "${OP_SEPOLIA_RPC_URL:-}" "${OPTIMISM_SEPOLIA_RPC_URL:-}"; do
      if reachable "$u"; then RPC="$u"; break; fi
    done ;;
  op-mainnet)
    for u in "${RPC_URL_OVERRIDE:-}" "${OP_MAINNET_RPC_URL:-}" "${OPT_MAINNET_RPC:-}" "${OPTIMISM_RPC_URL:-}"; do
      if reachable "$u"; then RPC="$u"; break; fi
    done ;;
  *) echo "❌ Unknown network: $NET (use sepolia | op-sepolia | op-mainnet)"; exit 1 ;;
esac
[ -z "$RPC" ] && { echo "❌ No reachable RPC for '$NET'. Set RPC_URL_OVERRIDE=<url> and retry."; exit 1; }
echo "🌐 RPC: $(echo "$RPC" | sed -E 's#(https?://[^/]+).*#\1/…#')  (chain-id $(cast chain-id --rpc-url "$RPC"))"

# ── Signer strategy ─────────────────────────────────────────────────────────────
FLAGS=(--rpc-url "$RPC" -vvvv --slow)
$SIMULATE || FLAGS+=(--broadcast)

if [ "$NET" == "op-mainnet" ]; then
  ACCT="${DEPLOYER_ACCOUNT:-op-deployer}"
  echo "🔐 signer: cast wallet keystore '$ACCT' (password prompt)"
  FLAGS+=(--account "$ACCT" --timeout 300)
else
  [ -z "${PRIVATE_KEY:-}" ] && { echo "❌ PRIVATE_KEY not set in $ENV_FILE"; exit 1; }
  echo "⚠️  signer: plaintext PRIVATE_KEY → $(cast wallet address --private-key "$PRIVATE_KEY") (testnet only)"
  echo "    balance: $(cast balance "$(cast wallet address --private-key "$PRIVATE_KEY")" --rpc-url "$RPC" --ether) ETH"
  FLAGS+=(--private-key "$PRIVATE_KEY")
fi

$VERIFY && [ -n "${ETHERSCAN_API_KEY:-}" ] && FLAGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")

# COMMUNITY_GUARDIAN_ADDRESS is read by the forge script via vm.envOr — export if present.
[ -n "${COMMUNITY_GUARDIAN_ADDRESS:-}" ] && export COMMUNITY_GUARDIAN_ADDRESS
echo "🏛  communityGuardian: ${COMMUNITY_GUARDIAN_ADDRESS:-<unset → address(0)>}"

# ── Build if needed, then run ───────────────────────────────────────────────────
[ -f "out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json" ] || { echo "🔧 forge build…"; forge build; }

echo ""
echo "=== Deploy AirAccount v0.17.0 → $NET  (simulate=$SIMULATE) ==="
# Redact any secret (private key) before echoing the command.
echo "forge script $SCRIPT $(printf '%s ' "${FLAGS[@]}" | sed -E 's/(--private-key )[^ ]+/\1***REDACTED***/g')"
echo ""
forge script "$SCRIPT" "${FLAGS[@]}"

echo ""
echo "✅ Done. Next:"
echo "   1. Copy the printed addresses into docs/DEPLOYMENT-v0.17.0.md (per-chain table) + .env.$NET"
echo "   2. Give the AgentRegistry address to the SuperPaymaster team (setAgentRegistries)"
echo "   3. Sync ABIs + addresses to the @aastar/sdk repo, then bump the lib/aastar-sdk submodule"
