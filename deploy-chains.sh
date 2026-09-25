#!/bin/bash
#
# deploy-chains.sh
#
# Deploys the core contract set described by a deployment manifest (default
# deployments/v1.1.json: VirtualMachine, ProxyFactory, InvariantChecker, ArithmeticProcessor,
# and the BlueprintEncoder library the VM links) to the chains listed in chains.json, verifies
# source, and checks every address on-chain afterwards.
#
#   DEPLOYER_ACCOUNT=deployer ./deploy-chains.sh                        # every chain in chains.json
#   DEPLOYER_ACCOUNT=deployer ./deploy-chains.sh sepolia base-sepolia   # only these chains
#
# The deployer signs from a Foundry keystore (`cast wallet import deployer --interactive`), so the
# private key never appears in a process argument list. Without ETH_PASSWORD, cast and forge prompt
# for the keystore password: once at start, then once per chain broadcast.
#
# Before any chain is touched, the set is deployed to a throwaway local anvil and the runtime
# codehashes are read back. They must equal the pinned codehashes in the manifest, or the run
# stops before sending anything. The codehashes do not depend on the chain: ProxyFactory's
# immutables are the VM and CreateX addresses, which are the same everywhere.
#
# Per chain: simulate as the deployer address (no signer needed); broadcast only when the
# simulation prints the canonical addresses; then compare each on-chain codehash, the linked
# libraries included, with the reference build.
# Re-runs are idempotent: deployed contracts are adopted, and forge sends no transactions.
#
# Manifest fields:
#   commit                      full SHA; the source must match this commit in src/, script/,
#                               lib/, foundry.toml and remappings.txt
#   deployer                    address the DEPLOYER_ACCOUNT keystore must hold
#   contracts[]                 name (as printed by DeployAll), address, codehash
#   libraries[]                 name, address, codehash of each library forge links into a
#                               contract; the VM codehash embeds these addresses
#
# chains.json fields per chain:
#   name, chainId, rpc          required
#   verifier                    etherscan | blockscout | sourcify | none
#   verifierUrl                 required for blockscout
#   extraArgs                   optional array of extra `forge script` flags, e.g. ["--legacy"]
#
# Environment:
#   DEPLOYER_ACCOUNT    Foundry keystore account of the manifest deployer (required unless UNLOCKED=1)
#   ETH_PASSWORD        Optional path to the keystore password file; skips the password prompts
#   ETHERSCAN_API_KEY   Etherscan V2 key, required when a selected chain uses the etherscan verifier
#   MANIFEST            Deployment manifest (default: deployments/v1.1.json next to this script)
#   CHAINS_FILE         Chain registry (default: chains.json next to this script)
#   RPC_<NAME>          RPC override, e.g. RPC_SEPOLIA, RPC_ARC_TESTNET
#   NO_VERIFY=1         Skip explorer verification
#   UNLOCKED=1          Rehearsal on an anvil fork started with --auto-impersonate: send as the
#                       deployer without a key. Use with RPC_<NAME> pointing at the fork.

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR" || exit 1

MANIFEST=${MANIFEST:-"$SCRIPT_DIR/deployments/v1.1.json"}
CHAINS_FILE=${CHAINS_FILE:-"$SCRIPT_DIR/chains.json"}
CREATEX_SOURCE="lib/createx-forge/script/CreateX.d.sol"

usage() {
  echo "Usage: DEPLOYER_ACCOUNT=<keystore-account> ./deploy-chains.sh [chain...]"
  echo "Chains in $CHAINS_FILE:"
  jq -r '.chains[] | "  \(.name)  (\(.chainId))"' "$CHAINS_FILE"
}

lower() { echo "$1" | tr 'A-F' 'a-f'; }

