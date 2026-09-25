// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {EchoContract, DispatcherTarget} from "../test/lib/Mocks.sol";

contract VirtualMachineScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address echoContract = address(new EchoContract());

        address dispatcherTarget = address(new DispatcherTarget());

        vm.stopBroadcast();
    }
}


