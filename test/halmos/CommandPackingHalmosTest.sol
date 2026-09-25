// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { CommandPacking } from 'src/CommandPacking.sol';
import { VmErrors } from 'src/VmErrors.sol';
import {
    Call,
    CallDataBuild,
    Explode,
    DepositApproved,
    CallDataSurgery,
    SurgeryDescriptor,
    Return,
    AbiEncode,
    RemainingGas,
    NativeBalance,
    Log,
    LogVariant
} from 'src/DataModel.sol';

// halmos --contract CommandPackingHalmosTest --loop 100
// Harness to expose internal library functions for revert testing
contract CommandPackingHarness {
    function packCallDataBuild(bytes4 sel, uint8 destReg, bytes memory bp) external pure returns (bytes32) {
        return CommandPacking.packCallDataBuild(sel, destReg, bp);
    }

    function packAbiEncode(uint8 destReg, bytes memory bp) external pure returns (bytes32) {
        return CommandPacking.packAbiEncode(destReg, bp);
    }

    function unpackCallDataBuild(bytes32 packed) external pure returns (CallDataBuild memory) {
        return CommandPacking.unpackCallDataBuild(packed);
    }
}

// halmos --contract CommandPackingHalmosTest --loop 100
contract CommandPackingHalmosTest is Test, SymTest {
    CommandPackingHarness private h = new CommandPackingHarness();

    // Property 1) Call roundtrip
    // Pack a Call command with symbolic fields, then unpack and check equality
    function check_call_roundtrip(
        address target,
        uint8 callType,
        uint8 destReg,
        uint8 srcReg,
        uint8 valueReg
    )
        external
        pure
    {
        bytes32 packed = CommandPacking.packCall(target, callType, destReg, srcReg, valueReg);
        Call memory callCmd = CommandPacking.unpackCall(packed);
        assertEq(callCmd.target, target, 'target');
        assertEq(callCmd.callType, callType, 'callType');
        assertEq(callCmd.destReg, destReg, 'destReg');
        assertEq(callCmd.srcReg, srcReg, 'srcReg');
        assertEq(callCmd.valueReg, valueReg, 'valueReg');
    }

    // property 2) CallDataBuild roundtrip and guard
    // Pack a CallDataBuild command with symbolic fields, then unpack and check equality
    // Guard: blueprint length <= 22
    function check_calldata_build_roundtrip(bytes4 sel, uint8 destReg) external pure {
        uint256 lenSym = svm.createUint(5, 'len'); // 0..31
        vm.assume(lenSym < 23); // max 22 bytes can be packed
        for (uint256 len = 0; len < 23; len++) {
            if (len == lenSym) {
                bytes memory bp = svm.createBytes(len, 'bp');
                bytes32 packed = CommandPacking.packCallDataBuild(sel, destReg, bp);
                CallDataBuild memory c = CommandPacking.unpackCallDataBuild(packed);
                assertEq(c.selector, sel, 'selector');
                assertEq(c.destReg, destReg, 'destReg');
                assertEq(c.blueprint.length, bp.length, 'bp.len');
                for (uint256 j = 0; j < c.blueprint.length; ++j) {
                    assertEq(c.blueprint[j], bp[j], 'bp[j]');
                }
            }
        }
    }

    // property 3) Explode roundtrip and guard
    // Pack an Explode command with symbolic fields, then unpack and check equality
    function check_explode_roundtrip() external pure {
        uint256 sourceRegSym = svm.createUint(8, 'sourceReg');
        uint256 destCountSym = svm.createUint(8, 'destCount');
        vm.assume(sourceRegSym < 0x80); // byte 0 high bit is a reserved dead flag, must be clear
        vm.assume(destCountSym > 0 && destCountSym < 27); // 1..26 dest

        for (uint256 i = 1; i < 26; i++) {
            if (i == destCountSym) {
                uint8[] memory destRegs = new uint8[](i); // max 26 dest regs
                for (uint256 j; j < i; j++) {
                    destRegs[j] = uint8(svm.createUint(8, 'destReg'));
                }
                bytes32 packed = CommandPacking.packExplode(uint8(sourceRegSym), uint8(i), destRegs);
                Explode memory e = CommandPacking.unpackExplode(packed);
                assertEq(e.sourceReg, sourceRegSym, 'sourceReg');
                assertEq(e.destCount, uint8(i), 'destCount');
                for (uint256 j = 0; j < i; ++j) {
                    assertEq(
                        uint8(e.packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - j * 8)), destRegs[j], 'reg[j]'
                    );
                }
            }
        }
    }

    // property 4) DepositApproved roundtrip
    // Pack a DepositApproved command with symbolic fields, then unpack and check equality
    function check_deposit_approved_roundtrip(address token, uint8 destReg, uint8 maxDepositReg) external pure {
        DepositApproved memory d = DepositApproved({ token: token, destReg: destReg, maxDepositReg: maxDepositReg });
        bytes32 packed = CommandPacking.packDepositApproved(d);
        DepositApproved memory deposit = CommandPacking.unpackDepositApproved(packed);
        assertEq(deposit.token, token, 'token');
        assertEq(deposit.destReg, destReg, 'destReg');
        assertEq(deposit.maxDepositReg, maxDepositReg, 'maxDepositReg');
    }

    // Property 5) CallDataSurgery roundtrip
    // Pack a CallDataSurgery command with symbolic fields, then unpack and check equality
    // Guard: surgeryCount < 7
    function check_surgery_roundtrip(uint8 srcReg, uint8 surgeryCountSym) external pure {
        vm.assume(surgeryCountSym < 7);
        for (uint256 surgeryCount; surgeryCount < 7; surgeryCount++) {
            if (surgeryCount == surgeryCountSym) {
                SurgeryDescriptor[6] memory surgeries;

                for (uint8 j; j < surgeryCount; j++) {
                    surgeries[j] = SurgeryDescriptor({ offset: j, length: j, replacementReg: j });
                }

                CallDataSurgery memory cds =
                    CallDataSurgery({ sourceReg: srcReg, surgeryCount: uint8(surgeryCount), surgeries: surgeries });
                bytes32 packed = CommandPacking.packCallDataSurgery(cds);
                CallDataSurgery memory s = CommandPacking.unpackCallDataSurgery(packed);
                assertEq(s.sourceReg, srcReg, 'sourceReg');
                assertEq(s.surgeryCount, surgeryCount, 'count');
                for (uint256 i = 0; i < surgeryCount; ++i) {
                    assertEq(s.surgeries[i].offset, surgeries[i].offset, 'offset[i]');
                    assertEq(s.surgeries[i].length, surgeries[i].length, 'length[i]');
                    assertEq(s.surgeries[i].replacementReg, surgeries[i].replacementReg, 'replacementReg[i]');
                }
                for (uint256 i = surgeryCount; i < 6; ++i) {
                    assertEq(s.surgeries[i].offset, 0, 'unused.offset');
                    assertEq(s.surgeries[i].length, 0, 'unused.length');
                    assertEq(s.surgeries[i].replacementReg, 0, 'unused.repl');
                }
            }
        }
    }

    // Property 6) Return roundtrip
    // Pack a Return command with symbolic fields, then unpack and check equality
    function check_return_roundtrip(uint8 src) external pure {
        bytes32 packed = CommandPacking.packReturn(src);
        Return memory returnCmd = CommandPacking.unpackReturn(packed);
        assertEq(returnCmd.sourceReg, src, 'return.src');
    }

    // Property 7) AbiEncode roundtrip
    // Pack an AbiEncode command with symbolic fields, then unpack and check equality
    // Guard: blueprint length <= 27
    function check_abi_encode_roundtrip(uint8 destReg) external pure {
        uint256 lenSym = svm.createUint(5, 'len'); // 0..31
        vm.assume(lenSym < 28); // max 27 bytes can be packed
        for (uint256 len; len < 28; len++) {
            if (len == lenSym) {
                bytes memory bp = svm.createBytes(len, 'bp');
                bytes32 packed = CommandPacking.packAbiEncode(destReg, bp);
                AbiEncode memory a = CommandPacking.unpackAbiEncode(packed);
                assertEq(a.destReg, destReg, 'destReg');
                assertEq(a.blueprint.length, bp.length, 'bp.len');
                for (uint256 i = 0; i < a.blueprint.length; ++i) {
                    assertEq(a.blueprint[i], bp[i], 'bp[i]');
                }
            }
        }
    }

    // Property 7b) packCallDataBuild reverts when blueprint length > 22
    function check_calldata_build_blueprint_too_large_reverts() external {
        bytes memory bp = svm.createBytes(23, 'bpTooBig');
        bytes memory cd = abi.encodeWithSelector(
            CommandPackingHarness.packCallDataBuild.selector, bytes4(0x12345678), uint8(0xAB), bp
        );
        (bool ok, bytes memory ret) = address(h).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), VmErrors.BlueprintTooLarge.selector, 'selector');
    }

    // Property 7c) packAbiEncode reverts when blueprint length > 27
    function check_abi_encode_blueprint_too_large_reverts() external {
        bytes memory bp = svm.createBytes(28, 'bpTooBig');
        bytes memory cd = abi.encodeWithSelector(CommandPackingHarness.packAbiEncode.selector, uint8(0xCD), bp);
        (bool ok, bytes memory ret) = address(h).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), VmErrors.BlueprintTooLarge.selector, 'selector');
    }

    // Property 8) RemainingGas roundtrip
    // Pack a RemainingGas command with symbolic fields, then unpack and check equality
    function check_remaining_gas_roundtrip(uint8 destReg) external pure {
        bytes32 packed = CommandPacking.packRemainingGas(destReg);
        RemainingGas memory remainingGas = CommandPacking.unpackRemainingGas(packed);
        assertEq(remainingGas.destReg, destReg, 'remainingGas.destReg');
    }

    // Property 9) NativeBalance roundtrip
    // Pack a NativeBalance command with symbolic fields, then unpack and check equality
    function check_native_balance_roundtrip(uint8 addrReg, uint8 destReg) external pure {
        bytes32 packed = CommandPacking.packNativeBalance(addrReg, destReg);
        NativeBalance memory nativeBalance = CommandPacking.unpackNativeBalance(packed);
        assertEq(nativeBalance.addrReg, addrReg, 'addrReg');
        assertEq(nativeBalance.destReg, destReg, 'destReg');
    }

    // Property 10) Log roundtrip
    // Pack a Log command with symbolic fields, then unpack and check equality
    // Guard: variant <= LogVariant.DYNAMIC
    function check_log_roundtrip(uint8 variant, uint256 sourceRegs) external pure {
        vm.assume(variant <= uint8(LogVariant.DYNAMIC)); // LogVariant.DYNAMIC
        bytes32 packed = CommandPacking.packLog(variant, sourceRegs);
        Log memory log = CommandPacking.unpackLog(packed);
        assertEq(log.variant, variant, 'variant');
        assertEq(log.sourceRegs & ((uint256(1) << 208) - 1), sourceRegs, 'sourceRegs');
    }

    // Property 11) UnpackCallDataBuild reverts on overflow length
    function check_unpackCallDataBuild_overflow() external {
        uint8 L = 28; // Arbitrary value >22, exceeds MAX_CDB_BP
        bytes32 packed = bytes32(uint256(uint32(0xCAFEBABE))) << 224;
        packed |= bytes32(uint256(0x77)) << 216; // destReg
        packed |= bytes32(uint256(L)) << 208; // blueprint length
        // Fill blueprint bytes with pattern
        for (uint256 i = 0; i < 22; ++i) {
            packed |= bytes32(uint256(uint8(0xAA + i))) << ((25 - i) * 8);
        }
        // unpackCallDataBuild now validates blueprint length and reverts
        bytes memory cd = abi.encodeWithSelector(CommandPackingHarness.unpackCallDataBuild.selector, packed);
        (bool ok, bytes memory ret) = address(h).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), VmErrors.BlueprintTooLarge.selector, 'selector');
    }

    // // REVERSE ROUNDTRIP PROPERTIES //
    // function check_call_packaed_roundtrip(
    //     bytes32 packed
    // ) external pure {
    //     Call memory callCmd = CommandPacking.unpackCall(packed);

    //     bytes32 packed2 = CommandPacking.packCall(
    //         callCmd.target,
    //         callCmd.callType,
    //         callCmd.destReg,
    //         callCmd.srcReg,
    //         callCmd.valueReg
    //     );
    //     assertEq(packed, packed2, "packed");
    // }
}
