// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { BaseSetup } from '@chimera/BaseSetup.sol';
import { vm } from '@chimera/Hevm.sol';

// Managers
import { ActorManager } from '@recon/ActorManager.sol';
import { AssetManager } from '@recon/AssetManager.sol';

// Helpers
import { Utils } from '@recon/Utils.sol';

// Your deps
import { VirtualMachine } from 'src/VirtualMachine.sol';
import { ClampedStorage } from './ClampedStorage.sol';
import { OmniTarget } from './mocks/OmniTarget.sol';
import { MockERC4626Tester } from './mocks/MockERC4626Tester.sol';
import { MockFoTToken } from './mocks/MockFoTToken.sol';
import { MockUSDT } from './mocks/MockUSDT.sol';
import { StETHMock } from './mocks/StETHMock.sol';
import { MockReturnFalseOnFailure } from './mocks/MockReturnFalseOnFailure.sol';

abstract contract Setup is BaseSetup, ActorManager, AssetManager, Utils, ClampedStorage {
    VirtualMachine virtualMachine;

    OmniTarget omniTarget;
    address usdtLike;
    address fotLike;
    address stETHLike;
    address returnFalseERC20;

    MockERC4626Tester maliciousERC4626;

    bytes constant DIRTY_REGISTRY_FLAG = hex'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    uint256 constant VOID_REGISTRY_FLAG = 122;
    uint256 constant MAX_REGISTRY_COUNT = 128;

    // B4 and After is the State
    // We could possibly also pass that with the goal of making it do operations over time

    /// === Setup === ///
    /// This contains all calls to be performed in the tester constructor, both for Echidna and Foundry
    function setup() internal virtual override {
        virtualMachine = new VirtualMachine();
        omniTarget = new OmniTarget();

        /// === ASSETS === ///

        usdtLike = address(new MockUSDT());
        _addAsset(usdtLike);

        fotLike = address(new MockFoTToken());
        _addAsset(fotLike);

        stETHLike = address(new StETHMock());
        _addAsset(stETHLike);

        returnFalseERC20 = address(new MockReturnFalseOnFailure());
        _addAsset(returnFalseERC20);

        _newAsset(18); // WETH

        /// === VAULT === ///

        maliciousERC4626 = new MockERC4626Tester(_getAsset()); // ERC4626 with Malicious behaviour, uses safe token

        /// === ACTORS === ///

        _addActor(address(0x101));
        _addActor(address(0x202));

        /// === APPROVALS === ///

        address[] memory approvalArray = new address[](1);
        approvalArray[0] = address(virtualMachine);

        _finalizeAssetDeployment(_getActors(), approvalArray, type(uint88).max);

        /// HACK: Make the last 128 registries dirty as a flag that they were reached in any way
        for (uint256 i = 256 - MAX_REGISTRY_COUNT; i < 256; i++) {
            state.registers[i] = DIRTY_REGISTRY_FLAG;
        }
    }

    /// === MODIFIERS === ///
    /// Prank admin and actor

    modifier asAdmin() {
        vm.prank(address(this));
        _;
    }

    modifier asActor() {
        vm.prank(address(_getActor()));
        _;
    }

    /// === DICTIONARY LIKE === ///
    /// === DICTIONARY LIKE SWITCH CASES === ///
    /// This function allows to generated encoded calldata for our clamped targets
    // It returns the calldata
    // as well as the number of parameters
    // The number of params is used in the doomsdsay test to verify that the surgery worked
    function generateClampedCalldata(
        uint32 callIndex,
        bytes memory dstCalldata
    )
        internal
        returns (bytes memory, bytes memory, uint8)
    {
        uint8 paramCount;

        if (clampedTarget == address(omniTarget)) {
            callIndex %= 2;

            if (callIndex == 0) {
                uint256 value;
                assembly {
                    value := mload(add(dstCalldata, 0x20))
                }

                dstCalldata = abi.encodeCall(OmniTarget.setValue, (value));
                paramCount = 1;
            }

            if (callIndex == 1) {
                dstCalldata = abi.encodeCall(OmniTarget.returnValue, ());
                paramCount = 0;
            }
        }

        return (dstCalldata, removeOffsetAssembly(abi.encode(dstCalldata)), paramCount);
    }

    function shortcut_setClampedTarget(uint256 targetIndex) public {
        if (targetIndex == 0) {
            clampedTarget = address(omniTarget);
        }
        if (targetIndex == 1) {
            clampedTarget = address(maliciousERC4626);
        }
        if (targetIndex == 2) {
            clampedTarget = address(_getAsset());
        }
    }

    // Removing the offset so we can use abi.encoded data
    function removeOffsetAssembly(bytes memory data) internal pure returns (bytes memory result) {
        assembly {
            let len := sub(mload(data), 0x20) // subtract 32 from length
            result := mload(0x40) // free memory pointer
            mstore(result, len) // store new length

            // Copy data starting from offset 32
            let src := add(data, 0x40) // source: data + 32 (offset) + 32 (length position)
            let dest := add(result, 0x20)

            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dest, i), mload(add(src, i))) }

            mstore(0x40, add(dest, len)) // update free memory pointer
        }
    }
}