load_manifest() {
  # Sets DEPLOYER, COMMIT and the parallel arrays NAMES, ADDRS, PINNED: the contracts in manifest
  # order, then the libraries. N_CONTRACTS is the number of contracts at the front.
  local name addr hash
  if [ ! -f "$MANIFEST" ]; then
    echo "Error: manifest $MANIFEST not found"; exit 1
  fi
  DEPLOYER=$(jq -r '.deployer' "$MANIFEST")
  COMMIT=$(jq -r '.commit' "$MANIFEST")
  NAMES=(); ADDRS=(); PINNED=()
  while read -r name addr hash; do
    NAMES+=("$name"); ADDRS+=("$addr"); PINNED+=("$hash")
  done < <(jq -r '.contracts[] | "\(.name) \(.address) \(.codehash)"' "$MANIFEST")
  N_CONTRACTS=${#NAMES[@]}
  while read -r name addr hash; do
    NAMES+=("$name"); ADDRS+=("$addr"); PINNED+=("$hash")
  done < <(jq -r '.libraries[]? | "\(.name) \(.address) \(.codehash)"' "$MANIFEST")
  VM=$(address_of VirtualMachine)
  PF=$(address_of ProxyFactory)
  if [ -z "$VM" ] || [ -z "$PF" ]; then
    echo "Error: $MANIFEST must list VirtualMachine and ProxyFactory"; exit 1
  fi
}

address_of() {
  local i
  for i in "${!NAMES[@]}"; do
    if [ "${NAMES[$i]}" = "$1" ]; then echo "${ADDRS[$i]}"; return; fi
  done
}

select_chains() {
  # Sets SELECTED to the named chains, or to every chain when no name is given.
  if [ $# -eq 0 ]; then
    SELECTED=$(jq -r '.chains[].name' "$CHAINS_FILE")
    return
  fi
  local arg
  for arg in "$@"; do
    if [ -z "$(jq -r --arg a "$arg" '.chains[] | select(.name == $a) | .name' "$CHAINS_FILE")" ]; then
      echo "Error: no chain named '$arg'"; usage; exit 1
    fi
  done
  SELECTED="$*"
}

chain_config() {
  # Sets CHAIN_ID, RPC, VERIFY_ARGS, EXTRA_ARGS for chain $1.
  local entry override_var verifier arg
  entry=$(jq -c --arg n "$1" '.chains[] | select(.name == $n)' "$CHAINS_FILE")
  CHAIN_ID=$(jq -r '.chainId' <<<"$entry")
  RPC=$(jq -r '.rpc' <<<"$entry")
  override_var="RPC_$(echo "$1" | tr 'a-z-' 'A-Z_')"
  RPC=${!override_var:-$RPC}

  EXTRA_ARGS=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && EXTRA_ARGS+=("$arg")
  done < <(jq -r '.extraArgs[]?' <<<"$entry")

  VERIFY_ARGS=()
  verifier=$(jq -r '.verifier // "etherscan"' <<<"$entry")
  if [ -n "${NO_VERIFY:-}" ] || [ "$verifier" = "none" ]; then
    return
  fi
  case $verifier in
    # forge reads ETHERSCAN_API_KEY from the environment; keep it out of the argument list.
    etherscan) VERIFY_ARGS=(--verify) ;;
    blockscout) VERIFY_ARGS=(--verify --verifier blockscout --verifier-url "$(jq -r '.verifierUrl' <<<"$entry")") ;;
    sourcify) VERIFY_ARGS=(--verify --verifier sourcify) ;;
    *) echo "Error: $1 has unknown verifier '$verifier' in $CHAINS_FILE"; exit 1 ;;
  esac
}

