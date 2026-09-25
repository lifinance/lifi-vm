# LI.FI Virtual Machine

The LI.FI Virtual Machine is a Solidity contract that executes a program of packed 32-byte commands against a caller-supplied register file. A program can build ABI calldata from registers, call other contracts, split and patch their return data, pull approved ERC-20 tokens, transfer tokens, and emit logs, all in one transaction. Each user runs programs through a personal proxy that delegatecalls the VM, so the program acts as the user's own contract account.

This repository contains the contracts, their Foundry test, fuzzing and Halmos suites, the deployment scripts, and a few operator tools.

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Deployment](#deployment)
- [Tools](#tools)
- [Error reference](#error-reference)
- [Audits](#audits)
- [Security](#security)
- [License](#license)

## How it works

### Contracts

| Contract | Source | Role |
|---|---|---|
| `VirtualMachine` | `src/VirtualMachine.sol` | Executes command programs. Entry points `runVM` and `runWithState`. |
| `BlueprintEncoder` | `src/BlueprintEncoder.sol` | Library that encodes ABI data from registers. Linked into the VM and deployed alongside it. |
| `ProxyFactory` | `src/proxy/ProxyFactory.sol` | Deploys one `MinimalProxy` per user at a deterministic CREATE3 address. |
| `MinimalProxy` | `src/proxy/MinimalProxy.sol` | Per-user proxy. Authenticates the caller and delegatecalls the VM. |
| `InvariantChecker` | `src/InvariantChecker.sol` | Standalone assertion contract that programs call to check values. |
| `ArithmeticProcessor` | `src/RPNArithmetic.sol` | Standalone contract that evaluates Reverse Polish Notation (RPN) arithmetic. |

Internal libraries in `src/` implement the opcodes: `CommandPacking.sol` decodes command words, `RegisterFile.sol` and `RegisterHelpers.sol` access registers, and `Explode.sol`, `SurgeryOPS.sol`, `DepositApproved.sol`, `SafeTransferLib.sol`, `VMLogLib.sol` and `MemoryUtils.sol` implement individual commands. `DataModel.sol` defines the command structs, `VmConstants.sol` the shared limits, `VmErrors.sol` the shared errors, and `StorageSlots.sol` the proxy owner slot.

### Execution model

```solidity
function runVM(VMCommand[] calldata commands, VMState memory initialState)
    public payable returns (bytes memory);

function runWithState(VMCommand[] calldata commands, VMState memory initialState)
    public payable returns (VMState memory, bytes memory);

struct VMCommand { OP op; bytes32 data; }
struct VMState   { bytes[] registers; }
```

The VM executes `commands` in order. Each command is an opcode plus one 32-byte word whose layout depends on the opcode. Execution stops at the first `RETURN`, which returns the contents of a register, or after the last command, which returns empty bytes. `runWithState` also returns the final register file, which helps with debugging and tests.

Every failure reverts the whole transaction. When an external call fails, the VM re-raises the callee's revert data unchanged.

### Calling context and proxies

`VirtualMachine` has no access control and keeps no state of its own. What protects a user is the context the VM runs in:

- **Per-user proxy.** `MinimalProxy` stores its `owner`, `vmAddress` and `factory` as immutables. Its fallback accepts calls only from the owner or the factory (otherwise `Unauthorized()`) and forwards the calldata unchanged to the VM with `delegatecall`. The VM code therefore runs in the proxy's context: the proxy holds tokens and ETH, and it is `msg.sender` for every external call the program makes.
- **One-time factory call.** The factory may call a proxy only once. `ProxyFactory.deployAndExecute(bytes)` deploys the caller's proxy and runs an initial program through it in the same transaction. A second call from the factory reverts with `AlreadyInitialized()`.
- **Reentrancy guard.** The proxy sets a guard before it forwards a call and clears it afterwards. A nested call into the proxy while a program runs reverts with `ReentrantCall(address)`. The guard uses transient storage when the chain supports `TSTORE` and falls back to regular storage otherwise (`src/proxy/TStorish.sol`).
- **No delegatecall from programs.** The `CALL` opcode rejects the `DELEGATECALL` call type with `Disallowed()`, so a program cannot run foreign code in the proxy's storage context. The VM has no opcode that writes storage.
- **Deposits come from the owner.** The proxy writes its owner to a fixed storage slot (`StorageSlots.OWNER_SLOT`) at construction. `DEPOSIT_APPROVED` reads that slot and pulls tokens from the owner into the proxy.
- **ETH.** The proxy's `receive()` accepts plain ETH transfers from anyone, so called contracts can send ETH back to it.
- **Direct calls.** Calling `runVM` on the `VirtualMachine` address directly runs the program in the VM's own context. `DEPOSIT_APPROVED` then pulls from `msg.sender`, because the owner slot is empty. Any token or ETH balance left on the VM contract is available to every caller, so do not leave funds there.
- **No upgrades.** The factory and every proxy store the VM address in immutables, and the proxy owner cannot change. Moving to a new VM requires a new factory and new proxies (see [Versioned redeploys](#versioned-redeploys)).

`ProxyFactory` deploys proxies through the CreateX CREATE3 factory. The proxy salt depends only on the factory address and the user address, so a factory at the same address on several chains gives a user the same proxy address on each of them. `predictProxyAddress(user)` returns that address. Anyone can call `deployProxy(user)` to deploy a proxy for any user; only that user can operate it.

### Registers

The caller passes the register file in `initialState.registers`, so the caller decides how many registers a program has.

| Aspect | Rule |
|---|---|
| Register operand | One byte. The low 7 bits are the index (`0x00`–`0x7F`); the high bit (`0x80`) is the dynamic flag. |
| Valid index | Below `registers.length`, otherwise `RegisterIndexOOB()`. |
| Void register | Index `0x7A` (122) always reads as 32 zero bytes, and writes to it are discarded. |
| Static value | Exactly 32 bytes, for example `abi.encode(uint256)` or `abi.encode(address)`. |
| Dynamic value | A length-prefixed ABI blob, `length ‖ data ‖ padding`, at least 32 bytes long. |
| Dynamic flag | Meaningful for the `CALL` destination, `EXPLODE` destinations, and blueprint register tokens. The `EXPLODE` source must have it clear. Other operands use only the index. |

Commands that read a word or an address from a register (call value, deposit cap, transfer amount, static `LOG` operands, balance address, transfer recipient) require that register to hold exactly 32 bytes.

`EXPLODE` copies dynamic fields out of its source without re-validating them, so a register filled from untrusted return data may hold non-canonical ABI. Decode such a register before you hash, sign or byte-compare it. [docs/isa.md](docs/isa.md) describes the canonicality rules.

### Instruction set

[docs/isa.md](docs/isa.md) specifies the byte layout of every command word, the padding rules, and the edge cases. [docs/abi_memory_layouts.md](docs/abi_memory_layouts.md) describes the ABI memory layouts that the encoder and the VM produce and consume.

| OP | Name | Effect |
|---:|---|---|
| 0 | `CALL` | Calls a target with the calldata held in a register. Call types: `CALL` (1), `STATICCALL` (2), `VALUECALL` (3, value taken from a static register). `DELEGATECALL` (0) reverts. The return data goes to the destination register: verbatim when the dynamic flag is clear, or as a length-prefixed blob when it is set, which requires the return value to be a single dynamic value such as `bytes` or `string`. |
| 1 | `CALLDATA_BUILD` | Encodes a 4-byte selector and a blueprint of up to 22 bytes into length-prefixed calldata. |
| 2 | `EXPLODE` | Splits the ABI-encoded tuple in one register into 1–26 destination registers. |
| 3 | `DEPOSIT_APPROVED` | Transfers `min(allowance, owner balance, cap)` of an ERC-20 from the owner to the current contract and stores the amount actually received, so fee-on-transfer tokens report the net amount. |
| 4 | `CALLDATA_SURGERY` | Overwrites up to 6 byte windows of a register in place. Each replacement is right-aligned in its window and zero-padded on the left. |
| 5 | `RETURN` | Stops execution and returns the contents of a register. |
| 6 | `ABI_ENCODE` | Encodes a blueprint of up to 27 bytes without a selector. |
| 7 | `REMAINING_GAS` | Stores `gasleft()` as a 32-byte word. |
| 8 | `NATIVE_BALANCE` | Stores the native balance of the address held in a register. |
| 9 | `LOG` | Emits `VMLogStatic1` to `VMLogStatic5` with one to five 32-byte registers, or `VMLogDyn` with the raw bytes of one register. |
| 10 | `SAFE_TRANSFER` | Transfers an ERC-20 from the current contract to the address in one register, for the amount in another, using Solady's `SafeTransferLib`. |

### Blueprint encoder

`CALLDATA_BUILD` and `ABI_ENCODE` describe their output with a blueprint: a byte string in which each byte is either a register reference or a container token.

| Token | Meaning |
|---|---|
| `0x00`–`0x7A` | Static register. Copied as one 32-byte head word. |
| `0x80`–`0xFF` | Dynamic register `token & 0x7F`. A pointer goes in the head and the blob goes in the tail. |
| `0x7F` | Open a static tuple: encoded inline, no pointer. |
| `0x7E` | Open a dynamic tuple: pointer in the parent head, contents in the tail. |
| `0x7D` | Open a static array: encoded inline, no length word. |
| `0x7C` | Open a dynamic array: pointer in the parent head, length word followed by the elements in the tail. |
| `0x7B` | Close the innermost container. |

A blueprint without containers takes a single-pass fast path. Nested blueprints use a measure pass and then an encode pass that writes into one exact-size buffer. The output always starts with a 32-byte length word, so it can go straight into a register used as `CALL` calldata or as a dynamic blueprint input. The header comment of `src/BlueprintEncoder.sol` contains worked examples and a container encoding reference.

This example encodes `transfer(address,uint256)` from static registers 0 and 1:

```solidity
bytes memory blueprint = hex"0001"; // static register 0 (to), static register 1 (amount)
bytes memory data = BlueprintEncoder.encodeFromBlueprint(
    bytes4(keccak256("transfer(address,uint256)")), blueprint, registers
);
```

### RPN arithmetic

`ArithmeticProcessor` is a separate contract, not a VM opcode. A program calls it like any other contract, for example with `STATICCALL`.

```solidity
function evaluateRPN(uint256[] calldata regValues, bytes32 rpnStream, uint8 rpnLen)
    external pure returns (uint256 result);
```

The processor reads `rpnLen` bytes (at most 32) from `rpnStream`, starting at the most significant byte. A byte with the high bit set pushes `regValues[byte & 0x7F]`. Any other byte is an operator that pops `a` and `b` (where `b` was pushed last) and pushes the result. The expression must leave exactly one value on the stack.

| Byte | Operator | Result |
|---:|---|---|
| `0x00` | `ADD` | `a + b` |
| `0x01` | `SUB` | `a - b` |
| `0x02` | `MUL` | `a * b` |
| `0x03` | `DIV_DOWN` | `a / b`, rounded down |
| `0x04` | `DIV_UP` | `a / b`, rounded up: `a / b + (a % b > 0 ? 1 : 0)` |
| `0x05` | `MIN` | the smaller of `a` and `b` |
| `0x06` | `MAX` | the larger of `a` and `b` |

Arithmetic is checked: overflow and underflow revert with a Solidity panic, and both divisions revert with `DivByZero()` when `b` is 0.

```text
(v[0] + v[1]) * v[2] / v[3], rounded down
stream: 0x80 0x81 0x00 0x82 0x02 0x83 0x03   rpnLen: 7
```

### Invariant checker

`InvariantChecker` is a stateless assertion contract. A program calls it to revert the whole transaction when a value is out of bounds, for example a minimum output amount after a swap. It exposes `assertEqual`, `assertNotEqual`, `assertLessThan`, `assertGreaterThan`, `assertLessThanEqual`, `assertGreaterThanEqual` and `assertInRange`. It also exposes two batch forms: `batchAssert(uint8[] ops, uint256[] values)` and `batchAssertPacked(uint256 packedOps, uint8 opCount, uint256[] values)`, which accepts up to 32 operations. Batch operation codes are `0` no-op, `1` eq, `2` neq, `3` lt, `4` gt, `5` lte, `6` gte and `7` range (value, min, max).

### Limitations

- A blueprint cannot reference a multi-word static tuple or static array stored in a single register, because static tokens require exactly 32 bytes. Split the value with `EXPLODE` and rebuild it with container tokens.
- `START_ARRAY_STATIC` always encodes inline, even when its elements are dynamic, and the result then differs from `abi.encode`. For a fixed-size array of a dynamic type, such as `bytes[2]`, use `START_TUPLE_DYNAMIC`.
- Static register tokens cover indices `0x00`–`0x7A`. Registers 123–127 can appear in a blueprint only as dynamic registers.
- Blueprints are limited to 22 bytes (`CALLDATA_BUILD`) or 27 bytes (`ABI_ENCODE`), at most 12 nesting levels including the root, and at most 10 dynamic containers.
- A `CALL` with a dynamic destination accepts only a return value that is a single dynamic value. To store a tuple return, clear the flag and split the result with `EXPLODE`.

## Repository layout

| Path | Contents |
|---|---|
| `src/` | Contracts and libraries. `src/proxy/` holds the factory, the proxy, and their helpers. |
| `test/` | Foundry unit, integration and gas tests. `test/lib/` holds the test helpers (`Bp`, `VmCmd`, `Regs`, …). |
| `test/halmos/` | Halmos symbolic properties (`check_*`), with a [property catalogue](test/halmos/README.md). |
| `test/recon/` | Chimera invariant suite for Medusa and Echidna, with a [README](test/recon/README.md). |
| `script/` | Forge deployment scripts, `fuzz.sh`, and `get-lifi-addresses.sh`. |
| `deployments/` | Deployment manifests with pinned addresses and codehashes (`v1.1.json`). |
| `chains.json` | Chain registry used by `deploy-chains.sh`. |
| `docs/` | [ISA specification](docs/isa.md) and [ABI memory layouts](docs/abi_memory_layouts.md). |
| `audits/` | Published audit reports. |
| `snapshots/` | Gas snapshots written by `test/GasBenchmarks.t.sol`. |
| `deploy.sh`, `deploy-chains.sh`, `generate-proxy.sh`, `verify.sh`, `setup-tempo-foundry.sh` | Deployment and verification scripts. |
| `.claude/`, `.agents/` | Claude Code and Codex configuration and skills. |

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation). CI pins Foundry `v1.7.1`.
- `git`, to fetch the submodules under `lib/`.
- `jq`, for `script/fuzz.sh` and `deploy-chains.sh`.
- Optional: [Halmos](https://github.com/a16z/halmos) (CI uses `0.3.3` with Python 3.12), [Medusa](https://github.com/crytic/medusa) or [Echidna](https://github.com/crytic/echidna).

### Clone and build

```shell
git clone --recurse-submodules https://github.com/lifinance/lifi-vm.git
cd lifi-vm
forge build
```

In an existing clone without submodules, run `git submodule update --init --recursive`.

The compiler settings are in `foundry.toml`: solc `0.8.30`, `via_ir = true`, optimizer with 10,000 runs.

### Test

```shell
forge test                                  # unit, integration and gas tests
forge test --match-path test/Explode.t.sol  # a single file
forge fmt --check                           # formatting, as enforced in CI
```

`test/GasBenchmarks.t.sol` writes its gas figures to `snapshots/vmBenchmarks.json`. `lefthook.yml` defines an optional pre-commit hook that runs `forge fmt`.

### Formal verification (Halmos)

The Halmos properties are `check_*` functions, which `forge test` does not run.

```shell
halmos --config halmos.toml                                  # every property
halmos --contract ExplodeHalmosTest --config halmos.toml      # one contract, as in CI
```

Halmos `0.3.3` cannot execute artifacts built by Foundry `1.8.1`. Use Foundry `v1.7.1`, as CI does.

### Fuzzing (Medusa and Echidna)

Always run the Chimera suite through `script/fuzz.sh`. The fuzzer configs (`medusa.json`, `echidna.yaml`) skip compilation. The script builds artifacts under the separate `fuzz` Foundry profile (`out-fuzz/`) and removes build-info files that would crash crytic-compile.

```shell
script/fuzz.sh medusa                       # unbounded campaign
script/fuzz.sh medusa --test-limit 100000   # bounded campaign
script/fuzz.sh echidna
```

`test/recon/CryticToFoundry.sol` contains Foundry reproducers for the invariant properties, and they run under `forge test`.

### Continuous integration

`.github/workflows/ci-solidity.yml` runs on pushes to `main` and on pull requests:

- `test-vm`: `forge fmt --check`, `forge test -vvvv` and `forge build` with Foundry `v1.7.1`.
- `halmos-explode`: `halmos --contract ExplodeHalmosTest --config halmos.toml` with Halmos `0.3.3`.

## Deployment

[DEPLOYMENTS.md](DEPLOYMENTS.md) lists the deployed addresses per chain, the salt history, and how to check a deployment against its expected bytecode.

`script/DeployAll.s.sol` deploys `VirtualMachine`, `ProxyFactory`, `InvariantChecker` and `ArithmeticProcessor` through CreateX CREATE3 with fixed salts. Forge also deploys the `BlueprintEncoder` library that the VM links. A CREATE3 address depends only on the deployer and the salt, so the same deployer gets the same contract addresses on every chain. Forge deploys the library outside CreateX, so the library address, and therefore the VM bytecode, can differ between chains.

### Multi-chain deployment (recommended)

`deploy-chains.sh` deploys the set described by a manifest (default `deployments/v1.1.json`) to the chains in `chains.json`. It signs with a Foundry keystore, so the private key never appears in a process argument list.

```shell
cast wallet import deployer --interactive                     # once
DEPLOYER_ACCOUNT=deployer ./deploy-chains.sh                  # every chain in chains.json
DEPLOYER_ACCOUNT=deployer ./deploy-chains.sh sepolia arc-testnet
```

The script runs these steps in order:

1. It checks that the keystore holds the manifest's `deployer`, that the submodules are initialised, and that `src/`, `script/`, `lib/`, `foundry.toml` and `remappings.txt` match the manifest's `commit` with no uncommitted changes.
2. It deploys the set to a throwaway local anvil and compares every runtime codehash, the library's included, with the manifest. On a mismatch it stops before sending anything.
3. For each chain, it checks the chain ID, simulates the deployment, and broadcasts only if the simulation prints the manifest addresses.
4. It verifies the source on the chain's explorer and compares every on-chain codehash with the reference build. It also checks that `ProxyFactory.vmContract()` returns the manifest's VM.

Re-runs are idempotent: contracts that are already deployed are adopted, and no transactions are sent for them.

| Variable | Purpose |
|---|---|
| `DEPLOYER_ACCOUNT` | Foundry keystore account of the manifest deployer. Required unless `UNLOCKED=1`. |
| `ETH_PASSWORD` | Path to a keystore password file. Without it, the script prompts once at start and once per chain broadcast. |
| `ETHERSCAN_API_KEY` | Etherscan V2 key. Required when a selected chain uses the `etherscan` verifier. |
| `MANIFEST` | Manifest to deploy (default `deployments/v1.1.json`). |
| `CHAINS_FILE` | Chain registry (default `chains.json`). |
| `RPC_<NAME>` | RPC override per chain, for example `RPC_SEPOLIA` or `RPC_ARC_TESTNET`. |
| `NO_VERIFY=1` | Skip explorer verification. |
| `UNLOCKED=1` | Rehearse against an anvil fork started with `--auto-impersonate`, sending as the deployer without a key. |

Each `chains.json` entry has `name`, `chainId` and `rpc`, a `verifier` (`etherscan`, `blockscout`, `sourcify` or `none`), a `verifierUrl` for Blockscout, and optional `extraArgs` for `forge script` (for example `["--legacy"]`). The manifest pins the source `commit`, the `deployer`, and the `name`, `address` and `codehash` of each contract and linked library.

The source check in step 1 runs `git diff <commit>`, so the manifest's `commit` must exist in your clone; otherwise the script stops before it contacts any chain. `deployments/v1.1.json` records the testnet build (see [`DEPLOYMENTS.md`](./DEPLOYMENTS.md)). To deploy a different set, write a new manifest that pins a commit from this repository and point `MANIFEST` at it.

To rehearse against a local fork:

```shell
anvil --fork-url <sepolia-rpc-url> --auto-impersonate
UNLOCKED=1 NO_VERIFY=1 RPC_SEPOLIA=http://127.0.0.1:8545 ./deploy-chains.sh sepolia
```

### Single-chain deployment

`deploy.sh` wraps `script/DeployAll.s.sol` for one RPC endpoint. Simulate first. A simulation needs no key, because the addresses depend only on the deployer address:

```shell
./deploy.sh --simulate --sender <deployer-address> --rpc-url <rpc-url>
```

The simulation runs the script against the target chain without `--broadcast` and prints each address marked `ALREADY DEPLOYED` or `not deployed yet`.

To deploy for real, `deploy.sh` needs `--private-key`, which it passes to `forge` as a command-line argument. Read the key from an environment variable rather than typing it, and prefer `deploy-chains.sh` with a keystore wherever possible.

```shell
./deploy.sh --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url <rpc-url> \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

| Option | Description |
|---|---|
| `--simulate`, `--dry-run` | Simulate only. Never broadcasts. `--verify` is ignored. |
| `--private-key <key>` | Deployer key. Required for real deployments. Takes precedence over `--sender`. |
| `--sender <address>` | Deployer address for a simulation without a key. |
| `--rpc-url <url>` | RPC endpoint. Defaults to `$RPC_URL`, then `http://localhost:8545`. |
| `--verify` | Verify on Etherscan. Requires `--etherscan-api-key`. |
| `--etherscan-api-key <key>` | Etherscan API key. |
| `--gas-limit <value>` | Gas limit for the transactions. |
| `--legacy` | Send legacy (non-EIP-1559) transactions. |
| `--with-gas-price <wei>` | Gas price for legacy transactions, or max fee per gas for EIP-1559. |
| `--gas-estimate-multiplier <pct>` | Multiply forge's gas estimate. |
| `--tempo-fee-token <address>` | TIP-20 fee token for Tempo. Requires tempo-foundry. |
| `-v` … `-vvvvv`, `--verbose` | Forge verbosity (default `-v`). |

The environment variables `FORGE_BIN` and `CAST_BIN` select the `forge` and `cast` binaries.

#### Tempo

Tempo (chain ID 4217) has no native gas token, and its transactions must carry a fee-token annotation that only the Tempo fork of Foundry emits. `setup-tempo-foundry.sh` installs that fork into `~/.foundry-tempo` without touching your main Foundry install:

```shell
./setup-tempo-foundry.sh
FORGE_BIN="$HOME/.foundry-tempo/bin/forge" ./deploy.sh \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url <tempo-rpc-url> --tempo-fee-token <fee-token-address>
```

### Versioned redeploys

The deploy helpers adopt an existing deployment when the predicted CREATE3 address already holds code:

- `VirtualMachine`: the script adopts the existing contract only if its codehash equals the current build. Otherwise it reverts with `VM: existing VM at salt has different bytecode`.
- `ProxyFactory`: the script adopts the existing contract only if it is bound to the same VM and the same CreateX. Otherwise it reverts.
- `InvariantChecker` and `ArithmeticProcessor`: the script adopts any existing code at the address.

A changed contract therefore needs a new salt in `script/DeployAll.s.sol`. The factory and every proxy store the VM address in immutables, so a new VM also needs a new factory salt, and users need new proxies from the new factory. [DEPLOYMENTS.md](DEPLOYMENTS.md) records the salt history and its migration consequences.

### User proxies

Read a user's proxy address, and deploy the proxy with a keystore account:

```shell
cast call <factory-address> "predictProxyAddress(address)(address)" <user-address> --rpc-url <rpc-url>
cast send <factory-address> "deployProxy(address)" <user-address> --account deployer --rpc-url <rpc-url>
```

`generate-proxy.sh` runs `script/GenerateProxyAddress.s.sol`. The script deploys the proxy only if no code exists at the predicted address, and it prints the address in either case.

```shell
./generate-proxy.sh --user <user-address> --factory <factory-address> \
  --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url <rpc-url>
```

| Option | Description |
|---|---|
| `--user <address>` | Proxy owner. Required. |
| `--factory <address>` | `ProxyFactory` address. Required. |
| `--private-key <key>` | Key that pays for the deployment. Required. |
| `--rpc-url <url>` | RPC endpoint. Defaults to `$RPC_URL`, then `http://localhost:8545`. |
| `-v`, `-vv`, `-vvv` | Forge verbosity (default `-v`). |

A user can also deploy their own proxy and run a first program in one transaction with `ProxyFactory.deployAndExecute(bytes)`, passing `runVM` calldata. Any ETH sent with the call is forwarded to the proxy.

### Source verification

`deploy-chains.sh` and `deploy.sh --verify` verify during deployment. To verify an existing contract, use `verify.sh`. It calls `forge verify-contract` with the project's compiler settings (`--via-ir`, 10,000 optimizer runs).

```shell
./verify.sh --contract-address <address> --contract-name VirtualMachine \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
./verify.sh --contract-address <address> --contract-name VirtualMachine \
  --verifier sourcify --chain-id <chain-id> --rpc-url <rpc-url>
```

| Option | Description |
|---|---|
| `--contract-address <address>` | Contract to verify. Required. |
| `--contract-name <name>` | `VirtualMachine`, `ProxyFactory`, `InvariantChecker`, `ArithmeticProcessor` or `BlueprintEncoder`. Required. |
| `--verifier <name>` | `etherscan` (default) or `sourcify`. |
| `--etherscan-api-key <key>` | Required for `etherscan`. |
| `--chain-id <id>` | Required for `sourcify`. |
| `--verifier-url <url>` | Custom Sourcify endpoint. |
| `--rpc-url <url>` | Optional RPC endpoint. |
| `--constructor-args <hex>` | ABI-encoded constructor arguments. `ProxyFactory` takes `(address vmContract, address create3Factory)`. |
| `-v`, `-vv`, `-vvv` | Forge verbosity (default `-v`). |

## Tools

| Tool | Purpose |
|---|---|
| `.claude/skills/check-proxy-deployments/check.sh <user>` | Reports, for every chain in `DEPLOYMENTS.md`, whether the user's proxy is deployed. Override RPCs with `RPC_<chainId>` and the factory with `FACTORY`. |
| `script/get-lifi-addresses.sh` | Fetches the LI.FI diamond and related addresses from the public `lifinance/contracts` deployment files. |

### Claude Code and Codex

`.claude/settings.json` enables five Trail of Bits plugins from the [`trailofbits/skills`](https://github.com/trailofbits/skills) marketplace: `building-secure-contracts`, `audit-context-building`, `property-based-testing`, `mutation-testing` and `entry-point-analyzer`. Claude Code fetches them from GitHub after you approve the project settings.

`.claude/skills/` holds the project skills: `check-proxy-deployments`, `exec-plan`, `gas-optimize`, `refine-plan`, `smart-contract-audit` and `test-foundry`. `.agents/skills/` holds the Codex copies of `check-proxy-deployments`, `exec-plan` and `refine-plan`.

## Error reference

### `VmErrors` (`src/VmErrors.sol`)

| Error | Raised when |
|---|---|
| `Disallowed()` | A `CALL` uses the `DELEGATECALL` call type. |
| `InvalidCallDataLength()` | The `CALL` source register is shorter than 32 bytes. |
| `OutOfBounds()` | A `CALLDATA_SURGERY` window extends past its source. An `EXPLODE` source is shorter than its head region, or a dynamic offset is unaligned, inside the head, past the end, or not increasing. A `MemoryUtils.slice` range is out of bounds. |
| `ReplacementTooLarge()` | A surgery replacement is longer than its window. |
| `TooManySurgeries()` | A `CALLDATA_SURGERY` command specifies more than 6 surgeries. |
| `BlueprintTooLarge()` | A blueprint exceeds 22 bytes (`CALLDATA_BUILD`) or 27 bytes (`ABI_ENCODE`). |
| `InvalidRegisterLength()` | An `EXPLODE` source length is not a multiple of 32. |
| `DestinationCountOutOfBounds(uint8 count)` | An `EXPLODE` destination count is 0 or greater than 26. |
| `NonZeroPadding()` | A reserved `EXPLODE` bit is set: the source-register high bit, an unused destination byte, or bytes 28–31. |
| `InvalidLogVariant()` | A `LOG` variant is greater than 5 (`DYNAMIC`). |
| `InvalidAddressBytes()` | A register read as an address (`NATIVE_BALANCE`, `SAFE_TRANSFER` recipient) is not exactly 32 bytes. |
| `CallToNonContract()` | The `DEPOSIT_APPROVED` token has no code. |
| `GetBalanceFailed()` | `DEPOSIT_APPROVED` cannot read the current contract's token balance. |
| `Unauthorized()` | A caller other than the owner or the factory calls a proxy. |
| `AlreadyInitialized()` | The factory calls a proxy a second time. |
| `InvalidUserAddress()` | `ProxyFactory` is asked to deploy a proxy for the zero address. |
| `ProxyAlreadyDeployed()` | The user's proxy already exists. |
| `TooManyOperations()` | `InvariantChecker.batchAssertPacked` or `packOps` receives more than 32 operations. |
| `InvalidOpcode(uint8 opcode)` | The VM's fallback branch for an unknown opcode. In practice the ABI decoder rejects out-of-range `OP` values first, and the call reverts without data. |
| `SourceRegistersExceed208Bits()` | `CommandPacking.packLog` receives more than 208 bits of source registers. Encoding helper only. |
| `DestinationCountMismatch(uint8 expected, uint256 found)` | `CommandPacking.packExplode` receives fewer destination registers than its count. Encoding helper only. |

`VmErrors` also declares `InvalidCallType()`, `NoApprovedTokens()`, `TokenTransferFailed()`, `InvalidValueLength()`, `InvalidAddress()` and `InvalidTokenAddress()`, but no code raises them. An out-of-range call type fails with a Solidity enum-conversion panic (`0x21`).

### `RegisterFile` (`src/RegisterFile.sol`)

| Error | Raised when |
|---|---|
| `RegisterIndexOOB()` | A register index (other than the void register) is not below `registers.length`. |
| `InvalidStaticData()` | A register read as a word (call value, deposit cap, transfer amount, static `LOG` operand) is not exactly 32 bytes. |
| `InvalidDynamicData()` | A `CALL` with a dynamic destination receives return data that is not a single ABI-encoded dynamic value (shorter than 64 bytes, or a first word other than `0x20`). |

### `BlueprintEncoder` (`src/BlueprintEncoder.sol`)

| Error | Raised when |
|---|---|
| `StackOverflow()` | Container nesting reaches `MAX_STACK_DEPTH` (12). |
| `StackUnderflow()` | A close token (`0x7B`) has no matching open token. |
| `UnclosedContainer()` | The blueprint ends inside an open container. |
| `InvalidToken()` | A byte is neither a valid register token nor a container token. |
| `DynHeadBufOverflow()` | The blueprint opens more than 10 dynamic containers. |
| `BadStaticFormat(uint8 index)` | A static register is not exactly 32 bytes. |
| `BadDynamicFormat(uint8 index)` | A dynamic register is shorter than 32 bytes, so it has no length prefix. |
| `BufferTooSmall(uint256 required, uint256 provided)` | An internal write would exceed the output buffer. |

### `ArithmeticProcessor` (`src/RPNArithmetic.sol`)

| Error | Raised when |
|---|---|
| `TooManyOpcodes(uint8 actualLen, uint8 maxLen)` | `rpnLen` is greater than 32. |
| `RegIndexOOB(uint8 attemptedRegIndex)` | A push references an index at or beyond `regValues.length`. |
| `StackUnderflow()` | An operator finds fewer than two operands. |
| `InvalidOpcode(uint8 opcode)` | An operator byte is greater than `0x06`. |
| `DivByZero()` | `DIV_DOWN` or `DIV_UP` divides by zero. |
| `InvalidRPNStack()` | The stack does not hold exactly one value at the end, which includes an empty expression. |
| `MissingDestReg()` | `regValues` is empty. |

`EmptyExpression()` is declared but no code raises it.

### `InvariantChecker` (`src/InvariantChecker.sol`)

| Error | Raised when |
|---|---|
| `AssertEqFailed(uint256 a, uint256 b)` | `a != b` |
| `AssertNeqFailed(uint256 a, uint256 b)` | `a == b` |
| `AssertLtFailed(uint256 a, uint256 b)` | `a >= b` |
| `AssertGtFailed(uint256 a, uint256 b)` | `a <= b` |
| `AssertLteFailed(uint256 a, uint256 b)` | `a > b` |
| `AssertGteFailed(uint256 a, uint256 b)` | `a < b` |
| `AssertRangeFailed(uint256 value, uint256 min, uint256 max)` | `value < min` or `value > max` |
| `UnknownOpcode(uint8 opcode)` | A batch operation code is greater than 7. |

### Proxy (`src/proxy/`)

| Error | Raised when |
|---|---|
| `ReentrantCall(address existingCaller)` | A call reaches a proxy while it is already executing. Selector `0xf57c448b`, raised in assembly. |
| `TStoreAlreadyActivated()` | `__activateTstore()` is called when transient storage is already active. |
| `TStoreNotSupported()` | `__activateTstore()` is called on a chain without `TSTORE`. |
| `TloadTestContractDeploymentFailed()` | The proxy constructor cannot deploy its `TLOAD` probe contract. |

### Solady `SafeTransferLib`

| Error | Raised when |
|---|---|
| `TransferFromFailed()` | The `DEPOSIT_APPROVED` `transferFrom` fails. |
| `TransferFailed()` | The `SAFE_TRANSFER` `transfer` fails. |
| `ETHTransferFailed()` | `ProxyFactory.deployAndExecute` cannot forward ETH to a new proxy. |

## Audits

| Report | Reviewer | Date | Scope | Result |
|---|---|---|---|---|
| [adevar-report.pdf](audits/adevar-report.pdf) | Adevar Labs | October 10, 2025 | Core VM sources (`BlueprintEncoder`, `CommandPacking`, `DataModel`, `DepositApproved`, `InvariantChecker`, `RegisterFile`, `RegisterHelpers`, `RPNArithmetic`, `SurgeryOPS`, `VirtualMachine`, `VmConstants`, `VmErrors`, `VMLogLib`) at commit `3caed99`; fix review at `e460177`. | 3 Low, all fixed; 12 enhancement opportunities. |
| [recon-report.pdf](audits/recon-report.pdf) | Recon (Alex the Entreprenerd, Knot) | 2025 | Two weeks of invariant testing of the VirtualMachine at commit `b0458e9`. | 5 Medium, 5 QA. |
| [somraaj-explode-report.pdf](audits/somraaj-explode-report.pdf) | Sujith Somraaj | September 20, 2026 | Differential review of the `EXPLODE` opcode at commit `f763689`: `Explode.sol`, plus the related changes in `VirtualMachine`, `CommandPacking`, `MemoryUtils`, `VmConstants`, `VmErrors` and `DataModel`. | 2 Low, 3 Informational. Four fixed; one accepted as designed and documented. |

The auditors reviewed the code in the private repository `lifinance/Yggdrasil-VirtualMachine`, where this code was developed. The listed commits belong to that repository's history, which this repository does not include.

## Security

Do not report vulnerabilities in public issues or pull requests. Follow [SECURITY.md](SECURITY.md) and report privately to security@li.fi.

## License

The repository is licensed under the GNU Lesser General Public License v3.0; see [LICENSE](LICENSE). The LGPL-3.0 supplements the GNU General Public License v3.0, whose text is in [LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt). Core sources carry `SPDX-License-Identifier: LGPL-3.0-only`.

Some files keep a different license. Each file's SPDX header is authoritative.

| Files | License | Text |
|---|---|---|
| `src/proxy/TStorish.sol`, `src/proxy/EfficiencyLib.sol`, `src/proxy/Types.sol` (adapted from Uniswap's [The Compact](https://github.com/Uniswap/the-compact)) | MIT, Copyright (c) 2025 Uniswap Labs | [LICENSES/MIT-the-compact.txt](LICENSES/MIT-the-compact.txt) |
| `test/recon/` harness files marked `GPL-2.0` (generated from the Recon template) | GPL-2.0 | [LICENSES/GPL-2.0.txt](LICENSES/GPL-2.0.txt) |
| `test/recon/mocks/StETHMock.sol` (derived from Lido) | GPL-3.0 | [LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt) |
| Other files marked `MIT` (`script/Create3Helpers.sol`, `test/RPNArithmeticSpec.t.sol`, `test/recon/mocks/MockERC4626Tester.sol`) | MIT | per file header |
