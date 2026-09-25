// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { StorageSlots } from 'src/StorageSlots.sol';
import { VirtualMachine } from 'src/VirtualMachine.sol';
import { MinimalProxy } from 'src/proxy/MinimalProxy.sol';
import { CommandPacking } from 'src/CommandPacking.sol';
import { DepositApproved, VMCommand, VMState, OP } from 'src/DataModel.sol';
import { MinimalERC20 } from './mocks/MinimalERC20.sol';

// halmos --contract MinimalProxyAccessHalmosTest --loop 100
contract MinimalProxyAccessHalmosTest is Test, SymTest {
    address constant OWNER = address(0xA11CE);
    address constant FACTORY = address(0xFAC);
    address constant CALLER = address(0xCA11E);

    VirtualMachine vm_;
    MinimalProxy proxy;
    MinimalERC20 token;

    function setUp() public {
        vm_ = new VirtualMachine();
        proxy = new MinimalProxy(OWNER, address(vm_), FACTORY);
        token = new MinimalERC20();
    }

    function _buildDepositCall(address tkn) internal pure returns (bytes memory) {
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({
            op: OP.DEPOSIT_APPROVED,
            data: CommandPacking.packDepositApproved(DepositApproved({ token: tkn, destReg: 0, maxDepositReg: 1 }))
        });

        VMState memory state;
        state.registers = new bytes[](2);
        state.registers[1] = abi.encode(type(uint256).max);

        return abi.encodeWithSelector(VirtualMachine.runVM.selector, cmds, state);
    }

    // Property 1) DEPOSIT_APPROVED through proxy pulls tokens from owner (OWNER_SLOT)
    function check_proxy_deposit_pulls_from_owner() external {
        uint256 amount = 100e18;

        token.mint(OWNER, amount);
        vm.prank(OWNER);
        token.approve(address(proxy), amount);

        bytes memory callData = _buildDepositCall(address(token));
        vm.prank(OWNER);
        (bool ok,) = address(proxy).call(callData);

        assertTrue(ok, 'call must succeed');
        assertEq(token.balanceOf(OWNER), 0, 'owner tokens drained');
        assertEq(token.balanceOf(address(proxy)), amount, 'proxy received tokens');
    }

    // Property 2) DEPOSIT_APPROVED on VM directly pulls tokens from msg.sender
    function check_direct_deposit_pulls_from_caller() external {
        uint256 amount = 100e18;

        token.mint(CALLER, amount);
        vm.prank(CALLER);
        token.approve(address(vm_), amount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VMCommand({
            op: OP.DEPOSIT_APPROVED,
            data: CommandPacking.packDepositApproved(
                DepositApproved({ token: address(token), destReg: 0, maxDepositReg: 1 })
            )
        });

        VMState memory state;
        state.registers = new bytes[](2);
        state.registers[1] = abi.encode(type(uint256).max);

        vm.prank(CALLER);
        vm_.runVM(cmds, state);

        assertEq(token.balanceOf(CALLER), 0, 'caller tokens drained');
        assertEq(token.balanceOf(address(vm_)), amount, 'vm received tokens');
    }

    // Property 3) After factory init consumed, only owner can call the proxy
    function check_only_owner_can_call(address caller) external {
        vm.assume(caller != address(0));

        bytes memory dummyCall =
            abi.encodeWithSelector(VirtualMachine.runVM.selector, new VMCommand[](0), VMState(new bytes[](0)));
        vm.prank(FACTORY);
        (bool initOk,) = address(proxy).call(dummyCall);
        assertTrue(initOk, 'factory init must succeed');

        vm.prank(caller);
        (bool ok,) = address(proxy).call(dummyCall);

        if (caller == OWNER) {
            assertTrue(ok, 'owner must succeed');
        } else {
            assertFalse(ok, 'non-owner must fail');
        }
    }
}
