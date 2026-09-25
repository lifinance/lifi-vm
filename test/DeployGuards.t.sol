// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { Test } from 'forge-std/Test.sol';
import { DeployVirtualMachine } from '../script/VirtualMachine.s.sol';
import { DeployProxyFactory } from '../script/ProxyFactory.s.sol';
import { ProxyFactory } from '../src/proxy/ProxyFactory.sol';
import { VirtualMachine } from '../src/VirtualMachine.sol';

/// @dev Covers the idempotency guards in the deploy helpers. Both helpers key off an address
///      derived from the salt alone, so an incumbent left by an aborted run is adopted unless
///      its identity is asserted. Everything the guards reject is immutable once the factory
///      is deployed, so these are the only checks standing between a partial rollout and a
///      fleet silently pinned to the wrong VM.
contract DeployGuardsTest is Test, DeployVirtualMachine, DeployProxyFactory {
    bytes32 constant VM_SALT = bytes32(uint256(0xdeadbeef1));
    bytes32 constant FACTORY_SALT = bytes32(uint256(0xdeadbeef2));

    /// @dev Runtime code that reverts with empty returndata: PUSH1 0, PUSH1 0, REVERT.
    bytes constant REVERTING_STUB = hex'60006000fd';
    /// @dev Runtime code that returns successfully with empty returndata: STOP.
    bytes constant EMPTY_RETURN_STUB = hex'00';

    function setUp() public withCreateX { }

    // --- VM guard ---

    function test_vmGuardReturnsIncumbentWhenBytecodeMatches() public {
        address first = deployVM(VM_SALT);
        assertEq(deployVM(VM_SALT), first, 'second run must adopt the identical incumbent');
    }

    function test_vmGuardRevertsWhenIncumbentHasDifferentBytecode() public {
        address deployed = deployVM(VM_SALT);
        vm.etch(deployed, REVERTING_STUB);

        vm.expectRevert('VM: existing VM at salt has different bytecode');
        this.deployVM(VM_SALT);
    }

    // --- ProxyFactory guard ---

    function test_factoryGuardReturnsIncumbentWhenBoundToSameVm() public {
        address vmAddress = deployVM(VM_SALT);
        address first = deployProxyFactory(FACTORY_SALT, vmAddress);
        assertEq(
            deployProxyFactory(FACTORY_SALT, vmAddress),
            first,
            'second run must adopt the factory already bound to this VM'
        );
    }

    function test_factoryGuardRevertsWhenBoundToDifferentVm() public {
        address vmAddress = deployVM(VM_SALT);
        deployProxyFactory(FACTORY_SALT, vmAddress);

        address otherVm = address(new VirtualMachine());
        vm.expectRevert('ProxyFactory: existing factory bound to a different VM');
        this.deployProxyFactory(FACTORY_SALT, otherVm);
    }

    function test_factoryGuardRevertsWhenBoundToDifferentCreateX() public {
        address vmAddress = deployVM(VM_SALT);
        address factory = deployProxyFactory(FACTORY_SALT, vmAddress);

        // Immutables live in runtime code, so etching a factory built against another CreateX
        // yields an incumbent that answers vmContract() correctly and create3Factory() wrongly.
        address rogue = address(new ProxyFactory(vmAddress, address(0xC0FFEE)));
        vm.etch(factory, rogue.code);

        vm.expectRevert('ProxyFactory: existing factory bound to a different CreateX');
        this.deployProxyFactory(FACTORY_SALT, vmAddress);
    }

    function test_factoryGuardRevertsWhenIncumbentCallReverts() public {
        address vmAddress = deployVM(VM_SALT);
        address factory = deployProxyFactory(FACTORY_SALT, vmAddress);
        vm.etch(factory, REVERTING_STUB);

        vm.expectRevert('ProxyFactory: address occupied by a non-factory contract');
        this.deployProxyFactory(FACTORY_SALT, vmAddress);
    }

    function test_factoryGuardRevertsWhenIncumbentReturnsNothing() public {
        address vmAddress = deployVM(VM_SALT);
        address factory = deployProxyFactory(FACTORY_SALT, vmAddress);
        vm.etch(factory, EMPTY_RETURN_STUB);

        vm.expectRevert('ProxyFactory: address occupied by a non-factory contract');
        this.deployProxyFactory(FACTORY_SALT, vmAddress);
    }
}
