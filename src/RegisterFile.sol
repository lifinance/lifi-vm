// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './VmConstants.sol';

/// @title Register file utilities for the VM
/// @custom:version 1.0.0
library RegisterFile {
    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev ABI‑encoded `uint256(0)` for the void register.
    bytes internal constant ZERO_VALUE = hex'0000000000000000000000000000000000000000000000000000000000000000';

    /*//////////////////////////////////////////////////////////////////////////
                                       ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when `index` ≥ `registers.length`.
    error RegisterIndexOOB();

    /// @notice Thrown when provided data is not a dynamic abi-encoded field.
    error InvalidDynamicData();

    /// @notice Thrown when provided data is not a static abi-encoded field (32 bytes).
    error InvalidStaticData();

    /*//////////////////////////////////////////////////////////////////////////
                                        READS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the raw data stored in a register.
    /// @dev The void register always returns `ZERO_VALUE`.
    function get(bytes[] memory registers, uint8 index) internal pure returns (bytes memory) {
        if (index == VmConstants.VOID_REG) return ZERO_VALUE;
        if (index >= registers.length) revert RegisterIndexOOB();
        return registers[index];
    }

    /// @notice Returns the raw data stored in a register and checks its 32 bytes.
    /// @dev The void register always returns `ZERO_VALUE`.
    function getStatic(bytes[] memory registers, uint8 index) internal pure returns (bytes memory out) {
        if (index == VmConstants.VOID_REG) return ZERO_VALUE;
        if (index >= registers.length) revert RegisterIndexOOB();

        uint256 len;
        assembly {
            // slot = registers.data + index * 32
            let slot := add(add(registers, 0x20), shl(5, index))
            out := mload(slot) // bytes pointer
            len := mload(out) // bytes length
        }
        if (len != 32) revert InvalidStaticData();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                        WRITES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Stores raw `data` into `register[index]`.
    function set(bytes[] memory registers, uint8 index, bytes memory data) internal pure {
        if (index == VmConstants.VOID_REG) return;
        if (index >= registers.length) revert RegisterIndexOOB();
        registers[index] = data;
    }

    /// @notice Stores `data` into `register[index]`, dropping the leading
    ///         0x20 pointer word expected in ABI‑encoded structures. Re-tags the data as bytes by also
    ///         rewriting the data length as the raw-bytes length (bytes and strings are unchanged).
    ///         (e.g. `abi.encode(string)`).
    /// @dev This function does not work for dynamic tuples and will generate garbage in that case.
    function setDynamic(bytes[] memory registers, uint8 index, bytes memory data) internal pure {
        if (index == VmConstants.VOID_REG) return;
        if (index >= registers.length) revert RegisterIndexOOB();

        // The `data` is expected to be a single dynamic field abi-encoded. It must thus contain an
        // initial 32-byte `0x20` offset, followed by a 32-byte length descriptor.
        if (data.length < 0x40) {
            revert InvalidDynamicData();
        }
        uint256 abiOffset;
        assembly {
            abiOffset := mload(add(data, 0x20)) // Add 0x20 to point to the first 32-byte word
        }
        if (abiOffset != 0x20) {
            revert InvalidDynamicData();
        }

        bytes memory view_;
        // WARNING - This is an in-place modification (length correction)
        // Any reference to data will ALSO be affected
        assembly {
            view_ := add(data, 0x20) // skip the ABI offset
            mstore(view_, sub(mload(data), 0x20)) // correct byte length
        }

        registers[index] = view_;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   INITIALISATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Allocates `numRegisters` empty registers.
    /// @dev Zero‑initialised memory is already valid empty `bytes`, so we
    ///      simply return a new array—no per‑slot writes needed.
    function initialize(uint256 numRegisters) internal pure returns (bytes[] memory) {
        return new bytes[](numRegisters);
    }
}
