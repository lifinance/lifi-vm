// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import { CommandPacking } from '../src/CommandPacking.sol';
import {
    Call,
    CallDataBuild,
    Explode,
    DepositApproved,
    CallDataSurgery,
    SurgeryDescriptor,
    Return,
    AbiEncode,
    RemainingGas,
    NativeBalance,
    Log,
    LogVariant,
    SafeTransfer
} from '../src/DataModel.sol';
import { VmErrors } from '../src/VmErrors.sol';

contract CommandPackingTest is Test {
    // Constants for bit manipulation - computed using shifts instead of literals
    // Mask for bytes 1-31 (keeps only byte 0)
    bytes32 constant MASK_BYTE0_ONLY = bytes32(uint256(0xFF) << 248);

    // Mask for bytes 2-31 (keeps bytes 0-1)
    bytes32 constant MASK_BYTES01_ONLY = bytes32(uint256(0xFFFF) << 240);

    // Mask for clearing first 4 bytes (command type)
    bytes32 constant MASK_CLEAR_COMMAND_TYPE = bytes32((uint256(1) << 224) - 1);

    // Mask for clearing last 4 bytes (padding)
    bytes32 constant MASK_CLEAR_PADDING = bytes32(~uint256(0xFFFFFFFF));

    // Mask for CALL command (clears command type and padding)
    bytes32 constant MASK_CALL_RELEVANT = bytes32(((uint256(1) << 224) - 1) & ~uint256(0xFFFFFFFF));

    // Alternating bit pattern for testing
    bytes32 constant PATTERN_ALTERNATING =
        bytes32(uint256(0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA));

    // External wrapper functions for expectRevert tests
    function _tryPackCallDataBuild(bytes4 selector, uint8 destReg, bytes calldata blueprint) external pure {
        CommandPacking.packCallDataBuild(selector, destReg, blueprint);
    }

    function _tryPackAbiEncode(uint8 destReg, bytes calldata blueprint) external pure {
        CommandPacking.packAbiEncode(destReg, blueprint);
    }

    function _tryPackCallDataSurgery(CallDataSurgery calldata surgery) external pure {
        CommandPacking.packCallDataSurgery(surgery);
    }

    function _tryPackLog(uint8 variant, uint256 sourceRegs) external pure {
        CommandPacking.packLog(variant, sourceRegs);
    }

    function _tryUnpackCallDataSurgery(bytes32 packed) external pure {
        CommandPacking.unpackCallDataSurgery(packed);
    }

    function _tryUnpackCallDataBuild(bytes32 packed) external pure {
        CommandPacking.unpackCallDataBuild(packed);
    }

    function _tryUnpackAbiEncode(bytes32 packed) external pure {
        CommandPacking.unpackAbiEncode(packed);
    }

    function _tryPackExplode(uint8 sourceReg, uint8 destCount, uint8[] calldata destRegs) external pure {
        CommandPacking.packExplode(sourceReg, destCount, destRegs);
    }

    function _tryUnpackExplode(bytes32 packed) external pure {
        CommandPacking.unpackExplode(packed);
    }

    // Tests that CALL pack -> unpack preserves all fields
    function testFuzz_Call_RoundTrip(
        address target,
        uint8 callType,
        uint8 destReg,
        uint8 srcReg,
        uint8 valueReg
    )
        public
        pure
    {
        bytes32 packed = CommandPacking.packCall(target, callType, destReg, srcReg, valueReg);
        Call memory unpacked = CommandPacking.unpackCall(packed);

        assertEq(unpacked.target, target);
        assertEq(unpacked.callType, callType);
        assertEq(unpacked.destReg, destReg);
        assertEq(unpacked.srcReg, srcReg);
        assertEq(unpacked.valueReg, valueReg);
    }

    // Tests that CALLDATA_BUILD pack -> unpack preserves all fields
    function testFuzz_CallDataBuild_RoundTrip(bytes4 selector, uint8 destReg, bytes memory blueprint) public pure {
        vm.assume(blueprint.length <= 22);

        bytes32 packed = CommandPacking.packCallDataBuild(selector, destReg, blueprint);
        CallDataBuild memory unpacked = CommandPacking.unpackCallDataBuild(packed);

        assertEq(unpacked.selector, selector);
        assertEq(unpacked.destReg, destReg);
        assertEq(unpacked.blueprint, blueprint);
    }

    // Tests that EXPLODE pack -> unpack preserves all fields
    function testFuzz_Explode_RoundTrip(uint8 sourceReg, uint8 destCount) public {
        vm.assume(destCount > 0 && destCount <= 26);
        // Byte 0's high bit is a reserved dead flag; the canonical encoding requires it clear.
        vm.assume(sourceReg < 0x80);

        uint8[] memory destRegs = new uint8[](destCount);
        for (uint256 i = 0; i < destCount; i++) {
            destRegs[i] = uint8(uint256(keccak256(abi.encode(i))) % 256);
        }

        bytes32 packed = CommandPacking.packExplode(sourceReg, destCount, destRegs);
        Explode memory unpacked = CommandPacking.unpackExplode(packed);

        assertEq(unpacked.sourceReg, sourceReg);
        assertEq(unpacked.destCount, destCount);
        for (uint256 i = 0; i < destCount; i++) {
            assertEq(uint8(unpacked.packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - i * 8)), destRegs[i]);
        }
    }

    // Tests that DEPOSIT_APPROVED pack -> unpack preserves all fields
    function testFuzz_DepositApproved_RoundTrip(address token, uint8 destReg, uint8 maxDepositReg) public pure {
        DepositApproved memory deposit = DepositApproved(token, destReg, maxDepositReg);
        bytes32 packed = CommandPacking.packDepositApproved(deposit);
        DepositApproved memory unpacked = CommandPacking.unpackDepositApproved(packed);

        assertEq(unpacked.token, token);
        assertEq(unpacked.destReg, destReg);
        assertEq(unpacked.maxDepositReg, maxDepositReg);
    }

    // Tests that CALLDATA_SURGERY pack -> unpack preserves all fields
    function testFuzz_CallDataSurgery_RoundTrip(uint8 sourceReg, uint8 surgeryCount) public pure {
        vm.assume(surgeryCount <= 6);

        CallDataSurgery memory surgery;
        surgery.sourceReg = sourceReg;
        surgery.surgeryCount = surgeryCount;

        for (uint256 i = 0; i < surgeryCount; i++) {
            surgery.surgeries[i] =
                SurgeryDescriptor({ offset: uint16(i * 100), length: uint8(i + 1), replacementReg: uint8(i * 2) });
        }

        bytes32 packed = CommandPacking.packCallDataSurgery(surgery);
        CallDataSurgery memory unpacked = CommandPacking.unpackCallDataSurgery(packed);

        assertEq(unpacked.sourceReg, sourceReg);
        assertEq(unpacked.surgeryCount, surgeryCount);

        for (uint256 i = 0; i < surgeryCount; i++) {
            assertEq(unpacked.surgeries[i].offset, surgery.surgeries[i].offset);
            assertEq(unpacked.surgeries[i].length, surgery.surgeries[i].length);
            assertEq(unpacked.surgeries[i].replacementReg, surgery.surgeries[i].replacementReg);
        }
    }

    // Tests that RETURN pack -> unpack preserves all fields
    function testFuzz_Return_RoundTrip(uint8 sourceReg) public pure {
        bytes32 packed = CommandPacking.packReturn(sourceReg);
        Return memory unpacked = CommandPacking.unpackReturn(packed);

        assertEq(unpacked.sourceReg, sourceReg);
    }

    // Tests that ABI_ENCODE pack -> unpack preserves all fields
    function testFuzz_AbiEncode_RoundTrip(uint8 destReg, bytes memory blueprint) public pure {
        vm.assume(blueprint.length <= 27);

        bytes32 packed = CommandPacking.packAbiEncode(destReg, blueprint);
        AbiEncode memory unpacked = CommandPacking.unpackAbiEncode(packed);

        assertEq(unpacked.destReg, destReg);
        assertEq(unpacked.blueprint, blueprint);
    }

    // Tests that REMAINING_GAS pack -> unpack preserves all fields
    function testFuzz_RemainingGas_RoundTrip(uint8 destReg) public pure {
        bytes32 packed = CommandPacking.packRemainingGas(destReg);
        RemainingGas memory unpacked = CommandPacking.unpackRemainingGas(packed);

        assertEq(unpacked.destReg, destReg);
    }

    // Tests that NATIVE_BALANCE pack -> unpack preserves all fields
    function testFuzz_NativeBalance_RoundTrip(uint8 addrReg, uint8 destReg) public pure {
        bytes32 packed = CommandPacking.packNativeBalance(addrReg, destReg);
        NativeBalance memory unpacked = CommandPacking.unpackNativeBalance(packed);

        assertEq(unpacked.addrReg, addrReg);
        assertEq(unpacked.destReg, destReg);
    }

    // Tests that LOG pack -> unpack preserves all fields
    function testFuzz_Log_RoundTrip(uint8 variant, uint256 sourceRegs) public pure {
        vm.assume(variant <= uint8(LogVariant.DYNAMIC));
        vm.assume(sourceRegs <= type(uint208).max);

        bytes32 packed = CommandPacking.packLog(variant, sourceRegs);
        Log memory unpacked = CommandPacking.unpackLog(packed);

        assertEq(unpacked.variant, variant);
        assertEq(unpacked.sourceRegs, sourceRegs);
    }

    // Tests CALLDATA_BUILD with boundary blueprint lengths
    function test_CallDataBuild_BoundaryLengths() public pure {
        bytes4 selector = 0x12345678;
        uint8 destReg = 1;

        // Length 0
        bytes memory blueprint0 = new bytes(0);
        bytes32 packed0 = CommandPacking.packCallDataBuild(selector, destReg, blueprint0);
        CallDataBuild memory unpacked0 = CommandPacking.unpackCallDataBuild(packed0);
        assertEq(unpacked0.blueprint.length, 0);

        // Length 1
        bytes memory blueprint1 = new bytes(1);
        blueprint1[0] = 0xAA;
        bytes32 packed1 = CommandPacking.packCallDataBuild(selector, destReg, blueprint1);
        CallDataBuild memory unpacked1 = CommandPacking.unpackCallDataBuild(packed1);
        assertEq(unpacked1.blueprint.length, 1);
        assertEq(uint8(unpacked1.blueprint[0]), 0xAA);

        // Length 22 (maximum)
        bytes memory blueprint22 = new bytes(22);
        for (uint256 i = 0; i < 22; i++) {
            blueprint22[i] = bytes1(uint8(i));
        }
        bytes32 packed22 = CommandPacking.packCallDataBuild(selector, destReg, blueprint22);
        CallDataBuild memory unpacked22 = CommandPacking.unpackCallDataBuild(packed22);
        assertEq(unpacked22.blueprint.length, 22);
        for (uint256 i = 0; i < 22; i++) {
            assertEq(uint8(unpacked22.blueprint[i]), uint8(i));
        }
    }

    // Tests ABI_ENCODE with boundary blueprint lengths
    function test_AbiEncode_BoundaryLengths() public pure {
        uint8 destReg = 1;

        // Length 0
        bytes memory blueprint0 = new bytes(0);
        bytes32 packed0 = CommandPacking.packAbiEncode(destReg, blueprint0);
        AbiEncode memory unpacked0 = CommandPacking.unpackAbiEncode(packed0);
        assertEq(unpacked0.blueprint.length, 0);

        // Length 1
        bytes memory blueprint1 = new bytes(1);
        blueprint1[0] = 0xBB;
        bytes32 packed1 = CommandPacking.packAbiEncode(destReg, blueprint1);
        AbiEncode memory unpacked1 = CommandPacking.unpackAbiEncode(packed1);
        assertEq(unpacked1.blueprint.length, 1);
        assertEq(uint8(unpacked1.blueprint[0]), 0xBB);

        // Length 27 (maximum)
        bytes memory blueprint27 = new bytes(27);
        for (uint256 i = 0; i < 27; i++) {
            blueprint27[i] = bytes1(uint8(i + 100));
        }
        bytes32 packed27 = CommandPacking.packAbiEncode(destReg, blueprint27);
        AbiEncode memory unpacked27 = CommandPacking.unpackAbiEncode(packed27);
        assertEq(unpacked27.blueprint.length, 27);
        for (uint256 i = 0; i < 27; i++) {
            assertEq(uint8(unpacked27.blueprint[i]), uint8(i + 100));
        }
    }

    // Tests that unpackAbiEncode reverts when blueprint length > 27 bytes
    function test_UnpackAbiEncode_RevertsTooLarge() public {
        // Manually craft a packed value with blueprint length > 27
        bytes32 packed = bytes32(uint256(1)) << 248; // destReg at byte 0
        packed |= bytes32(uint256(28)) << 240; // blueprint length at byte 1 (28 > 27)

        vm.expectRevert(VmErrors.BlueprintTooLarge.selector);
        this._tryUnpackAbiEncode(packed);
    }

    // Tests EXPLODE with boundary destination counts
    function test_Explode_BoundaryDestCounts() public {
        uint8 sourceReg = 0x42;

        // destCount = 1 (minimum valid)
        uint8[] memory destRegs1 = new uint8[](1);
        destRegs1[0] = 0x11;
        bytes32 packed1 = CommandPacking.packExplode(sourceReg, 1, destRegs1);
        Explode memory unpacked1 = CommandPacking.unpackExplode(packed1);
        assertEq(unpacked1.destCount, 1);
        assertEq(uint8(unpacked1.packedDests >> CommandPacking.EXPLODE_DESTS_SHIFT_BASE), 0x11);

        // destCount = 26 (maximum)
        uint8[] memory destRegs26 = new uint8[](26);
        for (uint256 i = 0; i < 26; i++) {
            destRegs26[i] = uint8(i);
        }
        bytes32 packed26 = CommandPacking.packExplode(sourceReg, 26, destRegs26);
        Explode memory unpacked26 = CommandPacking.unpackExplode(packed26);
        assertEq(unpacked26.destCount, 26);
        for (uint256 i = 0; i < 26; i++) {
            assertEq(uint8(unpacked26.packedDests >> (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - i * 8)), uint8(i));
        }
    }

    // Tests CALLDATA_SURGERY with boundary surgery counts
    function test_CallDataSurgery_BoundarySurgeryCounts() public pure {
        uint8 sourceReg = 0x33;

        // surgeryCount = 0
        CallDataSurgery memory surgery0;
        surgery0.sourceReg = sourceReg;
        surgery0.surgeryCount = 0;
        bytes32 packed0 = CommandPacking.packCallDataSurgery(surgery0);
        CallDataSurgery memory unpacked0 = CommandPacking.unpackCallDataSurgery(packed0);
        assertEq(unpacked0.surgeryCount, 0);

        // surgeryCount = 6 (maximum)
        CallDataSurgery memory surgery6;
        surgery6.sourceReg = sourceReg;
        surgery6.surgeryCount = 6;
        for (uint256 i = 0; i < 6; i++) {
            surgery6.surgeries[i] =
                SurgeryDescriptor({ offset: uint16(0xFFFF - i), length: uint8(255 - i), replacementReg: uint8(i) });
        }
        bytes32 packed6 = CommandPacking.packCallDataSurgery(surgery6);
        CallDataSurgery memory unpacked6 = CommandPacking.unpackCallDataSurgery(packed6);
        assertEq(unpacked6.surgeryCount, 6);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(unpacked6.surgeries[i].offset, uint16(0xFFFF - i));
            assertEq(unpacked6.surgeries[i].length, uint8(255 - i));
            assertEq(unpacked6.surgeries[i].replacementReg, uint8(i));
        }
    }

    // Tests LOG with boundary variants
    function test_Log_BoundaryVariants() public pure {
        // Variant 0 (STATIC_1)
        bytes32 packed0 = CommandPacking.packLog(0, 0x12);
        Log memory unpacked0 = CommandPacking.unpackLog(packed0);
        assertEq(unpacked0.variant, 0);
        assertEq(unpacked0.sourceRegs, 0x12);

        // Variant 5 (DYNAMIC)
        bytes32 packed5 = CommandPacking.packLog(5, 0xABCDEF);
        Log memory unpacked5 = CommandPacking.unpackLog(packed5);
        assertEq(unpacked5.variant, 5);
        assertEq(unpacked5.sourceRegs, 0xABCDEF);

        // Maximum sourceRegs (2^208 - 1)
        uint256 maxRegs = type(uint208).max;
        bytes32 packedMax = CommandPacking.packLog(3, maxRegs);
        Log memory unpackedMax = CommandPacking.unpackLog(packedMax);
        assertEq(unpackedMax.sourceRegs, maxRegs);
    }

    // Tests with registers using dynamic flag
    function test_RegistersWithDynamicFlag() public pure {
        // Test with high bit set (dynamic flag)
        uint8 dynReg = 0x80 | 0x79; // Maximum non-void register with dynamic flag
        uint8 staticReg = 0x00; // Minimum register without dynamic flag

        bytes32 packed = CommandPacking.packCall(address(0x1234), 1, dynReg, staticReg, 0xFF);
        Call memory unpacked = CommandPacking.unpackCall(packed);

        assertEq(unpacked.destReg, dynReg);
        assertEq(unpacked.srcReg, staticReg);
        assertEq(unpacked.valueReg, 0xFF);
    }

    // Tests that CALLDATA_BUILD reverts when blueprint > 22 bytes
    function test_CallDataBuild_RevertsTooLarge() public {
        bytes memory blueprint = new bytes(23);
        for (uint256 i = 0; i < 23; i++) {
            blueprint[i] = bytes1(uint8(i));
        }

        vm.expectRevert(VmErrors.BlueprintTooLarge.selector);
        this._tryPackCallDataBuild(0x12345678, 1, blueprint);
    }

    // Tests that ABI_ENCODE reverts when blueprint > 27 bytes
    function test_AbiEncode_RevertsTooLarge() public {
        bytes memory blueprint = new bytes(28);
        for (uint256 i = 0; i < 28; i++) {
            blueprint[i] = bytes1(uint8(i));
        }

        vm.expectRevert(VmErrors.BlueprintTooLarge.selector);
        this._tryPackAbiEncode(1, blueprint);
    }

    // Tests that CALLDATA_SURGERY reverts when surgeryCount > 6
    function test_CallDataSurgery_RevertsTooManySurgeries() public {
        CallDataSurgery memory surgery;
        surgery.sourceReg = 1;
        surgery.surgeryCount = 7;

        vm.expectRevert(VmErrors.TooManySurgeries.selector);
        this._tryPackCallDataSurgery(surgery);
    }

    // Tests that LOG reverts when variant > DYNAMIC
    function test_Log_RevertsInvalidVariant() public {
        uint8 invalidVariant = uint8(LogVariant.DYNAMIC) + 1;

        vm.expectRevert(VmErrors.InvalidLogVariant.selector);
        this._tryPackLog(invalidVariant, 0);
    }

    // Tests that LOG reverts when sourceRegs > uint208.max
    function test_Log_RevertsSourceRegistersExceed208Bits() public {
        uint256 sourceRegs = uint256(type(uint208).max) + 1;

        vm.expectRevert(VmErrors.SourceRegistersExceed208Bits.selector);
        this._tryPackLog(0, sourceRegs);
    }

    // Tests that packExplode reverts when destCount = 0
    function test_PackExplode_RevertsDestCountZero() public {
        uint8 sourceReg = 0x42;
        uint8[] memory destRegs = new uint8[](0);

        vm.expectRevert(abi.encodeWithSelector(VmErrors.DestinationCountOutOfBounds.selector, 0));
        this._tryPackExplode(sourceReg, 0, destRegs);
    }

    // Tests that packExplode reverts when destCount > 26
    function test_PackExplode_RevertsDestCountTooLarge() public {
        uint8 sourceReg = 0x42;
        uint8[] memory destRegs = new uint8[](27);
        for (uint256 i = 0; i < 27; i++) {
            destRegs[i] = uint8(i);
        }

        vm.expectRevert(abi.encodeWithSelector(VmErrors.DestinationCountOutOfBounds.selector, 27));
        this._tryPackExplode(sourceReg, 27, destRegs);
    }

    // Tests that packExplode reverts when destRegs.length < destCount
    function test_PackExplode_RevertsDestCountMismatch() public {
        uint8 sourceReg = 0x42;
        uint8[] memory destRegs = new uint8[](5);
        for (uint256 i = 0; i < 5; i++) {
            destRegs[i] = uint8(i);
        }

        // Trying to pack 10 registers but only providing 5
        vm.expectRevert(abi.encodeWithSelector(VmErrors.DestinationCountMismatch.selector, 10, 5));
        this._tryPackExplode(sourceReg, 10, destRegs);
    }

    // Tests that unpackExplode reverts when destCount = 0
    function test_UnpackExplode_RevertsDestCountZero() public {
        // Manually craft a packed value with destCount = 0
        bytes32 packed = bytes32(uint256(0x42)) << 248; // sourceReg = 0x42
        packed |= bytes32(uint256(0)) << 240; // destCount = 0

        vm.expectRevert(abi.encodeWithSelector(VmErrors.DestinationCountOutOfBounds.selector, 0));
        this._tryUnpackExplode(packed);
    }

    // Tests that unpackExplode reverts when destCount > 26
    function test_UnpackExplode_RevertsDestCountTooLarge() public {
        // Manually craft a packed value with destCount = 27
        bytes32 packed = bytes32(uint256(0x42)) << 248; // sourceReg = 0x42
        packed |= bytes32(uint256(27)) << 240; // destCount = 27

        vm.expectRevert(abi.encodeWithSelector(VmErrors.DestinationCountOutOfBounds.selector, 27));
        this._tryUnpackExplode(packed);
    }

    // Tests that unpackExplode reverts when byte 0's reserved high bit (dead dynamic flag) is set
    function test_UnpackExplode_RevertsSourceHighBitSet() public {
        // sourceReg = 0x80 (high bit set), destCount = 1, one dest at byte 2, rest zero.
        bytes32 packed = bytes32(uint256(0x80)) << 248; // sourceReg high bit set
        packed |= bytes32(uint256(1)) << 240; // destCount = 1
        packed |= bytes32(uint256(0x05)) << CommandPacking.EXPLODE_DESTS_SHIFT_BASE; // dest[0]

        vm.expectRevert(VmErrors.NonZeroPadding.selector);
        this._tryUnpackExplode(packed);
    }

    // Tests that unpackExplode reverts when an unused destination byte (destCount < 26) is nonzero
    function test_UnpackExplode_RevertsNonZeroUnusedDestByte() public {
        // destCount = 1 so only byte 2 is a valid dest; set a stray byte at position 3.
        bytes32 packed = bytes32(uint256(0x42)) << 248; // sourceReg = 0x42
        packed |= bytes32(uint256(1)) << 240; // destCount = 1
        packed |= bytes32(uint256(0x05)) << CommandPacking.EXPLODE_DESTS_SHIFT_BASE; // dest[0] at byte 2
        // Stray nonzero byte 3 (one dest slot below the last used dest), padding still zero.
        packed |= bytes32(uint256(0xFF)) << (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - 8);

        vm.expectRevert(VmErrors.NonZeroPadding.selector);
        this._tryUnpackExplode(packed);
    }

    // Tests that unpackExplode reverts when the 28-31 padding is nonzero (even at max destCount)
    function test_UnpackExplode_RevertsNonZeroPadding() public {
        // destCount = 26 (max) so bytes 2-27 are all valid dests; only the 28-31 padding is reserved.
        bytes32 packed = bytes32(uint256(0x42)) << 248; // sourceReg = 0x42
        packed |= bytes32(uint256(26)) << 240; // destCount = 26
        for (uint256 i = 0; i < 26; i++) {
            packed |= bytes32(uint256(uint8(i + 1))) << (CommandPacking.EXPLODE_DESTS_SHIFT_BASE - i * 8);
        }
        packed |= bytes32(uint256(1)); // nonzero padding in bytes 28-31

        vm.expectRevert(VmErrors.NonZeroPadding.selector);
        this._tryUnpackExplode(packed);
    }

    // Tests that unpackCallDataBuild reverts when blueprint length > 22 bytes
    function test_UnpackCallDataBuild_RevertsTooLarge() public {
        // Manually craft a packed value with blueprint length > 22
        bytes32 packed = bytes32(uint256(0x12345678)) << 224; // selector
        packed |= bytes32(uint256(1)) << 216; // destReg
        packed |= bytes32(uint256(255)) << 208; // blueprint length (255 > 22)

        vm.expectRevert(VmErrors.BlueprintTooLarge.selector);
        this._tryUnpackCallDataBuild(packed);
    }

    // Tests that unpackCallDataBuild works correctly at the boundary (22 bytes)
    function test_UnpackCallDataBuild_MaxValidSize() public pure {
        // Manually craft a packed value with blueprint length = 22
        bytes32 packed = bytes32(uint256(0x12345678)) << 224; // selector
        packed |= bytes32(uint256(1)) << 216; // destReg
        packed |= bytes32(uint256(22)) << 208; // blueprint length (22, exactly at limit)

        // Fill the blueprint area with test data
        for (uint256 i = 0; i < 22; i++) {
            packed |= bytes32(uint256(uint8(i + 1))) << ((25 - i) * 8);
        }

        CallDataBuild memory unpacked = CommandPacking.unpackCallDataBuild(packed);
        assertEq(unpacked.blueprint.length, 22);
        for (uint256 i = 0; i < 22; i++) {
            assertEq(uint8(unpacked.blueprint[i]), uint8(i + 1));
        }
    }

    // Consolidated test for padding zeros across all commands
    function testFuzz_PaddingZero(uint8 reg1, uint8 reg2) public pure {
        // CALL: Last 8 bytes should be zero (refactored format)
        bytes32 packedCall = CommandPacking.packCall(address(0x1234), 1, reg1, reg2, 0);
        assertEq(uint64(uint256(packedCall)), 0);

        // RETURN: Bytes 1-31 should be zero
        bytes32 packedReturn = CommandPacking.packReturn(reg1);
        assertEq(uint256(packedReturn & ~MASK_BYTE0_ONLY), 0);

        // REMAINING_GAS: Bytes 1-31 should be zero
        bytes32 packedGas = CommandPacking.packRemainingGas(reg1);
        assertEq(uint256(packedGas & ~MASK_BYTE0_ONLY), 0);

        // NATIVE_BALANCE: Bytes 2-31 should be zero
        bytes32 packedBalance = CommandPacking.packNativeBalance(reg1, reg2);
        assertEq(uint256(packedBalance & ~MASK_BYTES01_ONLY), 0);

        // SAFE_TRANSFER: Bytes 22-31 should be zero
        bytes32 packedSafeTransfer = CommandPacking.packSafeTransfer(address(0x1234), reg1, reg2);
        assertEq(uint256(packedSafeTransfer) & 0x3FF, 0); // Last 10 bytes should be zero
    }

    // Tests SafeTransfer packing and unpacking round-trip
    function test_SafeTransfer_PackUnpack() public pure {
        address token = address(0x1234567890123456789012345678901234567890);
        uint8 toReg = 0x12;
        uint8 amountReg = 0x34;

        bytes32 packed = CommandPacking.packSafeTransfer(token, toReg, amountReg);
        SafeTransfer memory unpacked = CommandPacking.unpackSafeTransfer(packed);

        assertEq(unpacked.token, token);
        assertEq(unpacked.toReg, toReg);
        assertEq(unpacked.amountReg, amountReg);
    }

    // Tests SafeTransfer packing with boundary values
    function test_SafeTransfer_BoundaryValues() public pure {
        // Test with max uint8 values for registers
        address token = address(type(uint160).max);
        uint8 toReg = type(uint8).max;
        uint8 amountReg = type(uint8).max;

        bytes32 packed = CommandPacking.packSafeTransfer(token, toReg, amountReg);
        SafeTransfer memory unpacked = CommandPacking.unpackSafeTransfer(packed);

        assertEq(unpacked.token, token);
        assertEq(unpacked.toReg, toReg);
        assertEq(unpacked.amountReg, amountReg);
    }

    // Tests SafeTransfer packing with zero values
    function test_SafeTransfer_ZeroValues() public pure {
        address token = address(0);
        uint8 toReg = 0;
        uint8 amountReg = 0;

        bytes32 packed = CommandPacking.packSafeTransfer(token, toReg, amountReg);
        SafeTransfer memory unpacked = CommandPacking.unpackSafeTransfer(packed);

        assertEq(unpacked.token, token);
        assertEq(unpacked.toReg, toReg);
        assertEq(unpacked.amountReg, amountReg);
    }

    // Fuzz test for SafeTransfer packing/unpacking
    function testFuzz_SafeTransfer_PackUnpack(address token, uint8 toReg, uint8 amountReg) public pure {
        bytes32 packed = CommandPacking.packSafeTransfer(token, toReg, amountReg);
        SafeTransfer memory unpacked = CommandPacking.unpackSafeTransfer(packed);

        assertEq(unpacked.token, token);
        assertEq(unpacked.toReg, toReg);
        assertEq(unpacked.amountReg, amountReg);
    }
}
