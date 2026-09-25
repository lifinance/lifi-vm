// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @title VmConstants
/// @custom:version 1.1.0
/// @notice Shared constants for the Virtual Machine and test helpers
library VmConstants {
    // Register constants
    uint8 public constant DYN_MASK = 0x80;
    uint8 public constant IDX_MASK = 0x7F;
    uint8 public constant VOID_REG = 0x7A;

    // ABI / memory word size (32 bytes).
    uint256 public constant WORD_SIZE = 32;

    // Surgery limits
    uint8 public constant MAX_SURGERIES = 6;

    // Blueprint size limits
    uint8 public constant MAX_CDB_BP = 22; // CALLDATA_BUILD blueprint max size
    uint8 public constant MAX_ABI_BP = 27; // ABI_ENCODE blueprint max size

    // Blueprint container tokens (from BlueprintEncoder)
    uint8 public constant START_TUPLE_STATIC = 0x7F;
    uint8 public constant START_TUPLE_DYNAMIC = 0x7E;
    uint8 public constant START_ARRAY_STATIC = 0x7D;
    uint8 public constant START_ARRAY_DYNAMIC = 0x7C;
    uint8 public constant END_DYNAMIC = 0x7B;
}
