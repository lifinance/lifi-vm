// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { TestUtils } from './lib/TestUtils.sol';
import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { Bp } from './lib/Bp.sol';
import { BlueprintEncoder } from '../src/BlueprintEncoder.sol';
import { RegisterFile } from '../src/RegisterFile.sol';

contract CalldataBuildTest is SpecTestBase {
    using RegisterFile for bytes[];
    // Test function selector for tests

    bytes4 constant TEST_SELECTOR = bytes4(keccak256('transfer(address,uint256)'));

    // Structs for testing nested containers
    struct SimpleInner {
        uint256 value;
        bytes data;
    }

    struct ComplexOuter {
        uint256 id;
        SimpleInner inner;
        address recipient;
    }

    // Tests that CALLDATA_BUILD with empty blueprint produces selector-only calldata
    function test_CalldataBuild_SelectorOnly_EmptyBlueprint() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Empty blueprint should produce just the 4-byte selector
        bytes memory emptyBp = '';
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, emptyBp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Result should be exactly 4 bytes (selector only) + length word
        assertEq(s1.registers[1].length, 4 + 32);
        Asserts.dataHasSelectorPrefix(TestUtils.stripLength(s1.registers[1]), TEST_SELECTOR);
        Asserts.assertEncodingMatches(s1.registers[1], abi.encodePacked(TEST_SELECTOR));
    }

    // Tests that CALLDATA_BUILD with flat static args equals abi.encodeWithSelector
    function test_CalldataBuild_FlatStaticArgs_MatchesABI() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Set up static arguments
        address recipient = alice;
        uint256 amount = 1000 ether;

        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(amount);

        // Blueprint: two static registers
        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 2, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // VM output should equal Solidity's abi.encodeWithSelector
        bytes memory expected = abi.encodeWithSelector(TEST_SELECTOR, recipient, amount);
        Asserts.assertEncodingMatches(s1.registers[2], expected);
    }

    // Tests that CALLDATA_BUILD with single dynamic arg properly handles bytes
    function test_CalldataBuild_SingleDynamicArg_ProperlyEncoded() public withSnapshot {
        VMState memory s0 = Regs.init(3);

        // Dynamic bytes data - must be properly formatted with length prefix
        bytes memory dynamicData = 'Hello, Virtual Machine!';
        s0.registers.setDynamic(0, abi.encode(dynamicData));

        // Blueprint: one dynamic register
        bytes memory bp = Bp.d(0);

        // Use a different selector for this test
        bytes4 selector = bytes4(keccak256('processData(bytes)'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 1, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // VM output should equal Solidity's abi.encodeWithSelector
        bytes memory expected = abi.encodeWithSelector(selector, dynamicData);
        Asserts.assertEncodingMatches(s1.registers[1], expected);
    }

    struct InnerTuple {
        uint256 innerValue;
        bytes innerBytes;
    }

    struct OuterTuple {
        uint256 outerValue;
        InnerTuple inner;
    }

    // Tests nested containers with tuples containing dynamic elements
    function test_CalldataBuild_NestedContainers_TupleWithDynamic() public withSnapshot {
        VMState memory s0 = Regs.init(5);

        // Set up data for tuple(uint, (uint, bytes))
        uint256 outerValue = 42;
        uint256 innerValue = 100;
        bytes memory innerBytes = 'nested data';

        s0.registers[0] = abi.encode(outerValue);
        s0.registers[1] = abi.encode(innerValue);
        s0.registers.setDynamic(2, abi.encode(innerBytes));

        // Blueprint: (static, (static, dynamic))
        bytes memory bp = abi.encodePacked(
            Bp.s(0), // outer static value
            Bp.pushTuple(), // START_TUPLE_DYNAMIC (nested)
            Bp.s(1), // inner static value
            Bp.d(2), // inner dynamic bytes
            Bp.end() // END_DYNAMIC (close inner tuple)
        );

        bytes4 selector = bytes4(keccak256('processNested(uint256,(uint256,bytes))'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // Create expected encoding using struct to simulate the nested tuple (uint, (uint, bytes))
        InnerTuple memory innerTuple = InnerTuple({ innerValue: innerValue, innerBytes: innerBytes });
        bytes memory expected = abi.encodeWithSelector(selector, outerValue, innerTuple);

        // Verify the result matches the expected encoding
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests that static register with non-32-byte data reverts with BadStaticFormat
    function test_CalldataBuild_BadStaticFormat_NotExactly32Bytes_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Set register 0 with incorrect size (not 32 bytes)
        s0.registers[0] = abi.encodePacked(uint128(999)); // Only 16 bytes

        bytes memory bp = Bp.s(0); // static register 0

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, bp);

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadStaticFormat.selector, uint8(0)));
        run(cmds, s0);
    }

    // Tests that dynamic register with < 32 bytes reverts with BadDynamicFormat
    function test_CalldataBuild_BadDynamicFormat_LessThan32Bytes_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Set register 0 with less than 32 bytes (invalid for dynamic)
        s0.registers[0] = abi.encodePacked(uint64(123)); // Only 8 bytes

        bytes memory bp = Bp.d(0); // dynamic register 0

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, bp);

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadDynamicFormat.selector, uint8(0)));
        run(cmds, s0);
    }

    // Tests that referencing a missing register index reverts with RegisterIndexOOB
    function test_CalldataBuild_RegisterIndexOOB_OutOfBounds_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2); // Only registers 0 and 1

        // Blueprint references register 5 which doesn't exist
        bytes memory bp = Bp.s(5);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, bp);

        vm.expectRevert(abi.encodeWithSelector(RegisterFile.RegisterIndexOOB.selector));
        run(cmds, s0);
    }

    // Tests that early END_DYNAMIC without matching opener reverts with StackUnderflow
    function test_CalldataBuild_UnbalancedContainers_EarlyEnd_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        // Blueprint with END_DYNAMIC but no opening container
        bytes memory bp = abi.encodePacked(
            Bp.s(0),
            Bp.end() // END_DYNAMIC without opener
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, bp);

        vm.expectRevert(BlueprintEncoder.StackUnderflow.selector);
        run(cmds, s0);
    }

    // Tests that unclosed container at EOF reverts with UnclosedContainer
    function test_CalldataBuild_UnbalancedContainers_UnclosedAtEOF_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        // Blueprint with opening tuple but no closing END_DYNAMIC
        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(), // START_TUPLE_DYNAMIC
            Bp.s(0) // Missing END_DYNAMIC
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(TEST_SELECTOR, 1, bp);

        vm.expectRevert(BlueprintEncoder.UnclosedContainer.selector);
        run(cmds, s0);
    }

    // Tests that dest register high-bit (dyn flag) is ignored
    function test_CalldataBuild_DestHighBit_Ignored() public withSnapshot {
        VMState memory s0 = Regs.init(3);

        address recipient = bob;
        uint256 amount = 500 ether;

        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(amount);

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1));

        // Test with regular dest register
        VMCommand[] memory cmds1 = new VMCommand[](1);
        cmds1[0] = VmCmd.cdb(TEST_SELECTOR, 2, bp);
        (VMState memory s1,) = run(cmds1, s0);

        // Test with dest register having high bit set (should be ignored)
        VMCommand[] memory cmds2 = new VMCommand[](1);
        cmds2[0] = VmCmd.cdb(TEST_SELECTOR, Regs.withDyn(2), bp); // Set dyn bit on dest
        (VMState memory s2,) = run(cmds2, s0);

        // Both should write to the same register and produce identical results
        assertEq(keccak256(s1.registers[2]), keccak256(s2.registers[2]));

        // Verify the output is correct
        bytes memory expected = abi.encodeWithSelector(TEST_SELECTOR, recipient, amount);
        Asserts.assertEncodingMatches(s1.registers[2], expected);
    }

    // Property test: Output always starts with selector
    function test_CalldataBuild_Property_SelectorPrefix() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(123));

        // Various blueprints
        bytes memory bp1 = ''; // Empty
        bytes memory bp2 = Bp.s(0); // Single static
        bytes memory bp3 = abi.encodePacked( // With container
            Bp.pushTupleStatic(),
            Bp.s(0),
            Bp.end()
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = bytes4(keccak256('func1()'));
        selectors[1] = bytes4(keccak256('func2(uint256)'));
        selectors[2] = bytes4(keccak256('func3((uint256))'));

        bytes[] memory blueprints = new bytes[](3);
        blueprints[0] = bp1;
        blueprints[1] = bp2;
        blueprints[2] = bp3;

        for (uint256 i = 0; i < 3; i++) {
            VMCommand[] memory cmds = new VMCommand[](1);
            cmds[0] = VmCmd.cdb(selectors[i], 1, blueprints[i]);

            (VMState memory s1,) = run(cmds, s0);

            // Every output must start with the selector
            assertTrue(s1.registers[1].length >= 36); // At least length word + selector
            Asserts.dataHasSelectorPrefix(TestUtils.stripLength(s1.registers[1]), selectors[i]);
        }
    }

    // Property test: Functional equivalence with BlueprintEncoder.encodeFromBlueprint
    function test_CalldataBuild_Property_FunctionalEquivalence() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Set up test data
        s0.registers[0] = abi.encode(address(alice));
        s0.registers[1] = abi.encode(uint256(999));
        bytes memory dynamicData = 'test data';
        s0.registers.setDynamic(2, abi.encode(dynamicData));

        // Test various blueprint patterns
        bytes[] memory blueprints = new bytes[](4);
        blueprints[0] = ''; // Empty
        blueprints[1] = abi.encodePacked(Bp.s(0), Bp.s(1)); // Flat static
        blueprints[2] = Bp.d(2); // Single dynamic
        blueprints[3] = abi.encodePacked( // Mixed
            Bp.s(0),
            Bp.d(2),
            Bp.s(1)
        );

        for (uint256 i = 0; i < blueprints.length; i++) {
            // Run through VM
            VMCommand[] memory cmds = new VMCommand[](1);
            cmds[0] = VmCmd.cdb(TEST_SELECTOR, 3, blueprints[i]);
            (VMState memory s1,) = run(cmds, s0);

            // Compare with direct encoder call
            bytes memory expected = BlueprintEncoder.encodeFromBlueprint(TEST_SELECTOR, blueprints[i], s0.registers);

            Asserts.assertEncodingMatches(s1.registers[3], TestUtils.stripLength(expected));
        }
    }

    // Tests CALLDATA_BUILD with static array of dynamic elements f(bytes[2])
    function test_CalldataBuild_StaticArrayWithDynamicElements() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Set up two dynamic bytes elements for the static array
        bytes memory data1 = hex'abababababababababababababababababababababababababababababababababababab';
        bytes memory data2 = hex'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

        s0.registers.setDynamic(0, abi.encode(data1));
        s0.registers.setDynamic(1, abi.encode(data2));

        // Blueprint: static array [2] containing two dynamic elements
        bytes memory bp = abi.encodePacked(
            // START_ARRAY_STATIC -- fixed length but dynamic type -> encodes as dynamic tuple!
            Bp.pushTuple(),
            Bp.d(0), // first dynamic element
            Bp.d(1), // second dynamic element
            Bp.end() // END_DYNAMIC
        );

        // Function selector for f(bytes[2])
        bytes4 selector = bytes4(keccak256('f(bytes[2])'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 2, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expected = abi.encodeWithSelector(
            selector,
            [data1, data2] // Static array literal
        );

        Asserts.assertEncodingMatches(s1.registers[2], expected);
    }
}
