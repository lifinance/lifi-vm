// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { InvariantChecker } from '../src/InvariantChecker.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { Test } from 'forge-std/Test.sol';

// Test wrapper to expose internal _checkAssertion for testing
contract InvariantCheckerWrapper is InvariantChecker {
    function checkAssertion(
        uint8 op,
        uint256[] calldata values,
        uint256 valueIdx
    )
        external
        pure
        returns (uint256 nextIdx)
    {
        return _checkAssertion(op, values, valueIdx);
    }
}

contract InvariantCheckerTest is SpecTestBase {
    InvariantChecker invariantChecker;
    InvariantCheckerWrapper wrapper;

    function setUp() public virtual override {
        super.setUp();
        invariantChecker = new InvariantChecker();
        wrapper = new InvariantCheckerWrapper();
        vm.label(address(invariantChecker), 'InvariantChecker');
        vm.label(address(wrapper), 'InvariantCheckerWrapper');
    }

    // Helper to test any comparison operation with pass/fail/boundary cases
    function assertComparisonOp(
        function(uint256, uint256) external pure fn,
        bytes4 errorSelector,
        uint256 passA,
        uint256 passB,
        uint256 failA,
        uint256 failB
    )
        internal
    {
        // Happy path
        fn(passA, passB);

        // Failure case
        vm.expectRevert(abi.encodeWithSelector(errorSelector, failA, failB));
        fn(failA, failB);
    }

    // Tests assertEqual with all cases in one test
    function test_assertEqual_Complete() public {
        // Happy paths including boundaries
        invariantChecker.assertEqual(42, 42);
        invariantChecker.assertEqual(0, 0);
        invariantChecker.assertEqual(type(uint256).max, type(uint256).max);

        // Failure cases
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertEqFailed.selector, 42, 43));
        invariantChecker.assertEqual(42, 43);

        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertEqFailed.selector, 0, type(uint256).max));
        invariantChecker.assertEqual(0, type(uint256).max);
    }

    // Tests assertNotEqual with all cases in one test
    function test_assertNotEqual_Complete() public {
        // Happy paths including boundaries
        invariantChecker.assertNotEqual(42, 43);
        invariantChecker.assertNotEqual(0, 1);
        invariantChecker.assertNotEqual(0, type(uint256).max);

        // Failure cases
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertNeqFailed.selector, 42, 42));
        invariantChecker.assertNotEqual(42, 42);

        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertNeqFailed.selector, 0, 0));
        invariantChecker.assertNotEqual(0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(InvariantChecker.AssertNeqFailed.selector, type(uint256).max, type(uint256).max)
        );
        invariantChecker.assertNotEqual(type(uint256).max, type(uint256).max);
    }

    // Tests assertLessThan with adjacent boundaries
    function test_assertLessThan_Complete() public {
        // Happy paths
        invariantChecker.assertLessThan(41, 42);
        invariantChecker.assertLessThan(0, 1);
        invariantChecker.assertLessThan(type(uint256).max - 1, type(uint256).max);

        // Adjacent boundary: a = b-1 (passes)
        invariantChecker.assertLessThan(99, 100);

        // Adjacent boundary: a = b (fails)
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertLtFailed.selector, 42, 42));
        invariantChecker.assertLessThan(42, 42);

        // Adjacent boundary: a = b+1 (fails)
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertLtFailed.selector, 43, 42));
        invariantChecker.assertLessThan(43, 42);
    }

    // Tests assertGreaterThan with adjacent boundaries
    function test_assertGreaterThan_Complete() public {
        // Happy paths
        invariantChecker.assertGreaterThan(42, 41);
        invariantChecker.assertGreaterThan(1, 0);
        invariantChecker.assertGreaterThan(type(uint256).max, type(uint256).max - 1);

        // Adjacent boundary: a = b+1 (passes)
        invariantChecker.assertGreaterThan(100, 99);

        // Adjacent boundary: a = b (fails)
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertGtFailed.selector, 42, 42));
        invariantChecker.assertGreaterThan(42, 42);

        // Adjacent boundary: a = b-1 (fails)
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertGtFailed.selector, 41, 42));
        invariantChecker.assertGreaterThan(41, 42);
    }

    // Tests assertLessThanEqual with edge cases
    function test_assertLessThanEqual_Complete() public {
        // Happy paths including equal case
        invariantChecker.assertLessThanEqual(41, 42);
        invariantChecker.assertLessThanEqual(42, 42); // Equal case - critical
        invariantChecker.assertLessThanEqual(0, 0);
        invariantChecker.assertLessThanEqual(type(uint256).max, type(uint256).max);

        // Failure: a > b
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertLteFailed.selector, 43, 42));
        invariantChecker.assertLessThanEqual(43, 42);
    }

    // Tests assertGreaterThanEqual with edge cases
    function test_assertGreaterThanEqual_Complete() public {
        // Happy paths including equal case
        invariantChecker.assertGreaterThanEqual(42, 41);
        invariantChecker.assertGreaterThanEqual(42, 42); // Equal case - critical
        invariantChecker.assertGreaterThanEqual(0, 0);
        invariantChecker.assertGreaterThanEqual(type(uint256).max, type(uint256).max);

        // Failure: a < b
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertGteFailed.selector, 41, 42));
        invariantChecker.assertGreaterThanEqual(41, 42);
    }

    // Tests assertInRange with complex edge cases
    function test_assertInRange_Complete() public {
        // Happy paths
        invariantChecker.assertInRange(50, 0, 100);
        invariantChecker.assertInRange(0, 0, 100); // At min boundary
        invariantChecker.assertInRange(100, 0, 100); // At max boundary
        invariantChecker.assertInRange(42, 42, 42); // min==max==value

        // Failures: value outside range
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertRangeFailed.selector, 101, 0, 100));
        invariantChecker.assertInRange(101, 0, 100);

        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertRangeFailed.selector, 0, 1, 100));
        invariantChecker.assertInRange(0, 1, 100);

        // Edge case: min > max with value == min (still fails)
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertRangeFailed.selector, 100, 100, 0));
        invariantChecker.assertInRange(100, 100, 0);

        // Edge case: min > max with value in "inverted" range
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.AssertRangeFailed.selector, 50, 100, 0));
        invariantChecker.assertInRange(50, 100, 0);
    }

    // Tests that _checkAssertion returns correct next index for each opcode
    function test_checkAssertion_IndexProgression_Verified() public view {
        uint256[] memory values = new uint256[](12);
        // Set up values that will pass all assertions
        values[0] = 10;
        values[1] = 10; // For assertEqual
        values[2] = 20;
        values[3] = 30; // For assertNotEqual
        values[4] = 40;
        values[5] = 50; // For assertLessThan
        values[6] = 60;
        values[7] = 50; // For assertGreaterThan
        values[8] = 70;
        values[9] = 70; // For assertLessThanEqual and assertGreaterThanEqual
        values[10] = 50; // min for range
        values[11] = 60; // max for range

        // Test opcodes with values that will pass
        // Op 1: assertEqual(10, 10)
        uint256 nextIdx = wrapper.checkAssertion(1, values, 0);
        assertEq(nextIdx, 2, 'Op 1 should advance by 2');

        // Op 2: assertNotEqual(20, 30)
        nextIdx = wrapper.checkAssertion(2, values, 2);
        assertEq(nextIdx, 4, 'Op 2 should advance by 2');

        // Op 3: assertLessThan(40, 50)
        nextIdx = wrapper.checkAssertion(3, values, 4);
        assertEq(nextIdx, 6, 'Op 3 should advance by 2');

        // Op 4: assertGreaterThan(60, 50)
        nextIdx = wrapper.checkAssertion(4, values, 6);
        assertEq(nextIdx, 8, 'Op 4 should advance by 2');

        // Op 5: assertLessThanEqual(70, 70)
        nextIdx = wrapper.checkAssertion(5, values, 8);
        assertEq(nextIdx, 10, 'Op 5 should advance by 2');

        // Op 6: assertGreaterThanEqual(70, 70)
        nextIdx = wrapper.checkAssertion(6, values, 8);
        assertEq(nextIdx, 10, 'Op 6 should advance by 2');

        // Test opcode 7 (should advance by 3) - assertInRange(60, 50, 60)
        values[6] = 55; // value within range
        nextIdx = wrapper.checkAssertion(7, values, 6);
        assertEq(nextIdx, 9, 'Opcode 7 should advance by 3');

        // Test opcode 0 (no-op, should not advance)
        nextIdx = wrapper.checkAssertion(0, values, 5);
        assertEq(nextIdx, 5, 'Opcode 0 should not advance index');
    }

    // Tests bounds safety with insufficient values
    function test_checkAssertion_BoundsSafety_Precise() public {
        // Exactly at boundary - should fail
        uint256[] memory values1 = new uint256[](1);
        values1[0] = 42;

        // All comparison ops need 2 values minimum
        for (uint8 op = 1; op <= 6; op++) {
            vm.expectRevert(); // Array OOB access
            wrapper.checkAssertion(op, values1, 0);
        }

        // Range check needs 3 values
        uint256[] memory values2 = new uint256[](2);
        values2[0] = 50;
        values2[1] = 0;

        vm.expectRevert(); // Array OOB access
        wrapper.checkAssertion(7, values2, 0);

        // Test reading past array end
        uint256[] memory values3 = new uint256[](3);
        values3[0] = 1;
        values3[1] = 2;
        values3[2] = 3;

        vm.expectRevert(); // Trying to read values[3] which doesn't exist
        wrapper.checkAssertion(1, values3, 2); // Would need indices 2 and 3
    }

    // Tests unknown opcode in middle of batch
    function test_batchAssert_UnknownOpcodeMiddle() public {
        uint8[] memory ops = new uint8[](3);
        ops[0] = 1; // assertEqual (consumes 2 values)
        ops[1] = 255; // Unknown opcode - should revert here
        ops[2] = 1; // Never reached

        uint256[] memory values = new uint256[](6);
        values[0] = 42;
        values[1] = 42; // For first assertEqual
        values[2] = 10;
        values[3] = 10; // Would be for unknown op
        values[4] = 20;
        values[5] = 20; // Would be for last assertEqual

        // First op succeeds internally, then reverts on unknown
        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.UnknownOpcode.selector, 255));
        invariantChecker.batchAssert(ops, values);
    }

    // Tests all operations in sequence with proper value consumption
    function test_batchAssert_ValueConsumption() public view {
        uint8[] memory ops = new uint8[](6);
        ops[0] = 1; // assertEqual (2 values)
        ops[1] = 0; // no-op (0 values)
        ops[2] = 2; // assertNotEqual (2 values)
        ops[3] = 3; // assertLessThan (2 values)
        ops[4] = 7; // assertInRange (3 values)
        ops[5] = 4; // assertGreaterThan (2 values)

        // Total values needed: 2 + 0 + 2 + 2 + 3 + 2 = 11
        uint256[] memory values = new uint256[](11);
        values[0] = 10;
        values[1] = 10; // Equal
        // no-op consumes nothing
        values[2] = 20;
        values[3] = 30; // Not equal
        // no-op consumes nothing
        values[4] = 40;
        values[5] = 50; // Less than
        values[6] = 75; // value for range
        values[7] = 50; // min for range
        values[8] = 100; // max for range
        values[9] = 60;
        values[10] = 50; // Greater than

        invariantChecker.batchAssert(ops, values);
    }

    // Tests that packOps follows left-packing rule
    function test_packOps_LeftPackingRule() public view {
        uint8[] memory ops = new uint8[](4);
        ops[0] = 0x12;
        ops[1] = 0x34;
        ops[2] = 0x56;
        ops[3] = 0x78;

        uint256 packed = invariantChecker.packOps(ops);

        // Manual decode to verify left-packing
        assertEq(uint8(packed >> 248), 0x12, 'First op at bits 248-255');
        assertEq(uint8(packed >> 240), 0x34, 'Second op at bits 240-247');
        assertEq(uint8(packed >> 232), 0x56, 'Third op at bits 232-239');
        assertEq(uint8(packed >> 224), 0x78, 'Fourth op at bits 224-231');

        // Rest should be zeros
        assertEq(packed & ((1 << 224) - 1), 0, 'Lower bits should be zero');
    }

    // Tests unknown opcode in middle of packed word
    function test_batchAssertPacked_UnknownOpcodeMiddle() public {
        // Pack: [1, 255, 1] - unknown in middle
        uint256 packed = (uint256(1) << 248) | (uint256(255) << 240) | (uint256(1) << 232);

        uint256[] memory values = new uint256[](6);
        values[0] = 42;
        values[1] = 42; // For first assertEqual
        values[2] = 10;
        values[3] = 10; // Would be for unknown
        values[4] = 20;
        values[5] = 20; // Would be for last assertEqual

        vm.expectRevert(abi.encodeWithSelector(InvariantChecker.UnknownOpcode.selector, 255));
        invariantChecker.batchAssertPacked(packed, 3, values);
    }

    // Tests edge case: exactly 32 operations
    function test_batchAssertPacked_Exactly32Ops() public view {
        uint8[] memory ops = new uint8[](32);
        uint256[] memory values = new uint256[](64);

        // Fill with assertEqual operations
        for (uint8 i = 0; i < 32; i++) {
            ops[i] = 1; // assertEqual
            values[i * 2] = i;
            values[i * 2 + 1] = i; // All equal pairs
        }

        uint256 packed = invariantChecker.packOps(ops);
        invariantChecker.batchAssertPacked(packed, 32, values);
    }

    // Tests 33 operations fails
    function test_batchAssertPacked_33OpsFails() public {
        uint8[] memory ops = new uint8[](33);
        for (uint8 i = 0; i < 33; i++) {
            ops[i] = 1;
        }

        vm.expectRevert(VmErrors.TooManyOperations.selector);
        invariantChecker.packOps(ops);
    }

    // Tests complex mixed batch with all opcodes and edge cases
    function test_batchMixed_Comprehensive() public view {
        uint8[] memory ops = new uint8[](7);
        ops[0] = 1; // assertEqual
        ops[1] = 2; // assertNotEqual
        ops[2] = 3; // assertLessThan
        ops[3] = 4; // assertGreaterThan
        ops[4] = 5; // assertLessThanEqual
        ops[5] = 6; // assertGreaterThanEqual
        ops[6] = 7; // assertInRange

        // Calculate exact values needed: 2+2+2+2+2+2+3 = 15
        uint256[] memory values = new uint256[](15);
        uint256 idx = 0;

        // assertEqual
        values[idx++] = 100;
        values[idx++] = 100;

        // assertNotEqual
        values[idx++] = 200;
        values[idx++] = 201;

        // assertLessThan
        values[idx++] = 10;
        values[idx++] = 20;

        // assertGreaterThan
        values[idx++] = 30;
        values[idx++] = 20;

        // assertLessThanEqual
        values[idx++] = 40;
        values[idx++] = 40; // Equal case

        // assertGreaterThanEqual
        values[idx++] = 50;
        values[idx++] = 50; // Equal case

        // assertInRange
        values[idx++] = 75; // value
        values[idx++] = 50; // min
        values[idx++] = 100; // max

        assertEq(idx, 15, 'Should have exactly 15 values');

        // Test unpacked
        invariantChecker.batchAssert(ops, values);

        // Test packed
        uint256 packed = invariantChecker.packOps(ops);
        invariantChecker.batchAssertPacked(packed, 7, values);
    }
}
