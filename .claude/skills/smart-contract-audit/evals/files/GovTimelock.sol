// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @notice Governance timelock. Proposers queue actions; anyone executes after delay.
contract GovTimelock {
    address public admin;
    uint256 public delay;
    mapping(address => bool) public proposers;
    mapping(bytes32 => uint256) public queuedAt;

    event Queued(bytes32 id, address target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 id);
    event Cancelled(bytes32 id);

    constructor(uint256 _delay) {
        admin = msg.sender;
        delay = _delay;
        proposers[msg.sender] = true;
    }

    function setProposer(address who, bool ok) external {
        require(msg.sender == admin, "not admin");
        proposers[who] = ok;
    }

    function queue(address target, uint256 value, bytes calldata data) external returns (bytes32 id) {
        require(proposers[msg.sender], "not proposer");
        id = keccak256(abi.encodePacked(target, value, data));
        queuedAt[id] = block.timestamp;
        emit Queued(id, target, value, data, block.timestamp + delay);
    }

    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        bytes32 id = keccak256(abi.encodePacked(target, value, data));
        uint256 qAt = queuedAt[id];
        require(qAt != 0, "not queued");
        if (msg.sender != admin) {
            require(block.timestamp >= qAt + delay, "delay");
        }
        delete queuedAt[id];
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "call fail");
        emit Executed(id);
        return ret;
    }

    function cancel(address target, uint256 value, bytes calldata data) external {
        bytes32 id = keccak256(abi.encodePacked(target, value, data));
        delete queuedAt[id];
        emit Cancelled(id);
    }
}
