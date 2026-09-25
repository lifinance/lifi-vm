// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test, console } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';
import { VmErrors } from 'src/VmErrors.sol';
import { InvariantChecker } from 'src/InvariantChecker.sol';

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

// halmos --contract InvariantCheckerHalmosTest --loop 100
contract InvariantCheckerHalmosTest is Test, SymTest {
    InvariantCheckerWrapper internal impl;

    function setUp() public {
        impl = new InvariantCheckerWrapper();
    }

    // Extract the first 4 bytes (selector) from return/revert data
    function _sel(bytes memory data) internal pure returns (bytes4 s) {
        if (data.length < 4) return 0x00000000;
        assembly {
            s := mload(add(data, 32))
        }
    }

    // How many values are needed starting from idx to avoid OOB for a given op.
    function _needed(uint8 op) internal pure returns (uint256) {
        if (op == 0) return 1; // unconditional read of values[idx]
        if (op >= 1 && op <= 6) return 2;
        if (op == 7) return 3;
        return 1; // unknown still reads values[idx] before reverting
    }

    // Property 1: Single-op behavior matches the specified semantics (success nextIdx or correct revert selector).
    function check_single_op() external {
        uint256 opSym = svm.createUint(4, 'op'); // 0..15
        uint256[] memory values = new uint256[](10);
        for (uint256 i; i < values.length; ++i) {
            values[i] = svm.createUint256('value');
        }
        uint256 need = _needed(uint8(opSym));
        uint256 idxSym = svm.createUint256('idx');
        vm.assume(idxSym <= values.length - need); // avoid OOB
        bool expectSuccess;
        uint256 expectedNextIdx;
        bytes4 expectedSel;
        for (uint256 idx; idx < values.length; idx++) {
            if (idx == idxSym) {
                uint256 a = values[idx];
                if (opSym == 0) {
                    expectSuccess = true;
                    expectedNextIdx = idx;
                } else if (opSym == 1) {
                    uint256 b = values[idx + 1];
                    if (a != b) {
                        expectedSel = InvariantChecker.AssertEqFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 2) {
                    uint256 b = values[idx + 1];
                    if (a == b) {
                        expectedSel = InvariantChecker.AssertNeqFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 3) {
                    uint256 b = values[idx + 1];
                    if (a >= b) {
                        expectedSel = InvariantChecker.AssertLtFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 4) {
                    uint256 b = values[idx + 1];
                    if (a <= b) {
                        expectedSel = InvariantChecker.AssertGtFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 5) {
                    uint256 b = values[idx + 1];
                    if (a > b) {
                        expectedSel = InvariantChecker.AssertLteFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 6) {
                    uint256 b = values[idx + 1];
                    if (a < b) {
                        expectedSel = InvariantChecker.AssertGteFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 2;
                    }
                } else if (opSym == 7) {
                    uint256 minv = values[idx + 1];
                    uint256 maxv = values[idx + 2];
                    if (a < minv || a > maxv) {
                        expectedSel = InvariantChecker.AssertRangeFailed.selector;
                    } else {
                        expectSuccess = true;
                        expectedNextIdx = idx + 3;
                    }
                } else {
                    expectedSel = InvariantChecker.UnknownOpcode.selector;
                }

                // Call implementation
                (bool ok, bytes memory ret) =
                    address(impl).call(abi.encodeWithSelector(impl.checkAssertion.selector, opSym, values, idx));

                if (expectSuccess) {
                    assertTrue(ok, 'impl unexpectedly reverted');
                    uint256 got = abi.decode(ret, (uint256));
                    assertEq(got, expectedNextIdx, 'nextIdx mismatch');
                } else {
                    assertFalse(ok, 'impl unexpectedly succeeded');
                    assertEq(uint32(_sel(ret)), uint32(expectedSel), 'wrong revert selector');
                }
            }
        }
    }

    // Property 2: batchAssert and batchAssertPacked have equivalent behavior (success or same revert selector).
    function check_batch_vs_packed() external {
        uint256 opCountSym = svm.createUint(5, 'op'); // 0..31
        uint256[] memory values = new uint256[](3 * 31); // max possible needed
        for (uint256 i; i < values.length; ++i) {
            values[i] = svm.createUint256('value');
        }
        for (uint256 opCount; opCount < 32; ++opCount) {
            if (opCount == opCountSym) {
                uint8[] memory ops = new uint8[](opCount);
                for (uint8 i; i < opCount; ++i) {
                    ops[i] = uint8(svm.createUint(3, 'op')); // 0..7
                }
                uint256 packed = impl.packOps(ops);
                uint8 count = uint8(ops.length);
                (bool okA, bytes memory retA) =
                    address(impl).call(abi.encodeWithSelector(impl.batchAssert.selector, ops, values));
                (bool okB, bytes memory retB) =
                    address(impl).call(abi.encodeWithSelector(impl.batchAssertPacked.selector, packed, count, values));

                if (okA && okB) {
                    // both succeeded
                    assertEq(retA, retB, 'packed/unpacked success mismatch');
                } else if (!okA && !okB) {
                    // both reverted with the same selector
                    assertEq(uint32(_sel(retA)), uint32(_sel(retB)), 'packed/unpacked revert mismatch');
                } else {
                    emit log('packed/unpacked divergence');
                    assertFalse(true, 'divergence');
                }
            }
        }
    }

    // Property 3: Public assert* functions have the same behavior as _checkAssertion for corresponding ops.
    function check_public_asserts_match_internal(uint256 a, uint256 b, uint256 c) external {
        uint256 opSym = svm.createUint(3, 'op'); // 0..7
        vm.assume(opSym != 0); // skip NOP
        // Build values per op
        uint256[] memory values;
        if (opSym == 7) {
            values = new uint256[](3);
            values[0] = a; // value
            values[1] = b; // min
            values[2] = c; // max
        } else {
            values = new uint256[](2);
            values[0] = a;
            values[1] = b;
        }

        // Call the corresponding public assert
        bool okPub;
        bytes memory retPub;
        if (opSym == 1) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertEqual.selector, a, b));
        } else if (opSym == 2) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertNotEqual.selector, a, b));
        } else if (opSym == 3) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertLessThan.selector, a, b));
        } else if (opSym == 4) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertGreaterThan.selector, a, b));
        } else if (opSym == 5) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertLessThanEqual.selector, a, b));
        } else if (opSym == 6) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertGreaterThanEqual.selector, a, b));
        } else {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, a, b, c));
        }

        // Call internal via wrapper
        (bool okInt, bytes memory retInt) =
            address(impl).call(abi.encodeWithSelector(impl.checkAssertion.selector, opSym, values, 0));

        // Compare outcomes
        if (okPub && okInt) {
            // both succeed
            return;
        } else if (!okPub && !okInt) {
            assertEq(uint32(_sel(retPub)), uint32(_sel(retInt)), 'public/internal revert mismatch');
        } else {
            emit log('public/internal divergence');
            assertFalse(true, 'divergence');
        }
    }

    // Property 12: packOps boundaries and manual correctness for small arrays
    function check_packOps_boundaries_and_manual(uint8[] memory ops) external view {
        uint256 packed = impl.packOps(ops);
        uint256 manual;
        for (uint256 i = 0; i < ops.length; ++i) {
            manual |= uint256(ops[i]) << (248 - i * 8);
        }

        assertEq(packed, manual, 'packOps manual mismatch');
    }

    /// CLAMPED PROPERTIES ///

    // Property 4: batchAssertPacked reverts with TooManyOperations when opCount > 32 (guard).
    function check_batchPacked_too_many() external {
        uint256 packed = 0; // doesn't matter; guard triggers before use
        uint8 opCount = 33;
        uint256[] memory values = new uint256[](0);

        (bool ok, bytes memory ret) =
            address(impl).call(abi.encodeWithSelector(impl.batchAssertPacked.selector, packed, opCount, values));
        assertFalse(ok, 'batchAssertPacked should revert for >32 ops');
        assertEq(uint32(_sel(ret)), uint32(VmErrors.TooManyOperations.selector), 'wrong revert selector');
    }

    // Property 5: Public assert* functions have the same behavior as _checkAssertion for corresponding ops.
    function check_public_asserts_match_internal(uint8 op, uint256 a, uint256 b, uint256 c) external {
        vm.assume(op >= 1 && op <= 7);
        if (op == 7) {
            // Ensure a well-formed range
            vm.assume(b <= c);
        }

        uint256[] memory values;
        if (op == 7) {
            values = new uint256[](3);
            values[0] = a; // value
            values[1] = b; // min
            values[2] = c; // max
        } else {
            values = new uint256[](2);
            values[0] = a;
            values[1] = b;
        }

        bool okPub;
        bytes memory retPub;
        if (op == 1) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertEqual.selector, a, b));
        } else if (op == 2) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertNotEqual.selector, a, b));
        } else if (op == 3) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertLessThan.selector, a, b));
        } else if (op == 4) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertGreaterThan.selector, a, b));
        } else if (op == 5) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertLessThanEqual.selector, a, b));
        } else if (op == 6) {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertGreaterThanEqual.selector, a, b));
        } else {
            (okPub, retPub) = address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, a, b, c));
        }

        (bool okInt, bytes memory retInt) =
            address(impl).call(abi.encodeWithSelector(impl.checkAssertion.selector, op, values, 0));

        if (okPub && okInt) {
            return;
        } else if (!okPub && !okInt) {
            assertEq(uint32(_sel(retPub)), uint32(_sel(retInt)), 'public/internal revert mismatch');
        } else {
            assertFalse(true, 'divergence');
        }
    }

    // Property 6: assertInRange should be inclusive on both bounds when min <= max
    function check_inRange_inclusive_bounds(uint256 min, uint256 max) external {
        vm.assume(min <= max);

        // value == min should pass
        (bool okMin,) = address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, min, min, max));
        assertTrue(okMin, 'value == min must be accepted');

        // value == max should pass (this will fail if implementation uses 'value >= max')
        (bool okMax,) = address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, max, min, max));
        assertTrue(okMax, 'value == max must be accepted');
    }

    // Property 7: min > max and value >= min must revert (public + internal)
    function check_inRange_min_gt_max_reverts_ge_min(uint256 value, uint256 min, uint256 max) external {
        vm.assume(min > max);
        vm.assume(value == min);
        (bool okPub, bytes memory retPub) =
            address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, value, min, max));
        assertFalse(okPub, 'assertInRange should revert when min>max (>=min)');
        assertEq(
            uint32(_sel(retPub)),
            uint32(InvariantChecker.AssertRangeFailed.selector),
            'wrong revert selector (public, >=min)'
        );

        uint256[] memory values = new uint256[](3);
        values[0] = value;
        values[1] = min;
        values[2] = max;
        (bool okInt, bytes memory retInt) =
            address(impl).call(abi.encodeWithSelector(impl.checkAssertion.selector, uint8(7), values, 0));
        assertFalse(okInt, '_checkAssertion op7 should revert when min>max (>=min)');
        assertEq(
            uint32(_sel(retInt)),
            uint32(InvariantChecker.AssertRangeFailed.selector),
            'wrong revert selector (internal, >=min)'
        );
    }

    // Property 8: min > max and value < min must revert (public + internal)
    function check_inRange_min_gt_max_reverts_lt_min(uint256 value, uint256 min, uint256 max) external {
        vm.assume(min > max);
        // Pick value == max so (value < min) holds when min > max
        vm.assume(value == max);

        (bool okPub, bytes memory retPub) =
            address(impl).call(abi.encodeWithSelector(impl.assertInRange.selector, value, min, max));
        assertFalse(okPub, 'assertInRange should revert when min>max (<min)');
        assertEq(
            uint32(_sel(retPub)),
            uint32(InvariantChecker.AssertRangeFailed.selector),
            'wrong revert selector (public, <min)'
        );

        uint256[] memory values = new uint256[](3);
        values[0] = value;
        values[1] = min;
        values[2] = max;
        (bool okInt, bytes memory retInt) =
            address(impl).call(abi.encodeWithSelector(impl.checkAssertion.selector, uint8(7), values, 0));
        assertFalse(okInt, '_checkAssertion op7 should revert when min>max (<min)');
        assertEq(
            uint32(_sel(retInt)),
            uint32(InvariantChecker.AssertRangeFailed.selector),
            'wrong revert selector (internal, <min)'
        );
    }

    // Property 9: NOP (op 0) must not advance valueIdx in batch execution
    function check_nop_no_advance_in_batch(uint256 v0, uint256 v1) external {
        // Values used by op1 (eq): compare v0 and v1
        uint256[] memory values = new uint256[](2);
        values[0] = v0;
        values[1] = v1;

        // Program A: [NOP, EQ]
        uint8[] memory opsA = new uint8[](2);
        opsA[0] = 0; // nop
        opsA[1] = 1; // eq

        // Program B: [EQ]
        uint8[] memory opsB = new uint8[](1);
        opsB[0] = 1; // eq

        (bool okA, bytes memory retA) =
            address(impl).call(abi.encodeWithSelector(impl.batchAssert.selector, opsA, values));
        (bool okB, bytes memory retB) =
            address(impl).call(abi.encodeWithSelector(impl.batchAssert.selector, opsB, values));

        if (okA && okB) return;
        if (!okA && !okB) {
            assertEq(uint32(_sel(retA)), uint32(_sel(retB)), 'NOP advanced index');
        } else {
            assertFalse(true, 'divergence');
        }
    }

    // Property 10: batchAssertPacked boundaries: opCount == 0 succeeds; opCount == 32 (NOPs) succeeds
    function check_batchPacked_boundaries(uint256 v0, uint8 count) external {
        vm.assume(count < 33);
        uint256[] memory values1 = new uint256[](1);
        values1[0] = v0;
        (bool ok,) = address(impl).call(abi.encodeWithSelector(impl.batchAssertPacked.selector, 0, count, values1));
        assertTrue(ok, 'opCount < 33 NOPs should succeed');
    }

    // Property 11: packOps boundaries and manual correctness for small arrays
    function check_packOps_boundaries_and_manual(uint8 o0, uint8 o1, uint8 o2, uint8 o3) external {
        uint8[] memory ops4 = new uint8[](4);
        ops4[0] = o0;
        ops4[1] = o1;
        ops4[2] = o2;
        ops4[3] = o3;

        uint256 manual = (uint256(o0) << 248) | (uint256(o1) << 240) | (uint256(o2) << 232) | (uint256(o3) << 224);

        uint256 packed = impl.packOps(ops4);
        assertEq(packed, manual, 'packOps manual mismatch');
    }
}
