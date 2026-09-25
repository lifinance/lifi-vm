// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Asserts } from '@chimera/Asserts.sol';
import { BeforeAfter, OpType } from './BeforeAfter.sol';
import { CommandPacking } from 'src/CommandPacking.sol';
import {
    OP,
    Call,
    CallDataBuild,
    Explode,
    DepositApproved,
    CallDataSurgery,
    Return,
    AbiEncode,
    RemainingGas,
    NativeBalance,
    SafeTransfer
} from 'src/DataModel.sol';
import { RegisterFile } from 'src/RegisterFile.sol';
import { VmErrors } from 'src/VmErrors.sol';

abstract contract Properties is BeforeAfter, Asserts {
    using CommandPacking for bytes32;

    /// === Clamped Canaries === ///

    // It should be impossible to alter registries past 128
    // (as any value past it should be considered a flag for Dynamic Registries and not an index)
    function invariant_registries() public {
        for (uint256 i = 256 - MAX_REGISTRY_COUNT; i < 256; i++) {
            eq(state.registers[i].length, DIRTY_REGISTRY_FLAG.length, 'Registry Length has changed');
            eq(
                uint256(keccak256(state.registers[i])),
                uint256(keccak256(DIRTY_REGISTRY_FLAG)),
                'Registry Value has changed'
            );
        }
    }

    function property_untouched_registries() public {
        // Only applies for clamped calls
        if (currentOperation != OpType.CLAMPED_CALL) {
            return;
        }

        uint256 registriesCount = 0;
        uint256[] memory registries = new uint256[](128);

        // Check all dst registries in the queue
        for (uint256 i = 0; i < commands.length; i++) {
            if (commands[i].op == OP.CALL) {
                Call memory call = commands[i].data.unpackCall();
                registries[registriesCount++] = call.destReg;
            }

            if (commands[i].op == OP.CALLDATA_BUILD) {
                CallDataBuild memory cdb = commands[i].data.unpackCallDataBuild();
                registries[registriesCount++] = cdb.destReg;
            }

            if (commands[i].op == OP.EXPLODE) {
                Explode memory e = commands[i].data.unpackExplode();
                for (uint256 k = 0; k < e.destCount; k++) {
                    uint8 dr = uint8(e.packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - k * 8));
                    registries[registriesCount++] = dr & 0x7f; // strip the dynamic flag to a raw index
                }
            }

            if (commands[i].op == OP.DEPOSIT_APPROVED) {
                DepositApproved memory d = commands[i].data.unpackDepositApproved();
                registries[registriesCount++] = d.destReg;
            }

            if (commands[i].op == OP.CALLDATA_SURGERY) {
                CallDataSurgery memory s = commands[i].data.unpackCallDataSurgery();
                registries[registriesCount++] = s.sourceReg;
                for (uint256 j = 0; j < s.surgeryCount; j++) {
                    registries[registriesCount++] = s.surgeries[j].replacementReg;
                }
            }

            if (commands[i].op == OP.RETURN) {
                // No dstReg
            }

            if (commands[i].op == OP.ABI_ENCODE) {
                AbiEncode memory a = commands[i].data.unpackAbiEncode();
                registries[registriesCount++] = a.destReg;
            }

            if (commands[i].op == OP.REMAINING_GAS) {
                RemainingGas memory r = commands[i].data.unpackRemainingGas();
                registries[registriesCount++] = r.destReg;
            }

            if (commands[i].op == OP.NATIVE_BALANCE) {
                NativeBalance memory nb = commands[i].data.unpackNativeBalance();
                registries[registriesCount++] = nb.destReg;
            }

            if (commands[i].op == OP.LOG) {
                // NOTE: Unsopported
            }

            if (commands[i].op == OP.SAFE_TRANSFER) {
                // SafeTransfer doesn't modify any destination registers
                // It only transfers tokens from VM to recipient
                // No register modifications to track
            }
        }

        for (uint256 i = 0; i < _after.registers.length; i++) {
            if (_contains(registries, i)) {
                // Is part of DestReg, skip
                continue;
            }
            eq(
                uint256(keccak256(_after.registers[i])),
                uint256(keccak256(_before.registers[i])),
                'Registry Value has changed'
            );
        }
    }

    /// === EXPLODE invariants === ///
    /// Driven by the clamped handlers in ExplodeTargets via the `_explode` ghost. The handler runs one
    /// EXPLODE over a self-contained VMState and reduces the outcome to two digests: `expected`, the
    /// byte string the ISA says the destinations must hold, derived from the pre-command source; and
    /// `actual`, what they do hold. The properties assert the two agree for the mode that ran. The
    /// reduction happens in the handler because retaining register images in storage makes the harness
    /// undeployable — see the note on `ExplodeObs` in BeforeAfter.sol. Foundry reproducers for every
    /// property live in CryticToFoundry.

    /// @notice A clamped, well-formed EXPLODE must never revert.
    /// @dev Catches over-strict or off-by-one bounds validation in unpackExplode/ExplodeLib.execute
    ///      that would reject inputs the ISA deems valid.
    function property_explode_no_revert_on_valid() public {
        if (_explode.mode == ExplodeMode.NONE) return;
        t(!_explode.reverted, 'EXPLODE: well-formed command reverted');
    }

    /// @notice All-static EXPLODE conserves bytes: the destinations, concatenated in destination order,
    ///         equal the head region of the source, byte for byte.
    /// @dev Catches wrong word extraction, mis-ordered writes, truncation, or reading the wrong slice.
    function property_explode_static_conservation() public {
        if (_explode.mode != ExplodeMode.STATIC || _explode.reverted) return;
        eq(
            uint256(_explode.actual),
            uint256(_explode.expected),
            'EXPLODE: static destinations do not reconstruct the source head'
        );
    }

    /// @notice All-dynamic EXPLODE partitions the source: the destination tails, concatenated in
    ///         destination order, equal the source region from the head length to the end — no gap,
    ///         no overlap, nothing dropped.
    /// @dev Catches wrong tail boundaries (off-by-one on a start/end offset, or a missed final tail).
    function property_explode_dynamic_tail_partition() public {
        if (_explode.mode != ExplodeMode.DYNAMIC || _explode.reverted) return;
        eq(uint256(_explode.actual), uint256(_explode.expected), 'EXPLODE: dynamic tails do not partition the source');
    }

    /// @notice Registers that are not EXPLODE destinations are byte-identical before and after.
    /// @dev Catches stray writes, including accidental mutation of a non-aliased source register.
    function property_explode_non_interference() public {
        if (_explode.mode == ExplodeMode.NONE || _explode.reverted) return;
        t(_explode.untouched, 'EXPLODE: non-destination register mutated');
    }

    /// @notice When a destination aliases the source register it still receives the value derived from
    ///         the pre-command source contents, because the source is read once up front.
    /// @dev Catches a read-after-write bug where the source is re-read after being overwritten.
    function property_explode_alias_safety() public {
        if (_explode.mode != ExplodeMode.ALIAS || _explode.reverted) return;
        eq(
            uint256(_explode.actual),
            uint256(_explode.expected),
            'EXPLODE: aliased destination not derived from the pre-image source'
        );
    }

    /// @notice A mixed EXPLODE reproduces the source exactly: each static destination holds its head
    ///         word, and each dynamic destination holds the slice running to the NEXT DYNAMIC
    ///         destination's offset — never truncated by an intervening static destination.
    /// @dev This is the only fuzzed cover for `ExplodeLib._resolveDynamicEnd`'s forward rescan. If a
    ///      static destination were allowed to terminate a dynamic tail, the earlier tail would come
    ///      back short and the concatenation would diverge from the string the handler built.
    function property_explode_mixed_partition() public {
        if (_explode.mode != ExplodeMode.MIXED || _explode.reverted) return;
        eq(
            uint256(_explode.actual),
            uint256(_explode.expected),
            'EXPLODE: mixed destinations do not reproduce the source'
        );
    }

    /// @notice An arbitrary EXPLODE word may be rejected, but only for a reason the ISA declares.
    /// @dev Gates the widest handler, `explode_raw`, which otherwise reports nothing: it feeds random
    ///      bits to the VM and reverting is the normal outcome. A Solidity `Panic` means the VM hit an
    ///      overflow or a bad index instead of rejecting the input; empty return data means it ran out
    ///      of gas. Either is a defect that a bare `catch {}` would hide behind an expected revert.
    function property_explode_raw_revert_taxonomy() public {
        if (!_explodeRaw.ran || !_explodeRaw.reverted) return;
        t(!_explodeRaw.emptyReason, 'EXPLODE: raw command reverted with no return data (panic or out of gas)');
        t(_explodeRaw.selector != PANIC_SELECTOR, 'EXPLODE: raw command triggered a Solidity panic');
        t(
            _isDeclaredExplodeRevert(_explodeRaw.selector),
            'EXPLODE: raw command reverted outside the declared error taxonomy'
        );
    }

    /// @dev Solidity's `Panic(uint256)`. Never a legitimate outcome of validating a command word.
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    /// @dev The complete set of errors an EXPLODE command may reject with. `unpackExplode` raises the
    ///      first two, `ExplodeLib.execute` and `MemoryUtils.slice` the next two, and `RegisterFile`
    ///      the last when a register index exceeds the file. Anything else is a bug, not a rejection.
    function _isDeclaredExplodeRevert(bytes4 selector) internal pure returns (bool) {
        return selector == VmErrors.DestinationCountOutOfBounds.selector || selector == VmErrors.NonZeroPadding.selector
            || selector == VmErrors.OutOfBounds.selector || selector == VmErrors.InvalidRegisterLength.selector
            || selector == RegisterFile.RegisterIndexOOB.selector;
    }

    function _contains(uint256[] memory array, uint256 value) internal pure returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }
}
