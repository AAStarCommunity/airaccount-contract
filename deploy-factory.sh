#!/bin/bash
# =============================================================================
# deploy-factory.sh — Deploy AirAccount M6 Factory
#
# Usage:
#   ./deploy-factory.sh sepolia          # Sepolia testnet (private key)
#   ./deploy-factory.sh op-mainnet       # OP Mainnet (cast wallet keystore)
#   ./deploy-factory.sh op-mainnet --force   # Force redeploy
#
# Env files (sourced from SuperPaymaster directory for shared credentials):
#   sepolia    → ../SuperPaymaster/.env.sepolia
#   op-mainnet → ../SuperPaymaster/.env.op-mainnet  (or .env.optimism)
#
# Signer strategy:
#   Sepolia:    uses PRIVATE_KEY from env (plaintext, testnet only)
#   OP Mainnet: uses DEPLOYER_ACCOUNT=optimism-deployer (cast wallet keystore)
#               → cast wallet import optimism-deployer --interactive
# =============================================================================

set -e

ENV=${1:-"sepolia"}
FORCE=false
[[ "$*" == *"--force"* ]] && FORCE=true

# ── Locate env file ──────────────────────────────────────────────────────────

SUPERPAYMASTER_DIR="../SuperPaymaster"

case "$ENV" in
  sepolia)
    ENV_FILE="$SUPERPAYMASTER_DIR/.env.sepolia"
    ;;
  op-mainnet|optimism)
    # Try op-mainnet first, fall back to optimism
    if [ -f "$SUPERPAYMASTER_DIR/.env.op-mainnet" ]; then
      ENV_FILE="$SUPERPAYMASTER_DIR/.env.op-mainnet"
    else
      ENV_FILE="$SUPERPAYMASTER_DIR/.env.optimism"
    fi
    ENV="op-mainnet"
    ;;
  *)
    echo "❌ Unknown environment: $ENV"
    echo "   Usage: $0 [sepolia|op-mainnet]"
    exit 1
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Env file not found: $ENV_FILE"
  echo "   Expected SuperPaymaster at: $SUPERPAYMASTER_DIR"
  exit 1
fi

echo "📂 Loading env: $ENV_FILE"
set -a; source "$ENV_FILE"; set +a

# ── Resolve RPC ──────────────────────────────────────────────────────────────

case "$ENV" in
  sepolia)
    RPC=${SEPOLIA_RPC_URL:-$RPC_URL}
    ;;
  op-mainnet)
    RPC=${OPT_MAINNET_RPC:-${OPTIMISM_RPC_URL:-$RPC_URL}}
    ;;
esac

if [ -z "$RPC" ]; then
  echo "❌ Could not resolve RPC URL for $ENV"
  echo "   Set SEPOLIA_RPC_URL or OPT_MAINNET_RPC in env file."
  exit 1
fi
echo "🌐 RPC: $RPC"

# ── Resolve signer strategy ──────────────────────────────────────────────────

FORGE_FLAGS="--rpc-url $RPC --broadcast --slow -vv"

if [ "$ENV" == "op-mainnet" ]; then
  # OP Mainnet: use cast wallet keystore
  if [ -z "$DEPLOYER_ACCOUNT" ]; then
    echo "❌ DEPLOYER_ACCOUNT not set in $ENV_FILE"
    echo "   Expected: DEPLOYER_ACCOUNT=optimism-deployer"
    exit 1
  fi

  echo "🔐 Signer: cast wallet keystore → $DEPLOYER_ACCOUNT"

  # Resolve address from keystore if not explicitly set
  if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "   Resolving address (password required)..."
    DEPLOYER_ADDRESS=$(cast wallet address --account "$DEPLOYER_ACCOUNT")
  fi
  echo "   Address: $DEPLOYER_ADDRESS"

  FORGE_FLAGS="$FORGE_FLAGS --account $DEPLOYER_ACCOUNT --timeout 300"
  export DEPLOYER_ADDRESS

else
  # Sepolia: use plaintext private key from env
  if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ PRIVATE_KEY not set in $ENV_FILE"
    exit 1
  fi
  DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS:-$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || echo "unknown")}
  echo "⚠️  Signer: plaintext private key (testnet only)"
  echo "   Address: $DEPLOYER_ADDRESS"

  FORGE_FLAGS="$FORGE_FLAGS --private-key $PRIVATE_KEY"
  export DEPLOYER_ADDRESS
fi

# ── Export forge env vars ────────────────────────────────────────────────────

export ENTRYPOINT=${ENTRY_POINT:-"0x0000000071727De22E5E9d8BAf0edAc6f37da032"}
export COMMUNITY_GUARDIAN=${COMMUNITY_GUARDIAN_ADDRESS:-"0x0000000000000000000000000000000000000000"}

echo ""
echo "=== Deploy AirAccount M6 Factory → $ENV ==="
echo "EntryPoint : $ENTRYPOINT"
echo "Guardian   : $COMMUNITY_GUARDIAN"
echo "Deployer   : $DEPLOYER_ADDRESS"
echo ""

# ── Check artifacts ──────────────────────────────────────────────────────────

if [ ! -f "out/AAStarAirAccountFactoryV7.sol/AAStarAirAccountFactoryV7.json" ]; then
  echo "⚠️  Artifacts not found. Running forge build..."
  forge build --quiet
fi

# ── Run forge script ─────────────────────────────────────────────────────────

echo "🚀 forge script script/DeployFactoryM6.s.sol:DeployFactoryM6 $FORGE_FLAGS"
echo ""
forge script script/DeployFactoryM6.s.sol:DeployFactoryM6 $FORGE_FLAGS

echo ""
echo "✅ Done. Add the printed AIRACCOUNT_FACTORY= address to:"
case "$ENV" in
  sepolia)
    echo "   $SUPERPAYMASTER_DIR/../airaccount-contract/.env.sepolia"
    echo "   → AIRACCOUNT_M6_R3_FACTORY=<address>"
    ;;
  op-mainnet)
    echo "   .env.optimism"
    echo "   → AIRACCOUNT_OP_FACTORY=<address>"
    echo "   Then run: pnpm tsx scripts/test-op-e2e.ts"
    ;;
esac
