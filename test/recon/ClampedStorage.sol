// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { VMCommand, OP, VMState, DepositApproved } from 'src/DataModel.sol';

abstract contract ClampedStorage {
    VMCommand[] commands;
    VMState state = VMState({ registers: new bytes[](256) });

    address clampedTarget;

    uint8 srcReg = 0;
    uint8 destReg = 1;
    uint8 valueReg = 2;

    // Bias towards calldata
    uint8 calldataSRCReg = 3;
    // Bias towards addresses
    uint8 addressSrcReg = 4;

    /// === ARBITRARY SETTERS === ///
    function setClampedTarget(address _clampedTarget) public {
        clampedTarget = _clampedTarget;
    }

    function setSrcReg(bytes memory data) public {
        state.registers[srcReg] = data;
    }

    function setValueReg(bytes memory data) public {
        state.registers[valueReg] = data;
    }

    function setDestReg(bytes memory data) public {
        state.registers[destReg] = data;
    }

    function setCalldataSRCReg(bytes memory data) public {
        state.registers[calldataSRCReg] = data;
    }

    function setAddressSRCReg(bytes memory data) public {
        state.registers[addressSrcReg] = data;
    }
}
