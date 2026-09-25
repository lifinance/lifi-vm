// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseTargetFunctions } from '@chimera/BaseTargetFunctions.sol';
import { BeforeAfter } from '../BeforeAfter.sol';
import { Properties } from '../Properties.sol';
// Chimera deps
import { vm } from '@chimera/Hevm.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

import { MockERC4626Tester } from '../mocks/MockERC4626Tester.sol';

abstract contract MaliciousERC4626Targets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function maliciousERC4626_approve(address spender, uint256 value) public asActor {
        maliciousERC4626.approve(spender, value);
    }

    function maliciousERC4626_decreaseYield(uint256 decreasePercentageFP4) public asActor {
        maliciousERC4626.decreaseYield(decreasePercentageFP4);
    }

    function maliciousERC4626_deposit(uint256 assets, address receiver) public asActor {
        maliciousERC4626.deposit(assets, receiver);
    }

    function maliciousERC4626_increaseYield(uint256 increasePercentageFP4) public asActor {
        maliciousERC4626.increaseYield(increasePercentageFP4);
    }

    function maliciousERC4626_mint(uint256 shares, address receiver) public asActor {
        maliciousERC4626.mint(shares, receiver);
    }

    function maliciousERC4626_mintUnbackedShares(uint256 amount, address to) public asActor {
        maliciousERC4626.mintUnbackedShares(amount, to);
    }

    function maliciousERC4626_redeem(uint256 shares, address receiver, address owner) public asActor {
        maliciousERC4626.redeem(shares, receiver, owner);
    }

    function maliciousERC4626_setDecimalsOffset(uint8 targetDecimalsOffset) public asActor {
        maliciousERC4626.setDecimalsOffset(targetDecimalsOffset);
    }

    function maliciousERC4626_setRevertBehaviour(
        MockERC4626Tester.FunctionType ft,
        MockERC4626Tester.RevertType rt
    )
        public
        asActor
    {
        maliciousERC4626.setRevertBehaviour(ft, rt);
    }

    function maliciousERC4626_transfer(address to, uint256 value) public asActor {
        maliciousERC4626.transfer(to, value);
    }

    function maliciousERC4626_transferFrom(address from, address to, uint256 value) public asActor {
        maliciousERC4626.transferFrom(from, to, value);
    }

    function maliciousERC4626_withdraw(uint256 assets, address receiver, address owner) public asActor {
        maliciousERC4626.withdraw(assets, receiver, owner);
    }
}