preflight() {
  if [ -n "${UNLOCKED:-}" ]; then
    SIGNER_ARGS=(--sender "$DEPLOYER" --unlocked)
  else
    if [ -z "${DEPLOYER_ACCOUNT:-}" ]; then
      echo "Error: DEPLOYER_ACCOUNT is not set (a Foundry keystore account; see the header of $0)"; exit 1
    fi
    SIGNER_ARGS=(--account "$DEPLOYER_ACCOUNT")
    if [ -n "${ETH_PASSWORD:-}" ]; then
      SIGNER_ARGS+=(--password-file "$ETH_PASSWORD")
    fi
    local addr
    addr=$(cast wallet address "${SIGNER_ARGS[@]}")
    if [ "$(lower "$addr")" != "$(lower "$DEPLOYER")" ]; then
      echo "Error: keystore '$DEPLOYER_ACCOUNT' holds '$addr', not the canonical deployer $DEPLOYER"; exit 1
    fi
    # forge does not derive the script sender from --account: without --sender, tx.origin in the
    # script is Foundry's default sender, so the CreateX salts and address predictions are wrong.
    SIGNER_ARGS+=(--sender "$DEPLOYER")
  fi

  if [ -z "${NO_VERIFY:-}" ] && [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    local needs_key
    needs_key=$(jq -r '[.chains[] | select((.name | IN($ARGS.positional[])) and ((.verifier // "etherscan") == "etherscan"))] | length' \
      "$CHAINS_FILE" --args $SELECTED)
    if [ "$needs_key" != "0" ]; then
      echo "Error: ETHERSCAN_API_KEY is not set (or pass NO_VERIFY=1)"; exit 1
    fi
  fi

  # Freeze the source: the set must build from its pinned commit, unmodified. An uninitialised
  # submodule shows no diff, so check initialisation first.
  if git submodule status -- lib | grep -q '^-'; then
    echo "Error: uninitialised submodules under lib/ (run: git submodule update --init --recursive)"; exit 1
  fi
  if ! git diff --quiet "$COMMIT" -- src script foundry.toml remappings.txt lib; then
    echo "Error: checkout differs from $COMMIT in src/, script/, foundry.toml, remappings.txt or lib/"; exit 1
  fi
  if [ -n "$(git status --porcelain -- src script foundry.toml remappings.txt)" ]; then
    echo "Error: uncommitted changes in src/, script/, foundry.toml or remappings.txt"; exit 1
  fi
}

stop_reference_anvil() {
  if [ -n "${ANVIL_PID:-}" ]; then
    kill "$ANVIL_PID" 2>/dev/null
    wait "$ANVIL_PID" 2>/dev/null
    ANVIL_PID=
  fi
  rm -f "${ANVIL_LOG:-}"
}

reference_build() {
  # Deploys the set to a local anvil and sets REF to the resulting codehashes, in manifest order.
  # Exits unless every codehash equals the pinned one: nothing has been sent to any chain yet.
  local out port ref_rpc createx_address createx_code i got ok=1
  echo ""
  echo "==================== reference build (local anvil) ===================="

  createx_address=$(sed -n 's/^address constant CREATEX_ADDRESS = \(0x[0-9a-fA-F]\{40\}\);$/\1/p' "$CREATEX_SOURCE")
  createx_code=$(sed -n 's/^ *hex"\([0-9a-fA-F]*\)";$/0x\1/p' "$CREATEX_SOURCE")
  if [ -z "$createx_address" ] || [ -z "$createx_code" ]; then
    echo "Error: cannot read the CreateX address and runtime code from $CREATEX_SOURCE"; exit 1
  fi

  ANVIL_LOG=$(mktemp)
  anvil --port 0 --auto-impersonate >"$ANVIL_LOG" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 50); do
    port=$(sed -n 's/^Listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$ANVIL_LOG")
    [ -n "$port" ] && break
    sleep 0.2
  done
  if [ -z "$port" ]; then
    cat "$ANVIL_LOG"; echo "Error: local anvil did not start"; exit 1
  fi
  ref_rpc="http://127.0.0.1:$port"

  # DeployAll etches CreateX only inside the script's own EVM, so put it on the anvil node too.
  # DeployAll then checks it against CREATEX_EXTCODEHASH before using it.
  cast rpc anvil_setCode "$createx_address" "$createx_code" --rpc-url "$ref_rpc" >/dev/null &&
    cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$ref_rpc" >/dev/null ||
    { echo "Error: cannot prepare the local anvil"; exit 1; }

  out=$(mktemp)
  if ! forge script script/DeployAll.s.sol --rpc-url "$ref_rpc" --sender "$DEPLOYER" --unlocked \
    --broadcast -v >"$out" 2>&1; then
    cat "$out"; rm -f "$out"; echo "Error: reference deploy failed on the local anvil"; exit 1
  fi
  rm -f "$out"

  REF=()
  for i in "${!NAMES[@]}"; do
    got=$(code_hash "${ADDRS[$i]}" "$ref_rpc")
    REF+=("$got")
    if [ "$got" = "${PINNED[$i]}" ]; then
      printf '  %-20s %s  OK\n' "${NAMES[$i]}" "$got"
    else
      printf '  %-20s MISMATCH (built %s, pinned %s)\n' "${NAMES[$i]}" "$got" "${PINNED[$i]}"; ok=0
    fi
  done
  stop_reference_anvil

  if [ $ok -ne 1 ]; then
    echo "Error: the local build does not match $MANIFEST. Nothing was sent to any chain."; exit 1
  fi
}

code_hash() {
  # code_hash ADDRESS RPC — keccak256 of the runtime code, from eth_getCode. `cast codehash` needs
  # eth_getProof, which some RPCs (Arc Testnet) do not serve. Prints nothing when the RPC fails.
  local code
  code=$(cast code "$1" --rpc-url "$2" 2>/dev/null) || return 1
  cast keccak "$code"
}

has_code() {
  local code
  code=$(cast code "$1" --rpc-url "$RPC" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "0x" ]
}

deploy_set() {
  local out expected got addr i
  out=$(mktemp)
  expected=$(for ((i = 0; i < N_CONTRACTS; i++)); do echo "${NAMES[$i]} ${ADDRS[$i]}"; done)

  # CREATE3 addresses depend only on the deployer and the salts, so the simulation needs no signer.
  echo "--- simulate"
  if ! forge script script/DeployAll.s.sol --rpc-url "$RPC" --sender "$DEPLOYER" "${EXTRA_ARGS[@]}" -v >"$out" 2>&1; then
    cat "$out"; rm -f "$out"; echo "FAIL: simulation failed on $CHAIN"; return 1
  fi
  got=$(grep -oE '[A-Za-z]+ deployed at: 0x[0-9a-fA-F]{40}' "$out" | awk '{print $1, $4}')
  if [ "$got" != "$expected" ]; then
    echo "$got"; rm -f "$out"; echo "FAIL: simulation printed unexpected addresses on $CHAIN"; return 1
  fi
  grep -E 'Estimated (total gas used|amount required)' "$out"

  echo "--- broadcast"
  forge script script/DeployAll.s.sol --rpc-url "$RPC" "${SIGNER_ARGS[@]}" "${EXTRA_ARGS[@]}" \
    --broadcast --slow "${VERIFY_ARGS[@]}" -v 2>&1 | tee "$out"
  local rc=${PIPESTATUS[0]}
  rm -f "$out"
  if [ "$rc" -ne 0 ]; then
    # forge exits non-zero when only verification fails; the on-chain checks decide.
    for addr in "${ADDRS[@]}"; do
      has_code "$addr" || { echo "FAIL: broadcast failed on $CHAIN"; return 1; }
    done
    echo "WARN: forge exited $rc on $CHAIN, but every contract and library has code (verification issue?)"
    WARNINGS+=("$CHAIN: forge exited $rc after deploying; check explorer verification")
  fi
}

check_chain() {
  local ok=1 i got
  for i in "${!NAMES[@]}"; do
    got=$(code_hash "${ADDRS[$i]}" "$RPC")
    if [ "$got" = "${REF[$i]}" ]; then
      printf '  %-20s %s  OK\n' "${NAMES[$i]}" "${ADDRS[$i]}"
    else
      printf '  %-20s %s  MISMATCH (got %s, want %s)\n' "${NAMES[$i]}" "${ADDRS[$i]}" "$got" "${REF[$i]}"; ok=0
    fi
  done
  got=$(cast call "$PF" "vmContract()(address)" --rpc-url "$RPC" 2>/dev/null)
  if [ "$(lower "$got")" = "$(lower "$VM")" ]; then
    echo "  ProxyFactory.vmContract() = $got  OK"
  else
    echo "  ProxyFactory.vmContract() = '$got'  MISMATCH"; ok=0
  fi
  [ $ok -eq 1 ]
}

trap stop_reference_anvil EXIT

load_manifest
select_chains "$@"
preflight
reference_build

WARNINGS=()
RESULTS=()
for CHAIN in $SELECTED; do
  chain_config "$CHAIN"
  echo ""
  echo "==================== $CHAIN ($CHAIN_ID) ===================="
  got_id=$(cast chain-id --rpc-url "$RPC" 2>/dev/null)
  if [ "$got_id" != "$CHAIN_ID" ]; then
    echo "FAIL: $RPC returned chain id '$got_id', want $CHAIN_ID"; RESULTS+=("$CHAIN FAIL (rpc)"); continue
  fi
  echo "Deployer balance: $(cast balance "$DEPLOYER" --ether --rpc-url "$RPC")"

  if deploy_set; then
    echo "--- on-chain checks"
    if check_chain; then RESULTS+=("$CHAIN OK"); else RESULTS+=("$CHAIN FAIL (checks)"); fi
  else
    RESULTS+=("$CHAIN FAIL (deploy)")
  fi
done

echo ""
echo "==================== Summary ===================="
printf '%s\n' "${RESULTS[@]}"
if [ ${#WARNINGS[@]} -gt 0 ]; then printf 'WARN: %s\n' "${WARNINGS[@]}"; fi
printf '%s\n' "${RESULTS[@]}" | grep -q FAIL && exit 1
exit 0
