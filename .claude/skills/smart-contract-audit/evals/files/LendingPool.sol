// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IChainlinkOracle {
    function latestAnswer() external view returns (int256);
}

/// @notice Minimal single-asset lending pool. Users deposit collateral token, borrow debt token.
contract LendingPool {
    IERC20 public immutable collateral;
    IERC20 public immutable debt;
    IChainlinkOracle public immutable collateralOracle; // price in USD, 8 decimals
    IChainlinkOracle public immutable debtOracle;

    uint256 public constant LTV = 75; // 75%
    uint256 public constant LIQ_BONUS = 10; // 10%

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public debtBalance;

    constructor(IERC20 _c, IERC20 _d, IChainlinkOracle _co, IChainlinkOracle _do) {
        collateral = _c;
        debt = _d;
        collateralOracle = _co;
        debtOracle = _do;
    }

    function deposit(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
    }

    function borrow(uint256 amount) external {
        debtBalance[msg.sender] += amount;
        require(_healthy(msg.sender), "unhealthy");
        debt.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        debt.transferFrom(msg.sender, address(this), amount);
        debtBalance[msg.sender] -= amount;
    }

    function withdraw(uint256 amount) external {
        collateralBalance[msg.sender] -= amount;
        require(_healthy(msg.sender), "unhealthy");
        collateral.transfer(msg.sender, amount);
    }

    function liquidate(address user) external {
        require(!_healthy(user), "healthy");
        uint256 seize = collateralBalance[user] * (100 + LIQ_BONUS) / 100;
        collateralBalance[user] = 0;
        debtBalance[user] = 0;
        collateral.transfer(msg.sender, seize);
    }

    function _healthy(address user) internal view returns (bool) {
        uint256 cPrice = uint256(collateralOracle.latestAnswer());
        uint256 dPrice = uint256(debtOracle.latestAnswer());
        uint256 cValue = collateralBalance[user] * cPrice;
        uint256 dValue = debtBalance[user] * dPrice;
        return cValue * LTV / 100 >= dValue;
    }
}
