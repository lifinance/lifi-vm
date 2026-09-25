// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './VmErrors.sol';

/// @custom:version 1.1.1
library MemoryUtils {
    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory result) {
        // Wrapped in `unchecked`: the first clause proves `start <= data.length`, so `data.length - start`
        // cannot underflow. `start + length` is avoided because it would panic on overflow instead of
        // reverting OutOfBounds.
        unchecked {
            if (start > data.length || length > data.length - start) revert VmErrors.OutOfBounds();
        }
        assembly {
            result := mload(0x40) // Get free memory pointer
            mstore(result, length) // Store length at start of result
            let src := add(add(data, 32), start) // Calculate source offset
            let dest := add(result, 32) // Destination starts at result + 32

            // Copy 32 bytes at a time
            {
                // copy full 32-byte words
                let end := add(dest, and(length, not(31)))
                for { } lt(dest, end) {
                    dest := add(dest, 32)
                    src := add(src, 32)
                } { mstore(dest, mload(src)) }
                // copy remaining bytes (if any) with masking
                let rem := and(length, 31)
                if rem {
                    // keep only the top `rem` bytes from src; low bytes become zero
                    let lowMask := sub(shl(mul(8, sub(32, rem)), 1), 1)
                    mstore(dest, and(mload(src), not(lowMask)))
                }
            }

            // Update free memory pointer
            mstore(0x40, add(add(result, 32), and(add(length, 31), not(31)))) // Update free memory pointer
        }
    }
}
