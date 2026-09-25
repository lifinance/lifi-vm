// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './VmConstants.sol';
import './VmErrors.sol';

/// @title RegisterHelpers
/// @custom:version 1.0.0
/// @notice Helper functions for VM register manipulation, including index extraction, dynamic flag checking, and type conversions
library RegisterHelpers {
    /// @dev Extract register index (lower 7 bits)
    function idx(uint8 r) internal pure returns (uint8) {
        return r & VmConstants.IDX_MASK;
    }

    /// @dev Check if register uses dynamic allocation (high bit set)
    function isDyn(uint8 r) internal pure returns (bool) {
        return (r & VmConstants.DYN_MASK) != 0;
    }

    /// @dev Encode uint256 as 32-byte array for register storage
    function encUint(uint256 x) internal pure returns (bytes memory b) {
        b = new bytes(32);
        assembly {
            mstore(add(b, 32), x)
        }
    }

    /// @dev Extract address from bytes (expects abi.encode(address) format)
    function asAddress(bytes memory b) internal pure returns (address a) {
        if (b.length != 32) revert VmErrors.InvalidAddressBytes();
        assembly {
            a := and(mload(add(b, 32)), 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
