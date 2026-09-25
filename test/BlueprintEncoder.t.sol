// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

/**
 * TEST COVERAGE MATRIX
 *
 * Based on src/BlueprintEncoder.sol's CONTAINER ENCODING REFERENCE table,
 * these tests provide coverage over possible combinations of containers and contained types:
 *
 * | Container Type            | Element Type | Encoding            | Pointer | Length | Tests                                       |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Static tuple              | Static       | Inline (no pointer) | No      | No     | test_allStaticFlatParameters                |
 * |                           |              |                     |         |        | test_staticTupleInline                      |
 * |                           |              |                     |         |        | test_staticArrayOfStaticElements            |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Dynamic tuple             | Static       | 32-byte pointer     | Yes     | No     | test_dynamicTupleWithOneDynamic             |
 * |                           | Dynamic      |                     |         |        | test_dynamicTuple                           |
 * |                           | Mixed        |                     |         |        | test_topLevelMultipleDynamics               |
 * |                           |              |                     |         |        | test_twoDynamics_TopLevel                   |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Static array T[k]         | Static       | Inline (no pointer) | No      | No     | test_staticArrayOfStaticElements            |
 * | (ABI-compliant)           | Dynamic      | 32-byte pointer     | Yes     | No     | test_staticArrayDynamicElementsABICompliant |
 * |                           |              | (encoded as tuple)  |         |        |                                             |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Dynamic array T[]         | Static       | 32-byte pointer +   | Yes     | Yes    | test_dynamicArrayOfStatics*                 |
 * |                           |              | length word         |         |        |                                             |
 * |                           | Dynamic      |                     |         |        | test_stringArray_Parametrized               |
 * |                           |              |                     |         |        | test_bytesArray_Parametrized                |
 * |                           |              |                     |         |        | test_dynamicArrayDynamicTuplesPointerBase   |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Dynamic scalar            | bytes/string | 32-byte pointer +   | Yes*    | Yes    | Used as elements in other tests             |
 * |                           |              | length word         |         |        |                                             |
 * |---------------------------|--------------|---------------------|---------|--------|---------------------------------------------|
 * | Nested combinations       | Mixed        | Per container rules | Varies  | Varies | test_nestedDynamicArrayOfTuples            |
 * |                           |              |                     |         |        | test_multipleDynamicArraysInTuple           |
 * |                           |              |                     |         |        | test_dynamicArrayInsideDynamicTuple         |
 * |                           |              |                     |         |        | test_mixedDynamicAndStaticParameters        |
 *
 * Notes:
 * - Static arrays with dynamic elements use START_TUPLE_DYNAMIC for ABI compliance
 * - Dynamic arrays always include a 32-byte length word before element data
 * - Element head pointers in dynamic arrays are relative to array_head_start + 32
 * - Element head pointers in tuples are relative to tuple_head_start
 * - *Top-level scalar encoding includes offset pointer: [0x20][length][data]
 */
import { SpecTestBase } from './SpecTestBase.sol';
import { BlueprintEncoder } from '../src/BlueprintEncoder.sol';
import { RegisterFile } from '../src/RegisterFile.sol';
import { Regs } from './lib/Regs.sol';
import { Bp } from './lib/Bp.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { Asserts } from './lib/Asserts.sol';

// Struct matching the POC example
struct ProcessData {
    uint256 value;
    bytes data;
}

