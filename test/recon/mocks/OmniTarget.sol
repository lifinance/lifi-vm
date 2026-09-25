// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

contract OmniTarget {
    uint256 public value;

    function setValue(uint256 _value) public {
        value = _value;
    }

    function returnValue() public view returns (uint256) {
        return value;
    }
}
