// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @notice The register file that holds all registers used by the VM.
struct VMState {
    bytes[] registers;
}

/// @notice Enum representing the different call types supported.
enum CallType {
    DELEGATECALL,
    CALL,
    STATICCALL,
    VALUECALL
}

/// @notice Enum representing the VM command operations.
enum OP {
    CALL, // External call using pre-built calldata.
    CALLDATA_BUILD, // Build calldata from registers.
    EXPLODE, // Splits an ABI-encoded tuple into multiple registers.
    DEPOSIT_APPROVED, // Deposits ERC20 tokens from an address that previously approved tokens.
    CALLDATA_SURGERY, // Performs replace-by-offset operations on a given calldata.
    RETURN, // Halts execution and returns the contents of a register.
    ABI_ENCODE, // Encodes data into ABI format from a blueprint.
    REMAINING_GAS, // Stores the current remaining gas in a register.
    NATIVE_BALANCE, // Gets the native token balance for an address and stores it in a register.
    LOG, // Emits a VMLog event with opcode and data from a register.
    SAFE_TRANSFER // Safely transfers ERC20 tokens using Solady's SafeTransferLib.
}

/// @notice A CALL command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packCall/unpackCall
struct Call {
    address target;
    uint8 callType;
    uint8 destReg; // High bit (0x80) indicates dynamic; lower 7 bits are the register index.
    uint8 srcReg; // High bit (0x80) indicates dynamic; lower 7 bits are the register index.
    uint8 valueReg; // High bit (0x80) indicates dynamic; lower 7 bits are the register index.
}

/// @notice A CALLDATA_BUILD command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packCallDataBuild/unpackCallDataBuild
struct CallDataBuild {
    bytes4 selector;
    uint8 destReg; // High bit = dynamic flag; low 7 bits = register index.
    bytes blueprint; // Blueprint defining the structure of the calldata (max 22 bytes)
}

/// @notice An EXPLODE command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packExplode/unpackExplode.
///      `packedDests` carries the entire original command word; the i-th destination
///      register is extracted as `uint8(packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - i * 8))`.
///      Bytes 0-1 hold `sourceReg`/`destCount`. unpackExplode validates that every reserved bit is
///      zero — the `sourceReg` high bit, the unused destination bytes below `2+destCount`, and the
///      28-31 padding — so the surrounding bits never collide with destination-byte extraction.
struct Explode {
    uint8 sourceReg; // Lower 7 bits are the register index; the high bit is a reserved dead flag and
    // must be zero (rejected by CommandPacking.unpackExplode/packExplode — no read path consumes it).
    uint8 destCount;
    uint256 packedDests; // Raw command word with up to 26 dest regs at bytes 2..27.
}

/// @notice A DEPOSIT_APPROVED command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packDepositApproved/unpackDepositApproved
struct DepositApproved {
    address token;
    uint8 destReg;
    uint8 maxDepositReg;
}

/// @notice A VM command structure.
/// @dev Each command type has its own packing format within the 32 bytes.
struct VMCommand {
    OP op;
    bytes32 data;
}

/**
 * @dev A surgery descriptor describing how to replace a portion of calldata.
 * @param offset         The byte offset in the source data at which to perform the replacement.
 * @param length         The number of bytes to replace.
 * @param replacementReg The register index containing the replacement bytes.
 */
struct SurgeryDescriptor {
    uint16 offset;
    uint8 length;
    uint8 replacementReg;
}

/**
 * @dev The CALLDATA_SURGERY command structure.
 * @notice For the packed bytes32 layout, see CommandPacking.packCallDataSurgery/unpackCallDataSurgery
 * @param sourceReg     The register index containing the template calldata.
 * @param surgeryCount  The number of surgery operations to perform (1–6).
 * @param surgeries     A fixed-size array (length 6) of surgery descriptors;
 *                      only the first `surgeryCount` are used.
 */
struct CallDataSurgery {
    uint8 sourceReg;
    uint8 surgeryCount;
    SurgeryDescriptor[6] surgeries;
}

/// @notice A RETURN command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packReturn/unpackReturn
struct Return {
    uint8 sourceReg;
}

/// @notice An ABI_ENCODE command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packAbiEncode/unpackAbiEncode
struct AbiEncode {
    uint8 destReg; // High bit = dynamic flag; low 7 bits = register index.
    bytes blueprint; // Blueprint defining the structure of the data to encode (max 27 bytes)
}

/// @notice A REMAINING_GAS command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packRemainingGas/unpackRemainingGas
struct RemainingGas {
    uint8 destReg; // High bit = dynamic flag; low 7 bits = register index.
}

/// @notice A NATIVE_BALANCE command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packNativeBalance/unpackNativeBalance
struct NativeBalance {
    uint8 addrReg; // Register containing the address
    uint8 destReg; // High bit = dynamic flag; low 7 bits = register index.
}

/// @notice Enum representing the different log variants supported.
enum LogVariant {
    STATIC_1, // Log 1 static register (32 bytes)
    STATIC_2, // Log 2 static registers (64 bytes)
    STATIC_3, // Log 3 static registers (96 bytes)
    STATIC_4, // Log 4 static registers (128 bytes)
    STATIC_5, // Log 5 static registers (160 bytes)
    DYNAMIC // Log dynamic data from a register
}

/// @notice A LOG command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packLog/unpackLog
struct Log {
    uint8 variant; // LogVariant enum value
    uint256 sourceRegs; // Packed register indices (only low 208 bits used)
}

/// @notice A SAFE_TRANSFER command structure.
/// @dev For the packed bytes32 layout, see CommandPacking.packSafeTransfer/unpackSafeTransfer
struct SafeTransfer {
    address token; // ERC20 token address (20 bytes)
    uint8 toReg; // Register containing recipient address
    uint8 amountReg; // Register containing transfer amount
}
