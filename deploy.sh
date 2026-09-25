#!/bin/bash
#
# deploy.sh
#
# Deploys the core contracts (VirtualMachine, ProxyFactory, InvariantChecker,
# ArithmeticProcessor) via script/DeployAll.s.sol.
#
# Use --simulate to preview the addresses without broadcasting. In simulate mode,
# pass either --private-key or --sender; --private-key takes precedence when both
# are supplied.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

PRIVATE_KEY=""
SENDER=""
RPC_URL=${RPC_URL:-"http://localhost:8545"}
VERBOSE="-v"
ETHERSCAN_API_KEY=""
VERIFY=""
GAS_LIMIT=""
TEMPO_FEE_TOKEN=""
LEGACY=""
GAS_PRICE=""
GAS_MULT=""
SIMULATE=""

FORGE_BIN=${FORGE_BIN:-"forge"}
CAST_BIN=${CAST_BIN:-"cast"}
DEPLOY_SCRIPT="script/DeployAll.s.sol"
ADDR_PATTERN="(VirtualMachine|ProxyFactory|InvariantChecker|ArithmeticProcessor) deployed at: 0x[0-9a-fA-F]{40}"
FORGE_EXIT_CODE=0

usage() {
  echo "Usage: ./deploy.sh --private-key <hex-string> [options]"
  echo "       ./deploy.sh --simulate (--private-key <hex-string> | --sender <address>) [options]"
  echo ""
  echo "Options:"
  echo "  --simulate|--dry-run                 Simulate only: do not broadcast transactions"
  echo "  --private-key <hex-string>           Deployer key. Takes precedence over --sender"
  echo "  --sender <address>                   Deployer address for simulation when no private key is provided"
  echo "  --rpc-url <url>                      RPC URL (default: http://localhost:8545)"
  echo "  -v|-vv|-vvv|-vvvv|-vvvvv             Verbosity level"
  echo "  --verify                             Verify contracts on Etherscan (ignored when simulating)"
  echo "  --etherscan-api-key <key>            Etherscan API key (required with --verify)"
  echo "  --gas-limit <value>                  Gas limit for transactions"
  echo "  --tempo-fee-token <address>          TIP-20 fee token for Tempo deployments (requires tempo-foundry)"
  echo "  --legacy                             Use legacy (non-EIP1559) transactions"
  echo "  --with-gas-price <wei>               Gas price for legacy txs / max fee per gas for EIP1559"
  echo "  --gas-estimate-multiplier <pct>      Multiply forge's gas estimate"
  echo ""
  echo "Environment variables:"
  echo "  FORGE_BIN                            Path to forge binary (default: 'forge')"
  echo "  CAST_BIN                             Path to cast binary (default: 'cast')"
}

