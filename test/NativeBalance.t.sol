// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';

contract NativeBalanceTest is SpecTestBase {
    function setUp() public virtual override {
        super.setUp();
        vm.label(alice, 'alice');
        vm.label(bob, 'bob');
    }

    // Tests that NATIVE_BALANCE opcode correctly reads account balance into destination register
    function test_NativeBalance_BasicExecution() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(alice);

        uint256 expected = alice.balance;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(0, 1);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        Asserts.equalsAbiData(s1.registers[1], abi.encode(expected));
    }

    // Tests that NATIVE_BALANCE correctly reads balance after vm.deal operation
    function test_NativeBalance_DealAndCheck() public withSnapshot {
        address target = address(0xCAFE);
        vm.label(target, 'target');

        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(target);

        uint256 dealtAmount = 42 ether;
        vm.deal(target, dealtAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(0, 1);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        Asserts.equalsAbiData(s1.registers[1], abi.encode(dealtAmount));
    }

    // Tests that NATIVE_BALANCE opcode ignores dyn flag when writing to destination register
    function test_NativeBalance_DynFlagIgnored() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(bob);

        uint256 expected = bob.balance;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(0, Regs.withDyn(1)); // dyn bit ignored for writes

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1].length, 32);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(expected));

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that writing NATIVE_BALANCE result to VOID register is discarded
    function test_NativeBalance_WriteToVoid_Ignored() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(alice);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(0, Regs.voidReg()); // write to VOID is discarded

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that reading from VOID register returns address(0) balance
    function test_NativeBalance_ReadFromVoid_AddressZero() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Never assume zero. Capture actual zero-address balance at start.
        uint256 expectedZero = address(0).balance;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(Regs.voidReg(), 1);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(expectedZero));
    }
}
