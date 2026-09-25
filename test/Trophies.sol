// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { TestUtils } from './lib/TestUtils.sol';
import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallDataBuild } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { CommandPacking } from 'src/CommandPacking.sol';
import { Bp } from './lib/Bp.sol';
import { BlueprintEncoder } from '../src/BlueprintEncoder.sol';
import { RegisterFile } from '../src/RegisterFile.sol';

// forge test --match-contract Trophies -vv
contract Trophies is SpecTestBase {
    using RegisterFile for bytes[];

    /// Minimal Repro for Halmos broken
    function test_staticArray_dynamicElements() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory a0 = hex'ff';
        bytes memory a1 = hex'dd';
        regs.setDynamic(0, abi.encode(a0));
        regs.setDynamic(1, abi.encode(a1));
        bytes memory bp = abi.encodePacked(
            Bp.pushTuple(), // NOTE: Static Array with dynamic elements must be considered as a dynamic tuple!
            Bp.d(0),
            Bp.d(1),
            Bp.end()
        );
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        bytes[2] memory arr;
        arr[0] = a0;
        arr[1] = a1;
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected, 'Broken');
    }

    struct DynamicTuple {
        bytes a;
        bytes b;
    }

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

    struct Data {
        uint256 value;
        bytes data;
    }

    /// === MANUAL REDO HALMOS REPRO === ///
    // Property 4.2) dynamic array with dynamic elements encoding matches abi.encode
    function test_halmos_repro_111() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory b0 = hex'ffffffffffffffff';
        bytes memory b1 = hex'bbbbbbbbbbbbbbbb';
        regs.setDynamic(0, abi.encode(b0));
        regs.setDynamic(1, abi.encode(b1));
        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        bytes[] memory arr = new bytes[](2);
        arr[0] = b0;
        arr[1] = b1;
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected, 'Broken');
    }

    // Property 3.1) static array[2] with dynamic elements matches abi.encode
    function test_halmos_repro1_222() public pure {
        /// Known issue: The issue is that the array should be viewed as a tuple
        bytes[] memory regs = new bytes[](2);
        bytes memory a0 = hex'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        bytes memory a1 = hex'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        regs.setDynamic(0, abi.encode(a0));
        regs.setDynamic(1, abi.encode(a1));
        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        bytes[2] memory arr;
        arr[0] = a0;
        arr[1] = a1;
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected, 'Broken');
    }

    function test_halmos_repro1_333() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory a0 = hex'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        bytes memory a1 = hex'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        regs.setDynamic(0, abi.encode(a0));
        regs.setDynamic(1, abi.encode(a1));
        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        bytes[2] memory arr;
        arr[0] = a0;
        arr[1] = a1;
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected, 'Broken');
    }

    struct OrderLite {
        address maker;
        uint256 amount;
        bytes data1;
        bytes data2;
    }

    // Dynamic tuple element pointer base off by 0x20 (array elements)
    // https://github.com/Recon-Fuzz/lifi-vm-review/issues/37
    function test_dynamic_tuple_array_pointer_base() public pure {
        // Registers layout (by index):
        // 0: order[0].maker (static)
        // 1: order[0].amount (static)
        // 2: order[0].data1 (dynamic)
        // 3: order[0].data2 (dynamic)
        // 4: sigs[0] (dynamic)
        // 5: sigs[1] (dynamic)
        bytes[] memory regs = RegisterFile.initialize(6);

        regs[0] = abi.encode(address(0x1111111111111111111111111111111111111111));
        regs[1] = abi.encode(uint256(123));
        regs.setDynamic(2, abi.encode(bytes('0xdead')));
        regs.setDynamic(3, abi.encode(bytes('beef')));
        regs.setDynamic(4, abi.encode(bytes(hex'5b59f0')));
        regs.setDynamic(5, abi.encode(bytes(hex'01bef3b2')));

        // Blueprint:
        // arg0: orders: dynamic array of dynamic tuple (address,uint256,bytes,bytes)
        //   [ pushArray, pushTuple, s(0), s(1), d(2), d(3), endTuple, endArray ]
        // arg1: sigs: dynamic array of bytes
        //   [ pushArray, d(4), d(5), endArray ]
        bytes memory bp;
        // orders
        bp = bytes.concat(Bp.pushArray());
        bp = bytes.concat(bp, Bp.pushTuple());
        bp = bytes.concat(bp, Bp.s(0), Bp.s(1), Bp.d(2), Bp.d(3));
        bp = bytes.concat(bp, Bp.end()); // end tuple
        bp = bytes.concat(bp, Bp.end()); // end orders array
        // sigs
        bp = bytes.concat(bp, Bp.pushArray());
        bp = bytes.concat(bp, Bp.d(4), Bp.d(5));
        bp = bytes.concat(bp, Bp.end());

        bytes4 selector = bytes4(keccak256('f((address,uint256,bytes,bytes)[],bytes[])'));

        // Encode via BlueprintEncoder
        bytes memory actual = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Expected using abi.encodeWithSelector
        OrderLite[] memory orders = new OrderLite[](1);
        orders[0] = OrderLite({
            maker: address(0x1111111111111111111111111111111111111111),
            amount: 123,
            data1: bytes('0xdead'),
            data2: bytes('beef')
        });
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = bytes(hex'5b59f0');
        sigs[1] = bytes(hex'01bef3b2');
        bytes memory expected = abi.encodeWithSelector(selector, orders, sigs);

        assertEq(TestUtils.stripLength(actual), expected, 'encoding mismatch');
    }

    // Dynamic array element pointer base off by 0x20
    // https://github.com/Recon-Fuzz/lifi-vm-review/issues/35
    function test_dynamic_array_pointer_base() public pure {
        // registers: [0] dynamic string "x"
        bytes[] memory regs = RegisterFile.initialize(1);
        regs.setDynamic(0, abi.encode(string('x')));

        // blueprint: [ START_ARRAY_DYNAMIC, d(0), END ]  => f(string[])
        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.d(0), Bp.end());
        bytes4 selector = bytes4(keccak256('f(string[])'));

        bytes memory actual = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        string[] memory arr = new string[](1);
        arr[0] = 'x';
        bytes memory expected = abi.encodeWithSignature('f(string[])', arr);

        assertEq(TestUtils.stripLength(actual), expected, 'encoding mismatch');
    }

    // Dynamic container metadata ordering causes sibling mispairing
    // https://github.com/Recon-Fuzz/lifi-vm-review/issues/36
    function test_dynamic_container_metadata_ordering() public pure {
        // registers: [0] string, [1] bytes el0, [2] bytes el1, [3] bool el0, [4] address
        bytes[] memory regs = RegisterFile.initialize(5);
        regs.setDynamic(0, abi.encode(string('hi')));
        regs.setDynamic(1, abi.encode(bytes('A')));
        regs.setDynamic(2, abi.encode(bytes('BC')));
        regs[3] = abi.encode(false);
        regs[4] = abi.encode(address(0x2222222222222222222222222222222222222222));

        // blueprint tokens: d(0), [pushArray d(1) d(2) end], [pushArray s(3) end], s(4)
        bytes memory bp = abi.encodePacked(
            Bp.d(0), Bp.pushArray(), Bp.d(1), Bp.d(2), Bp.end(), Bp.pushArray(), Bp.s(3), Bp.end(), Bp.s(4)
        );

        // Selector for f1(string,bytes[],bool[],address) (from fuzz case)
        bytes4 selector = 0x6390f115;

        bytes memory actual = BlueprintEncoder.encodeFromBlueprint(selector, bp, regs);

        // Expected
        string memory a0 = 'hi';
        bytes[] memory a1 = new bytes[](2);
        a1[0] = bytes('A');
        a1[1] = bytes('BC');
        bool[] memory a2 = new bool[](1);
        a2[0] = false;
        address a3 = address(0x2222222222222222222222222222222222222222);

        bytes memory expected = abi.encodeWithSignature('f1(string,bytes[],bool[],address)', a0, a1, a2, a3);

        assertEq(TestUtils.stripLength(actual), expected, 'encoding mismatch');
    }
}
