// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './RegisterFile.sol';
import './interfaces/IERC20.sol';
import './VmErrors.sol';
import './VmConstants.sol';
import { StorageSlots } from './StorageSlots.sol';
import { SafeTransferLib } from 'solady/utils/SafeTransferLib.sol';

/// @title DepositApproved Library
/// @custom:version 1.0.0
/// @notice Library for handling the DEPOSIT_APPROVED operation in the virtual machine
library DepositApprovedLib {
    using SafeTransferLib for address;

    /// @dev Storage slot for the owner address, shared with MinimalProxy.
    uint256 private constant _OWNER_SLOT = StorageSlots.OWNER_SLOT;

    /// @notice Executes the deposit approved operation, which deposits ERC20 tokens from the proxy owner
    /// @param depositCmd The DEPOSIT_APPROVED command parameters
    /// @param maxDeposit The maximum amount that can be deposited

    function depositApproved(DepositApproved memory depositCmd, uint256 maxDeposit) internal returns (uint256) {
        address token = depositCmd.token;
        uint256 approvedAmount;
        uint256 userBalance;
        uint256 amount;
        uint256 pre;
        uint256 post;
        address tokenOwner;
        uint256 ownerSlot = _OWNER_SLOT;

        assembly {
            // Load the owner from the dedicated storage slot.
            // Falls back to caller() when not in proxy context (slot is zero).
            tokenOwner := sload(ownerSlot)
            if iszero(tokenOwner) { tokenOwner := caller() }

            // Check if token contract exists
            if iszero(extcodesize(token)) {
                // revert CallToNonContract()
                mstore(0, 0xba18390000000000000000000000000000000000000000000000000000000000)
                revert(0, 4)
            }

            // Reserve ABI buffer [ptr .. ptr+0x7f]
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x80))

            // Prepare allowance call: allowance(owner, address(this))
            mstore(ptr, 0xdd62ed3e00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), tokenOwner)
            mstore(add(ptr, 0x24), address())
            let ok := staticcall(gas(), token, ptr, 0x44, ptr, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { approvedAmount := mload(ptr) }

            // Prepare balanceOf call: balanceOf(owner)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), tokenOwner)
            ok := staticcall(gas(), token, ptr, 0x24, ptr, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { userBalance := mload(ptr) }

            // Transfer the minimum of approved amount and user balance
            amount := approvedAmount
            if gt(amount, userBalance) { amount := userBalance }
            // Apply maxDeposit limit
            if gt(amount, maxDeposit) { amount := maxDeposit }

            // FOT support: get current balance
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), address())
            ok := staticcall(gas(), token, ptr, 0x24, ptr, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            if ok { pre := mload(ptr) }
            if iszero(ok) {
                // revert GetBalanceFailed()
                mstore(0, 0xda20f3fb00000000000000000000000000000000000000000000000000000000)
                revert(0, 4)
            }
        }

        if (amount == 0) return 0;

        // Handles non-standard ERC20s.
        token.safeTransferFrom(tokenOwner, address(this), amount);

        assembly {
            // Reserve a fresh ABI buffer [ptr .. ptr+0x7f]
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x80))
            // FOT support: measure actual received
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), address())
            let ok := staticcall(gas(), token, ptr, 0x24, ptr, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { post := mload(ptr) }
        }

        return post - pre;
    }
}
