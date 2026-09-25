#!/bin/bash

# Initialize variables
USER_ADDRESS=""
PROXY_FACTORY_ADDRESS=""
RPC_URL=${RPC_URL:-"http://localhost:8545"}
PRIVATE_KEY=""
VERBOSE="-v"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --user)
      USER_ADDRESS="$2"
      shift 2
      ;;
    --factory)
      PROXY_FACTORY_ADDRESS="$2"
      shift 2
      ;;
    --deploy)
      shift
      ;;
    --private-key)
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --rpc-url)
      RPC_URL="$2"
      shift 2
      ;;
    --verbose|-v|-vv|-vvv)
      VERBOSE="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if required parameters are provided
if [ -z "$USER_ADDRESS" ] || [ -z "$PROXY_FACTORY_ADDRESS" ] || [ -z "$PRIVATE_KEY" ]; then
  echo "Error: --user --factory and --private-key parameters are required"
  echo "Usage: $0 --user <address> --factory <address> --private-key <key> [--rpc-url <url>] [-v|-vv|-vvv]"
  exit 1
fi

# Export environment variables for the script
export USER_ADDRESS="$USER_ADDRESS"
export PROXY_FACTORY_ADDRESS="$PROXY_FACTORY_ADDRESS"

# Set up the forge command
FORGE_CMD="forge script script/GenerateProxyAddress.s.sol --rpc-url \"$RPC_URL\" $VERBOSE --private-key \"$PRIVATE_KEY\" --broadcast --gas-limit 5000000"

# Run the forge command
eval $FORGE_CMD
