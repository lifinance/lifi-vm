// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { VmErrors } from '../VmErrors.sol';
import { StorageSlots } from '../StorageSlots.sol';
import { Tstorish } from './TStorish.sol';

/// @title Minimal Proxy
/// @custom:version 1.0.0
/// @dev A minimal proxy that authenticates the sender and forwards all calls to the VM address
contract MinimalProxy is Tstorish {
    address public immutable owner;
    address public immutable vmAddress;
    address public immutable factory;
    // Storage slot used for the reentrancy guard, whether using TSTORE or SSTORE.
    uint256 private constant _REENTRANCY_GUARD_SLOT = uint256(keccak256('lifi.minimal-proxy.tstorish-slot'));
    /// @dev Storage slot for the owner address, readable by delegatecalled VM code via sload.
    uint256 internal constant _OWNER_SLOT = StorageSlots.OWNER_SLOT;
    /// @dev Storage slot for one-time factory initialization flag.
    uint256 private constant _INITIALIZED_SLOT = uint256(keccak256('lifi.minimal-proxy.initialized'));

    modifier onlyOwner() {
        if (msg.sender != owner) revert VmErrors.Unauthorized();
        _;
    }

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner && msg.sender != factory) revert VmErrors.Unauthorized();
        if (msg.sender == factory) {
            uint256 initializedSlot = _INITIALIZED_SLOT;
            uint256 initialized;
            assembly ('memory-safe') {
                initialized := sload(initializedSlot)
                sstore(initializedSlot, not(initialized))
            }
            if (initialized != 0) revert VmErrors.AlreadyInitialized();
        }
        _;
    }

    modifier setReentrancyGuard() {
        _setReentrancyGuard();
        _;
    }

    /**
     * @notice Internal function to set the reentrancy guard using either TSTORE or SSTORE.
     * Called as part of functions that require reentrancy protection. Reverts if called
     * again before the reentrancy guard has been cleared.
     * @dev Note that the caller is set to the value; this enables external contracts to
     * ascertain the account originating the ongoing call while handling the call using
     * exttload. Also note that the value is actually set to a value of 1 when cleared;
     * this results in a significant efficiency improvement for environments that do not
     * yet support tstore, and additionally provides a mechanism to determine whether the
     * contract has been entered in a previous stage of the current transaction for
     * environments that do support it.
     */
    function _setReentrancyGuard() internal {
        // Retrieve the current reentrancy sentinel value.
        uint256 entered = _getTstorish(_REENTRANCY_GUARD_SLOT);
        assembly ('memory-safe') {
            // Consider any value over 1 as indicating that reentrancy is disallowed.
            if gt(entered, 1) {
                // revert ReentrantCall(address existingCaller)
                mstore(0, 0xf57c448b)
                mstore(0x20, entered)
                revert(0x1c, 0x24)
            }

            // Use the address of the caller for the updated sentinel value.
            entered := caller()
        }

        // Store the updated sentinel value.
        _setTstorish(_REENTRANCY_GUARD_SLOT, entered);
    }

    /**
     * @notice Internal function to clear the reentrancy guard using either TSTORE or SSTORE.
     * Called as part of functions that require reentrancy protection.
     */
    function _clearReentrancyGuard() internal {
        // Store a value of 1 for the updated sentinel value. This indicates that the
        // contract can be entered again while keeping the sentinel storage slot dirty.
        _setTstorish(_REENTRANCY_GUARD_SLOT, 1);
    }

    constructor(address _owner, address _vmAddress, address _factory) Tstorish() {
        owner = _owner;
        vmAddress = _vmAddress;
        factory = _factory;
        // Store owner in a known storage slot so delegatecalled VM code can read it via sload.
        uint256 ownerSlot = _OWNER_SLOT;
        assembly ('memory-safe') {
            sstore(ownerSlot, _owner)
        }
    }

    function _forward() internal setReentrancyGuard returns (bytes memory out) {
        (bool ok, bytes memory ret) = vmAddress.delegatecall(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _clearReentrancyGuard();
        return ret;
    }

    fallback() external payable onlyOwnerOrFactory {
        bytes memory out = _forward();
        assembly ('memory-safe') {
            return(add(out, 0x20), mload(out))
        }
    }

    receive() external payable { }
}
