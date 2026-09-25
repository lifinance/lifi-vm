// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Create3Helpers
 * @dev Helper library for working with CreateX CREATE3 deployments
 * @notice CreateX guards salts internally before computing CREATE3 addresses.
 *         When predicting addresses, you must apply the same guarding logic.
 */
library Create3Helpers {
    /**
     * @dev Guard a salt the same way CreateX does internally
     * @param salt The raw salt value
     * @param deployer The address deploying (msg.sender in CreateX context)
     * @return guardedSalt The guarded salt that CreateX will use internally
     * @notice CreateX's _guard function: keccak256(bytes32(uint160(deployer)) || salt)
     *         This is used for MsgSender mode + no cross-chain protection
     */
    function guardSalt(bytes32 salt, address deployer) internal pure returns (bytes32 guardedSalt) {
        guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }
}