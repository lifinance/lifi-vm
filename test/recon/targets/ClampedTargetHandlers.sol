// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseTargetFunctions } from '@chimera/BaseTargetFunctions.sol';
import { BeforeAfter, OpType } from '../BeforeAfter.sol';
import { Properties } from '../Properties.sol';
// Chimera deps
import { vm } from '@chimera/Hevm.sol';

import { console2 } from 'forge-std/console2.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

import { OmniTarget } from '../mocks/OmniTarget.sol';
import { MockERC4626Tester } from '../mocks/MockERC4626Tester.sol';
import { MockERC20, ERC20 } from '@recon/MockERC20.sol';

import { CommandPacking } from 'src/CommandPacking.sol';
import {
    VMCommand,
    OP,
    VMState,
    DepositApproved,
    CallDataSurgery,
    SurgeryDescriptor,
    SafeTransfer
} from 'src/DataModel.sol';
import { Bp } from '../../lib/Bp.sol';

abstract contract ClampedTargetHandlers is BaseTargetFunctions, Properties {
    function clampedTargetAddToDictionary(
        uint8 callType,
        uint32 callIndex,
        bytes memory dstCalldata // NOTE: Effectively randomizes the arguments
    )
        public
    {
        if (clampedTarget == address(omniTarget)) {
            callIndex %= 2;

            if (callIndex == 0) {
                // Slice the first word of the dstCalldata
                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x20))
                }

                dstCalldata = abi.encodeCall(OmniTarget.setValue, (value));
            }

            if (callIndex == 1) {
                dstCalldata = abi.encodeCall(OmniTarget.returnValue, ());
            }
        }

        if (clampedTarget == address(_getAsset())) {
            callIndex %= 3;

            if (callIndex == 0) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                dstCalldata = abi.encodeCall(MockERC20.mint, (to, value));
            }

            if (callIndex == 1) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                dstCalldata = abi.encodeCall(ERC20.transfer, (to, value));
            }

            if (callIndex == 2) {
                address from;
                assembly {
                    from := mload(add(dstCalldata, 0x20))
                }

                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x40))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x60))
                }

                dstCalldata = abi.encodeCall(ERC20.transferFrom, (from, to, value));
            }
        }

        if (clampedTarget == address(maliciousERC4626)) {
            callIndex %= 4;

            if (callIndex == 0) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                dstCalldata = abi.encodeCall(MockERC4626Tester.deposit, (value, to));
            }

            if (callIndex == 1) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                dstCalldata = abi.encodeCall(MockERC4626Tester.mint, (value, to));
            }

            if (callIndex == 2) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                address owner;
                assembly {
                    owner := mload(add(dstCalldata, 0x60))
                }

                dstCalldata = abi.encodeCall(MockERC4626Tester.redeem, (value, to, owner));
            }

            if (callIndex == 3) {
                address to;
                assembly {
                    to := mload(add(dstCalldata, 0x20))
                }

                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x40))
                }

                address owner;
                assembly {
                    owner := mload(add(dstCalldata, 0x60))
                }

                dstCalldata = abi.encodeCall(MockERC4626Tester.withdraw, (value, to, owner));
            }
        }

        clampedAddPackedCallToDictionary(clampedTarget, callType, dstCalldata);
    }

    function clampedAddPackedCallWithValueToDictionary(
        address target,
        uint8 callType,
        bytes memory dstCalldata,
        uint256 value
    )
        public
    {
        state.registers[valueReg] = abi.encode(value);
        clampedAddPackedCallToDictionary(target, callType, dstCalldata);
    }

    function clampedAddPackedCallToDictionary(address target, uint8 callType, bytes memory dstCalldata) public {
        state.registers[calldataSRCReg] = removeOffsetAssembly(abi.encode(dstCalldata));
        commands.push(VMCommand(OP.CALL, CommandPacking.packCall(target, 1, destReg, calldataSRCReg, valueReg)));
    }

    // By convention it uses the destReg as the return value, and performs a normal call
    function addPackedCallToDictionary() public {
        commands.push(VMCommand(OP.CALL, CommandPacking.packCall(clampedTarget, 1, destReg, calldataSRCReg, valueReg)));
    }

    // By convention it uses the destReg as the return value
    function addReturnToDictionary() public {
        commands.push(VMCommand(OP.RETURN, CommandPacking.packReturn(destReg)));
    }

    function addDepositApprovedToDictionary() public {
        DepositApproved memory depositInfo = DepositApproved({ token: _getAsset(), destReg: destReg, maxDepositReg: 0 });
        commands.push(VMCommand(OP.DEPOSIT_APPROVED, CommandPacking.packDepositApproved(depositInfo)));
    }

    function addRemainingGasToDictionary() public {
        commands.push(VMCommand(OP.REMAINING_GAS, CommandPacking.packRemainingGas(destReg)));
    }

    function addNativeBalanceToDictionary() public {
        commands.push(VMCommand(OP.NATIVE_BALANCE, CommandPacking.packNativeBalance(srcReg, destReg)));
    }

    function addPackedCallDataBuildToDictionary(bytes4 selector, bytes memory blueprint) public {
        commands.push(VMCommand(OP.CALLDATA_BUILD, CommandPacking.packCallDataBuild(selector, destReg, blueprint)));
    }

    function shortcut_callDataSurgeryTest(uint32 callIndex, bytes memory dstCalldata) public {
        uint8 startRegistry = 10;
        // uint8 surgeryCount; // Values are in registry start + 1 to startRegistry

        (, bytes memory theAbiEncodedCalldata, uint8 surgeryCount) =
            generateClampedCalldata(callIndex, new bytes(dstCalldata.length));
        // Encode with empty values (Alternative is to encode with full dirty values)
        state.registers[startRegistry] = theAbiEncodedCalldata;

        SurgeryDescriptor[6] memory surgeries;

        for (uint16 i = 0; i < surgeryCount; i++) {
            bytes32 replacement;
            /// Assuming the calldata is removeOffsetAssembly(abi.encode((abi.encodeCall(FUNCTION, (PARAMS)))));
            // 0x00 -> Real Length
            // 0x20 -> Virtual Length
            // 0x40 -> Seletor
            // 0x44 -> First Parameter
            assembly {
                replacement := mload(add(dstCalldata, add(4, mul(add(i, 2), 0x20))))
            }
            uint8 replacementReg = uint8(startRegistry + i + 1);
            // Setup surgery Content
            state.registers[replacementReg] = abi.encode(replacement);

            // Similar math as above
            // We are performing surgery on the calldata and offsets are shifted by 32 bytes already
            surgeries[i] = SurgeryDescriptor({ offset: 32 + 4 + i * 32, length: 32, replacementReg: replacementReg });
        }

        CallDataSurgery memory surgery =
            CallDataSurgery({ sourceReg: startRegistry, surgeryCount: surgeryCount, surgeries: surgeries });
        commands.push(VMCommand(OP.CALLDATA_SURGERY, CommandPacking.packCallDataSurgery(surgery)));
    }

    // Blueprint
    // Open and Close containers-> Skipped

    // For each target, you'd want to use a hardcoded blueprint
    // Then make sure the fuzzer can populate a sufficient amount of registers

    // And then could also hardcode some of the shortcuts
    function shortcut_callDataBuildTest(uint32 callIndex, bytes memory srcCalldata) public {
        bytes4 selector;
        bytes memory blueprint;

        if (clampedTarget == address(omniTarget)) {
            callIndex %= 2;
            if (callIndex == 0) {
                uint256 value;
                assembly {
                    value := mload(add(srcCalldata, 0x20))
                }

                selector = bytes4(keccak256('setValue(uint256)'));
                state.registers[12] = abi.encode(value); // Update state as well
                blueprint = abi.encodePacked(Bp.s(12));
            }

            if (callIndex == 1) {
                selector = bytes4(keccak256('returnValue()'));
                blueprint = hex''; // Empty blueprint
            }

            // TODO: For each target you can add a hardcoded blueprint
        }

        commands.push(
            VMCommand(OP.CALLDATA_BUILD, CommandPacking.packCallDataBuild(selector, calldataSRCReg, blueprint))
        );
    }

    // NOTE: Hardcoded Surgery
    function shortCutSurgeryToDictionary() public {
        // Hardcode to calldataSRCReg which is used by clamped calls as well
        // Surgery count should be hardcoded to the number of params in the calldataSRCReg
        SurgeryDescriptor[6] memory surgeries;
        surgeries[0] = SurgeryDescriptor({ offset: 4, length: 32, replacementReg: destReg });

        CallDataSurgery memory surgery =
            CallDataSurgery({ sourceReg: calldataSRCReg, surgeryCount: 1, surgeries: surgeries });
        addPackedCallDataSurgeryToDictionary(surgery);
    }

    function addPackedCallDataSurgeryToDictionary(CallDataSurgery memory surgery) public {
        commands.push(VMCommand(OP.CALLDATA_SURGERY, CommandPacking.packCallDataSurgery(surgery)));
    }

    function addPackedAbiEncodeToDictionary(bytes memory blueprint) public {
        commands.push(VMCommand(OP.ABI_ENCODE, CommandPacking.packAbiEncode(destReg, blueprint)));
    }

    // NOTE: Perform the clamped call
    // We add unrolled logs to allow us to reward the fuzzer whenever it increases it's coverage
    function performClampedCall() public updateGhostsWithType(OpType.CLAMPED_CALL) asActor returns (bytes memory) {
        // TODO: State space enrichment here
        (VMState memory newState, bytes memory result) = virtualMachine.runWithState(commands, state);

        if (commands.length == 1) {
            console2.log('1 command was ran');

            // TODO: Inspect commands
            if (commands[0].op == OP.CALL) {
                console2.log('1 command was a call');
            }

            if (commands[0].op == OP.RETURN) {
                console2.log('1 command was a return');
            }

            if (commands[0].op == OP.DEPOSIT_APPROVED) {
                console2.log('1 command was a deposit approved');
            }

            if (commands[0].op == OP.REMAINING_GAS) {
                console2.log('1 command was a remaining gas');
            }

            if (commands[0].op == OP.NATIVE_BALANCE) {
                console2.log('1 command was a native balance');
            }

            if (commands[0].op == OP.LOG) {
                console2.log('1 command was a log');
            }

            if (commands[0].op == OP.ABI_ENCODE) {
                console2.log('1 command was a abi encode');
            }

            if (commands[0].op == OP.CALLDATA_BUILD) {
                console2.log('1 command was a calldata build');
            }

            if (commands[0].op == OP.CALLDATA_SURGERY) {
                console2.log('1 command was a calldata surgery');
            }

            if (commands[0].op == OP.EXPLODE) {
                console2.log('1 command was a explode');
            }
        }

        if (commands.length == 2) {
            console2.log('2 commands were ran');

            if (commands[0].op == OP.CALL) {
                console2.log('2 command was a call');
            }

            if (commands[0].op == OP.RETURN) {
                console2.log('2 command was a return');
            }

            if (commands[0].op == OP.DEPOSIT_APPROVED) {
                console2.log('2 command was a deposit approved');
            }

            if (commands[0].op == OP.REMAINING_GAS) {
                console2.log('2 command was a remaining gas');
            }

            if (commands[0].op == OP.NATIVE_BALANCE) {
                console2.log('2 command was a native balance');
            }

            if (commands[0].op == OP.LOG) {
                console2.log('2 command was a log');
            }

            if (commands[0].op == OP.ABI_ENCODE) {
                console2.log('2 command was a abi encode');
            }

            if (commands[0].op == OP.CALLDATA_BUILD) {
                console2.log('2 command was a calldata build');
            }

            if (commands[1].op == OP.CALL) {
                console2.log('2 command was a call');
            }

            if (commands[1].op == OP.RETURN) {
                console2.log('2 command was a return');
            }

            if (commands[1].op == OP.DEPOSIT_APPROVED) {
                console2.log('2 command was a deposit approved');
            }

            if (commands[1].op == OP.REMAINING_GAS) {
                console2.log('2 command was a remaining gas');
            }

            if (commands[1].op == OP.NATIVE_BALANCE) {
                console2.log('2 command was a native balance');
            }

            if (commands[1].op == OP.LOG) {
                console2.log('2 command was a log');
            }

            if (commands[1].op == OP.ABI_ENCODE) {
                console2.log('2 command was a abi encode');
            }

            if (commands[1].op == OP.CALLDATA_BUILD) {
                console2.log('2 command was a calldata build');
            }

            if (commands[1].op == OP.CALLDATA_SURGERY) {
                console2.log('2 command was a calldata surgery');
            }

            if (commands[1].op == OP.EXPLODE) {
                console2.log('2 command was a explode');
            }
        }

        if (commands.length == 3) {
            console2.log('3 commands were ran');

            if (commands[0].op == OP.CALL) {
                console2.log('0 command was a call');
            }

            if (commands[0].op == OP.RETURN) {
                console2.log('0 command was a return');
            }

            if (commands[0].op == OP.DEPOSIT_APPROVED) {
                console2.log('0 command was a deposit approved');
            }

            if (commands[0].op == OP.REMAINING_GAS) {
                console2.log('0 command was a remaining gas');
            }

            if (commands[0].op == OP.NATIVE_BALANCE) {
                console2.log('0 command was a native balance');
            }

            if (commands[0].op == OP.LOG) {
                console2.log('0 command was a log');
            }

            if (commands[0].op == OP.ABI_ENCODE) {
                console2.log('0 command was a abi encode');
            }

            if (commands[0].op == OP.CALLDATA_BUILD) {
                console2.log('0 command was a calldata build');
            }

            if (commands[0].op == OP.CALLDATA_SURGERY) {
                console2.log('0 command was a calldata surgery');
            }

            if (commands[0].op == OP.EXPLODE) {
                console2.log('0 command was a explode');
            }

            if (commands[1].op == OP.CALL) {
                console2.log('1 command was a call');
            }

            if (commands[1].op == OP.RETURN) {
                console2.log('1 command was a return');
            }

            if (commands[1].op == OP.DEPOSIT_APPROVED) {
                console2.log('1 command was a deposit approved');
            }

            if (commands[1].op == OP.REMAINING_GAS) {
                console2.log('1 command was a remaining gas');
            }

            if (commands[1].op == OP.NATIVE_BALANCE) {
                console2.log('1 command was a native balance');
            }

            if (commands[1].op == OP.LOG) {
                console2.log('1 command was a log');
            }

            if (commands[1].op == OP.ABI_ENCODE) {
                console2.log('1 command was a abi encode');
            }

            if (commands[1].op == OP.CALLDATA_BUILD) {
                console2.log('1 command was a calldata build');
            }

            if (commands[1].op == OP.CALLDATA_SURGERY) {
                console2.log('1 command was a calldata surgery');
            }

            if (commands[1].op == OP.EXPLODE) {
                console2.log('1 command was a explode');
            }

            if (commands[2].op == OP.CALL) {
                console2.log('2 command was a call');
            }

            if (commands[2].op == OP.RETURN) {
                console2.log('2 command was a return');
            }

            if (commands[2].op == OP.DEPOSIT_APPROVED) {
                console2.log('2 command was a deposit approved');
            }

            if (commands[2].op == OP.REMAINING_GAS) {
                console2.log('2 command was a remaining gas');
            }

            if (commands[2].op == OP.NATIVE_BALANCE) {
                console2.log('2 command was a native balance');
            }

            if (commands[2].op == OP.LOG) {
                console2.log('2 command was a log');
            }

            if (commands[2].op == OP.ABI_ENCODE) {
                console2.log('2 command was a abi encode');
            }

            if (commands[2].op == OP.CALLDATA_BUILD) {
                console2.log('2 command was a calldata build');
            }

            if (commands[2].op == OP.CALLDATA_SURGERY) {
                console2.log('2 command was a calldata surgery');
            }

            if (commands[2].op == OP.EXPLODE) {
                console2.log('2 command was a explode');
            }

            if (commands[0].op == OP.SAFE_TRANSFER) {
                console2.log('3 first command was a safe transfer');
            }

            if (commands[1].op == OP.SAFE_TRANSFER) {
                console2.log('3 second command was a safe transfer');
            }

            if (commands[2].op == OP.SAFE_TRANSFER) {
                console2.log('3 third command was a safe transfer');
            }
        }

        if (commands.length > 3) {
            console2.log('Many commands were run');
        }

        state = newState;
        return result;
    }

    /// === SAFE_TRANSFER DICTIONARY FUNCTIONS === ///

    function addSafeTransferToDictionary(address token, address recipient, uint256 amount) public {
        // Setup registers for SafeTransfer
        state.registers[addressSrcReg] = abi.encode(recipient);
        state.registers[srcReg] = abi.encode(amount);

        // Add SafeTransfer command to dictionary
        commands.push(VMCommand(OP.SAFE_TRANSFER, CommandPacking.packSafeTransfer(token, addressSrcReg, srcReg)));
    }

    function addSafeTransferRandomAssetToRandomActorDictionary(uint256 amount) public {
        addSafeTransferToDictionary(_getAsset(), _getActor(), amount);
    }

    function addSafeTransferZeroAmountToDictionary(address token, address recipient) public {
        addSafeTransferToDictionary(_getAsset(), _getActor(), 0);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
