// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {VirtualMachine} from "../src/VirtualMachine.sol";

contract DeployVirtualMachine is Script, CreateXScript {
    function deployVM(bytes32 salt) public returns (address addr) {
        // get creation code
        bytes memory creationCode = type(VirtualMachine).creationCode;

        vm.startBroadcast();

        // Structure salt: [20 bytes: tx.origin | 1 byte: 0x00 | 11 bytes: entropy from input salt]
        // This matches CreateX's expected format for permissioned deploy
        bytes32 structuredSalt = bytes32(abi.encodePacked(tx.origin, hex"00", bytes11(uint88(uint256(salt)))));

        // Predicted address: computeCreate3Address guards the salt internally
        address predicted = computeCreate3Address(structuredSalt, tx.origin);

        // if already deployed, return — but only if it is the VM this script builds.
        // The address derives from the salt alone, not from the bytecode, so a VM left at this
        // salt by an aborted run would otherwise be adopted silently and then baked into
        // ProxyFactory.vmContract and every MinimalProxy.vmAddress, all of them immutable.
        // Note: runtime code carries the Solidity metadata hash, so a chain built with a
        // different toolchain (see DEPLOYMENTS.md on Tempo/4217) trips this on a re-run even
        // when the logic is identical. That is a deliberate stop, not a false alarm: resolve it
        // by confirming the incumbent build, never by weakening the check.
        if (predicted.code.length > 0) {
            vm.stopBroadcast();
            require(
                predicted.codehash == keccak256(type(VirtualMachine).runtimeCode),
                "VM: existing VM at salt has different bytecode"
            );
            return predicted;
        }

        // Deploy using CREATE3
        addr = create3(structuredSalt, creationCode);
        vm.stopBroadcast();

        // Verify the deployed address matches the prediction
        require(addr == predicted, "CREATE3: deployed address mismatch");
    }
}
