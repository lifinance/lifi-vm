// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @title ArithmeticProcessor
/// @custom:version 1.1.0
/// @notice Gas-efficient Reverse Polish Notation (RPN) arithmetic processor for evaluating mathematical expressions
contract ArithmeticProcessor {
    enum OpCode {
        ADD,
        SUB,
        MUL,
        DIV_DOWN,
        DIV_UP,
        MIN,
        MAX
    }

    // --- Custom Errors ---
    error EmptyExpression();
    error RegIndexOOB(uint8 attemptedRegIndex);
    error StackUnderflow();
    error DivByZero();
    error InvalidRPNStack();
    error MissingDestReg();
    error TooManyOpcodes(uint8 actualLen, uint8 maxLen);
    error InvalidOpcode(uint8 opcode);

    // --- OpCode Constants ---
    uint8 internal constant PUSH_REG_FLAG = 0x80; // 10000000 - highest bit set
    uint8 internal constant REG_INDEX_MASK = 0x7F; // 01111111 - lower 7 bits
    uint8 internal constant OP_ADD = uint8(OpCode.ADD);
    uint8 internal constant OP_SUB = uint8(OpCode.SUB);
    uint8 internal constant OP_MUL = uint8(OpCode.MUL);
    uint8 internal constant OP_DIV_DOWN = uint8(OpCode.DIV_DOWN);
    uint8 internal constant OP_DIV_UP = uint8(OpCode.DIV_UP);
    uint8 internal constant OP_MIN = uint8(OpCode.MIN);
    uint8 internal constant OP_MAX = uint8(OpCode.MAX);

    // --- RPN Evaluation Function ---
    function evaluateRPN(
        uint256[] calldata regValues,
        bytes32 rpnStream,
        uint8 rpnLen
    )
        external
        pure
        returns (uint256 result)
    {
        uint256 regsLen = regValues.length;

        if (rpnLen > 32) revert TooManyOpcodes(rpnLen, 32);

        // Initialize stack; new uint256[](0) is valid if rpnLen is 0.
        uint256[] memory stack = new uint256[](rpnLen);
        uint8 sp = 0; // Stack pointer

        // Process RPN stream.
        for (uint8 pc = 0; pc < rpnLen;) {
            // pc explicitly initialized.
            uint8 op = uint8(uint256(rpnStream >> ((31 - uint256(pc)) * 8)));

            if ((op & PUSH_REG_FLAG) != 0) {
                // Extract register index from lower 7 bits
                uint8 regIndex = op & REG_INDEX_MASK;

                if (regIndex >= regsLen) {
                    revert RegIndexOOB(regIndex);
                }

                uint256 val = regValues[regIndex];

                if (sp >= rpnLen) {
                    // This implies an invalid RPN structure or rpnLen too small.
                    revert InvalidRPNStack();
                }
                stack[sp] = val;
                unchecked {
                    sp++;
                }
            } else {
                if (sp < 2) {
                    revert StackUnderflow();
                }
                uint256 a;
                uint256 b;
                unchecked {
                    sp -= 2; // Pop two operands.
                    a = stack[sp];
                    b = stack[sp + 1];
                }

                uint256 c; // Result of the operation.
                if (op == OP_ADD) {
                    c = a + b;
                } else if (op == OP_SUB) {
                    c = a - b;
                } else if (op == OP_MUL) {
                    c = a * b;
                } else if (op == OP_DIV_DOWN) {
                    if (b == 0) {
                        revert DivByZero();
                    }
                    c = a / b;
                } else if (op == OP_DIV_UP) {
                    if (b == 0) {
                        revert DivByZero();
                    }
                    // Integer division floors. If a % b is nonzero, 1 should be added
                    c = a == 0 ? 0 : a / b + (a % b > 0 ? 1 : 0);
                } else if (op == OP_MIN) {
                    c = a < b ? a : b;
                } else if (op == OP_MAX) {
                    c = a > b ? a : b;
                } else {
                    revert InvalidOpcode(op);
                }
                stack[sp] = c; // Push result.
                unchecked {
                    sp++;
                }
            }
            unchecked {
                pc++;
            }
        }

        if (regsLen == 0) {
            revert MissingDestReg();
        }

        // Stack must contain exactly one value after evaluation.
        if (sp != 1) {
            revert InvalidRPNStack();
        }

        result = stack[0];
        return result;
    }
}
