#!/usr/bin/env bash
#
# Deterministic entry point for the Chimera/Recon fuzzing harness (test/recon).
#
# Usage:
#   script/fuzz.sh medusa  [extra medusa args...]     # e.g. --test-limit 100000
#   script/fuzz.sh echidna [extra echidna args...]
#
# WHY THIS SCRIPT EXISTS
#
# crytic-compile parses every file in the Foundry artifact directory's `build-info/`
# and hard-fails when one carries no solc `output`, either inline or in a sibling
# `<id>.output.json`:
#
#   FileNotFoundError: out/build-info/<id>.output.json
#   KeyError: 'output'
#
# forge writes exactly such an output-less stub — `{id, language, source_id_to_path}` —
# on every ordinary `forge build` / `forge test`, because the full solc output is only
# emitted under `--build-info`. crytic-compile normally survives this by running
# `forge clean` before its own `forge build --build-info`, but that leaves a ~40 s
# window: any second forge process that writes a stub during it (a parallel CI step, a
# watcher, an IDE integration, another terminal) kills the campaign with a bare Python
# traceback and no indication that the cause was a concurrent build.
#
# This script removes the failure mode instead of narrowing the window:
#
#   1. Build under the `fuzz` profile, whose artifact and cache directories are separate
#      from the default profile's. A concurrent default-profile forge run cannot write
#      into the directory the fuzzers read.
#   2. Prune any build-info entry that has neither an inline `output` nor a sibling
#      `.output.json`, so a forge version that emits stubs even under `--build-info`
#      cannot break the run either.
#   3. Run the fuzzer with compilation skipped (`--foundry-ignore-compile`, set in
#      medusa.json / echidna.yaml), so nothing recompiles and no new stub can appear.
#
# Step 3 is why the committed fuzzer configs cannot be driven by a bare `medusa fuzz`:
# they deliberately do not build. Always go through this script.
#
# One crytic-compile quirk makes steps 1 and 3 interact. In
# crytic_compile/platform/foundry.py, `forge config --json` is only consulted on the
# compiling path; under `--foundry-ignore-compile` the config is never loaded and the
# artifact directory falls back to the literal `"out"`, ignoring FOUNDRY_PROFILE. The
# fuzzer configs therefore also pass `--foundry-out-directory out-fuzz`, which must stay
# in sync with `out` in `[profile.fuzz]`. This script asserts the two agree.

set -euo pipefail

usage() {
  echo "usage: script/fuzz.sh {medusa|echidna} [extra fuzzer args...]" >&2
  exit 64
}

[[ $# -ge 1 ]] || usage
FUZZER="$1"
shift

case "$FUZZER" in
medusa | echidna) ;;
*) usage ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for bin in forge jq "$FUZZER"; do
  command -v "$bin" >/dev/null || {
    echo "fuzz.sh: '$bin' not found in PATH" >&2
    exit 127
  }
done

export FOUNDRY_PROFILE=fuzz
OUT_DIR="$(forge config --json | jq -r '.out')"

if [[ "$OUT_DIR" == "out" || -z "$OUT_DIR" || "$OUT_DIR" == "null" ]]; then
  echo "fuzz.sh: the 'fuzz' profile must define its own 'out' directory (got '${OUT_DIR}')." >&2
  echo "         Restore [profile.fuzz] in foundry.toml; see the comment there." >&2
  exit 78
fi

# Catch drift between [profile.fuzz].out and the --foundry-out-directory the fuzzer
# config hands crytic-compile. They are two independent files; a mismatch surfaces as
# 'Compilation failed. Can you run build command?' with no mention of either path.
case "$FUZZER" in
medusa) CFG_FILE="medusa.json" CFG_OUT="$(jq -r '
    .compilation.platformConfig.args as $a
    | ($a | index("--foundry-out-directory")) as $i
    | if $i == null then "" else $a[$i + 1] end' medusa.json)" ;;
echidna) CFG_FILE="echidna.yaml" CFG_OUT="$(sed -n 's/^cryticArgs:.*"--foundry-out-directory","\([^"]*\)".*/\1/p' echidna.yaml)" ;;
esac

if [[ "$CFG_OUT" != "$OUT_DIR" ]]; then
  echo "fuzz.sh: ${CFG_FILE} points crytic-compile at '${CFG_OUT:-<unset>}' but [profile.fuzz] builds into '${OUT_DIR}'." >&2
  echo "         Make the two agree; see the comment block at the top of this script." >&2
  exit 78
fi

echo "==> building fuzz artifacts (profile=fuzz, out=${OUT_DIR})"
forge clean
forge build --build-info

BUILD_INFO="${OUT_DIR}/build-info"
[[ -d "$BUILD_INFO" ]] || {
  echo "fuzz.sh: ${BUILD_INFO} was not produced by 'forge build --build-info'." >&2
  exit 70
}

echo "==> pruning build-info entries with no solc output"
pruned=0
kept=0
for f in "$BUILD_INFO"/*.json; do
  [[ -e "$f" ]] || continue
  case "$f" in *.output.json) continue ;; esac
  if jq -e 'has("output")' "$f" >/dev/null 2>&1 || [[ -f "${f%.json}.output.json" ]]; then
    kept=$((kept + 1))
  else
    rm -f "$f"
    pruned=$((pruned + 1))
  fi
done
echo "    kept ${kept}, pruned ${pruned}"

if [[ "$kept" -eq 0 ]]; then
  echo "fuzz.sh: every build-info entry lacked solc output — nothing for crytic-compile to read." >&2
  exit 70
fi

echo "==> running ${FUZZER}"
case "$FUZZER" in
medusa) exec medusa fuzz "$@" ;;
echidna) exec echidna . --contract CryticTester --config echidna.yaml "$@" ;;
esac
