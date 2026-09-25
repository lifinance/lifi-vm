// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseTargetFunctions } from '@chimera/BaseTargetFunctions.sol';
import { BeforeAfter } from '../BeforeAfter.sol';
import { Properties } from '../Properties.sol';
// Chimera deps
import { vm } from '@chimera/Hevm.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

import { VmCmd } from '../../lib/VmCmd.sol';
import { Regs } from '../../lib/Regs.sol';
import { VMCommand, VMState, OP } from 'src/DataModel.sol';
import { MemoryUtils } from 'src/MemoryUtils.sol';

/// @notice Recon/Chimera target handlers for the EXPLODE opcode.
/// @dev A raw handler feeds the fuzzer's packed word straight into the VM (reverts are the normal
///      outcome and are checked against the ISA's declared taxonomy, not swallowed), while the
///      clamped handlers steer the fuzzer into the valid input space so the EXPLODE invariants in
///      Properties.sol run against real executions. The clamped handlers run
///      a single EXPLODE over a freshly-built, self-contained VMState and record the pre/post register
///      images into the `_explode` ghost so the properties can reason about a known command.
abstract contract ExplodeTargets is BaseTargetFunctions, Properties {
    /// @dev Register-file size for the self-contained EXPLODE executions. `destCount` tops out at
    ///      `MAX_EXPLODE_DESTS` = 26, so index 0 for the source plus 1..26 for the destinations is the
    ///      whole reachable space; 32 leaves headroom. The raw handler still reaches indices above this
    ///      bound, where `RegisterFile` reverts `RegisterIndexOOB` — a legitimate path to explore.
    uint256 internal constant EXPLODE_REGS = 32;

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// @notice Raw handler: hand the fuzzer's packed word to the VM as an EXPLODE command.
    /// @dev Exercises CommandPacking.unpackExplode and ExplodeLib.execute across arbitrary bits.
    ///      Most inputs are malformed, so reverting is the expected outcome and says nothing on its
    ///      own. The revert *reason* does: the outcome is recorded into the `_explodeRaw` ghost and
    ///      `property_explode_raw_revert_taxonomy` asserts it is one of the errors the ISA declares.
    ///      Swallowing the reason here would make a Solidity panic inside the VM indistinguishable
    ///      from an intended `OutOfBounds` rejection.
    function explode_raw(uint256 packedWord, bytes memory sourceData) public asActor {
        VMState memory s = VMState({ registers: new bytes[](EXPLODE_REGS) });
        uint8 srcIdx = uint8(packedWord >> 248) & 0x7f;
        if (srcIdx < EXPLODE_REGS) {
            s.registers[srcIdx] = sourceData;
        }

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({ op: OP.EXPLODE, data: bytes32(packedWord) });

        _explodeRaw.ran = true;
        _explodeRaw.emptyReason = false;
        _explodeRaw.selector = bytes4(0);

        try virtualMachine.runWithState(cmds, s) returns (VMState memory, bytes memory) {
            _explodeRaw.reverted = false;
        } catch (bytes memory reason) {
            _explodeRaw.reverted = true;
            if (reason.length < 4) {
                _explodeRaw.emptyReason = true;
            } else {
                _explodeRaw.selector = bytes4(reason);
            }
        }
    }

    /// @notice Clamped handler: all-static EXPLODE over a well-formed head-only source blob.
    function explode_clampedStatic(uint256 seed) public asActor {
        uint8 destCount = uint8(between(seed, 1, 26));
        bytes memory source = _buildStaticSource(seed, destCount);

        uint8[] memory dests = new uint8[](destCount);
        for (uint256 i = 0; i < destCount; i++) {
            dests[i] = uint8(1 + i); // static, distinct, never the source register (0)
        }

        _executeClampedExplode(0, dests, source, ExplodeMode.STATIC);
    }

    /// @notice Clamped handler: all-dynamic EXPLODE with word-aligned, strictly-increasing offsets.
    function explode_clampedDynamic(uint256 seed) public asActor {
        uint8 destCount = uint8(between(seed, 1, 26));
        (bytes memory source,) = _buildDynamicSource(seed, destCount);

        uint8[] memory dests = new uint8[](destCount);
        for (uint256 i = 0; i < destCount; i++) {
            dests[i] = Regs.withDyn(uint8(1 + i)); // dynamic, distinct, never the source register (0)
        }

        _executeClampedExplode(0, dests, source, ExplodeMode.DYNAMIC);
    }

    /// @notice Clamped handler: single dynamic destination that aliases the source register.
    /// @dev The source is read once up front, so the aliased destination must receive the tail of the
    ///      pre-command source, not of the value it overwrites.
    function explode_aliasSource(uint256 seed) public asActor {
        uint256 tailWords = 1 + (uint256(keccak256(abi.encodePacked(seed, 'alias'))) & 3); // 1..4 words
        uint256 sourceLen = 32 + tailWords * 32;
        bytes memory source = new bytes(sourceLen);

        // Head word (offset 0) holds the dynamic offset: the start of the tail region (== headLen).
        uint256 off = 32;
        assembly {
            mstore(add(source, 0x20), off)
        }
        // Fill the tail region with pseudo-random words.
        for (uint256 p = 32; p < sourceLen; p += 32) {
            bytes32 w = keccak256(abi.encodePacked(seed, 'alias-tail', p));
            assembly {
                mstore(add(add(source, 0x20), p), w)
            }
        }

        uint8[] memory dests = new uint8[](1);
        dests[0] = Regs.withDyn(0); // destination aliases the source register (index 0)

        _executeClampedExplode(0, dests, source, ExplodeMode.ALIAS);
    }

    /// @notice Clamped handler: interleaved static and dynamic destinations.
    /// @dev Targets `ExplodeLib._resolveDynamicEnd`, the forward rescan that decides where a dynamic
    ///      tail ends. A static destination sitting between two dynamic ones must NOT terminate the
    ///      earlier tail — the tail runs on to the next *dynamic* destination's offset. Every other
    ///      clamped handler is all-static, all-dynamic or single-alias, so this is the only fuzzed
    ///      cover for that scan; before it, the rescan was defended by fixed-input unit tests alone.
    function explode_clampedMixed(uint256 seed) public asActor {
        uint8 destCount = uint8(between(seed, 3, 26));

        bool[] memory isDyn = new bool[](destCount);
        uint256 pattern = uint256(keccak256(abi.encodePacked(seed, 'mixed')));
        for (uint256 i = 0; i < destCount; i++) {
            isDyn[i] = ((pattern >> i) & 1) == 1;
        }
        // Pin the shape this handler exists to defend into every run: dynamic, static, dynamic. The
        // remaining destinations keep their seed-derived flags, so the interleaving still varies.
        isDyn[0] = true;
        isDyn[1] = false;
        isDyn[2] = true;

        (bytes memory source, bytes memory want) = _buildMixedSource(seed, destCount, isDyn);

        uint8[] memory dests = new uint8[](destCount);
        for (uint256 i = 0; i < destCount; i++) {
            dests[i] = isDyn[i] ? Regs.withDyn(uint8(1 + i)) : uint8(1 + i);
        }

        _runClampedExplode(0, dests, source, ExplodeMode.MIXED, want);
    }

    /// @notice Push a clamped all-static EXPLODE onto the shared command queue.
    /// @dev Lets EXPLODE participate in multi-command sequences run by `performClampedCall`, so the
    ///      generic `property_untouched_registries` canary covers it too.
    function addExplodeToDictionary(uint256 seed) public {
        uint8 destCount = uint8(between(seed, 1, 8));
        bytes memory source = _buildStaticSource(seed, destCount);
        state.registers[srcReg] = source;

        uint8[] memory dests = new uint8[](destCount);
        for (uint256 i = 0; i < destCount; i++) {
            dests[i] = uint8(5 + i); // avoid the reserved 0..4 registers used elsewhere
        }

        commands.push(VmCmd.explode(srcReg, dests));
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    /// === Internal helpers === ///

    /// @dev Mode-derived entry point for the single-shape clamped handlers. STATIC destinations must
    ///      reconstruct the head region; DYNAMIC and ALIAS must reconstruct the tail region, i.e.
    ///      everything from the head length to the end of the source. MIXED cannot be expressed this
    ///      way and calls `_runClampedExplode` with its expected string built alongside the source.
    function _executeClampedExplode(
        uint8 sourceReg,
        uint8[] memory destRegs,
        bytes memory source,
        ExplodeMode mode
    )
        internal
    {
        uint256 headLen = destRegs.length * 32;
        bytes memory want = mode == ExplodeMode.STATIC
            ? MemoryUtils.slice(source, 0, headLen)
            : MemoryUtils.slice(source, headLen, source.length - headLen);

        _runClampedExplode(sourceReg, destRegs, source, mode, want);
    }

    /// @dev Runs one EXPLODE over a fresh, self-contained VMState and reduces the outcome into the
    ///      `_explode` ghost: `expected` is the digest of `want`, the byte string the ISA says the
    ///      destinations must hold, concatenated in destination order and derived from the source as
    ///      it was BEFORE the command; `actual` is the digest of what they hold afterwards; and
    ///      `untouched` records that no non-destination register moved. Reducing here rather than
    ///      storing register images is what keeps the harness deployable — see the note on
    ///      `ExplodeObs` in BeforeAfter.sol.
    function _runClampedExplode(
        uint8 sourceReg,
        uint8[] memory destRegs,
        bytes memory source,
        ExplodeMode mode,
        bytes memory want
    )
        internal
    {
        VMState memory s = VMState({ registers: new bytes[](EXPLODE_REGS) });
        s.registers[sourceReg] = source;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(sourceReg, destRegs);

        _explode.mode = mode;
        _explode.expected = keccak256(want);
        _explode.actual = bytes32(0);
        _explode.untouched = false;

        try virtualMachine.runWithState(cmds, s) returns (VMState memory ns, bytes memory) {
            _explode.reverted = false;
            _explode.actual = _concatDigest(ns.registers, destRegs);
            _explode.untouched = _nonDestUntouched(ns.registers, destRegs, sourceReg, source);
        } catch {
            _explode.reverted = true;
        }
    }

    /// @dev Digest of the destination register contents concatenated in destination order.
    function _concatDigest(bytes[] memory regs, uint8[] memory destRegs) private pure returns (bytes32) {
        bytes memory concat;
        for (uint256 i = 0; i < destRegs.length; i++) {
            concat = abi.encodePacked(concat, regs[destRegs[i] & 0x7f]);
        }
        return keccak256(concat);
    }

    /// @dev True when every register that is not a destination still holds its pre-command value. The
    ///      pre-image is known exactly: `sourceReg` held `source` and every other slot was empty.
    function _nonDestUntouched(
        bytes[] memory regs,
        uint8[] memory destRegs,
        uint8 sourceReg,
        bytes memory source
    )
        private
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < regs.length; i++) {
            bool isDest;
            for (uint256 j = 0; j < destRegs.length; j++) {
                if ((destRegs[j] & 0x7f) == uint8(i)) {
                    isDest = true;
                    break;
                }
            }
            if (isDest) continue;

            bytes32 want = uint8(i) == (sourceReg & 0x7f) ? keccak256(source) : keccak256('');
            if (keccak256(regs[i]) != want) return false;
        }
        return true;
    }

    /// @dev Builds a head-only source blob of `destCount` pseudo-random words.
    function _buildStaticSource(uint256 seed, uint8 destCount) internal pure returns (bytes memory source) {
        uint256 headLen = uint256(destCount) * 32;
        source = new bytes(headLen);
        for (uint256 i = 0; i < destCount; i++) {
            bytes32 w = keccak256(abi.encodePacked(seed, i));
            assembly {
                mstore(add(add(source, 0x20), mul(i, 32)), w)
            }
        }
    }

    /// @dev Builds a well-formed all-dynamic source: `destCount` head words holding strictly-increasing,
    ///      word-aligned offsets that start at the head length, followed by pseudo-random tail words.
    function _buildDynamicSource(
        uint256 seed,
        uint8 destCount
    )
        internal
        pure
        returns (bytes memory source, uint256[] memory offsets)
    {
        uint256 headLen = uint256(destCount) * 32;
        offsets = new uint256[](destCount);

        uint256 sourceLen = headLen;
        for (uint256 i = 0; i < destCount; i++) {
            offsets[i] = sourceLen;
            uint256 sz = 32 * (1 + (uint256(keccak256(abi.encodePacked(seed, 'sz', i))) & 3)); // 32..128 bytes
            sourceLen += sz;
        }

        source = new bytes(sourceLen);
        for (uint256 i = 0; i < destCount; i++) {
            uint256 off = offsets[i];
            assembly {
                mstore(add(add(source, 0x20), mul(i, 32)), off)
            }
        }
        for (uint256 p = headLen; p < sourceLen; p += 32) {
            bytes32 w = keccak256(abi.encodePacked(seed, 'tail', p));
            assembly {
                mstore(add(add(source, 0x20), p), w)
            }
        }
    }

    /// @dev Builds a well-formed source with interleaved static and dynamic head words, and alongside
    ///      it the exact byte string the destinations must hold, concatenated in destination order.
    ///      Dynamic tails are laid out contiguously in destination order, so the offsets are
    ///      word-aligned and strictly increasing and the tails partition everything past the head.
    ///      `want` is produced by construction rather than by re-deriving the tail boundaries the way
    ///      the VM does; re-implementing `_resolveDynamicEnd` here would make the property tautological.
    function _buildMixedSource(
        uint256 seed,
        uint8 destCount,
        bool[] memory isDyn
    )
        internal
        pure
        returns (bytes memory source, bytes memory want)
    {
        uint256 headLen = uint256(destCount) * 32;

        uint256[] memory starts = new uint256[](destCount);
        uint256[] memory ends = new uint256[](destCount);
        uint256 cursor = headLen;
        for (uint256 i = 0; i < destCount; i++) {
            if (!isDyn[i]) continue;
            uint256 sz = 32 * (1 + (uint256(keccak256(abi.encodePacked(seed, 'msz', i))) & 3)); // 32..128
            starts[i] = cursor;
            cursor += sz;
            ends[i] = cursor;
        }
        uint256 sourceLen = cursor;

        source = new bytes(sourceLen);
        for (uint256 i = 0; i < destCount; i++) {
            bytes32 w = isDyn[i] ? bytes32(starts[i]) : keccak256(abi.encodePacked(seed, 'mhead', i));
            assembly {
                mstore(add(add(source, 0x20), mul(i, 32)), w)
            }
        }
        for (uint256 p = headLen; p < sourceLen; p += 32) {
            bytes32 w = keccak256(abi.encodePacked(seed, 'mtail', p));
            assembly {
                mstore(add(add(source, 0x20), p), w)
            }
        }

        for (uint256 i = 0; i < destCount; i++) {
            want = abi.encodePacked(
                want,
                isDyn[i]
                    ? MemoryUtils.slice(source, starts[i], ends[i] - starts[i])
                    : MemoryUtils.slice(source, i * 32, 32)
            );
        }
    }
}
