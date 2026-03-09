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

# Map variable names (env uses SEPOLIA_RPC_URL, script expects SEPOLIA_RPC)
export SEPOLIA_RPC="${SEPOLIA_RPC:-${SEPOLIA_RPC_URL:-${RPC_URL:-}}}"

echo "=== AirAccount V7 ECDSA E2E Test ==="
echo "Network: Sepolia"
echo ""

# Check required env vars
: "${PRIVATE_KEY:?'Set PRIVATE_KEY in .env.sepolia'}"
: "${SEPOLIA_RPC:?'Set SEPOLIA_RPC or SEPOLIA_RPC_URL in .env.sepolia'}"

npx tsx scripts/test-e2e-ecdsa.ts
