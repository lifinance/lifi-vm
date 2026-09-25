// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './VmErrors.sol';
import './RegisterHelpers.sol';
import './RegisterFile.sol';

/// @title SurgeryOps
/// @custom:version 1.0.0
/// @notice Library for performing byte-level surgery operations on calldata
library SurgeryOps {
    using RegisterHelpers for uint8;
    using RegisterFile for bytes[];
    /// @notice Performs surgery operations on calldata, replacing specific byte ranges with new content in place
    /// @param registers The register array containing register data (in-memory)
    /// @param sourceReg Register index containing the template calldata (which will be modified in place)
    /// @param surgeries Array of surgery descriptors defining the replacements to perform
    /// @param surgeryCount Number of valid surgery operations in the array

    function performSurgery(
        bytes[] memory registers,
        uint8 sourceReg,
        SurgeryDescriptor[6] memory surgeries,
        uint8 surgeryCount
    )
        internal
        pure
    {
        // Mask register indices to get actual register index
        uint8 srcRegIndex = sourceReg.idx();
        // Get source calldata (to be modified in place)
        bytes memory sourceData = registers.get(srcRegIndex);
        uint256 sourceLength = sourceData.length;
        // Apply surgeries directly to the source buffer
        for (uint256 i = 0; i < surgeryCount;) {
            SurgeryDescriptor memory desc = surgeries[i];
            uint8 replacementRegIndex = desc.replacementReg.idx();
            bytes memory replacement = registers.get(replacementRegIndex);
            uint256 replacementLength = replacement.length;
            uint256 surgeryLength = desc.length;

            // Extract values before assembly block
            uint256 offset = desc.offset;

            // Bounds checking - ensure the surgery doesn't go beyond the source data
            if (offset + surgeryLength > sourceLength) {
                revert VmErrors.OutOfBounds();
            }

            // Check if replacement length is greater than surgery length
            // We must revert rather than truncate in this case
            if (replacementLength > surgeryLength) {
                revert VmErrors.ReplacementTooLarge();
            }

            // Apply the replacement directly to the source buffer
            assembly {
                // Compute source memory addresses
                let targetPtr := add(add(sourceData, 0x20), offset)
                let replacementPtr := add(replacement, 0x20)

                // If surgery length > replacement length, we'll need to pad with zeros
                // Right-align the data (for ABI compatibility)
                let padLength := sub(surgeryLength, replacementLength)

                // Fill the zero padding first
                let targetReplacementPtr := add(targetPtr, padLength)
                for { } lt(targetPtr, targetReplacementPtr) { targetPtr := add(targetPtr, 1) } { mstore8(targetPtr, 0) }

                // Then copy the replacement data to the end for right alignment
                for { let j := 0 } lt(j, replacementLength) { j := add(j, 1) } {
                    mstore8(add(targetPtr, j), byte(0, mload(add(replacementPtr, j))))
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
