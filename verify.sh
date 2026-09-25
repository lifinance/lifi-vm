#!/bin/bash

# Initialize variables
CONTRACT_ADDRESS=""
CONTRACT_NAME=""
RPC_URL=""
ETHERSCAN_API_KEY=""
CONSTRUCTOR_ARGS=""
VERBOSE="-v"
VERIFIER="etherscan"
VERIFIER_URL=""
CHAIN_ID=""

# CreateX address is constant across all chains
CREATEX_ADDRESS="0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --contract-address)
      CONTRACT_ADDRESS="$2"
      shift 2
      ;;
    --contract-name)
      CONTRACT_NAME="$2"
      shift 2
      ;;
    --rpc-url)
      RPC_URL="$2"
      shift 2
      ;;
    --etherscan-api-key)
      ETHERSCAN_API_KEY="$2"
      shift 2
      ;;
    --constructor-args)
      CONSTRUCTOR_ARGS="$2"
      shift 2
      ;;
    --verbose|-v|-vv|-vvv)
      VERBOSE="$1"
      shift
      ;;
    --verifier)
      VERIFIER="$2"
      shift 2
      ;;
    --verifier-url)
      VERIFIER_URL="$2"
      shift 2
      ;;
    --chain-id)
      CHAIN_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if required parameters are provided
if [ -z "$CONTRACT_ADDRESS" ]; then
  echo "Error: --contract-address parameter is required"
  exit 1
fi

if [ -z "$CONTRACT_NAME" ]; then
  echo "Error: --contract-name parameter is required"
  exit 1
fi

# Etherscan API key is only required for etherscan verifier
if [ "$VERIFIER" = "etherscan" ] && [ -z "$ETHERSCAN_API_KEY" ]; then
  echo "Error: --etherscan-api-key parameter is required for etherscan verifier"
  exit 1
fi

# Chain ID is required for sourcify verifier
if [ "$VERIFIER" = "sourcify" ] && [ -z "$CHAIN_ID" ]; then
  echo "Error: --chain-id parameter is required for sourcify verifier"
  exit 1
fi

# Map contract names to their source paths
case "$CONTRACT_NAME" in
  "VirtualMachine")
    CONTRACT_PATH="src/VirtualMachine.sol:VirtualMachine"
    ;;
  "ProxyFactory")
    CONTRACT_PATH="src/proxy/ProxyFactory.sol:ProxyFactory"
    ;;
  "InvariantChecker")
    CONTRACT_PATH="src/InvariantChecker.sol:InvariantChecker"
    ;;
  "ArithmeticProcessor")
    CONTRACT_PATH="src/RPNArithmetic.sol:ArithmeticProcessor"
    ;;
  "BlueprintEncoder")
    CONTRACT_PATH="src/BlueprintEncoder.sol:BlueprintEncoder"
    ;;
  *)
    echo "Error: Unknown contract name: $CONTRACT_NAME"
    echo "Supported contracts: VirtualMachine, ProxyFactory, InvariantChecker, ArithmeticProcessor, BlueprintEncoder"
    echo ""
    echo "Usage examples:"
    echo "  Etherscan: ./verify.sh --contract-address 0x... --contract-name VirtualMachine --etherscan-api-key YOUR_KEY"
    echo "  Sourcify:  ./verify.sh --contract-address 0x... --contract-name VirtualMachine --verifier sourcify --chain-id 143 --rpc-url https://rpc.monad.xyz --verifier-url 'https://sourcify-api-monad.blockvision.org/'"
    exit 1
    ;;
esac

# Build forge verify-contract command
# Include compiler settings from foundry.toml: via_ir=true, optimizer_runs=10000
CMD="forge verify-contract \"$CONTRACT_ADDRESS\" \"$CONTRACT_PATH\" --via-ir --num-of-optimizations 10000 $VERBOSE"

# Add verifier-specific options
if [ "$VERIFIER" = "sourcify" ]; then
  CMD="$CMD --verifier sourcify"
  if [ -n "$VERIFIER_URL" ]; then
    CMD="$CMD --verifier-url \"$VERIFIER_URL\""
  fi
  if [ -n "$CHAIN_ID" ]; then
    CMD="$CMD --chain-id $CHAIN_ID"
  fi
else
  # Default: etherscan
  CMD="$CMD --etherscan-api-key \"$ETHERSCAN_API_KEY\""
fi

# Add RPC URL if provided (optional - forge can detect chain from contract address)
if [ -n "$RPC_URL" ]; then
  CMD="$CMD --rpc-url \"$RPC_URL\""
fi

# Add constructor arguments if provided
if [ -n "$CONSTRUCTOR_ARGS" ]; then
  CMD="$CMD --constructor-args \"$CONSTRUCTOR_ARGS\""
fi

echo "Verifying contract: $CONTRACT_NAME at $CONTRACT_ADDRESS"
echo "Contract path: $CONTRACT_PATH"
echo "Verifier: $VERIFIER"
echo ""

# Execute verification
eval $CMD
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "✅ Contract verified successfully"
else
  echo ""
  echo "❌ Contract verification failed"
fi

exit $EXIT_CODE
