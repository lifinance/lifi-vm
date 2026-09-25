// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Permit-style voucher redeemer. Signer authorizes a recipient+amount; anyone can relay.
contract SigReplay {
    IERC20 public immutable token;
    address public immutable signer;

    bytes32 public constant TYPEHASH =
        keccak256("Voucher(address recipient,uint256 amount)");

    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor(IERC20 _token, address _signer) {
        token = _token;
        signer = _signer;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version)"),
                keccak256(bytes("SigReplay")),
                keccak256(bytes("1"))
            )
        );
    }

    function redeem(
        address recipient,
        uint256 amount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, recipient, amount));
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address recovered = ecrecover(digest, v, r, s);
        require(recovered == signer, "bad sig");
        require(token.transfer(recipient, amount), "xfer fail");
    }
}
