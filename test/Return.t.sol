// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';

contract ReturnTest is SpecTestBase {
    function setUp() public virtual override {
        super.setUp();
    }

    // Tests that RETURN instruction correctly returns data from source register
    function test_Return_BasicExecution() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        // No registers should be modified by RETURN
        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // Output should match source register content
        Asserts.equalsAbiData(out, abi.encode(uint256(42)));
    }

    // Tests that RETURN instruction halts execution - commands after RETURN are not executed
    function test_Return_HaltsExecution() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(100));
        s0.registers[1] = abi.encode(alice);

        VMCommand[] memory cmds = new VMCommand[](3);
        cmds[0] = VmCmd.ret(0);
        // These commands should never execute
        cmds[1] = VmCmd.nativeBal(1, 2); // Would read alice balance into reg[2]
        cmds[2] = VmCmd.ret(2); // Would return reg[2]

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        // No registers should be modified - nativeBal never happened
        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // Output should be from first RETURN only
        Asserts.equalsAbiData(out, abi.encode(uint256(100)));

        // Verify register 2 was never written
        assertEq(s1.registers[2].length, 0);
    }

    // Tests that RETURN correctly handles dynamic data from source register
    function test_Return_DynamicData() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        bytes memory dynamicData = abi.encode('Hello, World!', uint256(123), address(alice));
        s0.registers[0] = dynamicData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        Asserts.equalsAbiData(out, dynamicData);
    }

    // Tests that reading from VOID register returns 32 zero bytes
    function test_Return_FromVoid() public withSnapshot {
        VMState memory s0 = Regs.init(1);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(Regs.voidReg());

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // VOID register always returns 32 zero bytes
        assertEq(out.length, 32);
        Asserts.equalsAbiData(out, abi.encode(uint256(0)));
    }

    // Tests that RETURN ignores dyn bit on source register
    function test_Return_DynBitIgnored() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(999));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(Regs.withDyn(0)); // dyn bit set on source

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // Should return full register content regardless of dyn bit
        Asserts.equalsAbiData(out, abi.encode(uint256(999)));
    }

    // Tests that execution without RETURN instruction returns empty bytes
    function test_Return_NoReturnEmptyOutput() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(alice);

        VMCommand[] memory cmds = new VMCommand[](2);
        cmds[0] = VmCmd.nativeBal(0, 1);
        cmds[1] = VmCmd.gasTo(2);
        // No RETURN instruction

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](2);
        dests[0] = 1;
        dests[1] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // Without explicit RETURN, output should be empty
        assertEq(out.length, 0);
    }

    // Tests RETURN with empty register returns empty bytes
    function test_Return_EmptyRegister() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // Register 0 is uninitialized (empty)

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        assertEq(out.length, 0);
    }

    // Tests RETURN with complex nested data structures
    function test_Return_ComplexData() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Create complex nested data
        uint256[] memory numbers = new uint256[](3);
        numbers[0] = 1;
        numbers[1] = 2;
        numbers[2] = 3;

        bytes memory complexData = abi.encode(alice, numbers, 'Complex test data', true, int256(-42));

        s0.registers[0] = complexData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        Asserts.equalsAbiData(out, complexData);
    }
}
