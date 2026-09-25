// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { DepositApprovedLib } from 'src/DepositApproved.sol';
import { IERC20 } from 'src/interfaces/IERC20.sol';
import { DepositApproved } from 'src/DataModel.sol';
import { VmErrors } from 'src/VmErrors.sol';
import { MinimalERC20 } from './mocks/MinimalERC20.sol';

contract DepositApprovedHarness {
    function depositApproved(DepositApproved memory cmd, uint256 maxDeposit) external returns (uint256) {
        return DepositApprovedLib.depositApproved(cmd, maxDeposit);
    }
}

// halmos --contract DepositApprovedHalmosTest --loop 100
contract DepositApprovedHalmosTest is Test, SymTest {
    MinimalERC20 token;
    DepositApprovedHarness h = new DepositApprovedHarness();

    function setUp() public {
        token = new MinimalERC20();
    }

    function check_depositApprovedWithCustomBehavior(
        MinimalERC20.Behavior _behavior,
        uint256 mintAmt,
        uint256 approveAmt,
        address targetToken
    )
        public
    {
        token.setBehavior(_behavior);

        address theContract = address(this);

        // Only mint and approve if targetToken matches our token
        if (targetToken == address(token)) {
            token.mint(address(this), mintAmt);
            token.approve(address(h), approveAmt);
        }

        DepositApproved memory cmd = DepositApproved({ token: address(token), destReg: 0, maxDepositReg: 0 });

        try h.depositApproved(cmd, type(uint256).max) returns (uint256 transferred) {
            uint256 bal = token.balanceOf(address(h));

            // Calculate expected amount based on whether we minted/approved
            uint256 expectedTransferred = 0;
            if (targetToken == address(token)) {
                expectedTransferred = mintAmt >= approveAmt ? approveAmt : mintAmt;
            }

            // For FOT tokens, the actual received amount is less due to the 1% fee
            uint256 expectedReceived = expectedTransferred;
            if (_behavior == MinimalERC20.Behavior.FOT && expectedTransferred > 0) {
                uint256 fee = expectedTransferred * 1 / 100;
                expectedReceived = expectedTransferred - fee;
            }

            // DepositApproved returns the actual amount received (post - pre)
            assertEq(transferred, expectedReceived, 'transferred');

            // Actual balance should match what was transferred (accounting for fees)
            assertEq(bal, transferred, 'bal');
        } catch {
            assertTrue(false, 'Should not revert when allowance and balance are sufficient');
        }
        vm.stopPrank();
    }

    /// Clamped Properties ///

    // Property 1) depositApproved command execution
    function check_deposit_approved_command(uint256 mintAmt, uint256 approveAmt) external {
        token.mint(address(this), mintAmt);
        token.approve(address(h), approveAmt);
        DepositApproved memory cmd = DepositApproved({ token: address(token), destReg: 0, maxDepositReg: 0 });

        uint256 transferred = h.depositApproved(cmd, type(uint256).max);
        uint256 bal = token.balanceOf(address(h));
        if (mintAmt >= approveAmt) {
            assertEq(transferred, approveAmt, 'transferred approve');
        } else {
            assertEq(transferred, mintAmt, 'transferred mint');
        }
    }

    // Property 2) depositApproved with zero approval
    function check_deposit_approved_zero_approval() external {
        token.mint(address(this), 1000 ether);
        token.approve(address(h), 0);
        DepositApproved memory cmd = DepositApproved({ token: address(token), destReg: 0, maxDepositReg: 0 });

        uint256 transferred = h.depositApproved(cmd, type(uint256).max);
        uint256 bal = token.balanceOf(address(h));
        assertEq(transferred, bal, 'transferred');
        assertLe(transferred, 1000 ether, 'max bal');
        assertEq(transferred, 0, 'zero');
    }

    // Property 3) depositApproved with zero balance
    function check_deposit_approved_zero_balance() external {
        token.mint(address(this), 0);
        token.approve(address(h), type(uint256).max);
        DepositApproved memory cmd = DepositApproved({ token: address(token), destReg: 0, maxDepositReg: 0 });

        uint256 transferred = h.depositApproved(cmd, type(uint256).max);
        uint256 bal = token.balanceOf(address(h));
        assertEq(transferred, bal, 'transferred');
        assertLe(transferred, 0, 'max bal');
        assertEq(transferred, 0, 'zero');
    }

    // Property 4) depositApproved reverts with invalid token address (no code)
    function check_deposit_approved_invalid_token() external {
        token.mint(address(this), 1000 ether);
        token.approve(address(h), type(uint256).max);
        DepositApproved memory cmd = DepositApproved({
            token: address(0x1234), // Invalid token address (no code)
            destReg: 0,
            maxDepositReg: 0
        });

        bytes memory cd =
            abi.encodeWithSelector(DepositApprovedHarness.depositApproved.selector, cmd, type(uint256).max);
        (bool ok, bytes memory ret) = address(h).call(cd);
        assertTrue(!ok, 'should revert on non-contract token');
        assertGe(ret.length, 4, 'ret.len');
        assertEq(bytes4(ret), VmErrors.CallToNonContract.selector, 'selector');
    }
}
