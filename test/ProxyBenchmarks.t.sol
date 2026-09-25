// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { EchoContract, ValueChecker, StateChanger } from './lib/Mocks.sol';
import { MinimalProxy } from '../src/proxy/MinimalProxy.sol';
import { ProxyFactory } from '../src/proxy/ProxyFactory.sol';
import { CreateXScript } from 'createx-forge/script/CreateXScript.sol';
import { CREATEX_ADDRESS } from 'createx-forge/script/CreateX.d.sol';

/// forge-config: default.isolate = true
contract ProxyBenchmarksTest is SpecTestBase, CreateXScript {
    ProxyFactory proxyFactory;
    MinimalProxy aliceProxy;
    MinimalProxy bobProxy;

    EchoContract echoContract;
    ValueChecker valueChecker;
    StateChanger stateChanger;

    function setUp() public virtual override withCreateX {
        super.setUp();

        // Deploy test contracts
        echoContract = new EchoContract();
        valueChecker = new ValueChecker();
        stateChanger = new StateChanger();

        // Deploy proxy factory
        proxyFactory = new ProxyFactory(address(machine), CREATEX_ADDRESS);
        vm.label(address(proxyFactory), 'ProxyFactory');

        // Deploy proxies for alice and bob
        aliceProxy = MinimalProxy(payable(proxyFactory.deployProxy(alice)));
        bobProxy = MinimalProxy(payable(proxyFactory.deployProxy(bob)));
        vm.label(address(aliceProxy), 'AliceProxy');
        vm.label(address(bobProxy), 'BobProxy');

        // Set up approvals for benchmarks
        vm.prank(alice);
        mockToken.approve(address(machine), 1000 ether);
        vm.prank(alice);
        mockToken.approve(address(aliceProxy), 1000 ether);
    }

    /* ═══════════════════════════ HELPER FUNCTIONS ═══════════════════════════ */

    /**
     * @dev Helper to make proxy call
     */
    function callThroughProxy(
        MinimalProxy proxy,
        VMCommand[] memory commands,
        VMState memory initialState,
        uint256 value,
        address caller
    )
        internal
    {
        vm.prank(caller);
        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, commands, initialState);
        (bool success,) = address(proxy).call{ value: value }(callData);
        require(success, 'Proxy call failed');
    }

    /* ═══════════════════════════ SIMPLE RETURN BENCHMARKS ═══════════════════════════ */

    function test_direct_simple_return() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        machine.runVM(cmds, s0);
    }

    function test_proxy_simple_return() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }

    function test_proxy_unauthorized_call() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        // Test unauthorized call (should revert)
        vm.prank(address(0xDEAD)); // Unauthorized caller
        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);
        vm.expectRevert();
        (bool success,) = address(aliceProxy).call(callData);
    }

    /* ═══════════════════════════ CALL OPERATION BENCHMARKS ═══════════════════════════ */

    function test_direct_call_operation() external {
        vm.deal(address(machine), 1 ether);

        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, 1, 0, 2);

        machine.runVM{ value: 1 ether }(cmds, s0);
    }

    function test_proxy_call_operation() external {
        vm.deal(address(aliceProxy), 1 ether);

        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, 1, 0, 2);

        callThroughProxy(aliceProxy, cmds, s0, 1 ether, alice);
    }

    function test_direct_valuecall_operation() external {
        vm.deal(address(machine), 2 ether);

        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('checkValue()');
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 1, 0, 2);

        machine.runVM{ value: 2 ether }(cmds, s0);
    }

    function test_proxy_valuecall_operation() external {
        vm.deal(address(aliceProxy), 2 ether);

        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('checkValue()');
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 1, 0, 2);

        callThroughProxy(aliceProxy, cmds, s0, 2 ether, alice);
    }

    /* ═══════════════════════════ DEPOSIT_APPROVED BENCHMARK ═══════════════════════════ */

    function test_direct_deposit_approved() external {
        VMState memory s0 = Regs.init(2);
        // Set max deposit amount to unlimited
        s0.registers[1] = abi.encode(type(uint256).max);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);

        vm.prank(alice);
        machine.runVM(cmds, s0);
    }

    function test_proxy_deposit_approved() external {
        VMState memory s0 = Regs.init(2);
        // Set max deposit amount to unlimited
        s0.registers[1] = abi.encode(type(uint256).max);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);

        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }

    /* ═══════════════════════════ CALLDATA_BUILD BENCHMARK ═══════════════════════════ */

    function test_direct_calldata_build() external {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(1000);

        bytes memory bp = abi.encodePacked(uint8(0), uint8(1));
        bytes4 selector = bytes4(keccak256('transfer(address,uint256)'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 2, bp);

        machine.runVM(cmds, s0);
    }

    function test_proxy_calldata_build() external {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(1000);

        bytes memory bp = abi.encodePacked(uint8(0), uint8(1));
        bytes4 selector = bytes4(keccak256('transfer(address,uint256)'));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.cdb(selector, 2, bp);

        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }

    /* ═══════════════════════════ MULTI-COMMAND BENCHMARK ═══════════════════════════ */

    function test_direct_multi_command_flow() external {
        VMState memory s0 = Regs.init(8);

        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(100 ether);
        // Set max deposit amount to unlimited
        s0.registers[7] = abi.encode(type(uint256).max);

        bytes memory bp = abi.encodePacked(uint8(0), uint8(1));
        bytes4 selector = bytes4(keccak256('transfer(address,uint256)'));

        bytes memory callData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[4] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 2, 7);
        cmds[1] = VmCmd.cdb(selector, 3, bp);
        cmds[2] = VmCmd.call(address(echoContract), CallType.CALL, 5, 4, 6);
        cmds[3] = VmCmd.ret(5);

        vm.prank(alice);
        machine.runVM(cmds, s0);
    }

    function test_proxy_multi_command_flow() external {
        VMState memory s0 = Regs.init(8);

        s0.registers[0] = abi.encode(alice);
        s0.registers[1] = abi.encode(100 ether);
        // Set max deposit amount to unlimited
        s0.registers[7] = abi.encode(type(uint256).max);

        bytes memory bp = abi.encodePacked(uint8(0), uint8(1));
        bytes4 selector = bytes4(keccak256('transfer(address,uint256)'));

        bytes memory callData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[4] = TestUtils.prependLength(callData);

        VMCommand[] memory cmds = new VMCommand[](4);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 2, 7);
        cmds[1] = VmCmd.cdb(selector, 3, bp);
        cmds[2] = VmCmd.call(address(echoContract), CallType.CALL, 5, 4, 6);
        cmds[3] = VmCmd.ret(5);

        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }

    /* ═══════════════════════════ REENTRANCY GUARD SPECIFIC TESTS ═══════════════════════════ */

    function test_proxy_reentrancy_first_call() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(123));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }

    function test_proxy_reentrancy_second_call() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(123));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        // Call twice to ensure reentrancy guard resets properly
        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
        callThroughProxy(aliceProxy, cmds, s0, 0, alice);
    }
}
