// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { vm } from '@chimera/Hevm.sol';

// Helpers
import { Panic } from '@recon/Panic.sol';

// Targets
// NOTE: Always import and apply them in alphabetical order, so much easier to debug!
import { AdminTargets } from './targets/AdminTargets.sol';
import { ClampedTargetHandlers } from './targets/ClampedTargetHandlers.sol';
import { DoomsdayTargets } from './targets/DoomsdayTargets.sol';
import { ExplodeTargets } from './targets/ExplodeTargets.sol';
import { MaliciousERC4626Targets } from './targets/MaliciousERC4626Targets.sol';
import { ManagersTargets } from './targets/ManagersTargets.sol';
import { OmniTargets } from './targets/OmniTargets.sol';
import { VirtualMachineTargets } from './targets/VirtualMachineTargets.sol';

import { MockFoTToken } from './mocks/MockFoTToken.sol';
import { StETHMock } from './mocks/StETHMock.sol';

abstract contract TargetFunctions is
    AdminTargets,
    ClampedTargetHandlers,
    DoomsdayTargets,
    ExplodeTargets,
    MaliciousERC4626Targets,
    ManagersTargets,
    OmniTargets,
    VirtualMachineTargets
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function mockFoTToken_setFee(uint256 _fee) public asActor {
        MockFoTToken(fotLike).setFee(_fee);
    }

    function stETHMock_setPooledEthPerShare(uint256 _pooledEthPerShare) public asActor {
        StETHMock(stETHLike).setPooledEthPerShare(_pooledEthPerShare);
    }

    function stETHMock_submit(uint256 _sharesAmount) public asActor {
        StETHMock(stETHLike).submit(_sharesAmount);
    }

    function stETHMock_transferShares(address _recipient, uint256 _sharesAmount) public asActor {
        StETHMock(stETHLike).transferShares(_recipient, _sharesAmount);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
