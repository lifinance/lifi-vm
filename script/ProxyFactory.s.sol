// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {CREATEX_ADDRESS} from "createx-forge/script/CreateX.d.sol";
import "../src/proxy/ProxyFactory.sol";

contract DeployProxyFactory is Script, CreateXScript {
    function deployProxyFactory(bytes32 salt, address vmContract) public returns (address addr) {
        // append constructor args to creation code
        bytes memory creationCode = abi.encodePacked(
            type(ProxyFactory).creationCode,
            abi.encode(vmContract, CREATEX_ADDRESS)
        );

        vm.startBroadcast();

        // Structure salt: [20 bytes: tx.origin | 1 byte: 0x00 | 11 bytes: entropy from input salt]
        // This matches CreateX's expected format for permissioned deploy
        bytes32 structuredSalt = bytes32(abi.encodePacked(tx.origin, hex"00", bytes11(uint88(uint256(salt)))));

        // Predicted address: computeCreate3Address guards the salt internally
        address predicted = computeCreate3Address(structuredSalt, tx.origin);

        // if already deployed, return — but only if it is bound to the VM we just resolved and to
        // the CreateX this script uses. Both are immutable: a factory pointing at another VM can
        // never serve this one, and a factory pointing at another CreateX derives proxy addresses
        // this script cannot predict (see src/proxy/ProxyFactory.sol, predictProxyAddress).
        // Both getters are reached by raw staticcall: against a non-factory incumbent a typed call
        // reverts with empty returndata, hiding the message written for exactly this case.
        if (predicted.code.length > 0) {
            vm.stopBroadcast();
            (bool ok, bytes memory data) = predicted.staticcall(abi.encodeWithSignature("vmContract()"));
            require(ok && data.length == 32, "ProxyFactory: address occupied by a non-factory contract");
            require(
                abi.decode(data, (address)) == vmContract,
                "ProxyFactory: existing factory bound to a different VM"
            );
            (ok, data) = predicted.staticcall(abi.encodeWithSignature("create3Factory()"));
            require(ok && data.length == 32, "ProxyFactory: address occupied by a non-factory contract");
            require(
                abi.decode(data, (address)) == CREATEX_ADDRESS,
                "ProxyFactory: existing factory bound to a different CreateX"
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
