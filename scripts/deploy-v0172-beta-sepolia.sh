#!/usr/bin/env bash
# Deploy AirAccount v0.17.2-beta.1 to Sepolia.
#
# - Sources .env.sepolia
# - Aliases env vars to match what script/DeployV0172Beta.s.sol expects:
#     ENTRY_POINT_ADDRESS → ENTRY_POINT_07
#     PRIVATE_KEY_ANNI    → DEPLOYER_KEY  (Anni EOA = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9)
# - Pre-flight: deployer balance check (≥ 0.05 ETH)
# - Broadcasts the deploy + auto-verifies on Etherscan
# - Captures the deploy log + the broadcast addresses JSON
#
# Usage:
#   bash scripts/deploy-v0172-beta-sepolia.sh                  # full deploy (broadcast + verify)
#   DRY_RUN=1 bash scripts/deploy-v0172-beta-sepolia.sh        # no --broadcast (simulation only)
#   NO_VERIFY=1 bash scripts/deploy-v0172-beta-sepolia.sh      # broadcast without --verify
#   DEPLOYER=jason bash scripts/deploy-v0172-beta-sepolia.sh   # use jason key instead of anni (NOT RECOMMENDED — leaked)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-.env.sepolia}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

# Source env (allexport so subprocess sees them too)
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

DEPLOYER="${DEPLOYER:-anni}"
case "$DEPLOYER" in
  anni)
    DEPLOYER_KEY="${PRIVATE_KEY_ANNI:?PRIVATE_KEY_ANNI not set in $ENV_FILE}"
    DEPLOYER_ADDR="${ADDRESS_ANNI_EOA:-0xEcAACb915f7D92e9916f449F7ad42BD0408733c9}"
    ;;
  jason)
    echo "WARN: Jason key was previously leaked; only use with throwaway testnet gas." >&2
    DEPLOYER_KEY="${PRIVATE_KEY_JASON:?PRIVATE_KEY_JASON not set in $ENV_FILE}"
    DEPLOYER_ADDR="${ADDRESS_JASON_EOA:-0xb5600060e6de5E11D3636731964218E53caadf0E}"
    ;;
  *)
    echo "ERROR: unknown DEPLOYER=$DEPLOYER (expected: anni | jason)" >&2
    exit 1
    ;;
esac

# Aliases for the Foundry script
export ENTRY_POINT_07="${ENTRY_POINT_07:-${ENTRY_POINT_ADDRESS:-0x0000000071727De22E5E9d8BAf0edAc6f37da032}}"
export P256_VERIFIER="${P256_VERIFIER:-0x0000000000000000000000000000000000000100}"
export COMMUNITY_GUARDIAN_ADDRESS="${COMMUNITY_GUARDIAN_ADDRESS:?not set}"
export DEPLOYER_KEY

RPC="${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL not set}"
ETHERSCAN="${ETHERSCAN_API_KEY:-}"

echo "============================================================"
echo "  AirAccount v0.17.2-beta.1 — Sepolia deploy"
echo "============================================================"
echo "  Deployer        : $DEPLOYER ($DEPLOYER_ADDR)"
echo "  RPC             : ${RPC:0:60}..."
echo "  EntryPoint v0.7 : $ENTRY_POINT_07"
echo "  P256 verifier   : $P256_VERIFIER"
echo "  CommunityGuard  : $COMMUNITY_GUARDIAN_ADDRESS"
if [ -n "$ETHERSCAN" ]; then
  echo "  Etherscan key   : set (${#ETHERSCAN} chars, redacted)"
else
  echo "  Etherscan key   : NOT SET — --verify will be skipped"
fi
echo "------------------------------------------------------------"

# Pre-flight: balance check
BAL_WEI="$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC")"
BAL_ETH="$(cast to-unit "$BAL_WEI" ether)"
echo "  Deployer balance: $BAL_ETH ETH ($BAL_WEI wei)"
# 0.05 ETH = 50000000000000000 wei
MIN_WEI=50000000000000000
if [ "$(echo "$BAL_WEI < $MIN_WEI" | bc 2>/dev/null || python3 -c "print(int('$BAL_WEI') < $MIN_WEI)")" = "True" ] || [ "$BAL_WEI" -lt "$MIN_WEI" ] 2>/dev/null; then
  echo "ERROR: deployer balance below 0.05 ETH minimum" >&2
  exit 1
fi

# Block number sanity (RPC health)
BLOCK="$(cast block-number --rpc-url "$RPC")"
echo "  Sepolia block#  : $BLOCK"
echo "------------------------------------------------------------"

# Build the forge invocation
FORGE_ARGS=(
  script script/DeployV0172Beta.s.sol
  --rpc-url "$RPC"
  -vvv
)

if [ -z "${DRY_RUN:-}" ]; then
  FORGE_ARGS+=(--broadcast)
  if [ -z "${NO_VERIFY:-}" ] && [ -n "$ETHERSCAN" ]; then
    FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN")
  fi
else
  echo "  DRY_RUN=1 — simulation only (no --broadcast)"
fi

echo ""
echo "  Running: forge ${FORGE_ARGS[*]}"
echo "============================================================"
echo ""

LOG_FILE="deploy-v0172-beta-$(date -u +%Y%m%dT%H%M%SZ).log"
forge "${FORGE_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

echo ""
echo "============================================================"
echo "  forge script exit code: $EXIT_CODE"
echo "  Full log: $LOG_FILE"
if [ -d "broadcast/DeployV0172Beta.s.sol/11155111" ]; then
  echo "  Broadcast record: broadcast/DeployV0172Beta.s.sol/11155111/run-latest.json"
fi
echo "============================================================"

# Extract deployed addresses from the log for convenience
echo ""
echo "Deployed addresses:"
grep -E "^\s+(Deployed|Skipped|Wired) " "$LOG_FILE" || true

exit "$EXIT_CODE"
