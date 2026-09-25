// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/DataModel.sol';
import '../../src/VirtualMachine.sol';

/// @notice VM execution helpers for running commands and capturing results.
/// @dev Example: (VMState memory final, bytes memory out) = VmRun.run(vm, cmds, state);
library VmRun {
    /// @notice Run VM expecting revert and capture error data.
    /// @dev Example: bytes memory err = VmRun.runRevert(vm, cmds, state);
    /// @param vm Virtual machine instance.
    /// @param cmds Command array to execute.
    /// @param s Initial VM state.
    /// @return errData Raw revert data.
    function runRevert(
        VirtualMachine vm,
        VMCommand[] memory cmds,
        VMState memory s
    )
        internal
        returns (bytes memory errData)
    {
        try vm.runVM(cmds, s) {
            revert('Expected revert but call succeeded');
        } catch (bytes memory err) {
            errData = err;
        }
    }
}
