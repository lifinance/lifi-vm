// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, LogVariant } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { RegisterFile } from '../src/RegisterFile.sol';

contract LogTest is SpecTestBase {
    // Tests that LOG STATIC_1 opcode correctly emits VMLogStatic1 event with static data
    function test_Log_Static1_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(0));

        bytes32[5] memory words;
        words[0] = bytes32(uint256(42));
        Asserts.emittedStatic(words, 1);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG STATIC_2 opcode correctly emits VMLogStatic2 event with two static values
    function test_Log_Static2_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_2), sourceRegs);

        bytes32[5] memory words;
        words[0] = bytes32(uint256(42));
        words[1] = bytes32(uint256(uint160(alice)));
        Asserts.emittedStatic(words, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG STATIC_3 opcode correctly emits VMLogStatic3 event with three static values
    function test_Log_Static3_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_3), sourceRegs);

        bytes32[5] memory words;
        words[0] = bytes32(uint256(42));
        words[1] = bytes32(uint256(uint160(alice)));
        words[2] = bytes32(uint256(0xDEADBEEF));
        Asserts.emittedStatic(words, 3);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG STATIC_4 opcode correctly emits VMLogStatic4 event with four static values
    function test_Log_Static4_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));
        s0.registers[3] = abi.encode(uint256(999));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184) | (uint256(3) << 176);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_4), sourceRegs);

        bytes32[5] memory words;
        words[0] = bytes32(uint256(42));
        words[1] = bytes32(uint256(uint160(alice)));
        words[2] = bytes32(uint256(0xDEADBEEF));
        words[3] = bytes32(uint256(999));
        Asserts.emittedStatic(words, 4);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG STATIC_5 opcode correctly emits VMLogStatic5 event with five static values
    function test_Log_Static5_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(6);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));
        s0.registers[3] = abi.encode(uint256(999));
        s0.registers[4] = abi.encode(bytes32('Hello VM'));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs =
            (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184) | (uint256(3) << 176) | (uint256(4) << 168);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_5), sourceRegs);

        bytes32[5] memory words;
        words[0] = bytes32(uint256(42));
        words[1] = bytes32(uint256(uint160(alice)));
        words[2] = bytes32(uint256(0xDEADBEEF));
        words[3] = bytes32(uint256(999));
        words[4] = bytes32('Hello VM');
        Asserts.emittedStatic(words, 5);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG DYNAMIC opcode correctly emits VMLogDyn event with dynamic data
    function test_Log_Dynamic_EmitsEvent() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        bytes memory dynamicData =
            abi.encode(uint256(42), address(alice), 'This is a long dynamic string that exceeds 32 bytes');
        s0.registers[0] = dynamicData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.DYNAMIC), uint256(0));

        Asserts.emittedDynamic(dynamicData);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG DYNAMIC works with dyn bit set on register reference
    function test_Log_Dynamic_WithDynBit() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        bytes memory dynamicData = abi.encode(uint256(123), 'Dynamic content');
        s0.registers[0] = dynamicData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.DYNAMIC), uint256(Regs.withDyn(0)));

        Asserts.emittedDynamic(dynamicData);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG STATIC reverts when register is not exactly 32 bytes
    function test_Log_Static1_NonStaticRegister_ReadsFirst32Bytes() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // Create a register with more than 32 bytes
        bytes memory longData = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            longData[i] = bytes1(uint8(i + 1));
        }
        for (uint256 i = 32; i < 64; i++) {
            longData[i] = bytes1(uint8(0xFF));
        }
        s0.registers[0] = longData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(0));

        // Expect revert with InvalidStaticData error
        vm.expectRevert(abi.encodeWithSelector(RegisterFile.InvalidStaticData.selector));
        run(cmds, s0);
    }

    // Tests that LOG STATIC with register containing less than 32 bytes reverts
    function test_Log_Static1_ShortRegister_PadsWithZeros() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // Create a register with less than 32 bytes
        s0.registers[0] = abi.encodePacked(uint128(0x1234567890ABCDEF));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(0));

        // Expect revert with InvalidStaticData error
        vm.expectRevert(abi.encodeWithSelector(RegisterFile.InvalidStaticData.selector));
        run(cmds, s0);
    }

    // Tests that LOG with VOID register logs zero value for static logs
    function test_Log_Static1_VoidRegister_LogsZero() public withSnapshot {
        VMState memory s0 = Regs.init(1);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(Regs.voidReg()) << 200);

        bytes32[5] memory words;
        words[0] = bytes32(0);
        Asserts.emittedStatic(words, 1);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that LOG DYNAMIC with VOID register logs empty bytes
    function test_Log_Dynamic_VoidRegister_LogsEmpty() public withSnapshot {
        VMState memory s0 = Regs.init(1);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.DYNAMIC), uint256(Regs.voidReg()) << 200);

        Asserts.emittedDynamic(hex'0000000000000000000000000000000000000000000000000000000000000000');

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that invalid log variant reverts
    function test_Log_InvalidVariant_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(1);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        // First create a valid log command with variant 0 (STATIC_1)
        cmds[0] = VmCmd.logOp(0, uint256(0));

        // Now manually modify the packed data to have an invalid variant (6)
        // The variant is stored in the first byte (bits 248-255) of the packed data
        // Why you ask? Command packing checks itself if the variant is wrong - we want to
        // test the execution reverting, not the packing here.
        bytes32 packedData = cmds[0].data;
        assembly {
            // Clear the first byte (variant) and set it to 6
            packedData := or(and(packedData, not(shl(248, 0xFF))), shl(248, 6))
        }
        cmds[0].data = packedData;

        vm.expectRevert(abi.encodeWithSelector(VmErrors.InvalidLogVariant.selector));
        run(cmds, s0);
    }

    // Tests that multiple LOG operations emit multiple events in sequence
    function test_Log_MultipleOperations_EmitsMultipleEvents() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(100));
        s0.registers[1] = abi.encode(address(bob));
        bytes memory dynamicData = abi.encode('Dynamic log data');
        s0.registers[2] = dynamicData;

        VMCommand[] memory cmds = new VMCommand[](3);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(0) << 200);
        cmds[1] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(1) << 200);
        cmds[2] = VmCmd.logOp(uint8(LogVariant.DYNAMIC), uint256(2) << 200);

        bytes32[5] memory words1;
        words1[0] = bytes32(uint256(100));
        Asserts.emittedStatic(words1, 1);

        bytes32[5] memory words2;
        words2[0] = bytes32(uint256(uint160(bob)));
        Asserts.emittedStatic(words2, 1);

        Asserts.emittedDynamic(dynamicData);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }
}
