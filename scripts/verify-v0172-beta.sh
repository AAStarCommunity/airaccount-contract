#!/usr/bin/env bash
# Verify all v0.17.2-beta.1 contracts on Etherscan.
#
# CRITICAL: foundry.toml must have `auto_detect_remappings = false` under
# [profile.default] before running this. Without it, foundry auto-discovers
# `lib/SuperPaymaster/contracts/src/...` paths and Etherscan's source resolver
# fails with "Source 'lib/SuperPaymaster/...' not found".
#
# Run after setting that flag:
#   bash scripts/verify-v0172-beta.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Source env
set -a; . .env.sepolia; set +a

if ! grep -q "auto_detect_remappings = false" foundry.toml; then
  echo "ERROR: foundry.toml must have 'auto_detect_remappings = false' in [profile.default]" >&2
  echo "Add this line and re-run." >&2
  exit 1
fi

CHAIN_FLAGS="--chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --compiler-version 0.8.33 --num-of-optimizations 300 --evm-version cancun --via-ir"

# Constructor args
AGG_CTOR=$(cast abi-encode "constructor(address)" 0xB82127182A855B82eED05e47536FcE568b626457)
FACTORY_CTOR=$(cast abi-encode "constructor(address,address,address[],(uint256,uint256,uint256)[])" \
  0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 \
  "[]" "[]")

verify_one() {
  local addr="$1"; local target="$2"; local ctor_arg="${3:-}"
  echo ""
  echo "============================================================"
  echo "  Verifying $target"
  echo "  at $addr"
  echo "============================================================"
  local extra=""
  if [ -n "$ctor_arg" ]; then extra="--constructor-args $ctor_arg"; fi
  forge verify-contract "$addr" "$target" $CHAIN_FLAGS $extra --watch 2>&1 | tail -8
  echo ""
  # short pause between contracts to be polite to Etherscan + give RPC time
  sleep 5
}

verify_one "0x29edC0e59C7cCcd89334139556Bc254bBC1B1E2F" "src/validators/AAStarValidator.sol:AAStarValidator"
verify_one "0xBAc3f24946d0eb15189E1c01e38182e5B078Bbc1" "src/aggregator/AAStarBLSAggregator.sol:AAStarBLSAggregator" "$AGG_CTOR"
verify_one "0xc1e2534D9Cae27Fd9776e612229115604A9e07E9" "src/validators/SessionKeyValidator.sol:SessionKeyValidator"
verify_one "0x10dF485018620CCb04BfA290DD4ca8c05Ae72aD9" "src/core/ForceExitModule.sol:ForceExitModule"
verify_one "0x8603AAF6C3f07fdae810B323c95a198D796EC52E" "src/core/AirAccountDelegate.sol:AirAccountDelegate"
verify_one "0xc6c7FA51814f109Dea73757c73c378a25b2BAeE9" "src/core/AAStarAirAccountFactoryV7.sol:AAStarAirAccountFactoryV7" "$FACTORY_CTOR"
verify_one "0x05274e4Af481e5c23287571F71C52afCCC5Df127" "src/core/AAStarAirAccountV7.sol:AAStarAirAccountV7"
verify_one "0x6e3E6d7e6DFb383CeaAe6A9ae478745FFc5cAac0" "src/core/AirAccountExtension.sol:AirAccountExtension"
