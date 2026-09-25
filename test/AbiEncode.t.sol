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

contract AbiEncodeTest is SpecTestBase {
    using RegisterFile for bytes[];
    // Structs for test_AbiEncode_MixedNestedStructures

    struct Inner {
        bytes b;
        address a;
    }

    struct Pair {
        uint256 u;
        bytes32 h;
    }

    struct Outer {
        uint256 u;
        Inner inner;
        Pair pair;
    }

    // Structs for test_AbiEncode_ComplexMultilayerNesting
    struct InnerTuple1 {
        uint256 value;
        bytes data;
    }

    struct InnerTuple2 {
        uint256 value;
        address addr;
        bytes32 hash;
    }

    struct ComplexNested {
        uint256 value;
        InnerTuple1 inner1;
        InnerTuple2 inner2;
    }

    // Tests that ABI_ENCODE with empty blueprint produces empty bytes
    function test_AbiEncode_EmptyBlueprint() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        bytes memory emptyBp = '';
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, emptyBp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Empty blueprint produces length-prefixed empty data (32 bytes for length + 0 bytes data)
        assertEq(s1.registers[1].length, 32);
        // The stripped output should be empty
        bytes memory strippedOutput = TestUtils.stripLength(s1.registers[1]);
        assertEq(strippedOutput.length, 0);
    }

    // Tests that ABI_ENCODE with flat static arguments equals abi.encode
    function test_AbiEncode_FlatStaticArgs() public withSnapshot {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(bytes32(bytes20(address(0xdead))));

        // Blueprint: 3 static registers
        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1), Bp.s(2));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // VM output should equal Solidity's abi.encode
        bytes memory expected = abi.encode(uint256(42), address(alice), bytes32(bytes20(address(0xdead))));
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests that ABI_ENCODE with dynamic arguments properly encodes bytes/string
    function test_AbiEncode_DynamicArgs() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Static uint256
        s0.registers[0] = abi.encode(uint256(100));

        // Dynamic bytes - use RegisterFile.setDynamic to properly format
        bytes memory dynamicData = 'hello world';
        s0.registers.setDynamic(1, abi.encode(dynamicData));

        // Another static uint256
        s0.registers[2] = abi.encode(uint256(200));

        // Blueprint: static, dynamic, static
        bytes memory bp = abi.encodePacked(
            Bp.s(0), // static register 0
            Bp.d(1), // dynamic register 1
            Bp.s(2) // static register 2
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // VM output should equal Solidity's abi.encode
        bytes memory expected = abi.encode(uint256(100), dynamicData, uint256(200));
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests nested containers with tuples and arrays
    function test_AbiEncode_NestedContainers() public withSnapshot {
        VMState memory s0 = Regs.init(5);

        // Set up registers with static values
        s0.registers[0] = abi.encode(uint256(10));
        s0.registers[1] = abi.encode(uint256(20));
        s0.registers[2] = abi.encode(uint256(30));

        // Blueprint: tuple containing (uint256, tuple(uint256, uint256))
        bytes memory bp = abi.encodePacked(
            Bp.pushTupleStatic(), // START_TUPLE_STATIC
            Bp.s(0), // static register 0
            Bp.pushTupleStatic(), // START_TUPLE_STATIC (nested)
            Bp.s(1), // static register 1
            Bp.s(2), // static register 2
            Bp.end(), // END_DYNAMIC
            Bp.end() // END_DYNAMIC
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify structure matches expected encoding
        bytes memory expected = abi.encode(uint256(10), uint256(20), uint256(30));
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests that static token with non-32-byte register reverts with BadStaticFormat
    function test_AbiEncode_BadStaticFormat_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Set register 0 with incorrect size (not 32 bytes)
        s0.registers[0] = abi.encodePacked(uint16(42)); // Only 2 bytes

        bytes memory bp = Bp.s(0); // static register 0

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadStaticFormat.selector, uint8(0)));
        run(cmds, s0);
    }

    // Tests that dynamic token with < 32 bytes reverts with BadDynamicFormat
    function test_AbiEncode_BadDynamicFormat_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Set register 0 with less than 32 bytes for dynamic
        s0.registers[0] = abi.encodePacked(uint128(42)); // Only 16 bytes

        bytes memory bp = Bp.d(0); // dynamic register 0

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadDynamicFormat.selector, uint8(0)));
        run(cmds, s0);
    }

    // Tests that missing register index reverts with RegisterIndexOOB
    function test_AbiEncode_RegisterIndexOOB_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2); // Only registers 0 and 1

        bytes memory bp = Bp.s(5); // Try to access register 5

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(abi.encodeWithSelector(RegisterFile.RegisterIndexOOB.selector));
        run(cmds, s0);
    }

    // Tests that dest high-bit is ignored when writing result
    function test_AbiEncode_DestHighBitIgnored() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(999));

        bytes memory bp = Bp.s(0);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(Regs.withDyn(1), bp); // Set high bit on dest using Regs helper

        (VMState memory s1,) = run(cmds, s0);

        // Should write to register 1 (Regs.baseIdx(withDyn(1)) = 1)
        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expected = abi.encode(uint256(999));
        Asserts.assertEncodingMatches(s1.registers[1], expected);
    }

    // Tests complex multilayer nesting of static tuples in dynamic tuples
    function test_AbiEncode_ComplexMultilayerNesting() public withSnapshot {
        VMState memory s0 = Regs.init(8);

        // Set up registers
        s0.registers[0] = abi.encode(uint256(1));
        s0.registers[1] = abi.encode(uint256(2));
        s0.registers.setDynamic(2, abi.encode(bytes('test')));
        s0.registers[3] = abi.encode(uint256(3));
        s0.registers[4] = abi.encode(address(alice));
        s0.registers[5] = abi.encode(bytes32(bytes20(address(0xbeef))));

        // Blueprint: dynamic tuple containing (uint, tuple(uint, bytes), tuple(uint, address, bytes32))
        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(), // START_TUPLE_DYNAMIC (outer tuple)
            Bp.s(0), // static register 0 (first field)
            Bp.pushTuple(), // START_TUPLE_DYNAMIC (nested tuple 1)
            Bp.s(1), // static register 1
            Bp.d(2), // dynamic register 2
            Bp.end(), // END_DYNAMIC (close nested tuple 1)
            Bp.pushTupleStatic(), // START_TUPLE_STATIC (nested tuple 2)
            Bp.s(3), // static register 3
            Bp.s(4), // static register 4
            Bp.s(5), // static register 5
            Bp.end(), // END_DYNAMIC (close nested tuple 2)
            Bp.end() // END_DYNAMIC (close outer tuple)
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(6, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 6;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify complex structure matches expected encoding using structs
        bytes memory expected = abi.encode(
            ComplexNested({
                value: 1,
                inner1: InnerTuple1({ value: 2, data: bytes('test') }),
                inner2: InnerTuple2({ value: 3, addr: alice, hash: bytes32(bytes20(address(0xbeef))) })
            })
        );
        Asserts.assertEncodingMatches(s1.registers[6], expected);
    }

    // Tests dynamic array encoding
    function test_AbiEncode_DynamicArray() public withSnapshot {
        VMState memory s0 = Regs.init(5);

        // Array elements
        s0.registers[0] = abi.encode(uint256(10));
        s0.registers[1] = abi.encode(uint256(20));
        s0.registers[2] = abi.encode(uint256(30));

        // Blueprint: dynamic array of uint256
        bytes memory bp = abi.encodePacked(
            Bp.pushArray(), // START_ARRAY_DYNAMIC
            Bp.s(0), // element 0
            Bp.s(1), // element 1
            Bp.s(2), // element 2
            Bp.end() // END_DYNAMIC
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify array matches expected encoding
        uint256[] memory expectedArr = new uint256[](3);
        expectedArr[0] = 10;
        expectedArr[1] = 20;
        expectedArr[2] = 30;
        bytes memory expected = abi.encode(expectedArr);
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests static array encoding
    function test_AbiEncode_StaticArray() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Array elements
        s0.registers[0] = abi.encode(uint256(100));
        s0.registers[1] = abi.encode(uint256(200));

        // Blueprint: static array [2] of uint256
        bytes memory bp = abi.encodePacked(
            Bp.pushArrayStatic(), // START_ARRAY_STATIC
            Bp.s(0), // element 0
            Bp.s(1), // element 1
            Bp.end() // END_DYNAMIC
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(2, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 2;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify static array matches expected encoding
        bytes memory expected = abi.encode(uint256(100), uint256(200));
        Asserts.assertEncodingMatches(s1.registers[2], expected);
    }

    // Tests stack overflow with excessive nesting depth
    function test_AbiEncode_StackOverflow_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(1));

        // Create blueprint with nesting depth > MAX_STACK_DEPTH (12)
        bytes memory bp = '';
        for (uint8 i = 0; i < 13; i++) {
            bp = bytes.concat(bp, Bp.pushTupleStatic()); // START_TUPLE_STATIC
        }
        bp = bytes.concat(bp, Bp.s(0)); // register 0
        for (uint8 i = 0; i < 13; i++) {
            bp = bytes.concat(bp, Bp.end()); // END_DYNAMIC
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(BlueprintEncoder.StackOverflow.selector);
        run(cmds, s0);
    }

    // Tests selector-less equivalence property
    function test_AbiEncode_SelectorlessEquivalence() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(bob));

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(2, bp);

        (VMState memory s1,) = run(cmds, s0);

        // Direct call to BlueprintEncoder.encodeData should produce same result
        bytes memory directEncoded = BlueprintEncoder.encodeData(bp, s0.registers);
        assertEq(keccak256(s1.registers[2]), keccak256(directEncoded), 'Direct encoding mismatch');
    }

    // Tests with multiple dynamic arguments
    function test_AbiEncode_MultipleDynamicArgs() public withSnapshot {
        VMState memory s0 = Regs.init(5);

        bytes memory data1 = 'first dynamic data';
        bytes memory data2 = 'second';
        bytes memory data3 = 'third dynamic string data';

        s0.registers.setDynamic(0, abi.encode(data1));
        s0.registers.setDynamic(1, abi.encode(data2));
        s0.registers.setDynamic(2, abi.encode(data3));

        // Blueprint: 3 dynamic arguments
        bytes memory bp = abi.encodePacked(Bp.d(0), Bp.d(1), Bp.d(2));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(3, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 3;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify encoding matches Solidity's
        bytes memory expected = abi.encode(data1, data2, data3);
        Asserts.assertEncodingMatches(s1.registers[3], expected);
    }

    // Tests mixed static and dynamic in nested structures
    function test_AbiEncode_MixedNestedStructures() public withSnapshot {
        VMState memory s0 = Regs.init(7);

        s0.registers[0] = abi.encode(uint256(100));
        s0.registers.setDynamic(1, abi.encode(bytes('dynamic data')));
        s0.registers[2] = abi.encode(address(alice));
        s0.registers[3] = abi.encode(uint256(200));
        s0.registers[4] = abi.encode(bytes32(bytes20(address(0xcafe))));

        // Blueprint: tuple(uint, tuple(bytes, address), tuple(uint, bytes32))
        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(), // START_TUPLE_DYNAMIC (outer)
            Bp.s(0), // uint256
            Bp.pushTuple(), // START_TUPLE_DYNAMIC (inner 1)
            Bp.d(1), // dynamic bytes
            Bp.s(2), // address
            Bp.end(), // END_DYNAMIC
            Bp.pushTupleStatic(), // START_TUPLE_STATIC (inner 2)
            Bp.s(3), // uint256
            Bp.s(4), // bytes32
            Bp.end(), // END_DYNAMIC
            Bp.end() // END_DYNAMIC
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(5, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 5;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify mixed nested structure matches expected encoding using proper struct encoding
        bytes memory expected = abi.encode(
            Outer({
                u: 100,
                inner: Inner({ b: bytes('dynamic data'), a: alice }),
                pair: Pair({ u: 200, h: bytes32(bytes20(address(0xcafe))) })
            })
        );
        Asserts.assertEncodingMatches(s1.registers[5], expected);
    }

    // Tests that StackUnderflow is triggered when END_DYNAMIC has no opener
    function test_AbiEncode_StackUnderflow_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Blueprint with close token but no opener
        bytes memory bp = Bp.end(); // END_DYNAMIC without opener

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(BlueprintEncoder.StackUnderflow.selector);
        run(cmds, s0);
    }

    // Tests that UnclosedContainer is triggered when container is not closed
    function test_AbiEncode_UnclosedContainer_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        // Blueprint that opens tuple but never closes
        bytes memory bp = abi.encodePacked(Bp.pushTupleStatic(), Bp.s(0)); // START_TUPLE_STATIC without END

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(BlueprintEncoder.UnclosedContainer.selector);
        run(cmds, s0);
    }

    // Tests that DynHeadBufOverflow is triggered with >10 nested dynamic containers
    function test_AbiEncode_DynHeadBufOverflow_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(1));

        // Create 11 nested dynamic tuples (exceeds tmpDynHeads[10] buffer)
        bytes memory bp = '';
        for (uint8 i = 0; i < 11; i++) {
            bp = bytes.concat(bp, Bp.pushTuple()); // START_TUPLE_DYNAMIC
        }
        bp = bytes.concat(bp, Bp.s(0));
        for (uint8 i = 0; i < 11; i++) {
            bp = bytes.concat(bp, Bp.end()); // END_DYNAMIC
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        vm.expectRevert(BlueprintEncoder.DynHeadBufOverflow.selector);
        run(cmds, s0);
    }

    // Tests encoding of zero-length dynamic data
    function test_AbiEncode_EmptyDynamicData() public withSnapshot {
        VMState memory s0 = Regs.init(3);

        // Empty bytes encoded still produces 32-byte length word
        bytes memory emptyData = '';
        s0.registers.setDynamic(0, abi.encode(emptyData));

        bytes memory bp = Bp.d(0); // dynamic register 0

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(1, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expected = abi.encode(emptyData);
        Asserts.assertEncodingMatches(s1.registers[1], expected);
    }

    // Tests boundary register tokens at the edge of valid ranges
    function test_AbiEncode_BoundaryTokens() public withSnapshot {
        VMState memory s0 = Regs.init(122); // Need 122 registers (0-121)

        // Test highest valid static register before void (0x79 = 121)
        s0.registers[121] = abi.encode(uint256(999));

        bytes memory bp = Bp.s(121); // 0x79

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(120, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 120;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expected = abi.encode(uint256(999));
        Asserts.assertEncodingMatches(s1.registers[120], expected);
    }

    // Tests the highest valid dynamic register token
    function test_AbiEncode_BoundaryDynamicToken() public withSnapshot {
        VMState memory s0 = Regs.init(122); // Need 122 registers (0-121)

        // Test highest valid dynamic register (121 with dynamic flag = 0xF9)
        bytes memory dynamicData = 'boundary test';
        s0.registers.setDynamic(121, abi.encode(dynamicData));

        bytes memory bp = Bp.d(121); // 0xF9 (Regs.withDyn(121))

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(120, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 120;
        Asserts.unchangedExcept(s0, s1, dests);

        bytes memory expected = abi.encode(dynamicData);
        Asserts.assertEncodingMatches(s1.registers[120], expected);
    }

    // Struct for testing unsupported dynamic array of static-multiword tuples
    struct Uint256Pair {
        uint256 a;
        uint256 b;
    }

    // Tests that dynamic array of static-multiword tuples works correctly
    // This is tricky since it's a case where static values (the static tuple)
    // have head > 32 bytes
    function test_AbiEncode_DynamicArrayOfStaticMultiwordTuples() public withSnapshot {
        VMState memory s0 = Regs.init(7);

        // Set up registers for tuple elements
        s0.registers[0] = abi.encode(uint256(100));
        s0.registers[1] = abi.encode(uint256(200));
        s0.registers[2] = abi.encode(uint256(300));
        s0.registers[3] = abi.encode(uint256(400));
        s0.registers[4] = abi.encode(uint256(500));
        s0.registers[5] = abi.encode(uint256(600));

        // Blueprint: dynamic array of static tuples (uint256, uint256)[]
        bytes memory bp = abi.encodePacked(
            Bp.pushArray(), // START_ARRAY_DYNAMIC
            Bp.pushTupleStatic(), // START_TUPLE_STATIC for first tuple
            Bp.s(0), // first tuple's first element
            Bp.s(1), // first tuple's second element
            Bp.end(), // END_DYNAMIC (close first tuple)
            Bp.pushTupleStatic(), // START_TUPLE_STATIC for second tuple
            Bp.s(2), // second tuple's first element
            Bp.s(3), // second tuple's second element
            Bp.end(), // END_DYNAMIC (close second tuple)
            Bp.pushTupleStatic(), // START_TUPLE_STATIC for third tuple
            Bp.s(4), // third tuple's first element
            Bp.s(5), // third tuple's second element
            Bp.end(), // END_DYNAMIC (close third tuple)
            Bp.end() // END_DYNAMIC (close array)
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(6, bp);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 6;
        Asserts.unchangedExcept(s0, s1, dests);

        // Create the expected encoding using Solidity's abi.encode
        Uint256Pair[] memory expectedArray = new Uint256Pair[](3);
        expectedArray[0] = Uint256Pair({ a: 100, b: 200 });
        expectedArray[1] = Uint256Pair({ a: 300, b: 400 });
        expectedArray[2] = Uint256Pair({ a: 500, b: 600 });

        bytes memory expected = abi.encode(expectedArray);

        // Verify the VM's encoding matches Solidity's abi.encode
        Asserts.assertEncodingMatches(s1.registers[6], expected);
    }

    // Tests concatenation property between encodeData and theoretical encodeFromBlueprint
    function test_AbiEncode_ConcatenationProperty() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers.setDynamic(1, abi.encode(bytes('test')));

        // Flat blueprint to test concatenation of static and dynamic args
        bytes memory bp = abi.encodePacked(
            Bp.s(0), // static
            Bp.d(1) // dynamic
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(2, bp);

        (VMState memory s1,) = run(cmds, s0);

        // Also directly call BlueprintEncoder.encodeData for comparison
        bytes memory directEncoded = BlueprintEncoder.encodeData(bp, s0.registers);

        // VM result should match direct library call
        // Both s1.registers[2] and directEncoded are raw bytes, should match directly
        assertEq(keccak256(s1.registers[2]), keccak256(directEncoded), 'Direct encoding mismatch');

        // Verify the encoding is correct with flat encoding
        bytes memory expected = abi.encode(uint256(42), bytes('test'));
        Asserts.assertEncodingMatches(s1.registers[2], expected);
    }
}
