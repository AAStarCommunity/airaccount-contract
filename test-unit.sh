#!/usr/bin/env bash
# test-unit.sh — Run all YetAnotherAA-Validator unit tests with gas report
#
# Usage (from project root):
#   bash test-unit.sh
#   bash test-unit.sh -m testValidateUserOpWithBLSSignature   # single test
#   bash test-unit.sh -f test/AAStarValidator.t.sol           # single file
#   bash test-unit.sh -v                                       # verbose

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_DIR="$REPO_ROOT/lib/YetAnotherAA-Validator/contracts"

cd "$CONTRACT_DIR"

VERBOSE=""
MATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE="-vvv" ;;
    -m|--match)   MATCH="--match-test $2"; shift ;;
    -f|--file)    MATCH="--match-path $2"; shift ;;
    *) echo "Usage: $0 [-v] [-m <test>] [-f <file>]"; exit 1 ;;
  esac
  shift
done

echo "======================================"
echo " YetAnotherAA Unit Tests + Gas Report"
echo " $(date)"
echo "======================================"
echo ""

forge build --silent
forge test --gas-report $VERBOSE $MATCH
