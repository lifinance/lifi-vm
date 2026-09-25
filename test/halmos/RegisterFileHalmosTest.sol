// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test, console } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { RegisterFile } from 'src/RegisterFile.sol';
import { VmConstants } from 'src/VmConstants.sol';
import { TestUtils } from '../lib/TestUtils.sol';

contract RegisterFileHarness {
    using RegisterFile for bytes[];

    function get(bytes[] memory registers, uint8 index) external pure returns (bytes memory) {
        return registers.get(index);
    }

    function set(bytes[] memory registers, uint8 index, bytes memory data) external pure {
        registers.set(index, data);
    }

    function setDynamic(bytes[] memory registers, uint8 index, bytes memory data) external pure {
        registers.setDynamic(index, data);
    }
}

// halmos --contract RegisterFileHalmosTest --loop 100
contract RegisterFileHalmosTest is Test, SymTest {
    using RegisterFile for bytes[];

    RegisterFileHarness private rfh = new RegisterFileHarness();

    function _make_registers(uint8 length) internal pure returns (bytes[] memory registers) {
        registers = new bytes[](length);
        for (uint256 i; i < length; i++) {
            registers[i] = svm.createBytes(32, 'static');
        }
    }

    function _make_dynamic_registers(uint8 length) internal pure returns (bytes[] memory registers) {
        registers = new bytes[](length);
        for (uint8 i; i < length; i++) {
            registers.setDynamic(i, abi.encode(svm.createBytes(i * 32, 'dyn')));
        }
    }

    // Property 1) get(index) returns the correct value
    function check_get_static(bool dyn) external pure {
        bytes[] memory registers = dyn ? _make_dynamic_registers(128) : _make_registers(128);
        for (uint8 i; i < 128; i++) {
            bytes memory val = registers.get(i);
            if (i == VmConstants.VOID_REG) {
                assertEq(val, hex'0000000000000000000000000000000000000000000000000000000000000000');
            } else {
                assertEq(val, registers[i]);
            }
        }
    }

    // Property 2) getStatic(index) returns the correct value or reverts
    function check_getStatic() external pure {
        bytes[] memory registers = _make_registers(128);
        for (uint8 i; i < 128; i++) {
            if (i == VmConstants.VOID_REG) {
                bytes memory val = registers.getStatic(i);
                assertEq(val, hex'0000000000000000000000000000000000000000000000000000000000000000');
            } else {
                bytes memory val = registers.getStatic(i);
                assertEq(val, registers[i]);
            }
        }
    }

    // Property 3) set(index, data) correctly sets the value
    function check_set() external pure {
        bytes[] memory registers = new bytes[](128);
        for (uint256 i; i < 128; i++) {
            if (i != VmConstants.VOID_REG) {
                bytes memory newData = svm.createBytes((1 + i) * 32, 'newData');
                registers.set(uint8(i), newData);
                assertEq(registers[i], newData);
            }
        }
    }

    // Property 4) setDynamic(index, data) correctly sets the value
    function check_setDynamic() external pure {
        bytes[] memory registers = new bytes[](256);
        for (uint256 i = 0; i < 64; i++) {
            bytes memory payload = svm.createBytes(i * 32, 'dyn');
            bytes memory newData = abi.encode(payload);
            registers.setDynamic(uint8(i + 128), newData);
            assertEq(registers.get(uint8(i + 128)), TestUtils.stripLength(abi.encode(payload)), 'get-after-setDynamic');
        }
    }

    // Property 5) get(index) after set(index, data) returns the correct data
    function check_set_then_get() external pure {
        bytes[] memory registers = new bytes[](128);
        for (uint256 i; i < 127; i++) {
            if (i != VmConstants.VOID_REG) {
                bytes memory newData = svm.createBytes((3 + i) * 32, 'newData');
                registers.set(uint8(i), newData);
                bytes memory val = registers.get(uint8(i));
                assertEq(val, newData, 'get-after-set');
            }
        }
    }

    // Property 6) get(index) reverts when index >= registers.length
    function check_get_oob_reverts() external {
        bytes[] memory registers = new bytes[](64);

        uint256 idxSym = svm.createUint(8, 'idx');
        vm.assume(idxSym >= 64 && idxSym != VmConstants.VOID_REG && idxSym != VmConstants.IDX_MASK);

        bytes memory cd = abi.encodeWithSelector(RegisterFileHarness.get.selector, registers, idxSym);
        (bool ok, bytes memory ret) = address(rfh).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), RegisterFile.RegisterIndexOOB.selector, 'selector');
    }

    // Property 7) set(index, data) reverts when index >= registers.length
    function check_set_oob_reverts() external {
        bytes[] memory registers = new bytes[](64);

        uint256 idxSym = svm.createUint(8, 'idx');
        vm.assume(idxSym >= 64 && idxSym != VmConstants.VOID_REG && idxSym != VmConstants.IDX_MASK);

        bytes memory data = svm.createBytes(64, 'data'); // arbitrary payload

        bytes memory cd = abi.encodeWithSelector(RegisterFileHarness.set.selector, registers, idxSym, data);
        (bool ok, bytes memory ret) = address(rfh).call(cd);
        assertTrue(!ok, 'should revert');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), RegisterFile.RegisterIndexOOB.selector, 'selector');
    }

    // Property 8) get(VOID_REG) always returns the 32-byte zero value, regardless of any set operations
    function check_get_void_reg_always_zero() external pure {
        bytes[] memory registers = _make_registers(128);
        bytes memory val = registers.get(VmConstants.VOID_REG);
        assertEq(val, hex'0000000000000000000000000000000000000000000000000000000000000000', 'void-reg-zero');
    }

    // Property 9) set(VOID_REG, data) does not alter the state of any register
    function check_set_void_reg_noop() external pure {
        bytes[] memory registers = _make_registers(128);

        // Snapshot the state
        bytes[] memory before = new bytes[](128);
        for (uint256 i; i < 128; i++) {
            before[i] = registers[i];
        }

        bytes memory garbage = svm.createBytes(96, 'garbage');
        registers.set(VmConstants.VOID_REG, garbage);

        for (uint256 i; i < 128; i++) {
            assertEq(registers[i], before[i], 'void-set mutated state');
        }
    }

    // Property 10) setDynamic rejects payloads shorter than 64 bytes (ABI offset + length)
    function check_setDynamic_short_payload_reverts() external {
        bytes[] memory registers = _make_dynamic_registers(1);

        for (uint256 i; i < 64; i++) {
            bytes memory short = svm.createBytes(i, 'short');
            bytes memory cd = abi.encodeWithSelector(RegisterFileHarness.setDynamic.selector, registers, 0, short);
            (bool ok, bytes memory ret) = address(rfh).call(cd);
            assertTrue(!ok, 'should revert');
            assertGe(ret.length, 4, 'ret.len');
            assertEq(bytes4(ret), RegisterFile.InvalidDynamicData.selector, 'selector');
        }
    }
}
