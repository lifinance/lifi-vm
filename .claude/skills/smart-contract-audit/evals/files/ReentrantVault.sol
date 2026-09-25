// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @notice Simple ETH + reward vault. Users deposit ETH, earn rewards in a reward token.
contract ReentrantVault {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public rewardDebt;
    IERC20 public immutable rewardToken;
    address public owner;
    uint256 public totalDeposits;
    uint256 public rewardPerShare; // scaled 1e18

    constructor(IERC20 _rewardToken) {
        rewardToken = _rewardToken;
        owner = msg.sender;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }

    function deposit() external payable {
        require(msg.value > 0);
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        rewardDebt[msg.sender] = (balances[msg.sender] * rewardPerShare) / 1e18;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient");
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        balances[msg.sender] -= amount;
        totalDeposits -= amount;
    }

    function claimRewards() external {
        uint256 pending = (balances[msg.sender] * rewardPerShare) / 1e18 - rewardDebt[msg.sender];
        rewardToken.transfer(msg.sender, pending);
        rewardDebt[msg.sender] = (balances[msg.sender] * rewardPerShare) / 1e18;
    }

    function distributeRewards(uint256 amount) external {
        require(msg.sender == owner);
        rewardToken.transferFrom(msg.sender, address(this), amount);
        rewardPerShare += (amount * 1e18) / totalDeposits;
    }

    function emergencyDrain() external {
        require(msg.sender == owner);
        payable(owner).transfer(address(this).balance);
    }
}
