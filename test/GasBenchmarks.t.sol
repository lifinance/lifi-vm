// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType, LogVariant, SurgeryDescriptor } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Bp } from './lib/Bp.sol';
import { Surg } from './lib/Surg.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { EchoContract, ValueChecker, StateChanger } from './lib/Mocks.sol';
import { RegisterHelpers } from '../src/RegisterHelpers.sol';

/// forge-config: default.isolate = true
contract GasBenchmarksTest is SpecTestBase {
    EchoContract echoContract;
    ValueChecker valueChecker;
    StateChanger stateChanger;

    function setUp() public virtual override {
        super.setUp();
        echoContract = new EchoContract();
        valueChecker = new ValueChecker();
        stateChanger = new StateChanger();

        // Set up approvals for benchmarks
        vm.prank(alice);
        mockToken.approve(address(machine), 1000 ether);
    }

    /* ═══════════════════════════ CALL OPCODE BENCHMARKS ═══════════════════════════ */

    function test_call_gas() external {
        test_call(uint8(CallType.CALL));
    }

    function test_call(uint8 callTypeValue) public {
        // Restrict to valid CallType values, excluding DELEGATECALL which is disallowed
        vm.assume(callTypeValue > 0 && callTypeValue <= uint8(CallType.VALUECALL));

        CallType callType = CallType(callTypeValue);

        // Deal 1 eth to the machine for this test
        vm.deal(address(machine), 1 ether);

        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether); // Use register 2 with 1 ether value

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), callType, 1, 0, 2);

        machine.runVM{ value: 1 ether }(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'call');
    }

    function test_staticcall_gas() external {
        test_call(uint8(CallType.STATICCALL));
        vm.snapshotGasLastCall('vmBenchmarks', 'staticcall');
    }

    function test_valuecall_gas() external {
        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('checkValue()');
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 1, 0, 2);

        vm.deal(address(machine), 2 ether);
        machine.runVM{ value: 2 ether }(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'valuecall');
    }

    /* ═══════════════════════════ CALLDATA_BUILD OPCODE BENCHMARK ═══════════════════════════ */

    function test_calldata_build_gas() external {
        test_calldata_build();
    }

    function test_calldata_build() public {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(1000);

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1));
        bytes4 selector = bytes4(keccak256('transfer(address,uint256)'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 2, bp);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'calldataBuild');
    }

    /* ═══════════════════════════ DEPOSIT_APPROVED OPCODE BENCHMARK ═══════════════════════════ */

    function test_deposit_approved_gas() external {
        test_deposit_approved();
    }

    function test_deposit_approved() public {
        VMState memory s0 = Regs.init(2);
        // Set max deposit amount to unlimited
        s0.registers[1] = abi.encode(type(uint256).max);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);

        vm.prank(alice);
        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'depositApproved');
    }

    /* ═══════════════════════════ CALLDATA_SURGERY OPCODE BENCHMARK ═══════════════════════════ */

    function test_calldata_surgery_gas() external {
        test_calldata_surgery();
    }

    function test_calldata_surgery() public {
        VMState memory s0 = Regs.init(4);

        bytes memory originalCalldata = abi.encodeWithSignature('test(uint256,address)', 42, alice);
        s0.registers[0] = TestUtils.prependLength(originalCalldata);
        s0.registers[1] = abi.encode(100);
        s0.registers[2] = abi.encode(bob);

        SurgeryDescriptor[] memory descs = new SurgeryDescriptor[](1);
        descs[0] = Surg.desc(36, 32, 1); // Replace uint256 value at offset 36

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.surgery(0, descs);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'calldataSurgery');
    }

    /* ═══════════════════════════ RETURN OPCODE BENCHMARK ═══════════════════════════ */

    function test_return_gas() external {
        test_return();
    }

    function test_return() public {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode('Hello, World!');

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'return');
    }

    /* ═══════════════════════════ ABI_ENCODE OPCODE BENCHMARK ═══════════════════════════ */

    function test_abi_encode_gas() external {
        test_abi_encode();
    }

    function test_abi_encode() public {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(1000);

        bytes memory bp = abi.encodePacked(Bp.s(0), Bp.s(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.abiEnc(2, bp);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'abiEncode');
    }

    /* ═══════════════════════════ REMAINING_GAS OPCODE BENCHMARK ═══════════════════════════ */

    function test_remaining_gas_gas() external {
        test_remaining_gas();
    }

    function test_remaining_gas() public {
        VMState memory s0 = Regs.init(2);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.gasTo(0);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'remainingGas');
    }

    /* ═══════════════════════════ NATIVE_BALANCE OPCODE BENCHMARK ═══════════════════════════ */

    function test_native_balance_gas() external {
        test_native_balance();
    }

    function test_native_balance() public {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(alice);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.nativeBal(0, 1);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'nativeBalance');
    }

    /* ═══════════════════════════ LOG OPCODE BENCHMARKS ═══════════════════════════ */

    function test_log_static1_gas() external {
        test_log_static1();
    }

    function test_log_static1() public {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(0));

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logStatic1');
    }

    function test_log_static2_gas() external {
        test_log_static2();
    }

    function test_log_static2() public {
        VMState memory s0 = Regs.init(3);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_2), sourceRegs);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logStatic2');
    }

    function test_log_static3_gas() external {
        test_log_static3();
    }

    function test_log_static3() public {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_3), sourceRegs);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logStatic3');
    }

    function test_log_static4_gas() external {
        test_log_static4();
    }

    function test_log_static4() public {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));
        s0.registers[3] = abi.encode(uint256(999));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs = (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184) | (uint256(3) << 176);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_4), sourceRegs);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logStatic4');
    }

    function test_log_static5_gas() external {
        test_log_static5();
    }

    function test_log_static5() public {
        VMState memory s0 = Regs.init(6);
        s0.registers[0] = abi.encode(uint256(42));
        s0.registers[1] = abi.encode(address(alice));
        s0.registers[2] = abi.encode(uint256(0xDEADBEEF));
        s0.registers[3] = abi.encode(uint256(999));
        s0.registers[4] = abi.encode(bytes32('Hello VM'));

        VMCommand[] memory cmds = new VMCommand[](1);
        uint256 sourceRegs =
            (uint256(0) << 200) | (uint256(1) << 192) | (uint256(2) << 184) | (uint256(3) << 176) | (uint256(4) << 168);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.STATIC_5), sourceRegs);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logStatic5');
    }

    function test_log_dynamic_gas() external {
        test_log_dynamic();
    }

    function test_log_dynamic() public {
        VMState memory s0 = Regs.init(2);
        bytes memory dynamicData =
            abi.encode(uint256(42), address(alice), 'Dynamic benchmark data with variable length');
        s0.registers[0] = dynamicData;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.logOp(uint8(LogVariant.DYNAMIC), uint256(0));

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'logDynamic');
    }

    /* ═══════════════════════════ EXPLODE OPCODE BENCHMARKS ═══════════════════════════ */

    function test_explode_gas() external {
        test_explode();
    }

    function test_explode() public {
        // Small all-static explode: 3 destinations, one word each.
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(uint256(1), uint256(2), uint256(3));

        uint8[] memory staticDests = new uint8[](3);
        staticDests[0] = 1;
        staticDests[1] = 2;
        staticDests[2] = 3;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.explode(0, staticDests);

        machine.runVM(cmds, s0);
        vm.snapshotGasLastCall('vmBenchmarks', 'explodeStatic');

        // Worst case: 26 dynamic destinations, exercising the O(n^2) forward rescan.
        uint8 count = 26;
        uint256 headLen = uint256(count) * 32;

        bytes memory src;
        for (uint256 i = 0; i < count; i++) {
            src = abi.encodePacked(src, headLen + i * 32);
        }
        for (uint256 i = 0; i < count; i++) {
            src = abi.encodePacked(src, uint256(0xD00 + i));
        }

        VMState memory sMax = Regs.init(uint256(count) + 1);
        sMax.registers[0] = src;

        uint8[] memory dynDests = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            dynDests[i] = Regs.withDyn(uint8(i + 1));
        }

        VMCommand[] memory cmdsMax = new VMCommand[](1);
        cmdsMax[0] = VmCmd.explode(0, dynDests);

        machine.runVM(cmdsMax, sMax);
        vm.snapshotGasLastCall('vmBenchmarks', 'explodeDynamicMax');
    }

    /* ═══════════════════════════ AS_ADDRESS HELPER BENCHMARK ═══════════════════════════ */

    function test_as_address_gas() external {
        test_as_address();
    }

    function test_as_address() public {
        bytes memory encodedAddress = abi.encode(alice);

        // `asAddress` is `internal pure`, so it creates no call frame. `snapshotGasLastCall` would
        // report the last real call instead - `SpecTestBase.setUp`'s deployments - which is why this
        // figure used to sit in the millions and drift whenever unrelated bytecode changed. Snapshot
        // the code region instead so the number describes the helper.
        vm.startSnapshotGas('vmBenchmarks', 'asAddress');
        address result = RegisterHelpers.asAddress(encodedAddress);
        vm.stopSnapshotGas();

        // Verify the result is correct
        assert(result == alice);
    }
}
