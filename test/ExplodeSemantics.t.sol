// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Bp } from './lib/Bp.sol';
import { TestUtils } from './lib/TestUtils.sol';

/// @dev Returns a `(bytes, bytes)` tuple as raw return data, so each case controls every head
///      offset. Used to drive EXPLODE with a byte-identical command word but differing callee data.
contract TupleReturner {
    uint256 constant A = 0xAAAA;
    uint256 constant HIDDEN = 0xBADBAD;
    uint256 constant B = 0xBBBB;

    /// @dev `[0x20][tuple block]`, matching what solc emits for `returns (Struct memory)` with
    ///      dynamic members. The VM's dynamic-register store strips the leading `0x20`.
    function canonical() external pure returns (bytes memory) {
        _rawReturn(
            abi.encode(
                uint256(0x20),
                uint256(64), // off_a
                uint256(128), // off_b
                uint256(32),
                A, // tail a [64,128)
                uint256(32),
                B // tail b [128,192)
            )
        );
    }

    /// @dev off_b pushed one field outward, so field a's slice extends past its declared length.
    function surplus() external pure returns (bytes memory) {
        _rawReturn(
            abi.encode(
                uint256(0x20),
                uint256(64), // off_a — unchanged
                uint256(192), // off_b — pushed outward
                uint256(32),
                A, // [64,128)  field a, length word still 32
                uint256(32),
                HIDDEN, // [128,192) surplus bytes inside field a's slice
                uint256(32),
                B // [192,256) field b
            )
        );
    }

    /// @dev off_b pulled inward, so field a's slice is only its length word.
    function deficit() external pure returns (bytes memory) {
        _rawReturn(
            abi.encode(
                uint256(0x20),
                uint256(64), // off_a
                uint256(96), // off_b — one word after off_a
                uint256(32), // [64,96)  field a: length word, no payload
                uint256(32),
                B // [96,160) field b
            )
        );
    }

    function _rawReturn(bytes memory blob) private pure {
        assembly {
            return(add(blob, 0x20), mload(blob))
        }
    }
}

