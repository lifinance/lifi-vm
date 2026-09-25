// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { RegisterFile } from '../src/RegisterFile.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { Bp } from './lib/Bp.sol';
import { TestUtils } from './lib/TestUtils.sol';

contract ExplodeTarget {
    struct StaticPair {
        uint256 amount;
        address recipient;
    }

    struct DynamicPair {
        string first;
        string second;
    }

    function staticPair() external pure returns (StaticPair memory) {
        return StaticPair(123, address(uint160(0xBEEF)));
    }

    function dynamicPair() external pure returns (DynamicPair memory) {
        return DynamicPair('first', 'second');
    }

    function mixedValues() external pure returns (uint256, string memory, uint256) {
        return (7, 'middle', 9);
    }
}

contract ExplodeTest is SpecTestBase {
    using RegisterFile for bytes[];

    ExplodeTarget private target;

    function setUp() public override {
        super.setUp();
        target = new ExplodeTarget();
        vm.label(address(target), 'ExplodeTarget');
    }

    function test_Explode_StaticSingleStructReturn_AllowsReEncoding() public withSnapshot {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(ExplodeTarget.staticPair.selector));

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.call(address(target), CallType.STATICCALL, 1, 0, 0);
        cmds[1] = VmCmd.explode(1, _dests(2, 3));
        cmds[2] = VmCmd.abiEnc(4, abi.encodePacked(Bp.pushTupleStatic(), Bp.s(2), Bp.s(3), Bp.end()));
        cmds[3] = VmCmd.ret(4);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        assertEq(s1.registers[2], abi.encode(uint256(123)));
        assertEq(s1.registers[3], abi.encode(address(uint160(0xBEEF))));

        ExplodeTarget.StaticPair memory expected = ExplodeTarget.StaticPair(123, address(uint160(0xBEEF)));
        Asserts.assertEncodingMatches(out, abi.encode(expected));
    }

    function test_Explode_DynamicSingleStructReturn_AllowsReEncoding() public withSnapshot {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(ExplodeTarget.dynamicPair.selector));

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.call(address(target), CallType.STATICCALL, Regs.withDyn(1), 0, 0);
        // Source byte 0's high bit is a dead flag; the canonical encoding requires a plain index.
        cmds[1] = VmCmd.explode(1, _dests(Regs.withDyn(2), Regs.withDyn(3)));
        cmds[2] = VmCmd.abiEnc(4, abi.encodePacked(Bp.pushTuple(), Bp.d(2), Bp.d(3), Bp.end()));
        cmds[3] = VmCmd.ret(4);

        (VMState memory s1, bytes memory out) = run(cmds, s0);

        bytes[] memory expectedRegs = RegisterFile.initialize(2);
        expectedRegs.setDynamic(0, abi.encode(string('first')));
        expectedRegs.setDynamic(1, abi.encode(string('second')));

        assertEq(s1.registers[2], expectedRegs[0]);
        assertEq(s1.registers[3], expectedRegs[1]);

        ExplodeTarget.DynamicPair memory expected = ExplodeTarget.DynamicPair('first', 'second');
        Asserts.assertEncodingMatches(out, abi.encode(expected));
    }

    function test_Explode_MixedReturn_SlicesDynamicField() public withSnapshot {
        VMState memory s0 = Regs.init(6);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(ExplodeTarget.mixedValues.selector));

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.call(address(target), CallType.STATICCALL, 1, 0, 0);
        cmds[1] = VmCmd.explode(1, _dests(2, Regs.withDyn(3), 4));
        cmds[2] = VmCmd.abiEnc(5, abi.encodePacked(Bp.s(2), Bp.d(3), Bp.s(4)));
        cmds[3] = VmCmd.ret(5);

        (, bytes memory out) = run(cmds, s0);

        Asserts.assertEncodingMatches(out, abi.encode(uint256(7), string('middle'), uint256(9)));
    }

    function test_Explode_InvalidDynamicOffset_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    /* ───────────── EDGE CASES: SOURCE SHAPE VALIDATION ───────────── */

    function test_Explode_NonWordAlignedSource_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = new bytes(33);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1));

        vm.expectRevert(VmErrors.InvalidRegisterLength.selector);
        run(cmds, s0);
    }

    function test_Explode_SourceShorterThanHead_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        // Aligned to 32 but only 2 words (64 bytes) while destCount = 3.
        s0.registers[0] = abi.encodePacked(uint256(0), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1, 2, 3));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    /* ───────────── EDGE CASES: DYNAMIC OFFSET VALIDATION ───────────── */

    function test_Explode_DynamicOffsetNotWordAligned_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // headLen = 32. Source has 64 bytes; head[0] = 33 (in head bounds but not aligned).
        s0.registers[0] = abi.encodePacked(uint256(33), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    function test_Explode_DynamicOffsetEqualsSourceLength_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        // sourceLen = 64; head[0] = 64 (offset == sourceLen, out of bounds).
        s0.registers[0] = abi.encodePacked(uint256(64), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    function test_Explode_TwoDynamicOffsetsEqual_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Head: (64, 64) — end == start so slice length zero -> revert.
        s0.registers[0] = abi.encodePacked(uint256(64), uint256(64), uint256(0), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1), Regs.withDyn(2)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    function test_Explode_TwoDynamicOffsetsDecreasing_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Head: (96, 64) — end < start so slice length negative -> revert.
        s0.registers[0] = abi.encodePacked(uint256(96), uint256(64), uint256(0), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1), Regs.withDyn(2)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    /* ───────────── EDGE CASES: REGISTER ADDRESSING ───────────── */

    function test_Explode_DestRegisterOutOfBounds_Reverts() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(10));

        vm.expectRevert(RegisterFile.RegisterIndexOOB.selector);
        run(cmds, s0);
    }

    function test_Explode_VoidSourceWithSingleStatic_CopiesZeroWord() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(Regs.voidReg(), _dests(1));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1], abi.encode(uint256(0)));
    }

    function test_Explode_VoidDestination_DoesNotWriteAnyRegister() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        bytes memory original = abi.encode(uint256(0xCAFE));
        s0.registers[0] = original;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.voidReg()));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[0], original);
        assertEq(s1.registers[1].length, 0);
    }

    function test_Explode_DestAliasesSource_UsesOriginalData() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        // Source bytes are intentionally placed in register 1 because dest[0] also targets 1.
        s0.registers[1] = abi.encodePacked(uint256(0xAAAA), uint256(0xBBBB));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(1, _dests(1, 2));

        (VMState memory s1,) = run(cmds, s0);

        // Even though reg[1] was overwritten by the first dest write, the second slice
        // must read from the original source pointer, not the newly written value.
        assertEq(s1.registers[1], abi.encode(uint256(0xAAAA)));
        assertEq(s1.registers[2], abi.encode(uint256(0xBBBB)));
    }

    /* ───────────── HAPPY PATH: SHAPE COVERAGE ───────────── */

    function test_Explode_SingleStaticField_CopiesOneWord() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(0xDEADBEEF));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1], abi.encode(uint256(0xDEADBEEF)));
    }

    function test_Explode_MaxDestinationCount_AllStatic() public withSnapshot {
        uint8 count = 26;
        VMState memory s0 = Regs.init(uint256(count) + 1);

        bytes memory src;
        for (uint256 i = 0; i < count; i++) {
            src = abi.encodePacked(src, uint256(i + 100));
        }
        s0.registers[0] = src;

        uint8[] memory dests = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            dests[i] = uint8(i + 1);
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, dests);

        (VMState memory s1,) = run(cmds, s0);

        for (uint256 i = 0; i < count; i++) {
            assertEq(s1.registers[i + 1], abi.encode(uint256(i + 100)));
        }
    }

    function test_Explode_LastDynamicTail_SpansToSourceEnd() public withSnapshot {
        VMState memory s0 = Regs.init(3);
        bytes32 staticVal = bytes32(uint256(0x123));
        // Head: [static word, dyn offset = 64]; tail = three words at 64..160.
        s0.registers[0] = abi.encodePacked(staticVal, uint256(64), uint256(0x55), uint256(0x66), uint256(0x77));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1, Regs.withDyn(2)));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1], abi.encode(staticVal));
        bytes memory expectedTail = abi.encodePacked(uint256(0x55), uint256(0x66), uint256(0x77));
        assertEq(s1.registers[2], expectedTail);
    }

    function test_Explode_DynStaticDynPattern_SlicesCorrectly() public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encodePacked(
            uint256(96), // head[0] dyn offset
            uint256(0xABCD), // head[1] static value
            uint256(160), // head[2] dyn offset
            uint256(0x11), // tail0 word A
            uint256(0x22), // tail0 word B
            uint256(0x33) // tail1
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1), 2, Regs.withDyn(3)));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1], abi.encodePacked(uint256(0x11), uint256(0x22)));
        assertEq(s1.registers[2], abi.encode(uint256(0xABCD)));
        assertEq(s1.registers[3], abi.encode(uint256(0x33)));
    }

    /* ───────────── DIFFERENTIAL: ABI ENCODING ROUNDTRIP ───────────── */

    function testFuzz_Explode_StaticTriple_MatchesAbiEncode(uint256 a, uint256 b, uint256 c) public withSnapshot {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(a, b, c);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1, 2, 3));

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1], abi.encode(a));
        assertEq(s1.registers[2], abi.encode(b));
        assertEq(s1.registers[3], abi.encode(c));
    }

    /* ───────────── EDGE CASES: SOURCE & OFFSET BOUNDS ───────────── */

    function test_Explode_EmptySource_Reverts() public withSnapshot {
        // Length 0 is a multiple of 32, so InvalidRegisterLength does not fire; the
        // sourceLen < destCount*32 head check must revert OutOfBounds instead.
        VMState memory s0 = Regs.init(2);
        // registers[0] is already zero-length from Regs.init.

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    function test_Explode_DynamicOffsetInHeadMidRegion_Reverts() public withSnapshot {
        // destCount = 2 -> headLen = 64. head[0] = 32 = (destCount-1)*32 points inside the
        // head region (< headLen) and must revert OutOfBounds.
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encodePacked(uint256(32), uint256(0), uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1), 2));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    function test_Explode_DynamicOffsetMaxUint_Reverts() public withSnapshot {
        // A colossal offset must be rejected by the bounds check with no overflow / OOB read.
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encodePacked(type(uint256).max, uint256(0));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        vm.expectRevert(VmErrors.OutOfBounds.selector);
        run(cmds, s0);
    }

    /* ───────────── EDGE CASES: ALIASING & VOID DESTINATIONS ───────────── */

    function test_Explode_DynamicDestAliasesSource_UsesOriginalData() public withSnapshot {
        // dest[0] is dynamic and aliases the source register (reg 1). Writing it must not
        // corrupt the source seen by the later static dest[1], because the source is read
        // once up front.
        VMState memory s0 = Regs.init(3);
        // head: [dyn offset = 64, static value 0xBBBB]; tail word at 64 = 0xCCCC.
        s0.registers[1] = abi.encodePacked(uint256(64), uint256(0xBBBB), uint256(0xCCCC));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(1, _dests(Regs.withDyn(1), 2));

        (VMState memory s1,) = run(cmds, s0);

        // dest[0] (aliasing source) receives the dynamic tail derived from ORIGINAL source.
        assertEq(s1.registers[1], abi.encode(uint256(0xCCCC)));
        // dest[1] reads the ORIGINAL head word 1, proving the reg-1 write did not clobber source.
        assertEq(s1.registers[2], abi.encode(uint256(0xBBBB)));
    }

    function test_Explode_DynamicDestVoid_IsNoOp() public withSnapshot {
        // A dynamic destination pointing at the void register writes nothing and does not revert.
        VMState memory s0 = Regs.init(2);
        // head: [dyn offset = 32]; tail word at 32 = 0x9999.
        s0.registers[0] = abi.encodePacked(uint256(32), uint256(0x9999));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(Regs.voidReg())));

        (VMState memory s1,) = run(cmds, s0);

        // No real register received the slice; source register is untouched.
        assertEq(s1.registers[1].length, 0);
        assertEq(s1.registers[0], abi.encodePacked(uint256(32), uint256(0x9999)));
    }

    /* ───────────── HAPPY PATH: MAX DESTINATION COUNT ───────────── */

    function test_Explode_MaxDestinationCount_AllDynamic() public withSnapshot {
        // 26 dynamic destinations: the deepest path and the worst case for the O(n^2) forward
        // rescan in _resolveDynamicEnd. Head words are strictly increasing word-aligned offsets
        // starting at 26*32; each dynamic tail is exactly one word, the last running to source end.
        uint8 count = 26;
        uint256 headLen = uint256(count) * 32;

        bytes memory src;
        for (uint256 i = 0; i < count; i++) {
            src = abi.encodePacked(src, headLen + i * 32); // strictly increasing offsets
        }
        for (uint256 i = 0; i < count; i++) {
            src = abi.encodePacked(src, uint256(0xD00 + i)); // tail words
        }

        VMState memory s0 = Regs.init(uint256(count) + 1);
        s0.registers[0] = src;

        uint8[] memory dests = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            dests[i] = Regs.withDyn(uint8(i + 1));
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, dests);

        (VMState memory s1,) = run(cmds, s0);

        for (uint256 i = 0; i < count; i++) {
            assertEq(s1.registers[i + 1], abi.encode(uint256(0xD00 + i)));
        }
    }

    function test_Explode_MaxDestinationCount_AlternatingMix_StaticDoesNotTerminateTail() public withSnapshot {
        // 26 destinations: every 3rd is dynamic, the rest static. Each dynamic tail must span the
        // two intervening static destinations up to the NEXT dynamic destination's offset, proving
        // static destinations do not terminate a dynamic tail.
        uint8 count = 26;
        uint256 headLen = uint256(count) * 32;

        bytes memory src;
        for (uint256 i = 0; i < count; i++) {
            if (i % 3 == 0) {
                src = abi.encodePacked(src, headLen + (i / 3) * 96); // dynamic offset, spaced 3 words
            } else {
                src = abi.encodePacked(src, uint256(0x7000 + i)); // static value read directly
            }
        }
        // 27 tail words (9 dynamic tails * 3 words each): global word index 26..52.
        for (uint256 t = 0; t < 27; t++) {
            src = abi.encodePacked(src, uint256(0xF00 + 26 + t));
        }

        VMState memory s0 = Regs.init(uint256(count) + 1);
        s0.registers[0] = src;

        uint8[] memory dests = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            dests[i] = i % 3 == 0 ? Regs.withDyn(uint8(i + 1)) : uint8(i + 1);
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, dests);

        (VMState memory s1,) = run(cmds, s0);

        for (uint256 i = 0; i < count; i++) {
            if (i % 3 == 0) {
                uint256 k = i / 3;
                bytes memory expectedTail = abi.encodePacked(
                    uint256(0xF00 + 26 + 3 * k), uint256(0xF00 + 27 + 3 * k), uint256(0xF00 + 28 + 3 * k)
                );
                assertEq(s1.registers[i + 1], expectedTail);
            } else {
                assertEq(s1.registers[i + 1], abi.encode(uint256(0x7000 + i)));
            }
        }
    }

    function _dests(uint8 a) private pure returns (uint8[] memory destRegs) {
        destRegs = new uint8[](1);
        destRegs[0] = a;
    }

    function _dests(uint8 a, uint8 b) private pure returns (uint8[] memory destRegs) {
        destRegs = new uint8[](2);
        destRegs[0] = a;
        destRegs[1] = b;
    }

    function _dests(uint8 a, uint8 b, uint8 c) private pure returns (uint8[] memory destRegs) {
        destRegs = new uint8[](3);
        destRegs[0] = a;
        destRegs[1] = b;
        destRegs[2] = c;
    }
}
