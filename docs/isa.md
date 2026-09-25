# LI.FI VM Instruction Set Architecture

This document specifies the instruction set of the LI.FI Virtual Machine (`src/VirtualMachine.sol`): the command format, the register model, the byte layout of every opcode, and the runtime behaviour and errors of each instruction. The in-memory layout that `CALLDATA_BUILD` and `ABI_ENCODE` produce is specified in [ABI Memory Layout](./abi_memory_layouts.md).

## Execution model

A program is an array of commands. Each command is a `VMCommand` (`src/DataModel.sol`):

```solidity
struct VMCommand {
    OP op;        // opcode, see "Opcodes"
    bytes32 data; // packed operands, layout depends on op
}

struct VMState {
    bytes[] registers; // the register file
}
```

The VM exposes two entry points. Both are `payable`, and both execute the same loop.

| Entry point | Returns |
|---|---|
| `runVM(VMCommand[] commands, VMState initialState)` | The bytes of the register named by the first `RETURN`, or empty bytes if the program ends without one. |
| `runWithState(VMCommand[] commands, VMState initialState)` | `(VMState finalState, bytes out)`: the register file after execution, plus the same output as `runVM`. |

Execution rules:

- Commands run strictly in order. There are no jumps or branches.
- `RETURN` halts immediately. Commands after it do not run.
- Any revert aborts the whole program. A failed external `CALL` re-throws the callee's revert data unchanged.
- An `op` value outside `0`–`10` reverts. The Solidity ABI decoder rejects out-of-range enum values, and `_run` also ends in an `InvalidOpcode(uint8)` fallback.

In production the VM runs behind `MinimalProxy` (`src/proxy/MinimalProxy.sol`), which forwards calls with `delegatecall`. VM code therefore executes in the proxy's context: `address(this)` is the proxy, token balances and native balance are the proxy's, and events are emitted by the proxy.

## Registers

The register file is `VMState.registers`, a `bytes[]` supplied by the caller. Its length is the number of usable registers. A register is a byte string with no type attached. The instruction that reads it decides how to interpret it.

### Register fields

Every register operand in a command word is one byte:

| Bits | Meaning |
|---|---|
| `0x7F` (low 7 bits) | Register index, `0`–`127`. |
| `0x80` (high bit) | Flag. Its meaning depends on the field; see the table below. |

Register index `0x7A` (`VmConstants.VOID_REG`) is the **void register**:

- Reads return `ZERO_VALUE`, a 32-byte zero word. They never revert.
- Writes are discarded silently.
- It needs no slot in the register file.

Any other index at or beyond `registers.length` reverts `RegisterFile.RegisterIndexOOB()`.

### The high bit (`0x80`)

The high bit has an effect in only four kinds of field. Everywhere else, the VM reads the field through `RegisterHelpers.idx()`, which masks the bit off.

