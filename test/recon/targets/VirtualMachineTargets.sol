// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BaseTargetFunctions } from '@chimera/BaseTargetFunctions.sol';
import { BeforeAfter } from '../BeforeAfter.sol';
import { Properties } from '../Properties.sol';
// Chimera deps
import { vm } from '@chimera/Hevm.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

import 'src/VirtualMachine.sol';

abstract contract VirtualMachineTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function virtualMachine_runVM(VMCommand[] memory _commands, VMState memory initialState) public payable asActor {
        virtualMachine.runVM{ value: msg.value }(_commands, initialState);
    }

    function virtualMachine_runWithState(
        VMCommand[] memory _commands,
        VMState memory initialState
    )
        public
        payable
        asActor
    {
        virtualMachine.runWithState{ value: msg.value }(_commands, initialState);
    }
}