/// @notice Locks in the behaviours documented under "What EXPLODE does not validate" in
///         `docs/isa.md`, plus the destination write-order rule from the EXPLODE Instruction
///         section. Each of these is accepted silently rather than reverting, so without a test
///         a future tightening — or loosening — of `ExplodeLib` would change documented ISA
///         semantics undetected.
contract ExplodeSemanticsTest is SpecTestBase {
    TupleReturner private returner;

    function setUp() public override {
        super.setUp();
        returner = new TupleReturner();
    }

    function _dests(uint8 a) private pure returns (uint8[] memory d) {
        d = new uint8[](1);
        d[0] = a;
    }

    function _dests(uint8 a, uint8 b) private pure returns (uint8[] memory d) {
        d = new uint8[](2);
        d[0] = a;
        d[1] = b;
    }

    /* ─────────── destination write order ─────────── */

    /// ISA: "Writes happen in destination order, so if two destinations name the same register the
    /// last write wins."
    function test_Explode_DuplicateDestinations_LastWriteWins() public {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(0xAA), uint256(0xBB));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1, 1));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(s1.registers[1], abi.encode(uint256(0xBB)), 'second destination overwrote the first');
    }

    /* ─────────── shape is checked, type agreement is not ─────────── */

    /// ISA: a dynamic flag on a genuinely static field reinterprets the value as an offset; a value
    /// that is word-aligned and inside `[DestCount * 32, sourceLen)` is accepted, not rejected.
    function test_Explode_DynamicFlagOnStaticField_ValueAcceptedAsOffset() public {
        VMState memory s0 = Regs.init(2);
        // head[0] is a real value of 64 — e.g. an amount — and sourceLen is 128.
        s0.registers[0] = abi.encodePacked(uint256(64), uint256(7), uint256(0xAAAA), uint256(0xBBBB));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(
            s1.registers[1],
            abi.encodePacked(uint256(0xAAAA), uint256(0xBBBB)),
            'the amount 64 was consumed as an offset, no revert'
        );
    }

    /// ISA: a static flag on a genuinely dynamic field stores the raw offset word, not the field.
    function test_Explode_StaticFlagOnDynamicField_StoresRawOffsetWord() public {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encodePacked(uint256(32), uint256(1), bytes32(hex'ff'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(s1.registers[1], abi.encode(uint256(32)), 'register holds the offset word');
    }

    /* ─────────── DestCount is a claim, not a check ─────────── */

    /// ISA: a `Dest Count` below the source's real head-word count silently truncates.
    function test_Explode_DestCountBelowHeadWordCount_SilentlyTruncates() public {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(1), uint256(2), uint256(3));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(1, 2));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(s1.registers[1], abi.encode(uint256(1)));
        assertEq(s1.registers[2], abi.encode(uint256(2)));
        // The third head word is unreachable and no revert is raised.
    }

    /* ─────────── bytes belonging to no destination are dropped ─────────── */

    /// ISA: the first dynamic offset may exceed the head region; the intervening bytes are dropped.
    function test_Explode_GapBeforeFirstTail_SilentlyDiscardsBytes() public {
        VMState memory s0 = Regs.init(2);
        // headLen = 32, sourceLen = 128, head[0] = 64, so bytes [32,64) belong to no destination.
        s0.registers[0] = abi.encodePacked(uint256(64), uint256(0xDEAD), uint256(0x1111), uint256(0x2222));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1)));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(s1.registers[1], abi.encodePacked(uint256(0x1111), uint256(0x2222)), 'tail read from offset 64');
        // 0xDEAD at [32,64) was discarded without error.
    }

    /// ISA: with a dynamic destination present, only the bytes before the first dynamic offset are
    /// dropped. Every interval from one dynamic offset to the next is copied in full into the earlier
    /// destination, even when that field's own length word describes a shorter payload.
    function test_Explode_InterTailBytes_CopiedIntoEarlierDestination() public {
        VMState memory s0 = Regs.init(3);
        // headLen = 64. Tail A at [64,160) declares one payload word but is followed by 0xBADBAD
        // before tail B's offset at 160. Tail B at [160,224) declares one payload word.
        s0.registers[0] = abi.encodePacked(
            uint256(64),
            uint256(160), // head: offsets of A and B
            uint256(32),
            uint256(0xAAAA),
            uint256(0xBADBAD), // tail A: len=32, payload, surplus
            uint256(32),
            uint256(0xBBBB) // tail B: len=32, payload
        );

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, _dests(Regs.withDyn(1), Regs.withDyn(2)));

        (VMState memory s1,) = run(cmds, s0);
        assertEq(
            s1.registers[1],
            abi.encodePacked(uint256(32), uint256(0xAAAA), uint256(0xBADBAD)),
            'A carries the whole [64,160) interval, surplus included'
        );
        assertEq(s1.registers[2], abi.encodePacked(uint256(32), uint256(0xBBBB)), 'B starts at its own offset');
    }

    /* ─────────── a dynamic field's length prefix is not validated ─────────── */

    /// The command word below is byte-identical across all three cases; only the callee's return
    /// data differs. This is the shared program: CALL, EXPLODE into two dynamic destinations,
    /// re-encode both as a `(bytes, bytes)` tuple, return it.
    function _runProgram(bytes4 sel) private returns (VMState memory s1, bytes memory out) {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(sel));

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.call(address(returner), CallType.STATICCALL, Regs.withDyn(1), 0, 0);
        cmds[1] = VmCmd.explode(1, _dests(Regs.withDyn(2), Regs.withDyn(3)));
        cmds[2] = VmCmd.abiEnc(4, abi.encodePacked(Bp.pushTuple(), Bp.d(2), Bp.d(3), Bp.end()));
        cmds[3] = VmCmd.ret(4);

        (s1, out) = run(cmds, s0);
    }

    function _declaredLen(bytes memory blob) private pure returns (uint256 n) {
        assembly {
            n := mload(add(blob, 0x20))
        }
    }

    function _word(bytes memory blob, uint256 i) private pure returns (uint256 w) {
        assembly {
            w := mload(add(add(blob, 0x20), mul(i, 32)))
        }
    }

    /// Baseline: with canonical callee data the register's byte length and its declared payload
    /// length agree. The two cases below are departures from exactly this.
    function test_Explode_CanonicalCallee_RegisterLengthMatchesDeclaredLength() public {
        (VMState memory s1,) = _runProgram(TupleReturner.canonical.selector);

        assertEq(s1.registers[2].length, 64, 'length word plus one payload word');
        assertEq(_declaredLen(s1.registers[2]), 32, 'declares one payload word');
        assertEq(s1.registers[2].length, _declaredLen(s1.registers[2]) + 32, 'self-consistent');
    }

    /// ISA: pushing the next dynamic offset outward yields a register holding more bytes than its
    /// length word declares, and the surplus survives re-encoding into ABI dead space.
    function test_Explode_SurplusSlice_RegisterCarriesMoreThanItDeclares() public {
        (VMState memory s1, bytes memory out) = _runProgram(TupleReturner.surplus.selector);

        assertEq(_declaredLen(s1.registers[2]), 32, 'field a still declares one word');
        assertEq(s1.registers[2].length, 128, 'but the register carries four');

        bytes memory reg2 = s1.registers[2];
        uint256 surplus;
        assembly {
            surplus := mload(add(reg2, 0x80)) // 0x20 header + 96 bytes
        }
        assertEq(surplus, 0xBADBAD, 'callee-chosen word sits past the declared payload');

        // Re-encoding copies the register verbatim and derives the next field offset from its
        // actual byte length, so the surplus reaches the output as ABI dead space.
        (, bytes memory canonicalOut) = _runProgram(TupleReturner.canonical.selector);
        assertEq(out.length, canonicalOut.length + 64, 'output grew by the surplus');
        assertEq(_word(out, 7), 0xBADBAD, 'surplus word is present in the returned payload');

        // The logical fields still decode unchanged: this is a canonicality break, not corruption.
        assertEq(_word(out, 5), 0xAAAA, 'field a payload intact');
        assertEq(_word(out, 9), 0xBBBB, 'field b payload intact');
    }

    /// ISA: pulling the next dynamic offset inward yields a register declaring more payload than it
    /// carries, so re-encoded fields overlap.
    function test_Explode_DeficitSlice_RegisterDeclaresMoreThanItCarries() public {
        (VMState memory s1, bytes memory out) = _runProgram(TupleReturner.deficit.selector);

        assertEq(s1.registers[2].length, 32, 'register is its length word alone');
        assertEq(_declaredLen(s1.registers[2]), 32, 'yet declares a payload word it does not carry');

        // Payload layout: [0x20][off_a=0x40][off_b=0x60][len_a=0x20][len_b=0x20][B].
        // Field a's declared payload begins where field b's header sits, so the two overlap.
        assertEq(_word(out, 2), 0x40, 'off_a');
        assertEq(_word(out, 3), 0x60, 'off_b is only one word past field a header');
        assertEq(_word(out, 4), 0x20, 'field a declares one payload word');
        assertEq(_word(out, 5), 0x20, "field a's payload word is field b's length word");
        assertEq(_word(out, 6), 0xBBBB, 'field b payload');
    }
}