| Field | Effect of the high bit |
|---|---|
| `CALL` destination register | Selects how the return data is stored: set means `RegisterFile.setDynamic`, clear means `RegisterFile.set`. See [CALL](#call-0). |
| `EXPLODE` destination registers | Selects how the source is read: set means a dynamic tail slice, clear means one 32-byte head word. See [EXPLODE](#explode-2). |
| `EXPLODE` source register | Reserved. Must be zero, or `unpackExplode` reverts `NonZeroPadding()`. |
| Blueprint register tokens | Selects a static (32-byte word) or dynamic (length-prefixed blob) operand. See [Blueprints](#blueprints). |
| Every other register field | Ignored. Producers should leave it clear. |

### Register contents

The VM checks register length only where an instruction needs a particular shape:

| Shape | Requirement | Checked by |
|---|---|---|
| Static word | Exactly 32 bytes. | `RegisterFile.getStatic` (`InvalidStaticData()`), blueprint static tokens (`BadStaticFormat(uint8)`), `RegisterHelpers.asAddress` (`InvalidAddressBytes()`). |
| Dynamic blob | A length-prefixed ABI tail: `[length (32)][data][zero padding to a 32-byte multiple]`. The VM checks only that it is at least 32 bytes long. | Blueprint dynamic tokens (`BadDynamicFormat(uint8)`). |
| Calldata | `[length L (32)][L bytes of calldata]`, the format `CALLDATA_BUILD` produces. At least 32 bytes long. | `CALL` (`InvalidCallDataLength()`). |

Address and amount operands are ABI words: an address is right-aligned in 32 bytes, and a `uint256` is the full word.

## Opcodes

| `op` | Name | Summary |
|---|---|---|
| 0 | `CALL` | External call using calldata held in a register. |
| 1 | `CALLDATA_BUILD` | Builds selector-prefixed calldata from registers using a blueprint. |
| 2 | `EXPLODE` | Splits an ABI-encoded tuple in one register into one register per field. |
| 3 | `DEPOSIT_APPROVED` | Pulls approved ERC-20 tokens from the owner into the executing contract. |
| 4 | `CALLDATA_SURGERY` | Overwrites byte ranges of a register in place. |
| 5 | `RETURN` | Halts and returns a register's bytes. |
| 6 | `ABI_ENCODE` | ABI-encodes registers using a blueprint, without a selector. |
| 7 | `REMAINING_GAS` | Stores `gasleft()` in a register. |
| 8 | `NATIVE_BALANCE` | Stores an address's native-token balance in a register. |
| 9 | `LOG` | Emits an event carrying register data. |
| 10 | `SAFE_TRANSFER` | Transfers ERC-20 tokens out of the executing contract. |

## Command word layouts

`data` is a big-endian `bytes32`. Byte 0 is the most significant byte (bits 255–248), and byte 31 is the least significant (bits 7–0). A one-byte field at byte `N` is packed with `value << ((31 - N) * 8)` and read with `uint8(uint256(data >> ((31 - N) * 8)))`. `src/CommandPacking.sol` implements the packer and unpacker for every opcode.

Rows marked *Reserved* are zero by convention. Only `EXPLODE` enforces this; see [Padding and Reserved-Bit Policy](#padding-and-reserved-bit-policy).

### CALL (0)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Call type | 1 | `CallType` value, see below. |
| 1–20 | Target | 20 | Address to call. |
| 21 | Destination register | 1 | Receives the return data. High bit selects the store path. |
| 22 | Source register | 1 | Holds the calldata. High bit ignored. |
| 23 | Value register | 1 | Holds the call value, read only for `VALUECALL`. High bit ignored. |
| 24–31 | Reserved | 8 | |

| Call type | Name | Behaviour |
|---|---|---|
| 0 | `DELEGATECALL` | Reverts `Disallowed()`. |
| 1 | `CALL` | `target.call(calldata)` with zero value. |
| 2 | `STATICCALL` | `target.staticcall(calldata)`. |
| 3 | `VALUECALL` | `target.call{value: v}(calldata)`, where `v` is the value register read with `getStatic` (exactly 32 bytes, else `InvalidStaticData()`). The value is paid from the executing contract's native balance. |

A call type above 3 fails the enum conversion and reverts with `Panic(0x21)`.

**Calldata.** The source register must hold `[L (32 bytes)][calldata]`, which is the `CALLDATA_BUILD` output format. A register shorter than 32 bytes reverts `InvalidCallDataLength()`. The VM sends the `L` bytes that follow the length word. It does not check `L` against the register's actual length, so producers must keep `L <= registerLength - 32`. The void register as source yields `L = 0`, which sends empty calldata.

**Execution.** The VM does not check that the target has code. A call to an address without code succeeds with empty return data. If the call fails, the VM reverts with the callee's revert data unchanged.

#### CALL destination-register high bit

The high bit of the destination register selects the store path for the return data. The two paths accept different return shapes. The producer must choose correctly, because the VM cannot infer the right path.

- **Clear (static).** `RegisterFile.set` stores the return data verbatim, with no shape check. Use this for static returns and for tuples.
- **Set (dynamic).** `RegisterFile.setDynamic` expects the ABI encoding of a single dynamic value: `bytes`, `string`, or one dynamic array. It requires `returndata.length >= 0x40` and word 0 equal to `0x20`, and reverts `InvalidDynamicData()` otherwise. It then drops the leading offset word, so the register holds `[length][payload]`, which is the dynamic-blob shape the blueprint encoder consumes.

A tuple return must use a clear high bit and be decomposed with `EXPLODE`. `EXPLODE` reads head offsets relative to the start of the stored block, which is exactly what `set` stores. A dynamic tuple such as `(bytes,string,uint256[])` has head words `0x60, 0xa0, 0xe0`. Its word 0 is not `0x20`, so a set high bit reverts `InvalidDynamicData()`.

**The `word 0 == 0x20` test catches some wrong flags. It cannot confirm a right one.** Word 0 of a tuple return is the tuple's first head word, and for a static first field that word is the field's value. A return of `(uint256 amount, bytes data)` with `amount == 32` passes the test. `setDynamic` then strips `amount`, so the register's length word is the tuple's offset word (`0x40`) and its contents are meaningless. Nothing reverts. The ambiguity also runs the other way: a one-field dynamic tuple `(bytes)` and a bare `bytes` are byte-identical in return data. Choosing the flag correctly is the producer's responsibility. A wrong choice usually corrupts the register silently rather than reverting. `test/CallRegisterCanonicality.t.sol` pins both directions.

Two further consequences:

- Return data is the ABI encoding of the return *list*. If the only return value is a dynamic tuple `T`, the return data is `0x20 || encode(T)`, a one-field tuple and not a bare `T`. An `EXPLODE` of that register must use a one-destination list matching the wrapper. Treating the register as a bare `T` reads the offset word as field 0 and reverts `OutOfBounds()`.
- `setDynamic` corrects the length in place. It rewrites the length word inside the return-data buffer, so any other reference to that buffer sees the change.

An encoder that emits `CALL` commands must therefore:

1. Set the destination high bit only when the callee returns exactly one `bytes`, `string`, or dynamic array.
2. Clear it for every tuple return, and read a dynamic-tuple result only through `EXPLODE`.
3. Model a sole dynamic-tuple return value as a one-field tuple wrapping it.

### CALLDATA_BUILD (1)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0–3 | Selector | 4 | Function selector. |
| 4 | Destination register | 1 | Receives the calldata. High bit ignored. |
| 5 | Blueprint length | 1 | `0`–`22` (`VmConstants.MAX_CDB_BP`). A larger value reverts `BlueprintTooLarge()`. |
| 6–27 | Blueprint | 22 | Blueprint tokens. Only the first *blueprint length* bytes are read. |
| 28–31 | Reserved | 4 | |

The VM runs `BlueprintEncoder.encodeFromBlueprint(selector, blueprint, registers)` and stores the result with `set`. The register then holds:

```
[4 + N (32 bytes)][selector (4 bytes)][ABI-encoded arguments (N bytes)]
```

This is the in-memory `bytes` produced by `abi.encodeWithSelector(selector, args...)`, including its length word, and it is the calldata format `CALL` expects. An empty blueprint yields `[4][selector]`. See [Blueprints](#blueprints) for the token format and [ABI Memory Layout](./abi_memory_layouts.md) for the payload layout.

The result is `36 + N` bytes long, which is not a multiple of 32. It is therefore not a well-formed dynamic blob for another blueprint.

### EXPLODE (2)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Source register | 1 | Holds the ABI-encoded tuple. The high bit is reserved and must be zero. |
| 1 | Destination count | 1 | `1`–`26` (`CommandPacking.MAX_EXPLODE_DESTS`). |
| 2–27 | Destination registers | 26 | One byte per destination. Destination `i` is at byte `2 + i`. The high bit is a live flag: set means dynamic, clear means static. |
| 28–31 | Reserved | 4 | Must be zero. |

`EXPLODE` treats the source register as an ABI tuple block with one 32-byte head word per destination. It writes one register per field, so a returned struct or tuple can be decomposed into the register shapes `ABI_ENCODE` and `CALLDATA_BUILD` consume.

#### Unpacking rules

`CommandPacking.unpackExplode` enforces a canonical encoding:

- The destination count must be in `[1, 26]`, else `DestinationCountOutOfBounds(uint8 count)`.
- The source-register high bit (byte 0, bit `0x80`) must be clear, else `NonZeroPadding()`. `ExplodeLib.execute` reads the source through `idx()`, so the bit has no read path. Rejecting it prevents two different words from encoding the same command.
- Every bit below the last used destination byte must be zero, else `NonZeroPadding()`. That region is the unused destination slots (bytes `2 + count` through 27) plus bytes 28–31.

#### Execution

`ExplodeLib.execute` (`src/Explode.sol`) runs as follows:

1. It reads the source register once, before writing any destination. A destination may name the source register, and every destination sees the original contents.
2. The source length must be a multiple of 32, else `InvalidRegisterLength()`.
3. The source must be at least `count * 32` bytes long (one head word per destination), else `OutOfBounds()`.
4. For each destination `i`, in order from `0` to `count - 1`:
   - **Static (high bit clear):** copies the 32-byte head word at offset `i * 32`.
   - **Dynamic (high bit set):** reads the head word at `i * 32` as a byte offset `start` into the source. The slice runs from `start` to the offset held by the *next dynamic* destination (static destinations in between do not end it), or to the end of the source if no later destination is dynamic. The VM copies that slice.
   - It writes the result with `RegisterFile.set`. `EXPLODE` never calls `setDynamic`: the high bit selects how the source is read, not how the register is stored.

Every dynamic offset, both a destination's own `start` and the next dynamic destination's offset used as its end, must be:

- at least `count * 32`, so it points past the head region;
- strictly less than the source length;
- a multiple of 32.

The slice end must be strictly greater than its start, so successive dynamic offsets must strictly increase. Any violation reverts `OutOfBounds()`.

Further properties:

- Writes happen in destination order. If two destinations name the same register, the last write wins.
- A destination of `0x7A` (void) discards that field.
- A void source reads as one zero word. `EXPLODE` from the void register with count 1 and a static destination copies a zero word.
- `EXPLODE` writes no return data. Its only effect is on the register file.
- **Cost.** Finding a dynamic slice's end scans forward to the next dynamic destination and stops there. Successive scans never overlap, so one command performs at most `count - 1` destination checks in total (25 at the maximum count). Memory allocation and copying scale with the total bytes copied. `snapshots/vmBenchmarks.json` records the all-static case (`explodeStatic`) and the 26-destination all-dynamic worst case (`explodeDynamicMax`).

Encoders must not emit more than 26 destinations. A larger count reverts `DestinationCountOutOfBounds`.

#### What EXPLODE does not validate

The rules above constrain the *shape* of the source: its length, and the alignment, range and ordering of the dynamic offsets. They do not check that the source is the ABI encoding the command claims it is. Producers, and anyone reasoning about a register that `EXPLODE` wrote, must account for the following. Each is intended behaviour, pinned by `test/ExplodeSemantics.t.sol`.

- **The destination flags define the tuple shape. The data cannot override them.** Nothing checks that the fields marked dynamic are the fields the source encodes dynamically. A dynamic flag on a static field reinterprets the field's *value* as an offset. A large value reverts `OutOfBounds()`, but a value that is word-aligned and inside `[count * 32, sourceLength)` is accepted, and the destination receives unrelated bytes. A static flag on a dynamic field stores the raw offset word instead of the field.
- **A dynamic field's own length prefix is never checked against its slice.** The slice extent comes only from the surrounding offsets, never from the length word at the start of the field, so the two can disagree in both directions. The source is usually the return data of an earlier `CALL`, so the callee, not the program author, chooses those offsets. Pushing the next offset outward yields a register with more bytes than its length word declares, and the surplus survives re-encoding into the dead space of a later `ABI_ENCODE` payload. Pulling it inward yields a register that declares more payload than it carries, so re-encoded fields overlap and a decoder reads the next field's header as this field's content. Neither case reads outside the source or breaks a well-formed decode of the logical values, but neither is canonical ABI.
- **The destination count is a claim about the source, not a check on it.** A count smaller than the source's real number of head words truncates silently: trailing fields and their tails are folded into the last dynamic destination or dropped. Nothing reverts.
- **With at least one dynamic destination, only the bytes between the head and the first dynamic offset are discarded.** The first dynamic offset may be greater than `count * 32`. The bytes in between belong to no destination and are dropped without error. From that offset on, nothing is dropped: each interval between consecutive dynamic offsets, and from the last one to the end of the source, is copied in full into the earlier destination. With no dynamic destination, the head words are the entire read and everything past `count * 32` is dropped.

**Why there is no length check.** `EXPLODE` carries one bit per destination, static or dynamic, and no ABI type. It cannot know what a dynamic field's first word means:

- Only `bytes` and `string` begin with a byte length, and their payload is padded, so the correct predicate would be `sliceLength == 32 + ceil(declaredLength / 32) * 32`, not `32 + declaredLength`.
- A dynamic array begins with an *element* count. A `uint256[]` holding 2 elements is a 96-byte tail whose first word is `2`.
- A nested dynamic tuple has no length prefix at all. Its first word is ordinary data.

Any single length-based rule would therefore reject valid encodings. Checking slice extents would require per-destination type information in the command word, which is an encoding change rather than a bounds check.

### DEPOSIT_APPROVED (3)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0–19 | Token | 20 | ERC-20 token address. |
| 20 | Destination register | 1 | Receives the amount received. High bit ignored. |
| 21 | Max deposit register | 1 | Holds the maximum amount as a 32-byte word. High bit ignored. |
| 22–31 | Reserved | 10 | |

`DepositApprovedLib.depositApproved` (`src/DepositApproved.sol`) pulls tokens from the **owner** into the executing contract:

1. The owner is the address stored at `StorageSlots.OWNER_SLOT` (`keccak256("lifi.minimal-proxy.owner")`), which `MinimalProxy` writes in its constructor. If the slot is zero, for example when the VM is called directly, the owner is `msg.sender`.
2. The max deposit register is read with `getStatic`. It must be exactly 32 bytes, else `InvalidStaticData()`.
3. A token without code reverts `CallToNonContract()`.
4. The VM reads `allowance(owner, address(this))` and `balanceOf(owner)`. A call that fails or does not return exactly 32 bytes counts as `0`.
5. `amount = min(allowance, balanceOf(owner), maxDeposit)`.
6. The VM reads `balanceOf(address(this))`. This call must succeed and return exactly 32 bytes, else `GetBalanceFailed()`. The check runs even when `amount` is zero.
7. If `amount` is zero, the VM writes `0` to the destination and stops.
8. Otherwise, it calls `transferFrom(owner, address(this), amount)` through Solady's `SafeTransferLib.safeTransferFrom`, which reverts `TransferFromFailed()` on failure.
9. It reads `balanceOf(address(this))` again and writes `after - before` to the destination as a 32-byte word. This is the amount actually received, which is lower than `amount` for fee-on-transfer tokens.

### CALLDATA_SURGERY (4)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Source register | 1 | Register to modify in place. High bit ignored. |
| 1 | Surgery count | 1 | `0`–`6` (`VmConstants.MAX_SURGERIES`). A larger value reverts `TooManySurgeries()`. |
| 2–25 | Descriptors | 24 | Six 4-byte descriptor slots. Only the first *surgery count* slots are read. |
| 26–31 | Reserved | 6 | |

Descriptor `i` occupies bytes `2 + 4i` to `5 + 4i`:

| Descriptor byte | Field | Description |
|---|---|---|
| 0–1 | Offset | `uint16`, big-endian. Byte offset into the source register. |
| 2 | Length | `uint8`. Number of bytes to overwrite. |
| 3 | Replacement register | Register holding the replacement bytes. High bit ignored. |

`SurgeryOps.performSurgery` (`src/SurgeryOPS.sol`) applies the descriptors in order, directly to the source register's buffer:

1. `offset + length` must not exceed the source length, else `OutOfBounds()`.
2. The replacement register's byte length must not exceed `length`, else `ReplacementTooLarge()`.
3. The VM writes `length - replacementLength` zero bytes at `offset`, then the replacement bytes. The replacement is right-aligned inside the window, as ABI words are.

Offsets address the register's raw bytes. For a `CALLDATA_BUILD` result, calldata byte `k` is at offset `32 + k`, and the first argument word starts at offset `36`. Descriptors may overlap; later descriptors overwrite earlier ones. A count of zero modifies nothing, but the source register is still read, so an invalid index still reverts `RegisterIndexOOB()`.

### RETURN (5)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Source register | 1 | Register to return. High bit ignored. |
| 1–31 | Reserved | 31 | |

`RETURN` halts the program and returns the register's raw bytes without interpreting them. The void register returns one zero word. If a program has no `RETURN`, the VM returns empty bytes.

### ABI_ENCODE (6)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Destination register | 1 | Receives the encoding. High bit ignored. |
| 1 | Blueprint length | 1 | `0`–`27` (`VmConstants.MAX_ABI_BP`). A larger value reverts `BlueprintTooLarge()`. |
| 2–28 | Blueprint | 27 | Blueprint tokens. Only the first *blueprint length* bytes are read. |
| 29–31 | Reserved | 3 | |

The VM runs `BlueprintEncoder.encodeData(blueprint, registers)` and stores the result with `set`. The register then holds:

```
[N (32 bytes)][ABI encoding (N bytes)]
```

For an ABI-conformant blueprint, this is the in-memory `bytes` produced by `abi.encode(args...)`, including its length word. An empty blueprint yields one zero word (`N = 0`). When `N` is a multiple of 32, which holds whenever every dynamic operand is padded, the register is also a valid dynamic blob. A blueprint can then pass it on as a `bytes` argument.

### REMAINING_GAS (7)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Destination register | 1 | Receives the gas value. High bit ignored. |
| 1–31 | Reserved | 31 | |

Stores `gasleft()`, the gas remaining in the current call frame at the point the instruction executes, as a 32-byte `uint256` word.

### NATIVE_BALANCE (8)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Address register | 1 | Holds the address to query. High bit ignored. |
| 1 | Destination register | 1 | Receives the balance. High bit ignored. |
| 2–31 | Reserved | 30 | |

The address register must be exactly 32 bytes, else `InvalidAddressBytes()`. The low 20 bytes are the address, and the upper 12 bytes are ignored. The VM stores `address.balance` as a 32-byte `uint256` word. The void register queries `address(0)`.

### LOG (9)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0 | Variant | 1 | `LogVariant` value `0`–`5`. |
| 1–26 | Source registers | 26 | One register byte each. The variant decides how many are read, starting at byte 1. High bits ignored. |
| 27–31 | Reserved | 5 | |

| Variant | Name | Registers read | Event emitted |
|---|---|---|---|
| 0 | `STATIC_1` | byte 1 | `VMLogStatic1(bytes32 data1)` |
| 1 | `STATIC_2` | bytes 1–2 | `VMLogStatic2(bytes32 data1, bytes32 data2)` |
| 2 | `STATIC_3` | bytes 1–3 | `VMLogStatic3(bytes32 data1, bytes32 data2, bytes32 data3)` |
| 3 | `STATIC_4` | bytes 1–4 | `VMLogStatic4(bytes32 data1, bytes32 data2, bytes32 data3, bytes32 data4)` |
| 4 | `STATIC_5` | bytes 1–5 | `VMLogStatic5(bytes32 data1, bytes32 data2, bytes32 data3, bytes32 data4, bytes32 data5)` |
| 5 | `DYNAMIC` | byte 1 | `VMLogDyn(bytes data)` |

A variant above 5 reverts `InvalidLogVariant()`. Static variants read each register with `getStatic`, so each must be exactly 32 bytes, else `InvalidStaticData()`. `DYNAMIC` emits the register's raw bytes, whatever their length. The events are declared in `VMLogLib` (`src/VMLogLib.sol`). Behind a proxy, the proxy's address emits them.

### SAFE_TRANSFER (10)

| Bytes | Field | Size | Description |
|---|---|---|---|
| 0–19 | Token | 20 | ERC-20 token address. |
| 20 | Recipient register | 1 | Holds the recipient address. High bit ignored. |
| 21 | Amount register | 1 | Holds the amount as a 32-byte word. High bit ignored. |
| 22–31 | Reserved | 10 | |

`SafeTransferVMLib.execute` (`src/SafeTransferLib.sol`) transfers `amount` of `token` from the executing contract's own balance. There is no source-of-funds operand: the payer is always `address(this)`, which is the proxy when the VM runs behind `MinimalProxy`.

- The recipient register must be exactly 32 bytes, else `InvalidAddressBytes()`. Only its low 20 bytes are used.
- The amount register is read with `getStatic`. It must be exactly 32 bytes, else `InvalidStaticData()`.
- The void register reads as a zero word, which gives recipient `address(0)` or amount `0` rather than a revert.
- The transfer uses Solady's `SafeTransferLib.safeTransfer`. It accepts a successful call that returns `true` or returns no data. It reverts `TransferFailed()` when the call reverts, when it returns anything else, or when the token has no code.
- A zero amount is an ordinary transfer of zero. Whether it succeeds is up to the token.
- `SAFE_TRANSFER` writes no register and returns no data.

`snapshots/vmBenchmarks.json` has no entry for this opcode. Its cost is dominated by the token's own `transfer`.

## Blueprints

`CALLDATA_BUILD` and `ABI_ENCODE` describe their output with a **blueprint**, a byte string of tokens interpreted by `src/BlueprintEncoder.sol`. Every byte value is a valid token:

| Token | Name | Meaning |
|---|---|---|
| `0x00`–`0x7A` | Static register | Register `token` (index `0x7A` is void) is one 32-byte head word. It must be exactly 32 bytes, else `BadStaticFormat(index)`. |
| `0x7B` | `END_DYNAMIC` | Closes the innermost open container of any kind. |
| `0x7C` | `START_ARRAY_DYNAMIC` | Opens a dynamic array `T[]`: a pointer in the parent head, then `[length][elements]` in the parent tail. |
| `0x7D` | `START_ARRAY_STATIC` | Opens a fixed-size array `T[k]`, encoded inline in the parent head. |
| `0x7E` | `START_TUPLE_DYNAMIC` | Opens a dynamic tuple: a pointer in the parent head, then the tuple's head and tail in the parent tail. |
| `0x7F` | `START_TUPLE_STATIC` | Opens a static tuple, encoded inline in the parent head. |
| `0x80`–`0xFF` | Dynamic register | Register `token & 0x7F` is a dynamic blob. It must be at least 32 bytes, else `BadDynamicFormat(index)`. The encoder writes a pointer in the head and copies the blob into the tail. |

Consequences of the token map:

- Registers `0x7B`–`0x7F` can appear in a blueprint only as dynamic operands (`0xFB`–`0xFF`), because their static token values are container tokens.
- Each array element is one register token or one closed child container. The encoder writes the element count of a dynamic array.
- The encoder copies a dynamic blob by its exact byte length and advances the tail by that length. It does not check that the length is a multiple of 32, so an unpadded blob misaligns everything after it.

Limits and errors:

| Rule | Error on violation |
|---|---|
| Blueprint length is at most 22 bytes (`CALLDATA_BUILD`) or 27 bytes (`ABI_ENCODE`). | `BlueprintTooLarge()`, on unpack |
| At most 11 containers are open at once (`MAX_STACK_DEPTH = 12`, which includes the root frame). | `StackOverflow()` |
| At most 10 dynamic containers (`0x7C`, `0x7E`) per blueprint (`MAX_DYN_HEADS`). | `DynHeadBufOverflow()` |
| `END_DYNAMIC` must close an open container. | `StackUnderflow()` |
| Every opened container must be closed before the blueprint ends. | `UnclosedContainer()` |

`InvalidToken()` and `BufferTooSmall(uint256,uint256)` are defensive guards. `InvalidToken()` is unreachable because every byte value is a token. `BufferTooSmall` guards consistency between the measuring pass and the writing pass.

`*_STATIC` containers always encode inline. Placing a dynamic operand inside one produces output that differs from `abi.encode`. For an ABI-conformant fixed-size array of a dynamic type, such as `bytes[2]`, use `START_TUPLE_DYNAMIC`.

For the exact head, tail and pointer layout of every container, see [ABI Memory Layout](./abi_memory_layouts.md).

Example: calldata for `f(uint256 id, (uint256,bytes) data, uint256[] amounts)`, with `id` in `r0`, the tuple fields in `r1` (static) and `r2` (dynamic), and the array elements in `r3`–`r5`:

```
00 7E 01 82 7B 7C 03 04 05 7B
```

## Padding and Reserved-Bit Policy

The *Reserved* rows in the layouts above are zero by convention. The VM enforces this for only one opcode:

- **`EXPLODE` rejects any nonzero reserved bit** with `NonZeroPadding()`. This covers the source-register high bit (byte 0), the unused destination slots (bytes `2 + count` through 27), and bytes 28–31. `packExplode` rejects a flagged source register the same way, so the packer never produces a word the unpacker refuses.
- **Every other opcode ignores its reserved bits.** The other unpackers read only the fields they use and never revert on nonzero padding, unused blueprint bytes, unused descriptor slots, unused log register bytes, or a set high bit on a register field that does not use it.

Producers should zero all reserved regions anyway. `EXPLODE` has the strict check because it is the only command whose word carries a variable-length run of operands, so a canonical, non-malleable encoding matters most there. The check changes no execution result, since `ExplodeLib` never reads the reserved region. It guarantees that each command has exactly one valid word, and it keeps the region free for future use.

## Register Canonicality

**A register is a byte string with a length, not a validated ABI value.** The VM guarantees memory safety and bounds on every register it writes. It does not guarantee that a register holds the canonical ABI encoding of the value it nominally represents. Two instructions write registers from data an external party controls, and neither establishes canonicality:

- **`CALL` with a dynamic destination.** `setDynamic` checks only `returndata.length >= 0x40` and word 0 `== 0x20`. It never compares the length word (word 1) with the bytes that follow. A callee returning `[0x20][0x20][three payload words]` produces a 128-byte register whose length word says 32. A callee returning `[0x20][0x20]` with no payload produces a 32-byte register that declares 32 bytes of payload it does not contain. Both are accepted.
- **`EXPLODE` with a dynamic destination.** The slice extent comes from the surrounding head offsets and is never compared with the field's own length word; see [What EXPLODE does not validate](#what-explode-does-not-validate).

The consumers do not close the gap. For a dynamic operand, `ABI_ENCODE` and `CALLDATA_BUILD` require only `length >= 32` and copy the register by its actual byte length. A non-canonical register therefore propagates into the payload as chosen bytes in ABI dead space, overlapping fields, or an inflated payload.

**This is permitted by design.** Neither producer can validate canonicality without type information the ISA does not carry, and `abi.decode` of the affected payloads still yields the intended logical values. The rule for producers and consumers:

> Do not hash, sign, or byte-compare a payload built from a register that a `CALL` or an `EXPLODE` wrote, without re-validating it. Decode it instead.

Programs that only decode are unaffected. The exposure is limited to consumers that depend on canonical bytes, such as code that hashes or signs built calldata, or a callee that slices `calldata` by offset instead of decoding it.

## Companion contracts

Two stateless helper contracts extend the VM. Programs call them with `CALL` (usually `STATICCALL`), using calldata built by `CALLDATA_BUILD`, and store the `uint256` result through a clear destination high bit.

### ArithmeticProcessor (RPN)

`src/RPNArithmetic.sol` evaluates a Reverse Polish Notation expression over `uint256` values:

```solidity
function evaluateRPN(uint256[] calldata regValues, bytes32 rpnStream, uint8 rpnLen)
    external pure returns (uint256 result);
```

The processor reads `rpnLen` tokens from `rpnStream`, starting at byte 0 (the most significant byte). `rpnLen` must be at most 32, else `TooManyOpcodes(rpnLen, 32)`.

| Token | Meaning |
|---|---|
| `0x80 \| i` | Push `regValues[i]`. `i >= regValues.length` reverts `RegIndexOOB(i)`. |
| `0x00` `ADD` | `a + b` |
| `0x01` `SUB` | `a - b` |
| `0x02` `MUL` | `a * b` |
| `0x03` `DIV_DOWN` | `a / b`, rounded down. `b == 0` reverts `DivByZero()`. |
| `0x04` `DIV_UP` | `a / b`, rounded up (`0` when `a == 0`). `b == 0` reverts `DivByZero()`. |
| `0x05` `MIN` | `min(a, b)` |
| `0x06` `MAX` | `max(a, b)` |
| `0x07`–`0x7F` | `InvalidOpcode(op)` |

Each operator pops `b` (the top of the stack), then `a`, and pushes the result. Arithmetic is checked, so overflow and underflow revert with `Panic(0x11)`. An operator with fewer than two values on the stack reverts `StackUnderflow()`. After the last token:

- an empty `regValues` reverts `MissingDestReg()`;
- a stack that does not hold exactly one value reverts `InvalidRPNStack()`.

Example: `(r0 + r1) * r2 / r3`, rounded down, is `80 81 00 82 02 83 03` with `rpnLen = 7`.

### InvariantChecker

`src/InvariantChecker.sol` reverts when a comparison fails. It offers single assertions (`assertEqual`, `assertNotEqual`, `assertLessThan`, `assertGreaterThan`, `assertLessThanEqual`, `assertGreaterThanEqual`, `assertInRange`) and two batch forms:

```solidity
function batchAssert(uint8[] calldata ops, uint256[] calldata values) external pure;
function batchAssertPacked(uint256 packedOps, uint8 opCount, uint256[] calldata values) external pure;
```

`batchAssertPacked` reads `opCount` one-byte ops from `packedOps`, starting at the most significant byte. `opCount` must be at most 32, else `TooManyOperations()`. `batchAssert` takes the ops as an array instead. Each op consumes values from `values` in order. Every op, including `0`, first reads the value at the current position, so running out of values reverts with `Panic(0x32)`.

| Op | Check | Values consumed | Error |
|---|---|---|---|
| 0 | none | 0 | |
| 1 | `a == b` | 2 | `AssertEqFailed(a, b)` |
| 2 | `a != b` | 2 | `AssertNeqFailed(a, b)` |
| 3 | `a < b` | 2 | `AssertLtFailed(a, b)` |
| 4 | `a > b` | 2 | `AssertGtFailed(a, b)` |
| 5 | `a <= b` | 2 | `AssertLteFailed(a, b)` |
| 6 | `a >= b` | 2 | `AssertGteFailed(a, b)` |
| 7 | `min <= v <= max` | 3 (`v, min, max`) | `AssertRangeFailed(v, min, max)` |
| 8–255 | | | `UnknownOpcode(op)` |

## Error reference

| Error | Source | Raised when |
|---|---|---|
| `Disallowed()` | `VmErrors` | `CALL` with call type `DELEGATECALL`. |
| `InvalidCallDataLength()` | `VmErrors` | `CALL` source register is shorter than 32 bytes. |
| `InvalidOpcode(uint8)` | `VmErrors` | Fallback arm for an unknown `op`. |
| `BlueprintTooLarge()` | `VmErrors` | Blueprint length above 22 (`CALLDATA_BUILD`) or 27 (`ABI_ENCODE`). |
| `DestinationCountOutOfBounds(uint8)` | `VmErrors` | `EXPLODE` count outside `[1, 26]`. |
| `NonZeroPadding()` | `VmErrors` | `EXPLODE` reserved bit set. |
| `InvalidRegisterLength()` | `VmErrors` | `EXPLODE` source length is not a multiple of 32. |
| `OutOfBounds()` | `VmErrors` | `EXPLODE` head or offset violation; `CALLDATA_SURGERY` window past the end of the source. |
| `TooManySurgeries()` | `VmErrors` | Surgery count above 6. |
| `ReplacementTooLarge()` | `VmErrors` | Surgery replacement longer than its window. |
| `InvalidLogVariant()` | `VmErrors` | `LOG` variant above 5. |
| `InvalidAddressBytes()` | `VmErrors` | Address register is not exactly 32 bytes (`NATIVE_BALANCE`, `SAFE_TRANSFER`). |
| `CallToNonContract()` | `VmErrors` | `DEPOSIT_APPROVED` token has no code. |
| `GetBalanceFailed()` | `VmErrors` | `DEPOSIT_APPROVED` cannot read the executing contract's token balance. |
| `DestinationCountMismatch(uint8,uint256)` | `VmErrors` | `packExplode` only: fewer destination registers than the count. |
| `SourceRegistersExceed208Bits()` | `VmErrors` | `packLog` only: the register bytes do not fit in bytes 1–26. |
| `RegisterIndexOOB()` | `RegisterFile` | Register index at or beyond `registers.length` (other than `0x7A`). |
| `InvalidStaticData()` | `RegisterFile` | Register read with `getStatic` is not exactly 32 bytes. |
| `InvalidDynamicData()` | `RegisterFile` | `CALL` dynamic destination: return data shorter than 64 bytes, or word 0 not `0x20`. |
| `BadStaticFormat(uint8)` | `BlueprintEncoder` | Static blueprint operand is not exactly 32 bytes. |
| `BadDynamicFormat(uint8)` | `BlueprintEncoder` | Dynamic blueprint operand is shorter than 32 bytes. |
| `StackOverflow()`, `StackUnderflow()`, `DynHeadBufOverflow()`, `UnclosedContainer()` | `BlueprintEncoder` | Blueprint structure errors; see [Blueprints](#blueprints). |
| `TransferFailed()` | Solady `SafeTransferLib` | `SAFE_TRANSFER` failed. |
| `TransferFromFailed()` | Solady `SafeTransferLib` | `DEPOSIT_APPROVED` `transferFrom` failed. |
| `Panic(0x21)` | Solidity | `CALL` call type above 3. |
