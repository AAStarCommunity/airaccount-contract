#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# Load .env.sepolia or .env
if [ -f .env.sepolia ]; then
  set -a
  source .env.sepolia
  set +a
elif [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Map variable names
export SEPOLIA_RPC="${SEPOLIA_RPC:-${SEPOLIA_RPC_URL:-${RPC_URL:-}}}"

echo "=== AirAccount M2 BLS E2E Test ==="
echo "Network: Sepolia"
echo ""

# Check required env vars
: "${PRIVATE_KEY:?'Set PRIVATE_KEY in .env.sepolia'}"
: "${SEPOLIA_RPC:?'Set SEPOLIA_RPC or SEPOLIA_RPC_URL in .env.sepolia'}"
: "${BLS_TEST_NODE_ID_1:?'Set BLS_TEST_NODE_ID_1 in .env.sepolia'}"
: "${BLS_TEST_PRIVATE_KEY_1:?'Set BLS_TEST_PRIVATE_KEY_1 in .env.sepolia'}"

# Parse args
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && export DRY_RUN="1"
done

npx tsx scripts/test-e2e-bls.ts
