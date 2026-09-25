// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { MockERC20 } from '@recon/MockERC20.sol';

contract MockFoTToken is MockERC20 {
    uint256 public fee;
    uint256 public constant MAX_BPS = 10_000;

    constructor() MockERC20('FoT Token', 'FOT', 18) { }

    function setFee(uint256 _fee) public {
        require(_fee <= MAX_BPS, 'Fee exceeds max BPS');
        fee = _fee;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);

        uint256 feeAmount = amount * fee / MAX_BPS; // Note: Rounds down, not a huge deal

        _burn(to, feeAmount);
        _mint(address(this), feeAmount);

        assembly {
            // Actually returns nothing
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);

        uint256 feeAmount = amount * fee / MAX_BPS; // Note: Rounds down, not a huge deal

        _burn(to, feeAmount);
        _mint(address(this), feeAmount);

        assembly {
            // Actually returns nothing
            return(0, 0)
        }
    }
}
