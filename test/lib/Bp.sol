// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/VmConstants.sol';

/// @notice Blueprint builder for constructing calldata/ABI encoding blueprints.
/// @dev Example: bytes memory blueprint = Bp.bp().s(0).d(1).pushTuple().s(2).end().end();
library Bp {
    // Use container tokens from VmConstants

    /// @notice Initialize empty blueprint.
    /// @dev Example: bytes memory bp = Bp.bp();
    /// @return Empty bytes array for blueprint building.
    function bp() internal pure returns (bytes memory) {
        return '';
    }

    /// @notice Add static register token to blueprint.
    /// @dev Example: bp = Bp.s(0);
    /// @param reg Register index (0-127).
    /// @return Single-byte blueprint with static register.
    function s(uint8 reg) internal pure returns (bytes memory) {
        require(reg < 128, 'Register index too high');
        bytes memory result = new bytes(1);
        result[0] = bytes1(reg);
        return result;
    }

    /// @notice Add dynamic register token to blueprint.
    /// @dev Example: bp = Bp.d(0);
    /// @param reg Register index (0-127).
    /// @return Single-byte blueprint with dynamic register.
    function d(uint8 reg) internal pure returns (bytes memory) {
        require(reg < 128, 'Register index too high');
        bytes memory result = new bytes(1);
        result[0] = bytes1(reg | VmConstants.DYN_MASK);
        return result;
    }

    /// @notice Add dynamic tuple open token.
    /// @dev Example: bp = Bp.pushTuple();
    /// @return Single-byte blueprint with tuple open token.
    function pushTuple() internal pure returns (bytes memory) {
        bytes memory result = new bytes(1);
        result[0] = bytes1(VmConstants.START_TUPLE_DYNAMIC);
        return result;
    }

    /// @notice Add dynamic array open token.
    /// @dev Example: bp = Bp.pushArray();
    /// @return Single-byte blueprint with array open token.
    function pushArray() internal pure returns (bytes memory) {
        bytes memory result = new bytes(1);
        result[0] = bytes1(VmConstants.START_ARRAY_DYNAMIC);
        return result;
    }

    /// @notice Add static tuple open token.
    /// @dev Example: bp = Bp.pushTupleStatic();
    /// @return Single-byte blueprint with static tuple open token.
    function pushTupleStatic() internal pure returns (bytes memory) {
        bytes memory result = new bytes(1);
        result[0] = bytes1(VmConstants.START_TUPLE_STATIC);
        return result;
    }

    /// @notice Add static array open token.
    /// @dev Example: bp = Bp.pushArrayStatic();
    /// @return Single-byte blueprint with static array open token.
    function pushArrayStatic() internal pure returns (bytes memory) {
        bytes memory result = new bytes(1);
        result[0] = bytes1(VmConstants.START_ARRAY_STATIC);
        return result;
    }

    /// @notice Add container close token.
    /// @dev Example: bp = Bp.end();
    /// @return Single-byte blueprint with close token.
    function end() internal pure returns (bytes memory) {
        bytes memory result = new bytes(1);
        result[0] = bytes1(VmConstants.END_DYNAMIC);
        return result;
    }

    /// @notice Build blueprint from static register array.
    /// @dev Example: bp = Bp.fromRegsStatic([0, 1, 2]);
    /// @param regs Array of register indices.
    /// @return Blueprint with static register tokens.
    function fromRegsStatic(uint8[] memory regs) internal pure returns (bytes memory) {
        bytes memory result = new bytes(regs.length);
        for (uint256 i = 0; i < regs.length; i++) {
            require(regs[i] < 128, 'Register index too high');
            result[i] = bytes1(regs[i]);
        }
        return result;
    }
}
