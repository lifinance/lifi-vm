// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { IERC20 } from 'src/interfaces/IERC20.sol';

/// @notice Minimal ERC20 implementation for testing various token behaviors
/// @dev Supports multiple behaviors: DEFAULT, FOT, NO_RETURN, FALSE_ON_FAILURE, APPROVE_PROTECTED
contract MinimalERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    enum Behavior {
        DEFAULT,
        FOT,
        NO_RETURN,
        FALSE_ON_FAILURE,
        APPROVE_PROTECTED
    }

    Behavior public theBehavior;

    function setBehavior(Behavior _behavior) external {
        theBehavior = _behavior;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (theBehavior == Behavior.NO_RETURN) {
            assembly {
                return(0, 0)
            }
        }

        if (theBehavior == Behavior.FALSE_ON_FAILURE) {
            if (allowance[msg.sender][spender] != 0) {
                return false;
            }
        }

        if (theBehavior == Behavior.APPROVE_PROTECTED) {
            if (allowance[msg.sender][spender] != 0) {
                revert('Protected');
            }
        }

        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (theBehavior == Behavior.FALSE_ON_FAILURE) {
            if (balanceOf[msg.sender] < amount) {
                return false;
            }
        } else {
            // Default behavior - revert on insufficient balance
            require(balanceOf[msg.sender] >= amount, 'Insufficient balance');
        }

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        if (theBehavior == Behavior.FOT) {
            // Apply 1% fee on transfer
            uint256 fee = amount * 1 / 100;
            if (fee > 0) {
                balanceOf[to] -= fee;
            }
        }

        if (theBehavior == Behavior.NO_RETURN) {
            assembly {
                return(0, 0)
            }
        }

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (theBehavior == Behavior.FALSE_ON_FAILURE) {
            if (allowance[from][msg.sender] < amount || balanceOf[from] < amount) {
                return false;
            }
        }

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (theBehavior == Behavior.FOT) {
            balanceOf[to] -= amount * 1 / 100;
        }

        if (theBehavior == Behavior.NO_RETURN) {
            assembly {
                return(0, 0)
            }
        }

        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}
