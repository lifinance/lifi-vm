// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './RegisterFile.sol';
import './RegisterHelpers.sol';
import './VmErrors.sol';
import { SafeTransferLib } from 'solady/utils/SafeTransferLib.sol';

/// @title SafeTransferLib
/// @custom:version 1.0.0
/// @notice Library for handling the SAFE_TRANSFER operation in the virtual machine
library SafeTransferVMLib {
    using SafeTransferLib for address;
    using RegisterFile for bytes[];
    using RegisterHelpers for uint8;
    using RegisterHelpers for bytes;

    /// @notice Executes the SAFE_TRANSFER opcode's logic.
    /// @param registers The VM register array.
    /// @param cmd The unpacked SafeTransfer command parameters.
    function execute(bytes[] memory registers, SafeTransfer memory cmd) internal {
        // Get recipient address from register
        bytes memory toRegData = registers.get(cmd.toReg.idx());
        address to = toRegData.asAddress();

        // Get amount from register
        bytes memory amountRegData = registers.getStatic(cmd.amountReg.idx());
        uint256 amount;
        assembly {
            amount := mload(add(amountRegData, 0x20))
        }

        // Execute transfer - will revert on failure
        cmd.token.safeTransfer(to, amount);
    }
}
