// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { Test, console } from 'forge-std/Test.sol';
import { SymTest } from 'halmos-cheatcodes/SymTest.sol';

import { ArithmeticProcessor } from 'src/RPNArithmetic.sol';
import { RPNEvaluationDeOptimized } from './mocks/RPNEvaluationDeOptimized.sol';

// halmos --match-contract ArithmeticProcessorHalmosTest --loop 100 --array-lengths "toks={3}"
contract ArithmeticProcessorHalmosTest is Test, SymTest {
    ArithmeticProcessor processor;
    RPNEvaluationDeOptimized deOptimized;
    // OpCode constants matching implementation
    uint8 constant PUSH_REG_FLAG = 0x80;
    uint8 constant OP_ADD = 0;
    uint8 constant OP_SUB = 1;
    uint8 constant OP_MUL = 2;
    uint8 constant OP_DIV_DOWN = 3;
    uint8 constant OP_DIV_UP = 4;
    uint8 constant OP_MIN = 5;
    uint8 constant OP_MAX = 6;

    function setUp() public {
        processor = new ArithmeticProcessor();
        deOptimized = new RPNEvaluationDeOptimized();
    }

    // Helper to create PUSH_REG opcode
    function pushReg(uint8 regIndex) internal pure returns (uint8) {
        return PUSH_REG_FLAG | regIndex;
    }

    function createRPNStream(uint8[] memory opcodes) internal pure returns (bytes32) {
        bytes32 stream = 0;
        for (uint256 i = 0; i < opcodes.length; i++) {
            stream |= bytes32(uint256(opcodes[i])) << (248 - i * 8);
        }
        return stream;
    }

    function _make_concrete_bytes1(uint8 b) internal pure returns (uint8) {
        for (uint8 i; i < 7; i++) {
            if (i == b) {
                return i;
            }
        }
        for (uint8 i = 128; i < 131; i++) {
            if (i == b) {
                return i;
            }
        }
    }

    // Property 1) evaluateRPN produces expected results
    // Guard: rpnLenSym < 32
    function check_evaluateRPN(uint8[] memory toks) external view {
        vm.assume(toks.length < 32);
        for (uint256 i; i < toks.length; i++) {
            vm.assume(toks[i] < 7 || (toks[i] >= 0x80 && toks[i] < 0x80 + 3));
            // only valid opcodes and regs 0-2
            toks[i] = _make_concrete_bytes1(toks[i]); // make concrete
        }
        uint256[] memory regValues = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            regValues[i] = i * 3;
        }
        bytes32 rpnStream = createRPNStream(toks);
        uint256 result = processor.evaluateRPN(regValues, rpnStream, uint8(toks.length));

        uint256 resultDeOptimized = deOptimized.evaluateRPN(regValues, rpnStream, uint8(toks.length));
        assertEq(result, resultDeOptimized, 'Result Matches');
    }

    enum OP_TYPE {
        ADD,
        SUB,
        MUL,
        DIV_DOWN,
        DIV_UP,
        MIN,
        MAX
    }

    function _setRpnStream(uint8 op) internal pure returns (bytes32 rpnStream) {
        require(op <= 6, 'Op must be 0-6');

        assembly ('memory-safe') {
            rpnStream := shl(232, add(0x808100, op))
        }
    }

    /// Makes sure a valid operation never reverts
    function check_oneOpFuzzRPN(uint128 a, uint128 b, uint8 op) public {
        uint8 rpnLen = 3;

        OP_TYPE op = OP_TYPE(op % 7);

        uint256[] memory regs = new uint256[](128);
        regs[0] = a;
        regs[1] = b;

        bytes32 rpnStream;

        assembly ('memory-safe') {
            // First register
            rpnStream := or(shl(248, 0x80), rpnStream)

            // Second register
            rpnStream := or(shl(240, 0x81), rpnStream)

            // Operation
            rpnStream := or(shl(232, add(0x00, op)), rpnStream)
        }

        try processor.evaluateRPN(regs, rpnStream, rpnLen) returns (uint256 r) {
            if (op == OP_TYPE.DIV_DOWN) {
                assertEq(r, a / b, 'Division down result');
            }
            if (op == OP_TYPE.DIV_UP) {
                uint256 expected = a == 0 ? 0 : (a + b - 1) / b;
                assertEq(r, expected, 'Division up result');
            }
            if (op == OP_TYPE.SUB) {
                assertGe(r, a - b, 'Subtraction result');
            }
            if (op == OP_TYPE.MUL) {
                assertGe(r, a * b, 'Multiplication result');
            }

            if (op == OP_TYPE.ADD) {
                assertEq(r, a + b, 'Addition result');
            }

            if (op == OP_TYPE.MIN) {
                assertEq(r, a < b ? a : b, 'Min result');
            }

            if (op == OP_TYPE.MAX) {
                assertEq(r, a > b ? a : b, 'Max result');
            }
        } catch {
            // Reaching here means the operation reverted. Only DIV (by zero) and
            // SUB (underflow) may legitimately revert; every other opcode is total
            // over the uint128 input domain and must never revert.
            if (op == OP_TYPE.DIV_DOWN || op == OP_TYPE.DIV_UP) {
                // Must fail due to division by zero
                assertEq(b, 0, 'Division by zero');
            } else if (op == OP_TYPE.SUB) {
                // Must fail due to underflow (b > a)
                assertGt(b, a, 'Subtraction underflow');
            } else {
                // ADD, MUL, MIN, MAX must never revert
                assertTrue(false, 'Unexpected revert for non-reverting opcode');
            }
        }
    }

    /// @notice MIN and MAX are total functions over the full uint256 domain: they must
    /// never revert and must return the correct extremum for ANY pair of inputs.
    /// Unlike check_oneOpFuzzRPN this takes symbolic uint256 (not uint128) operands and
    /// has no permissive catch, so any revert fails the property. Halmos proves this
    /// exhaustively over the entire uint256 x uint256 space rather than by sampling.
    function check_minMaxSymbolic(uint256 a, uint256 b) public view {
        uint256[] memory regs = new uint256[](128);
        regs[0] = a;
        regs[1] = b;

        bytes32 minStream;
        bytes32 maxStream;
        assembly ('memory-safe') {
            // push reg 0 (0x80), push reg 1 (0x81), then the operation opcode
            let base := or(shl(248, 0x80), shl(240, 0x81))
            minStream := or(base, shl(232, 5)) // OP_MIN
            maxStream := or(base, shl(232, 6)) // OP_MAX
        }

        uint256 minResult = processor.evaluateRPN(regs, minStream, 3);
        assertEq(minResult, a < b ? a : b, 'Min result');

        uint256 maxResult = processor.evaluateRPN(regs, maxStream, 3);
        assertEq(maxResult, a > b ? a : b, 'Max result');
    }

    function check_rpLenZeroAlwaysReverts() public {
        uint256[] memory regs = new uint256[](128);
        bytes32 rpnStream;
        uint8 rpnLen = 0;
        try processor.evaluateRPN(regs, rpnStream, rpnLen) {
            assertTrue(false, 'Should revert');
        } catch { }
    }

    // Simple debug test that shows max items in the stack
    function check_maxItemsInStack() public {
        uint256[] memory regs = new uint256[](128);
        // Derived manually from: https://comforting-marshmallow-061c2c.netlify.app/
        bytes32 rpnStream = bytes32(hex'80808080808080808080808080808080000000000000000000000000');
        uint8 rpnLen = 31;
        processor.evaluateRPN(regs, rpnStream, rpnLen);
    }
}
