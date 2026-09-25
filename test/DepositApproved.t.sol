// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Asserts } from './lib/Asserts.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { IERC20 } from '../src/interfaces/IERC20.sol';

/// @notice Mock non-standard ERC20 token that doesn't return a boolean from transferFrom
/// This simulates the behavior of tokens like USDT that don't follow the ERC20 standard
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = 'Tether USD';
    string public symbol = 'USDT';
    uint8 public decimals = 6;
    uint256 public totalSupply;

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    /// @notice transferFrom without return value to test non-standard ERC20 implementations
    function transferFrom(address sender, address recipient, uint256 amount) external {
        require(balanceOf[sender] >= amount, 'Insufficient balance');

        // Only check and update allowance if sender != msg.sender
        if (sender != msg.sender) {
            require(allowance[sender][msg.sender] >= amount, 'Insufficient allowance');
            allowance[sender][msg.sender] -= amount;
        }
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        // No return statement - key difference from standard ERC20
    }
}

/// @notice Mock token that returns false on failed transfers
contract MockTokenWithFalseReturn is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool public shouldFail = false;

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        if (shouldFail) {
            // Return false to indicate failure
            return false;
        }

        require(balanceOf[sender] >= amount, 'Insufficient balance');

        if (sender != msg.sender) {
            require(allowance[sender][msg.sender] >= amount, 'Insufficient allowance');
            allowance[sender][msg.sender] -= amount;
        }
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;

        return true;
    }
}

/// @notice Mock fee-on-transfer token that charges a fee on every transfer
contract MockFeeOnTransferToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = 'Fee On Transfer Token';
    string public symbol = 'FOT';
    uint8 public decimals = 18;
    uint256 public totalSupply;

    uint256 public feeRate = 200; // 2% fee (200 basis points)
    uint256 public constant FEE_DENOMINATOR = 10_000;
    address public feeRecipient;

    constructor() {
        feeRecipient = address(0xdead);
    }

    function setFeeRate(uint256 _feeRate) external {
        require(_feeRate <= FEE_DENOMINATOR, 'Fee rate too high');
        feeRate = _feeRate;
    }

    function setFeeRecipient(address _feeRecipient) external {
        feeRecipient = _feeRecipient;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[sender] >= amount, 'Insufficient balance');

        if (sender != msg.sender) {
            require(allowance[sender][msg.sender] >= amount, 'Insufficient allowance');
            allowance[sender][msg.sender] -= amount;
        }

        // Calculate fee
        uint256 fee = (amount * feeRate) / FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Transfer tokens
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amountAfterFee;
        if (fee > 0) {
            balanceOf[feeRecipient] += fee;
        }

        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, 'Insufficient balance');

        // Calculate fee
        uint256 fee = (amount * feeRate) / FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Transfer tokens
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amountAfterFee;
        if (fee > 0) {
            balanceOf[feeRecipient] += fee;
        }

        return true;
    }
}

