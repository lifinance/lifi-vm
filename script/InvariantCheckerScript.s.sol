// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {InvariantChecker} from "../src/InvariantChecker.sol";

contract InvariantCheckerScript is Script, CreateXScript {
    function deployInvariantChecker(bytes32 salt) public returns (address addr) {
        // get creation code
        bytes memory creationCode = type(InvariantChecker).creationCode;

        vm.startBroadcast();

        // Structure salt: [20 bytes: tx.origin | 1 byte: 0x00 | 11 bytes: entropy from input salt]
        // This matches CreateX's expected format for permissioned deploy
        bytes32 structuredSalt = bytes32(abi.encodePacked(tx.origin, hex"00", bytes11(uint88(uint256(salt)))));

        // Predicted address: computeCreate3Address guards the salt internally
        address predicted = computeCreate3Address(structuredSalt, tx.origin);

        // if already deployed, return
        if (predicted.code.length > 0) {
            vm.stopBroadcast();
            return predicted;
        }

        // Deploy using CREATE3
        addr = create3(structuredSalt, creationCode);
        vm.stopBroadcast();

        // Verify the deployed address matches the prediction
        require(addr == predicted, "CREATE3: deployed address mismatch");
    }
}
