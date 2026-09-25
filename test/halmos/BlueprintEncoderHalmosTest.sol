// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test, console } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';
import { BlueprintEncoder } from 'src/BlueprintEncoder.sol';
import { RegisterFile } from 'src/RegisterFile.sol';
import { VirtualMachine } from 'src/VirtualMachine.sol';
import { VmConstants } from 'src/VmConstants.sol';
import { VMCommand, VMState } from 'src/DataModel.sol';

import { TestUtils } from '../lib/TestUtils.sol';
import { Bp } from '../lib/Bp.sol';
import { VmCmd } from '../lib/VmCmd.sol';

// halmos --contract BlueprintEncoderHalmosTest --loop 100
contract BlueprintEncoderHalmosTest is Test, SymTest {
    using RegisterFile for bytes[];

    // Property 1) symbolic flat blueprint matches abi.encode
    function check_symbolic_flat_matches_abi() public pure {
        bytes[] memory regs = new bytes[](4);
        regs[0] = abi.encode(svm.createBytes32('s0'));
        regs[1] = abi.encode(svm.createBytes32('s1'));
        bytes memory d2 = svm.createBytes(32, 'd2');
        bytes memory d3 = svm.createBytes(64, 'd3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));

        bytes memory bp = new bytes(3);
        uint8 t0 = uint8(svm.createUint(8, 't0'));
        uint8 t1 = uint8(svm.createUint(8, 't1'));
        uint8 t2 = uint8(svm.createUint(8, 't2'));

        bool ok0 = (t0 == 0 || t0 == 1 || t0 == 0x82 || t0 == 0x83);
        bool ok1 = (t1 == 0 || t1 == 1 || t1 == 0x82 || t1 == 0x83);
        bool ok2 = (t2 == 0 || t2 == 1 || t2 == 0x82 || t2 == 0x83);
        require(ok0 && ok1 && ok2);

        bp[0] = bytes1(t0);
        bp[1] = bytes1(t1);
        bp[2] = bytes1(t2);

        bytes memory out = BlueprintEncoder.encodeData(bp, regs);

        uint8 m;
        if ((t0 & 0x80) != 0) m |= 1;
        if ((t1 & 0x80) != 0) m |= 2;
        if ((t2 & 0x80) != 0) m |= 4;

        bytes32 s_at_0;
        bytes32 s_at_1;
        bytes32 s_at_2;
        bytes memory d_at_0;
        bytes memory d_at_1;
        bytes memory d_at_2;
        assembly {
            s_at_0 := mload(add(mload(add(add(regs, 32), shl(5, and(t0, 0x7F)))), 32))
            s_at_1 := mload(add(mload(add(add(regs, 32), shl(5, and(t1, 0x7F)))), 32))
            s_at_2 := mload(add(mload(add(add(regs, 32), shl(5, and(t2, 0x7F)))), 32))
            d_at_0 := mload(add(add(regs, 32), shl(5, and(t0, 0x7F))))
            d_at_1 := mload(add(add(regs, 32), shl(5, and(t1, 0x7F))))
            d_at_2 := mload(add(add(regs, 32), shl(5, and(t2, 0x7F))))
        }

        bytes memory expected;
        if (m == 0) {
            expected = abi.encode(s_at_0, s_at_1, s_at_2);
        } else if (m == 1) {
            expected = abi.encode(TestUtils.stripLength(d_at_0), s_at_1, s_at_2);
        } else if (m == 2) {
            expected = abi.encode(s_at_0, TestUtils.stripLength(d_at_1), s_at_2);
        } else if (m == 3) {
            expected = abi.encode(TestUtils.stripLength(d_at_0), TestUtils.stripLength(d_at_1), s_at_2);
        } else if (m == 4) {
            expected = abi.encode(s_at_0, s_at_1, TestUtils.stripLength(d_at_2));
        } else if (m == 5) {
            expected = abi.encode(TestUtils.stripLength(d_at_0), s_at_1, TestUtils.stripLength(d_at_2));
        } else if (m == 6) {
            expected = abi.encode(s_at_0, TestUtils.stripLength(d_at_1), TestUtils.stripLength(d_at_2));
        } else {
            expected =
                abi.encode(TestUtils.stripLength(d_at_0), TestUtils.stripLength(d_at_1), TestUtils.stripLength(d_at_2));
        }

        assertEq(TestUtils.stripLength(out), expected);
    }

    // Property 2) encodeFromBlueprint with flat args matches abi.encode
    function check_encode_from_blueprint_flat_matches_abi() public pure {
        bytes[] memory regs = new bytes[](4);
        regs[0] = abi.encode(svm.createBytes32('s0'));
        regs[1] = abi.encode(svm.createBytes32('s1'));
        bytes memory d2 = svm.createBytes(32, 'd2');
        bytes memory d3 = svm.createBytes(64, 'd3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));
        bytes memory bp = new bytes(3);
        uint8 t0 = uint8(svm.createUint(8, 't0f'));
        uint8 t1 = uint8(svm.createUint(8, 't1f'));
        uint8 t2 = uint8(svm.createUint(8, 't2f'));
        bool ok0 = (t0 == 0 || t0 == 1 || t0 == 0x82 || t0 == 0x83);
        bool ok1 = (t1 == 0 || t1 == 1 || t1 == 0x82 || t1 == 0x83);
        bool ok2 = (t2 == 0 || t2 == 1 || t2 == 0x82 || t2 == 0x83);
        require(ok0 && ok1 && ok2);
        bp[0] = bytes1(t0);
        bp[1] = bytes1(t1);
        bp[2] = bytes1(t2);
        bytes4 sel = bytes4(svm.createBytes32('sel'));
        bytes memory out = BlueprintEncoder.encodeFromBlueprint(sel, bp, regs);
        uint8 m;
        if ((t0 & 0x80) != 0) m |= 1;
        if ((t1 & 0x80) != 0) m |= 2;
        if ((t2 & 0x80) != 0) m |= 4;
        bytes32 s_at_0;
        bytes32 s_at_1;
        bytes32 s_at_2;
        bytes memory d_at_0;
        bytes memory d_at_1;
        bytes memory d_at_2;
        assembly {
            s_at_0 := mload(add(mload(add(add(regs, 32), shl(5, and(t0, 0x7F)))), 32))
            s_at_1 := mload(add(mload(add(add(regs, 32), shl(5, and(t1, 0x7F)))), 32))
            s_at_2 := mload(add(mload(add(add(regs, 32), shl(5, and(t2, 0x7F)))), 32))
            d_at_0 := mload(add(add(regs, 32), shl(5, and(t0, 0x7F))))
            d_at_1 := mload(add(add(regs, 32), shl(5, and(t1, 0x7F))))
            d_at_2 := mload(add(add(regs, 32), shl(5, and(t2, 0x7F))))
        }
        bytes memory body;
        if (m == 0) {
            body = abi.encode(s_at_0, s_at_1, s_at_2);
        } else if (m == 1) {
            body = abi.encode(TestUtils.stripLength(d_at_0), s_at_1, s_at_2);
        } else if (m == 2) {
            body = abi.encode(s_at_0, TestUtils.stripLength(d_at_1), s_at_2);
        } else if (m == 3) {
            body = abi.encode(TestUtils.stripLength(d_at_0), TestUtils.stripLength(d_at_1), s_at_2);
        } else if (m == 4) {
            body = abi.encode(s_at_0, s_at_1, TestUtils.stripLength(d_at_2));
        } else if (m == 5) {
            body = abi.encode(TestUtils.stripLength(d_at_0), s_at_1, TestUtils.stripLength(d_at_2));
        } else if (m == 6) {
            body = abi.encode(s_at_0, TestUtils.stripLength(d_at_1), TestUtils.stripLength(d_at_2));
        } else {
            body =
                abi.encode(TestUtils.stripLength(d_at_0), TestUtils.stripLength(d_at_1), TestUtils.stripLength(d_at_2));
        }
        bytes memory expected = bytes.concat(sel, body);
        assertEq(TestUtils.stripLength(out), expected);
    }

    // Property 3) static array[2] encoding matches abi.encode
    function check_static_array2_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        regs[0] = abi.encode(svm.createBytes32('a0'));
        regs[1] = abi.encode(svm.createBytes32('a1'));
        bytes memory bp = abi.encodePacked(Bp.pushArrayStatic(), Bp.s(0), Bp.s(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes32 s0;
        bytes32 s1;
        assembly {
            s0 := mload(add(mload(add(add(regs, 32), shl(5, 0))), 32))
            s1 := mload(add(mload(add(add(regs, 32), shl(5, 1))), 32))
        }
        uint256[2] memory arr;
        arr[0] = uint256(s0);
        arr[1] = uint256(s1);
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected);
    }

    // Property 3.1) static array[2] with dynamic elements matches abi.encode
    function check_static_array2_with_dynamic_elements_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory a0 = svm.createBytes(36, 'a0');
        bytes memory a1 = svm.createBytes(36, 'a1');
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

    function check_static_array2_with_dynamic_elements_works_as_dynamic_tuple() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory a0 = svm.createBytes(36, 'a0');
        bytes memory a1 = svm.createBytes(36, 'a1');
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

    // Property 4) dynamic array with static elements encoding matches abi.encode
    function check_dynamic_array_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        regs[0] = abi.encode(svm.createBytes32('b0'));
        regs[1] = abi.encode(svm.createBytes32('b1'));
        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.s(0), Bp.s(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes32 s0;
        bytes32 s1;
        assembly {
            s0 := mload(add(mload(add(add(regs, 32), shl(5, 0))), 32))
            s1 := mload(add(mload(add(add(regs, 32), shl(5, 1))), 32))
        }
        uint256[] memory arr = new uint256[](2);
        arr[0] = uint256(s0);
        arr[1] = uint256(s1);
        bytes memory expected = abi.encode(arr);
        assertEq(TestUtils.stripLength(out), expected);
    }

    // Property 4.2) dynamic array with dynamic elements encoding matches abi.encode
    function check_dynamic_array_with_dynamic_elements_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory b0 = svm.createBytes(36, 'b0');
        bytes memory b1 = svm.createBytes(36, 'b1');
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

    /// Property 5) tuple with static elements encoding matches abi.encode

    struct StaticTuple {
        uint256 a;
        uint256 b;
    }

    /// Property 5.1) tuple with static elements encoding matches abi.encode
    function check_tuple_with_static_elements_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes32 c0 = svm.createBytes32('c0');
        bytes32 c1 = svm.createBytes32('c1');
        regs[0] = abi.encode(c0);
        regs[1] = abi.encode(c1);
        bytes memory bp = abi.encodePacked(Bp.pushTupleStatic(), Bp.s(0), Bp.s(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory expected = abi.encode(StaticTuple({ a: uint256(c0), b: uint256(c1) }));
        assertEq(TestUtils.stripLength(out), expected);
    }

    struct DynamicTuple {
        bytes a;
        bytes b;
    }

    /// Property 5.2) tuple with dynamic elements encoding matches abi.encode
    function check_tuple_with_dynamic_elements_matches_abi() public pure {
        bytes[] memory regs = new bytes[](2);
        bytes memory c0 = svm.createBytes(36, 'c0');
        bytes memory c1 = svm.createBytes(36, 'c1');
        regs.setDynamic(0, abi.encode(c0));
        regs.setDynamic(1, abi.encode(c1));
        bytes memory bp = abi.encodePacked(Bp.pushTuple(), Bp.d(0), Bp.d(1), Bp.end());
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory expected = abi.encode(DynamicTuple({ a: c0, b: c1 }));
        assertEq(TestUtils.stripLength(out), expected);
    }

    // Property 6) malformed static register data causes revert
    function check_bad_static_format_reverts() external {
        bytes[] memory regs = new bytes[](1);
        regs[0] = hex'01'; // length 1, invalid for static
        bytes memory bp = new bytes(1);
        bp[0] = bytes1(uint8(0)); // static register 0

        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), BlueprintEncoder.BadStaticFormat.selector, 'selector');
    }

    // Property 7) malformed dynamic register data causes revert
    function check_bad_dynamic_format_reverts() external {
        bytes[] memory regs = new bytes[](1);
        regs[0] = hex'01'; // length 1, invalid for dynamic (< 32)
        bytes memory bp = new bytes(1);
        bp[0] = bytes1(uint8(0x80)); // dynamic register 0

        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), BlueprintEncoder.BadDynamicFormat.selector, 'selector');
    }

    // Property 8) payload length invariants hold for data and selector
    function check_payload_length_invariants() public pure {
        bytes[] memory regs = new bytes[](2);
        regs[0] = abi.encode(svm.createBytes32('x0'));
        bytes memory d = svm.createBytes(48, 'xd');
        regs.setDynamic(1, abi.encode(d));
        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.d(1));
        bytes memory outData = BlueprintEncoder.encodeData(bp, regs);
        bytes memory plData = TestUtils.stripLength(outData);
        uint256 headBytes = 64;
        uint256 tailBytes;
        assembly {
            let r1 := mload(add(add(regs, 32), shl(5, 1)))
            tailBytes := mload(r1)
        }
        assertEq(plData.length, headBytes + tailBytes);
        bytes4 sel = bytes4(svm.createBytes32('sel2'));
        bytes memory outSel = BlueprintEncoder.encodeFromBlueprint(sel, bp, regs);
        bytes memory plSel = TestUtils.stripLength(outSel);
        assertEq(plSel.length, 4 + headBytes + tailBytes);
    }

    // Property 9) dynamic pointers point within encoded tail bounds
    function check_pointer_bounds_flat() public pure {
        bytes[] memory regs = new bytes[](4);
        regs[0] = abi.encode(svm.createBytes32('p0'));
        regs[1] = abi.encode(svm.createBytes32('p1'));
        bytes memory d2 = svm.createBytes(32, 'pd2');
        bytes memory d3 = svm.createBytes(96, 'pd3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));
        bytes memory bp = new bytes(3);
        uint8 t0 = uint8(svm.createUint(8, 'pt0'));
        uint8 t1 = uint8(svm.createUint(8, 'pt1'));
        uint8 t2 = uint8(svm.createUint(8, 'pt2'));
        bool ok0 = (t0 == 0 || t0 == 1 || t0 == 0x82 || t0 == 0x83);
        bool ok1 = (t1 == 0 || t1 == 1 || t1 == 0x82 || t1 == 0x83);
        bool ok2 = (t2 == 0 || t2 == 1 || t2 == 0x82 || t2 == 0x83);
        require(ok0 && ok1 && ok2);
        bp[0] = bytes1(t0);
        bp[1] = bytes1(t1);
        bp[2] = bytes1(t2);
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory pl = TestUtils.stripLength(out);
        uint256 headBytes = 96;
        uint256 dlen2;
        uint256 dlen3;
        assembly {
            let r2 := mload(add(add(regs, 32), shl(5, 2)))
            let r3 := mload(add(add(regs, 32), shl(5, 3)))
            dlen2 := mload(r2)
            dlen3 := mload(r3)
        }
        uint256 tailBytes = 0;
        if ((t0 & 0x80) != 0) {
            if ((t0 & 0x7F) == 2) tailBytes += dlen2;
            else tailBytes += dlen3;
        }
        if ((t1 & 0x80) != 0) {
            if ((t1 & 0x7F) == 2) tailBytes += dlen2;
            else tailBytes += dlen3;
        }
        if ((t2 & 0x80) != 0) {
            if ((t2 & 0x7F) == 2) tailBytes += dlen2;
            else tailBytes += dlen3;
        }
        assertEq(pl.length, headBytes + tailBytes);
        uint256 p0;
        uint256 p1;
        uint256 p2;
        assembly {
            p0 := mload(add(add(pl, 32), 0))
            p1 := mload(add(add(pl, 32), 32))
            p2 := mload(add(add(pl, 32), 64))
        }
        if ((t0 & 0x80) != 0) {
            assertEq(p0 % 32, 0);
            uint256 len = ((t0 & 0x7F) == 2) ? dlen2 : dlen3;
            assertTrue(p0 >= headBytes && p0 + len <= headBytes + tailBytes);
        }
        if ((t1 & 0x80) != 0) {
            assertEq(p1 % 32, 0);
            uint256 len = ((t1 & 0x7F) == 2) ? dlen2 : dlen3;
            assertTrue(p1 >= headBytes && p1 + len <= headBytes + tailBytes);
        }
        if ((t2 & 0x80) != 0) {
            assertEq(p2 % 32, 0);
            uint256 len = ((t2 & 0x7F) == 2) ? dlen2 : dlen3;
            assertTrue(p2 >= headBytes && p2 + len <= headBytes + tailBytes);
        }
    }

    // Property 9b) dynamic array case: head pointer is 32-byte aligned and in-bounds
    function check_pointer_alignment_dynamic_array() public pure {
        bytes[] memory regs = new bytes[](2);
        regs[0] = abi.encode(svm.createBytes32('pa0'));
        regs[1] = abi.encode(svm.createBytes32('pa1'));

        bytes memory bp = abi.encodePacked(Bp.pushArray(), Bp.s(0), Bp.s(1), Bp.end());

        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory pl = TestUtils.stripLength(out);

        uint256 headBytes = 32; // single dynamic arg -> one head word
        uint256 p0;
        assembly {
            p0 := mload(add(add(pl, 32), 0))
        }

        assertEq(p0 % 32, 0);
        assertTrue(p0 >= headBytes && p0 < pl.length);

        uint256 n;
        assembly {
            n := mload(add(add(pl, 32), p0))
        }
        uint256 tailBytes = 32 + 32 * n; // length + n elements (uint256 each)
        assertEq(pl.length, headBytes + tailBytes);
        assertTrue(p0 + tailBytes <= pl.length);
    }

    // Property 9c) nested tuple case: head pointer(s) are 32-byte aligned and inside buffer
    function check_pointer_alignment_nested_tuple() public pure {
        bytes[] memory regs = new bytes[](3);
        regs[0] = abi.encode(svm.createBytes32('pn0'));
        regs[1] = abi.encode(svm.createBytes32('pn1'));
        bytes memory d = svm.createBytes(48, 'pnd');
        regs.setDynamic(2, abi.encode(d));

        // Blueprint for (uint256, (uint256, bytes))
        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.pushTuple(), Bp.s(1), Bp.d(2), Bp.end());

        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory pl = TestUtils.stripLength(out);

        uint256 headBytes = 64;
        uint256 p1;
        assembly {
            p1 := mload(add(add(pl, 32), 32))
        }
        assertEq(p1 % 32, 0);
        assertTrue(p1 >= headBytes && p1 < pl.length);
    }

    // Property 10) generative blueprint: encodeFromBlueprint payload = selector || encodeData payload
    function check_generative_encoder_invariants() public view {
        bytes[] memory regs = new bytes[](4);
        regs[0] = abi.encode(svm.createBytes32('gs0'));
        regs[1] = abi.encode(svm.createBytes32('gs1'));
        bytes memory d2 = svm.createBytes(32, 'gd2');
        bytes memory d3 = svm.createBytes(64, 'gd3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));
        bytes memory bp = _gen_blueprint();
        bytes memory outData;
        bool ok1;

        try this.encode_data_wrapper(bp, regs) returns (bytes memory r1) {
            outData = r1;
            ok1 = true;
        } catch {
            ok1 = false;
        }
        bytes4 sel = bytes4(svm.createBytes32('gsel'));
        bytes memory outSel;
        bool ok2;
        try this.encode_from_blueprint_wrapper(sel, bp, regs) returns (bytes memory r2) {
            outSel = r2;
            ok2 = true;
        } catch {
            ok2 = false;
        }

        assertEq(ok1, ok2);
        if (ok1 && ok2) {
            bytes memory pl1 = TestUtils.stripLength(outData);
            bytes memory pl2 = TestUtils.stripLength(outSel);
            bytes memory expected = bytes.concat(sel, pl1);
            assertEq(pl2, expected);
        }
    }

    // Property 11) encodeData reverts with UnclosedContainer if containers are unbalanced
    function check_unclosed_container_reverts() external {
        bytes[] memory regs = new bytes[](0);
        uint8 opener = uint8(svm.createUint(8, 'opener'));
        vm.assume(
            opener == VmConstants.START_TUPLE_STATIC || opener == VmConstants.START_TUPLE_DYNAMIC
                || opener == VmConstants.START_TUPLE_DYNAMIC || opener == VmConstants.START_TUPLE_STATIC
        );
        bytes memory bp = new bytes(1);
        bp[0] = bytes1(opener);

        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), BlueprintEncoder.UnclosedContainer.selector, 'selector');
    }

    // Property 12) encodeData reverts with StackOverflow if blueprint nesting exceeds MAX_STACK_DEPTH
    function check_stack_overflow_reverts() external {
        bytes[] memory regs = new bytes[](0);
        // MAX_STACK_DEPTH = 12, so craft 13 nested openers
        bytes memory bp = new bytes(13);
        for (uint256 i; i < 13; i++) {
            bp[i] = bytes1(VmConstants.START_TUPLE_STATIC);
        }

        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), BlueprintEncoder.StackOverflow.selector, 'selector');
    }

    // Property 13) encodeData with an empty blueprint returns an empty bytes array
    function check_empty_blueprint_returns_empty() external pure {
        bytes[] memory regs = new bytes[](0);
        bytes memory bp = new bytes(0);
        bytes memory out = BlueprintEncoder.encodeData(bp, regs);
        bytes memory expected = hex'0000000000000000000000000000000000000000000000000000000000000000';
        assertEq(out, expected, 'empty');
    }

    // Property 14a) referencing a static register index >= registers.length reverts (MissingRegister semantics)
    function check_missing_register_static_reverts() external {
        bytes[] memory regs = new bytes[](1);
        regs[0] = abi.encode(uint256(123));
        bytes memory bp = abi.encodePacked(Bp.s(1));
        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), RegisterFile.RegisterIndexOOB.selector, 'selector');
    }

    // Property 14b) referencing a dynamic register index >= registers.length reverts (MissingRegister semantics)
    function check_missing_register_dynamic_reverts() external {
        bytes[] memory regs = new bytes[](1);
        regs[0] = abi.encode(uint256(456));

        bytes memory bp = abi.encodePacked(Bp.d(1));

        bytes memory cd = abi.encodeWithSelector(this.encode_data_wrapper.selector, bp, regs);
        (bool ok, bytes memory ret) = address(this).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), RegisterFile.RegisterIndexOOB.selector, 'selector');
    }

    // Property 15) VM ABI_ENCODE(bp) output equals BlueprintEncoder.encodeData(bp, regs)
    function check_vm_abi_encode_equals_encoder() external {
        bytes[] memory regs = new bytes[](5);
        regs[0] = abi.encode(svm.createBytes32('vm0'));
        regs[1] = abi.encode(svm.createBytes32('vm1'));
        bytes memory d2 = svm.createBytes(32, 'vmd2');
        bytes memory d3 = svm.createBytes(64, 'vmd3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));

        bytes memory bp = _gen_blueprint();
        bytes memory expected = BlueprintEncoder.encodeData(bp, regs);
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(4, bp);
        VirtualMachine vmc = new VirtualMachine();
        VMState memory s;
        s.registers = regs;
        (VMState memory fin,) = vmc.runWithState(cmds, s);

        assertEq(fin.registers[4], expected, 'abi_encode mismatch');
    }

    // Property 16) VM CALLDATA_BUILD(sel, bp) output equals bytes.concat(sel, ABI_ENCODE(bp))
    function check_vm_calldata_build_equals_concat() external {
        bytes[] memory regs = new bytes[](5);
        regs[0] = abi.encode(svm.createBytes32('cdb0'));
        regs[1] = abi.encode(svm.createBytes32('cdb1'));
        bytes memory d2 = svm.createBytes(32, 'cdb2');
        bytes memory d3 = svm.createBytes(64, 'cdb3');
        regs.setDynamic(2, abi.encode(d2));
        regs.setDynamic(3, abi.encode(d3));

        bytes memory bp = _gen_blueprint();
        bytes4 sel = bytes4(svm.createBytes32('sel-cdb'));

        bytes memory body = BlueprintEncoder.encodeData(bp, regs);
        bytes memory expected = bytes.concat(sel, TestUtils.stripLength(body));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(sel, 4, bp);
        VirtualMachine vmc = new VirtualMachine();
        VMState memory s;
        s.registers = regs;
        (VMState memory fin,) = vmc.runWithState(cmds, s);

        assertEq(TestUtils.stripLength(fin.registers[4]), expected, 'cdb != sel||abi');
    }

    //// === HARDCODED COMPLEX ==== ///
    /// Static Array
    /// Static Array with Dynamic elements
    /// Dynamic array with static elements
    /// Dynamic array with dynamic elements
    /// Tuple with Static Elements
    /// Tuple with Dynamic Elements

    // function check_hardcoded_complex_double

    // Helper: expose encodeFromBlueprint via external wrapper for try/catch
    function encode_from_blueprint_wrapper(
        bytes4 sel,
        bytes memory bp,
        bytes[] memory regs
    )
        external
        pure
        returns (bytes memory)
    {
        return BlueprintEncoder.encodeFromBlueprint(sel, bp, regs);
    }

    // Helper: generate a valid random blueprint shape for property 10
    function _gen_blueprint() internal pure returns (bytes memory bp) {
        uint8 shape = uint8(svm.createUint(8, 'shape'));
        shape &= 3;
        if (shape == 0) {
            return abi.encodePacked(Bp.pushArrayStatic(), Bp.s(0), Bp.s(1), Bp.end());
        } else if (shape == 1) {
            return abi.encodePacked(Bp.pushArray(), Bp.s(0), Bp.s(1), Bp.end());
        } else if (shape == 2) {
            return abi.encodePacked(Bp.s(0), Bp.pushTuple(), Bp.s(1), Bp.d(2), Bp.end());
        } else {
            bp = new bytes(3);
            uint8 t0 = uint8(svm.createUint(8, 't0g'));
            uint8 t1 = uint8(svm.createUint(8, 't1g'));
            uint8 t2 = uint8(svm.createUint(8, 't2g'));
            bool ok0 = (t0 == 0 || t0 == 1 || t0 == 0x82 || t0 == 0x83);
            bool ok1 = (t1 == 0 || t1 == 1 || t1 == 0x82 || t1 == 0x83);
            bool ok2 = (t2 == 0 || t2 == 1 || t2 == 0x82 || t2 == 0x83);
            require(ok0 && ok1 && ok2);
            bp[0] = bytes1(t0);
            bp[1] = bytes1(t1);
            bp[2] = bytes1(t2);
            return bp;
        }
    }

    // Helper: expose encodeData via external wrapper for try/catch
    function encode_data_wrapper(bytes memory bp, bytes[] memory regs) external pure returns (bytes memory) {
        return BlueprintEncoder.encodeData(bp, regs);
    }
}
