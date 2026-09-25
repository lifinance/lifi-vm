// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { CommandPacking } from 'src/CommandPacking.sol';
import { SafeTransferVMLib } from 'src/SafeTransferLib.sol';
import { SafeTransfer } from 'src/DataModel.sol';
import { VmErrors } from 'src/VmErrors.sol';
import { IERC20 } from 'src/interfaces/IERC20.sol';
import { MinimalERC20 } from './mocks/MinimalERC20.sol';

// Harness to expose SafeTransferVMLib for revert testing
contract SafeTransferHarness {
    function executeSafeTransfer(bytes[] memory registers, address token, uint8 toReg, uint8 amountReg) external {
        SafeTransfer memory cmd = SafeTransfer({ token: token, toReg: toReg, amountReg: amountReg });
        SafeTransferVMLib.execute(registers, cmd);
    }
}

// halmos --contract SafeTransferHalmosTest --loop 100
contract SafeTransferHalmosTest is Test, SymTest {
    SafeTransferHarness private h = new SafeTransferHarness();

    // Property ST-1: SafeTransfer pack/unpack roundtrip preserves all fields
    function check_safeTransfer_roundtrip(address token, uint8 toReg, uint8 amountReg) external pure {
        // Pack the SafeTransfer command
        bytes32 packed = CommandPacking.packSafeTransfer(token, toReg, amountReg);

        // Unpack it back
        SafeTransfer memory unpacked = CommandPacking.unpackSafeTransfer(packed);

        // Assert all fields are preserved
        assertEq(unpacked.token, token, 'token preserved in roundtrip');
        assertEq(unpacked.toReg, toReg, 'toReg preserved in roundtrip');
        assertEq(unpacked.amountReg, amountReg, 'amountReg preserved in roundtrip');
    }

    // Property ST-2: SafeTransfer execution with valid registers transfers tokens
    function check_safeTransfer_execution_success(
        uint256 initialBalance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure meaningful test conditions
        vm.assume(initialBalance >= transferAmount);
        vm.assume(transferAmount > 0);
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(this));
        vm.assume(recipient != address(h));

        MinimalERC20 token = new MinimalERC20();

        // Setup: mint tokens to harness (simulating VM holding tokens)
        token.mint(address(h), initialBalance);

        // Setup registers with valid data
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient); // toReg = 0
        registers[1] = abi.encode(transferAmount); // amountReg = 1

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 senderBalanceBefore = token.balanceOf(address(h));

        // Execute the SafeTransfer via harness
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Verify the transfer occurred correctly
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + transferAmount, 'recipient balance increased');
        assertEq(token.balanceOf(address(h)), senderBalanceBefore - transferAmount, 'sender balance decreased');
    }

    // Property ST-3: SafeTransfer with insufficient balance should revert
    function check_safeTransfer_insufficient_balance_reverts(
        uint256 balance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure insufficient balance condition
        vm.assume(balance < transferAmount);
        vm.assume(transferAmount > 0);
        vm.assume(recipient != address(0));

        MinimalERC20 token = new MinimalERC20();

        // Setup: mint insufficient tokens to harness
        token.mint(address(h), balance);

        // Setup registers
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(transferAmount);

        // Use low-level call to check for specific revert (following CommandPacking pattern)
        bytes memory callData =
            abi.encodeWithSelector(SafeTransferHarness.executeSafeTransfer.selector, registers, address(token), 0, 1);

        (bool success, bytes memory returnData) = address(h).call(callData);
        assertTrue(!success, 'should revert');
        assertGe(returnData.length, 4, 'returnData.length');
        // Solady's SafeTransferLib throws TransferFailed()
        assertEq(bytes4(returnData), bytes4(keccak256('TransferFailed()')), 'expected TransferFailed selector');
    }

    // Property ST-4: SafeTransfer with invalid address length should revert
    function check_safeTransfer_invalid_address_reverts() external {
        MinimalERC20 token = new MinimalERC20();
        token.mint(address(h), 1000);

        // Setup registers with invalid address length (10 bytes instead of 32)
        bytes[] memory registers = new bytes[](2);
        registers[0] = svm.createBytes(10, 'badAddr'); // Invalid address length
        registers[1] = abi.encode(uint256(100));

        // Use low-level call to check for specific revert
        bytes memory callData =
            abi.encodeWithSelector(SafeTransferHarness.executeSafeTransfer.selector, registers, address(token), 0, 1);

        (bool success, bytes memory returnData) = address(h).call(callData);
        assertTrue(!success, 'should revert');
        assertGe(returnData.length, 4, 'returnData.length');
        assertEq(bytes4(returnData), VmErrors.InvalidAddressBytes.selector, 'expected InvalidAddressBytes selector');
    }

    // Property ST-5: SafeTransfer with zero amount succeeds without transfer
    function check_safeTransfer_zero_amount(address recipient, uint256 initialBalance) external {
        // Guard: ensure valid conditions
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(h));
        vm.assume(initialBalance > 0);

        MinimalERC20 token = new MinimalERC20();
        token.mint(address(h), initialBalance);

        // Setup registers with zero amount
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(uint256(0));

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 senderBalanceBefore = token.balanceOf(address(h));

        // Execute SafeTransfer with zero amount
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Verify no tokens moved
        assertEq(token.balanceOf(recipient), recipientBalanceBefore, 'recipient balance unchanged for zero transfer');
        assertEq(token.balanceOf(address(h)), senderBalanceBefore, 'sender balance unchanged for zero transfer');
    }

    // Property ST-6: SafeTransfer with FOT (fee-on-transfer) behavior
    function check_safeTransfer_fot_behavior(
        uint256 initialBalance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure meaningful test conditions
        vm.assume(initialBalance >= transferAmount);
        vm.assume(transferAmount > 100); // Need enough for 1% fee
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(this));
        vm.assume(recipient != address(h));

        MinimalERC20 token = new MinimalERC20();
        token.setBehavior(MinimalERC20.Behavior.FOT);

        // Setup: mint tokens to harness
        token.mint(address(h), initialBalance);

        // Setup registers
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(transferAmount);

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 senderBalanceBefore = token.balanceOf(address(h));

        // Execute the SafeTransfer
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Calculate expected fee (1% of transfer amount)
        uint256 expectedFee = transferAmount * 1 / 100;
        uint256 expectedReceivedAmount = transferAmount - expectedFee;

        // Verify FOT behavior - recipient receives less due to fee
        assertEq(
            token.balanceOf(recipient),
            recipientBalanceBefore + expectedReceivedAmount,
            'recipient received amount minus fee'
        );
        assertEq(
            token.balanceOf(address(h)), senderBalanceBefore - transferAmount, 'sender balance decreased by full amount'
        );
    }

    // Property ST-7: SafeTransfer with NO_RETURN behavior
    function check_safeTransfer_no_return_behavior(
        uint256 initialBalance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure meaningful test conditions
        vm.assume(initialBalance >= transferAmount);
        vm.assume(transferAmount > 0);
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(this));
        vm.assume(recipient != address(h));

        MinimalERC20 token = new MinimalERC20();
        token.setBehavior(MinimalERC20.Behavior.NO_RETURN);

        // Setup: mint tokens to harness
        token.mint(address(h), initialBalance);

        // Setup registers
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(transferAmount);

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 senderBalanceBefore = token.balanceOf(address(h));

        // Execute SafeTransfer - Solady's SafeTransferLib should handle no return
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Verify the transfer occurred correctly despite no return value
        assertEq(
            token.balanceOf(recipient),
            recipientBalanceBefore + transferAmount,
            'recipient balance increased with no-return token'
        );
        assertEq(
            token.balanceOf(address(h)),
            senderBalanceBefore - transferAmount,
            'sender balance decreased with no-return token'
        );
    }

    // Property ST-8: SafeTransfer with FALSE_ON_FAILURE behavior - insufficient balance
    function check_safeTransfer_false_on_failure_insufficient_balance(
        uint256 balance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure insufficient balance condition
        vm.assume(balance < transferAmount);
        vm.assume(transferAmount > 0);
        vm.assume(recipient != address(0));

        MinimalERC20 token = new MinimalERC20();
        token.setBehavior(MinimalERC20.Behavior.FALSE_ON_FAILURE);

        // Setup: mint insufficient tokens to harness
        token.mint(address(h), balance);

        // Setup registers
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(transferAmount);

        // Use low-level call to check for revert
        bytes memory callData =
            abi.encodeWithSelector(SafeTransferHarness.executeSafeTransfer.selector, registers, address(token), 0, 1);

        (bool success, bytes memory returnData) = address(h).call(callData);
        // Solady's SafeTransferLib should detect the false return and revert
        assertTrue(!success, 'should revert on false return');
        assertGe(returnData.length, 4, 'returnData.length');
        assertEq(bytes4(returnData), bytes4(keccak256('TransferFailed()')), 'expected TransferFailed selector');
    }

    // Property ST-9: SafeTransfer with all behaviors (symbolic testing)
    function check_safeTransfer_all_behaviors(
        MinimalERC20.Behavior behavior,
        uint256 initialBalance,
        uint256 transferAmount,
        address recipient
    )
        external
    {
        // Guard: ensure meaningful test conditions
        vm.assume(initialBalance >= transferAmount);
        vm.assume(transferAmount > 100); // Need enough for potential 1% fee
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(this));
        vm.assume(recipient != address(h));

        MinimalERC20 token = new MinimalERC20();
        token.setBehavior(behavior);

        // Setup: mint tokens to harness
        token.mint(address(h), initialBalance);

        // Setup registers
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(recipient);
        registers[1] = abi.encode(transferAmount);

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 senderBalanceBefore = token.balanceOf(address(h));

        // Execute SafeTransfer
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Verify transfer occurred
        assertEq(
            token.balanceOf(address(h)),
            senderBalanceBefore - transferAmount,
            'sender balance decreased for all behaviors'
        );

        // Check recipient balance based on behavior
        if (behavior == MinimalERC20.Behavior.FOT) {
            uint256 expectedFee = transferAmount * 1 / 100;
            assertEq(
                token.balanceOf(recipient),
                recipientBalanceBefore + transferAmount - expectedFee,
                'recipient received amount minus fee for FOT'
            );
        } else {
            assertEq(
                token.balanceOf(recipient),
                recipientBalanceBefore + transferAmount,
                'recipient received full amount for non-FOT'
            );
        }
    }

    // Property ST-10: SafeTransfer to self (harness transfers to itself)
    function check_safeTransfer_to_self(uint256 initialBalance, uint256 transferAmount) external {
        // Guard: ensure meaningful test conditions
        vm.assume(initialBalance >= transferAmount);
        vm.assume(transferAmount > 0);

        MinimalERC20 token = new MinimalERC20();

        // Setup: mint tokens to harness
        token.mint(address(h), initialBalance);

        // Setup registers - recipient is the harness itself
        bytes[] memory registers = new bytes[](2);
        registers[0] = abi.encode(address(h)); // toReg points to harness
        registers[1] = abi.encode(transferAmount);

        uint256 harnessBalanceBefore = token.balanceOf(address(h));

        // Execute SafeTransfer to self
        h.executeSafeTransfer(registers, address(token), 0, 1);

        // Balance should remain the same for self-transfer
        assertEq(token.balanceOf(address(h)), harnessBalanceBefore, 'balance unchanged for self-transfer');
    }
}
