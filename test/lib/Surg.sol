// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/DataModel.sol';

/// @notice Surgery descriptor builders for calldata modification.
/// @dev Example: SurgeryDescriptor d = Surg.desc(10, 32, 5);
library Surg {
    /// @notice Build a surgery descriptor.
    /// @dev Example: SurgeryDescriptor d = Surg.desc(100, 32, 2);
    /// @param off Byte offset in source data.
    /// @param len Number of bytes to replace.
    /// @param replReg Register containing replacement bytes.
    /// @return SurgeryDescriptor struct.
    function desc(uint16 off, uint8 len, uint8 replReg) internal pure returns (SurgeryDescriptor memory) {
        return SurgeryDescriptor({ offset: off, length: len, replacementReg: replReg });
    }

    /// @notice Pad descriptor array to maximum size.
    /// @dev Example: SurgeryDescriptor[] padded = Surg.padToMax(descs);
    /// @param in_ Input descriptor array.
    /// @return Padded array with 6 elements.
    function padToMax(SurgeryDescriptor[] memory in_) internal pure returns (SurgeryDescriptor[] memory) {
        SurgeryDescriptor[] memory result = new SurgeryDescriptor[](6);
        uint256 len = in_.length > 6 ? 6 : in_.length;

        for (uint256 i = 0; i < len; i++) {
            result[i] = in_[i];
        }

        return result;
    }

    /// @notice Build descriptors that exceed maximum count.
    /// @dev Example: SurgeryDescriptor[] bad = Surg.tooMany(0);
    /// @param srcReg Source register (for documentation).
    /// @return Array with 7 dummy descriptors.
    function tooMany(uint8 srcReg) internal pure returns (SurgeryDescriptor[] memory) {
        srcReg; // Avoid unused parameter warning
        SurgeryDescriptor[] memory result = new SurgeryDescriptor[](7);

        for (uint256 i = 0; i < 7; i++) {
            result[i] = SurgeryDescriptor({ offset: uint16(i * 10), length: 4, replacementReg: uint8(i) });
        }

        return result;
    }

    /// @notice Build descriptor with out-of-bounds length.
    /// @dev Example: SurgeryDescriptor[] bad = Surg.oobLen(1000, 255, 0);
    /// @param off Offset value.
    /// @param len Length value (intentionally large).
    /// @param replReg Replacement register.
    /// @return Single-element array with OOB descriptor.
    function oobLen(uint16 off, uint8 len, uint8 replReg) internal pure returns (SurgeryDescriptor[] memory) {
        SurgeryDescriptor[] memory result = new SurgeryDescriptor[](1);
        result[0] = SurgeryDescriptor({ offset: off, length: len, replacementReg: replReg });
        return result;
    }

    /// @notice Build overlapping descriptors.
    /// @dev Example: SurgeryDescriptor[] bad = Surg.overlapping(d1, d2);
    /// @param a First descriptor.
    /// @param b Second descriptor (overlaps with first).
    /// @return Two-element array with overlapping descriptors.
    function overlapping(
        SurgeryDescriptor memory a,
        SurgeryDescriptor memory b
    )
        internal
        pure
        returns (SurgeryDescriptor[] memory)
    {
        SurgeryDescriptor[] memory result = new SurgeryDescriptor[](2);
        result[0] = a;
        result[1] = b;
        return result;
    }
}
