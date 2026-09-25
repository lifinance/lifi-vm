# Chimera invariant-fuzzing harness

This directory holds a stateful fuzzing harness for the LI.FI Virtual Machine. It uses the [Chimera](https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html) framework and Recon's setup helpers (`lib/setup-helpers`). The same handlers and properties run under three tools:

| Tool | Entry point | Role |
|---|---|---|
| Medusa | `CryticTester` | Long fuzzing campaigns. |
| Echidna | `CryticTester` | Long fuzzing campaigns. |
| Foundry | `CryticToFoundry` | Deterministic reproducers. Part of `forge test`, so they also run in CI. |

The fuzzers do not run in CI. Run them locally with `script/fuzz.sh`.

## Layout

The contracts form one inheritance chain: `ClampedStorage` → `Setup` → `BeforeAfter` → `Properties` → `targets/*` → `TargetFunctions` → `CryticTester` / `CryticToFoundry`.

| File | Contents |
|---|---|
| `ClampedStorage.sol` | Shared fuzzing state: the `commands` queue, a 256-register `state`, the `clampedTarget` address, and the fixed register indices handlers use (`srcReg` 0, `destReg` 1, `valueReg` 2, `calldataSRCReg` 3, `addressSrcReg` 4). Also exposes setters for those registers. |
| `Setup.sol` | `setup()` deploys the `VirtualMachine`, the `OmniTarget` call target, four token mocks plus an 18-decimal `MockERC20`, and a `MockERC4626Tester` vault. It registers actors `0x101` and `0x202`, approves the VM for each asset, and fills registers 128–255 with a sentinel value. Also defines the `asActor` and `asAdmin` modifiers and the calldata shortcuts used by the clamped handlers. |
| `BeforeAfter.sol` | Ghost state. The `updateGhosts` and `updateGhostsWithType` modifiers snapshot every register before and after a handler. `_explode` and `_explodeRaw` record the outcome of the most recent EXPLODE handler. |
| `Properties.sol` | Global properties, listed [below](#properties). |
| `targets/` | Handlers the fuzzer calls, one file per area (see the next table). |
| `TargetFunctions.sol` | Combines every `targets/` contract, and adds handlers for the fee-on-transfer and stETH mocks. |
| `CryticTester.sol` | Fuzzer entry point. Its constructor calls `setup()` and it asserts through `CryticAsserts`. |
| `CryticToFoundry.sol` | Foundry entry point. `setUp()` calls `setup()` and it asserts through `FoundryAsserts`. Holds the reproducer tests. |
| `mocks/` | `OmniTarget` (a `setValue`/`returnValue` call target), `MockUSDT` (no return value on transfer), `MockFoTToken` (configurable transfer fee), `MockReturnFalseOnFailure`, `StETHMock` (share-based balances), and `MockERC4626Tester` (a vault with adjustable yield, decimals offset and revert behavior). |

| Target file | Handlers |
|---|---|
| `ClampedTargetHandlers.sol` | Queue builders (`add*ToDictionary`, `clampedAddPackedCall*`, `shortcut_callDataSurgeryTest`, `shortcut_callDataBuildTest`, `shortCutSurgeryToDictionary`) push well-formed VM commands onto `commands`. `performClampedCall` runs the queue with `runWithState` and stores the new register state. |
| `DoomsdayTargets.sol` | Self-contained scenarios with inline assertions: `DEPOSIT_APPROVED` amounts, `CALL` return values, `REMAINING_GAS`, and `SAFE_TRANSFER` balances. The `stateless` modifier reverts after the assertions, so these handlers leave no state behind. |
| `ExplodeTargets.sol` | `explode_raw` sends an arbitrary EXPLODE word to the VM. `explode_clampedStatic`, `explode_clampedDynamic`, `explode_aliasSource` and `explode_clampedMixed` build well-formed commands on a fresh 32-register state. `addExplodeToDictionary` queues an EXPLODE for `performClampedCall`. |
| `VirtualMachineTargets.sol` | Unconstrained `runVM` and `runWithState` calls with fuzzer-supplied commands and state. |
| `ManagersTargets.sol` | Actor and asset switching, new assets, and asset `approve`/`mint`. |
| `MaliciousERC4626Targets.sol` | Direct calls into the `MockERC4626Tester` vault. |
| `OmniTargets.sol` | `omniTarget_setValue`. |
| `AdminTargets.sol` | Empty placeholder for admin handlers. |

`recon.json` in the repository root lists the `VirtualMachine` functions (`runVM`, `runWithState`) that Recon's scaffolding generated handlers for; they live in `VirtualMachineTargets.sol`.

## Properties

Both fuzzers run in assertion mode. Every public function on `CryticTester` is a callable target, including the property functions below. Any failing Chimera assertion (`t`, `eq`, `lte`, ...) marks the call sequence as a counterexample.

| Property | Invariant |
|---|---|
| `invariant_registries` | Registers 128–255 still hold the sentinel written in `setup()`. Indices at or above 128 carry the dynamic flag, not a register index, so the VM must never write there. |
| `property_untouched_registries` | After `performClampedCall`, every register that no queued command writes is byte-identical to its pre-call value. Written registers are each command's destination, plus the source and replacement registers of `CALLDATA_SURGERY`. |
| `property_explode_no_revert_on_valid` | A well-formed clamped EXPLODE never reverts. |
| `property_explode_static_conservation` | All-static EXPLODE: the destinations, concatenated in order, equal the source head. |
| `property_explode_dynamic_tail_partition` | All-dynamic EXPLODE: the destination tails, concatenated in order, equal the source from the end of the head to the end, with no gaps or overlaps. |
| `property_explode_non_interference` | EXPLODE leaves every non-destination register unchanged. |
| `property_explode_alias_safety` | A destination that aliases the source register receives data derived from the source as it was before the command. |
| `property_explode_mixed_partition` | Interleaved static and dynamic destinations reproduce the source. A static destination never cuts short the preceding dynamic tail. |
| `property_explode_raw_revert_taxonomy` | When `explode_raw` reverts, the error is one of `DestinationCountOutOfBounds`, `NonZeroPadding`, `OutOfBounds`, `InvalidRegisterLength` or `RegisterIndexOOB`: never a `Panic`, never empty revert data. |

The `doomsday_*` handlers in `DoomsdayTargets.sol` also carry inline assertions. For example, `DEPOSIT_APPROVED` must never return more than the `maxDeposit` register allows.

## Running the fuzzers

### Requirements

- `forge` and `jq` on `PATH`.
- `medusa` or `echidna` on `PATH`.
- [`crytic-compile`](https://github.com/crytic/crytic-compile), which both fuzzers use to read the Foundry artifacts.
- Initialized submodules (`forge install`).

### Commands

Always start a campaign through `script/fuzz.sh`. Any arguments after the fuzzer name go straight to the fuzzer.

```shell
script/fuzz.sh medusa                          # unbounded campaign; stop with Ctrl-C
script/fuzz.sh medusa --test-limit 100000      # stop after 100,000 calls
script/fuzz.sh echidna
script/fuzz.sh echidna --test-limit 1000000 --workers 16
```

The script runs `medusa fuzz` (which reads `medusa.json`) or `echidna . --contract CryticTester --config echidna.yaml`.

### What `script/fuzz.sh` does

A plain `medusa fuzz` or `echidna` call does not work. Both configs pass `--foundry-ignore-compile`, so the fuzzers expect prebuilt artifacts. The script provides them:

1. Exports `FOUNDRY_PROFILE=fuzz`. The `[profile.fuzz]` section of `foundry.toml` inherits every compiler setting from the default profile but builds into `out-fuzz/` and `cache-fuzz/`, so a concurrent `forge build` or `forge test` cannot write into the directory the fuzzer reads.
2. Checks that the profile's `out` directory matches the `--foundry-out-directory` value in `medusa.json` or `echidna.yaml`. With `--foundry-ignore-compile`, crytic-compile ignores `FOUNDRY_PROFILE` and needs the directory named explicitly.
3. Runs `forge clean` and `forge build --build-info`.
4. Deletes every build-info file that carries no solc `output`, whether inline or in a sibling `.output.json`. crytic-compile fails on such files with `FileNotFoundError: out/build-info/<id>.output.json` or `KeyError: 'output'`.
5. Starts the fuzzer.

| Exit code | Cause |
|---|---|
| 64 | Missing or unknown fuzzer argument. |
| 127 | `forge`, `jq` or the fuzzer is not on `PATH`. |
| 78 | `[profile.fuzz]` has no dedicated `out` directory, or it disagrees with the fuzzer config. |
| 70 | The build produced no build-info, or no build-info entry with solc output. |

### Fuzzer configuration

Both configs link the external `BlueprintEncoder` library at address `0xf01` (`--compile-libraries=(BlueprintEncoder,0xf01)`) and use deployer `0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496`.

| Setting | `medusa.json` | `echidna.yaml` |
|---|---|---|
| Mode | Assertion testing (only `failOnAssertion` among panic codes); property testing enabled with prefix `invariant_` | `testMode: assertion` |
| Target | `CryticTester` | `CryticTester` (from `script/fuzz.sh`) |
| Test limit | `testLimit: 0` (unbounded), `timeout: 0` | Echidna default unless you pass `--test-limit` |
| Workers | 40 | Echidna default unless you pass `--workers` |
| Call sequence length | 100 | Echidna default |
| Balances | 3,000,000 ETH for `CryticTester` | 300 ETH for the contract (`balanceContract`) and for each sender (`balanceAddr`) |
| Senders | `0x10000`, `0x20000`, `0x30000` | Echidna default |
| Corpus directory | `medusa/` | `echidna/` |
| Coverage | Enabled | Enabled |
| Other | Cheatcodes on, FFI off, `stopOnFailedTest: false` | `shrinkLimit: 100000`; deploys `BlueprintEncoder` at `0xf01` via `deployContracts` |

The fuzzer's sender address never reaches the VM. Handlers call it either as the current actor (through `asActor` or `vm.prank(_getActor())`; `switchActor` changes the actor, and `setup()` adds `0x101` and `0x202`) or as `CryticTester` itself.

Both corpus directories and the `out-fuzz/`/`cache-fuzz/` build directories are gitignored.

## Reproducing a broken property in Foundry

`CryticToFoundry` runs the same `setup()`, handlers and properties under Forge, with assertions from `FoundryAsserts`. Use it to turn a fuzzer counterexample into a deterministic test:

1. Copy the shrunk call sequence from the fuzzer output.
2. Add a `test_` function to `CryticToFoundry.sol` that calls each handler in order with the reported arguments, then calls the broken property. If the sequence includes block or time delays, reproduce them with `vm.roll` and `vm.warp` between calls.
3. Run it:

   ```shell
   forge test --match-contract CryticToFoundry --match-test test_my_repro -vvvv
   ```

4. Fix the bug, keep the test as a regression, and confirm the whole contract passes:

   ```shell
   forge test --match-contract CryticToFoundry -vv
   ```

The existing reproducers show the pattern:

| Test | Sequence |
|---|---|
| `test_explode_static_conservation` | `explode_clampedStatic`, then the no-revert, static-conservation and non-interference properties. |
| `test_explode_dynamic_tail_partition` | `explode_clampedDynamic`, then the no-revert, tail-partition and non-interference properties. |
| `test_explode_alias_safety` | `explode_aliasSource`, then the no-revert and alias-safety properties. |
| `test_explode_single_static` | `explode_clampedStatic(0)` (one destination), then the static properties. |
| `test_explode_dictionary_untouched_registries` | `addExplodeToDictionary`, `performClampedCall`, then `invariant_registries` and `property_untouched_registries`. |
| `test_explode_mixed_partition` | `explode_clampedMixed`, then the no-revert, mixed-partition and non-interference properties. |
| `test_explode_raw_revert_taxonomy` | `explode_raw` with `destCount = 0`, then with an out-of-range source register, checking the revert taxonomy after each. |

`CryticTester` is large. `foundry.toml` sets `gas_limit = 30000000` so that `CryticToFoundry.setUp()` can deploy the harness; new handlers that push its code size up can surface as `EvmError: OutOfGas` in the constructor.

## Limitations

- **Unstructured bytes.** The fuzzers mutate `bytes` arguments without knowing their structure, so random input rarely forms a valid blueprint, surgery descriptor or command word. `CALLDATA_BUILD` and `CALLDATA_SURGERY` coverage comes mainly from the shortcut handlers, which hard-code well-formed shapes, mostly for `OmniTarget`. `ABI_ENCODE` only receives fuzzer-generated blueprints. Combinations nobody encoded as a shortcut stay mostly unexplored.
- **Clamped EXPLODE state.** The clamped EXPLODE handlers run on a fresh 32-register state, not on the shared `state`. Only `addExplodeToDictionary` feeds EXPLODE into multi-command sequences.
- **`property_untouched_registries` scope.** The check only applies when the last ghost-tracked handler was `performClampedCall`; after any other handler it returns without asserting.

## Credits

Recon ([getrecon.xyz](https://getrecon.xyz)) wrote the original harness.