contract BlueprintEncoderTest is SpecTestBase {
    using RegisterFile for bytes[];

    struct BytesTuple {
        bytes data;
    }

    struct UintBytesTuple {
        uint256 value;
        bytes data;
    }

    struct BytesBytesTuple {
        bytes data1;
        bytes data2;
    }

    struct BytesArrayBoolArrayTuple {
        bytes[] bytesArray;
        bool[] boolArray;
    }

    struct DynamicTuple {
        bytes a;
        bytes b;
    }

    struct StaticTripleTuple {
        uint256 a;
        address b;
        bool c;
    }

    struct TupleWithArray {
        bytes[] arr;
        uint256 num;
    }

    struct StaticPairTuple {
        uint256 val;
        bool flag;
    }

    // Tests dynamic string arrays with parameterized element counts
    function test_stringArray_Parametrized() public pure {
        // Test with 0, 1, and 3 elements to cover different cardinalities
        _testStringArrayWithCount(0);
        _testStringArrayWithCount(1);
        _testStringArrayWithCount(3);
    }

    function _testStringArrayWithCount(uint256 count) internal pure {
        bytes[] memory regs = RegisterFile.initialize(count);
        bytes memory bp = abi.encodePacked(Bp.pushArray());

        string[] memory arr = new string[](count);
        for (uint8 i = 0; i < count; i++) {
            string memory elem = string(abi.encodePacked('elem', _toString(i)));
            regs.setDynamic(i, abi.encode(elem));
            bp = abi.encodePacked(bp, Bp.d(uint8(i)));
            arr[i] = elem;
        }
        bp = abi.encodePacked(bp, Bp.end());

        bytes4 selector = bytes4(keccak256('f(string[])'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected = abi.encodeWithSignature('f(string[])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic bytes arrays with parameterized element counts
    function test_bytesArray_Parametrized() public pure {
        // Test with 0, 1, and 3 elements to cover different cardinalities
        _testBytesArrayWithCount(0);
        _testBytesArrayWithCount(1);
        _testBytesArrayWithCount(3);
    }

    function _testBytesArrayWithCount(uint256 count) internal pure {
        bytes[] memory regs = RegisterFile.initialize(count);
        bytes memory bp = abi.encodePacked(Bp.pushArray());

        bytes[] memory arr = new bytes[](count);
        for (uint8 i = 0; i < count; i++) {
            bytes memory elem = abi.encodePacked('data', _toString(i));
            regs.setDynamic(i, abi.encode(elem));
            bp = abi.encodePacked(bp, Bp.d(uint8(i)));
            arr[i] = elem;
        }
        bp = abi.encodePacked(bp, Bp.end());

        bytes4 selector = bytes4(keccak256('f(bytes[])'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected = abi.encodeWithSignature('f(bytes[])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Helper function to convert uint to string
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return '0';

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }

    // Tests mixed top-level dynamics for proper pointer handling
    function test_twoDynamics_TopLevel() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs.setDynamic(0, abi.encode(bytes('hello')));
        regs.setDynamic(1, abi.encode(string('world')));

        bytes memory bp = abi.encodePacked(Bp.d(0), Bp.d(1));
        bytes4 selector = bytes4(keccak256('f(bytes,string)'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected = abi.encodeWithSignature('f(bytes,string)', bytes('hello'), string('world'));

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic tuple array where each tuple contains dynamic bytes
    function test_dynamicTupleArrayWithDynamicBytes() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs.setDynamic(0, abi.encode(bytes('tuple1data')));
        regs.setDynamic(1, abi.encode(bytes('tuple2data')));

        // Blueprint: array containing tuples with dynamic bytes
        bytes memory bp = abi.encodePacked(
            Bp.pushArray(), Bp.pushTuple(), Bp.d(0), Bp.end(), Bp.pushTuple(), Bp.d(1), Bp.end(), Bp.end()
        );
        bytes4 selector = bytes4(keccak256('f((bytes)[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Create expected data structure
        BytesTuple[] memory structArray = new BytesTuple[](2);
        structArray[0] = BytesTuple(bytes('tuple1data'));
        structArray[1] = BytesTuple(bytes('tuple2data'));
        bytes memory expected = abi.encodeWithSelector(selector, structArray);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests mixed static/dynamic tuple array with single element
    // Verifies correct offset calculation for tuple containing uint256 (static) and bytes (dynamic)
    function test_mixedTupleArraySingleElement() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs.set(0, abi.encode(uint256(42))); // static uint256
        regs.setDynamic(1, abi.encode(bytes('test'))); // dynamic bytes

        // Blueprint: array containing one tuple with (uint256, bytes)
        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.pushTuple(), Bp.s(0), Bp.d(1), Bp.end(), Bp.end());
        bytes4 selector = bytes4(keccak256('f((uint256,bytes)[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Create expected data structure
        UintBytesTuple[] memory structArray = new UintBytesTuple[](1);
        structArray[0] = UintBytesTuple(42, bytes('test'));
        bytes memory expected = abi.encodeWithSelector(selector, structArray);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests deeply nested dynamic structures: array of arrays of tuples
    // Exercises complex nesting with dynamic-array-of-dynamic-tuples inside outer dynamic array
    function test_nestedDynamicArrayOfTuples() public pure {
        bytes[] memory regs = RegisterFile.initialize(4);
        regs.setDynamic(0, abi.encode(bytes('inner1a')));
        regs.setDynamic(1, abi.encode(bytes('inner1b')));
        regs.setDynamic(2, abi.encode(bytes('inner2a')));
        regs.setDynamic(3, abi.encode(bytes('inner2b')));

        // Blueprint: outer array containing inner arrays of tuples
        bytes memory bp = abi.encodePacked(
            Bp.pushArray(), // outer dynamic array
            Bp.pushArray(), // first inner dynamic array
            Bp.pushTuple(),
            Bp.d(0),
            Bp.d(1),
            Bp.end(), // first tuple
            Bp.end(), // end first inner array
            Bp.pushArray(), // second inner dynamic array
            Bp.pushTuple(),
            Bp.d(2),
            Bp.d(3),
            Bp.end(), // second tuple
            Bp.end(), // end second inner array
            Bp.end() // end outer array
        );
        bytes4 selector = bytes4(keccak256('f(((bytes,bytes)[])[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Create expected nested structure - need proper (bytes,bytes) tuples
        BytesBytesTuple[][] memory outerArray = new BytesBytesTuple[][](2);
        outerArray[0] = new BytesBytesTuple[](1);
        outerArray[0][0] = BytesBytesTuple(bytes('inner1a'), bytes('inner1b'));
        outerArray[1] = new BytesBytesTuple[](1);
        outerArray[1][0] = BytesBytesTuple(bytes('inner2a'), bytes('inner2b'));

        bytes memory expected = abi.encodeWithSelector(selector, outerArray);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Mixed dynamic arrays at function parameter level
    // Tests LIFO metadata pairing -- metadata should not be mixed!
    function test_mixedDynamicAndStaticParameters() public pure {
        bytes[] memory regs = RegisterFile.initialize(5);
        regs.setDynamic(0, abi.encode(string('hi')));
        regs.setDynamic(1, abi.encode(bytes('A')));
        regs.setDynamic(2, abi.encode(bytes('BC')));
        regs[3] = abi.encode(false);
        regs[4] = abi.encode(address(0x2222222222222222222222222222222222222222));

        bytes memory bp = abi.encodePacked(
            Bp.d(0), Bp.pushArray(), Bp.d(1), Bp.d(2), Bp.end(), Bp.pushArray(), Bp.s(3), Bp.end(), Bp.s(4)
        );

        bytes4 selector = bytes4(keccak256('f1(string,bytes[],bool[],address)'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        string memory a0 = 'hi';
        bytes[] memory a1 = new bytes[](2);
        a1[0] = bytes('A');
        a1[1] = bytes('BC');
        bool[] memory a2 = new bool[](1);
        a2[0] = false;
        address a3 = address(0x2222222222222222222222222222222222222222);

        bytes memory canon = abi.encodeWithSignature('f1(string,bytes[],bool[],address)', a0, a1, a2, a3);
        assertEq(TestUtils.stripLength(raw), canon);
    }

    // Tests two adjacent dynamic arrays of different types (bytes[], string[])
    // Verifies correct metadata pairing when dynamic types appear consecutively
    function test_adjacentDynamicArraysDifferentTypes() public pure {
        bytes[] memory regs = RegisterFile.initialize(4);
        regs.setDynamic(0, abi.encode(bytes('A')));
        regs.setDynamic(1, abi.encode(bytes('BC')));
        regs.setDynamic(2, abi.encode(string('x')));
        regs.setDynamic(3, abi.encode(string('yy')));

        bytes memory bp =
            abi.encodePacked(Bp.pushArray(), Bp.d(0), Bp.d(1), Bp.end(), Bp.pushArray(), Bp.d(2), Bp.d(3), Bp.end());

        bytes4 selector = bytes4(keccak256('f2(bytes[],string[])'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        bytes[] memory a0 = new bytes[](2);
        a0[0] = bytes('A');
        a0[1] = bytes('BC');
        string[] memory a1 = new string[](2);
        a1[0] = 'x';
        a1[1] = 'yy';

        bytes memory canon = abi.encodeWithSignature('f2(bytes[],string[])', a0, a1);
        assertEq(TestUtils.stripLength(raw), canon);
    }

    // Tests multiple dynamic arrays contained within a single dynamic tuple
    // Verifies correct offset calculation when sibling dynamic types are tuple fields
    function test_multipleDynamicArraysInTuple() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        // tuple field 0: bytes[] elements
        regs.setDynamic(0, abi.encode(bytes('A')));
        regs.setDynamic(1, abi.encode(bytes('BC')));
        // tuple field 1: bool[] elements
        regs[2] = abi.encode(true); // single element

        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(), // dynamic tuple
            Bp.pushArray(),
            Bp.d(0),
            Bp.d(1),
            Bp.end(), // bytes[]
            Bp.pushArray(),
            Bp.s(2),
            Bp.end(), // bool[]
            Bp.end()
        );

        bytes4 selector = bytes4(keccak256('f3((bytes[],bool[]))'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        bytes[] memory t0 = new bytes[](2);
        t0[0] = bytes('A');
        t0[1] = bytes('BC');
        bool[] memory t1 = new bool[](1);
        t1[0] = true;

        BytesArrayBoolArrayTuple memory tupleStruct = BytesArrayBoolArrayTuple(t0, t1);
        bytes memory canon = abi.encodeWithSelector(selector, tupleStruct);
        assertEq(TestUtils.stripLength(raw), canon);
    }

    // Tests dynamic arrays separated by static types in function parameters
    // Verifies correct metadata pairing when static types interrupt dynamic array sequence
    function test_dynamicArraysSeparatedByStaticTypes() public pure {
        bytes[] memory regs = RegisterFile.initialize(5);
        regs.setDynamic(0, abi.encode(bytes('A')));
        regs.setDynamic(1, abi.encode(bytes('BC')));
        regs[2] = abi.encode(address(0x7777777777777777777777777777777777777777));
        regs[3] = abi.encode(true);
        regs[4] = abi.encode(uint256(42));

        bytes memory bp = abi.encodePacked(
            Bp.pushArray(),
            Bp.d(0),
            Bp.d(1),
            Bp.end(), // bytes[]
            Bp.s(2), // address
            Bp.pushArray(),
            Bp.s(3),
            Bp.end(), // bool[]
            Bp.s(4) // uint256
        );

        bytes4 selector = bytes4(keccak256('f5(bytes[],address,bool[],uint256)'));
        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        bytes[] memory a0 = new bytes[](2);
        a0[0] = bytes('A');
        a0[1] = bytes('BC');
        address a1 = address(0x7777777777777777777777777777777777777777);
        bool[] memory a2 = new bool[](1);
        a2[0] = true;
        uint256 a3 = 42;

        bytes memory canon = abi.encodeWithSignature('f5(bytes[],address,bool[],uint256)', a0, a1, a2, a3);
        assertEq(TestUtils.stripLength(raw), canon);
    }

    // Tests encoding of a complex structure with tuple containing dynamic bytes and empty array
    // Verifies correct ABI encoding when dynamic array has zero elements
    function test_complexStructureWithEmptyArray() public {
        ProcessData memory data = ProcessData({ value: uint256(0x0bbbbbbb), data: bytes(hex'999999999999') });

        bytes[] memory registers = new bytes[](3);
        registers[0] = abi.encode(uint256(0x0aaaaaaa)); // id parameter
        registers[1] = abi.encode(data.value); // tuple value field
        registers.setDynamic(2, abi.encode(data.data)); // tuple data field

        // Blueprint encoding: uint256, (uint256, bytes), uint256[] where array is empty
        bytes memory blueprint = abi.encodePacked(
            uint8(0), // static register 0 (id)
            uint8(0x7E), // START_TUPLE_STATIC (tuple begins)
            uint8(1), // static register 1 (tuple.value)
            uint8(0x82), // dynamic register 2 (tuple.data, 2 | 0x80)
            uint8(0x7B), // END_DYNAMIC (tuple ends)
            uint8(0x7C), // START_ARRAY_DYNAMIC (empty array begins)
            uint8(0x7B) // END_DYNAMIC (empty array ends)
        );

        bytes4 selector = bytes4(keccak256('processData(uint256,(uint256,bytes),uint256[])'));
        bytes memory encoded = BlueprintEncoder.encodeFromBlueprint(selector, blueprint, registers);

        // Create expected encoding using standard ABI encoding with empty array
        bytes memory abiEncoded = abi.encodeWithSignature(
            'processData(uint256,(uint256,bytes),uint256[])', uint256(0x0aaaaaaa), data, new uint256[](0)
        );

        // Verify blueprint encoding matches standard ABI encoding
        Asserts.assertEncodingMatches(encoded, abiEncoded);
    }

    // Tests encoding of bytes[2] (fixed-size array of dynamic type)
    // NOTE: This test uses pushTuple() to achieve ABI-compliant encoding.
    // Per ABI spec, bytes[2] should be encoded as dynamic (with pointer).
    // pushArrayStatic() would encode it inline (treating as static data),
    // while pushTuple() produces the ABI-compliant encoding with pointer.
    function test_compareCalldataBuilds() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        bytes memory data1 = hex'abababababababababababababababababababababababababababababababababababab';
        bytes memory data2 = hex'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
        regs.setDynamic(0, abi.encode(data1));
        regs.setDynamic(1, abi.encode(data2));

        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        bytes[2] memory arr;
        arr[0] = data1;
        arr[1] = data2;
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected, 'Broken');
    }

    // Tests dynamic tuple encoding with two bytes elements
    // Verifies tuple structure is correctly encoded with dynamic fields
    function test_dynamicTuple() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory c0 = hex'00';
        bytes memory c1 = hex'11';
        regs.setDynamic(0, abi.encode(c0));
        regs.setDynamic(1, abi.encode(c1));
        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory expected = abi.encode(DynamicTuple({ a: c0, b: c1 }));
        assertEq(TestUtils.stripLength(out), expected);
    }

    // Tests all-static flat parameters (uint256,address,bool,bytes32)
    // Verifies that static parameters encode inline without pointers
    function test_allStaticFlatParameters() public pure {
        bytes[] memory regs = RegisterFile.initialize(4);
        regs[0] = abi.encode(uint256(42));
        regs[1] = abi.encode(address(0x1111111111111111111111111111111111111111));
        regs[2] = abi.encode(true);
        regs[3] = abi.encode(bytes32(0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef));

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1), Bp.s(2), Bp.s(3));
        bytes4 selector = bytes4(keccak256('f(uint256,address,bool,bytes32)'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected = abi.encodeWithSignature(
            'f(uint256,address,bool,bytes32)',
            uint256(42),
            address(0x1111111111111111111111111111111111111111),
            true,
            bytes32(0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
        );

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests top-level multiple dynamics without containers (bytes,string)
    // Verifies correct two pointers at head and correct tails with order preserved
    function test_topLevelMultipleDynamics() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs.setDynamic(0, abi.encode(bytes('hello')));
        regs.setDynamic(1, abi.encode(string('world')));

        bytes memory bp = abi.encodePacked(Bp.d(0), Bp.d(1));
        bytes4 selector = bytes4(keccak256('f(bytes,string)'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected = abi.encodeWithSignature('f(bytes,string)', bytes('hello'), string('world'));

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests static tuple (uint256,address,bool)
    // Verifies tuple encodes inline with no pointer
    function test_staticTupleInline() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        regs[0] = abi.encode(uint256(999));
        regs[1] = abi.encode(address(0x2222222222222222222222222222222222222222));
        regs[2] = abi.encode(false);

        bytes memory bp = abi.encodePacked(Bp.pushTupleStatic(), Bp.s(0), Bp.s(1), Bp.s(2), Bp.end());
        bytes4 selector = bytes4(keccak256('f((uint256,address,bool))'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        StaticTripleTuple memory tuple =
            StaticTripleTuple(999, address(0x2222222222222222222222222222222222222222), false);
        bytes memory expected = abi.encodeWithSelector(selector, tuple);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests static array of static elements uint256[3]
    // Verifies array encodes inline with no pointer
    function test_staticArrayOfStaticElements() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        regs[0] = abi.encode(uint256(10));
        regs[1] = abi.encode(uint256(20));
        regs[2] = abi.encode(uint256(30));

        bytes memory bp = abi.encodePacked(Bp.pushArrayStatic(), Bp.s(0), Bp.s(1), Bp.s(2), Bp.end());
        bytes4 selector = bytes4(keccak256('f(uint256[3])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        uint256[3] memory arr = [uint256(10), uint256(20), uint256(30)];
        bytes memory expected = abi.encodeWithSignature('f(uint256[3])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests static array of dynamic elements string[2] - ABI-compliant via tuple rule
    // Verifies ABI-compliant encoding using pushTuple()
    function test_staticArrayDynamicElementsABICompliant() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs.setDynamic(0, abi.encode(string('first')));
        regs.setDynamic(1, abi.encode(string('second')));

        // Using pushTuple for ABI-compliant encoding
        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes4 selector = bytes4(keccak256('f(string[2])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        string[2] memory arr = [string('first'), string('second')];
        bytes memory expected = abi.encodeWithSignature('f(string[2])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic array of static elements - empty array
    function test_dynamicArrayOfStaticsEmpty() public pure {
        bytes[] memory regs = RegisterFile.initialize(0);

        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.end());
        bytes4 selector = bytes4(keccak256('f(uint256[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        uint256[] memory arr = new uint256[](0);
        bytes memory expected = abi.encodeWithSignature('f(uint256[])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic array of static elements - single element
    function test_dynamicArrayOfStaticsSingle() public pure {
        bytes[] memory regs = RegisterFile.initialize(1);
        regs[0] = abi.encode(uint256(100));

        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.s(0), Bp.end());
        bytes4 selector = bytes4(keccak256('f(uint256[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        uint256[] memory arr = new uint256[](1);
        arr[0] = 100;
        bytes memory expected = abi.encodeWithSignature('f(uint256[])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic array of static elements - three elements
    function test_dynamicArrayOfStaticsThree() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        regs[0] = abi.encode(uint256(100));
        regs[1] = abi.encode(uint256(200));
        regs[2] = abi.encode(uint256(300));

        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.s(0), Bp.s(1), Bp.s(2), Bp.end());
        bytes4 selector = bytes4(keccak256('f(uint256[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        uint256[] memory arr = new uint256[](3);
        arr[0] = 100;
        arr[1] = 200;
        arr[2] = 300;
        bytes memory expected = abi.encodeWithSignature('f(uint256[])', arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Dynamic array of dynamic tuples with proper pointer base calculation
    // Tests ((uint256,bytes)[]) - validates pointer arithmetic for nested dynamic structures
    // This is a critical test for ensuring element heads point correctly within dynamic arrays
    function test_dynamicArrayDynamicTuplesPointerBase() public pure {
        bytes[] memory regs = RegisterFile.initialize(4);
        regs[0] = abi.encode(uint256(111));
        regs.setDynamic(1, abi.encode(bytes('first')));
        regs[2] = abi.encode(uint256(222));
        regs.setDynamic(3, abi.encode(bytes('second')));

        bytes memory bp = abi.encodePacked(
            Bp.pushArray(),
            Bp.pushTuple(),
            Bp.s(0),
            Bp.d(1),
            Bp.end(),
            Bp.pushTuple(),
            Bp.s(2),
            Bp.d(3),
            Bp.end(),
            Bp.end()
        );
        bytes4 selector = bytes4(keccak256('f((uint256,bytes)[])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        UintBytesTuple[] memory arr = new UintBytesTuple[](2);
        arr[0] = UintBytesTuple(111, bytes('first'));
        arr[1] = UintBytesTuple(222, bytes('second'));
        bytes memory expected = abi.encodeWithSelector(selector, arr);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests dynamic tuple with one dynamic element (uint256,bytes)
    function test_dynamicTupleWithOneDynamic() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs[0] = abi.encode(uint256(555));
        regs.setDynamic(1, abi.encode(bytes('dynamic data')));

        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.s(0), Bp.d(1), Bp.end());
        bytes4 selector = bytes4(keccak256('f((uint256,bytes))'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        UintBytesTuple memory tuple = UintBytesTuple(555, bytes('dynamic data'));
        bytes memory expected = abi.encodeWithSelector(selector, tuple);

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests zero-length dynamic bytes/string handling
    // Verifies (bytes,string,bytes) with empty middle and non-empty tail
    function test_zeroLengthDynamics() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        regs.setDynamic(0, abi.encode(bytes('first')));
        regs.setDynamic(1, abi.encode(string(''))); // Empty string
        regs.setDynamic(2, abi.encode(bytes('third')));

        bytes memory bp = abi.encodePacked(Bp.d(0), Bp.d(1), Bp.d(2));
        bytes4 selector = bytes4(keccak256('f(bytes,string,bytes)'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
        bytes memory expected =
            abi.encodeWithSignature('f(bytes,string,bytes)', bytes('first'), string(''), bytes('third'));

        Asserts.assertEncodingMatches(raw, expected);
    }

    // Error handling - bad dynamic format (register shorter than 32 bytes)
    function test_errorBadDynamicFormat() public {
        bytes[] memory regs = RegisterFile.initialize(1);
        regs[0] = hex'11'; // Only 1 byte, should be at least 32 for length word

        bytes memory bp = abi.encodePacked(Bp.d(0));
        bytes4 selector = bytes4(keccak256('f(bytes)'));

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadDynamicFormat.selector, uint8(0)));
        BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
    }

    // Error handling - static register size must be 32
    function test_errorStaticRegisterSize() public {
        bytes[] memory regs = RegisterFile.initialize(1);
        regs[0] = hex'01'; // Only 1 byte, should be 32 bytes

        bytes memory bp = abi.encodePacked(Bp.s(0));
        bytes4 selector = bytes4(keccak256('f(uint256)'));

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.BadStaticFormat.selector, uint8(0)));
        BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
    }

    // Error handling - unbalanced containers
    function test_errorUnbalancedContainers() public {
        bytes[] memory regs = RegisterFile.initialize(1);
        regs[0] = abi.encode(uint256(42));

        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.s(0)); // Missing end()
        bytes4 selector = bytes4(keccak256('f((uint256))'));

        vm.expectRevert(abi.encodeWithSelector(BlueprintEncoder.UnclosedContainer.selector));
        BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
    }

    // Error handling - invalid register index
    function test_errorInvalidRegisterIndex() public {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs[0] = abi.encode(uint256(1));
        regs[1] = abi.encode(uint256(2));

        bytes memory bp = abi.encodePacked(Bp.s(7)); // Index 7 > available registers
        bytes4 selector = bytes4(keccak256('f(uint256)'));

        // This will likely trigger a bounds check in register access
        vm.expectRevert();
        BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);
    }

    // Tests encodeFromBlueprint vs encodeData selector check
    function test_selectorVsNoSelector() public pure {
        bytes[] memory regs = RegisterFile.initialize(2);
        regs[0] = abi.encode(uint256(999));
        regs.setDynamic(1, abi.encode(bytes('test')));

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.d(1));
        bytes4 selector = bytes4(keccak256('f(uint256,bytes)'));

        // With selector
        bytes memory withSelector = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Without selector
        bytes memory withoutSelector = BlueprintEncoder.encodeData(bp, regs);

        // Verify withSelector has the selector prepended to the same data as withoutSelector
        // Build expected result by prepending selector to withoutSelector
        bytes memory expectedWithSelector = abi.encodePacked(selector, TestUtils.stripLength(withoutSelector));

        Asserts.assertEncodingMatches(withSelector, expectedWithSelector);
    }

    // Tests dynamic array inside dynamic tuple
    // Verifies (bytes[],uint256) with array length 2
    function test_dynamicArrayInsideDynamicTuple() public pure {
        bytes[] memory regs = RegisterFile.initialize(3);
        regs.setDynamic(0, abi.encode(bytes('elem1')));
        regs.setDynamic(1, abi.encode(bytes('elem2')));
        regs[2] = abi.encode(uint256(777));

        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(),
            Bp.pushArray(),
            Bp.d(0),
            Bp.d(1),
            Bp.end(), // bytes[] inside tuple
            Bp.s(2), // uint256 inside tuple
            Bp.end()
        );
        bytes4 selector = bytes4(keccak256('f((bytes[],uint256))'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Create expected structure
        bytes[] memory arr = new bytes[](2);
        arr[0] = bytes('elem1');
        arr[1] = bytes('elem2');
        TupleWithArray memory tuple = TupleWithArray(arr, 777);

        bytes memory expected = abi.encodeWithSelector(selector, tuple);
        Asserts.assertEncodingMatches(raw, expected);
    }

    // Tests fixed array of static tuples (uint256,bool)[2]
    // Verifies entirely inline encoding
    function test_fixedArrayOfStaticTuples() public pure {
        bytes[] memory regs = RegisterFile.initialize(4);
        regs[0] = abi.encode(uint256(10));
        regs[1] = abi.encode(true);
        regs[2] = abi.encode(uint256(20));
        regs[3] = abi.encode(false);

        bytes memory bp = abi.encodePacked(
            Bp.pushArrayStatic(),
            Bp.pushTupleStatic(),
            Bp.s(0),
            Bp.s(1),
            Bp.end(),
            Bp.pushTupleStatic(),
            Bp.s(2),
            Bp.s(3),
            Bp.end(),
            Bp.end()
        );
        bytes4 selector = bytes4(keccak256('f((uint256,bool)[2])'));

        bytes memory raw = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Create expected structure
        StaticPairTuple[2] memory arr;
        arr[0] = StaticPairTuple(10, true);
        arr[1] = StaticPairTuple(20, false);

        bytes memory expected = abi.encodeWithSelector(selector, arr);
        Asserts.assertEncodingMatches(raw, expected);
    }
}
