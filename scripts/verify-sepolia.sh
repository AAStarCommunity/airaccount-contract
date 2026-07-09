#!/usr/bin/env bash
# verify-sepolia.sh — Verify the AirAccount stack on Etherscan (Sepolia). PROVEN WORKING 2026-07-09.
#
# ── THE METHOD (what actually works) ─────────────────────────────────────────
#   1. Pass the CONTRACT NAME ONLY (e.g. `AAStarValidator`), NOT a `src/path.sol:Name` form.
#      forge auto-resolves the path; a wrong explicit path is what caused the earlier
#      "cannot resolve file" — it was NOT a foundry bug.
#   2. Use `--chain 11155111` (numeric) + the WORKING key in ~/Dev/.env.
#      (the .env.sepolia MZD… key is DEAD — "Missing/Invalid API Key".)
#   3. The stack ships with `bytecode_hash=none`, so verification matches RUNTIME bytecode
#      only — comments/metadata don't matter, but compiled-in constants (ACCOUNT_VERSION /
#      FACTORY_VERSION) DO. Verify version-carrying contracts at their DEPLOYED version.
#
# ── STATUS (Sepolia v0.27.0 stack) ───────────────────────────────────────────
#   ✅ VERIFIED (4 core): AAStarValidator(router), AAStarAirAccountV7(impl),
#      AAStarAirAccountFactoryV7(factory), AgentRegistry.
#   ⏳ Remaining (SessionKeyValidator, AirAccountExtension, ForceExitModule,
#      AirAccountDelegate, CalldataParserRegistry) are REUSED from earlier deploy
#      versions → their source drifted from main; verify each from its own deploy tag.
#
# Usage:  bash scripts/verify-sepolia.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
set -a; source ./.env.sepolia; set +a                                  # AIRACCOUNT_V0270_* + COMMUNITY_GUARDIAN_ADDRESS
KEY="$(grep ETHERSCAN_API_KEY "$HOME/Dev/.env" | head -1 | sed -E 's/.*="?([^"]*)"?.*/\1/')"
[ -n "$KEY" ] || { echo "ERROR: no ETHERSCAN_API_KEY in ~/Dev/.env" >&2; exit 1; }
EP="0x0000000071727De22E5E9d8BAf0edAc6f37da032"                        # EntryPoint v0.7

FLAGS="--chain 11155111 --etherscan-api-key $KEY --compiler-version 0.8.33 \
  --num-of-optimizations 200 --evm-version cancun --via-ir --watch"

vf(){ echo -e "\n=== $2 @ $1 ==="; local x=""; [ -n "${3:-}" ] && x="--constructor-args $3"
      forge verify-contract "$1" "$2" $FLAGS $x 2>&1 | grep -iE "Details:|verified|does NOT match" | tail -2; }

# ── Version-independent (verify from current source) ─────────────────────────
vf "$AIRACCOUNT_V0270_VALIDATOR_ROUTER" AAStarValidator
vf "$AIRACCOUNT_V0270_AGENT_REGISTRY"   AgentRegistry

# ── Version-carrying (Impl/Factory) — deployed at v0.27.0 ─────────────────────
# ACCOUNT_VERSION/FACTORY_VERSION are compiled in. main is now v0.28.0, so temporarily pin the two
# constants back to the DEPLOYED version, rebuild, verify, restore. (Rename didn't change bytecode.)
DEPLOYED_VERSION="0.27.0"
perl -pi -e "s/(ACCOUNT_VERSION = )\"[0-9.]+\"/\$1\"$DEPLOYED_VERSION\"/" src/core/AAStarAirAccountV7.sol
perl -pi -e "s/(FACTORY_VERSION = )\"[0-9.]+\"/\$1\"$DEPLOYED_VERSION\"/" src/core/AAStarAirAccountFactoryV7.sol
forge build --skip script >/dev/null 2>&1
IMPL_CTOR=$(cast abi-encode 'constructor(address)' "$AIRACCOUNT_V0270_VALIDATOR_ROUTER")
FACTORY_CTOR=$(cast abi-encode 'constructor(address,address,address,address[],(uint256,uint256,uint256)[])' \
  "$AIRACCOUNT_V0270_IMPL" "$EP" "$COMMUNITY_GUARDIAN_ADDRESS" '[]' '[]')
vf "$AIRACCOUNT_V0270_IMPL"    AAStarAirAccountV7          "$IMPL_CTOR"
vf "$AIRACCOUNT_V0270_FACTORY" AAStarAirAccountFactoryV7   "$FACTORY_CTOR"
git checkout src/core/AAStarAirAccountV7.sol src/core/AAStarAirAccountFactoryV7.sol >/dev/null 2>&1
forge build --skip script >/dev/null 2>&1
echo -e "\nRestored version constants. NOTE: reused modules (SessionKeyValidator / AirAccountExtension /"
echo "ForceExitModule / AirAccountDelegate / CalldataParserRegistry) must be verified from their own"
echo "deploy-version tag (their main source has drifted). For OP mainnet: same method, --chain 10."
