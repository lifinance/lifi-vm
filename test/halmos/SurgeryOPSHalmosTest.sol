// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test, console } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { RegisterHelpers } from 'src/RegisterHelpers.sol';
import { RegisterFile } from 'src/RegisterFile.sol';
import { VMState, SurgeryDescriptor } from 'src/DataModel.sol';
import { SurgeryOps } from 'src/SurgeryOPS.sol';
import { Regs } from '../lib/Regs.sol';

// halmos --contract SurgeryOPSHalmosTest --loop 100
contract SurgeryOPSHalmosTest is Test, SymTest {
    using RegisterHelpers for uint8;
    using RegisterFile for bytes[];

    // Helper to clone a bytes array (value copy)
    function _clone(bytes memory src) internal pure returns (bytes memory dst) {
        uint256 n = src.length;
        dst = new bytes(n);
        for (uint256 i; i < n; ++i) {
            dst[i] = src[i];
        }
    }

    // Helper to create a surgery descriptor with valid constraints
    function _make_surgery_descriptor(
        uint8[] memory lengths,
        uint8 sourceReg
    )
        internal
        pure
        returns (SurgeryDescriptor memory serg)
    {
        uint256 targetReg = svm.createUint(8, 'replacementReg');
        vm.assume(sourceReg >= targetReg); // sourceReg.length must be >= replacementReg.length

        for (uint8 rr; rr < lengths.length; rr++) {
            if (rr == targetReg) {
                if (lengths[sourceReg] == lengths[rr]) {
                    return SurgeryDescriptor({
                        offset: 0, // it can only be 0
                        length: lengths[rr], // it can only be targetReg length
                        replacementReg: uint8(rr)
                    });
                }
                uint8 diff = uint8(lengths[sourceReg] - lengths[rr]); // concrete
                uint256 offSym = svm.createUint(8, 'offset');
                vm.assume(offSym < diff);
                for (uint8 off; off < lengths[sourceReg] - 32; off++) {
                    if (off == offSym) {
                        uint256 lenSym = svm.createUint(8, 'length');
                        vm.assume(lenSym >= lengths[rr] && lenSym < lengths[rr] + diff - off);
                        for (uint256 len = lengths[rr]; len < lengths[rr] + diff - off; len++) {
                            if (len == lenSym) {
                                return SurgeryDescriptor({
                                    offset: uint8(off), length: uint8(len), replacementReg: uint8(rr)
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    // Property 1: Checks that the surgery effect matches the specification
    // 1) Length unchanged
    // 2) Outside all windows, bytes must be unchanged
    // 3) Inside each window, content equals zero-left padding then replacement right-aligned
    //    (the replacement must fit inside the window, i.e. replacement.length <= window.length)
    function check_perform_surgery(uint8 sourceReg, uint8 surgeryCount) external pure {
        vm.assume(surgeryCount < 7);
        vm.assume(sourceReg < 10);
        uint8[] memory lengths = new uint8[](10);
        bytes[] memory registers = new bytes[](10);
        for (uint256 i; i < 10; i++) {
            registers[i] = svm.createBytes((i / 2 + 1) * 32, 'register'); // 32 32 64 64 96 96 128 128
            lengths[i] = uint8((i / 2 + 1) * 32);
        }
        VMState memory st = VMState({ registers: registers });
        SurgeryDescriptor[6] memory surgeries;

        for (uint8 i; i < registers.length; i++) {
            if (i == sourceReg) {
                for (uint8 j; j < surgeryCount; j++) {
                    surgeries[j] = _make_surgery_descriptor(lengths, i);
                }
                bytes memory beforeBytes = _clone(st.registers[i]);
                SurgeryOps.performSurgery(st.registers, i, surgeries, surgeryCount);
                bytes memory afterBytes = st.registers[i];

                // 1) Length unchanged
                assertEq(afterBytes.length, beforeBytes.length, 'surgery must not change length');

                // 2) Outside all windows, bytes must be unchanged
                bool[] memory inWindow = new bool[](afterBytes.length);
                for (uint8 j; j < surgeryCount; j++) {
                    SurgeryDescriptor memory d3 = surgeries[j];
                    uint256 off = d3.offset;
                    uint256 len = d3.length;
                    for (uint256 t; t < len; t++) {
                        inWindow[off + t] = true;
                    }
                }
                for (uint256 p; p < afterBytes.length; p++) {
                    if (!inWindow[p]) {
                        assertEq(afterBytes[p], beforeBytes[p], 'bytes outside windows must remain unchanged');
                    }
                }

                // 3) Inside each window, content equals zero-left padding then replacement right-aligned
                // Build the expected result by applying the surgeries on a local copy
                bytes memory expected = _clone(beforeBytes);
                for (uint8 j; j < surgeryCount; j++) {
                    SurgeryDescriptor memory surg = surgeries[j];
                    uint256 off = surg.offset;
                    uint256 len = surg.length;
                    bytes memory rr = st.registers[surg.replacementReg.idx()];
                    uint256 rlen = rr.length;

                    // Replacement must fit inside the window (same condition as performSurgery)
                    assertTrue(rlen <= len, 'replacement must fit in window');
                    uint256 pad = len - rlen; // zero-left padding size

                    // Zero-left padding inside the window
                    for (uint256 k; k < pad; k++) {
                        expected[off + k] = bytes1(0);
                    }
                    // Right-aligned replacement bytes
                    for (uint256 k; k < rlen; k++) {
                        expected[off + pad + k] = rr[k];
                    }
                }

                // Final check: afterBytes must match the deterministically computed expected result
                assertEq(afterBytes, expected, 'afterBytes must equal expected surgery result');
            }
        }
    }

    /// CLAMPED PROPERTIES ///
    function check_performingNoSurgeryIsIdempotent(bytes[] memory registerData) public {
        VMState memory vmState = Regs.init(registerData.length);

        for (uint256 i = 0; i < registerData.length; i++) {
            vmState.registers[i] = registerData[i];
        }

        SurgeryDescriptor[6] memory surgeries;
        uint8 surgeryCount = 0;
        SurgeryOps.performSurgery(vmState.registers, 0, surgeries, surgeryCount);

        for (uint256 i = 0; i < registerData.length; i++) {
            assertEq(vmState.registers[i], registerData[i]);
        }
    }

    // TODO: Replacement logic
    // After we replace the data, we want to verify that the change is correct
    // Perhaps let's start with basic stuff such as replacin the last byte
    function check_replaceTheEntireObject(bytes32 data, bytes32 dataReplacement) public {
        VMState memory vmState = Regs.init(2);
        vmState.registers[0] = abi.encodePacked(abi.encode(data));
        vmState.registers[1] = abi.encodePacked(abi.encode(dataReplacement));

        SurgeryDescriptor[6] memory surgeries;
        surgeries[0].offset = 0;
        surgeries[0].length = 32;
        surgeries[0].replacementReg = 1;

        uint8 surgeryCount = 1;
        SurgeryOps.performSurgery(vmState.registers, 0, surgeries, surgeryCount);

        assertEq(vmState.registers[0], abi.encode(dataReplacement));
    }

    function check_replaceTheEntireObject_dynamic(bytes32 data, bytes32 dataReplacement) public {
        VMState memory vmState = Regs.init(2);
        vmState.registers[0] = abi.encode(abi.encode(data));
        vmState.registers[1] = abi.encode(abi.encode(dataReplacement));

        SurgeryDescriptor[6] memory surgeries;
        surgeries[0].offset = 0;
        surgeries[0].length = 96;
        surgeries[0].replacementReg = 1;

        uint8 surgeryCount = 1;
        SurgeryOps.performSurgery(vmState.registers, 0, surgeries, surgeryCount);

        assertEq(vmState.registers[0], abi.encode(abi.encode(dataReplacement)));
    }

    function check_replaceTheLastByte(bytes32 data, bytes32 dataReplacement) public {
        VMState memory vmState = Regs.init(2);
        vmState.registers[0] = abi.encode(data);
        vmState.registers[1] = abi.encodePacked(abi.encode(dataReplacement)[0]);

        console.log('vmState.registers[1].length', vmState.registers[1].length);

        SurgeryDescriptor[6] memory surgeries;
        surgeries[0].offset = 31;
        surgeries[0].length = 1;
        surgeries[0].replacementReg = 1;

        uint8 surgeryCount = 1;
        SurgeryOps.performSurgery(vmState.registers, 0, surgeries, surgeryCount);

        console.logBytes(vmState.registers[0]);
        console.logBytes(abi.encode(dataReplacement));

        assertEq(vmState.registers[0].length, 32);
        assertEq(vmState.registers[0][31], dataReplacement[0]);
    }

    function check_zeroOutThroughEmptyByte(bytes32 data) public {
        VMState memory vmState = Regs.init(2);
        vmState.registers[0] = abi.encode(data);
        vmState.registers[1] = abi.encodePacked(hex'00');

        console.log('vmState.registers[1].length', vmState.registers[1].length);

        SurgeryDescriptor[6] memory surgeries;
        surgeries[0].offset = 0;
        surgeries[0].length = 32;
        surgeries[0].replacementReg = 1;

        uint8 surgeryCount = 1;
        SurgeryOps.performSurgery(vmState.registers, 0, surgeries, surgeryCount);

        console.logBytes(vmState.registers[0]);

        assertEq(vmState.registers[0].length, 32);
        assertEq(vmState.registers[0], abi.encode(bytes32(0)));
    }
}
