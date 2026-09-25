// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { FoundryAsserts } from '@chimera/FoundryAsserts.sol';

import 'forge-std/console2.sol';

import { Test } from 'forge-std/Test.sol';
import { TargetFunctions } from './TargetFunctions.sol';
import { OmniTarget } from './mocks/OmniTarget.sol';
import { MockUSDT } from './mocks/MockUSDT.sol';
import { MockERC20 } from '@recon/MockERC20.sol';

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// forge test --match-test test_explode -vv

    function test_explode_static_conservation() public {
        explode_clampedStatic(0x1234);
        property_explode_no_revert_on_valid();
        property_explode_static_conservation();
        property_explode_non_interference();
    }

    function test_explode_dynamic_tail_partition() public {
        explode_clampedDynamic(0xABCDEF);
        property_explode_no_revert_on_valid();
        property_explode_dynamic_tail_partition();
        property_explode_non_interference();
    }

    function test_explode_alias_safety() public {
        explode_aliasSource(0x99);
        property_explode_no_revert_on_valid();
        property_explode_alias_safety();
    }

    function test_explode_single_static() public {
        explode_clampedStatic(0); // destCount clamps to 1
        property_explode_no_revert_on_valid();
        property_explode_static_conservation();
        property_explode_non_interference();
    }

    function test_explode_dictionary_untouched_registries() public {
        addExplodeToDictionary(0x7);
        performClampedCall();
        invariant_registries();
        property_untouched_registries();
    }

    function test_explode_mixed_partition() public {
        explode_clampedMixed(0x5EED);
        property_explode_no_revert_on_valid();
        property_explode_mixed_partition();
        property_explode_non_interference();
    }

    function test_explode_raw_revert_taxonomy() public {
        // destCount = 0 — rejected with DestinationCountOutOfBounds.
        explode_raw(uint256(0), hex'');
        property_explode_raw_revert_taxonomy();

        // Source register 0x40 sits past the 32-slot register file — rejected with RegisterIndexOOB.
        explode_raw((uint256(0x40) << 248) | (uint256(1) << 240), hex'');
        property_explode_raw_revert_taxonomy();
    }
}
