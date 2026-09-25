// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './DataModel.sol';
import './RegisterFile.sol';
import './CommandPacking.sol';
import './BlueprintEncoder.sol';
import './SurgeryOPS.sol';
import './DepositApproved.sol';
import './VMLogLib.sol';
import './SafeTransferLib.sol';
import './Explode.sol';
import './VmErrors.sol';
import './RegisterHelpers.sol';

/// @title VirtualMachine
/// @custom:version 1.1.0
/// @notice Main VM execution engine that interprets and executes command sequences with register-based state management
contract VirtualMachine {
    using RegisterHelpers for uint8;
    using RegisterHelpers for uint256;
    using RegisterHelpers for bytes;
    using RegisterFile for bytes[];

    /* ───────────────────────── PUBLIC ENTRYPOINTS ───────────────────── */

    /// @notice Executes a command sequence and returns the output from a RETURN opcode.
    /// @dev Commands execute sequentially with shared register state until RETURN or completion.
    function runVM(VMCommand[] calldata commands, VMState memory initialState) public payable returns (bytes memory) {
        return _run(commands, initialState);
    }

    /// @notice Executes commands with state introspection capabilities.
    /// @dev Returns both the final state snapshot and execution output for debugging/analysis.
    function runWithState(
        VMCommand[] calldata commands,
        VMState memory initialState
    )
        public
        payable
        returns (VMState memory, bytes memory)
    {
        bytes memory out = _run(commands, initialState); // state mutated in‑place
        return (initialState, out);
    }

    /* ────────────────────────── CORE EXECUTION ENGINE ─────────────────────── */

    /// @dev Primary execution loop with inline opcode handlers for maximum efficiency.
    /// All opcodes are handled within this function to eliminate call overhead and
    /// maintain optimal register access patterns.
    function _run(VMCommand[] calldata commands, VMState memory vmState) internal returns (bytes memory) {
        uint256 len = commands.length;

        for (uint256 i; i < len;) {
            VMCommand calldata cmd = commands[i];
            OP op = cmd.op;
            bytes32 data = cmd.data;

            if (op == OP.CALL) {
                // External contract invocation with configurable call semantics
                Call memory c = CommandPacking.unpackCall(data);
                bytes memory callData = vmState.registers.get(c.srcReg.idx());

                // Check that calldata length is at least 32 bytes (32 for the length word + 0+ bytes for the selector)
                if (callData.length < 32) revert VmErrors.InvalidCallDataLength();

                // Skip the first 32 bytes (length prefix) by adjusting the pointer
                assembly {
                    callData := add(callData, 0x20)
                }

                uint256 value;
                if (c.callType == uint8(CallType.VALUECALL)) {
                    bytes memory v = vmState.registers.getStatic(c.valueReg.idx());
                    assembly {
                        value := mload(add(v, 32))
                    }
                }

                (bool success, bytes memory ret) = _performCall(c.target, CallType(c.callType), callData, value);
                if (!success) {
                    // Bubble up the exact revert data from the failed call
                    assembly ('memory-safe') {
                        let p := mload(0x40)
                        returndatacopy(p, 0, returndatasize())
                        revert(p, returndatasize())
                    }
                }

                // Dynamic register allocation flag (MSB) determines storage strategy
                if (c.destReg.isDyn()) {
                    vmState.registers.setDynamic(c.destReg.idx(), ret);
                } else {
                    vmState.registers.set(c.destReg.idx(), ret);
                }
            } else if (op == OP.CALLDATA_BUILD) {
                // Template-based calldata construction from blueprint specification
                CallDataBuild memory cdb = CommandPacking.unpackCallDataBuild(data);
                bytes memory built =
                    BlueprintEncoder.encodeFromBlueprint(cdb.selector, cdb.blueprint, vmState.registers);
                vmState.registers.set(cdb.destReg.idx(), built);
            } else if (op == OP.EXPLODE) {
                // Structured data decomposition into individual register slots
                // e.g: (uint,uint,uint) into (r0, r1, r2)
                Explode memory e = CommandPacking.unpackExplode(data);
                ExplodeLib.execute(vmState.registers, e);
            } else if (op == OP.DEPOSIT_APPROVED) {
                // ERC20 allowance verification and transfer
                DepositApproved memory d = CommandPacking.unpackDepositApproved(data);
                // Read the max deposit value from the register
                bytes memory maxDepositBytes = vmState.registers.getStatic(d.maxDepositReg.idx());
                uint256 maxDeposit;
                assembly {
                    maxDeposit := mload(add(maxDepositBytes, 32))
                }
                uint256 depositedAmount = DepositApprovedLib.depositApproved(d, maxDeposit);
                vmState.registers.set(d.destReg.idx(), RegisterHelpers.encUint(depositedAmount));
            } else if (op == OP.CALLDATA_SURGERY) {
                // In-place calldata modification via targeted byte operations
                CallDataSurgery memory s = CommandPacking.unpackCallDataSurgery(data);
                SurgeryOps.performSurgery(vmState.registers, s.sourceReg, s.surgeries, s.surgeryCount);
            } else if (op == OP.RETURN) {
                // Immediate execution termination with register data output
                Return memory r = CommandPacking.unpackReturn(data);
                return vmState.registers.get(r.sourceReg.idx());
            } else if (op == OP.ABI_ENCODE) {
                // Direct ABI encoding from register data via blueprint template
                AbiEncode memory ae = CommandPacking.unpackAbiEncode(data);
                bytes memory enc = BlueprintEncoder.encodeData(ae.blueprint, vmState.registers);
                vmState.registers.set(ae.destReg.idx(), enc);
            } else if (op == OP.REMAINING_GAS) {
                // Store current remaining gas in register as raw uint256
                RemainingGas memory rg = CommandPacking.unpackRemainingGas(data);
                vmState.registers.set(rg.destReg.idx(), RegisterHelpers.encUint(gasleft()));
            } else if (op == OP.NATIVE_BALANCE) {
                // Store current native token balance in register as raw uint256
                NativeBalance memory nb = CommandPacking.unpackNativeBalance(data);
                address targetAddress = vmState.registers.get(nb.addrReg.idx()).asAddress();
                vmState.registers.set(nb.destReg.idx(), RegisterHelpers.encUint(targetAddress.balance));
            } else if (op == OP.LOG) {
                // Emit log events with data from registers
                Log memory log = CommandPacking.unpackLog(data);
                VMLogLib.execute(vmState, log);
            } else if (op == OP.SAFE_TRANSFER) {
                // Safely transfer ERC20 tokens using Solady
                SafeTransfer memory safeTransfer = CommandPacking.unpackSafeTransfer(data);
                SafeTransferVMLib.execute(vmState.registers, safeTransfer);
            } else {
                revert VmErrors.InvalidOpcode(uint8(op));
            }

            unchecked {
                ++i;
            }
        }

        // Execution completed without explicit RETURN - return empty bytes
        return '';
    }

    /* ────────────────────────── CALL DISPATCH LAYER ────────────────────── */

    /// @dev Low-level call dispatcher supporting all EVM call semantics.
    /// Centralizes call logic to ensure consistent error handling and gas management.
    function _performCall(
        address target,
        CallType t,
        bytes memory data,
        uint256 value
    )
        internal
        returns (bool ok, bytes memory ret)
    {
        // Removing this altogether would require changing the CALL
        // variants and compiler implementation.
        if (t == CallType.DELEGATECALL) revert VmErrors.Disallowed();
        if (t == CallType.CALL) return target.call(data);
        if (t == CallType.STATICCALL) return target.staticcall(data);
        // VALUECALL
        return target.call{ value: value }(data);
    }

    /* ───────────────────────── ETHER HANDLING ───────────────────── */

    /// @dev Accept direct ether transfers for value call operations
    fallback() external payable { }
    receive() external payable { }
}
