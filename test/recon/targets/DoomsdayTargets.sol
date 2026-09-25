// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseTargetFunctions } from '@chimera/BaseTargetFunctions.sol';
import { BeforeAfter } from '../BeforeAfter.sol';
import { Properties } from '../Properties.sol';
// Chimera deps
import { vm } from '@chimera/Hevm.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

import { CommandPacking } from 'src/CommandPacking.sol';
import { VMCommand, OP, DepositApproved, CallType } from 'src/DataModel.sol';
import { MockERC20 } from '@recon/MockERC20.sol';
import { MockFoTToken } from '../mocks/MockFoTToken.sol';
import { StETHMock } from '../mocks/StETHMock.sol';
import { OmniTarget } from '../mocks/OmniTarget.sol';
import { VMCommand, OP, VMState, DepositApproved, CallDataSurgery, SurgeryDescriptor } from 'src/DataModel.sol';
import { console2 } from 'forge-std/console2.sol';

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// Makes a handler have no side effects
    /// The fuzzer will call this anyway, and because it reverts it will be removed from shrinking
    /// Replace the "withGhosts" with "stateless" to make the code clean
    modifier stateless() {
        _;
        revert('stateless');
    }

    // NOTE: We limit the amount to 128 bits to avoid overflows for FoT Tokens and stETH
    function doomsday_depositApprovedExactAmountTest(uint128 amount, uint128 maxAmount) public stateless {
        // Actor approves the exact amount
        vm.prank(_getActor());
        MockERC20(_getAsset()).approve(address(virtualMachine), amount);

        vm.prank(_getActor());
        MockERC20(_getAsset()).mint(address(_getActor()), amount);

        uint8 MAX_DEPOSIT_REG = 0;

        /// NOTE:  Hardcode maxAmount to support maxDepositReg
        state.registers[MAX_DEPOSIT_REG] = abi.encode(maxAmount);

        // Deposit approved
        DepositApproved memory depositInfo =
            DepositApproved({ token: _getAsset(), destReg: destReg, maxDepositReg: MAX_DEPOSIT_REG }); /// TODO: Wrong maxDepositReg??

        VMCommand[] memory doomsdayCommands = new VMCommand[](2);
        doomsdayCommands[0] = VMCommand(OP.DEPOSIT_APPROVED, CommandPacking.packDepositApproved(depositInfo));
        doomsdayCommands[1] = VMCommand(OP.RETURN, CommandPacking.packReturn(destReg));

        uint256 balB4 = MockERC20(_getAsset()).balanceOf(address(virtualMachine));

        // Run the commands
        vm.prank(_getActor());
        bytes memory result;
        try virtualMachine.runVM(doomsdayCommands, state) returns (bytes memory _result) {
            result = _result;
        } catch {
            t(false, 'run vm should never revert with benign tokens');
        }

        uint256 balAfter = MockERC20(_getAsset()).balanceOf(address(virtualMachine));

        try this.doAbiDecode(result) returns (uint256 decodedAmount) {
            // AMT delta consistent
            if (balAfter > balB4) {
                eq(decodedAmount, balAfter - balB4, 'result amount is not correct');
            }

            // NOTE: LTE because FoT tokens can break this property
            if (maxAmount > amount) {
                lte(decodedAmount, amount, 'result amount is equal to amount when maxAmount is greater than amount');
            } else {
                lte(decodedAmount, maxAmount, 'result amount is equal to maxAmount when maxAmount is less than amount');
            }

            lte(decodedAmount, maxAmount, 'result amount is greater than maxAmount');
        } catch {
            t(false, 'doAbiDecode failed');
        }
    }

    function doomsday_callReturnsTheCorrectValue(
        uint8 callReturnReg,
        uint8 srcReg,
        uint256 absoluteValue // NOTE: Can be extended to be an arbitrary value
    )
        public
        stateless
    {
        require(srcReg < MAX_REGISTRY_COUNT, 'Src Return Reg must be less than 128');
        require(callReturnReg < MAX_REGISTRY_COUNT, 'Call Return Reg must be less than 128');
        require(srcReg != VOID_REGISTRY_FLAG);
        require(callReturnReg != VOID_REGISTRY_FLAG);

        require(callReturnReg != srcReg, 'Call Return Reg and Source Reg cannot be the same');

        require(keccak256(abi.encode(absoluteValue)) != keccak256(DIRTY_REGISTRY_FLAG));

        VMState memory initialState;
        initialState.registers = new bytes[](256);
        for (uint256 i = 0; i < 256; i++) {
            initialState.registers[i] = DIRTY_REGISTRY_FLAG;
        }

        omniTarget.setValue(absoluteValue);

        bytes memory initialCallValue = removeOffsetAssembly(abi.encode(abi.encodeCall(OmniTarget.returnValue, ())));

        // Calldata
        initialState.registers[srcReg] = initialCallValue;

        VMCommand[] memory doomsdayCommands = new VMCommand[](1);
        doomsdayCommands[0] = VMCommand(
            OP.CALL, CommandPacking.packCall(address(omniTarget), uint8(CallType.CALL), callReturnReg, srcReg, 0)
        );

        try virtualMachine.runWithState(doomsdayCommands, initialState) returns (VMState memory _state, bytes memory) {
            // Check that srsrcReg is unchanged
            // Check that dstReg has the value we expect
            t(keccak256(initialCallValue) == keccak256(_state.registers[srcReg]), 'Call src value is unchanged');
            try this.doAbiDecode(_state.registers[callReturnReg]) returns (uint256 decodedValue) {
                t(decodedValue == absoluteValue, 'Call return value is not correct');
            } catch {
                t(false, 'doAbiDecode failed');
            }
        } catch {
            t(false, 'Call should never revert with a known target (since we exclude the void register)');
        }
    }

    // Doomsday Test, deposit approved always works exactly for the correct amount
    // And returns the correct amount

    function doAbiDecode(bytes memory result) external pure returns (uint256) {
        return abi.decode(result, (uint256));
    }

    //* after execution the dest register should contain the remaining gas balance - TODO

    function doomsday_gas_in_register(uint8 gasReturnReg, uint8 gasreturnReg2, uint64 gasAmount) public stateless {
        // Ignore the 122 0x7A Register which is the void register
        require(gasReturnReg != VOID_REGISTRY_FLAG);
        require(gasreturnReg2 != VOID_REGISTRY_FLAG);
        require(gasReturnReg != gasreturnReg2, 'Gas Return Reg and Gas Return Reg 2 cannot be the same');

        uint256 initialGas = gasleft();
        console2.log('initialGas', initialGas);
        VMCommand[] memory doomsdayCommands = new VMCommand[](2);
        doomsdayCommands[0] = VMCommand(OP.REMAINING_GAS, CommandPacking.packRemainingGas(gasReturnReg));
        doomsdayCommands[1] = VMCommand(OP.REMAINING_GAS, CommandPacking.packRemainingGas(gasreturnReg2));

        // TODO: Mark all registries as dirty and check the return value that way
        VMState memory initialState;
        initialState.registers = new bytes[](MAX_REGISTRY_COUNT);
        for (uint256 i = 0; i < MAX_REGISTRY_COUNT; i++) {
            initialState.registers[i] = DIRTY_REGISTRY_FLAG;
        }

        // Run the commands
        vm.prank(_getActor());
        bytes memory result;

        try virtualMachine.runWithState(doomsdayCommands, initialState) returns (VMState memory _state, bytes memory) {
            t(
                keccak256(_state.registers[gasReturnReg]) != keccak256(DIRTY_REGISTRY_FLAG),
                'Gas Remaining cannot be the dirty flag value'
            );
            t(
                keccak256(_state.registers[gasreturnReg2]) != keccak256(DIRTY_REGISTRY_FLAG),
                'Gas Remaining cannot be the dirty flag value 2'
            );
            // Decode it
            uint256 gasAfter = abi.decode(_state.registers[gasReturnReg], (uint256));
            t(gasAfter > 0, 'Gas Remaining cannot be an empty value');
            t(gasAfter < initialGas, 'Gas Remaining should be less than initial gas');
            console2.log('gasAfter', gasAfter);
            console2.log('gasleft', gasleft());

            // NOTE: This breaks. Seems to be because foundry / medusa pass 12MLN gas
            // 1/64 is about 200k which is more than the gas left
            // So the gas left inside the VM is less than what we get when we resume execution
            // Must be because foundry gas usage is so high that 1/64 causes it to use less gas than what it sends
            // t(gasAfter > gasleft(), 'Gas Remaining should be greater than current gas left');

            uint256 gasAfter2 = abi.decode(_state.registers[gasreturnReg2], (uint256));
            t(gasAfter2 > 0, 'Gas Remaining cannot be an empty value 2');
            t(gasAfter2 < gasAfter, 'Gas Remaining is monotonically decreasing');
        } catch {
            // TODO: Should this revert every time?
            t(gasReturnReg <= MAX_REGISTRY_COUNT, 'Gas Remaining should never revert unless it goes OOG');
        }

        (VMState memory _state,) = virtualMachine.runWithState{ gas: gasAmount }(doomsdayCommands, initialState);
        uint256 gasAfter = abi.decode(_state.registers[gasReturnReg], (uint256));

        t(gasAfter < gasAmount, 'Gas in the VM cannot be more than gas passed');
    }

    function doomsday_safeTransferTest(uint256 amount) public stateless {
        // Setup recipient address (use an actor)
        address recipient = _getActor();

        // Mint tokens to the VirtualMachine
        MockERC20 token = MockERC20(_getAsset());
        token.mint(address(virtualMachine), amount);

        // Setup initial state with registers
        VMState memory initialState;
        initialState.registers = new bytes[](256);

        // Initialize all registers with dirty flag for safety
        for (uint256 i = 0; i < 256; i++) {
            initialState.registers[i] = DIRTY_REGISTRY_FLAG;
        }

        // Setup registers for SafeTransfer
        uint8 toReg = 10; // Register containing recipient address
        uint8 amountReg = 11; // Register containing transfer amount

        initialState.registers[toReg] = abi.encode(recipient);
        initialState.registers[amountReg] = abi.encode(amount);

        // Create SafeTransfer command
        VMCommand[] memory doomsdayCommands = new VMCommand[](1);
        doomsdayCommands[0] =
            VMCommand(OP.SAFE_TRANSFER, CommandPacking.packSafeTransfer(address(token), toReg, amountReg));

        // Get initial balances
        uint256 vmBalanceBefore = token.balanceOf(address(virtualMachine));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        // Calculate expected transfer amounts based on token type
        uint256 expectedVMDecrease = amount;
        uint256 expectedReceivedAmount = amount;

        if (_getAsset() == fotLike) {
            // For FoT tokens, calculate the expected amount after fee deduction
            uint256 fee = MockFoTToken(fotLike).fee();
            uint256 feeAmount = amount * fee / 10_000;
            expectedReceivedAmount = amount - feeAmount;
        } else if (_getAsset() == stETHLike) {
            // For stETH, account for rounding in shares conversion
            expectedVMDecrease = StETHMock(stETHLike).getTransferAmount(amount);
            expectedReceivedAmount = expectedVMDecrease;
        }

        // Execute the SafeTransfer command
        try virtualMachine.runWithState(doomsdayCommands, initialState) returns (VMState memory, bytes memory) {
            // Check final balances
            uint256 vmBalanceAfter = token.balanceOf(address(virtualMachine));
            uint256 recipientBalanceAfter = token.balanceOf(recipient);

            // Verify the correct amount was transferred
            if (amount > 0) {
                t(
                    vmBalanceBefore - vmBalanceAfter == expectedVMDecrease,
                    'VM balance should decrease by expected amount'
                );
                t(
                    recipientBalanceAfter - recipientBalanceBefore == expectedReceivedAmount,
                    'Recipient should receive expected amount'
                );
            } else {
                // For zero amount, balances should remain unchanged
                t(vmBalanceBefore == vmBalanceAfter, 'VM balance should remain unchanged for zero transfer');
                t(
                    recipientBalanceBefore == recipientBalanceAfter,
                    'Recipient balance should remain unchanged for zero transfer'
                );
            }
        } catch {
            // SafeTransfer should only revert if VM has insufficient balance
            t(amount > vmBalanceBefore, 'SafeTransfer should only revert for insufficient balance');
        }
    }
}
