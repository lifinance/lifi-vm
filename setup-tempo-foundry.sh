#!/bin/bash
#
# Installs tempo-foundry into an isolated directory (~/.foundry-tempo) so it
# does NOT overwrite your main Foundry install at ~/.foundry.
#
# Why: Tempo (chain 4217) has no native gas token. Transactions must carry a
# stablecoin fee-token annotation that only tempo-foundry's `forge` knows how
# to emit. Without it, deployments are accepted by the EVM but rejected by the
# Tempo sequencer (receipt status = 0, contract never persisted).
#
# After install, deploy with:
#   FORGE_BIN=$HOME/.foundry-tempo/bin/forge ./deploy.sh \
#     --private-key <KEY> \
#     --rpc-url https://rpc.mainnet.tempo.xyz \
#     --tempo-fee-token 0x20C0000000000000000000000000000000000000

set -euo pipefail

TEMPO_DIR="$HOME/.foundry-tempo"

echo "==> Installing tempo-foundry into $TEMPO_DIR (isolated from ~/.foundry)"

if ! command -v foundryup >/dev/null 2>&1; then
  echo "Error: foundryup not found on PATH."
  echo "Install Foundry first: https://book.getfoundry.sh/getting-started/installation"
  exit 1
fi

mkdir -p "$TEMPO_DIR/bin"

# foundryup honours FOUNDRY_DIR for the install target. The -n tempo flag
# selects the Tempo fork channel.
FOUNDRY_DIR="$TEMPO_DIR" foundryup -n tempo

echo ""
echo "==> Verifying install"
if [ ! -x "$TEMPO_DIR/bin/forge" ]; then
  echo "Error: $TEMPO_DIR/bin/forge not found after install."
  echo "Your foundryup version may not support '-n tempo'. Check:"
  echo "  https://docs.chainstack.com/docs/tempo-tooling"
  exit 1
fi

FORGE_VERSION=$("$TEMPO_DIR/bin/forge" -V 2>&1 || true)
echo "$FORGE_VERSION"

if ! echo "$FORGE_VERSION" | grep -q "tempo"; then
  echo ""
  echo "Warning: forge version string does not contain 'tempo'."
  echo "The binary may not be the Tempo fork. Re-check the install before using."
  exit 1
fi

echo ""
echo "==> Success. Tempo-foundry installed at $TEMPO_DIR"
echo ""
echo "Use it without polluting your main Foundry:"
echo ""
echo "  export FORGE_BIN=\"$TEMPO_DIR/bin/forge\""
echo ""
echo "Then deploy on Tempo:"
echo ""
echo "  FORGE_BIN=\"$TEMPO_DIR/bin/forge\" ./deploy.sh \\"
echo "    --private-key <KEY> \\"
echo "    --rpc-url https://rpc.mainnet.tempo.xyz \\"
echo "    --tempo-fee-token 0x20C0000000000000000000000000000000000000"
echo ""
echo "To remove: rm -rf $TEMPO_DIR"
