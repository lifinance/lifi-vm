// SPDX-License-Identifier: LGPL-3.0-only
import { console } from 'forge-std/console.sol';

pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { CallType } from '../src/DataModel.sol';
import { EchoContract, ValueChecker, StateChanger, RevertingTarget } from './lib/Mocks.sol';
import { Bp } from './lib/Bp.sol';
import { RegisterFile } from '../src/RegisterFile.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { VmErrors } from '../src/VmErrors.sol';

contract CallTest is SpecTestBase {
    EchoContract echoContract;
    ValueChecker valueChecker;
    StateChanger stateChanger;

    function setUp() public virtual override {
        super.setUp();
        echoContract = new EchoContract();
        valueChecker = new ValueChecker();
        stateChanger = new StateChanger();

        vm.label(address(echoContract), 'Echo');
        vm.label(address(valueChecker), 'ValueChecker');
        vm.label(address(stateChanger), 'StateChanger');
    }

    // Tests that CALL opcode correctly executes external call and stores return data in destination register
    function test_Call_BasicExecution_RegisterInspection() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(echoContract));
        bytes memory testData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[1] = TestUtils.prependLength(testData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, 2, 1, 0);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // Echo returns the exact calldata
        assertEq(s1.registers[2].length, 36);
        assertEq(s1.registers[2], testData);
    }

    // Tests that STATICCALL opcode correctly executes view call
    function test_Call_StaticCall_ViewFunction() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(stateChanger));
        bytes memory callData = abi.encodeWithSignature('viewState()');
        s0.registers[1] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(stateChanger), CallType.STATICCALL, 2, 1, 0);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // viewState returns uint256(0), VM stores first 32 bytes
        assertEq(s1.registers[2].length, 32);
        bytes32 expected = bytes32(uint256(0));
        assertEq(bytes32(s1.registers[2]), expected);
    }

    // Tests that VALUECALL opcode correctly sends value with call
    function test_Call_ValueCall_SendsEther() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(address(valueChecker));
        bytes memory callData = abi.encodeWithSignature('checkValue()');
        s0.registers[1] = TestUtils.prependLength(callData); // Store calldata with length prefix
        uint256 sendValue = 1 ether;
        s0.registers[2] = abi.encode(sendValue);

        vm.deal(address(machine), sendValue);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 3, 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        Asserts.equalsAbiData(s1.registers[3], abi.encode(sendValue));
    }

    // Tests that DELEGATECALL opcode is disallowed
    function test_Call_DelegateCall_IsDisallowed() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(stateChanger));
        bytes memory callData = abi.encodeWithSignature('viewState()');
        s0.registers[1] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(stateChanger), CallType.DELEGATECALL, 2, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(VmErrors.Disallowed.selector));
        run(cmds, s0);
    }

    // Tests that CALL with dynamic flag removes first 32 bytes from return data
    function test_Call_DynamicDestination_RemovesPointer() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        string memory _string = 'Hello World';
        s0.registers[0] = abi.encode(address(echoContract));
        bytes memory longData = abi.encodeWithSignature('echo(string)', _string);
        s0.registers[1] = TestUtils.prependLength(longData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, Regs.withDyn(2), 1, 0);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expectedStringInMemory = abi.encode(_string);
        assembly {
            // base points to the "offset" word inside the abi.encode payload (data start)
            let base := add(expectedStringInMemory, 0x20)
            // Overwrite the offset word with the new bytes length: 32 (len word) + strlen (also 32)
            mstore(base, add(0x20, 32))
            // Repoint the high-level variable: now it's a proper bytes whose content is <len><data>
            expectedStringInMemory := base
        }
        assertEq(expectedStringInMemory, s1.registers[2]);
    }

    // Tests that writing CALL result to VOID register is discarded
    function test_Call_WriteToVoid_Ignored() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(address(echoContract));
        bytes memory testData = abi.encodeWithSignature('test()');
        s0.registers[1] = TestUtils.prependLength(testData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, Regs.voidReg(), 1, 0);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests that reverting calls bubble up revert messages
    function test_Call_RevertingCall_BubblesMessage() public withSnapshot {
        // Create a reverting contract
        RevertingTarget reverter = new RevertingTarget();
        vm.label(address(reverter), 'RevertingTarget');

        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(reverter));
        bytes memory callData = abi.encodeWithSignature('alwaysReverts()');
        s0.registers[1] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(reverter), CallType.CALL, 2, 1, 0);

        // revert message from RevertingTarget.alwaysReverts()
        vm.expectRevert('Always reverts');
        run(cmds, s0);
    }

    // Tests that STATICCALL to non-view function reverts
    function test_Call_StaticCallToNonView_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(stateChanger));
        bytes memory callData = abi.encodeWithSignature('changeState(uint256)', 42);
        s0.registers[1] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(stateChanger), CallType.STATICCALL, 2, 1, 0);

        vm.expectRevert();
        run(cmds, s0);
    }

    // Tests that CALL with calldata shorter than 32  bytes reverts
    function test_Call_ShortCallData_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(address(echoContract));
        // Create calldata that's only 31 bytes
        bytes memory shortCallData = new bytes(31);
        // Fill with some data
        for (uint256 i = 0; i < 31; i++) {
            shortCallData[i] = bytes1(uint8(i));
        }
        s0.registers[1] = shortCallData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, 2, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(VmErrors.InvalidCallDataLength.selector));
        run(cmds, s0);
    }

    // Tests that VALUECALL with value shorter than 32 bytes reverts
    function test_ValueCall_ShortValue_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(address(valueChecker));
        bytes memory callData = abi.encodeWithSignature('checkValue()');
        s0.registers[1] = TestUtils.prependLength(callData);
        // Create value data that's only 31 bytes
        bytes memory shortValue = new bytes(31);
        s0.registers[2] = shortValue;

        vm.deal(address(machine), 1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 3, 1, 2);

        vm.expectRevert(abi.encodeWithSelector(RegisterFile.InvalidStaticData.selector));
        run(cmds, s0);
    }

    // Tests that VALUECALL with value exactly 32 bytes succeeds
    function test_ValueCall_MinimumValue_Succeeds() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(address(valueChecker));
        bytes memory callData = abi.encodeWithSignature('checkValue()');
        s0.registers[1] = TestUtils.prependLength(callData);
        // Use abi.encode to ensure exactly 32 bytes
        uint256 sendValue = 0.5 ether;
        s0.registers[2] = abi.encode(sendValue);

        vm.deal(address(machine), sendValue);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 3, 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        // Should succeed
        Asserts.equalsAbiData(s1.registers[3], abi.encode(sendValue));
    }

    // Tests that VALUECALL can transfer ETH without any calldata
    function test_ValueCall_TransferETH_EmptyCalldata() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(address(echoContract));
        // Empty calldata - just the length prefix (32 bytes with value 0)
        s0.registers[1] = TestUtils.prependLength(hex'');
        uint256 sendValue = 1 ether;
        s0.registers[2] = abi.encode(sendValue);

        // Record initial balance
        uint256 initialBalance = address(echoContract).balance;

        vm.deal(address(machine), sendValue);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.VALUECALL, 3, 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify ETH was transferred
        assertEq(address(echoContract).balance, initialBalance + sendValue);
        // Empty calldata returns empty data
        assertEq(s1.registers[3].length, 0);
    }

    // Tests that CALL to address with no bytecode succeeds (doesn't revert by default)
    function test_Call_NoBytecode_Succeeds() public withSnapshot {
        address emptyAddress = address(0xDEAD);
        vm.etch(emptyAddress, hex'');
        vm.label(emptyAddress, 'EmptyAddress');

        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(emptyAddress);
        bytes memory callData = abi.encodeWithSignature('nonExistent()');
        s0.registers[1] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(emptyAddress, CallType.CALL, 2, 1, 0);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // Empty return data for calls to addresses without code - stored as empty bytes in register
        assertEq(s1.registers[2].length, 0);
    }
}
