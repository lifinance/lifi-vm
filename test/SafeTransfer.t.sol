// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, SafeTransfer } from '../src/DataModel.sol';
import { CommandPacking } from '../src/CommandPacking.sol';
import { SafeTransferVMLib } from '../src/SafeTransferLib.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { IERC20 } from 'forge-std/interfaces/IERC20.sol';
import { ERC20Mock } from '@openzeppelin/contracts/mocks/token/ERC20Mock.sol';

contract SafeTransferTest is SpecTestBase {
    ERC20Mock public token;
    address public recipient;
    uint256 public transferAmount = 1000 * 10 ** 18;

    function setUp() public virtual override {
        super.setUp();

        // Create mock ERC20 token
        token = new ERC20Mock();
        recipient = address(0x1234);

        vm.label(address(token), 'TestToken');
        vm.label(recipient, 'recipient');

        // Mint tokens to the VM contract for testing
        token.mint(address(machine), 10_000 * 10 ** 18);
    }

    // Tests basic SAFE_TRANSFER execution with successful transfer
    function test_SafeTransfer_BasicSuccess() public withSnapshot {
        VMState memory s0 = Regs.init(4);

        // Setup registers:
        // reg[0] = recipient address
        // reg[1] = transfer amount
        // reg[2] = result (will be set by SAFE_TRANSFER)
        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(transferAmount);

        uint256 initialBalance = token.balanceOf(recipient);
        uint256 initialVMBalance = token.balanceOf(address(machine));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        (VMState memory s1,) = run(cmds, s0);

        // Check token balances
        assertEq(token.balanceOf(recipient), initialBalance + transferAmount, 'Recipient balance should increase');
        assertEq(token.balanceOf(address(machine)), initialVMBalance - transferAmount, 'VM balance should decrease');

        // Check no registers changed (SAFE_TRANSFER doesn't modify registers)
        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests SAFE_TRANSFER with insufficient balance (should revert)
    function test_SafeTransfer_InsufficientBalance() public withSnapshot {
        // Transfer all tokens away first (as the machine)
        vm.startPrank(address(machine));
        token.transfer(alice, token.balanceOf(address(machine)));
        vm.stopPrank();

        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(transferAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        // Should revert due to insufficient balance (VM wraps the error as TransferFailed)
        vm.expectRevert('TransferFailed()');
        run(cmds, s0);
    }

    // Tests SAFE_TRANSFER with invalid address length (should revert)
    function test_SafeTransfer_InvalidAddressLength() public withSnapshot {
        VMState memory s0 = Regs.init(2);

        // Invalid address length (10 bytes instead of 20 or 32)
        s0.registers[0] = abi.encodePacked(uint80(0x123456789));
        s0.registers[1] = abi.encode(transferAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        // Should revert due to invalid register length
        vm.expectRevert();
        run(cmds, s0);
    }

    // Tests SAFE_TRANSFER with invalid amount format (should revert)
    function test_SafeTransfer_InvalidAmountLength() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(recipient);

        // Invalid amount length (16 bytes instead of 32)
        s0.registers[1] = abi.encodePacked(uint128(transferAmount));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        // Should revert due to invalid register length
        vm.expectRevert();
        run(cmds, s0);
    }

    // Tests SAFE_TRANSFER with zero amount
    function test_SafeTransfer_ZeroAmount() public withSnapshot {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(uint256(0));

        uint256 initialBalance = token.balanceOf(recipient);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        (VMState memory s1,) = run(cmds, s0);

        // Check balance unchanged (zero transfer)
        assertEq(token.balanceOf(recipient), initialBalance, 'Balance should remain unchanged');
    }

    // Tests SAFE_TRANSFER with large transfer amount
    function test_SafeTransfer_LargeAmount() public withSnapshot {
        uint256 largeAmount = type(uint128).max;

        // Mint enough tokens for the test
        token.mint(address(machine), largeAmount);

        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(recipient);
        s0.registers[1] = abi.encode(largeAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.safeTransfer(address(token), 0, 1);

        (VMState memory s1,) = run(cmds, s0);

        // Check token was transferred
        assertEq(token.balanceOf(recipient), largeAmount, 'Recipient should receive large amount');
    }
}
