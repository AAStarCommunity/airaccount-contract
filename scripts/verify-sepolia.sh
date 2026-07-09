#!/usr/bin/env bash
# verify-sepolia.sh — Verify the CURRENT AirAccount stack on Etherscan (Sepolia).
#
# ── STATUS (2026-07-09, checked via Etherscan v2 getsourcecode) ──────────────
#   The deployed v0.27.0 Sepolia stack is 0/9 VERIFIED. This script verifies them.
#
# ── ⚠️ VERSION-MATCH REQUIREMENT ─────────────────────────────────────────────
#   Verification matches the SUBMITTED source against the DEPLOYED bytecode.
#   ACCOUNT_VERSION/FACTORY_VERSION are compiled into the bytecode, so you MUST run
#   this from a checkout whose source matches the deployed version:
#     - deployed Sepolia = v0.27.0  → run from `git worktree add ../aa-v0270 v0.27.0`
#     - main is now v0.28.0 (unbumped rename) → do NOT verify v0.27.0 contracts from main.
#   After a fresh v0.28.0 deploy, re-run this from main against the new addresses.
#
# ── ⚠️ KNOWN TOOLING BLOCKER (forge 1.7.1 on macOS) ──────────────────────────
#   `forge verify-contract` fails to build standard-json: "Failed to get standard
#   json input — cannot resolve file at src/...". The `--flatten` path then demands
#   bytecode_hash=ipfs, but the stack was deployed with bytecode_hash=none → mismatch.
#   WORKAROUNDS (either):
#     (a) run this from CI / Linux with a known-good foundry, OR
#     (b) POST the exact standard-json from out/build-info/*.json (`.input`) to the
#         Etherscan v2 API (module=contract&action=verifysourcecode) directly.
#   This script uses the forge path; switch runner if (a)/(b) is needed.
#
# ── KEY ──────────────────────────────────────────────────────────────────────
#   Working Etherscan v2 key is in ~/Dev/.env (ETHERSCAN_API_KEY). The MZD… key in
#   .env.sepolia is DEAD ("Missing/Invalid API Key") — do not use it.
#
# Usage:  bash scripts/verify-sepolia.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

set -a; . .env.sepolia; set +a                          # addresses (AIRACCOUNT_V0270_*)
KEY="$(grep ETHERSCAN_API_KEY "$HOME/Dev/.env" | head -1 | sed -E 's/.*="?([^"]*)"?.*/\1/')"   # working key
[ -n "$KEY" ] || { echo "ERROR: no ETHERSCAN_API_KEY in ~/Dev/.env" >&2; exit 1; }

grep -q "auto_detect_remappings = false" foundry.toml || { echo "ERROR: foundry.toml needs auto_detect_remappings=false" >&2; exit 1; }

FLAGS="--chain sepolia --etherscan-api-key $KEY \
  --compiler-version 0.8.33 --num-of-optimizations 200 --evm-version cancun --via-ir --watch"

# Constructor args (from deploy-v0.27.0.ts) for the two contracts that take them.
IMPL_CTOR="$(cast abi-encode 'constructor(address)' "$AIRACCOUNT_V0270_VALIDATOR_ROUTER")"
FACTORY_CTOR="$(cast abi-encode 'constructor(address,address,address,address[],(uint256,uint256,uint256)[])' \
  "$AIRACCOUNT_V0270_IMPL" 0x0000000071727De22E5E9d8BAf0edAc6f37da032 "$COMMUNITY_GUARDIAN_ADDRESS" '[]' '[]')"

verify() {  # <addr> <target> [ctor-args-hex]
  echo -e "\n=== $2  @ $1 ==="
  local extra=""; [ -n "${3:-}" ] && extra="--constructor-args $3"
  forge verify-contract "$1" "$2" $FLAGS $extra 2>&1 | tail -6
  sleep 4
}

verify "$AIRACCOUNT_V0270_VALIDATOR_ROUTER"      "src/validators/AAStarValidator.sol:AAStarValidator"
verify "$AIRACCOUNT_V0270_SESSION_KEY_VALIDATOR" "src/validators/SessionKeyValidator.sol:SessionKeyValidator"
verify "$AIRACCOUNT_V0270_AGENT_REGISTRY"        "src/core/AgentRegistry.sol:AgentRegistry"
verify "$AIRACCOUNT_V0270_IMPL"                  "src/core/AAStarAirAccountV7.sol:AAStarAirAccountV7"          "$IMPL_CTOR"
verify "$AIRACCOUNT_V0270_FACTORY"               "src/core/AAStarAirAccountFactoryV7.sol:AAStarAirAccountFactoryV7" "$FACTORY_CTOR"

# NOTE: Extension is deployed via an internal `new` inside the impl ctor — verify it by reading its
# creation-tx constructor args from Etherscan. ForceExit/Delegate/ParserRegistry are reused from an
# earlier deploy version — verify them from THAT version's tag, not this stack's version.
echo -e "\nDone. Re-check status: curl the Etherscan v2 getsourcecode API for each address."
