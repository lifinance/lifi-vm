---
name: check-proxy-deployments
description: Check whether a ProxyFactory proxy is deployed for a given user address on every chain listed in DEPLOYMENTS.md. Use when the user asks "is the proxy deployed for <address>", "check proxy on all chains", "audit proxy coverage", or wants a per-chain deployment status table. Triggers on: check proxy, proxy status, proxy coverage, deployed proxy, all chains.
user_invocable: true
---

# /check-proxy-deployments — Per-Chain Proxy Deployment Audit

Verifies that a deterministic proxy (predicted via `ProxyFactory.predictProxyAddress`) is deployed for a given user address on every chain in `DEPLOYMENTS.md`.

## When to use

- User asks whether a proxy exists for `<address>` across all chains.
- After running `generate-proxy.sh` on multiple chains and you need to confirm coverage.
- Auditing which chains still need a proxy deploy for a known user (e.g. LiFiDiamond, executor, an EOA).

## How it works

1. Reads the `ProxyFactory` address from the first line of `DEPLOYMENTS.md` matching `ProxyFactory`.
2. Parses the chain table from `DEPLOYMENTS.md` (rows shaped like `| <id> | <name> | …`).
3. For each chain, in parallel:
   - `cast call <factory> 'predictProxyAddress(address)(address)' <user> --rpc-url <rpc>`
   - `cast code <predicted> --rpc-url <rpc>` → non-`0x` means deployed.
4. Prints a sorted table (`CHAIN_ID | NAME | PREDICTED_ADDRESS | STATUS | NOTE`) and a summary.

`STATUS` values: `DEPLOYED`, `MISSING`, `ERR` (RPC/call failure), `SKIP` (no RPC configured).
Exit code `2` if any chain is `MISSING` or `ERR`; `0` if all `DEPLOYED` (skipped chains do not fail).

## Usage

```bash
.Codex/skills/check-proxy-deployments/check.sh <user-address>
```

Examples:

```bash
# Check coverage for the LiFiDiamond
.Codex/skills/check-proxy-deployments/check.sh 0x1231deb6f5749ef6ce6943a275a1d3e7486f4eae

# Override the factory address (e.g. testing a re-deploy)
FACTORY=0xabc... .Codex/skills/check-proxy-deployments/check.sh 0x1231...

# Override an RPC for a specific chain (env name: RPC_<chainId>)
RPC_999=https://my-private-hyperevm-rpc \
RPC_4326=https://my-megaeth-rpc \
  .Codex/skills/check-proxy-deployments/check.sh 0x1231...

# Tune parallelism (default 8)
PARALLEL=4 .Codex/skills/check-proxy-deployments/check.sh 0x1231...
```

## Configuration

Default public RPCs are baked into `check.sh` for most chains in `DEPLOYMENTS.md`. A chain without a default RPC reports `SKIP` until you set `RPC_<chainId>`, for example `RPC_4326` (MegaETH) or `RPC_98866` (Plume).

If a default public RPC is rate-limited or down, override it via `RPC_<chainId>=<url>`.

## Follow-up actions

- For each `MISSING` chain, run:
  ```bash
  ./generate-proxy.sh \
    --user <user> \
    --factory <factory-from-DEPLOYMENTS.md> \
    --private-key "$PRIVATE_KEY" \
    --rpc-url <chain-rpc>
  ```
  `generate-proxy.sh` is idempotent (it skips chains where the predicted address already has bytecode), so re-running it for a `DEPLOYED` chain is a no-op.

## Dependencies

- `cast` (foundry)
- `awk`, `xargs`, `column`, `sort`, `grep` (standard POSIX/coreutils)
- `git` (used to locate the repo root; falls back to `$PWD`)

## Anti-patterns

- **Don't** edit `check.sh` to hard-code a user address — pass it as an argument so the skill stays general.
- **Don't** add chains by hand; the script derives the list from `DEPLOYMENTS.md`. Update that file (the source of truth) and the skill picks them up automatically.
- **Don't** treat `SKIP` as a deployment problem — it's a missing RPC config. Set `RPC_<chainId>` and re-run.
