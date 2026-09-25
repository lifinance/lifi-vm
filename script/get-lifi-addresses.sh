#!/usr/bin/env bash
#
# Fetches LI.FI diamond & executor (+ receiver, fee collector) addresses
# from https://github.com/lifinance/contracts deployment files.
#
# Usage:
#   ./script/get-lifi-addresses.sh              # all chains
#   ./script/get-lifi-addresses.sh mainnet       # single chain
#   ./script/get-lifi-addresses.sh arbitrum base  # multiple chains
#   ./script/get-lifi-addresses.sh --json         # JSON output (all chains)
#   ./script/get-lifi-addresses.sh --json mainnet # JSON output (single chain)
#   ./script/get-lifi-addresses.sh --list         # list available chain names

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/lifinance/contracts/main"
NETWORKS_URL="$BASE_URL/config/networks.json"

# Fields to extract from each deployment file
FIELDS=("LiFiDiamond" "LiFiDiamondImmutable" "Executor" "Receiver" "FeeCollector" "ERC20Proxy")

json_mode=false
list_mode=false
chains=()

for arg in "$@"; do
  case "$arg" in
    --json) json_mode=true ;;
    --list) list_mode=true ;;
    --help|-h)
      sed -n '3,12p' "$0"
      exit 0
      ;;
    *) chains+=("$arg") ;;
  esac
done

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# Fetch networks config (chain name -> chain ID mapping)
networks_json=$(curl -sf "$NETWORKS_URL") || {
  echo "Error: failed to fetch networks config from $NETWORKS_URL" >&2
  exit 1
}

if $list_mode; then
  echo "Available chains (name -> chainId):"
  echo "$networks_json" | jq -r 'to_entries | sort_by(.key) | .[] | "  \(.key) (\(.value.chainId))"'
  exit 0
fi

# If no chains specified, use all from networks.json
if [ ${#chains[@]} -eq 0 ]; then
  mapfile -t chains < <(echo "$networks_json" | jq -r 'keys[]' | sort)
fi

# Build jq filter for the fields we want.
# Each field maps to its own dot-path: "LiFiDiamond": .LiFiDiamond, ...
jq_pairs=()
for f in "${FIELDS[@]}"; do
  jq_pairs+=("\"$f\": .$f")
done
jq_filter="{ $(IFS=,; echo "${jq_pairs[*]}") }"

json_results="[]"
errors=()

for chain in "${chains[@]}"; do
  deploy_url="$BASE_URL/deployments/${chain}.json"
  chain_id=$(echo "$networks_json" | jq -r --arg c "$chain" '.[$c].chainId // empty')

  if [ -z "$chain_id" ]; then
    errors+=("Warning: '$chain' not found in networks config, skipping.")
    continue
  fi

  deploy_json=$(curl -sf "$deploy_url" 2>/dev/null) || {
    errors+=("Warning: no deployment file for '$chain' (chainId: $chain_id)")
    continue
  }

  extracted=$(echo "$deploy_json" | jq "$jq_filter")

  # Check if at least diamond or executor exists
  diamond=$(echo "$extracted" | jq -r '.LiFiDiamond // empty')
  executor=$(echo "$extracted" | jq -r '.Executor // empty')

  if [ -z "$diamond" ] && [ -z "$executor" ]; then
    errors+=("Warning: '$chain' deployment has no Diamond or Executor address")
    continue
  fi

  if $json_mode; then
    entry=$(echo "$extracted" | jq --arg c "$chain" --arg id "$chain_id" '. + {chain: $c, chainId: ($id | tonumber)}')
    json_results=$(echo "$json_results" | jq --argjson e "$entry" '. + [$e]')
  else
    echo "=== $chain (chainId: $chain_id) ==="
    for field in "${FIELDS[@]}"; do
      val=$(echo "$extracted" | jq -r --arg f "$field" '.[$f] // "-"')
      printf "  %-24s %s\n" "$field" "$val"
    done
    echo ""
  fi
done

if $json_mode; then
  echo "$json_results" | jq .
fi

# Print warnings at the end
for err in "${errors[@]+"${errors[@]}"}"; do
  echo "$err" >&2
done
