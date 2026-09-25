// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

library MerkleProof {
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed = computed < p ? keccak256(abi.encodePacked(computed, p)) : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }
}

/// @notice Admin publishes merkle root; recipients claim against proof.
contract MerkleAirdrop {
    IERC20 public immutable token;
    address public admin;
    bytes32 public root;

    constructor(IERC20 _token) {
        token = _token;
        admin = msg.sender;
    }

    function setRoot(bytes32 _root) external {
        require(msg.sender == admin, "not admin");
        root = _root;
    }

    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        bytes32 leaf = keccak256(abi.encodePacked(account));
        require(MerkleProof.verify(proof, root, leaf), "bad proof");
        require(token.transfer(account, amount), "xfer fail");
    }
}
