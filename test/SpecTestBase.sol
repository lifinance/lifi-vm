// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { BaseVmTest } from './BaseVm.t.sol';
import { IERC20 } from '../src/interfaces/IERC20.sol';

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = 'Mock Token';
    string public symbol = 'MOCK';
    uint8 public decimals = 18;
    uint256 public totalSupply;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[sender] >= amount, 'Insufficient balance');

        // Only check and update allowance if sender != msg.sender
        if (sender != msg.sender) {
            require(allowance[sender][msg.sender] >= amount, 'Insufficient allowance');
            allowance[sender][msg.sender] -= amount;
        }
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;

        return true;
    }
}

abstract contract SpecTestBase is BaseVmTest {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    MockERC20 internal mockToken;

    modifier withSnapshot() {
        uint256 snap = vm.snapshot();
        _;
        vm.revertTo(snap);
    }

    modifier asUser(address who) {
        vm.startPrank(who);
        _;
        vm.stopPrank();
    }

    function setUp() public virtual override {
        super.setUp(); // VM constructed & labeled
        vm.label(alice, 'alice');
        vm.label(bob, 'bob');
        vm.warp(1_700_000_000);
        vm.roll(1);
        vm.chainId(1);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // Deploy mock ERC20 token
        mockToken = new MockERC20();
        vm.label(address(mockToken), 'MockERC20');

        // Deal 1000 tokens to alice and bob
        deal(address(mockToken), alice, 1000 * 10 ** 18);
        deal(address(mockToken), bob, 1000 * 10 ** 18);
    }
}
