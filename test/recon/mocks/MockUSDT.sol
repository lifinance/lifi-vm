// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { MockERC20 } from '@recon/MockERC20.sol';

contract MockUSDT is MockERC20 {
    constructor() MockERC20('Mock USDT', 'USDT', 6) { }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);

        assembly {
            // Actually returns nothing
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);

        assembly {
            // Actually returns nothing
            return(0, 0)
        }
    }
}
