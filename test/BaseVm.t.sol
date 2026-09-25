// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import { VirtualMachine } from '../src/VirtualMachine.sol';
import { VMState, VMCommand } from '../src/DataModel.sol';

abstract contract BaseVmTest is Test {
    VirtualMachine internal machine;

    function setUp() public virtual {
        machine = new VirtualMachine();
        vm.label(address(machine), 'VirtualMachine');
    }

    function run(VMCommand[] memory cmds, VMState memory s0) internal returns (VMState memory s1, bytes memory out) {
        return machine.runWithState(cmds, s0);
    }
}
