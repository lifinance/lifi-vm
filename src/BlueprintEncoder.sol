// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './RegisterHelpers.sol';
import './RegisterFile.sol';

/// @title  BlueprintEncoder
/// @custom:version 1.0.0
///
/// @notice A specialized, gas-efficient ABI encoder that uses a custom Domain
/// Specific Language (DSL) called a "blueprint" to construct calldata.
/// @dev    This library is not a general-purpose ABI encoder. It is designed for
/// applications where the structure of the calldata is
/// known in advance. The caller must prepare all data in `registers`
/// beforehand and provide a `blueprint` that dictates the final layout.
///
/// CONCEPT OVERVIEW:
///
/// 1. Blueprint: A `bytes` array that acts as a set of instructions. It contains
/// a sequence of tokens that define the structure of the output.
///
/// 2. Registers: An array of `bytes` (`bytes[]`) that serves as a data source.
/// The blueprint references items in this array by their index. Each register
/// must be pre-formatted according to its type (static or dynamic).
///
/// 3. Tokens: The blueprint is composed of two categories of tokens (bytes):
///
/// A. Register Tokens (0x00 - 0x79): These bytes are indices into the
/// `registers` array. The 7th bit acts as a flag:
/// - Bit 7 clear (0b0...): The token points to a *static* register, which
/// is expected to be exactly 32 bytes long.
/// - Bit 7 set   (0b1...): The token points to a *dynamic* register. The
/// register itself must be a self-contained, length-prefixed ABI blob
/// (i.e., `length | data | padding`).
///
/// B. Container Tokens (0x7B - 0x7F): These are control tokens that define
/// the start and end of tuples and arrays, allowing for nested data
/// structures.
///
/// ENCODING PROCESS:
///
/// The encoder uses a two-pass system:
///
/// - Fast Path (Flat Blueprint): If the blueprint contains no container tokens,
/// the encoder performs a single pass. It calculates the total size and writes
/// the data in one go, minimizing overhead.
///
/// - General Case (Nested Blueprint): For blueprints with nested structures,
/// a two-pass "measure-then-write" approach is used:
/// 1. Measure Pass (`_measure`): Traverses the blueprint to calculate the
/// exact size of the head and tail sections of the final payload without
/// writing any data. It uses a stack to handle nested containers and
/// records the dimensions of dynamic structures.
/// 2. Encode Pass (`_encodeCore`): Allocates a single buffer of the exact
/// required size and then performs a second traversal of the blueprint to
/// write the data, using the measurements from the first pass to correctly
/// place all pointers and data.
///
/// This two-pass system ensures that the entire payload can be constructed with
/// a single memory allocation.
///
/// HOW TO USE THE BLUEPRINT DSL:
///
/// The blueprint DSL is designed for applications where you need to construct
/// ABI-encoded calldata or data blobs from pre-prepared register values. Here's
/// how to use it effectively:
///
/// 1. **Prepare Your Data in Registers**: Before creating a blueprint, store all
/// your data in the `registers` array. Each register must be properly formatted:
/// - Static registers: Exactly 32 bytes (e.g., `abi.encode(uint256)`)
/// - Dynamic registers: First `abi.encode()` the data, then use `setDynamic()`
///   to create the length-prefixed blob
///
/// 2. **Construct the Blueprint**: Create a byte sequence using tokens:
/// - `0x00-0x79`: Static register indices (bit 7 clear)
/// - `0x80-0xF9`: Dynamic register indices (bit 7 set, actual index = value & 0x7F)
/// - `0x7F`: Start static tuple `(...)`
/// - `0x7E`: Start dynamic tuple `(...)`
/// - `0x7D`: Start static array `[...]`
/// - `0x7C`: Start dynamic array `[...]`
/// - `0x7B`: End any container
///
/// **Example 1 - Simple Function Call:**
/// ```solidity
/// // Function: transfer(address to, uint256 amount)
/// bytes[] memory registers = new bytes[](2);
/// registers[0] = abi.encode(address(0x123...)); // to address
/// registers[1] = abi.encode(uint256(1000));     // amount
///
/// bytes memory blueprint = abi.encodePacked(
///     uint8(0), // static register 0 (address)
///     uint8(1)  // static register 1 (amount)
/// );
///
/// bytes memory calldata = BlueprintEncoder.encodeFromBlueprint(
///     bytes4(keccak256("transfer(address,uint256)")),
///     blueprint,
///     registers
/// );
/// ```
///
/// **Example 2 - Dynamic Data with Nested Structures:**
/// ```solidity
/// // Function: processData(uint256 id, (uint256 value, bytes data), uint256[] amounts)
/// bytes[] memory registers = new bytes[](6);
/// registers[0] = abi.encode(uint256(42));           // id
/// registers[1] = abi.encode(uint256(100));          // tuple.value
/// registers.setDynamic(2, abi.encode(bytes("hello"))); // tuple.data (note: setDynamic after abi.encode)
/// registers[3] = abi.encode(uint256(10));           // amounts[0]
/// registers[4] = abi.encode(uint256(20));           // amounts[1]
/// registers[5] = abi.encode(uint256(30));           // amounts[2]
///
/// bytes memory blueprint = abi.encodePacked(
///     uint8(0),    // static register 0 (id)
///     uint8(0x7E), // START_TUPLE_DYNAMIC (tuple begins)
///         uint8(1),    // static register 1 (tuple.value)
///         uint8(0x82), // dynamic register 2 (tuple.data, 2 | 0x80)
///     uint8(0x7B), // END_DYNAMIC (tuple ends)
///     uint8(0x7C), // START_ARRAY_DYNAMIC (array begins)
///         uint8(3),    // static register 3 (amounts[0])
///         uint8(4),    // static register 4 (amounts[1])
///         uint8(5),    // static register 5 (amounts[2])
///     uint8(0x7B)  // END_DYNAMIC (array ends)
/// );
/// ```
///
/// FIXED-SIZE ARRAYS WITH DYNAMIC ELEMENTS
///
/// ABI rule: A fixed-size array T[k] is encoded exactly like a k-tuple of T.
/// If T is dynamic (bytes, string, or a tuple containing any dynamic), then T[k]
/// is a dynamic container: the parent stores a pointer; the child region holds a
/// tuple head of k element heads followed by element tails. There is NO array
/// length word. Spec: https://docs.soliditylang.org/en/latest/abi-spec.html
///
/// Offset bases:
/// - Tuple (and fixed array encoded-as-tuple): element offsets are relative to the
///   start of the tuple head (the start of the child region the pointer targets).
/// - Dynamic array: element offsets are relative to the start of the array head
///   AFTER the 32-byte length word.
///
/// ENCODER DESIGN (DIVERGES FROM ABI WHEN REQUESTED BY BLUEPRINT)
/// - START_ARRAY_STATIC: always inlines in the parent head, treating contents as static
///   regardless of element tokens. Using this with dynamic elements is NON-ABI and
///   will not match Solidity's abi.encode.
/// - START_TUPLE_DYNAMIC: encodes via a pointer (child region in parent's tail),
///   matching ABI for fixed-size arrays whose element type is dynamic and for tuples
///   that contain dynamics.
///
/// Guidance:
/// - To match ABI for T[k] where T is dynamic (e.g., bytes[2], string[3], (bytes,uint)[k]),
///   use START_TUPLE_DYNAMIC ... END, not START_ARRAY_STATIC.
///
/// CONTAINER ENCODING REFERENCE
///
/// Legend:
/// - Parent head: what is written at the container's slot in the parent.
/// - Child region: content at the pointer target (if any).
/// - Offset base: where element offsets are measured from.
///
/// | Kind                              | Parent head                  | Child region start                          | Pointer | Length word | Offset base                              | Notes |
/// |-----------------------------------|------------------------------|---------------------------------------------|---------|-------------|-------------------------------------------|-------|
/// | Static tuple (all static types)   | Inline (no pointer, no tail) | —                                           | No      | No          | n/a                                       | e.g., (uint,address) |
/// | Dynamic tuple (any dynamic type)  | 32-byte pointer              | Tuple head (k element head words)           | Yes     | No          | Tuple head start                          |       |
/// | Static array of static T[k]       | Inline (no pointer, no tail) | —                                           | No      | No          | n/a                                       | e.g., uint[3] |
/// | Static array of dynamic T[k]      | 32-byte pointer              | Tuple head of k element heads               | Yes     | No          | Tuple head start                          | ABI = k-tuple of T |
/// | Dynamic array of static T[]       | 32-byte pointer              | [length][elements inline]                   | Yes     | Yes (first) | n/a (no per-element heads)                |       |
/// | Dynamic array of dynamic T[]      | 32-byte pointer              | [length][k element head words]              | Yes     | Yes (first) | Array head start + 32 (after length)      |       |
/// | Dynamic scalar (bytes/string)     | 32-byte pointer (as element) | [length][data]                              | Yes*    | Yes         | n/a                                       | *Top-level abi.encode = [0x20][length][data] |
///
/// Notes:
/// - "Inline (no pointer, no tail)" means the entire encoding is the fixed head words written in place.
/// - bytes/string always carry their own 32-byte length before data.
/// - Fixed arrays of dynamic types are encoded exactly like tuples of the same arity.
/// - In this encoder, START_ARRAY_STATIC always inlines, even if children are dynamic. For ABI parity,
///   use START_TUPLE_DYNAMIC for fixed arrays of dynamic types.
///
/// MEMORY LAYOUT EXAMPLES (annotated bases)
///
/// 1) Dynamic array of static uint256[] = [10, 20]
/// 0x00: [0x20]                 pointer to array region (base A = 0x20)
/// A+0x00: [0x02]               length = 2
/// A+0x20: [10]                 element 0 (inline)
/// A+0x40: [20]                 element 1 (inline)
///
/// 2) Dynamic array of dynamic string[] = ["hello","world"]
/// 0x00: [0x20]                 pointer to array region (base A = 0x20)
/// A+0x00: [0x02]               length = 2
/// (element offset base = A+0x20)
/// A+0x20: [0x40]               off elem0 -> (A+0x20)+0x40 = A+0x60 = 0x80
/// A+0x40: [0x80]               off elem1 -> (A+0x20)+0x80 = A+0xA0 = 0xC0
/// A+0x60: [0x05]["hello"...]   string payload (length + data)
/// A+0xA0: [0x05]["world"...]   string payload (length + data)
///
/// 3) Static array of dynamic bytes[2] = [0x1234, 0x5678] (ABI form = tuple)
/// 0x00: [0x20]                 pointer to tuple region (base B = 0x20)
/// (element offset base = B)
/// B+0x00: [0x40]               off elem0 -> B+0x40 = 0x60
/// B+0x20: [0x80]               off elem1 -> B+0x80 = 0xA0
/// B+0x40: [0x02][0x1234..]     bytes payload (length + data)
/// B+0x80: [0x02][0x5678..]     bytes payload (length + data)
/// (No array length word, unlike dynamic arrays)
///
/// 4) Dynamic scalar bytes = 0xdeadbeef (as an element in a parent)
/// Parent writes: [offset]      pointer to bytes data
/// At offset: [0x04][0xdeadbeef000...] length=4, data padded to 32 bytes
/// (Top-level abi.encode(bytes): [0x20][0x04][0xdeadbeef000...])
///
/// 5) Dynamic tuple (string,uint256) = ("hello", 42)
/// 0x00: [0x20]                 pointer to tuple region (base T = 0x20)
/// T+0x00: [0x40]               off "hello" (relative to T) -> T+0x40 = 0x60
/// T+0x20: [0x2a]               uint256 = 42 (static in head)
/// T+0x40: [0x05]["hello"...]   string payload (length + data)
///
/// 6) Static array uint256[2] = [10, 20]
/// Parent head words: [uint256=10][uint256=20]; no pointer; no child region or length word.
///
/// 7) Static tuple (uint256,address) = (100, 0x1234…7890)
/// Parent head words: [uint256=100][address=0x1234…7890]; no pointer; no child region or length word.
///
/// KEY POINTS
/// - Static containers (*_STATIC) encode inline here by design. If you place dynamic
///   elements inside them, the result diverges from abi.encode on purpose.
/// - Dynamic containers (*_DYNAMIC) emit a 32-byte pointer in the parent head and
///   place the child region in the parent's tail.
/// - Only START_ARRAY_DYNAMIC prepends a 32-byte length word to its child region.
/// - For ABI-compliant fixed arrays of dynamic types, use START_TUPLE_DYNAMIC.
/// - Offset bases: tuple/fixed-array-as-tuple -> tuple head start; dynamic array → array head start + 32.
library BlueprintEncoder {
    using RegisterHelpers for uint8;
    using RegisterFile for bytes[];
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    // A word in the EVM is 32 bytes.
    uint8 internal constant LEN_WORD = 32;

    // --- ABI encoding constants ---
    // Size of a function selector in bytes.
    uint8 internal constant SELECTOR_SIZE = 4;
    // Offset for writing data after length word + first data word (32 + 32 bytes).
    uint8 internal constant DATA_OFFSET = 0x40;

    // --- Register token boundaries ---
    // Maximum token value for static register indices (0x00 - 0x7A).
    uint8 internal constant MAX_STATIC_REGISTER_TOKEN = 0x7A;

    // --- Temporary buffer limits ---
    // Maximum number of dynamic containers that can be tracked in tmpDynHeads.
    uint8 internal constant MAX_DYN_HEADS = 10;

    // --- Bit-packing constants for `tmpDynHeads` and dynamic array metadata ---
    // The measurement pass needs to store metadata about dynamic containers. For
    // dynamic arrays, it must store both the head length and the element count.
    // To save space, these are packed into a single uint256 word.

    // Shift for element count: we shift the count left by 96 bits.
    uint8 internal constant SHIFT_CNT = 96;
    // Mask for head length: a 96-bit mask to extract the head length.
    uint256 internal constant MASK_LEN = (1 << 96) - 1;

    // --- Sizing Frame bit positions (for packed uint256 during measurement pass) ---
    // Shift amount for tail length field in Sizing Frame.
    uint8 internal constant SHIFT_SIZING_TAIL = 96;
    // Shift amount for ContainerKind field in Sizing Frame.
    uint8 internal constant SHIFT_SIZING_KIND = 192;

    // --- Encoding Frame bit positions (for packed uint256 during encoding pass) ---
    // Shift amount for current head offset field in Encoding Frame.
    uint8 internal constant SHIFT_FRAME_CUR_HEAD = 48;
    // Shift amount for tail start field in Encoding Frame.
    uint8 internal constant SHIFT_FRAME_TAIL_START = 96;
    // Shift amount for current tail offset field in Encoding Frame.
    uint8 internal constant SHIFT_FRAME_CUR_TAIL = 144;
    // Shift amount for ContainerKind field in Encoding Frame.
    uint8 internal constant SHIFT_FRAME_KIND = 192;

    /*//////////////////////////////////////////////////////////////////////////
                                BLUEPRINT TOKENS
    //////////////////////////////////////////////////////////////////////////*/

    /// Bit mask to check the "dynamic" flag on a register token (0x80 = 10000000).
    /// If `(token & REG_DYNAMIC_MASK) != 0`, it's a dynamic register.
    uint8 internal constant REG_DYNAMIC_MASK = 0x80;

    // --- Container Tokens (0x7B-0x7F) ---
    // These tokens control the opening and closing of tuples and arrays.
    // They are ordered to simplify range checks (e.g., `t >= START_ARRAY_DYNAMIC`).

    // Opening tokens for containers.
    uint8 internal constant START_TUPLE_STATIC = 0x7F; // "(...)" - encoded inline, no pointer.
    uint8 internal constant START_TUPLE_DYNAMIC = 0x7E; // "(...)" - pointer to tail data.
    // NOTE: START_ARRAY_STATIC always encodes inline, treating the structure as static.
    // For ABI-compliant encoding of T[k] where T is dynamic (e.g., bytes[2]),
    // use START_TUPLE_DYNAMIC which encodes with a pointer as per ABI specification.
    uint8 internal constant START_ARRAY_STATIC = 0x7D; // "[...]" - fixed-size, encoded inline.
    uint8 internal constant START_ARRAY_DYNAMIC = 0x7C; // "[...]" - pointer to tail data with length prefix.

    /// A single, shared token to close any container type.
    uint8 internal constant END_DYNAMIC = 0x7B;

    /*//////////////////////////////////////////////////////////////////////////
                                    LIMITS & MASKS
    //////////////////////////////////////////////////////////////////////////*/

    /// A safety limit to prevent excessively deep nesting, which could lead to
    /// stack exhaustion or denial-of-service. 12 levels is a generous limit.
    uint8 internal constant MAX_STACK_DEPTH = 12;

    // Masks for unpacking the Encoding Frame struct. The fields are 48 bits wide.
    uint256 internal constant MASK_48 = (1 << 48) - 1;
    // Mask for unpacking the Sizing Frame struct. The fields are 96 bits wide.
    uint256 internal constant MASK_96 = (1 << 96) - 1;

    /*//////////////////////////////////////////////////////////////////////////
                                        TYPES
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Identifies the type of container currently being processed on the stack
     * during either the measurement or encoding pass.
     */
    enum ContainerKind {
        NONE, // Root of the blueprint, not inside any container.
        DYNAMIC_ARRAY, // A dynamic array, e.g., `uint[]`. Encoded with a pointer and length.
        DYNAMIC_TUPLE, // A dynamic tuple. Encoded with a pointer.
        STATIC_ARRAY, // A fixed-size array, e.g., `uint[3]`. Encoded inline.
        STATIC_TUPLE // A static tuple. Encoded inline.
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error StackOverflow(); // Nesting depth exceeds MAX_STACK_DEPTH.
    error StackUnderflow(); // Encountered a closing token (END_DYNAMIC) without a matching opener.
    error DynHeadBufOverflow(); // The temporary buffer for dynamic head sizes is too small.
    error InvalidToken(); // Encountered a byte in the blueprint that is not a valid token.
    error UnclosedContainer(); // The blueprint ended while inside an open container.
    error BufferTooSmall(uint256 required, uint256 provided); // The output buffer is smaller than the required size.
    error BadStaticFormat(uint8 index); // A static register's length was not exactly 32 bytes.
    error BadDynamicFormat(uint8 index); // A dynamic register's length was less than 32 bytes (must be length-prefixed).

    /*//////////////////////////////////////////////////////////////////////////
                        PACKED SIZING FRAME (uint256) HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    // During the measurement pass (`_measure`), a stack of `uint256` is used to
    // track the sizes of nested containers. Each `uint256` is a packed struct
    // representing a "Sizing Frame". This avoids stack-too-deep errors.
    //
    // Sizing Frame Layout (uint256):
    // | Bits 255 - 192 (64) | Bits 191 - 96 (96) | Bits 95 - 0 (96) |
    // |---------------------|--------------------|------------------|
    // |   ContainerKind     |     tailLength     |    headLength    |

    /// @dev Constructs a packed Sizing Frame.
    function _mkSizing(uint256 headLen, uint256 tailLen, ContainerKind ct) internal pure returns (uint256 p) {
        assembly {
            p := or(or(headLen, shl(SHIFT_SIZING_TAIL, tailLen)), shl(SHIFT_SIZING_KIND, ct))
        }
    }

    /// @dev Extracts the head length from a Sizing Frame.
    function _szHead(uint256 p) internal pure returns (uint256) {
        return p & MASK_96;
    }

    /// @dev Extracts the tail length from a Sizing Frame.
    function _szTail(uint256 p) internal pure returns (uint256) {
        return (p >> SHIFT_SIZING_TAIL) & MASK_96;
    }

    /// @dev Extracts the ContainerKind from a Sizing Frame.
    function _szKind(uint256 p) internal pure returns (ContainerKind) {
        return ContainerKind(uint8(p >> SHIFT_SIZING_KIND));
    }

    /// @dev Increments the head length in a Sizing Frame.
    function _szAddHead(uint256 p, uint256 inc) internal pure returns (uint256) {
        return p + inc;
    }

    /// @dev Increments the tail length in a Sizing Frame.
    function _szAddTail(uint256 p, uint256 inc) internal pure returns (uint256) {
        return p + (inc << SHIFT_SIZING_TAIL);
    }

    /*//////////////////////////////////////////////////////////////////////////
                       PACKED ENCODING FRAME (uint256) HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    // During the encoding pass (`_encodeCore`), a similar packed struct is used
    // for the "Encoding Frame" stack. It tracks the memory offsets for writing
    // both the head and tail parts of each nested container.
    //
    // Encoding Frame Layout (uint256):
    // | Bits 255-192 | Bits 191-144 | Bits 143-96  | Bits 95-48   | Bits 47-0    |
    // |--------------|--------------|--------------|--------------|--------------|
    // | ContainerKind| curTailOff   | tailStart    | curHeadOff   | headStart    |
    // | (64 bits)    | (48 bits)    | (48 bits  )  | (48 bits)    | (48 bits)    |

    /// @dev Constructs a packed Encoding Frame.
    function _mkFrame(
        ContainerKind ct,
        uint256 headStart,
        uint256 curHeadOff,
        uint256 tailStart,
        uint256 curTailOff
    )
        internal
        pure
        returns (uint256 p)
    {
        assembly {
            p := or(
                or(
                    or(or(headStart, shl(SHIFT_FRAME_CUR_HEAD, curHeadOff)), shl(SHIFT_FRAME_TAIL_START, tailStart)),
                    shl(SHIFT_FRAME_CUR_TAIL, curTailOff)
                ),
                shl(SHIFT_FRAME_KIND, ct)
            )
        }
    }

    /// @dev Extracts the absolute start offset of the head.
    function _fHeadStart(uint256 p) internal pure returns (uint256) {
        return p & MASK_48;
    }

    /// @dev Extracts the current relative offset within the head.
    function _fHeadOff(uint256 p) internal pure returns (uint256) {
        return (p >> SHIFT_FRAME_CUR_HEAD) & MASK_48;
    }

    /// @dev Extracts the absolute start offset of the tail.
    function _fTailStart(uint256 p) internal pure returns (uint256) {
        return (p >> SHIFT_FRAME_TAIL_START) & MASK_48;
    }

    /// @dev Extracts the current relative offset within the tail.
    function _fTailOff(uint256 p) internal pure returns (uint256) {
        return (p >> SHIFT_FRAME_CUR_TAIL) & MASK_48;
    }

    /// @dev Extracts the ContainerKind.
    function _fKind(uint256 p) internal pure returns (ContainerKind) {
        return ContainerKind(uint8(p >> SHIFT_FRAME_KIND));
    }

    /// @dev Bumps the current head offset.
    function _fBumpHead(uint256 p, uint256 inc) internal pure returns (uint256) {
        return p + (inc << SHIFT_FRAME_CUR_HEAD);
    }

    /// @dev Bumps the current tail offset.
    function _fBumpTail(uint256 p, uint256 inc) internal pure returns (uint256) {
        return p + (inc << SHIFT_FRAME_CUR_TAIL);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                FLAT-BLUEPRINT HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Checks if a blueprint has no container tokens. This allows using the
    ///      more efficient single-pass encoding path.
    function _isFlat(bytes calldata bp) private pure returns (bool flat) {
        uint256 len = bp.length;
        for (uint256 i; i < len;) {
            uint8 t = uint8(bp[i]);
            // Any container token immediately means the blueprint is not flat.
            if (t == END_DYNAMIC || (t >= START_ARRAY_DYNAMIC && t <= START_TUPLE_STATIC)) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @dev Single-pass measurement for a flat blueprint.
    function _measureFlat(
        bytes calldata bp,
        bytes[] memory regs
    )
        private
        pure
        returns (uint256 headBytes, uint256 tailBytes)
    {
        uint256 len = bp.length;
        for (uint256 i; i < len;) {
            uint8 tok = uint8(bp[i]);
            // Every item in a flat blueprint contributes one 32-byte slot to the head part.
            headBytes += LEN_WORD;

            if (tok.isDyn()) {
                // Dynamic register: its data goes into the tail.
                uint8 idx = tok.idx();
                uint256 blobLen = regs.get(idx).length;
                // Dynamic registers must be pre-formatted (length-prefixed), hence >= 32 bytes.
                if (blobLen < LEN_WORD) revert BadDynamicFormat(idx);
                tailBytes += blobLen;
            } else {
                // Static register: its data is part of the head, size already counted.
                // Just need to validate the token and register format.
                if (tok > MAX_STATIC_REGISTER_TOKEN) revert InvalidToken();
                if (regs.get(tok).length != LEN_WORD) revert BadStaticFormat(tok);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Single-pass encoder for a flat blueprint, including a function selector.
    function _encodeFlat(
        bytes4 selector,
        bytes calldata bp,
        bytes[] memory regs,
        uint256 headBytes,
        uint256 tailBytes
    )
        private
        pure
        returns (bytes memory out)
    {
        // Allocate the full buffer with length prefix for selector + head + tail.
        uint256 payloadLen = SELECTOR_SIZE + headBytes + tailBytes;
        out = _allocWithLength(payloadLen);
        assembly {
            mstore(add(out, DATA_OFFSET), selector)
        } // write selector after length word
        // Delegate to the core flat encoder, offsetting by 32 (length) + SELECTOR_SIZE bytes.
        _encodeFlatCoreInto(out, bp, regs, headBytes, LEN_WORD + SELECTOR_SIZE);
        return out;
    }

    /// @dev Core logic for flat encoding, writing into a pre-allocated buffer.
    function _encodeFlatCoreInto(
        bytes memory out,
        bytes calldata bp,
        bytes[] memory regs,
        uint256 headBytes,
        uint256 startOffset
    )
        private
        pure
    {
        // `headPtr` tracks the write position in the head section (relative to `headBase`).
        uint256 headPtr = 0;
        // `tailPtr` tracks the write position in the tail section (relative to `headBase`).
        uint256 tailPtr = headBytes;
        uint256 len = bp.length;
        // The absolute memory offset where the ABI data begins.
        uint256 headBase = startOffset;

        for (uint256 i; i < len;) {
            uint8 tok = uint8(bp[i]);

            // --- STATIC REGISTER ---
            if ((tok & REG_DYNAMIC_MASK) == 0) {
                if (tok > MAX_STATIC_REGISTER_TOKEN) revert InvalidToken();
                uint8 idx = tok;
                if (regs.get(idx).length != LEN_WORD) revert BadStaticFormat(idx);
                // Copy the 32-byte word directly into the head.
                _copyWord(out, headBase + headPtr, regs.get(idx));
                headPtr += LEN_WORD;
            }
            // --- DYNAMIC REGISTER ---
            else {
                uint8 idx = tok.idx();
                bytes memory reg = regs.get(idx);
                uint256 dataLen = reg.length;
                if (dataLen < LEN_WORD) revert BadDynamicFormat(idx);

                // Calculate the absolute memory address for the tail data.
                uint256 absTail = headBase + tailPtr;
                // Write the pointer to the head section.
                _writeUint(out, headBase + headPtr, tailPtr);
                // Copy the entire dynamic blob (length-prefixed) to the tail section.
                uint256 written = _copyDyn(out, absTail, reg);

                headPtr += LEN_WORD;
                tailPtr += written;
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                PASS 1 - SIZE MEASUREMENT
    //////////////////////////////////////////////////////////////////////////*/
    /// @dev First pass for nested blueprints. Traverses the blueprint to calculate
    ///      the total size and gather metadata about dynamic containers.
    function _measure(
        bytes calldata blueprint,
        bytes[] memory registers,
        uint256[MAX_DYN_HEADS] memory tmpDynHeads
    )
        private
        pure
        returns (uint256 totalBytes, uint256 headBytes, uint256 dynHeadCount)
    {
        // `stack` holds Sizing Frames to track container dimensions at each nesting level.
        uint256[MAX_STACK_DEPTH] memory stack;
        // `elemCount` tracks the number of elements in arrays at each nesting level.
        uint256[MAX_STACK_DEPTH] memory elemCount;
        // `metaIndex` tracks which slot in tmpDynHeads each container should use.
        uint256[MAX_STACK_DEPTH] memory metaIndex;
        uint256 sp; // stack pointer
        uint256 nextMetaIdx; // next available slot in tmpDynHeads

        // Initialize the stack with a root frame.
        stack[0] = _mkSizing(0, 0, ContainerKind.NONE);
        elemCount[0] = 0;

        uint256 bpLen = blueprint.length;
        uint256 regCount = registers.length;
        for (uint256 i; i < bpLen;) {
            uint8 tok = uint8(blueprint[i]);
            ContainerKind open = _decodeKind(tok);

            /*> open a new container */
            if (open != ContainerKind.NONE) {
                if (sp + 1 >= MAX_STACK_DEPTH) revert StackOverflow();
                // Reserve slot for dynamic containers
                if (open == ContainerKind.DYNAMIC_ARRAY || open == ContainerKind.DYNAMIC_TUPLE) {
                    if (nextMetaIdx >= tmpDynHeads.length) revert DynHeadBufOverflow();
                    metaIndex[sp + 1] = nextMetaIdx++;
                }
                // Push a new, empty Sizing Frame onto the stack for the new container.
                stack[++sp] = _mkSizing(0, 0, open);
                elemCount[sp] = 0; // Reset element count for the new level.
            }
            /*> close the current container */
            else if (tok == END_DYNAMIC) {
                if (sp == 0) revert StackUnderflow();
                // Pop the completed child container's frame from the stack.
                uint256 child = stack[sp];
                uint256 childElemCount = elemCount[sp];
                sp--;

                ContainerKind ck = _szKind(child);
                uint256 childHeadLen = _szHead(child);
                uint256 childTailLen = _szTail(child);

                // If the parent is an array, the child we just closed counts as one element.
                ContainerKind parent = _szKind(stack[sp]);
                if (parent == ContainerKind.DYNAMIC_ARRAY || parent == ContainerKind.STATIC_ARRAY) {
                    unchecked {
                        elemCount[sp]++;
                    }
                }

                bool dynamic = (ck == ContainerKind.DYNAMIC_TUPLE || ck == ContainerKind.DYNAMIC_ARRAY);
                if (dynamic) {
                    // For dynamic containers, we add a 32-byte pointer to the parent's head.
                    // The container's content becomes part of the parent's tail.
                    uint256 idx = metaIndex[sp + 1];
                    // Store metadata for the encoding pass. For dynamic arrays, we pack
                    // the head length and element count together.
                    if (ck == ContainerKind.DYNAMIC_ARRAY) {
                        uint256 packed = childHeadLen | (childElemCount << SHIFT_CNT);
                        tmpDynHeads[idx] = packed;
                    } else {
                        // Tuple
                        tmpDynHeads[idx] = childHeadLen;
                    }

                    stack[sp] = _szAddHead(stack[sp], LEN_WORD); // Add pointer slot to parent head.
                    uint256 bytesChild = childHeadLen + childTailLen;
                    // Dynamic arrays also have a 32-byte length word.
                    if (ck == ContainerKind.DYNAMIC_ARRAY) {
                        stack[sp] = _szAddTail(
                            stack[sp],
                            bytesChild + LEN_WORD /*length word*/
                        );
                    } else {
                        stack[sp] = _szAddTail(stack[sp], bytesChild);
                    }
                } else {
                    // For static containers, their head and tail are merged directly
                    // into the parent's head and tail. No pointers are needed.
                    // NOTE: This interprets STATIC_ARRAY as always inline, regardless of element types.
                    // For ABI-compliant encoding of T[k] where T is dynamic, use DYNAMIC_TUPLE
                    // which will encode with a pointer as specified in the ABI.
                    stack[sp] = _szAddHead(stack[sp], childHeadLen);
                    stack[sp] = _szAddTail(stack[sp], childTailLen);
                }
            }
            /*> static register */
            else if (tok <= MAX_STATIC_REGISTER_TOKEN) {
                // A static register adds 32 bytes to the current container's head.
                stack[sp] = _szAddHead(stack[sp], LEN_WORD);
                ContainerKind here = _szKind(stack[sp]);
                if (here == ContainerKind.DYNAMIC_ARRAY || here == ContainerKind.STATIC_ARRAY) {
                    unchecked {
                        elemCount[sp]++;
                    } // It's one element of an array.
                }
            }
            /*> dynamic register */
            else if (tok.isDyn()) {
                uint8 idx = tok.idx();
                uint256 blobLen = idx < regCount ? registers.get(idx).length : 0;
                // A dynamic register adds a 32-byte pointer to the head and its
                // blob length to the tail.
                stack[sp] = _szAddHead(stack[sp], LEN_WORD);
                stack[sp] = _szAddTail(stack[sp], blobLen);
                ContainerKind here = _szKind(stack[sp]);
                if (here == ContainerKind.DYNAMIC_ARRAY || here == ContainerKind.STATIC_ARRAY) {
                    unchecked {
                        elemCount[sp]++;
                    } // It's one element of an array.
                }
            } else {
                revert InvalidToken();
            }
            unchecked {
                ++i;
            }
        }

        if (sp != 0) revert UnclosedContainer();
        // The final dimensions are in the root frame.
        headBytes = _szHead(stack[0]);
        totalBytes = headBytes + _szTail(stack[0]);
        dynHeadCount = nextMetaIdx;
    }

    /*//////////////////////////////////////////////////////////////////////////
                          PASS 2 - ENCODING (PUBLIC ENTRY)
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @notice Encodes a full ABI payload, prepending a 4-byte function selector.
     * @param selector The function selector.
     * @param blueprint The byte-level layout description.
     * @param registers Caller-supplied data referenced by the blueprint.
     * @return out A (4 + N)-byte ABI blob suitable for a low-level `call`.
     */
    function encodeFromBlueprint(
        bytes4 selector,
        bytes calldata blueprint,
        bytes[] memory registers
    )
        public
        pure
        returns (bytes memory out)
    {
        /* fast path #0: empty blueprint */
        if (blueprint.length == 0) {
            // Nothing to encode, just return the selector with length prefix.
            out = _allocWithLength(SELECTOR_SIZE);
            assembly {
                mstore(add(out, DATA_OFFSET), selector)
            } // 0x20 (len) + 0x20 (first data word)
            return out;
        }

        /* fast path #1: flat blueprint (no containers) */
        if (_isFlat(blueprint)) {
            (uint256 headB, uint256 tailB) = _measureFlat(blueprint, registers);
            // Delegate to the specialized flat encoder.
            return _encodeFlat(selector, blueprint, registers, headB, tailB);
        }

        /* general case: two-pass measure/encode for nested blueprints */
        // Use a small, fixed-size buffer on the stack for performance.
        uint256[MAX_DYN_HEADS] memory tmpHeads;
        (uint256 total, uint256 headBytes, uint256 dynCnt) = _measure(blueprint, registers, tmpHeads);
        // Copy the metadata from the temporary stack buffer to a properly-sized heap array.
        // The data is needed in FIFO order for the encoding pass.
        uint256[] memory dynHead = new uint256[](dynCnt);
        for (uint256 j; j < dynCnt;) {
            dynHead[j] = tmpHeads[j];
            unchecked {
                ++j;
            }
        }

        // Allocate the final buffer for the entire payload with length prefix.
        uint256 payloadLen = SELECTOR_SIZE + total;
        out = _allocWithLength(payloadLen);
        assembly {
            mstore(add(out, DATA_OFFSET), selector)
        }
        // Call the core encoder, starting after the length word + SELECTOR_SIZE.
        _encodeCore(blueprint, registers, dynHead, out, LEN_WORD + SELECTOR_SIZE, headBytes);
        return out;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                MODULAR ENCODING
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @notice Encodes an ABI data blob *without* a function selector.
     * @param blueprint Layout description.
     * @param registers Caller-supplied registers.
     * @return out ABI-encoded data blob.
     */
    function encodeData(bytes calldata blueprint, bytes[] memory registers) public pure returns (bytes memory out) {
        /* fast path #0: empty blueprint */
        if (blueprint.length == 0) return _allocWithLength(0); // just the 32-byte length word (value = 0)

        /* fast path #1: flat blueprint */
        if (_isFlat(blueprint)) {
            (uint256 headB, uint256 tailB) = _measureFlat(blueprint, registers);
            uint256 payloadLen = headB + tailB;
            out = _allocWithLength(payloadLen);
            _encodeFlatCoreInto(out, blueprint, registers, headB, LEN_WORD);
            return out;
        }

        /* general case: two-pass measure/encode for nested blueprints */
        uint256[MAX_DYN_HEADS] memory tmpHeads;
        (uint256 total, uint256 headBytes, uint256 dynCnt) = _measure(blueprint, registers, tmpHeads);
        uint256[] memory dynHead = new uint256[](dynCnt);
        for (uint256 j; j < dynCnt;) {
            dynHead[j] = tmpHeads[j];
            unchecked {
                ++j;
            }
        }

        out = _allocWithLength(total);
        // Start writing at offset LEN_WORD (after length word), as there is no selector.
        _encodeCore(blueprint, registers, dynHead, out, LEN_WORD, headBytes);
        return out;
    }

    /**
     * @dev Core encoding logic for nested blueprints (Pass 2).
     * @param dynHead Pre-computed metadata for dynamic containers (FIFO).
     * @param out The pre-allocated output buffer.
     * @param startOffset Where to begin writing in `out` (32 or 36 bytes).
     * @param headBytes Pre-measured size of the head section.
     */
    function _encodeCore(
        bytes calldata blueprint,
        bytes[] memory registers,
        uint256[] memory dynHead,
        bytes memory out,
        uint256 startOffset,
        uint256 headBytes
    )
        private
        pure
    {
        // The head section starts at `startOffset`.
        uint256 headStart = startOffset;
        // The tail section starts immediately after the head section.
        uint256 tailStart = startOffset + headBytes;

        // `fs` is the "Frame Stack", holding packed Encoding Frames.
        uint256[MAX_STACK_DEPTH] memory fs;
        // Initialize the stack with the root frame, with offsets set up.
        fs[0] = _mkFrame(ContainerKind.NONE, headStart, 0, tailStart, 0);

        uint256 sp; // stack pointer
        uint256 dynPop; // index for popping from `dynHead` metadata array
        uint256 bpLen = blueprint.length;
        for (uint256 i; i < bpLen;) {
            uint8 tok = uint8(blueprint[i]);
            uint256 frame = fs[sp];

            /*> open a new container */
            if (tok >= START_ARRAY_DYNAMIC && tok <= START_TUPLE_STATIC) {
                if (sp + 1 >= MAX_STACK_DEPTH) revert StackOverflow();
                ContainerKind ck = _decodeKind(tok);

                uint256 childHeadStart;
                uint256 childTailStart;
                uint256 childHeadOff; // Used only by dynamic arrays for the length slot.

                if (ck == ContainerKind.DYNAMIC_TUPLE || ck == ContainerKind.DYNAMIC_ARRAY) {
                    // This container is dynamic. Write a pointer to it in the parent's head.
                    // The pointer's target is the current end of the parent's tail.
                    uint256 absPtr = _fTailStart(frame) + _fTailOff(frame);
                    // If parent is a dynamic array, element head pointers are relative to headStart + 32
                    uint256 base = _fHeadStart(frame);
                    if (_fKind(frame) == ContainerKind.DYNAMIC_ARRAY) {
                        unchecked {
                            base += LEN_WORD;
                        }
                    }
                    uint256 relPtr = absPtr - base;
                    _writeUint(out, _fHeadStart(frame) + _fHeadOff(frame), relPtr);

                    // The pointer itself occupies 32 bytes in the parent's head.
                    frame = _fBumpHead(frame, LEN_WORD);

                    // Retrieve the pre-measured metadata for this container (in FIFO order).
                    if (dynPop >= dynHead.length) revert DynHeadBufOverflow();
                    uint256 meta = dynHead[dynPop++];
                    uint256 childHeadLen = meta & MASK_LEN;

                    // The child's data starts where the pointer points.
                    childHeadStart = absPtr;
                    if (ck == ContainerKind.DYNAMIC_ARRAY) {
                        // Dynamic arrays need their element count written first.
                        uint256 arrLen = meta >> SHIFT_CNT;
                        _writeUint(out, childHeadStart, arrLen);

                        // The child's head starts after its length word.
                        childHeadOff = LEN_WORD;
                        childTailStart = childHeadStart + LEN_WORD + childHeadLen;
                        // The child occupies `32 (len) + head + tail` bytes in the parent's tail.
                        frame = _fBumpTail(frame, LEN_WORD + childHeadLen);
                    } else {
                        // Dynamic Tuple
                        childTailStart = childHeadStart + childHeadLen;
                        // The child occupies `head + tail` bytes in the parent's tail.
                        frame = _fBumpTail(frame, childHeadLen);
                    }
                } else {
                    // This container is static. It's encoded inline. Its head starts at the
                    // current position in the parent's head.
                    // NOTE: STATIC_ARRAY tokens always encode inline regardless of element types.
                    // For ABI-compliant encoding of T[k] where T is dynamic, use DYNAMIC_TUPLE
                    // which encodes with a pointer as per the ABI specification.
                    childHeadStart = _fHeadStart(frame) + _fHeadOff(frame);
                    childTailStart = _fTailStart(frame) + _fTailOff(frame);
                }

                fs[sp] = frame; // Save the updated parent frame.
                ++sp; // Push.
                // Create the new child frame on the stack.
                fs[sp] = _mkFrame(ck, childHeadStart, childHeadOff, childTailStart, 0);
            }
            /*> close the current container */
            else if (tok == END_DYNAMIC) {
                if (sp == 0) revert StackUnderflow();
                // Pop the child frame that we just finished encoding.
                uint256 closed = fs[sp--];

                // Propagate the written lengths up to the new parent frame.
                if (_fKind(closed) == ContainerKind.DYNAMIC_TUPLE || _fKind(closed) == ContainerKind.DYNAMIC_ARRAY) {
                    // Dynamic containers only grow the parent's tail.
                    fs[sp] = _fBumpTail(fs[sp], _fTailOff(closed));
                } else {
                    // Static container
                    // Static containers grow both the parent's head and tail.
                    fs[sp] = _fBumpHead(fs[sp], _fHeadOff(closed));
                    fs[sp] = _fBumpTail(fs[sp], _fTailOff(closed));
                }
            }
            /*> static register */
            else if (tok <= MAX_STATIC_REGISTER_TOKEN) {
                uint8 idx = tok;
                if (registers.get(idx).length != LEN_WORD) revert BadStaticFormat(idx);
                // Copy the 32-byte word directly into the current head position.
                uint256 dst = _fHeadStart(frame) + _fHeadOff(frame);
                _copyWord(out, dst, registers.get(idx));
                // Advance the head offset for the current frame.
                fs[sp] = _fBumpHead(frame, LEN_WORD);
            }
            /*> dynamic register */
            else if (tok.isDyn()) {
                uint8 idx = tok.idx();
                if (registers.get(idx).length < LEN_WORD) revert BadDynamicFormat(idx);

                // Write pointer to head.
                uint256 absPtr = _fTailStart(frame) + _fTailOff(frame);
                // For dynamic arrays, element head pointers are relative to the start of the
                // array head AFTER the 32-byte length word. For other containers, pointers are
                // relative to the container's head start as usual.
                uint256 base = _fHeadStart(frame);
                if (_fKind(frame) == ContainerKind.DYNAMIC_ARRAY) {
                    unchecked {
                        base += LEN_WORD;
                    } // skip array length word
                }
                uint256 relPtr = absPtr - base;
                _writeUint(out, _fHeadStart(frame) + _fHeadOff(frame), relPtr);

                // Copy data to tail.
                uint256 bytesW = _copyDyn(out, absPtr, registers.get(idx));
                // Advance head offset (for the pointer) and tail offset (for the data).
                fs[sp] = _fBumpHead(frame, LEN_WORD);
                fs[sp] = _fBumpTail(fs[sp], bytesW);
            } else {
                revert InvalidToken();
            }
            unchecked {
                ++i;
            }
        }
        if (sp != 0) revert UnclosedContainer();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                MEMORY COPY HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Copies a 32-byte word from a `bytes` register to the output buffer.
    function _copyWord(bytes memory out, uint256 dst, bytes memory srcReg) private pure {
        if (dst + LEN_WORD > out.length) revert BufferTooSmall(dst + LEN_WORD, out.length);
        assembly {
            // `mstore` to `out + LEN_WORD (length) + dst`, from `srcReg + LEN_WORD (length)`.
            mstore(add(add(out, LEN_WORD), dst), mload(add(srcReg, LEN_WORD)))
        }
    }

    /// @dev Copies a dynamic, length-prefixed register blob.
    function _copyDyn(bytes memory out, uint256 dst, bytes memory reg) private pure returns (uint256 written) {
        // The register `reg` is a pre-encoded ABI blob: `<length><data>`.
        // The first word of a `bytes` variable in memory holds its length.
        uint256 blobLen;
        assembly {
            blobLen := mload(reg)
        }
        if (dst + blobLen > out.length) revert BufferTooSmall(dst + blobLen, out.length);
        // Efficiently copy word-by-word. Assumes `blob` is a multiple of 32.
        assembly {
            let srcPtr := add(reg, LEN_WORD)
            let dstPtr := add(add(out, LEN_WORD), dst)
            for { let off := 0 } lt(off, blobLen) { off := add(off, LEN_WORD) } {
                mstore(add(dstPtr, off), mload(add(srcPtr, off)))
            }
        }
        return blobLen;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                UTILITY HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Decodes a container token byte into its `ContainerKind`.
    function _decodeKind(uint8 tok) private pure returns (ContainerKind kind) {
        if (tok == START_TUPLE_DYNAMIC) return ContainerKind.DYNAMIC_TUPLE;
        if (tok == START_ARRAY_DYNAMIC) return ContainerKind.DYNAMIC_ARRAY;
        if (tok == START_TUPLE_STATIC) return ContainerKind.STATIC_TUPLE;
        if (tok == START_ARRAY_STATIC) return ContainerKind.STATIC_ARRAY;
        return ContainerKind.NONE;
    }

    /// @dev Writes a `uint` value into the output buffer at a given offset.
    function _writeUint(bytes memory buf, uint256 off, uint256 val) private pure {
        if (off + LEN_WORD > buf.length) revert BufferTooSmall(off + LEN_WORD, buf.length);
        assembly {
            // `mstore` to `buf + LEN_WORD (length) + off`.
            mstore(add(add(buf, LEN_WORD), off), val)
        }
    }

    /// @dev Allocates `LEN_WORD + payloadLen` bytes and writes `payloadLen` as the
    ///      first 32-byte word of the returned buffer's data area.
    function _allocWithLength(uint256 payloadLen) private pure returns (bytes memory out) {
        out = new bytes(LEN_WORD + payloadLen);
        _writeUint(out, 0, payloadLen);
    }
}
