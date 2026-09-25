#!/usr/bin/env bash
#
# Check proxy deployment status across all chains for a given user address.
#
# For each chain listed in DEPLOYMENTS.md, this script:
#   1. Calls ProxyFactory.predictProxyAddress(user) on the chain's RPC.
#   2. Checks whether the predicted address has bytecode (i.e. proxy deployed).
#
# Usage:
#   ./check.sh <user-address>
#
# Env overrides:
#   FACTORY=0x...               Override factory address (default: parsed from DEPLOYMENTS.md)
#   RPC_<chainId>=<url>         Override RPC for a specific chain (e.g. RPC_999=https://...)
#   PARALLEL=<n>                Concurrent jobs (default: 8)
#
# Compatible with bash 3.2 (macOS default).

set -uo pipefail

USER_ADDRESS="${1:-}"
if [ -z "$USER_ADDRESS" ]; then
  echo "Usage: $0 <user-address>" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEPLOYMENTS="$REPO_ROOT/DEPLOYMENTS.md"
if [ ! -f "$DEPLOYMENTS" ]; then
  echo "Error: DEPLOYMENTS.md not found at $DEPLOYMENTS" >&2
  exit 1
fi

for cmd in cast awk grep sort xargs column; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required" >&2; exit 1; }
done

FACTORY="${FACTORY:-$(awk -F'`' '/ProxyFactory/ && /0x/ {print $2; exit}' "$DEPLOYMENTS")}"
if [ -z "$FACTORY" ]; then
  echo "Error: could not parse ProxyFactory address from DEPLOYMENTS.md" >&2
  exit 1
fi

# Default public RPCs (case statement keeps us bash-3.2 compatible).
# Override per-chain via RPC_<chainId> env vars. Empty => SKIP.
default_rpc() {
  case "$1" in
    1)      echo "https://eth.llamarpc.com" ;;
    10)     echo "https://mainnet.optimism.io" ;;
    56)     echo "https://bsc-dataseed.bnbchain.org" ;;
    100)    echo "https://rpc.gnosischain.com" ;;
    130)    echo "https://mainnet.unichain.org" ;;
    137)    echo "https://polygon-rpc.com" ;;
    143)    echo "https://testnet-rpc.monad.xyz" ;;
    146)    echo "https://rpc.soniclabs.com" ;;
    324)    echo "https://mainnet.era.zksync.io" ;;
    480)    echo "https://worldchain-mainnet.g.alchemy.com/public" ;;
    999)    echo "https://rpc.hyperliquid.xyz/evm" ;;
    1088)   echo "https://andromeda.metis.io/?owner=1088" ;;
    1135)   echo "https://rpc.api.lisk.com" ;;
    1868)   echo "https://rpc.soneium.org" ;;
    4326)   echo "" ;;  # MegaETH — set RPC_4326 to override
    5000)   echo "https://rpc.mantle.xyz" ;;
    8453)   echo "https://mainnet.base.org" ;;
    42161)  echo "https://arb1.arbitrum.io/rpc" ;;
    42220)  echo "https://forno.celo.org" ;;
    43114)  echo "https://api.avax.network/ext/bc/C/rpc" ;;
    59144)  echo "https://rpc.linea.build" ;;
    80094)  echo "https://rpc.berachain.com" ;;
    98866)  echo "" ;;  # Plume — set RPC_98866 to override
    534352) echo "https://rpc.scroll.io" ;;
    747474) echo "https://rpc.katana.network" ;;
    *)      echo "" ;;
  esac
}

resolve_rpc() {
  local id="$1"
  local var="RPC_${id}"
  local override="${!var:-}"
  if [ -n "$override" ]; then echo "$override"; return; fi
  default_rpc "$id"
}

# Worker. Reads "id<TAB>name<TAB>rpc" on stdin (one record).
check_chain() {
  local id="$1" name="$2" rpc="$3"
  [ "$rpc" = "NONE" ] && rpc=""
  if [ -z "$rpc" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "-" "SKIP" "no RPC (set RPC_${id})"
    return
  fi

  local predicted
  predicted="$(cast call "$FACTORY" 'predictProxyAddress(address)(address)' "$USER_ADDRESS" --rpc-url "$rpc" 2>/dev/null)" || {
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "-" "ERR" "predict call failed"
    return
  }
  predicted="$(echo "$predicted" | tr -d '[:space:]')"
  if [ -z "$predicted" ] || [ "$predicted" = "0x0000000000000000000000000000000000000000" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "-" "ERR" "empty prediction (factory missing?)"
    return
  fi

  local code
  code="$(cast code "$predicted" --rpc-url "$rpc" 2>/dev/null)" || {
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$predicted" "ERR" "code call failed"
    return
  }
  if [ "$code" = "0x" ] || [ -z "$code" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$predicted" "MISSING" ""
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$predicted" "DEPLOYED" ""
  fi
}

export -f check_chain
export FACTORY USER_ADDRESS

PARALLEL="${PARALLEL:-8}"

echo "Factory: $FACTORY"
echo "User:    $USER_ADDRESS"
echo

# Build "id<TAB>name<TAB>rpc" records into a temp file.
TMP="$(mktemp)"
RESULTS="$(mktemp)"
trap 'rm -f "$TMP" "$RESULTS"' EXIT

CHAIN_COUNT=0
while IFS='|' read -r id name; do
  rpc="$(resolve_rpc "$id")"
  # Null-separated triples so xargs -0 -n 3 can pass them as 3 distinct args.
  # BSD xargs collapses runs of NUL, so empty RPCs are sent as the literal "NONE".
  [ -z "$rpc" ] && rpc="NONE"
  printf '%s\0%s\0%s\0' "$id" "$name" "$rpc" >> "$TMP"
  CHAIN_COUNT=$((CHAIN_COUNT + 1))
done < <(awk -F'|' '
  /^\| *[0-9]+ *\|/ {
    gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $3);
    print $2 "|" $3
  }' "$DEPLOYMENTS")

if [ "$CHAIN_COUNT" -eq 0 ]; then
  echo "Error: no chains parsed from DEPLOYMENTS.md" >&2
  exit 1
fi

# Run in parallel: each call gets exactly 3 args (id, name, rpc).
xargs -0 -n 3 -P "$PARALLEL" bash -c 'check_chain "$1" "$2" "$3"' _ < "$TMP" > "$RESULTS"

# Print sorted by chain_id (numeric).
{
  printf 'CHAIN_ID\tNAME\tPREDICTED_ADDRESS\tSTATUS\tNOTE\n'
  sort -n -k1,1 "$RESULTS"
} | column -t -s "$(printf '\t')"

deployed=$(grep -c "$(printf '\tDEPLOYED\t')" "$RESULTS" || true)
missing=$(grep -c "$(printf '\tMISSING\t')" "$RESULTS" || true)
errors=$(grep -c "$(printf '\tERR\t')" "$RESULTS" || true)
skipped=$(grep -c "$(printf '\tSKIP\t')" "$RESULTS" || true)

echo
echo "Summary: ${deployed}/${CHAIN_COUNT} deployed | ${missing} missing | ${errors} errors | ${skipped} skipped"

if [ "$missing" -gt 0 ] || [ "$errors" -gt 0 ]; then
  exit 2
fi
exit 0
