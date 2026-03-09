#!/usr/bin/env bash
# test-e2e-bls.sh — E2E BLS signature + ERC-4337 UserOp on Sepolia
#
# What it does:
#   1. Loads deployed addresses and BLS test keys from .env.sepolia
#   2. Verifies both test BLS nodes are registered on-chain
#   3. Builds a real UserOp: AA account sends 0.001 ETH to ADDRESS_ANNI_EOA
#   4. Signs with real BLS aggregate + two ECDSA (per _parseAndValidateAAStarSignature)
#   5. Funds EntryPoint deposit if needed
#   6. Submits handleOps() — real on-chain execution
#
# Usage (from project root):
#   bash test-e2e-bls.sh
#   bash test-e2e-bls.sh --dry-run    # skip actual submission

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_ROOT/.env.sepolia"
TS_DIR="$REPO_ROOT/lib/YetAnotherAA-Validator"
SCRIPT="$REPO_ROOT/scripts/test-e2e-bls.ts"

# Load env
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found"; exit 1
fi
set -o allexport
source "$ENV_FILE"
set +o allexport

# Override RPC to Alchemy (more reliable than drpc for sending txs)
export RPC_URL="$SEPOLIA_RPC_URL"
export PRIVATE_KEY="$PRIVATE_KEY"
export DRY_RUN=""

for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && export DRY_RUN="1"
done

echo "======================================"
echo " YetAnotherAA E2E BLS Test — Sepolia"
echo " $(date)"
echo "======================================"
echo ""
echo "  AA Account  : $AASTAR_AA_ACCOUNT_ADDRESS"
echo "  Validator   : $VALIDATOR_CONTRACT_ADDRESS"
echo "  Factory     : $AASTAR_ACCOUNT_FACTORY_ADDRESS"
echo "  BLS Node 1  : $BLS_TEST_NODE_ID_1"
echo "  BLS Node 2  : $BLS_TEST_NODE_ID_2"
echo "  Beneficiary : $ADDRESS_ANNI_EOA"
[ -n "$DRY_RUN" ] && echo "  Mode        : DRY RUN (no submission)" || echo "  Mode        : LIVE"
echo ""

cd "$TS_DIR"
npx tsx "$SCRIPT"