require_value() {
  if [ -z "${2:-}" ]; then
    echo "Error: $1 requires a value"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --private-key)
        require_value "$1" "${2:-}"
        PRIVATE_KEY="$2"
        shift 2
        ;;
      --sender)
        require_value "$1" "${2:-}"
        SENDER="$2"
        shift 2
        ;;
      --rpc-url)
        require_value "$1" "${2:-}"
        RPC_URL="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE="-v"
        shift
        ;;
      -v|-vv|-vvv|-vvvv|-vvvvv)
        VERBOSE="$1"
        shift
        ;;
      --verify)
        VERIFY="--verify"
        shift
        ;;
      --etherscan-api-key)
        require_value "$1" "${2:-}"
        ETHERSCAN_API_KEY="$2"
        shift 2
        ;;
      --gas-limit)
        require_value "$1" "${2:-}"
        GAS_LIMIT="$2"
        shift 2
        ;;
      --tempo-fee-token)
        require_value "$1" "${2:-}"
        TEMPO_FEE_TOKEN="$2"
        shift 2
        ;;
      --legacy)
        LEGACY="--legacy"
        shift
        ;;
      --with-gas-price)
        require_value "$1" "${2:-}"
        GAS_PRICE="$2"
        shift 2
        ;;
      --gas-estimate-multiplier)
        require_value "$1" "${2:-}"
        GAS_MULT="$2"
        shift 2
        ;;
      --simulate|--dry-run)
        SIMULATE="1"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate_args() {
  if [ -z "$PRIVATE_KEY" ] && [ -z "$SENDER" ]; then
    echo "Error: either --private-key or --sender is required"
    usage
    exit 1
  fi

  if [ -z "$SIMULATE" ] && [ -z "$PRIVATE_KEY" ]; then
    echo "Error: --private-key is required for real deployments"
    echo "       --sender can only be used with --simulate"
    exit 1
  fi

  if [ -n "$SIMULATE" ] && [ "$VERIFY" = "--verify" ]; then
    echo "Note: --verify is ignored when simulating (no contracts are deployed)"
    VERIFY=""
    ETHERSCAN_API_KEY=""
  fi

  if [ "$VERIFY" = "--verify" ] && [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "Error: --etherscan-api-key is required when using --verify"
    exit 1
  fi

  if [ -n "$PRIVATE_KEY" ] && [ -n "$SENDER" ]; then
    echo "Note: --private-key takes precedence over --sender"
  fi
}

build_command() {
  FORGE_CMD=("$FORGE_BIN" script "$DEPLOY_SCRIPT" --rpc-url "$RPC_URL")

  if [ -n "$PRIVATE_KEY" ]; then
    FORGE_CMD+=(--private-key "$PRIVATE_KEY")
    if [ -n "$SIMULATE" ]; then
      SIM_DEPLOYER=$(command -v "$CAST_BIN" >/dev/null 2>&1 && "$CAST_BIN" wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
      SIM_DEPLOYER="${SIM_DEPLOYER:-"(derived from --private-key)"}"
    fi
  elif [ -n "$SIMULATE" ]; then
    FORGE_CMD+=(--sender "$SENDER")
    SIM_DEPLOYER="$SENDER"
  fi

  if [ -z "$SIMULATE" ]; then
    FORGE_CMD+=(--broadcast)
  fi

  FORGE_CMD+=("$VERBOSE")

  if [ "$VERIFY" = "--verify" ]; then
    FORGE_CMD+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
  fi

  if [ -n "$GAS_LIMIT" ]; then
    FORGE_CMD+=(--gas-limit "$GAS_LIMIT")
  fi

  if [ -n "$TEMPO_FEE_TOKEN" ]; then
    if ! "$FORGE_BIN" -V 2>&1 | grep -q "tempo"; then
      echo "Error: --tempo-fee-token requires tempo-foundry."
      echo "Install it with ./setup-tempo-foundry.sh, then re-run with:"
      echo "  FORGE_BIN=\$HOME/.foundry-tempo/bin/forge ./deploy.sh ..."
      exit 1
    fi
    FORGE_CMD+=(--tempo.fee-token "$TEMPO_FEE_TOKEN")
  fi

  if [ -n "$LEGACY" ]; then
    FORGE_CMD+=(--legacy)
  fi
  if [ -n "$GAS_PRICE" ]; then
    FORGE_CMD+=(--with-gas-price "$GAS_PRICE")
  fi
  if [ -n "$GAS_MULT" ]; then
    FORGE_CMD+=(--gas-estimate-multiplier "$GAS_MULT")
  fi
}

extract_addresses() {
  grep -oE "$ADDR_PATTERN" "$1" | awk '!seen[$0]++'
}

report_simulated_addresses() {
  local addresses
  addresses=$(extract_addresses "$1")

  if [ -z "$addresses" ]; then
    echo "Warning: Could not find deployment addresses in output"
    return
  fi

  echo "$addresses" | while read -r NAME _ _ ADDR; do
    STATUS="unknown (cast unavailable)"
    if command -v "$CAST_BIN" >/dev/null 2>&1; then
      CODE=$("$CAST_BIN" code "$ADDR" --rpc-url "$RPC_URL" 2>/dev/null)
      if [ -n "$CODE" ] && [ "$CODE" != "0x" ]; then
        STATUS="ALREADY DEPLOYED"
      else
        STATUS="not deployed yet"
      fi
    fi
    printf "%-22s %s  [%s]\n" "$NAME" "$ADDR" "$STATUS"
  done
}

run_deployment() {
  build_command

  local forge_output
  forge_output=$(mktemp)
  trap 'rm -f "$forge_output"' RETURN

  if [ -n "$SIMULATE" ]; then
    echo "Simulating deployment against $RPC_URL (no transactions will be sent)"
    echo ""
  fi

  "${FORGE_CMD[@]}" 2>&1 | tee "$forge_output"
  FORGE_EXIT_CODE=${PIPESTATUS[0]}

  if [ $FORGE_EXIT_CODE -ne 0 ]; then
    if [ -n "$SIMULATE" ]; then
      echo ""
      echo "Simulation FAILED - see the forge output above."
      echo "The deployment would not succeed on this chain as configured."
    fi
    return
  fi

  if [ -n "$SIMULATE" ]; then
    echo ""
    echo "==================== Simulation Summary ===================="
    echo "Deployer (simulated): $SIM_DEPLOYER"
    echo ""
    report_simulated_addresses "$forge_output"
    echo ""
    echo "No transactions were broadcast. To deploy for real, run:"
    echo "  ./deploy.sh --private-key <deployer-key> --rpc-url $RPC_URL"
    echo "============================================================"
  else
    echo ""
    echo "==================== Deployment Summary ===================="
    extract_addresses "$forge_output" | grep . || echo "Warning: Could not find deployment addresses in output"
    echo "============================================================"
  fi
}

parse_args "$@"
validate_args
run_deployment

exit $FORGE_EXIT_CODE
