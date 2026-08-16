#!/usr/bin/env bash
# Probe the EIP-7212 (RIP-7212) P-256 precompile at 0x100 across chains (read-only, no gas).
# A valid abi.encode(hash,r,s,x,y) returns 1 iff the precompile is live; empty return = absent
# (precompile cost ~6,900 gas on L1 EIP-7951 / ~3,450 on OP-Stack RIP-7212; without it, ALL P256 sites —
#  shared Solady primitive since #191 — fall back to the canonical Solidity verifier 0x…Ea1a at ~300k gas
#  where it is deployed (most chains incl. Sepolia); P256 fails only where NEITHER precompile nor verifier exists).
# Issue #28. Usage: bash scripts/probe-eip7212.sh
set -u
# A known-valid secp256r1 vector (payloadHash || r || s || x || y), 160 bytes.
IN="0x8b60709d5ed0da5caf5fb6c91e7c507a7580a438046e24aa527761fa93b249a4c8dd49a86356bf038385cce161bad16a4208c21c3a5bff43b7fb4560a1794ed458b3f6aaddc832edf24a7fae98b65a336daedf059b4091ee5aa00d674c6d7d5fe8e47200eb693978a384a1d2d4baaca209c91a2fefa004e818ae9a734bf7287c6e9808d701ac9a2fcad8ede6374ed3dc8187eaade2f0ae3a43a0232441df32d1"
ONE="0x0000000000000000000000000000000000000000000000000000000000000001"
probe() {
  local name="$1" rpc="$2"
  local out
  out=$(curl -s --max-time 12 "$rpc" -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"0x0000000000000000000000000000000000000100\",\"data\":\"$IN\"},\"latest\"]}" \
    2>/dev/null | grep -oE '"result":"0x[0-9a-f]*"' | cut -d'"' -f4)
  if   [ "$out" = "$ONE" ];                 then echo "  ✅ $name — EIP-7212 PRESENT"
  elif [ -z "$out" ] || [ "$out" = "0x" ];  then echo "  ❌ $name — NO precompile (P256 ~300k gas)"
  else echo "  ⚠️  $name — unexpected: ${out:0:20}..."; fi
}
echo "=== EIP-7212 P-256 precompile (0x100) probe — $(date -u +%Y-%m-%d) ==="
probe "ETH mainnet     " "https://ethereum-rpc.publicnode.com"
probe "ETH Sepolia     " "https://ethereum-sepolia-rpc.publicnode.com"
probe "OP Mainnet      " "https://optimism-rpc.publicnode.com"
probe "OP Sepolia      " "https://optimism-sepolia-rpc.publicnode.com"
probe "Base Mainnet    " "https://base-rpc.publicnode.com"
probe "Base Sepolia    " "https://base-sepolia-rpc.publicnode.com"
probe "Arbitrum One    " "https://arbitrum-one-rpc.publicnode.com"
probe "Arbitrum Sepolia" "https://arbitrum-sepolia-rpc.publicnode.com"
probe "Polygon PoS     " "https://polygon-bor-rpc.publicnode.com"
probe "Avalanche C     " "https://avalanche-c-chain-rpc.publicnode.com"
