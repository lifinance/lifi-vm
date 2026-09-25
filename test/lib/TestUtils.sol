// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import 'forge-std/Vm.sol';

/// @notice Common test utilities and helpers for VM testing.
library TestUtils {
    /// @notice Get the Foundry VM instance for cheatcodes.
    /// @dev Consolidates the VM instance creation in one place.
    /// @return vm The Foundry VM instance.
    function getVm() internal pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
    }

    /// @notice Prepends bytes data with its length as a 32-byte word.
    /// @dev The VM now expects all calldata in memory to be prefixed with a word containing the bytes length.
    /// @param data The original bytes data to prepend with length.
    /// @return result The new bytes data with length prefix.
    function prependLength(bytes memory data) internal pure returns (bytes memory result) {
        uint256 dataLength = data.length;
        result = new bytes(32 + dataLength);

        assembly {
            // Store the length in the first 32 bytes
            mstore(add(result, 0x20), dataLength)

            // Copy the original data after the length word
            let src := add(data, 0x20)
            let dst := add(result, 0x40)
            let end := add(src, dataLength)

            for { } lt(src, end) { } {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }

    /// @notice Prepends bytes data with a 0x20 offset pointer as a 32-byte word.
    /// @dev This is useful for dynamic data that needs the ABI offset pointer format.
    /// @param data The original bytes data to prepend with pointer.
    /// @return result The new bytes data with 0x20 pointer prefix.
    function prependPointer(bytes memory data) internal pure returns (bytes memory result) {
        uint256 dataLength = data.length;
        result = new bytes(32 + dataLength);

        assembly {
            // Store the pointer value 0x20 in the first 32 bytes
            mstore(add(result, 0x20), 0x20)

            // Copy the original data after the pointer word
            let src := add(data, 0x20)
            let dst := add(result, 0x40)
            let end := add(src, dataLength)

            for { } lt(src, end) { } {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }

    /// @notice Strips the length prefix from bytes data.
    /// @dev The opposite of prependLength - removes the first 32 bytes (length word).
    /// @param data The bytes data with length prefix.
    /// @return result The bytes data without the length prefix.
    function stripLength(bytes memory data) internal pure returns (bytes memory result) {
        require(data.length >= 32, 'Data too short to have length prefix');

        uint256 dataLength = data.length - 32;
        result = new bytes(dataLength);

        assembly {
            // Copy data starting from byte 32 (skipping the length word)
            let src := add(data, 0x40)
            let dst := add(result, 0x20)
            let end := add(src, dataLength)

            for { } lt(src, end) { } {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }
}
