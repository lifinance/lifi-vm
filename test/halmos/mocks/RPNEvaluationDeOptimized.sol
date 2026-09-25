contract RPNEvaluationDeOptimized {
    uint8 internal constant PUSH_REG_FLAG = 0x80; // 10000000 - highest bit set
    uint8 internal constant REG_INDEX_MASK = 0x7F; // 01111111 - lower 7 bits
    uint8 internal constant OP_ADD = uint8(0);
    uint8 internal constant OP_SUB = uint8(1);
    uint8 internal constant OP_MUL = uint8(2);
    uint8 internal constant OP_DIV_DOWN = uint8(3);
    uint8 internal constant OP_DIV_UP = uint8(4);
    uint8 internal constant OP_MIN = uint8(5);
    uint8 internal constant OP_MAX = uint8(6);

    function evaluateRPN(
        uint256[] calldata regValues,
        bytes32 rpnStream,
        uint8 rpnLen
    )
        external
        pure
        returns (uint256 result)
    {
        require(rpnLen <= 32, 'Too many opcodes');

        // Initialize stack; new uint256[](0) is valid if rpnLen is 0.
        uint256[] memory stack = new uint256[](rpnLen);
        uint8 sp = 0; // Stack pointer

        // Process RPN stream.
        for (uint8 pc = 0; pc < rpnLen; pc++) {
            // Read the bytes from the left
            uint8 op = uint8(bytes1(rpnStream[pc])); // De-optimized bytes

            if (op >= 0x80) {
                uint8 regIndex = op & REG_INDEX_MASK; // Get the register index

                uint256 val = regValues[regIndex];

                stack[sp] = val;
                sp++;
                // Load a register
            } else {
                sp -= 2; // Pop two operands.
                uint256 a = stack[sp];
                uint256 b = stack[sp + 1];

                uint256 c; // Result of the operation.
                if (op == OP_ADD) {
                    c = a + b;
                } else if (op == OP_SUB) {
                    c = a - b;
                } else if (op == OP_MUL) {
                    c = a * b;
                } else if (op == OP_DIV_DOWN) {
                    if (b == 0) {
                        revert('Div by zero');
                    }
                    c = a / b;
                } else if (op == OP_DIV_UP) {
                    if (b == 0) {
                        revert('Div by zero');
                    }
                    c = a == 0 ? 0 : (a + b - 1) / b;
                } else if (op == OP_MIN) {
                    c = a < b ? a : b;
                } else if (op == OP_MAX) {
                    c = a > b ? a : b;
                } else {
                    revert('Invalid opcode');
                }
                stack[sp] = c; // Push result.
                sp++;
            }
        }

        if (sp != 1) {
            revert('Invalid RPN stack');
        }

        return stack[0];
    }
}
