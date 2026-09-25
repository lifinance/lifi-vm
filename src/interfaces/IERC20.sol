// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @custom:version 1.0.0
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}
