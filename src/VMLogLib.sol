// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './RegisterFile.sol';
import './VmErrors.sol';
import './RegisterHelpers.sol';

/// @title VMLogLib
/// @custom:version 1.0.0
/// @notice Library for handling the LOG operation that emits events with raw bytes data.
library VMLogLib {
    using RegisterHelpers for uint8;
    using RegisterFile for bytes[];
    /// @notice Event emitted for static data with 1 register (32 bytes)

    event VMLogStatic1(bytes32 data1);

    /// @notice Event emitted for static data with 2 registers (64 bytes)
    event VMLogStatic2(bytes32 data1, bytes32 data2);

    /// @notice Event emitted for static data with 3 registers (96 bytes)
    event VMLogStatic3(bytes32 data1, bytes32 data2, bytes32 data3);

    /// @notice Event emitted for static data with 4 registers (128 bytes)
    event VMLogStatic4(bytes32 data1, bytes32 data2, bytes32 data3, bytes32 data4);

    /// @notice Event emitted for static data with 5 registers (160 bytes)
    event VMLogStatic5(bytes32 data1, bytes32 data2, bytes32 data3, bytes32 data4, bytes32 data5);

    /// @notice Event emitted for dynamic data from a register
    event VMLogDyn(bytes data);

    /// @notice Executes the LOG opcode's logic.
    /// @param vmState The current VM state (in memory).
    /// @param cmd The unpacked Log command parameters.
    function execute(VMState memory vmState, Log memory cmd) internal {
        // Check if variant is valid before casting to enum
        if (cmd.variant > uint8(LogVariant.DYNAMIC)) {
            revert VmErrors.InvalidLogVariant();
        }

        LogVariant variant = LogVariant(cmd.variant);

        if (variant == LogVariant.STATIC_1) {
            executeStatic1(vmState.registers, cmd.sourceRegs);
        } else if (variant == LogVariant.STATIC_2) {
            executeStatic2(vmState.registers, cmd.sourceRegs);
        } else if (variant == LogVariant.STATIC_3) {
            executeStatic3(vmState.registers, cmd.sourceRegs);
        } else if (variant == LogVariant.STATIC_4) {
            executeStatic4(vmState.registers, cmd.sourceRegs);
        } else if (variant == LogVariant.STATIC_5) {
            executeStatic5(vmState.registers, cmd.sourceRegs);
        } else if (variant == LogVariant.DYNAMIC) {
            executeDynamic(vmState.registers, cmd.sourceRegs);
        }
    }

    /// @notice Extracts a register index from packed sourceRegs at the given byte position
    function extractRegister(uint256 sourceRegs, uint8 position) private pure returns (uint8) {
        // Each register is 1 byte, shift to get the byte at position
        return uint8((sourceRegs >> ((25 - position) * 8)));
    }

    /// @notice Executes LOG for 1 static register
    function executeStatic1(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg1 = extractRegister(sourceRegs, 0);
        bytes memory regData = registers.getStatic(reg1.idx());
        bytes32 data1;
        assembly {
            data1 := mload(add(regData, 0x20))
        }

        emit VMLogStatic1(data1);
    }

    /// @notice Executes LOG for 2 static registers
    function executeStatic2(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg1 = extractRegister(sourceRegs, 0);
        uint8 reg2 = extractRegister(sourceRegs, 1);

        bytes memory regData1 = registers.getStatic(reg1.idx());
        bytes memory regData2 = registers.getStatic(reg2.idx());

        bytes32 data1;
        bytes32 data2;
        assembly {
            data1 := mload(add(regData1, 0x20))
            data2 := mload(add(regData2, 0x20))
        }

        emit VMLogStatic2(data1, data2);
    }

    /// @notice Executes LOG for 3 static registers
    function executeStatic3(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg1 = extractRegister(sourceRegs, 0);
        uint8 reg2 = extractRegister(sourceRegs, 1);
        uint8 reg3 = extractRegister(sourceRegs, 2);

        bytes memory regData1 = registers.getStatic(reg1.idx());
        bytes memory regData2 = registers.getStatic(reg2.idx());
        bytes memory regData3 = registers.getStatic(reg3.idx());

        bytes32 data1;
        bytes32 data2;
        bytes32 data3;
        assembly {
            data1 := mload(add(regData1, 0x20))
            data2 := mload(add(regData2, 0x20))
            data3 := mload(add(regData3, 0x20))
        }

        emit VMLogStatic3(data1, data2, data3);
    }

    /// @notice Executes LOG for 4 static registers
    function executeStatic4(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg1 = extractRegister(sourceRegs, 0);
        uint8 reg2 = extractRegister(sourceRegs, 1);
        uint8 reg3 = extractRegister(sourceRegs, 2);
        uint8 reg4 = extractRegister(sourceRegs, 3);

        bytes memory regData1 = registers.getStatic(reg1.idx());
        bytes memory regData2 = registers.getStatic(reg2.idx());
        bytes memory regData3 = registers.getStatic(reg3.idx());
        bytes memory regData4 = registers.getStatic(reg4.idx());

        bytes32 data1;
        bytes32 data2;
        bytes32 data3;
        bytes32 data4;
        assembly {
            data1 := mload(add(regData1, 0x20))
            data2 := mload(add(regData2, 0x20))
            data3 := mload(add(regData3, 0x20))
            data4 := mload(add(regData4, 0x20))
        }

        emit VMLogStatic4(data1, data2, data3, data4);
    }

    /// @notice Executes LOG for 5 static registers
    function executeStatic5(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg1 = extractRegister(sourceRegs, 0);
        uint8 reg2 = extractRegister(sourceRegs, 1);
        uint8 reg3 = extractRegister(sourceRegs, 2);
        uint8 reg4 = extractRegister(sourceRegs, 3);
        uint8 reg5 = extractRegister(sourceRegs, 4);

        bytes memory regData1 = registers.getStatic(reg1.idx());
        bytes memory regData2 = registers.getStatic(reg2.idx());
        bytes memory regData3 = registers.getStatic(reg3.idx());
        bytes memory regData4 = registers.getStatic(reg4.idx());
        bytes memory regData5 = registers.getStatic(reg5.idx());

        bytes32 data1;
        bytes32 data2;
        bytes32 data3;
        bytes32 data4;
        bytes32 data5;
        assembly {
            data1 := mload(add(regData1, 0x20))
            data2 := mload(add(regData2, 0x20))
            data3 := mload(add(regData3, 0x20))
            data4 := mload(add(regData4, 0x20))
            data5 := mload(add(regData5, 0x20))
        }

        emit VMLogStatic5(data1, data2, data3, data4, data5);
    }

    /// @notice Executes LOG for dynamic data
    function executeDynamic(bytes[] memory registers, uint256 sourceRegs) private {
        uint8 reg = extractRegister(sourceRegs, 0);
        bytes memory data = registers.get(reg.idx());

        emit VMLogDyn(data);
    }
}
