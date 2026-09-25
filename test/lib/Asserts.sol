// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/DataModel.sol';
import '../../src/SurgeryOPS.sol';
import '../../src/VmErrors.sol';
import '../../src/VMLogLib.sol';
import './TestUtils.sol';
import './Regs.sol';
import 'forge-std/Test.sol';
import 'forge-std/Vm.sol';

/// @notice Behavior assertions for VM tests.
/// @dev Example: Asserts.unchangedExcept(before, afterState, [1, 2]);
library Asserts {
    error ExpectEqBytes(bytes a, bytes b);
    error RegisterChanged(uint8 reg);
    error SelectorMismatch(bytes4 expected, bytes4 actual);
    error DataMismatch();
    error SurgeryMismatch();
    error UnexpectedRevert();
    error EventMismatch();

    /// @notice Assert registers unchanged except specified.
    /// @dev Example: Asserts.unchangedExcept(before, afterState, [1, 2]);
    /// @param before Initial state.
    /// @param afterState Final state.
    /// @param dests Changed register indices.
    function unchangedExcept(VMState memory before, VMState memory afterState, uint8[] memory dests) internal pure {
        require(before.registers.length == afterState.registers.length, 'State length mismatch');

        for (uint256 i = 0; i < before.registers.length; i++) {
            bool isException = false;
            for (uint256 j = 0; j < dests.length; j++) {
                if (uint8(i) == dests[j]) {
                    isException = true;
                    break;
                }
            }

            if (!isException && keccak256(before.registers[i]) != keccak256(afterState.registers[i])) {
                revert RegisterChanged(uint8(i));
            }
        }
    }

    /// @notice Assert data has selector prefix.
    /// @dev Example: Asserts.dataHasSelectorPrefix(out, 0x12345678);
    /// @param out Output data.
    /// @param sel Expected selector.
    function dataHasSelectorPrefix(bytes memory out, bytes4 sel) internal pure {
        require(out.length >= 4, 'Out<4');
        bytes4 got;
        assembly {
            got := mload(add(out, 32))
        }
        if (got != sel) revert SelectorMismatch(sel, got);
    }

    /// @notice Assert output equals selector + expected data.
    /// @dev Example: Asserts.equalsWithSelector(out, sel, expectedData);
    /// @param out Output data.
    /// @param sel Expected selector.
    /// @param expect Expected data after selector.
    function equalsWithSelector(bytes memory out, bytes4 sel, bytes memory expect) internal pure {
        require(out.length >= 4, 'Out<4');
        bytes4 gotSel;
        assembly {
            gotSel := mload(add(out, 32))
        }
        if (gotSel != sel) revert SelectorMismatch(sel, gotSel);

        require(out.length == 4 + expect.length, 'Length mismatch');

        // Efficient comparison using keccak256 on memory slices
        bytes32 outHash;
        bytes32 expectHash;
        assembly {
            // Hash the payload part of 'out' (skip first 4 bytes)
            outHash := keccak256(add(out, 36), mload(expect))
            // Hash the 'expect' data
            expectHash := keccak256(add(expect, 32), mload(expect))
        }
        if (outHash != expectHash) revert DataMismatch();
    }

    /// @notice Assert ABI-encoded data equality.
    /// @dev Example: Asserts.equalsAbiData(out, expected);
    /// @param out Output data.
    /// @param expect Expected data.
    function equalsAbiData(bytes memory out, bytes memory expect) internal pure {
        if (keccak256(out) != keccak256(expect)) {
            revert ExpectEqBytes(out, expect);
        }
    }

    /// @notice Assert VM's length-prefixed encoding matches abi.encode output.
    /// @dev Strips the first 32 bytes (length prefix) from VM output before comparing.
    /// @param vmOutput Output from VM's ABI_ENCODE operation (with length prefix).
    /// @param expected Expected encoding from Solidity's abi.encode (no length prefix).
    function assertEncodingMatches(bytes memory vmOutput, bytes memory expected) internal pure {
        bytes memory strippedOutput = TestUtils.stripLength(vmOutput);
        if (keccak256(strippedOutput) != keccak256(expected)) {
            revert ExpectEqBytes(strippedOutput, expected);
        }
    }

    /// @notice Assert surgery applied correctly.
    /// @dev Example: Asserts.appliedInOrder(state, srcReg, expected, descs);
    /// @param st VM state containing source and replacement registers.
    /// @param srcReg Source register to apply surgeries to.
    /// @param expected Expected data after surgeries.
    /// @param ds Surgery descriptors.
    function appliedInOrder(
        VMState memory st,
        uint8 srcReg,
        bytes memory expected,
        SurgeryDescriptor[] memory ds
    )
        internal
        pure
    {
        SurgeryDescriptor[6] memory fixedArray;
        require(ds.length <= 6, 'too many surgeries');
        for (uint256 i; i < ds.length; ++i) {
            fixedArray[i] = ds[i];
        }

        // mutate in-place in st.registers[srcReg]
        SurgeryOps.performSurgery(st.registers, srcReg, fixedArray, uint8(ds.length));

        if (keccak256(st.registers[Regs.baseIdx(srcReg)]) != keccak256(expected)) revert SurgeryMismatch();
    }

    /// @notice Assert OOB error occurred.
    /// @dev Example: Asserts.oobFailed(errorData);
    /// @param err Error data from revert.
    function oobFailed(bytes memory err) internal pure {
        require(err.length >= 4, 'Error too short');
        bytes4 selector;
        assembly {
            selector := mload(add(err, 32))
        }
        require(selector == VmErrors.OutOfBounds.selector, 'Not OOB error');
    }

    /// @notice Assert too many surgeries error.
    /// @dev Example: Asserts.tooManyFailed(errorData);
    /// @param err Error data from revert.
    function tooManyFailed(bytes memory err) internal pure {
        require(err.length >= 4, 'Error too short');
        bytes4 selector;
        assembly {
            selector := mload(add(err, 32))
        }
        require(selector == VmErrors.TooManySurgeries.selector, 'Not TooMany error');
    }

    /// @notice Assert replacement too large error.
    /// @dev Example: Asserts.replacementTooLargeFailed(errorData);
    /// @param err Error data from revert.
    function replacementTooLargeFailed(bytes memory err) internal pure {
        require(err.length >= 4, 'Error too short');
        bytes4 selector;
        assembly {
            selector := mload(add(err, 32))
        }
        require(selector == VmErrors.ReplacementTooLarge.selector, 'Not ReplacementTooLarge error');
    }

    /// @notice Assert static log emitted.
    /// @dev Example: Asserts.emittedStatic([data1, data2, ...], count);
    /// @param words Expected static data words.
    /// @param count Number of words (1-5).
    function emittedStatic(bytes32[5] memory words, uint256 count) internal {
        Vm vm = TestUtils.getVm();

        if (count == 1) {
            vm.expectEmit(true, true, true, true);
            emit VMLogLib.VMLogStatic1(words[0]);
        } else if (count == 2) {
            vm.expectEmit(true, true, true, true);
            emit VMLogLib.VMLogStatic2(words[0], words[1]);
        } else if (count == 3) {
            vm.expectEmit(true, true, true, true);
            emit VMLogLib.VMLogStatic3(words[0], words[1], words[2]);
        } else if (count == 4) {
            vm.expectEmit(true, true, true, true);
            emit VMLogLib.VMLogStatic4(words[0], words[1], words[2], words[3]);
        } else if (count == 5) {
            vm.expectEmit(true, true, true, true);
            emit VMLogLib.VMLogStatic5(words[0], words[1], words[2], words[3], words[4]);
        } else {
            revert('Invalid static log count');
        }
    }

    /// @notice Assert dynamic log emitted.
    /// @dev Example: Asserts.emittedDynamic(expectedData);
    /// @param expected Expected dynamic log data.
    function emittedDynamic(bytes memory expected) internal {
        Vm vm = TestUtils.getVm();
        vm.expectEmit(true, true, true, true);
        emit VMLogLib.VMLogDyn(expected);
    }

    /// @notice Assert any VM log emitted.
    /// @dev Example: Asserts.emitted();
    /// @dev This checks that at least one VM log event was emitted.
    function emitted() internal {
        Vm vm = TestUtils.getVm();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        bytes32 static1Topic = keccak256('VMLogStatic1(bytes32)');
        bytes32 static2Topic = keccak256('VMLogStatic2(bytes32,bytes32)');
        bytes32 static3Topic = keccak256('VMLogStatic3(bytes32,bytes32,bytes32)');
        bytes32 static4Topic = keccak256('VMLogStatic4(bytes32,bytes32,bytes32,bytes32)');
        bytes32 static5Topic = keccak256('VMLogStatic5(bytes32,bytes32,bytes32,bytes32,bytes32)');
        bytes32 dynTopic = keccak256('VMLogDyn(bytes)');

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                bytes32 topic0 = logs[i].topics[0];
                if (
                    topic0 == static1Topic || topic0 == static2Topic || topic0 == static3Topic || topic0 == static4Topic
                        || topic0 == static5Topic || topic0 == dynTopic
                ) {
                    found = true;
                    break;
                }
            }
        }

        require(found, 'No VM log event emitted');
    }
}
