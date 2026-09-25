// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/interfaces/IERC20.sol';

/// @notice Token test library for capturing token state.
/// @dev Example: (uint256 userBal, uint256 vmBal, uint256 allowance) = Token.snapshot(user, vm, token);
library Token {
    /// @notice Capture token balances and allowance.
    /// @dev Example: (userBal, vmBal, allow) = Token.snapshot(user, vmAddr, token);
    /// @param user User address.
    /// @param vmAddr VM address.
    /// @param token ERC20 token contract.
    /// @return balUser User's token balance.
    /// @return balVM VM's token balance.
    /// @return allow User's allowance to VM.
    function snapshot(
        address user,
        address vmAddr,
        IERC20 token
    )
        internal
        view
        returns (uint256 balUser, uint256 balVM, uint256 allow)
    {
        balUser = token.balanceOf(user);
        balVM = token.balanceOf(vmAddr);
        allow = token.allowance(user, vmAddr);
    }
}
