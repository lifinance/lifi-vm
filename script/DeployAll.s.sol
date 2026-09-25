// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {DeployVirtualMachine} from "./VirtualMachine.s.sol";
import {DeployProxyFactory} from "./ProxyFactory.s.sol";
import {InvariantCheckerScript} from "./InvariantCheckerScript.s.sol";
import {RPNArithmeticScript} from "./RPNArithmeticScript.s.sol";

contract DeployAll is DeployVirtualMachine, DeployProxyFactory, InvariantCheckerScript, RPNArithmeticScript {
    // Default salts for each contract. The VM and ProxyFactory salts are versioned together:
    // both the factory and every MinimalProxy bake in the VM address, so a VM change needs a new
    // salt for each. Salt history and pending addresses live in DEPLOYMENTS.md.
    bytes32 constant DEFAULT_VM_SALT = bytes32(uint256(0xc0deb));
    bytes32 constant DEFAULT_PROXY_FACTORY_SALT = bytes32(uint256(0xc0dec));
    bytes32 constant DEFAULT_INVARIANT_CHECKER_SALT = bytes32(uint256(0xc0de7));
    bytes32 constant DEFAULT_RPN_ARITHMETIC_SALT = bytes32(uint256(0xc0dea));

    function setUp() public withCreateX {}

    function run() public {
        // Deploy with hardcoded default salts
        deploy(DEFAULT_VM_SALT, DEFAULT_PROXY_FACTORY_SALT, DEFAULT_INVARIANT_CHECKER_SALT, DEFAULT_RPN_ARITHMETIC_SALT);
    }
    
    function deploy(
        bytes32 vmSalt,
        bytes32 proxyFactorySalt,
        bytes32 invariantCheckerSalt,
        bytes32 rpnArithmeticSalt
    ) public returns (
        address vmAddress,
        address proxyFactoryAddress,
        address invariantCheckerAddress,
        address rpnArithmeticAddress
    ) {
        // Step 1: Deploy VirtualMachine
        vmAddress = deployVM(vmSalt);

        // Step 2: Deploy ProxyFactory
        proxyFactoryAddress = deployProxyFactory(proxyFactorySalt, vmAddress);

        // Step 3: Deploy InvariantChecker
        invariantCheckerAddress = deployInvariantChecker(invariantCheckerSalt);

        // Step 4: Deploy RPNArithmetic
        rpnArithmeticAddress = deployRPNArithmetic(rpnArithmeticSalt);

        // Log deployment addresses for parsing by deploy scripts
        console.log("VirtualMachine deployed at:", vmAddress);
        console.log("ProxyFactory deployed at:", proxyFactoryAddress);
        console.log("InvariantChecker deployed at:", invariantCheckerAddress);
        console.log("ArithmeticProcessor deployed at:", rpnArithmeticAddress);
    }
}
