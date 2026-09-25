// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ProxyFactory} from "../src/proxy/ProxyFactory.sol";
import {MinimalProxy} from "../src/proxy/MinimalProxy.sol";

contract GenerateProxyAddress is Script {
    function run() public {
        address userAddress = vm.envAddress("USER_ADDRESS");
        address proxyFactoryAddress = vm.envAddress("PROXY_FACTORY_ADDRESS");

        ProxyFactory factory = ProxyFactory(proxyFactoryAddress);

        address vmContract = factory.vmContract();
        address predictedAddress = factory.predictProxyAddress(userAddress);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }

        if (codeSize == 0) {
            vm.startBroadcast();
            address deployedAddress = factory.deployProxy(userAddress);
            vm.stopBroadcast();

            console.log("Proxy deployed at:", deployedAddress);
        } else {
            console.log("Proxy already exists at:", predictedAddress);
        }

        // Print predicted address for verification
        console.log("Predicted proxy address:", predictedAddress);
    }
}
