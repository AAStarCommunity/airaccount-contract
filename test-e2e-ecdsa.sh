#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# Load .env if exists
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

echo "=== AirAccount V7 ECDSA E2E Test ==="
echo "Network: Sepolia"
echo ""

# Check required env vars
: "${PRIVATE_KEY:?'Set PRIVATE_KEY in .env'}"
: "${SEPOLIA_RPC:?'Set SEPOLIA_RPC in .env'}"

npx tsx scripts/test-e2e-ecdsa.ts
