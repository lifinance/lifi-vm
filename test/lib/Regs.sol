// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/DataModel.sol';
import '../../src/VmConstants.sol';

/// @notice Register sugar for VM state initialization and manipulation.
/// @dev Example: VMState state = Regs.init(5);
library Regs {
    /// @notice Initialize VM state with zeroed registers.
    /// @dev Example: VMState state = Regs.init(10);
    /// @param n Number of registers to initialize.
    /// @return VMState with n zeroed registers.
    function init(uint256 n) internal pure returns (VMState memory) {
        VMState memory state;
        state.registers = new bytes[](n);
        return state;
    }

    /// @notice Set MSB to mark a register as dynamic.
    /// @dev Example: uint8 dynReg = Regs.withDyn(5);
    /// @param idx Base register index (0..127).
    /// @return Register index with dynamic flag set.
    function withDyn(uint8 idx) internal pure returns (uint8) {
        return idx | VmConstants.DYN_MASK;
    }

    /// @notice Get the void register index.
    /// @dev Example: uint8 void = Regs.voidReg();
    /// @return Void register index (0x7F).
    function voidReg() internal pure returns (uint8) {
        return VmConstants.VOID_REG;
    }

    /// @notice Extract base register index by removing dynamic flag.
    /// @dev Example: uint8 baseIdx = Regs.baseIdx(0x81); // returns 1
    /// @param reg Register index potentially with dynamic flag.
    /// @return Base register index (0..127).
    function baseIdx(uint8 reg) internal pure returns (uint8) {
        return reg & VmConstants.IDX_MASK;
    }
}
