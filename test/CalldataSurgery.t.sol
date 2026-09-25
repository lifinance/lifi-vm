// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, SurgeryDescriptor, OP } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { VmErrors } from '../src/VmErrors.sol';

contract CalldataSurgeryTest is SpecTestBase {
    // Tests that CALLDATA_SURGERY correctly modifies calldata and maintains length
    // Before: [1111111111111111] [2222222222222222]
    //          <---- 32 bytes --> <---- 32 bytes -->
    // Surgery: Replace first 32 bytes with [3333333333333333]
    // After:  [3333333333333333] [2222222222222222]
    function test_CalldataSurgery_SingleSurgery_LengthPreserved() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Source data to modify
        bytes memory sourceData = abi.encode(uint256(0x1111111111111111), uint256(0x2222222222222222));
        s0.registers[0] = sourceData;
        // Replacement data (32 bytes)
        s0.registers[1] = abi.encode(uint256(0x3333333333333333));

        // Create surgery descriptor to replace first 32 bytes
        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](1);
        descs[0] = SurgeryDescriptor({ offset: 0, length: 32, replacementReg: 1 });

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        (VMState memory s1,) = run(cmds, s0);

        // Source register is modified in place
        uint8[] memory dests = new uint8[](1);
        dests[0] = 0;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify length is preserved
        assertEq(s1.registers[0].length, sourceData.length);

        // Verify the surgery was applied
        bytes memory expected = abi.encode(uint256(0x3333333333333333), uint256(0x2222222222222222));
        Asserts.equalsAbiData(s1.registers[0], expected);
    }

    // Tests that overlapping surgeries are applied in order with second overwriting first
    // Before:    [AAAAAAAAAAAAAAAA] [BBBBBBBBBBBBBBBB] [CCCCCCCCCCCCCCCC]
    // Surgery 1: |--------Replace with XXXX--------|
    //            offset=8, length=32
    // Surgery 2:           |--------Replace with YYYY--------|
    //                      offset=16, length=32
    // After:     [AAAAAAAA] [YYYYYYYYYYYYYYYY] [YYYYYYYY] [CCCCCCCC]
    //            (Second surgery overwrites part of first)
    function test_CalldataSurgery_OverlappingSurgeries_SecondOverwritesFirst() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Source = A, B, C (96 bytes total)
        bytes memory sourceData =
            abi.encode(uint256(0xAAAAAAAAAAAAAAAA), uint256(0xBBBBBBBBBBBBBBBB), uint256(0xCCCCCCCCCCCCCCCC));
        s0.registers[0] = sourceData;

        // Replacement payloads
        bytes memory xData = abi.encode(uint256(0x5858585858585858)); // "XXXX…"
        bytes memory yData = abi.encode(uint256(0x5959595959595959)); // "YYYY…"
        s0.registers[1] = xData;
        s0.registers[2] = yData;

        // Two overlapping descriptors – later one will clobber the overlap
        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](2);
        descs[0] = SurgeryDescriptor({ offset: 8, length: 32, replacementReg: 1 });
        descs[1] = SurgeryDescriptor({ offset: 16, length: 32, replacementReg: 2 });

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        (VMState memory s1,) = run(cmds, s0);

        // Only register 0 is allowed to change
        uint8[] memory dests = new uint8[](1);
        dests[0] = 0;
        Asserts.unchangedExcept(s0, s1, dests);

        // Length must stay identical
        assertEq(s1.registers[0].length, sourceData.length);

        // Build the expected post-surgery bytes in-memory
        bytes memory expected =
            abi.encode(uint256(0xAAAAAAAAAAAAAAAA), uint256(0xBBBBBBBBBBBBBBBB), uint256(0xCCCCCCCCCCCCCCCC));

        // Apply surgery 1 (XXXX at offset 8)
        for (uint256 i = 0; i < 32; ++i) {
            expected[8 + i] = xData[i];
        }
        // Apply surgery 2 (YYYY at offset 16) – overwrites part of the first
        for (uint256 i = 0; i < 32; ++i) {
            expected[16 + i] = yData[i];
        }

        Asserts.equalsAbiData(s1.registers[0], expected);
    }

    // Tests that surgery with offset + length > src length reverts with OutOfBounds
    // Source: [1111111111111111] [2222222222222222]
    //         <------ 64 bytes total ------>
    // Surgery:                          [3333333333333333]
    //                                   ^-- offset=48
    //                                   <--- length=32 --->
    // Error: offset(48) + length(32) = 80 > source length(64)
    function test_CalldataSurgery_OffsetPlusLengthExceedsSrcLength_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Source data: 64 bytes
        s0.registers[0] = abi.encode(uint256(0x1111111111111111), uint256(0x2222222222222222));
        // Replacement data
        s0.registers[1] = abi.encode(uint256(0x3333333333333333));

        // Create surgery that exceeds bounds: offset 48 + length 32 = 80 > 64
        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](1);
        descs[0] = SurgeryDescriptor({ offset: 48, length: 32, replacementReg: 1 });

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    // Tests that surgery with no descriptors leaves source register unchanged
    // Before: [1111111111111111] [2222222222222222]
    // Surgery: (no operations)
    // After:  [1111111111111111] [2222222222222222]
    //         (unchanged)
    function test_CalldataSurgery_NoDescriptors_SourceUnchanged() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // Source data
        bytes memory sourceData = abi.encode(uint256(0x1111111111111111), uint256(0x2222222222222222));
        s0.registers[0] = sourceData;

        // Create empty surgery descriptor array
        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](0);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        (VMState memory s1,) = run(cmds, s0);

        // Source register should be modified (surgery operates in-place)
        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // But content should be identical
        Asserts.equalsAbiData(s1.registers[0], sourceData);
    }

    // Tests that surgery count > 6 causes revert (memory OOB access)
    // Command structure: [op][srcReg][surgeryCount][surgery1]...[surgery6][surgery7]
    //                                      ^-- max=6                         ^-- OOB!
    // Surgery count = 7 exceeds the hardcoded limit of 6 surgeries
    function test_CalldataSurgery_TooManySurgeries_RevertsOOB() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(0x1111111111111111));

        // Manually create command with surgery count > 6 to bypass VmCmd validation
        // Pack source register (byte 0) and surgery count (byte 1)
        // The rest of the bytes can be arbitrary since the command should fail
        // when unpacking detects surgeryCount > 6
        bytes32 packed = bytes32(uint256(0)) << 248; // source register 0
        packed |= bytes32(uint256(7)) << 240; // surgery count = 7 (exceeds max of 6)

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({ op: OP.CALLDATA_SURGERY, data: packed });

        // Expecting TooManySurgeries error when unpacking the command
        vm.expectRevert(VmErrors.TooManySurgeries.selector);
        run(cmds, s0);
    }

    // Tests that surgery with length 0 leaves source unchanged
    // Before: [AAAAAAAAAAAAAAAA] [BBBBBBBBBBBBBBBB]
    // Surgery: ||
    //          ^-- offset=16, length=0 (no bytes replaced)
    // After:  [AAAAAAAAAAAAAAAA] [BBBBBBBBBBBBBBBB]
    //         (unchanged)
    function test_CalldataSurgery_ZeroLengthSurgery_SourceUnchanged() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Two-word source payload
        bytes memory sourceData = abi.encode(uint256(0xAAAAAAAAAAAAAAAA), uint256(0xBBBBBBBBBBBBBBBB));
        s0.registers[0] = sourceData;

        // Empty replacement register (never used because length == 0)
        s0.registers[1] = bytes('');

        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](1);
        descs[0] = SurgeryDescriptor({
            offset: 16,
            length: 0, // zero-length – should be a no-op
            replacementReg: 1
        });

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        (VMState memory s1,) = run(cmds, s0);

        // Surgery operates in-place, so register 0 is modified
        uint8[] memory dests = new uint8[](1);
        dests[0] = 0;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify the content is identical (zero-length surgery is a no-op)
        Asserts.equalsAbiData(s1.registers[0], sourceData);
    }

    // Tests that surgery with replacement length > surgery length reverts with ReplacementTooLarge
    // Source:      [1111111111111111] [2222222222222222]
    // Surgery:     |----16 bytes----|
    //              ^-- offset=0, length=16
    // Replacement: [3333333333333333333333333333333]
    //              <------------ 32 bytes ----------->
    // Error: Replacement (32 bytes) > Surgery length (16 bytes)
    function test_CalldataSurgery_ReplacementLargerThanSurgeryLength_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Source data
        s0.registers[0] = abi.encode(uint256(0x1111111111111111), uint256(0x2222222222222222));
        // Replacement data: 32 bytes
        s0.registers[1] = abi.encode(uint256(0x3333333333333333));

        // Create surgery with length 16 but replacement is 32 bytes
        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](1);
        descs[0] = SurgeryDescriptor({
            offset: 0,
            length: 16, // Surgery length is only 16 bytes
            replacementReg: 1 // But replacement register contains 32 bytes
        });

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        vm.expectRevert(VmErrors.ReplacementTooLarge.selector);
        run(cmds, s0);
    }
}
