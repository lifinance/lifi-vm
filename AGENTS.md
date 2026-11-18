# lifi-vm

Public release of the LI.FI Virtual Machine: a Solidity contract that runs a program of packed 32-byte commands against a caller-supplied register file, plus the per-user `MinimalProxy` and the `ProxyFactory` that deploys it. Foundry project (solc 0.8.30, `via_ir`, see `foundry.toml`). [README.md](README.md) is the full reference; this file is the map.

## Layout

| Path | What lives there |
|---|---|
| `src/` | `VirtualMachine.sol`, `BlueprintEncoder.sol`, `InvariantChecker.sol`, `RPNArithmetic.sol` and the opcode libraries. `src/proxy/` holds `ProxyFactory`, `MinimalProxy` and their helpers. |
| `test/` | Foundry unit, integration and gas tests; helpers in `test/lib/`. |
| `test/halmos/` | Halmos `check_*` properties ([catalogue](test/halmos/README.md)). |
| `test/recon/` | Chimera invariant suite for Medusa and Echidna ([README](test/recon/README.md)). |
| `script/` | Forge deploy scripts (`DeployAll.s.sol` and per-contract scripts), `fuzz.sh`, `get-lifi-addresses.sh`. |
| `deployments/` | Deployment manifests pinning commit, deployer, addresses and codehashes (`v1.1.json`). |
| `docs/` | [ISA specification](docs/isa.md) and [ABI memory layouts](docs/abi_memory_layouts.md). |
| `audits/` | Published audit reports. |
| `snapshots/` | Gas snapshots written by `test/GasBenchmarks.t.sol`. |
| `chains.json` | Chain registry for `deploy-chains.sh`. |

## Commands

```bash
git submodule update --init --recursive   # once, fetches lib/
forge build
forge test                                # unit, integration, gas, and the recon Foundry reproducers
forge test --match-path test/Explode.t.sol
forge fmt --check                         # CI runs this; it skips script/ (see [fmt] ignore in foundry.toml)
halmos --contract ExplodeHalmosTest --config halmos.toml   # the CI Halmos job
script/fuzz.sh medusa --test-limit 100000 # or: script/fuzz.sh echidna
```

CI (`.github/workflows/ci-solidity.yml`) runs `forge fmt --check`, `forge test -vvvv`, `forge build` with Foundry `v1.7.1`, and the Halmos job with Halmos `0.3.3`.

## Conventions that are not obvious from the code

- Use Foundry `v1.7.1` for Halmos work: Halmos `0.3.3` cannot run artifacts built by Foundry `1.8.1`.
- `forge test` does not run the Halmos `check_*` properties; run `halmos` for them.
- Run the fuzzers only through `script/fuzz.sh`. It builds the separate `fuzz` profile into `out-fuzz/`; `medusa.json` and `echidna.yaml` skip compilation.
- A changed contract needs a new CREATE3 salt in `script/DeployAll.s.sol`. A new VM also needs a new factory salt, because the factory and every proxy store the VM address as an immutable. [DEPLOYMENTS.md](DEPLOYMENTS.md) records the salt history.
- Deploy with `deploy-chains.sh` and a manifest; it refuses to run when `src/`, `script/`, `lib/`, `foundry.toml` or `remappings.txt` differ from the manifest's commit. Simulate single-chain deploys with `./deploy.sh --simulate --sender <address> --rpc-url <rpc-url>` first.
- `lefthook.yml` defines an optional pre-commit hook (`lefthook install`) that runs `forge fmt` over the whole tree. It does not re-stage the files it formats, so stage them yourself before committing.
- Report vulnerabilities privately as [SECURITY.md](SECURITY.md) describes, never in issues or pull requests.

## Config and environment

[.env.example](.env.example) lists the environment variables the deploy scripts and Forge scripts read, except private keys, which never go in a file. Forge loads `.env` itself, but `deploy.sh`, `deploy-chains.sh` and `generate-proxy.sh` do not: export it first with `set -a; source .env; set +a`. `generate-proxy.sh` takes the user and factory only from `--user` and `--factory`; `USER_ADDRESS` and `PROXY_FACTORY_ADDRESS` apply only when running `script/GenerateProxyAddress.s.sol` directly. `deploy-chains.sh` also reads `ETH_PASSWORD`, a path to the keystore password file; set it in the shell for one run, not in `.env`, because forge loads `.env` on every run and would then unlock the keystore for any command that uses `--account`. `deploy-chains.sh` signs with a Foundry keystore (`cast wallet import`). `deploy.sh` and `generate-proxy.sh` accept only `--private-key`, which reaches forge as a process argument: read it from an environment variable rather than typing it, and use `deploy-chains.sh` wherever it covers the deployment. Compiler and test profiles live in `foundry.toml`, Halmos settings in `halmos.toml`, fuzzer settings in `medusa.json` and `echidna.yaml`.

## Deeper docs

- [README.md](README.md): execution model, registers, instruction set, limitations, deployment, error reference, audits.
- [docs/isa.md](docs/isa.md): instruction set specification.
- [DEPLOYMENTS.md](DEPLOYMENTS.md): deployed addresses per chain and how to check a deployment.
- `.claude/skills/`: project skills for Claude Code. `.agents/skills/` holds Codex copies of `check-proxy-deployments`, `exec-plan` and `refine-plan` only.

## Ownership

Composer squad, reviewer Rory (`@rory660`). Review requests: request the reviewer above on the PR.
