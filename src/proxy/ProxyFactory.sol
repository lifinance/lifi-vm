// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { MinimalProxy } from './MinimalProxy.sol';
import { VmErrors } from '../VmErrors.sol';
import { ICreateX } from 'createx-forge/script/ICreateX.sol';
import { SafeTransferLib } from 'solady/utils/SafeTransferLib.sol';

/// @title Proxy Factory
/// @custom:version 1.0.0
/// @dev Contract to create and manage proxies using CREATE3 for deterministic deployment
contract ProxyFactory {
    address public immutable vmContract;
    address public immutable create3Factory;

    // Make both parameters indexed so they appear in topics
    event ProxyDeployed(address indexed user, address indexed proxy);

    constructor(address _vmContract, address _create3Factory) {
        vmContract = _vmContract;
        create3Factory = _create3Factory;
    }

    /**
     * @dev Calculate the deterministic address for a user's proxy before deployment
     * @param user The address of the user
     * @return The address the proxy would be deployed to
     */
    function predictProxyAddress(address user) external view returns (address) {
        return ICreateX(create3Factory).computeCreate3Address(_guardedSalt(user), create3Factory);
    }

    /**
     * @dev Deploy a new proxy for a specific address with deterministic address.
     *      Note: the factory's one-time call privilege (via onlyOwnerOrFactory) is NOT
     *      consumed here. This is safe because the factory exposes no public function
     *      that calls an already-deployed proxy — the one-time call is only exercisable
     *      inside the atomic deployAndExecute flow.
     * @param user The address of the user to deploy a proxy for
     * @return The address of the newly deployed proxy
     */
    function deployProxy(address user) external returns (address) {
        address proxy = _deploy(user);
        emit ProxyDeployed(user, proxy);
        return proxy;
    }

    /**
     * @dev Deploy a new proxy for msg.sender and execute initial VM commands atomically.
     *      Caller should approve their own proxy (deterministic via predictProxyAddress) for
     *      any tokens needed. DEPOSIT_APPROVED in the VM calldata will pull from the owner.
     * @param arbiCall The calldata to execute on the VM after proxy deployment
     * @return The raw bytes returned by the VM execution (empty if arbiCall is empty)
     */
    function deployAndExecute(bytes calldata arbiCall) external payable returns (bytes memory) {
        address proxy = _deploy(msg.sender);

        // Execute init commands via proxy fallback (onlyOwnerOrFactory allows factory)
        if (arbiCall.length > 0) {
            (bool ok, bytes memory ret) = proxy.call{ value: msg.value }(arbiCall);
            if (!ok) {
                assembly ('memory-safe') {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            emit ProxyDeployed(msg.sender, proxy);
            // ret is already ABI-encoded bytes memory (from runVM), forward directly
            assembly ('memory-safe') {
                return(add(ret, 0x20), mload(ret))
            }
        }

        // Forward ETH when no arbiCall provided
        if (msg.value > 0) {
            SafeTransferLib.safeTransferETH(proxy, msg.value);
        }

        emit ProxyDeployed(msg.sender, proxy);
    }

    /**
     * @dev Compute the CREATE3 structured salt for a given user
     */
    function _structuredSalt(address user) private view returns (bytes32) {
        bytes32 entropy = keccak256(abi.encodePacked(user));
        return bytes32(abi.encodePacked(address(this), hex'00', bytes11(entropy)));
    }

    /**
     * @dev Compute the guarded CREATE3 salt for a given user
     */
    function _guardedSalt(address user) private view returns (bytes32) {
        bytes32 structuredSalt = _structuredSalt(user);
        return keccak256(abi.encodePacked(uint256(uint160(address(this))), structuredSalt));
    }

    /**
     * @dev Validate, then deploy a new MinimalProxy for `user` via CREATE3
     */
    function _deploy(address user) private returns (address proxy) {
        if (user == address(0)) revert VmErrors.InvalidUserAddress();

        address predicted = ICreateX(create3Factory).computeCreate3Address(_guardedSalt(user), create3Factory);
        if (predicted.code.length != 0) revert VmErrors.ProxyAlreadyDeployed();

        bytes memory creationCode =
            abi.encodePacked(type(MinimalProxy).creationCode, abi.encode(user, vmContract, address(this)));

        proxy = ICreateX(create3Factory).deployCreate3(_structuredSalt(user), creationCode);
    }
}
