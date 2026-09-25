// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './CommandPacking.sol';
import './MemoryUtils.sol';
import './RegisterFile.sol';
import './RegisterHelpers.sol';
import './VmErrors.sol';
import './VmConstants.sol';

/// @title Explode Library
/// @custom:version 1.0.0
/// @notice Library for handling the EXPLODE operation in the virtual machine
library ExplodeLib {
    using RegisterFile for bytes[];
    using RegisterHelpers for uint8;

    /// @notice Executes the EXPLODE opcode's logic.
    /// @dev Splits an ABI tuple block into register-shaped ABI field blobs, one per destination.
    ///      The source is read once up front, so a destination may alias the source register.
    /// @dev A dynamic slice runs from this destination's head offset to the next dynamic
    ///      destination's head offset (intervening static destinations do not terminate it), or to
    ///      the end of `source`. The length word the field carries at its own start is never
    ///      compared against that extent, so a callee-controlled source can yield a
    ///      non-canonical register. Deliberate, see docs/isa.md "Register Canonicality": do not
    ///      hash, sign, or byte-compare such a register's payload without re-validating it;
    ///      decode it instead.
    /// @param registers The VM register array.
    /// @param e The unpacked Explode command parameters.
    function execute(bytes[] memory registers, Explode memory e) internal pure {
        bytes memory source = registers.get(e.sourceReg.idx());
        uint256 sourceLen = source.length;
        if ((sourceLen & (VmConstants.WORD_SIZE - 1)) != 0) revert VmErrors.InvalidRegisterLength();

        uint256 destCount = e.destCount;
        uint256 packedDests = e.packedDests;
        uint256 headLen = destCount * VmConstants.WORD_SIZE;
        if (sourceLen < headLen) revert VmErrors.OutOfBounds();

        for (uint256 i; i < destCount;) {
            uint8 destReg = uint8(packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - i * 8));
            if (destReg.isDyn()) {
                uint256 start = _readWord(source, i * VmConstants.WORD_SIZE);
                _validateDynamicOffset(start, headLen, sourceLen);

                uint256 end = _resolveDynamicEnd(source, packedDests, i, destCount, headLen, sourceLen);

                // invariant: end > start (validated below) so slice length is positive.
                if (end <= start) revert VmErrors.OutOfBounds();
                registers.set(destReg.idx(), MemoryUtils.slice(source, start, end - start));
            } else {
                registers.set(
                    destReg.idx(), MemoryUtils.slice(source, i * VmConstants.WORD_SIZE, VmConstants.WORD_SIZE)
                );
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Locates the next dynamic destination after `i`; its head word is the slice end
    ///      for destination `i`. If no later dynamic destination exists, the slice extends
    ///      to the end of `source`. The scan stops at the first dynamic destination it finds,
    ///      so successive scans never overlap: across one command the loop below runs at most
    ///      `destCount - 1` times in total (25 under `MAX_EXPLODE_DESTS`), not `O(destCount^2)`.
    function _resolveDynamicEnd(
        bytes memory source,
        uint256 packedDests,
        uint256 i,
        uint256 destCount,
        uint256 headLen,
        uint256 sourceLen
    )
        private
        pure
        returns (uint256 end)
    {
        end = sourceLen;
        for (uint256 j = i + 1; j < destCount;) {
            if (uint8(packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - j * 8)).isDyn()) {
                end = _readWord(source, j * VmConstants.WORD_SIZE);
                _validateDynamicOffset(end, headLen, sourceLen);
                break;
            }
            unchecked {
                ++j;
            }
        }
    }

    function _readWord(bytes memory data, uint256 offset) private pure returns (uint256 word) {
        assembly {
            word := mload(add(add(data, 0x20), offset))
        }
    }

    function _validateDynamicOffset(uint256 offset, uint256 headLen, uint256 sourceLen) private pure {
        if (offset < headLen || offset >= sourceLen || (offset & (VmConstants.WORD_SIZE - 1)) != 0) {
            revert VmErrors.OutOfBounds();
        }
    }
}
