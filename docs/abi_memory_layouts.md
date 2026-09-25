# ABI Memory Layout

This document specifies the bytes that `BlueprintEncoder` (`src/BlueprintEncoder.sol`) writes for the `CALLDATA_BUILD` and `ABI_ENCODE` instructions, and the register shapes it expects as input. The blueprint token format, limits and errors are specified under [Blueprints](./isa.md#blueprints) in the ISA.

The encoder is not a general-purpose ABI encoder. The blueprint fixes the structure, and the registers supply pre-encoded words and blobs. The encoder never pads, reorders or repairs register contents. For an ABI-conformant blueprint over well-formed registers, its output matches Solidity's `abi.encode` / `abi.encodeWithSelector` byte for byte.

## 1. Output register

Both instructions store a register whose first 32-byte word is the payload length, followed by the payload:

```
CALLDATA_BUILD:  [4 + H + T (32 bytes)][selector (4)][head (H)][tail (T)]
ABI_ENCODE:      [H + T     (32 bytes)][head (H)][tail (T)]
```

| | `CALLDATA_BUILD` | `ABI_ENCODE` |
|---|---|---|
| Head starts at register byte | 36 | 32 |
| Tail starts at register byte | 36 + H | 32 + H |
| Empty blueprint | `[4][selector]` | `[0]` (one zero word) |

This is the in-memory form of a Solidity `bytes` value, including its length word: `abi.encodeWithSelector(selector, args...)` and `abi.encode(args...)` respectively. `CALL` sends the `4 + H + T` bytes after the length word as calldata.

## 2. Offsets

A dynamic value is referenced from its parent's head by a **32-byte unsigned byte offset**. The offset is measured from a base that depends on the enclosing container:

| Enclosing container | Offset base |
|---|---|
| Root (the blueprint's top level) | First head byte, i.e. the byte after the selector for `CALLDATA_BUILD`. |
| Dynamic tuple (`0x7E`) | First byte of the tuple's head, which is where the parent's offset points. |
| Dynamic array (`0x7C`) | The byte after the array's 32-byte element-count word. |
| Static tuple (`0x7F`) or static array (`0x7D`) | The container's own first inline head byte. This matters only when a dynamic operand sits inside a static container, which is not ABI-conformant (see section 4). |

These bases match the Solidity ABI specification.

## 3. Register operands

### Static operand (token `0x00`–`0x7A`)

- The register must be exactly **32 bytes**, else `BadStaticFormat(index)`.
- It is copied verbatim into the current head slot.
- It must already be a correct ABI word:

| Type | Word format |
|---|---|
| `uintN` | Right-aligned, zero-extended. |
| `intN` | Right-aligned, sign-extended two's complement. |
| `address` | Right-aligned 20 bytes, upper 12 bytes zero. |
| `bool` | `0` or `1`. |
| `bytesN` | Left-aligned, zero-padded on the right. |

The void register (`0x7A`) is a zero word.

### Dynamic operand (token `0x80`–`0xFF`, register `token & 0x7F`)

- The register must hold the complete ABI **tail** of a dynamic value. For `bytes` and `string` this is:

  ```
  [byte length (32)][data][zero padding to a multiple of 32]
  ```

  For a dynamic array `T[]` it is `[element count (32)][element heads][element tails]`, and for a dynamic tuple it is `[tuple head][tuple tail]`.
- The encoder writes an offset into the current head slot and appends the register's bytes, unchanged, to the tail.
- The only check is a minimum length of 32 bytes, else `BadDynamicFormat(index)`. The length is **not** checked to be a multiple of 32. The tail advances by the register's exact byte length, so an unpadded blob misaligns every value after it.
- The void register is one zero word, which encodes an empty `bytes`, `string` or array.

Registers in this shape come from:

- `CALL` with the destination high bit set (`RegisterFile.setDynamic` strips the leading `0x20` offset word from a single-dynamic-value return);
- `EXPLODE` with a dynamic destination (the tail slice of the source);
- `ABI_ENCODE` (its output register is a `bytes` tail whose contents are the encoding, provided the payload is word-aligned);
- the initial register file supplied by the caller.

A `CALLDATA_BUILD` result is `36 + H + T` bytes long, so it is not word-aligned and is not a valid dynamic operand.

## 4. Containers

| Token | Container | Parent head holds | Child block | Length word | Offset base |
|---|---|---|---|---|---|
| `0x7F` | Static tuple | The fields' head words, inline | None | No | n/a |
| `0x7D` | Static array `T[k]` | The elements' head words, inline | None | No | n/a |
| `0x7E` | Dynamic tuple, or `T[k]` with dynamic `T` | 32-byte offset | `[head][tail]`, appended to the parent tail | No | Tuple head start |
| `0x7C` | Dynamic array `T[]` | 32-byte offset | `[count][element heads][element tails]`, appended to the parent tail | Yes (element count) | Byte after the count word |

`0x7B` closes the innermost open container.

### Static tuple (`0x7F`) and static array (`0x7D`)

- Encoded inline in the parent head: each static field or element contributes its 32-byte word.
- There is no length word. The number of elements is the number of tokens (or closed child containers) between the opener and `0x7B`.
- Both tokens behave identically; they differ only in intent.
- **Dynamic members make the output non-ABI.** The encoder writes an offset in the inline head, measured from the container's inline start, and appends the member's blob to the parent tail. The ABI instead treats any tuple or fixed array with a dynamic member as dynamic and references it by offset. For those types, use `0x7E`.

### Dynamic tuple (`0x7E`)

- The parent head holds an offset to a block `[tuple head][tuple tail]` in the parent tail.
- Inside the block, static fields are inline in the tuple head, and dynamic fields are offsets, relative to the tuple head start, to data in the tuple tail.
- There is no length word.
- A fixed-size array of a dynamic type, such as `bytes[2]` or `string[3]`, has exactly this encoding in the ABI. Encode it with `0x7E`, not `0x7D`.

### Dynamic array (`0x7C`)

- The parent head holds an offset to an array block in the parent tail.
- The block starts with the element count. The encoder counts the register tokens and closed child containers inside the array and writes that count.
- **Static elements:** `[count][elem0][elem1]…`, with no per-element tail.
- **Dynamic elements:** `[count][one offset per element][element tails]`. Each offset is measured from the byte after the count word.

## 5. Worked examples

Each example shows an `ABI_ENCODE` payload. Offsets in the left column are relative to the payload start, i.e. register byte 32. The register's first word, not shown, is the payload length.

**`uint256[]` = `[10, 20]`.** Registers `r0 = 10`, `r1 = 20`. Blueprint `7C 00 01 7B`. Payload length `0x80`.

```
0x00  0x20   offset of the array block (root base 0x00)
0x20  0x02   element count
0x40  10     element 0
0x60  20     element 1
```

**`string[]` = `["hello", "world"]`.** Registers `r0` and `r1` each hold `[0x05]["hello"/"world" padded to 32 bytes]`. Blueprint `7C 80 81 7B`. Payload length `0x100`.

```
0x00  0x20   offset of the array block (root base 0x00)
0x20  0x02   element count
0x40  0x40   offset of element 0, base 0x40 -> 0x80
0x60  0x80   offset of element 1, base 0x40 -> 0xC0
0x80  0x05   "hello" length
0xA0  "hello" + zero padding
0xC0  0x05   "world" length
0xE0  "world" + zero padding
```

**`(string, uint256)` = `("hello", 42)`.** Register `r0` holds `[0x05]["hello" padded]`, and `r1 = 42`. Blueprint `7E 80 01 7B`. Payload length `0xA0`.

```
0x00  0x20   offset of the tuple block (root base 0x00)
0x20  0x40   offset of the string, base 0x20 -> 0x60
0x40  0x2a   42, inline in the tuple head
0x60  0x05   "hello" length
0x80  "hello" + zero padding
```

`bytes[2]` encoded with `7E 80 81 7B` has the same shape: two offsets based at the tuple head start, followed by the two blobs, with no count word.

**`(uint256, bytes)` at the top level.** With `r0 = 7`, `r1 = [0x04][0xdeadbeef padded]`, and blueprint `00 81`, the blueprint has no containers:

```
0x00  7      r0
0x20  0x40   offset of the bytes value (root base 0x00)
0x40  0x04   length
0x60  0xdeadbeef + zero padding
```

With `CALLDATA_BUILD`, the same blueprint yields `[0x84][selector][these 0x80 bytes]`, and the offsets are unchanged because the root base is the byte after the selector.

## 6. Composite values cannot be one static register

A static register is exactly one word. A multi-word static value, such as a static tuple `(bytes32, bytes32)` or a static array `uint256[3]`, cannot be supplied as a single static register. Marking it dynamic does not help either: the encoder would write an offset and copy the bytes to the tail, which is not the ABI encoding of a static composite.

Supply each word as its own register and compose the value with `0x7F` or `0x7D`. If the composite is already held in one register, for example as a call's return data, split it into word registers with `EXPLODE` first.

## 7. Checklist

- Static operands are exactly 32 bytes and already in ABI word format.
- Dynamic operands are complete ABI tails, padded to a multiple of 32 bytes.
- Offsets are relative to the enclosing container's head start, or to the byte after the count word for dynamic arrays.
- Use `0x7E` for tuples with dynamic members and for fixed-size arrays of dynamic types; reserve `0x7F` and `0x7D` for all-static contents.
- Build multi-word static values from per-word registers with container tokens, not from one register.
