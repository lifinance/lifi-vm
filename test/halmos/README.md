# Halmos symbolic tests

This directory holds the [Halmos](https://github.com/a16z/halmos) property suite for the LI.FI Virtual Machine. Each `*HalmosTest.sol` contract declares `check_*` functions. Halmos runs them with symbolic inputs and reports any input that breaks an assertion.

`forge test` does not run these properties: Forge only picks up `test*` functions, so it compiles the contracts and skips every `check_*` function. Run them with Halmos.

## Running

### Requirements

| Tool | Version | Notes |
|---|---|---|
| Foundry | `v1.7.1` | The version CI pins. Halmos 0.3.3 cannot run artifacts built by Foundry 1.8.1 (see [CI](#ci)). |
| Halmos | `0.3.3` | Needs Python; CI uses Python 3.12. |
| Submodules | — | `lib/forge-std` and `lib/halmos-cheatcodes` provide `Test` and `SymTest`. |

```shell
foundryup --install v1.7.1
pip install halmos==0.3.3
forge install
```

### Commands

Run from the repository root.

```shell
# One test contract (what CI does for ExplodeHalmosTest)
halmos --config halmos.toml --contract ExplodeHalmosTest

# One property; --function matches function names and overrides the config value
halmos --config halmos.toml --contract ExplodeHalmosTest --function check_explode_roundtrip_three

# Every test contract in the repository
halmos --config halmos.toml
```

The full suite takes much longer than a single contract. `SurgeryOPSHalmosTest` is by far the slowest because `check_perform_surgery` unrolls nested loops over symbolic windows.

### Configuration

`halmos.toml` sets these `[global]` options:

| Key | Value | Effect |
|---|---|---|
| `function` | `"check"` | Runs functions whose names start with `check`. |
| `loop` | `100` | Unrolls loops up to 100 iterations. |
| `array-lengths` | `"toks={3}"` | Fixes the symbolic `toks` array in `ArithmeticProcessorHalmosTest.check_evaluateRPN` at length 3. |
| `early-exit` | `false` | Keeps exploring after a counterexample, so a run reports every failing path. |

## CI

The `halmos-explode` job in `.github/workflows/ci-solidity.yml` runs one contract:

```shell
halmos --contract ExplodeHalmosTest --config halmos.toml
```

The job installs Foundry `v1.7.1` and `halmos==0.3.3` on Python 3.12. No other Halmos contract runs in CI, so run the rest locally after changing the code they cover.

Both Solidity workflows pin Foundry `v1.7.1`. Under Foundry 1.8.1, Halmos 0.3.3 rejects the test constructor with `Unsupported cheat code: deployCode(string)` and every property fails. Upgrade the two pins together, and only after the Halmos job passes on the new toolchain.

## Properties

Each table lists the active `check_*` functions of one test contract.

### `CommandPackingHalmosTest`

Pack and unpack round trips for `src/CommandPacking.sol`. `CommandPackingHarness` exposes the library functions so the revert checks can call them externally.

| Property | What it checks |
|---|---|
| `check_call_roundtrip` | `packCall` then `unpackCall` returns the original `target`, `callType`, `destReg`, `srcReg` and `valueReg`. |
| `check_calldata_build_roundtrip` | `packCallDataBuild` then `unpackCallDataBuild` returns the selector, `destReg` and every blueprint byte for blueprint lengths 0–22. |
| `check_explode_roundtrip` | `packExplode` then `unpackExplode` returns `sourceReg` (below `0x80`), `destCount` and each destination byte. Checked for `destCount` 1–25. |
| `check_deposit_approved_roundtrip` | `packDepositApproved` then `unpackDepositApproved` returns `token`, `destReg` and `maxDepositReg`. |
| `check_surgery_roundtrip` | `packCallDataSurgery` then `unpackCallDataSurgery` returns `sourceReg`, `surgeryCount` (0–6) and each descriptor. Unused descriptor slots unpack as zero. Descriptor fields are concrete: slot `j` holds `offset = length = replacementReg = j`. |
| `check_return_roundtrip` | `packReturn` then `unpackReturn` returns `sourceReg`. |
| `check_abi_encode_roundtrip` | `packAbiEncode` then `unpackAbiEncode` returns `destReg` and every blueprint byte for blueprint lengths 0–27. |
| `check_calldata_build_blueprint_too_large_reverts` | `packCallDataBuild` with a 23-byte blueprint reverts with `BlueprintTooLarge`. |
| `check_abi_encode_blueprint_too_large_reverts` | `packAbiEncode` with a 28-byte blueprint reverts with `BlueprintTooLarge`. |
| `check_remaining_gas_roundtrip` | `packRemainingGas` then `unpackRemainingGas` returns `destReg`. |
| `check_native_balance_roundtrip` | `packNativeBalance` then `unpackNativeBalance` returns `addrReg` and `destReg`. |
| `check_log_roundtrip` | `packLog` then `unpackLog` returns the variant (up to `LogVariant.DYNAMIC`) and the `sourceRegs` mask. Masks wider than 208 bits revert in `packLog`, so only 208-bit masks reach the assertion. |
| `check_unpackCallDataBuild_overflow` | `unpackCallDataBuild` reverts with `BlueprintTooLarge` when the encoded blueprint length is 28, above the 22-byte maximum. |

### `DepositApprovedHalmosTest`

`DepositApprovedLib.depositApproved` (`src/DepositApproved.sol`), called through `DepositApprovedHarness` against the `MinimalERC20` mock in `mocks/`.

| Property | What it checks |
|---|---|
| `check_depositApprovedWithCustomBehavior` | For a symbolic token behavior (`DEFAULT`, `FOT`, `NO_RETURN`, `FALSE_ON_FAILURE`, `APPROVE_PROTECTED`), the call does not revert. It returns the amount received, `min(balance, allowance)` less the 1% fee for `FOT`, and that amount equals the harness balance. |
| `check_deposit_approved_command` | With symbolic balance and allowance, the transferred amount is `min(balance, allowance)`. |
| `check_deposit_approved_zero_approval` | Zero allowance transfers nothing. |
| `check_deposit_approved_zero_balance` | Zero balance transfers nothing. |
| `check_deposit_approved_invalid_token` | A token address without code reverts with `CallToNonContract`. |

### `InvariantCheckerHalmosTest`

Assertion opcodes in `src/InvariantChecker.sol`. `InvariantCheckerWrapper` exposes the internal `_checkAssertion` as `checkAssertion`.

| Property | What it checks |
|---|---|
| `check_single_op` | For every opcode 0–15 and every in-bounds value index, `_checkAssertion` returns the correct next index or reverts with the matching error: `AssertEqFailed`, `AssertNeqFailed`, `AssertLtFailed`, `AssertGtFailed`, `AssertLteFailed`, `AssertGteFailed`, `AssertRangeFailed`, or `UnknownOpcode` for opcodes 8–15. |
| `check_batch_vs_packed` | For 0–31 symbolic opcodes, `batchAssert(ops, values)` and `batchAssertPacked(packOps(ops), count, values)` either both succeed with equal return data or both revert with the same selector. |
| `check_public_asserts_match_internal(uint256,uint256,uint256)` | For opcodes 1–7, each public `assert*` function and `_checkAssertion` agree on success or revert selector. |
| `check_public_asserts_match_internal(uint8,uint256,uint256,uint256)` | Same equivalence with a symbolic `uint8` opcode, restricted to well-formed ranges (`min <= max`) for opcode 7. |
| `check_packOps_boundaries_and_manual(uint8[])` | `packOps` equals manual big-endian byte packing for a symbolic array. |
| `check_packOps_boundaries_and_manual(uint8,uint8,uint8,uint8)` | `packOps` equals manual packing for a four-element array. |
| `check_batchPacked_too_many` | `batchAssertPacked` with 33 operations reverts with `TooManyOperations`. |
| `check_batchPacked_boundaries` | `batchAssertPacked` succeeds for 0–32 NOP operations. |
| `check_inRange_inclusive_bounds` | `assertInRange` accepts `value == min` and `value == max` when `min <= max`. |
| `check_inRange_min_gt_max_reverts_ge_min` | With `min > max` and `value == min`, both `assertInRange` and opcode 7 revert with `AssertRangeFailed`. |
| `check_inRange_min_gt_max_reverts_lt_min` | With `min > max` and `value == max`, both `assertInRange` and opcode 7 revert with `AssertRangeFailed`. |
| `check_nop_no_advance_in_batch` | Prefixing a batch with NOP does not advance the value index: `[NOP, EQ]` and `[EQ]` have the same outcome. |

### `RegisterFileHalmosTest`

Register access in `src/RegisterFile.sol`. `RegisterFileHarness` exposes `get`, `set` and `setDynamic` for the revert checks.

| Property | What it checks |
|---|---|
| `check_get_static` | Over 128 static or dynamic registers, `get(i)` returns 32 zero bytes for `VOID_REG` and the stored bytes otherwise. |
| `check_getStatic` | Over 128 static registers, `getStatic(i)` returns 32 zero bytes for `VOID_REG` and the stored value otherwise. |
| `check_set` | `set(i, data)` stores `data` for every index below 128 except `VOID_REG`. |
| `check_setDynamic` | For indices 128–191, `setDynamic` followed by `get` returns the ABI-encoded payload without its leading offset word. |
| `check_set_then_get` | `get(i)` after `set(i, data)` returns `data` for every index below 127 except `VOID_REG`. |
| `check_get_oob_reverts` | `get` on a 64-register file reverts with `RegisterIndexOOB` for any index of 64 or more, excluding `VOID_REG` and `IDX_MASK`. |
| `check_set_oob_reverts` | `set` reverts with `RegisterIndexOOB` under the same conditions. |
| `check_get_void_reg_always_zero` | `get(VOID_REG)` returns 32 zero bytes. |
| `check_set_void_reg_noop` | `set(VOID_REG, data)` leaves all 128 registers unchanged. |
| `check_setDynamic_short_payload_reverts` | `setDynamic` reverts with `InvalidDynamicData` for every payload shorter than 64 bytes. |

### `SurgeryOPSHalmosTest`

`SurgeryOps.performSurgery` (`src/SurgeryOPS.sol`).

| Property | What it checks |
|---|---|
| `check_perform_surgery` | For up to 6 symbolic surgeries on one of 10 symbolic registers (32 to 160 bytes long), the source register keeps its length, bytes outside every window stay unchanged, and each window holds zero left-padding followed by the right-aligned replacement. The result must equal an independently computed expected value. |
| `check_performingNoSurgeryIsIdempotent` | A surgery count of 0 leaves every register unchanged. |
| `check_replaceTheEntireObject` | A 32-byte window at offset 0 replaces a static word with the replacement word. |
| `check_replaceTheEntireObject_dynamic` | A 96-byte window at offset 0 replaces an ABI-encoded `bytes` value with the replacement value. |
| `check_replaceTheLastByte` | A 1-byte window at offset 31 replaces only the last byte of a 32-byte register. |
| `check_zeroOutThroughEmptyByte` | A 1-byte zero replacement in a 32-byte window zeroes the whole word. |

### `BlueprintEncoderHalmosTest`

ABI encoding in `src/BlueprintEncoder.sol` and the VM commands that use it. The expected values come from Solidity's `abi.encode`.

| Property | What it checks |
|---|---|
| `check_symbolic_flat_matches_abi` | A 3-token flat blueprint, each token drawn from static registers 0–1 and dynamic registers 2–3, makes `encodeData` equal `abi.encode` of the selected values. |
| `check_encode_from_blueprint_flat_matches_abi` | The same flat shapes make `encodeFromBlueprint(sel, …)` equal `sel` followed by `abi.encode(…)`. |
| `check_static_array2_matches_abi` | A static array of two static registers encodes like `uint256[2]`. |
| `check_static_array2_with_dynamic_elements_matches_abi` | A tuple opener around two dynamic registers encodes like `bytes[2]`. |
| `check_static_array2_with_dynamic_elements_works_as_dynamic_tuple` | Identical body to the previous property. |
| `check_dynamic_array_matches_abi` | A dynamic array of two static registers encodes like `uint256[]`. |
| `check_dynamic_array_with_dynamic_elements_matches_abi` | A dynamic array of two dynamic registers encodes like `bytes[]`. |
| `check_tuple_with_static_elements_matches_abi` | A static tuple of two static registers encodes like `(uint256, uint256)`. |
| `check_tuple_with_dynamic_elements_matches_abi` | A dynamic tuple of two dynamic registers encodes like `(bytes, bytes)`. |
| `check_bad_static_format_reverts` | A 1-byte static register reverts with `BadStaticFormat`. |
| `check_bad_dynamic_format_reverts` | A 1-byte dynamic register reverts with `BadDynamicFormat`. |
| `check_payload_length_invariants` | For a blueprint of one static and one dynamic register, the `encodeData` payload is 64 head bytes plus the dynamic register's length. The `encodeFromBlueprint` payload is 4 bytes longer. |
| `check_pointer_bounds_flat` | For the flat 3-token shapes, the payload length equals head plus tail, and every dynamic head pointer is 32-byte aligned with its data inside the payload. |
| `check_pointer_alignment_dynamic_array` | A dynamic array's head pointer is 32-byte aligned and in bounds, and the payload length is head plus tail. |
| `check_pointer_alignment_nested_tuple` | In `(uint256, (uint256, bytes))`, the nested tuple's head pointer is 32-byte aligned and in bounds. |
| `check_generative_encoder_invariants` | Across four generated shapes (static array, dynamic array, nested tuple, flat), `encodeData` and `encodeFromBlueprint` succeed or fail together, and on success the latter equals the selector followed by the former. |
| `check_unclosed_container_reverts` | A blueprint consisting of a single tuple opener (static or dynamic) reverts with `UnclosedContainer`. |
| `check_stack_overflow_reverts` | 13 nested static-tuple openers (one more than `MAX_STACK_DEPTH`) revert with `StackOverflow`. |
| `check_empty_blueprint_returns_empty` | An empty blueprint yields only a zero length word. |
| `check_missing_register_static_reverts` | A static token that references a register past the end of the file reverts with `RegisterIndexOOB`. |
| `check_missing_register_dynamic_reverts` | Same for a dynamic token. |
| `check_vm_abi_encode_equals_encoder` | For the generated shapes, the VM's `ABI_ENCODE` command writes exactly `BlueprintEncoder.encodeData(bp, regs)` to its destination register. |
| `check_vm_calldata_build_equals_concat` | For the generated shapes, the VM's `CALLDATA_BUILD` command writes the selector followed by the `encodeData` payload. |

### `SafeTransferHalmosTest`

`SafeTransferVMLib.execute` (`src/SafeTransferLib.sol`), called through `SafeTransferHarness` against the `MinimalERC20` mock.

| Property | What it checks |
|---|---|
| `check_safeTransfer_roundtrip` | `packSafeTransfer` then `unpackSafeTransfer` returns `token`, `toReg` and `amountReg`. |
| `check_safeTransfer_execution_success` | With enough balance, the recipient gains and the sender loses exactly the amount. |
| `check_safeTransfer_insufficient_balance_reverts` | With too little balance, execution reverts with `TransferFailed()`. |
| `check_safeTransfer_invalid_address_reverts` | A 10-byte recipient register reverts with `InvalidAddressBytes`. |
| `check_safeTransfer_zero_amount` | A zero-amount transfer succeeds and moves no tokens. |
| `check_safeTransfer_fot_behavior` | With a 1% fee-on-transfer token, the sender loses the full amount and the recipient gains the amount minus the fee. |
| `check_safeTransfer_no_return_behavior` | A token whose `transfer` returns no data still transfers the exact amount. |
| `check_safeTransfer_false_on_failure_insufficient_balance` | A token that returns `false` on failure makes execution revert with `TransferFailed()`. |
| `check_safeTransfer_all_behaviors` | For every symbolic token behavior, the sender loses the full amount and the recipient gains the amount, less the fee for `FOT`. |
| `check_safeTransfer_to_self` | A transfer from the harness to itself leaves its balance unchanged. |

### `ExplodeHalmosTest`

The `EXPLODE` command: `packExplode`/`unpackExplode` in `src/CommandPacking.sol` and execution through `VirtualMachine.runWithState`. The source labels the properties E-1 to E-13. This is the contract CI runs.

| ID | Property | What it checks |
|---|---|---|
| E-1 | `check_explode_roundtrip_three` | With `destCount = 3`, a symbolic `sourceReg` below `0x80` and symbolic destinations, pack then unpack returns every field. |
| E-2 | `check_explode_destCount_zero_reverts` | `packExplode` with `destCount = 0` reverts with `DestinationCountOutOfBounds`. |
| E-3 | `check_explode_destCount_too_large_reverts` | `packExplode` with `destCount = 27` reverts with `DestinationCountOutOfBounds`. |
| E-4 | `check_explode_unaligned_source_reverts` | A 33-byte source register reverts with `InvalidRegisterLength`. |
| E-5 | `check_explode_source_too_short_reverts` | A 64-byte source with three destinations (96 head bytes) reverts with `OutOfBounds`. |
| E-6 | `check_explode_all_static_extracts_each_word` | Three static destinations receive the three source words in order. |
| E-7 | `check_explode_single_dynamic_tail_equals_remainder` | A trailing dynamic destination receives the whole tail after its offset. The static destination before it receives its head word. |
| E-8 | `check_explode_nonzero_padding_reverts` | `unpackExplode` reverts with `NonZeroPadding` when any of padding bytes 28–31 is nonzero. |
| E-9 | `check_explode_pack_source_high_bit_reverts` | `packExplode` rejects a `sourceReg` with bit `0x80` set with `NonZeroPadding`. |
| E-10 | `check_explode_unpack_source_high_bit_reverts` | `unpackExplode` rejects a word whose only defect is the `sourceReg` high bit with `NonZeroPadding`. |
| E-11 | `check_explode_unused_dest_slot_reverts` | `unpackExplode` rejects a nonzero byte in the unused destination slots (bytes `2 + destCount` to 27) with `NonZeroPadding`. |
| E-12 | `check_explode_non_increasing_dynamic_offsets_reverts` | Two dynamic destinations whose offsets are individually valid but not strictly increasing revert with `OutOfBounds`. |
| E-13 | `check_explode_invalid_dynamic_offset_reverts` | A dynamic offset that is unaligned, inside the head, or past the source end reverts with `OutOfBounds`. |

### `MinimalProxyAccessHalmosTest`

End-to-end checks against a real `MinimalProxy` (`src/MinimalProxy.sol`) that delegates to a real `VirtualMachine`, with the `MinimalERC20` mock as the token.

| Property | What it checks |
|---|---|
| `check_proxy_deposit_pulls_from_owner` | A `DEPOSIT_APPROVED` the owner sends through the proxy moves the owner's approved tokens into the proxy. |
| `check_direct_deposit_pulls_from_caller` | A `DEPOSIT_APPROVED` called directly on the VM pulls tokens from `msg.sender` into the VM. |
| `check_only_owner_can_call` | After the factory's first call, a symbolic caller succeeds only if it is the owner. |

### `ArithmeticProcessorHalmosTest`

RPN evaluation in `src/RPNArithmetic.sol` (`ArithmeticProcessor`).

| Property | What it checks |
|---|---|
| `check_evaluateRPN` | A 3-token stream of opcodes (`ADD` to `MAX`) and register pushes (registers 0–2) evaluates to the same result as the reference model `mocks/RPNEvaluationDeOptimized.sol`. |
| `check_oneOpFuzzRPN` | For `uint128` operands and every opcode, `reg0 op reg1` matches exactly for `ADD`, `DIV_DOWN`, `DIV_UP`, `MIN` and `MAX`, and is bounded below by the expected value for `SUB` and `MUL`. Only `DIV_*` with a zero divisor and `SUB` with `b > a` may revert. |
| `check_minMaxSymbolic` | `MIN` and `MAX` never revert and return the correct extremum over the full `uint256` domain. |
| `check_rpLenZeroAlwaysReverts` | A stream length of 0 reverts. |
| `check_maxItemsInStack` | A 31-token stream (16 register pushes, then 15 `ADD`s) evaluates without reverting. |

## Known limitations

- **Bounded, not complete.** Halmos unrolls loops up to `loop = 100`. Symbolic byte strings have fixed lengths chosen per property, and many properties fix the shape of the input (register count, blueprint layout, `destCount`). A pass means no counterexample exists within those bounds.
- **Reverting paths pass silently.** Halmos discards paths that revert without failing an assertion, just like a failed `vm.assume`. Properties that expect a revert therefore make a low-level call or use `try`/`catch` and assert on the selector. `check_log_roundtrip` relies on this: masks wider than 208 bits revert in `packLog` and drop out.
- **EXPLODE `destCount` coverage.** `check_explode_roundtrip` only asserts for `destCount` 1–25. When `destCount` is 26, the unrolled loop has no matching branch, so the assertion never runs. `testFuzz_Explode_RoundTrip` in `test/CommandPackingTest.t.sol` covers 1–26, and E-1 fixes `destCount` at 3.
- **BlueprintEncoder shapes.** Properties cover flat 3-token blueprints and a few fixed container shapes with two elements, at most one level of nesting. Arbitrary nesting and larger containers are not explored. `check_unclosed_container_reverts` only tries tuple openers.
- **RPN streams.** `check_evaluateRPN` compares against the reference model for 3-token streams only (`array-lengths = "toks={3}"`). Longer streams are not explored symbolically.
- **Disabled properties.** Two properties are commented out and never run:
  - `CommandPackingHalmosTest.check_call_packaed_roundtrip`: a reverse (unpack, then pack) round trip. It cannot hold because an arbitrary packed word can carry nonzero bits in unused bytes that do not survive repacking.
  - `BlueprintEncoderHalmosTest.check_hardcoded_complex_double`: only the name exists, with no body.
- **Toolchain coupling.** Only the Foundry and Halmos versions CI pins are known to work together (see [CI](#ci)).

## Credits

Recon ([getrecon.xyz](https://getrecon.xyz)) wrote the original Halmos suite.
