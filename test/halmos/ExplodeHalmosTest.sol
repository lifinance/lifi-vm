// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { Test } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { CommandPacking } from 'src/CommandPacking.sol';
import { Explode, OP, VMCommand, VMState } from 'src/DataModel.sol';
import { VmConstants } from 'src/VmConstants.sol';
import { VmErrors } from 'src/VmErrors.sol';
import { VirtualMachine } from 'src/VirtualMachine.sol';

// halmos --contract ExplodeHalmosTest --loop 100
contract ExplodeHalmosTest is Test, SymTest {
    VirtualMachine private machine = new VirtualMachine();

    /* ───────────────── Property E-1: pack/unpack roundtrip ───────────────── */

    function check_explode_roundtrip_three(uint8 sourceReg) external pure {
        // Byte 0's high bit is a reserved dead flag; the canonical encoding requires it clear.
        vm.assume(sourceReg < 0x80);
        uint8 destCount = 3;
        uint8[] memory destRegs = new uint8[](destCount);
        destRegs[0] = uint8(svm.createUint(8, 'd0'));
        destRegs[1] = uint8(svm.createUint(8, 'd1'));
        destRegs[2] = uint8(svm.createUint(8, 'd2'));

        bytes32 packed = CommandPacking.packExplode(sourceReg, destCount, destRegs);
        Explode memory unpacked = CommandPacking.unpackExplode(packed);

        assertEq(unpacked.sourceReg, sourceReg, 'sourceReg');
        assertEq(unpacked.destCount, destCount, 'destCount');
        uint256 shiftBase = CommandPacking.EXPLODE_DESTS_SHIFT_BASE;
        assertEq(uint8(unpacked.packedDests >> shiftBase), destRegs[0], 'd0');
        assertEq(uint8(unpacked.packedDests >> (shiftBase - 8)), destRegs[1], 'd1');
        assertEq(uint8(unpacked.packedDests >> (shiftBase - 16)), destRegs[2], 'd2');
    }

    /* ───────────────── Property E-2: destCount = 0 rejected ───────────────── */

    function check_explode_destCount_zero_reverts(uint8 sourceReg) external {
        uint8[] memory destRegs = new uint8[](1);
        destRegs[0] = 1;
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeWithSelector(this._packWrapper.selector, sourceReg, uint8(0), destRegs));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.DestinationCountOutOfBounds.selector, 'DestinationCountOutOfBounds');
    }

    /* ───────────────── Property E-3: destCount > 26 rejected ───────────────── */

    function check_explode_destCount_too_large_reverts(uint8 sourceReg) external {
        uint8[] memory destRegs = new uint8[](27);
        for (uint256 i = 0; i < 27; i++) {
            destRegs[i] = uint8(i);
        }
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeWithSelector(this._packWrapper.selector, sourceReg, uint8(27), destRegs));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.DestinationCountOutOfBounds.selector, 'DestinationCountOutOfBounds');
    }

    // External wrapper so `try/call` can capture the revert from a library call.
    function _packWrapper(uint8 sourceReg, uint8 destCount, uint8[] memory destRegs) external pure returns (bytes32) {
        return CommandPacking.packExplode(sourceReg, destCount, destRegs);
    }

    /* ───────────────── Property E-4: unaligned source -> InvalidRegisterLength ───────────────── */

    function check_explode_unaligned_source_reverts() external {
        bytes[] memory regs = new bytes[](2);
        regs[0] = svm.createBytes(33, 'src33');

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;

        (bool ok, bytes memory ret) = _callExplode(regs, 0, dests);
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.InvalidRegisterLength.selector, 'InvalidRegisterLength');
    }

    /* ───────────────── Property E-5: source shorter than head -> OutOfBounds ───────────────── */

    function check_explode_source_too_short_reverts() external {
        bytes[] memory regs = new bytes[](4);
        // 64 bytes is aligned to 32 but < 3 * 32 head bytes.
        regs[0] = svm.createBytes(64, 'src64');

        uint8[] memory dests = new uint8[](3);
        dests[0] = 1;
        dests[1] = 2;
        dests[2] = 3;

        (bool ok, bytes memory ret) = _callExplode(regs, 0, dests);
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.OutOfBounds.selector, 'OutOfBounds');
    }

    /* ───────────────── Property E-6: all-static = direct word extraction ───────────────── */

    function check_explode_all_static_extracts_each_word() external {
        bytes32 w0 = svm.createBytes32('w0');
        bytes32 w1 = svm.createBytes32('w1');
        bytes32 w2 = svm.createBytes32('w2');

        bytes[] memory regs = new bytes[](4);
        regs[0] = abi.encodePacked(w0, w1, w2);

        uint8[] memory dests = new uint8[](3);
        dests[0] = 1;
        dests[1] = 2;
        dests[2] = 3;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({ op: OP.EXPLODE, data: CommandPacking.packExplode(0, 3, dests) });

        VMState memory s0 = VMState({ registers: regs });
        (VMState memory s1,) = machine.runWithState(cmds, s0);

        assertEq(s1.registers[1], abi.encode(w0), 'reg1 = w0');
        assertEq(s1.registers[2], abi.encode(w1), 'reg2 = w1');
        assertEq(s1.registers[3], abi.encode(w2), 'reg3 = w2');
    }

    /* ───────────────── Property E-7: single trailing dynamic gets full tail ───────────────── */

    function check_explode_single_dynamic_tail_equals_remainder() external {
        // Build: head = [staticWord, dynOffset = 64], tail = 2 symbolic words.
        bytes32 staticWord = svm.createBytes32('static');
        bytes32 t0 = svm.createBytes32('t0');
        bytes32 t1 = svm.createBytes32('t1');

        bytes[] memory regs = new bytes[](3);
        regs[0] = abi.encodePacked(staticWord, uint256(64), t0, t1);

        uint8[] memory dests = new uint8[](2);
        dests[0] = 1;
        dests[1] = VmConstants.DYN_MASK | 2;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({ op: OP.EXPLODE, data: CommandPacking.packExplode(0, 2, dests) });

        VMState memory s0 = VMState({ registers: regs });
        (VMState memory s1,) = machine.runWithState(cmds, s0);

        assertEq(s1.registers[1], abi.encode(staticWord), 'static word preserved');
        bytes memory expectedTail = abi.encodePacked(t0, t1);
        assertEq(keccak256(s1.registers[2]), keccak256(expectedTail), 'dynamic tail = source[64:]');
    }

    /* ───────────────── Property E-8: padding bytes 28-31 must be zero ───────────────── */

    function check_explode_nonzero_padding_reverts(bytes32 packed) external {
        // For any packed word whose low 4 bytes (padding) are non-zero, unpackExplode reverts.
        vm.assume(uint32(uint256(packed)) != 0);
        // destCount must be a valid value, otherwise DestinationCountOutOfBounds may fire first.
        uint8 destCount = uint8(uint256(packed >> 240));
        vm.assume(destCount > 0 && destCount <= 26);

        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(this._unpackWrapper.selector, packed));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.NonZeroPadding.selector, 'NonZeroPadding');
    }

    function _unpackWrapper(bytes32 packed) external pure returns (Explode memory) {
        return CommandPacking.unpackExplode(packed);
    }

    /* ───────────────── Property E-9: pack rejects source high bit -> NonZeroPadding ───────────────── */

    function check_explode_pack_source_high_bit_reverts(uint8 sourceReg, uint8 destCount) external {
        // Symbolic sourceReg with the reserved 0x80 bit set; destCount kept in the valid 1..26
        // range (and enough destRegs supplied) so DestinationCountOutOfBounds cannot fire first.
        // This is the pack-side guard that keeps packExplode/unpackExplode mutually inverse.
        vm.assume(sourceReg & VmConstants.DYN_MASK != 0);
        vm.assume(destCount >= 1 && destCount <= 26);
        uint8[] memory destRegs = new uint8[](26);

        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeWithSelector(this._packWrapper.selector, sourceReg, destCount, destRegs));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.NonZeroPadding.selector, 'NonZeroPadding');
    }

    /* ───────────────── Property E-10: unpack rejects source high bit alone -> NonZeroPadding ───────────────── */

    function check_explode_unpack_source_high_bit_reverts(uint8 sourceReg, uint8 destCount) external {
        // Symbolic word whose byte-0 high bit is set but whose destination region and padding are
        // otherwise well formed: only bytes 0 (sourceReg) and 1 (destCount) are populated, so every
        // reserved bit below the last destination byte is zero. This proves the source high bit
        // alone is sufficient to reject, distinguishing it from the bytes 28..31 padding property.
        vm.assume(sourceReg & VmConstants.DYN_MASK != 0);
        vm.assume(destCount >= 1 && destCount <= 26);
        bytes32 packed = bytes32((uint256(sourceReg) << 248) | (uint256(destCount) << 240));

        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(this._unpackWrapper.selector, packed));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.NonZeroPadding.selector, 'NonZeroPadding');
    }

    /* ───────────────── Property E-11: unpack rejects nonzero unused dest slots -> NonZeroPadding ───────────────── */

    function check_explode_unused_dest_slot_reverts(uint8 destCount, bytes32 unused) external {
        // destCount in 1..25 guarantees at least one unused destination byte in [2+destCount .. 27].
        vm.assume(destCount >= 1 && destCount <= 25);
        // Destination i occupies the byte whose low bit sits at EXPLODE_DESTS_SHIFT_BASE - i*8, so
        // the last used destination's low bit is at `lastDestShift`.
        uint256 lastDestShift = CommandPacking.EXPLODE_DESTS_SHIFT_BASE - (uint256(destCount) - 1) * 8;
        // Restrict the injected nonzero bits to the UNUSED destination bytes only: bits
        // [32 .. lastDestShift). Leaving bits [0 .. 32) (the 28..31 padding) zero keeps this
        // property distinct from the padding property (E-8).
        uint256 reservedMask = ((uint256(1) << lastDestShift) - 1) & ~((uint256(1) << 32) - 1);
        uint256 reserved = uint256(unused) & reservedMask;
        vm.assume(reserved != 0);
        bytes32 packed = bytes32((uint256(destCount) << 240) | reserved);

        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(this._unpackWrapper.selector, packed));
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.NonZeroPadding.selector, 'NonZeroPadding');
    }

    /* ───────────────── Property E-12: non-increasing dynamic offsets -> OutOfBounds ───────────────── */

    function check_explode_non_increasing_dynamic_offsets_reverts(uint256 off0, uint256 off1) external {
        // Two dynamic destinations read head words 0 and 1 as byte offsets. headLen = 64,
        // sourceLen = 128. Both offsets are individually valid (word-aligned, within
        // [headLen, sourceLen)), but the second does not strictly increase, so tail resolution
        // must revert OutOfBounds.
        vm.assume(off0 >= 64 && off0 < 128 && (off0 & 31) == 0);
        vm.assume(off1 >= 64 && off1 < 128 && (off1 & 31) == 0);
        vm.assume(off1 <= off0);

        bytes[] memory regs = new bytes[](3);
        regs[0] = abi.encodePacked(off0, off1, svm.createBytes32('w2'), svm.createBytes32('w3'));

        uint8[] memory dests = new uint8[](2);
        dests[0] = VmConstants.DYN_MASK | 1;
        dests[1] = VmConstants.DYN_MASK | 2;

        (bool ok, bytes memory ret) = _callExplode(regs, 0, dests);
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.OutOfBounds.selector, 'OutOfBounds');
    }

    /* ───────────────── Property E-13: invalid dynamic offset alignment/range -> OutOfBounds ───────────────── */

    function check_explode_invalid_dynamic_offset_reverts(uint256 offset) external {
        // Single dynamic destination with a symbolic head-word offset. headLen = 32, sourceLen = 96.
        // Any offset that is unaligned, lands inside the head region, or is out of range must revert.
        vm.assume((offset & 31) != 0 || offset < 32 || offset >= 96);

        bytes[] memory regs = new bytes[](2);
        regs[0] = abi.encodePacked(offset, svm.createBytes32('w1'), svm.createBytes32('w2'));

        uint8[] memory dests = new uint8[](1);
        dests[0] = VmConstants.DYN_MASK | 1;

        (bool ok, bytes memory ret) = _callExplode(regs, 0, dests);
        assertTrue(!ok, 'should revert');
        assertEq(bytes4(ret), VmErrors.OutOfBounds.selector, 'OutOfBounds');
    }

    /* ───────────────── Helpers ───────────────── */

    function _callExplode(
        bytes[] memory regs,
        uint8 sourceReg,
        uint8[] memory dests
    )
        private
        returns (bool ok, bytes memory ret)
    {
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({ op: OP.EXPLODE, data: CommandPacking.packExplode(sourceReg, uint8(dests.length), dests) });
        VMState memory s0 = VMState({ registers: regs });
        return address(machine).call(abi.encodeWithSelector(VirtualMachine.runWithState.selector, cmds, s0));
    }
}
