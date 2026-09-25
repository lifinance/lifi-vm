// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @title StorageSlots
/// @notice Shared storage-slot constants used by MinimalProxy and VM libraries.
library StorageSlots {
    /// @dev Storage slot for the proxy owner address.
    uint256 internal constant OWNER_SLOT = uint256(keccak256('lifi.minimal-proxy.owner'));
}
