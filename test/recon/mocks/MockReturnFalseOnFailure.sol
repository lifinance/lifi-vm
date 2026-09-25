// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { MockERC20 } from '@recon/MockERC20.sol';

contract MockReturnFalseOnFailure is MockERC20 {
    constructor() MockERC20('Mock USDT', 'USDT', 6) { }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Return false on failure
        if (balanceOf[msg.sender] < amount) {
            return false;
        }

        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Return false on failure
        if (balanceOf[from] < amount) {
            return false;
        }

        return super.transferFrom(from, to, amount);
    }
}
