// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './VmErrors.sol';
import './VmConstants.sol';

/// @title CommandPacking
/// @custom:version 1.1.0
/// @notice Library for packing and unpacking VM commands into/from 32-byte words for efficient storage and transmission
library CommandPacking {
    /// @dev Upper bound on an EXPLODE command's destination count, fixed by the byte layout: bytes
    ///      2-27 of the packed word hold one destination register each, and bytes 28-31 are reserved
    ///      padding. The off-chain compiler mirrors this ceiling
    ///      (`MAX_EXPLODE_OUTPUTS` in `rs/lifi_vm_edsl/src/ir/isa/command/types/explode.rs`); the two
    ///      must agree or the compiler emits words this library rejects.
    uint8 internal constant MAX_EXPLODE_DESTS = 26; // Max destination count for Explode

    /// @dev Right-shift amount that lands byte 2 — the first destination-register byte — in the low
    ///      byte of a packed EXPLODE word. Destination `i` is read as
    ///      `uint8(packedDests >> (EXPLODE_DESTS_SHIFT_BASE - i * 8))`, since byte 2 occupies bits
    ///      232-239 of the 32-byte word.
    ///
    ///      Why it exists as a named constant: `Explode.packedDests` deliberately carries the raw
    ///      command word rather than a decoded `uint8[]`, so that unpacking an EXPLODE does not
    ///      allocate a 26-word memory array. The cost of that choice is that the destination bytes
    ///      are re-derived at every read site — `unpackExplode`'s reserved-region check below,
    ///      `ExplodeLib.execute`, and `ExplodeLib._resolveDynamicEnd` — and each site needs the same
    ///      base shift. Naming it once keeps those readers provably in agreement; four copies of the
    ///      literal `232` could drift, and a drifted copy would read a neighbouring register index
    ///      rather than fail loudly.
    uint256 internal constant EXPLODE_DESTS_SHIFT_BASE = 232;

    /**
     * @notice Packs a CALL command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Call type (uint8) - variant/sub-opcode
     *   Bytes 1–20:  Target address (20 bytes)
     *   Byte 21:     Destination register (uint8) with dynamic flag in high bit.
     *   Byte 22:     Source register (uint8) with dynamic flag in high bit.
     *   Byte 23:     Value register (uint8) with dynamic flag in high bit.
     *   Bytes 24–31: Padding (8 bytes, available for future use)
     * @param target The external contract address.
     * @param callType The call type (0: DELEGATECALL, 1: CALL, etc.).
     * @param destReg The destination register (with dynamic flag in high bit).
     * @param srcReg The source register (with dynamic flag in high bit).
     * @param valueReg The value register (with dynamic flag in high bit).
     * @return packed The packed 32-byte command.
     */
    function packCall(
        address target,
        uint8 callType,
        uint8 destReg,
        uint8 srcReg,
        uint8 valueReg
    )
        internal
        pure
        returns (bytes32 packed)
    {
        assembly {
            // Insert call type (byte 0, shift left by 248 bits) - variant at front like LOG
            packed := shl(248, callType)
            // Insert target address (bytes 1-20, shift left by 88 bits)
            packed := or(packed, shl(88, target))
            // Insert destination register (byte 21, shift left by 80 bits)
            packed := or(packed, shl(80, destReg))
            // Insert source register (byte 22, shift left by 72 bits)
            packed := or(packed, shl(72, srcReg))
            // Insert value register (byte 23, shift left by 64 bits)
            packed := or(packed, shl(64, valueReg))
        }
    }

    /**
     * @notice Packs a CALLDATA_BUILD command into a single 32-byte word.
     * @dev Format:
     *   Bytes 0–3:   Function selector (bytes4)
     *   Byte 4:      Destination register (uint8) with dynamic flag in high bit
     *   Byte 5:      Blueprint length (uint8)
     *   Bytes 6–27:  Blueprint (up to 22 bytes)
     *   Bytes 28-31: Padding (must be zero)
     * @param selector The 4-byte function selector.
     * @param destReg The destination register (with dynamic flag in high bit).
     * @param blueprint The blueprint defining the structure of the calldata.
     * @return packed The packed 32-byte command.
     */
    function packCallDataBuild(
        bytes4 selector,
        uint8 destReg,
        bytes memory blueprint
    )
        internal
        pure
        returns (bytes32 packed)
    {
        if (blueprint.length > VmConstants.MAX_CDB_BP) {
            revert VmErrors.BlueprintTooLarge();
        }
        // Pack function selector into bytes 0-3.
        packed = bytes32(uint256(uint32(selector))) << 224;
        // Pack destination register into byte 4.
        packed |= bytes32(uint256(destReg)) << 216;
        // Pack blueprint length into byte 5.
        packed |= bytes32(uint256(blueprint.length)) << 208;
        // Pack each blueprint byte into subsequent bytes starting at byte 6.
        for (uint256 i = 0; i < blueprint.length;) {
            // Each blueprint byte occupies one byte at position (6 + i).
            // Shift left by (32 - (6 + i + 1)) * 8 = (25 - i) * 8 bits.
            unchecked {
                packed |= bytes32(uint256(uint8(blueprint[i]))) << ((25 - i) * 8);
                ++i;
            }
        }
    }

    /**
     * @notice Unpacks a CALL command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Call type (uint8) - variant/sub-opcode for consistency with LOG
     *   Bytes 1–20:  Target address (20 bytes)
     *   Byte 21:     Destination register (uint8) with dynamic flag in high bit.
     *   Byte 22:     Source register (uint8) with dynamic flag in high bit.
     *   Byte 23:     Value register (uint8) with dynamic flag in high bit.
     *   Bytes 24–31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return callCmd A Call struct with the unpacked fields.
     */
    function unpackCall(bytes32 packed) internal pure returns (Call memory callCmd) {
        // Extract call type from byte 0.
        callCmd.callType = uint8(uint256(packed >> 248));
        // Extract target address from bytes 1-20.
        callCmd.target = address(uint160(uint256(packed >> 88)));
        // Extract destination register from byte 21.
        callCmd.destReg = uint8(uint256(packed >> 80));
        // Extract source register from byte 22.
        callCmd.srcReg = uint8(uint256(packed >> 72));
        // Extract value register from byte 23.
        callCmd.valueReg = uint8(uint256(packed >> 64));
    }

    /**
     * @notice Unpacks a CALLDATA_BUILD command from a 32-byte word.
     * @dev Expects format:
     *   Bytes 0–3:   Function selector (bytes4)
     *   Byte 4:      Destination register (uint8) with dynamic flag in high bit
     *   Byte 5:      Blueprint length (uint8)
     *   Bytes 6–27:  Blueprint (up to 22 bytes)
     *   Bytes 28-31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return cdb A CallDataBuild struct with the unpacked fields.
     */
    function unpackCallDataBuild(bytes32 packed) internal pure returns (CallDataBuild memory cdb) {
        // Extract function selector from bytes 0-3.
        cdb.selector = bytes4(uint32(uint256(packed >> 224)));

        // Extract destination register from byte 4.
        cdb.destReg = uint8(uint256(packed >> 216));

        // Extract blueprint length from byte 5.
        uint8 blueprintLength = uint8(uint256(packed >> 208));

        // Validate blueprint length to prevent resource exhaustion
        if (blueprintLength > VmConstants.MAX_CDB_BP) {
            revert VmErrors.BlueprintTooLarge();
        }

        // Create the blueprint bytes array.
        cdb.blueprint = new bytes(blueprintLength);
        for (uint256 i = 0; i < blueprintLength;) {
            unchecked {
                cdb.blueprint[i] = bytes1(uint8(uint256(packed >> ((25 - i) * 8))));
                ++i;
            }
        }
    }

    /**
     * @notice Packs an EXPLODE command into a single 32-byte word.
     * @dev Canonical format (every reserved bit MUST be zero so pack/unpack stay symmetric):
     *   Byte 0:      Source register index (low 7 bits). The high bit (0x80) is reserved and
     *                must be zero – it is a dead flag that no read path consumes.
     *   Byte 1:      Destination register count (uint8) – number of destination registers (1–26).
     *   Bytes 2–27:  Destination registers (up to 26 one-byte values).
     *                Each destination uses its high bit as a dynamic flag (0x80); the low 7 bits
     *                specify the index. Bytes beyond the last used destination must be zero.
     *   Bytes 28–31: Padding – reserved, must be zero.
     * @param sourceReg The source register index (high bit must be clear).
     * @param destCount The number of destination registers.
     * @param destRegs An array of destination registers (max 26).
     * @return packed The packed 32-byte command.
     */
    function packExplode(
        uint8 sourceReg,
        uint8 destCount,
        uint8[] memory destRegs
    )
        internal
        pure
        returns (bytes32 packed)
    {
        if (destCount == 0 || destCount > MAX_EXPLODE_DESTS) {
            revert VmErrors.DestinationCountOutOfBounds(destCount);
        }
        if (destRegs.length < uint256(destCount)) {
            revert VmErrors.DestinationCountMismatch(destCount, destRegs.length);
        }
        // Why this invariant: byte 0's high bit is a reserved bit that `unpackExplode` rejects (see
        // the note there). If `packExplode` accepted a flagged `sourceReg` and emitted it, the two
        // functions would stop being inverses — the packer would mint words its own unpacker
        // refuses, so `unpackExplode(packExplode(x)) == x` (Halmos property E-1) would be false for
        // half the `sourceReg` domain, and the only place the mistake would surface is an on-chain
        // revert. Rejecting here makes `packExplode` total over exactly the inputs `unpackExplode`
        // accepts, which is what lets the roundtrip be stated as an unconditional property.
        if (sourceReg & VmConstants.DYN_MASK != 0) revert VmErrors.NonZeroPadding();
        assembly {
            // Insert sourceReg into byte 0 (shift left by 248 bits).
            packed := shl(248, sourceReg)
            // Insert destCount into byte 1 (shift left by 240 bits).
            packed := or(packed, shl(240, destCount))
            // Insert each destination register into bytes 2-27.
            // For dynamic arrays, the pointer 'destRegs' points to the length slot.
            // So the first element is at offset 0x20.
            for { let i := 0 } lt(i, destCount) { i := add(i, 1) } {
                let elementPtr := add(add(destRegs, 0x20), mul(i, 0x20))
                let regVal := and(mload(elementPtr), 0xFF)
                let shiftAmount := sub(EXPLODE_DESTS_SHIFT_BASE, mul(i, 8))
                packed := or(packed, shl(shiftAmount, regVal))
            }
        }
    }

    /**
     * @notice Unpacks an EXPLODE command from a 32-byte word.
     * @dev Enforces the canonical encoding; any word with a reserved bit set is rejected as
     *      malleable (`NonZeroPadding`):
     *   Byte 0:      Source register index (low 7 bits). The high bit (0x80) is reserved and must
     *                be zero – it is a dead flag with no read path.
     *   Byte 1:      Destination register count (uint8), validated to 1–26.
     *   Bytes 2..(1+destCount): destination registers (each may carry its own 0x80 dynamic flag).
     *   Bytes (2+destCount)..31: reserved – all bits below the last used destination byte (the
     *                unused destination bytes plus the 28–31 padding) must be zero.
     * @param packed The packed 32-byte command.
     * @return explodeCmd An Explode struct with the unpacked fields.
     */
    function unpackExplode(bytes32 packed) internal pure returns (Explode memory explodeCmd) {
        // Extract sourceReg from byte 0.
        uint8 sourceReg = uint8(uint256(packed >> 248));
        // Extract destCount from byte 1.
        uint8 destCount = uint8(uint256(packed >> 240));

        if (destCount == 0 || destCount > MAX_EXPLODE_DESTS) {
            revert VmErrors.DestinationCountOutOfBounds(destCount);
        }

        // "Malleable" here means: two distinct 32-byte words that decode to the same `Explode` struct
        // and therefore execute identically. Byte 0's high bit is the clearest instance —
        // `ExplodeLib.execute` reads the source through `.idx()`, which masks bit 0x80 off, so
        // `0x80 | reg` and `reg` are the same program. Accepting both would make the packed word a
        // non-canonical encoding of the command: the on-the-wire form would no longer be the
        // command's identity, so equality, hashing, caching or golden-artifact comparison over
        // command words (compiler snapshot tests, off-chain simulation replay, blueprint dedup)
        // would silently compare representations instead of behaviour.
        if (uint256(packed >> 248) & VmConstants.DYN_MASK != 0) revert VmErrors.NonZeroPadding();

        // Correctness concern or hygiene? Hygiene, deliberately. `ExplodeLib.execute` reads exactly
        // `destCount` destination bytes and never touches the region below them, so no bit pattern
        // rejected here could have changed execution — this check turns no exploitable input into a
        // revert. What it buys is (a) the canonical encoding described above, and (b) a reserved
        // region that is provably unused on-chain, so a later version can give bytes 28-31 or the
        // trailing destination slots a meaning without having to honour already-accepted nonzero
        // words. EXPLODE is the only command that pays for this; `docs/isa.md` ("Padding and
        // Reserved-Bit Policy") records the asymmetry so the inconsistency is not read as a bug.
        //
        // Mechanics: destination i is read as `uint8(packedDests >> (EXPLODE_DESTS_SHIFT_BASE - i*8))`,
        // so the final destination (i = destCount - 1) occupies the byte whose low bit sits at
        // `lastDestShift`. Everything strictly below that bit — the unused destination bytes
        // [2+destCount .. 27] plus the 28-31 padding — is the reserved region. At destCount = 26 it
        // collapses to exactly the 4 padding bytes (lastDestShift = 32).
        uint256 lastDestShift = EXPLODE_DESTS_SHIFT_BASE - (uint256(destCount) - 1) * 8;
        if (uint256(packed) & ((uint256(1) << lastDestShift) - 1) != 0) {
            revert VmErrors.NonZeroPadding();
        }

        explodeCmd.sourceReg = sourceReg;
        explodeCmd.destCount = destCount;
        // Carry the entire packed word; consumers extract each destination register inline via
        // `uint8(packedDests >> (EXPLODE_DESTS_SHIFT_BASE - i * 8))`. The reserved-bit checks above
        // guarantee every bit below the last destination byte (unused dests + padding) is zero.
        explodeCmd.packedDests = uint256(packed);
    }

    /**
     * @notice Packs a DEPOSIT_APPROVED command into a single 32-byte word.
     * @dev Format:
     *   Bytes 0-19:  ERC20 token address (20 bytes)
     *   Byte 20:     Destination register index (uint8)
     *   Byte 21:     Max deposit register index (uint8)
     *   Bytes 22-31: Unused (must be zero)
     * @param deposit The DepositApproved struct containing the token address, destination register, and max deposit register.
     * @return packed The packed 32-byte word.
     */
    function packDepositApproved(DepositApproved memory deposit) internal pure returns (bytes32 packed) {
        assembly {
            // Load the token (an address is stored right-aligned in a 32-byte word)
            let token := and(mload(deposit), 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
            // Shift the token left by 96 bits to place it in bytes 0-19.
            packed := shl(96, token)
            // Load the destination register (stored as a uint8 in the next 32 bytes).
            let reg := and(mload(add(deposit, 32)), 0xFF)
            // Shift the destination register left by 88 bits to place it in byte 20.
            packed := or(packed, shl(88, reg))
            // Load the max deposit register (stored as a uint8 in the next 32 bytes).
            let maxDepositReg := and(mload(add(deposit, 64)), 0xFF)
            // Shift the max deposit register left by 80 bits to place it in byte 21.
            packed := or(packed, shl(80, maxDepositReg))
        }
    }

    /**
     * @notice Unpacks a DEPOSIT_APPROVED command from a 32-byte word.
     * @dev Expects format:
     *   Bytes 0-19:  ERC20 token address (20 bytes)
     *   Byte 20:     Destination register index (uint8)
     *   Byte 21:     Max deposit register index (uint8)
     *   Bytes 22-31: Unused (ignored)
     * @param packed The packed 32-byte word.
     * @return deposit The unpacked DepositApproved struct.
     */
    function unpackDepositApproved(bytes32 packed) internal pure returns (DepositApproved memory deposit) {
        assembly {
            // Allocate memory for the struct (3 fields now).
            deposit := mload(0x40)
            mstore(0x40, add(deposit, 96))

            // Extract token: shift right by 96 bits.
            let token := shr(96, packed)
            // Ensure we only keep the lower 20 bytes.
            token := and(token, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
            mstore(deposit, token)

            // Extract the destination register:
            // Shift right by 88 bits. Note that packed = (token << 96) OR (reg << 88),
            // so shifting right by 88 gives: (token << 8) OR reg.
            // Because (token << 8) is divisible by 256, its lowest 8 bits are zero.
            let reg := and(shr(88, packed), 0xFF)
            mstore(add(deposit, 32), reg)

            // Extract the max deposit register:
            // Shift right by 80 bits to get the value in byte 21.
            let maxDepositReg := and(shr(80, packed), 0xFF)
            mstore(add(deposit, 64), maxDepositReg)
        }
    }

    /**
     * @notice Packs a CALLDATA_SURGERY command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Source register (uint8)
     *   Byte 1:      Surgery count (uint8) - Number of surgeries to perform (1-6, must not be 0)
     *   Bytes 2-25:  Surgery descriptors (up to 6 × 4 bytes)
     *     For each surgery descriptor:
     *       - 2 bytes: offset (uint16, big-endian)
     *       - 1 byte: length (uint8)
     *       - 1 byte: replacementReg (uint8)
     *   Bytes 26-31: Padding (must be zero)
     * @param surgery The CallDataSurgery struct to pack.
     * @return packed The packed 32-byte command.
     */
    function packCallDataSurgery(CallDataSurgery memory surgery) internal pure returns (bytes32 packed) {
        if (surgery.surgeryCount > 6) {
            revert VmErrors.TooManySurgeries();
        }

        // Pack source register into byte 0
        packed = bytes32(uint256(surgery.sourceReg)) << 248;

        // Pack surgery count into byte 1
        packed |= bytes32(uint256(surgery.surgeryCount)) << 240;

        // Pack each surgery descriptor - each takes 4 bytes starting at byte 2
        for (uint256 i = 0; i < surgery.surgeryCount;) {
            unchecked {
                // Calculate byte position for this descriptor
                uint256 bytePos = 2 + (i * 4);
                uint256 bitPos = 248 - (bytePos * 8);

                // Pack offset high byte (first byte of the u16)
                packed |= bytes32(uint256(surgery.surgeries[i].offset >> 8) & 0xFF) << bitPos;

                // Pack offset low byte (second byte of the u16)
                packed |= bytes32(uint256(surgery.surgeries[i].offset & 0xFF)) << (bitPos - 8);

                // Pack length (1 byte)
                packed |= bytes32(uint256(surgery.surgeries[i].length)) << (bitPos - 16);

                // Pack replacement register (1 byte)
                packed |= bytes32(uint256(surgery.surgeries[i].replacementReg)) << (bitPos - 24);

                ++i;
            }
        }

        return packed;
    }

    /**
     * @notice Unpacks a CALLDATA_SURGERY command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Source register (uint8)
     *   Byte 1:      Surgery count (uint8)
     *   Bytes 2-25:  Surgery descriptors (up to 6 × 4 bytes)
     *   Bytes 26-31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return surgery The unpacked CallDataSurgery struct.
     */
    function unpackCallDataSurgery(bytes32 packed) internal pure returns (CallDataSurgery memory surgery) {
        // Extract source register from byte 0
        surgery.sourceReg = uint8(uint256(packed >> 248));

        // Extract surgery count from byte 1
        surgery.surgeryCount = uint8(uint256(packed >> 240));
        if (surgery.surgeryCount > 6) {
            revert VmErrors.TooManySurgeries();
        }

        // Extract each surgery descriptor - each takes 4 bytes starting at byte 2
        for (uint256 i = 0; i < surgery.surgeryCount;) {
            unchecked {
                // Calculate byte position for this descriptor (each takes 4 bytes)
                uint256 bytePos = 2 + (i * 4);
                uint256 bitPos = 248 - (bytePos * 8);

                // Extract offset (2 bytes = 16 bits)
                // First byte is high byte (>> 8), second byte is low byte
                uint16 highByte = uint16(uint256(packed >> (bitPos)) & 0xFF);
                uint16 lowByte = uint16(uint256(packed >> (bitPos - 8)) & 0xFF);
                surgery.surgeries[i].offset = (highByte << 8) | lowByte;

                // Extract length (1 byte = 8 bits) from the 3rd byte of descriptor
                surgery.surgeries[i].length = uint8(uint256(packed >> (bitPos - 16)));

                // Extract replacement register (1 byte = 8 bits) from the 4th byte of descriptor
                surgery.surgeries[i].replacementReg = uint8(uint256(packed >> (bitPos - 24)));

                ++i;
            }
        }

        // Initialize any unused descriptors to zero
        for (uint256 i = surgery.surgeryCount; i < 6;) {
            surgery.surgeries[i].offset = 0;
            surgery.surgeries[i].length = 0;
            surgery.surgeries[i].replacementReg = 0;
            unchecked {
                ++i;
            }
        }

        return surgery;
    }

    /**
     * @notice Packs a RETURN command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Source register (uint8) containing the data to be returned.
     *   Bytes 1-31:  Unused (must be zero)
     * @param sourceReg The source register containing the data to be returned.
     * @return packed The packed 32-byte command.
     */
    function packReturn(uint8 sourceReg) internal pure returns (bytes32 packed) {
        assembly {
            // Insert sourceReg into byte 0 (shift left by 248 bits).
            packed := shl(248, sourceReg)
        }
    }

    /**
     * @notice Unpacks a RETURN command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Source register (uint8) containing the data to be returned.
     *   Bytes 1-31:  Unused (ignored)
     * @param packed The packed 32-byte command.
     * @return returnCmd A Return struct with the unpacked fields.
     */
    function unpackReturn(bytes32 packed) internal pure returns (Return memory returnCmd) {
        // Extract sourceReg from byte 0.
        returnCmd.sourceReg = uint8(uint256(packed >> 248));
    }

    /**
     * @notice Packs an ABI_ENCODE command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Destination register (uint8) with dynamic flag in high bit.
     *   Byte 1:      Blueprint length (uint8)
     *   Bytes 2-28:  Blueprint (up to 27 bytes).
     *   Bytes 29-31: Padding (must be zero)
     * @param destReg The destination register (with dynamic flag in high bit).
     * @param blueprint The blueprint defining the structure of the data to encode.
     * @return packed The packed 32-byte command.
     */
    function packAbiEncode(uint8 destReg, bytes memory blueprint) internal pure returns (bytes32 packed) {
        if (blueprint.length > VmConstants.MAX_ABI_BP) {
            revert VmErrors.BlueprintTooLarge();
        }
        // Pack destination register into byte 0.
        packed = bytes32(uint256(destReg)) << 248;
        // Pack blueprint length into byte 1.
        packed |= bytes32(uint256(blueprint.length)) << 240;
        // Pack each blueprint byte into subsequent bytes starting at byte 2.
        for (uint256 i = 0; i < blueprint.length;) {
            // Each blueprint byte occupies one byte at position (2 + i).
            // Shift left by (32 - (2 + i + 1)) * 8 = (29 - i) * 8 bits.
            unchecked {
                packed |= bytes32(uint256(uint8(blueprint[i]))) << ((29 - i) * 8);
                ++i;
            }
        }
    }

    /**
     * @notice Unpacks an ABI_ENCODE command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Destination register (uint8) with dynamic flag in high bit.
     *   Byte 1:      Blueprint length (uint8)
     *   Bytes 2-28:  Blueprint (up to 27 bytes).
     *   Bytes 29-31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return abiEncode An AbiEncode struct with the unpacked fields.
     */
    function unpackAbiEncode(bytes32 packed) internal pure returns (AbiEncode memory abiEncode) {
        // Extract destination register from byte 0.
        abiEncode.destReg = uint8(uint256(packed >> 248));

        // Extract blueprint length from byte 1.
        uint8 blueprintLength = uint8(uint256(packed >> 240));

        // Revert if blueprint length exceeds maximum
        if (blueprintLength > 27) {
            revert VmErrors.BlueprintTooLarge();
        }

        // Create the blueprint bytes array.
        abiEncode.blueprint = new bytes(blueprintLength);
        for (uint256 i = 0; i < blueprintLength;) {
            unchecked {
                abiEncode.blueprint[i] = bytes1(uint8(uint256(packed >> ((29 - i) * 8))));
                ++i;
            }
        }
    }

    /**
     * @notice Packs a REMAINING_GAS command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Destination register (uint8) with dynamic flag in high bit.
     *   Bytes 1-31:  Unused (must be zero)
     * @param destReg The destination register (with dynamic flag in high bit).
     * @return packed The packed 32-byte command.
     */
    function packRemainingGas(uint8 destReg) internal pure returns (bytes32 packed) {
        assembly {
            // Insert destReg into byte 0 (shift left by 248 bits).
            packed := shl(248, destReg)
        }
    }

    /**
     * @notice Unpacks a REMAINING_GAS command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Destination register (uint8) with dynamic flag in high bit.
     *   Bytes 1-31:  Unused (ignored)
     * @param packed The packed 32-byte command.
     * @return remainingGas A RemainingGas struct with the unpacked fields.
     */
    function unpackRemainingGas(bytes32 packed) internal pure returns (RemainingGas memory remainingGas) {
        // Extract destination register from byte 0.
        remainingGas.destReg = uint8(uint256(packed >> 248));
    }

    /**
     * @notice Packs a NATIVE_BALANCE command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Address register (uint8) containing the address to get balance of
     *   Byte 1:      Destination register (uint8) with dynamic flag in high bit.
     *   Bytes 2-31:  Unused (must be zero)
     * @param addrReg Register containing the target address to retrieve native balance of.
     * @param destReg The destination register (with dynamic flag in high bit).
     * @return packed The packed 32-byte command.
     */
    function packNativeBalance(uint8 addrReg, uint8 destReg) internal pure returns (bytes32 packed) {
        assembly {
            // Insert addrReg into byte 0 (shift left by 248 bits).
            packed := shl(248, addrReg)
            // Insert destReg into byte 1 (shift left by 240 bits).
            packed := or(packed, shl(240, destReg))
        }
    }

    /**
     * @notice Unpacks a NATIVE_BALANCE command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Address register (uint8) containing the address to get balance of
     *   Byte 1:      Destination register (uint8) with dynamic flag in high bit.
     *   Bytes 2-31:  Unused (ignored)
     * @param packed The packed 32-byte command.
     * @return nativeBalance A NativeBalance struct with the unpacked fields.
     */
    function unpackNativeBalance(bytes32 packed) internal pure returns (NativeBalance memory nativeBalance) {
        // Extract address register from byte 0 (shift right by 248 bits)
        nativeBalance.addrReg = uint8(uint256(packed >> 248));
        // Extract destination register from byte 1 (shift right by 240 bits and mask)
        nativeBalance.destReg = uint8(uint256(packed >> 240));
    }

    /**
     * @notice Packs a LOG command into a single 32-byte word.
     * @dev Format:
     *   Byte 0:      Log variant (uint8) - specifies which type of log to emit (0-5).
     *   Bytes 1-26:  Source registers packed as uint208 - contains up to 26 register indices.
     *                For STATIC_1 (variant=0): only byte 1 is used (1 register).
     *                For STATIC_2 (variant=1): only bytes 1-2 are used (2 registers).
     *                For STATIC_3 (variant=2): only bytes 1-3 are used (3 registers).
     *                For STATIC_4 (variant=3): only bytes 1-4 are used (4 registers).
     *                For STATIC_5 (variant=4): only bytes 1-5 are used (5 registers).
     *                For DYNAMIC (variant=5): only byte 1 is used (points to dynamic array).
     *                Each byte represents a register with high bit as dynamic flag (0x80) and low 7 bits as index.
     *                Unused bytes must be zero.
     *   Bytes 27-31: Padding (must be zero)
     * @param variant The log variant (0: STATIC_1, 1: STATIC_2, ..., 5: DYNAMIC).
     * @param sourceRegs The packed register indices (only low 208 bits used).
     * @return packed The packed 32-byte command.
     */
    function packLog(uint8 variant, uint256 sourceRegs) internal pure returns (bytes32 packed) {
        if (variant > uint8(LogVariant.DYNAMIC)) {
            revert VmErrors.InvalidLogVariant();
        }
        if (sourceRegs > type(uint208).max) {
            revert VmErrors.SourceRegistersExceed208Bits();
        }

        assembly {
            // Pack variant into byte 0 (shift left by 248 bits)
            packed := shl(248, variant)
            // Pack sourceRegs into bytes 1-26 (shift left by 40 bits to align with bytes 1-26)
            packed := or(packed, shl(40, sourceRegs))
        }
    }

    /**
     * @notice Unpacks a LOG command from a 32-byte word.
     * @dev Expects format:
     *   Byte 0:      Log variant (uint8)
     *   Bytes 1-26:  Source registers packed as uint208
     *   Bytes 27-31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return log A Log struct with the unpacked fields.
     */
    function unpackLog(bytes32 packed) internal pure returns (Log memory log) {
        // Extract variant from byte 0
        log.variant = uint8(uint256(packed >> 248));
        // Extract sourceRegs from bytes 1-26 (shift right by 40 bits and mask to 208 bits)
        log.sourceRegs = uint256((uint256(packed >> 40) & ((1 << 208) - 1)));
    }

    /**
     * @notice Packs a SAFE_TRANSFER command into a single 32-byte word.
     * @dev Format:
     *   Bytes 0-19:  Token address (20 bytes)
     *   Byte 20:     To register (uint8)
     *   Byte 21:     Amount register (uint8)
     *   Bytes 22-31: Padding (10 bytes, available for future use)
     * @param token The ERC20 token contract address.
     * @param toReg The register containing recipient address.
     * @param amountReg The register containing transfer amount.
     * @return packed The packed 32-byte command.
     */
    function packSafeTransfer(address token, uint8 toReg, uint8 amountReg) internal pure returns (bytes32 packed) {
        assembly {
            // Insert token address (bytes 0-19, shift left by 96 bits)
            packed := shl(96, token)
            // Insert toReg (byte 20, shift left by 88 bits)
            packed := or(packed, shl(88, toReg))
            // Insert amountReg (byte 21, shift left by 80 bits)
            packed := or(packed, shl(80, amountReg))
        }
    }

    /**
     * @notice Unpacks a SAFE_TRANSFER command from a 32-byte word.
     * @dev Expects format:
     *   Bytes 0-19:  Token address (20 bytes)
     *   Byte 20:     To register (uint8)
     *   Byte 21:     Amount register (uint8)
     *   Bytes 22-31: Padding (ignored)
     * @param packed The packed 32-byte command.
     * @return safeTransfer A SafeTransfer struct with the unpacked fields.
     */
    function unpackSafeTransfer(bytes32 packed) internal pure returns (SafeTransfer memory safeTransfer) {
        // Extract token address from bytes 0-19
        safeTransfer.token = address(uint160(uint256(packed >> 96)));
        // Extract toReg from byte 20
        safeTransfer.toReg = uint8(uint256(packed >> 88));
        // Extract amountReg from byte 21
        safeTransfer.amountReg = uint8(uint256(packed >> 80));
    }
}