contract DepositApprovedTest is SpecTestBase {
    MockUSDT internal usdtToken;
    MockTokenWithFalseReturn internal failableToken;
    MockFeeOnTransferToken internal feeToken;

    function setUp() public virtual override {
        super.setUp();
        vm.label(alice, 'alice');
        vm.label(bob, 'bob');

        // Deploy mock non-standard token (USDT-like)
        usdtToken = new MockUSDT();
        vm.label(address(usdtToken), 'MockUSDT');

        // Deploy mock token that can return false
        failableToken = new MockTokenWithFalseReturn();
        vm.label(address(failableToken), 'MockTokenWithFalseReturn');

        // Deploy fee-on-transfer token
        feeToken = new MockFeeOnTransferToken();
        vm.label(address(feeToken), 'MockFeeOnTransferToken');

        // Give alice and bob some USDT (note: USDT has 6 decimals)
        deal(address(usdtToken), alice, 1000 * 10 ** 6);
        deal(address(usdtToken), bob, 1000 * 10 ** 6);

        // Give alice and bob some failable tokens
        deal(address(failableToken), alice, 1000 * 10 ** 18);
        deal(address(failableToken), bob, 1000 * 10 ** 18);

        // Give alice and bob some fee-on-transfer tokens
        deal(address(feeToken), alice, 1000 * 10 ** 18);
        deal(address(feeToken), bob, 1000 * 10 ** 18);
    }

    // Tests that DEPOSIT_APPROVED correctly transfers approved tokens to VM and stores amount in destination register
    function test_DepositApproved_RegisterInspection() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(alice);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        // Alice approves 100 tokens to the VM
        uint256 approvalAmount = 100 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify the deposited amount is stored in the register
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));

        // Verify token balances changed correctly
        assertEq(mockToken.balanceOf(alice), aliceInitialBalance - approvalAmount);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + approvalAmount);

        // Verify approval was consumed
        assertEq(mockToken.allowance(alice, address(machine)), 0);
    }

    // Tests that DEPOSIT_APPROVED correctly handles partial approvals when user has less balance than approval
    function test_DepositApproved_PartialBalance() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Get alice's current balance
        uint256 aliceBalance = mockToken.balanceOf(alice);

        // Alice approves more than her balance
        uint256 approvalAmount = aliceBalance + 100 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        // Transfer most of alice's tokens away, leaving only 50 tokens
        uint256 remainingBalance = 50 * 10 ** 18;
        mockToken.transferFrom(alice, bob, aliceBalance - remainingBalance);

        assertEq(mockToken.balanceOf(alice), remainingBalance);
        assertEq(mockToken.allowance(alice, address(machine)), approvalAmount);

        // Capture VM initial balance
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        // The implementation should transfer only the available balance (50 tokens)
        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify only the available balance was transferred
        Asserts.equalsAbiData(s1.registers[1], abi.encode(remainingBalance));

        // Verify token balances changed correctly
        assertEq(mockToken.balanceOf(alice), 0);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + remainingBalance);

        // Verify the remaining approval (original approval - transferred amount)
        assertEq(mockToken.allowance(alice, address(machine)), approvalAmount - remainingBalance);
    }

    // Tests that DEPOSIT_APPROVED returns 0 when no tokens are approved
    function test_DepositApproved_NoApproval_ReturnsZero() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Ensure no approval exists
        assertEq(mockToken.allowance(alice, address(machine)), 0);

        // Capture initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(alice);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify 0 was stored in the register
        Asserts.equalsAbiData(s1.registers[1], abi.encode(uint256(0)));

        // Verify balances remain unchanged
        assertEq(mockToken.balanceOf(alice), aliceInitialBalance);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance);
    }

    // Tests that DEPOSIT_APPROVED with Bob's approval works correctly
    function test_DepositApproved_BobApproval() public withSnapshot asUser(bob) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 bobInitialBalance = mockToken.balanceOf(bob);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        // Bob approves 250 tokens to the VM
        uint256 approvalAmount = 250 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify the deposited amount is stored in the register
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));

        // Verify token balances changed correctly
        assertEq(mockToken.balanceOf(bob), bobInitialBalance - approvalAmount);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + approvalAmount);

        // Verify approval was consumed
        assertEq(mockToken.allowance(bob, address(machine)), 0);
    }

    // Tests that writing DEPOSIT_APPROVED result to VOID register is discarded
    function test_DepositApproved_WriteToVoid_Ignored() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(alice);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        // Alice approves 100 tokens to the VM
        uint256 approvalAmount = 100 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), Regs.voidReg(), 2);

        (VMState memory s1,) = run(cmds, s0);

        // No registers should change when writing to VOID
        uint8[] memory dests = new uint8[](0);
        Asserts.unchangedExcept(s0, s1, dests);

        // But the token transfer should still happen
        assertEq(mockToken.balanceOf(alice), aliceInitialBalance - approvalAmount);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + approvalAmount);
        assertEq(mockToken.allowance(alice, address(machine)), 0);
    }

    // Tests that DEPOSIT_APPROVED ignores dyn flag when writing to destination register
    function test_DepositApproved_DynFlagIgnored() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Alice approves tokens
        uint256 approvalAmount = 75 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), Regs.withDyn(1), 2);

        (VMState memory s1,) = run(cmds, s0);

        // Amount should be stored as fixed 32-byte word
        assertEq(s1.registers[1].length, 32);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);
    }

    // Tests oracle implementation comparison - deposits match expected behavior
    function test_DepositApproved_OracleComparison() public withSnapshot asUser(alice) {
        // Set up oracle scenario
        uint256 approvalAmount = 123 * 10 ** 18;
        uint256 aliceBalanceBefore = mockToken.balanceOf(alice);
        uint256 vmBalanceBefore = mockToken.balanceOf(address(machine));

        // Alice approves tokens
        mockToken.approve(address(machine), approvalAmount);
        uint256 allowanceAfterApproval = mockToken.allowance(alice, address(machine));
        assertEq(allowanceAfterApproval, approvalAmount);

        // Execute deposit via VM
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        // Oracle expectations:
        // 1. VM balance increases by approved amount
        assertEq(mockToken.balanceOf(address(machine)), vmBalanceBefore + approvalAmount);

        // 2. User balance decreases by approved amount
        assertEq(mockToken.balanceOf(alice), aliceBalanceBefore - approvalAmount);

        // 3. Allowance is consumed (set to 0)
        assertEq(mockToken.allowance(alice, address(machine)), 0);

        // 4. Register contains the deposited amount
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));
    }

    // Tests multiple sequential deposits consume approvals correctly
    function test_DepositApproved_MultipleDeposits() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(4);
        // Set max deposit amount to unlimited
        s0.registers[3] = abi.encode(type(uint256).max);

        // First approval and deposit
        uint256 firstApproval = 50 * 10 ** 18;
        mockToken.approve(address(machine), firstApproval);

        VMCommand[] memory cmds1 = new VMCommand[](1);
        cmds1[0] = VmCmd.depositApproved(address(mockToken), 1, 3);

        (VMState memory s1,) = run(cmds1, s0);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(firstApproval));
        assertEq(mockToken.allowance(alice, address(machine)), 0);

        // Second approval and deposit
        uint256 secondApproval = 75 * 10 ** 18;
        mockToken.approve(address(machine), secondApproval);

        VMCommand[] memory cmds2 = new VMCommand[](1);
        cmds2[0] = VmCmd.depositApproved(address(mockToken), 2, 3);

        (VMState memory s2,) = run(cmds2, s1);
        Asserts.equalsAbiData(s2.registers[2], abi.encode(secondApproval));
        assertEq(mockToken.allowance(alice, address(machine)), 0);

        // Verify total transferred
        assertEq(mockToken.balanceOf(address(machine)), firstApproval + secondApproval);
    }

    // Tests that DEPOSIT_APPROVED handles zero balance gracefully
    function test_DepositApproved_ZeroBalance_ReturnsZero() public withSnapshot asUser(alice) {
        // With the new implementation, having approval but zero balance
        // should result in a successful transfer of 0 tokens

        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        uint256 aliceBalance = mockToken.balanceOf(alice);
        uint256 approvalAmount = aliceBalance + 1000;
        // Approve more than balance
        mockToken.approve(address(machine), approvalAmount);

        // Transfer all tokens away
        mockToken.transferFrom(alice, bob, aliceBalance);
        assertEq(mockToken.balanceOf(alice), 0);

        // Capture VM initial balance
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        // The operation should succeed, transferring 0 tokens
        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify 0 tokens were transferred
        Asserts.equalsAbiData(s1.registers[1], abi.encode(uint256(0)));

        // Verify balances remain unchanged
        assertEq(mockToken.balanceOf(alice), 0);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance);

        // Verify the approval remains unchanged (since 0 was transferred)
        assertEq(mockToken.allowance(alice, address(machine)), approvalAmount);
    }

    /// @notice Test that depositApproved works with non-standard ERC20 tokens that don't return a boolean
    /// This test demonstrates proper handling of tokens like USDT that don't follow the standard interface
    function test_DepositApproved_NonStandardToken_NoReturnValue() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 aliceInitialBalance = usdtToken.balanceOf(alice);
        uint256 vmInitialBalance = usdtToken.balanceOf(address(machine));

        // Alice approves 100 USDT to the VM (6 decimals)
        uint256 approvalAmount = 100 * 10 ** 6;
        usdtToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(usdtToken), 1, 2);

        // This should succeed even though the token doesn't return a boolean
        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify the deposited amount is stored in the register
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));

        // Verify token balances changed correctly
        assertEq(usdtToken.balanceOf(alice), aliceInitialBalance - approvalAmount);
        assertEq(usdtToken.balanceOf(address(machine)), vmInitialBalance + approvalAmount);

        // Verify approval was consumed
        assertEq(usdtToken.allowance(alice, address(machine)), 0);
    }

    /// @notice Test multiple sequential deposits with non-standard token implementation
    function test_DepositApproved_NonStandardToken_MultipleDeposits() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(4);
        // Set max deposit amount to unlimited
        s0.registers[3] = abi.encode(type(uint256).max);

        // First approval and deposit
        uint256 firstApproval = 50 * 10 ** 6; // 50 USDT
        usdtToken.approve(address(machine), firstApproval);

        VMCommand[] memory cmds1 = new VMCommand[](1);
        cmds1[0] = VmCmd.depositApproved(address(usdtToken), 1, 3);

        (VMState memory s1,) = run(cmds1, s0);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(firstApproval));
        assertEq(usdtToken.allowance(alice, address(machine)), 0);

        // Second approval and deposit
        uint256 secondApproval = 75 * 10 ** 6; // 75 USDT
        usdtToken.approve(address(machine), secondApproval);

        VMCommand[] memory cmds2 = new VMCommand[](1);
        cmds2[0] = VmCmd.depositApproved(address(usdtToken), 2, 3);

        (VMState memory s2,) = run(cmds2, s1);
        Asserts.equalsAbiData(s2.registers[2], abi.encode(secondApproval));
        assertEq(usdtToken.allowance(alice, address(machine)), 0);

        // Verify total transferred
        assertEq(usdtToken.balanceOf(address(machine)), firstApproval + secondApproval);
    }

    /// @notice Test that depositApproved with non-standard tokens handles partial balance correctly
    function test_DepositApproved_NonStandardToken_PartialBalance() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Get alice's current USDT balance
        uint256 aliceBalance = usdtToken.balanceOf(alice);

        // Alice approves more than her balance
        uint256 approvalAmount = aliceBalance + 100 * 10 ** 6;
        usdtToken.approve(address(machine), approvalAmount);

        // Transfer most of alice's USDT away, leaving only 25 USDT
        uint256 remainingBalance = 25 * 10 ** 6;
        usdtToken.transferFrom(alice, bob, aliceBalance - remainingBalance);

        assertEq(usdtToken.balanceOf(alice), remainingBalance);
        assertEq(usdtToken.allowance(alice, address(machine)), approvalAmount);

        // Capture VM initial balance
        uint256 vmInitialBalance = usdtToken.balanceOf(address(machine));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(usdtToken), 1, 2);

        // Should transfer only the available balance
        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify only the available balance was transferred
        Asserts.equalsAbiData(s1.registers[1], abi.encode(remainingBalance));

        // Verify token balances changed correctly
        assertEq(usdtToken.balanceOf(alice), 0);
        assertEq(usdtToken.balanceOf(address(machine)), vmInitialBalance + remainingBalance);

        // Verify the remaining approval
        assertEq(usdtToken.allowance(alice, address(machine)), approvalAmount - remainingBalance);
    }

    /// @notice Test that proper error handling when a token returns false
    /// This demonstrates correct behavior with tokens that signal transfer failure
    function test_DepositApproved_TokenReturnsFalse_HandlesCorrectly() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Alice approves tokens
        uint256 approvalAmount = 100 * 10 ** 18;
        failableToken.approve(address(machine), approvalAmount);

        // Set token to fail
        failableToken.setShouldFail(true);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(failableToken), 1, 2);

        // This should revert when the token returns false
        vm.expectRevert();
        run(cmds, s0);
    }

    /// @notice Test that standard tokens still work correctly alongside non-standard implementations
    function test_DepositApproved_StandardTokenCompatibility() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(alice);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        // Alice approves tokens
        uint256 approvalAmount = 150 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        // Verify the transfer succeeded
        Asserts.equalsAbiData(s1.registers[1], abi.encode(approvalAmount));
        assertEq(mockToken.balanceOf(alice), aliceInitialBalance - approvalAmount);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + approvalAmount);
        assertEq(mockToken.allowance(alice, address(machine)), 0);
    }

    /// @notice Test that depositApproved correctly handles fee-on-transfer tokens
    /// The VM should receive less tokens than approved due to the transfer fee
    function test_DepositApproved_FeeOnTransfer_Basic() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Capture initial balances
        uint256 aliceInitialBalance = feeToken.balanceOf(alice);
        uint256 vmInitialBalance = feeToken.balanceOf(address(machine));
        uint256 feeRecipientInitial = feeToken.balanceOf(address(0xdead));

        // Alice approves 100 tokens to the VM
        uint256 approvalAmount = 100 * 10 ** 18;
        feeToken.approve(address(machine), approvalAmount);

        // Calculate expected amounts (2% fee)
        uint256 expectedFee = (approvalAmount * 200) / 10_000; // 2% fee
        uint256 expectedReceived = approvalAmount - expectedFee;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(feeToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // IMPORTANT: The register should contain the ACTUAL amount received (after fee)
        // not the approved amount
        Asserts.equalsAbiData(s1.registers[1], abi.encode(expectedReceived));

        // Verify token balances changed correctly
        assertEq(feeToken.balanceOf(alice), aliceInitialBalance - approvalAmount);
        assertEq(feeToken.balanceOf(address(machine)), vmInitialBalance + expectedReceived);
        assertEq(feeToken.balanceOf(address(0xdead)), feeRecipientInitial + expectedFee);

        // Verify approval was consumed
        assertEq(feeToken.allowance(alice, address(machine)), 0);
    }

    /// @notice Test multiple deposits with fee-on-transfer tokens
    function test_DepositApproved_FeeOnTransfer_MultipleDeposits() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(4);
        // Set max deposit amount to unlimited
        s0.registers[3] = abi.encode(type(uint256).max);

        // First deposit
        uint256 firstApproval = 50 * 10 ** 18;
        feeToken.approve(address(machine), firstApproval);
        uint256 firstExpectedFee = (firstApproval * 200) / 10_000;
        uint256 firstExpectedReceived = firstApproval - firstExpectedFee;

        VMCommand[] memory cmds1 = new VMCommand[](1);
        cmds1[0] = VmCmd.depositApproved(address(feeToken), 1, 3);

        (VMState memory s1,) = run(cmds1, s0);
        Asserts.equalsAbiData(s1.registers[1], abi.encode(firstExpectedReceived));
        assertEq(feeToken.allowance(alice, address(machine)), 0);

        // Second deposit with different amount
        uint256 secondApproval = 75 * 10 ** 18;
        feeToken.approve(address(machine), secondApproval);
        uint256 secondExpectedFee = (secondApproval * 200) / 10_000;
        uint256 secondExpectedReceived = secondApproval - secondExpectedFee;

        VMCommand[] memory cmds2 = new VMCommand[](1);
        cmds2[0] = VmCmd.depositApproved(address(feeToken), 2, 3);

        (VMState memory s2,) = run(cmds2, s1);
        Asserts.equalsAbiData(s2.registers[2], abi.encode(secondExpectedReceived));
        assertEq(feeToken.allowance(alice, address(machine)), 0);

        // Verify total received by VM (after fees)
        assertEq(feeToken.balanceOf(address(machine)), firstExpectedReceived + secondExpectedReceived);
        // Verify total fees collected
        assertEq(feeToken.balanceOf(address(0xdead)), firstExpectedFee + secondExpectedFee);
    }

    /// @notice Test that depositApproved reverts when called with a non-existent token address
    /// @dev Verifies that EXTCODESIZE check prevents calls to EOA addresses
    function test_DepositApproved_NonExistentToken_Reverts() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Use an address that has no contract code (EOA address)
        address nonExistentToken = address(0x1234567890123456789012345678901234567890);

        // Explicitly ensure this address has no code
        vm.etch(nonExistentToken, '');

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(nonExistentToken, 1, 2);

        // Should revert due to EXTCODESIZE check with CallToNonContract error
        vm.expectRevert(VmErrors.CallToNonContract.selector);
        run(cmds, s0);
    }

    /// @notice Test that DEPOSIT_APPROVED respects maxDepositReg limit
    function test_DepositApproved_MaxDepositLimit() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);

        // Set max deposit amount to 50 tokens
        uint256 maxDepositAmount = 50 * 10 ** 18;
        s0.registers[2] = abi.encode(maxDepositAmount);

        // Capture initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(alice);
        uint256 vmInitialBalance = mockToken.balanceOf(address(machine));

        // Alice approves 100 tokens to the VM (more than max deposit)
        uint256 approvalAmount = 100 * 10 ** 18;
        mockToken.approve(address(machine), approvalAmount);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify only the max deposit amount was transferred
        Asserts.equalsAbiData(s1.registers[1], abi.encode(maxDepositAmount));

        // Verify token balances changed correctly (only maxDepositAmount transferred)
        assertEq(mockToken.balanceOf(alice), aliceInitialBalance - maxDepositAmount);
        assertEq(mockToken.balanceOf(address(machine)), vmInitialBalance + maxDepositAmount);

        // Verify remaining approval (original approval - transferred amount)
        assertEq(mockToken.allowance(alice, address(machine)), approvalAmount - maxDepositAmount);
    }

    /// @notice Test fee-on-transfer with partial balance
    /// @dev Verifies that when approval > balance, only available balance is transferred
    /// and the register correctly stores the post-fee amount received
    function test_DepositApproved_FeeOnTransfer_PartialBalance() public withSnapshot asUser(alice) {
        VMState memory s0 = Regs.init(3);
        // Set max deposit amount to unlimited
        s0.registers[2] = abi.encode(type(uint256).max);

        // Get alice's current balance
        uint256 aliceBalance = feeToken.balanceOf(alice);

        // Alice approves more than her balance
        uint256 approvalAmount = aliceBalance + 100 * 10 ** 18;
        feeToken.approve(address(machine), approvalAmount);

        // Transfer most of alice's tokens away, leaving only 30 tokens
        uint256 remainingBalance = 30 * 10 ** 18;
        uint256 transferAmount = aliceBalance - remainingBalance;

        // Store the initial fee recipient balance
        uint256 feeRecipientInitial = feeToken.balanceOf(address(0xdead));

        feeToken.transfer(bob, transferAmount);

        assertEq(feeToken.balanceOf(alice), remainingBalance);
        assertEq(feeToken.allowance(alice, address(machine)), approvalAmount);

        // Calculate expected amounts for the actual transfer
        uint256 expectedFee = (remainingBalance * 200) / 10_000;
        uint256 expectedReceived = remainingBalance - expectedFee;

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(feeToken), 1, 2);

        (VMState memory s1,) = run(cmds, s0);

        uint8[] memory dests = new uint8[](1);
        dests[0] = 1;
        Asserts.unchangedExcept(s0, s1, dests);

        // Verify only the available balance was transferred (minus fee)
        Asserts.equalsAbiData(s1.registers[1], abi.encode(expectedReceived));

        // Verify balances
        assertEq(feeToken.balanceOf(alice), 0);
        assertEq(feeToken.balanceOf(address(machine)), expectedReceived);

        // Fee recipient should have received fees from both transfers
        uint256 firstTransferFee = (transferAmount * 200) / 10_000;
        assertEq(feeToken.balanceOf(address(0xdead)), feeRecipientInitial + firstTransferFee + expectedFee);

        // Verify the remaining approval
        assertEq(feeToken.allowance(alice, address(machine)), approvalAmount - remainingBalance);
    }
}
