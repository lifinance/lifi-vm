// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20Mintable {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @notice LayerZero-style cross-chain token bridge. Receives messages via _lzReceive.
contract Bridge {
    IERC20Mintable public immutable token;
    address public immutable endpoint;
    bytes public trustedRemote;

    constructor(IERC20Mintable _token, address _endpoint, bytes memory _trustedRemote) {
        token = _token;
        endpoint = _endpoint;
        trustedRemote = _trustedRemote;
    }

    function _lzReceive(
        uint16 /*_srcChainId*/,
        bytes calldata _srcAddress,
        uint64 /*_nonce*/,
        bytes calldata _payload
    ) external {
        require(msg.sender == endpoint, "not endpoint");
        require(keccak256(_srcAddress) == keccak256(trustedRemote), "untrusted");
        (address to, uint256 amount) = abi.decode(_payload, (address, uint256));
        mint(to, amount);
    }

    function mint(address to, uint256 amount) public {
        token.mint(to, amount);
    }

    function sendFrom(address from, uint16 /*dstChainId*/, bytes calldata /*toAddress*/, uint256 amount) external {
        token.burn(from, amount);
    }
}
