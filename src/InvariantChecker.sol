// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { VmErrors } from './VmErrors.sol';

/// @title InvariantChecker
/// @custom:version 1.0.0
/// @notice Companion contract for VM runtime invariant checking
/// @dev Gas-optimized contract that performs basic register value comparisons
contract InvariantChecker {
    error AssertEqFailed(uint256 a, uint256 b);
    error AssertNeqFailed(uint256 a, uint256 b);
    error AssertLtFailed(uint256 a, uint256 b);
    error AssertGtFailed(uint256 a, uint256 b);
    error AssertLteFailed(uint256 a, uint256 b);
    error AssertGteFailed(uint256 a, uint256 b);
    error AssertRangeFailed(uint256 value, uint256 min, uint256 max);
    error UnknownOpcode(uint8 opcode);

    /**
     * @notice Asserts that two values are equal
     */
    function assertEqual(uint256 a, uint256 b) external pure {
        if (a != b) revert AssertEqFailed(a, b);
    }

    /**
     * @notice Asserts that two values are not equal
     */
    function assertNotEqual(uint256 a, uint256 b) external pure {
        if (a == b) revert AssertNeqFailed(a, b);
    }

    /**
     * @notice Asserts that the first value is less than the second
     */
    function assertLessThan(uint256 a, uint256 b) external pure {
        if (a >= b) revert AssertLtFailed(a, b);
    }

    /**
     * @notice Asserts that the first value is greater than the second
     */
    function assertGreaterThan(uint256 a, uint256 b) external pure {
        if (a <= b) revert AssertGtFailed(a, b);
    }

    /**
     * @notice Asserts that the first value is less than or equal to the second
     */
    function assertLessThanEqual(uint256 a, uint256 b) external pure {
        if (a > b) revert AssertLteFailed(a, b);
    }

    /**
     * @notice Asserts that the first value is greater than or equal to the second
     */
    function assertGreaterThanEqual(uint256 a, uint256 b) external pure {
        if (a < b) revert AssertGteFailed(a, b);
    }

    /**
     * @notice Asserts that a value is within an inclusive range
     * @param value The value to check
     * @param min The minimum allowed value (inclusive)
     * @param max The maximum allowed value (inclusive)
     */
    function assertInRange(uint256 value, uint256 min, uint256 max) external pure {
        if (value < min || value > max) revert AssertRangeFailed(value, min, max);
    }

    /**
     * @notice Internal function to check a single assertion based on operation code
     * @param op Operation code (0=nop, 1=eq, 2=neq, 3=lt, 4=gt, 5=lte, 6=gte, 7=range)
     * @param values Array of values to check
     * @param valueIdx Current index in the values array
     * @return nextIdx The next index to use in the values array
     */
    function _checkAssertion(
        uint8 op,
        uint256[] calldata values,
        uint256 valueIdx
    )
        internal
        pure
        returns (uint256 nextIdx)
    {
        uint256 val1 = values[valueIdx];
        uint256 val2;

        unchecked {
            if (op == 1) {
                // Equal
                val2 = values[valueIdx + 1];
                if (val1 != val2) revert AssertEqFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 2) {
                // Not Equal
                val2 = values[valueIdx + 1];
                if (val1 == val2) revert AssertNeqFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 3) {
                // Less Than
                val2 = values[valueIdx + 1];
                if (val1 >= val2) revert AssertLtFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 4) {
                // Greater Than
                val2 = values[valueIdx + 1];
                if (val1 <= val2) revert AssertGtFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 5) {
                // Less Than Equal
                val2 = values[valueIdx + 1];
                if (val1 > val2) revert AssertLteFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 6) {
                // Greater Than Equal
                val2 = values[valueIdx + 1];
                if (val1 < val2) revert AssertGteFailed(val1, val2);
                return valueIdx + 2;
            } else if (op == 7) {
                // Range Check
                val2 = values[valueIdx + 1]; // min
                uint256 val3 = values[valueIdx + 2]; // max
                if (val1 < val2 || val1 > val3) revert AssertRangeFailed(val1, val2, val3);
                return valueIdx + 3;
            } else if (op != 0) {
                revert UnknownOpcode(op);
            }
        }
        return valueIdx;
    }

    /**
     * @notice Batch check multiple assertions to save gas on multiple comparisons
     * @param ops Array of operation codes (0=nop, 1=eq, 2=neq, 3=lt, 4=gt, 5=lte, 6=gte, 7=range)
     * @param values Array of values to check (for range check: [value, min, max])
     * @dev Op 0 (nop) performs no operation and doesn't consume any values
     * @dev For ops 1-6: values[valueIdx] and values[valueIdx+1] are compared
     * @dev For op 7: values[valueIdx], values[valueIdx+1], and values[valueIdx+2] are used
     * @dev Note: valueIdx is dynamically updated based on the operations executed
     */
    function batchAssert(uint8[] calldata ops, uint256[] calldata values) external pure {
        uint256 valueIdx = 0;
        uint256 opsLen = ops.length;
        for (uint256 i = 0; i < opsLen;) {
            valueIdx = _checkAssertion(ops[i], values, valueIdx);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Gas-optimized batch check using packed opcodes in a single uint256
     * @param packedOps A uint256 with packed operation codes, each taking 8 bits (0=nop, 1=eq, 2=neq, 3=lt, 4=gt, 5=lte, 6=gte, 7=range)
     * @param opCount Number of operations packed into packedOps (max 32)
     * @param values Array of values to check (for range check: [value, min, max])
     * @dev Op 0 (nop) performs no operation and doesn't consume any values
     * @dev For ops 1-6: values[valueIdx] and values[valueIdx+1] are compared
     * @dev For op 7: values[valueIdx], values[valueIdx+1], and values[valueIdx+2] are used
     * @dev Note: valueIdx is dynamically updated based on the operations executed
     */
    function batchAssertPacked(uint256 packedOps, uint8 opCount, uint256[] calldata values) external pure {
        if (opCount > 32) revert VmErrors.TooManyOperations();

        uint256 valueIdx = 0;

        for (uint8 i = 0; i < opCount;) {
            uint8 op = uint8(packedOps >> (248 - i * 8));
            valueIdx = _checkAssertion(op, values, valueIdx);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Helper function to pack operation codes into a single uint256
     * @param ops Array of operation codes to pack
     * @return packed The packed uint256 with all operation codes
     * @dev This is a pure view function primarily for testing
     */
    function packOps(uint8[] memory ops) external pure returns (uint256 packed) {
        if (ops.length > 32) revert VmErrors.TooManyOperations();

        uint256 opsLen = ops.length;
        packed = 0;
        for (uint8 i = 0; i < opsLen;) {
            packed |= uint256(ops[i]) << (248 - i * 8);
            unchecked {
                ++i;
            }
        }
    }
}
