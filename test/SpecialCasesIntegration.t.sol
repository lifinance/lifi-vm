// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { Bp } from './lib/Bp.sol';
import { BlueprintEncoder } from '../src/BlueprintEncoder.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { RegisterFile } from '../src/RegisterFile.sol';
import { EchoContract } from './lib/Mocks.sol';
import { CallType } from '../src/DataModel.sol';

contract ArrayEncodingTest is SpecTestBase {
    using RegisterFile for bytes[];

    EchoContract echoContract;

    function setUp() public override {
        super.setUp();
        echoContract = new EchoContract();
    }

    // Test encoding uint256[] array, calling echo, storing result, and rebuilding with CALLDATA_BUILD
    function test_ArrayEncoding_EchoAndRebuild() public withSnapshot {
        // Initialize registers
        VMState memory s0 = Regs.init(10);

        // Create array [1,2,3,4,5]
        uint256[] memory testArray = new uint256[](5);
        testArray[0] = 1;
        testArray[1] = 2;
        testArray[2] = 3;
        testArray[3] = 4;
        testArray[4] = 5;

        // Step 1: Encode the array using abi.encode and store in register 0
        bytes memory encodedArray = abi.encode(testArray);
        s0.registers.setDynamic(0, encodedArray);

        // Step 2: Build calldata for echo(uint256[]) using CALLDATA_BUILD
        bytes4 echoSelector = bytes4(keccak256('echo(uint256[])'));
        bytes memory blueprintForEcho = Bp.d(0); // Dynamic register 0 contains the encoded array

        VMCommand[] memory cmds = new VMCommand[](3);

        // Build calldata for echo function
        cmds[0] = VmCmd.cdb(echoSelector, 1, blueprintForEcho);

        // Step 3: Call echo(uint256[]) and store result in register 2
        cmds[1] = VmCmd.call(
            address(echoContract),
            CallType.CALL,
            Regs.withDyn(2), // destination register for result
            1, // data register (contains calldata)
            Regs.voidReg() // no value
        );

        // Step 4: Use CALLDATA_BUILD again to rebuild calldata from the echo result
        // The result from echo should be the same encoded array
        bytes memory blueprintForRebuild = Bp.d(2); // Dynamic register 2 contains echo result
        cmds[2] = VmCmd.cdb(echoSelector, 3, blueprintForRebuild);

        // Execute commands
        (VMState memory s1,) = run(cmds, s0);

        // Verify registers changed as expected
        uint8[] memory dests = new uint8[](3);
        dests[0] = 1; // First CALLDATA_BUILD result
        dests[1] = 2; // Echo result
        dests[2] = 3; // Second CALLDATA_BUILD result
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify the first CALLDATA_BUILD result matches abi.encodeWithSelector
        bytes memory expectedCalldata = abi.encodeWithSelector(echoSelector, testArray);
        Asserts.assertEncodingMatches(s1.registers[1], expectedCalldata);

        // Verify echo returned the correct array (register 2 contains the raw return data)
        uint256[] memory returnedArray = abi.decode(TestUtils.prependPointer(s1.registers[2]), (uint256[]));
        assertEq(returnedArray.length, 5, 'Array length mismatch');
        assertEq(returnedArray[0], 1, 'Array[0] mismatch');
        assertEq(returnedArray[1], 2, 'Array[1] mismatch');
        assertEq(returnedArray[2], 3, 'Array[2] mismatch');
        assertEq(returnedArray[3], 4, 'Array[3] mismatch');
        assertEq(returnedArray[4], 5, 'Array[4] mismatch');

        // Verify the second CALLDATA_BUILD result also matches abi.encodeWithSelector
        Asserts.assertEncodingMatches(s1.registers[3], expectedCalldata);

        // The two CALLDATA_BUILD results should be identical
        assertEq(keccak256(s1.registers[1]), keccak256(s1.registers[3]), 'CALLDATA_BUILD results should match');
    }
}
