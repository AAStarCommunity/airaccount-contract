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
# trap guarantees the source constants are restored even on Ctrl+C / early error (review: Medium).
IMPL_SRC="src/core/AAStarAirAccountV7.sol"; FACTORY_SRC="src/core/AAStarAirAccountFactoryV7.sol"
restore_versions(){ git checkout "$IMPL_SRC" "$FACTORY_SRC" >/dev/null 2>&1; }
trap restore_versions EXIT INT TERM
DEPLOYED_VERSION="0.27.0"
perl -pi -e "s/(ACCOUNT_VERSION = )\"[0-9.]+\"/\$1\"$DEPLOYED_VERSION\"/" "$IMPL_SRC"
perl -pi -e "s/(FACTORY_VERSION = )\"[0-9.]+\"/\$1\"$DEPLOYED_VERSION\"/" "$FACTORY_SRC"
forge build --skip script >/dev/null 2>&1 || { echo "ERROR: forge build failed after version pin — aborting (review: Low)"; exit 1; }
IMPL_CTOR=$(cast abi-encode 'constructor(address)' "$AIRACCOUNT_V0270_VALIDATOR_ROUTER")
FACTORY_CTOR=$(cast abi-encode 'constructor(address,address,address,address[],(uint256,uint256,uint256)[])' \
  "$AIRACCOUNT_V0270_IMPL" "$EP" "$COMMUNITY_GUARDIAN_ADDRESS" '[]' '[]')
vf "$AIRACCOUNT_V0270_IMPL"    AAStarAirAccountV7          "$IMPL_CTOR"
vf "$AIRACCOUNT_V0270_FACTORY" AAStarAirAccountFactoryV7   "$FACTORY_CTOR"
restore_versions; trap - EXIT INT TERM
forge build --skip script >/dev/null 2>&1 || echo "WARN: rebuild at v0.28.0 failed — run 'forge build' manually"

# ── Reused modules — verified from their DEPLOY-VERSION tags (git worktree add <path> vX.Y.Z) ──
#   These were deployed at older versions (300 optimizer runs, not 200) with drifted source.
#   Build the tag worktree, then `forge verify-contract <addr> <Name> --num-of-optimizations 300 ...`:
#     ✅ AirAccountExtension     → verified from MAIN (version-independent, no ctor, `new` = no args)
#     ✅ SessionKeyValidator     → v0.24.0 worktree (300 runs)
#     ✅ ForceExitModule         → v0.22.0 worktree (300 runs)
#     ✅ CalldataParserRegistry  → already verified on Etherscan
#     ⬜ AirAccountDelegate      → v0.20.0; blocked locally by submodule drift (OZ path) — needs a
#        CLEAN v0.20.0 clone (`git clone` + `git checkout v0.20.0` + `submodule update --init`), 300 runs.
#   STATUS: 8/9 verified on Sepolia (2026-07-09).
# For OP mainnet: redeploy is a single FRESH stack (all at 200 runs) — verify it all in one pass here (--chain 10).
