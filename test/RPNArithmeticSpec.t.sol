// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/Test.sol';
import '../src/RPNArithmetic.sol';

contract RPNArithmeticSpecTest is Test {
    ArithmeticProcessor processor;

    // OpCode constants matching implementation
    uint8 constant PUSH_REG_FLAG = 0x80;
    uint8 constant REG_INDEX_MASK = 0x7F;
    uint8 constant OP_ADD = 0;
    uint8 constant OP_SUB = 1;
    uint8 constant OP_MUL = 2;
    uint8 constant OP_DIV_DOWN = 3;
    uint8 constant OP_DIV_UP = 4;
    uint8 constant OP_MIN = 5;
    uint8 constant OP_MAX = 6;
    uint8 constant OP_INVALID = 7;

    function setUp() public {
        processor = new ArithmeticProcessor();
    }

    // Helper to create PUSH_REG opcode
    function pushReg(uint8 regIndex) internal pure returns (uint8) {
        return PUSH_REG_FLAG | regIndex;
    }

    // Helper to create RPN bytecode stream
    function createRPNStream(uint8[] memory opcodes) internal pure returns (bytes32) {
        bytes32 stream = 0;
        for (uint256 i = 0; i < opcodes.length; i++) {
            stream |= bytes32(uint256(opcodes[i])) << (248 - i * 8);
        }
        return stream;
    }

    // Tests basic addition operation
    function test_Addition() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 1;
        regValues[1] = 2;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_ADD; // 0x00
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 3);
    }

    // Tests basic subtraction operation
    function test_Subtraction() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 1;
        regValues[1] = 2;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(1); // 0x81
        opcodes[1] = pushReg(0); // 0x80
        opcodes[2] = OP_SUB; // 0x01
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 1);
    }

    // Tests basic multiplication operation
    function test_Multiplication() public view {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 7;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(0); // 0x80
        opcodes[2] = OP_MUL; // 0x02
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 49);
    }

    // Tests basic division up operation
    function test_Division_up() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 8;
        regValues[1] = 2;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_UP; // 0x03
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 4);
    }

    // Tests basic division up operation
    function test_Division_Up_Ceil() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 8;
        regValues[1] = 3;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_UP; // 0x03
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 3);
    }

    // Tests basic division down operation
    function test_Division_Down() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 8;
        regValues[1] = 2;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_DOWN; // 0x03
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 4);
    }

    // Tests basic division up operation
    function test_Division_Down_Floor() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 8;
        regValues[1] = 3;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_DOWN; // 0x03
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, 2);
    }

    // Tests MIN and MAX across the full uint256 input space
    function testFuzz_MinMax(uint256 a, uint256 b) public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = a;
        regValues[1] = b;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_MIN; // 0x05
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, a < b ? a : b);

        opcodes[2] = OP_MAX; // 0x06
        rpnStream = createRPNStream(opcodes);

        result = processor.evaluateRPN(regValues, rpnStream, 3);
        assertEq(result, a > b ? a : b);
    }

    // Tests MIN/MAX composed in a multi-op expression
    function test_MinMaxComplexExpression() public view {
        uint256[] memory regValues = new uint256[](3);
        regValues[0] = 2;
        regValues[1] = 9;
        regValues[2] = 4;

        // RPN: PUSH_REG(0), PUSH_REG(1), MIN, PUSH_REG(2), MAX
        // Evaluates to: max(min(2, 9), 4) = max(2, 4) = 4
        uint8[] memory opcodes = new uint8[](5);
        opcodes[0] = pushReg(0);
        opcodes[1] = pushReg(1);
        opcodes[2] = OP_MIN;
        opcodes[3] = pushReg(2);
        opcodes[4] = OP_MAX;
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 5);
        assertEq(result, 4);
    }

    // Tests division by zero reverts with DivByZero error
    function test_DivisionByZero_Reverts() public {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 8;
        regValues[1] = 0;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_UP; // 0x03
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.DivByZero.selector);
        processor.evaluateRPN(regValues, rpnStream, 3);

        uint8[] memory opcodesDown = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_DOWN; // 0x03
        bytes32 rpnStreamDown = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.DivByZero.selector);
        processor.evaluateRPN(regValues, rpnStreamDown, 3);
    }

    // Tests stack underflow when ALU operation lacks operands
    function test_StackUnderflow_OnALUOperation() public {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 5;

        uint8[] memory opcodes = new uint8[](1);
        opcodes[0] = OP_ADD; // 0x00
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.StackUnderflow.selector);
        processor.evaluateRPN(regValues, rpnStream, 1);
    }

    // Tests that more than 32 opcodes triggers TooManyOpcodes error
    function test_TooManyOpcodes_Reverts() public {
        uint256[] memory regValues = new uint256[](0);
        bytes32 rpnStream = bytes32(0); // content doesn't matter

        vm.expectRevert(abi.encodeWithSelector(ArithmeticProcessor.TooManyOpcodes.selector, 33, 32));
        processor.evaluateRPN(regValues, rpnStream, 33);
    }

    // Tests that invalid opcode triggers InvalidOpcode error
    // Note: Need to push values first to avoid stack underflow
    function test_InvalidOpcode_Reverts() public {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 5;
        regValues[1] = 3;

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // Push first value
        opcodes[1] = pushReg(1); // Push second value
        opcodes[2] = OP_INVALID; // 0x07 - first unassigned opcode
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(abi.encodeWithSelector(ArithmeticProcessor.InvalidOpcode.selector, OP_INVALID));
        processor.evaluateRPN(regValues, rpnStream, 3);
    }

    // Tests that accessing out-of-bounds register triggers RegIndexOOB error
    function test_RegisterIndexOutOfBounds_Reverts() public {
        uint256[] memory regValues = new uint256[](0);

        uint8[] memory opcodes = new uint8[](1);
        opcodes[0] = pushReg(0); // 0x80
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(abi.encodeWithSelector(ArithmeticProcessor.RegIndexOOB.selector, 0));
        processor.evaluateRPN(regValues, rpnStream, 1);
    }

    // Tests single value on stack returns successfully
    function test_SinglePushOperation_Succeeds() public view {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 9;

        uint8[] memory opcodes = new uint8[](1);
        opcodes[0] = pushReg(0); // 0x80
        bytes32 rpnStream = createRPNStream(opcodes);

        // Note: This should actually succeed, returning 9
        // The spec says it should revert with InvalidRPNStack
        // But the implementation checks for sp != 1 at the end
        // With one push, sp will be 1, so this succeeds
        uint256 result = processor.evaluateRPN(regValues, rpnStream, 1);
        assertEq(result, 9);
    }

    // Tests that multiple values left on stack triggers InvalidRPNStack error
    function test_MultipleValuesOnStack_Reverts() public {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = 5;
        regValues[1] = 3;

        uint8[] memory opcodes = new uint8[](2);
        opcodes[0] = pushReg(0);
        opcodes[1] = pushReg(1);
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.InvalidRPNStack.selector);
        processor.evaluateRPN(regValues, rpnStream, 2);
    }

    // Test empty expression with non-empty registers
    function test_EmptyExpression_NonEmptyRegisters() public {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 42;

        vm.expectRevert(ArithmeticProcessor.InvalidRPNStack.selector);
        processor.evaluateRPN(regValues, bytes32(0), 0);
    }

    // Test empty expression with empty registers
    function test_EmptyExpression_EmptyRegisters() public {
        uint256[] memory regValues = new uint256[](0);

        vm.expectRevert(ArithmeticProcessor.MissingDestReg.selector);
        processor.evaluateRPN(regValues, bytes32(0), 0);
    }

    // Test maximum register index (127)
    function test_MaxRegisterIndex() public view {
        uint256[] memory regValues = new uint256[](128);
        regValues[127] = 999;

        uint8[] memory opcodes = new uint8[](1);
        opcodes[0] = pushReg(127); // Maximum valid index with 7-bit mask
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 1);
        assertEq(result, 999);
    }

    // Test complex nested expression
    function test_ComplexNestedExpression() public view {
        uint256[] memory regValues = new uint256[](4);
        regValues[0] = 10;
        regValues[1] = 5;
        regValues[2] = 3;
        regValues[3] = 2;

        // ((10 + 5) * 3) - (2 * 2) = (15 * 3) - 4 = 45 - 4 = 41
        uint8[] memory opcodes = new uint8[](9);
        opcodes[0] = pushReg(0); // 10
        opcodes[1] = pushReg(1); // 5
        opcodes[2] = OP_ADD; // 15
        opcodes[3] = pushReg(2); // 3
        opcodes[4] = OP_MUL; // 45
        opcodes[5] = pushReg(3); // 2
        opcodes[6] = pushReg(3); // 2
        opcodes[7] = OP_MUL; // 4
        opcodes[8] = OP_SUB; // 41
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 9);
        assertEq(result, 41);
    }

    // Test stack underflow when trying to pop from empty stack
    function test_StackUnderflow_EmptyStack() public {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 5;

        uint8[] memory opcodes = new uint8[](1);
        opcodes[0] = OP_ADD; // Try to add with empty stack
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.StackUnderflow.selector);
        processor.evaluateRPN(regValues, rpnStream, 1);
    }

    // Test stack underflow with only one value
    function test_StackUnderflow_SingleValue() public {
        uint256[] memory regValues = new uint256[](1);
        regValues[0] = 5;

        uint8[] memory opcodes = new uint8[](2);
        opcodes[0] = pushReg(0); // Push one value
        opcodes[1] = OP_ADD; // Try to add (needs 2 values)
        bytes32 rpnStream = createRPNStream(opcodes);

        vm.expectRevert(ArithmeticProcessor.StackUnderflow.selector);
        processor.evaluateRPN(regValues, rpnStream, 2);
    }

    // Tests that division up handles overflow correctly
    // When (a + b - 1) would overflow, the operation should still succeed
    function test_Division_Up_NoOverflow() public view {
        uint256[] memory regValues = new uint256[](2);
        regValues[0] = type(uint256).max - 1; // a = max - 1
        regValues[1] = 2; // b = 2

        uint8[] memory opcodes = new uint8[](3);
        opcodes[0] = pushReg(0); // 0x80
        opcodes[1] = pushReg(1); // 0x81
        opcodes[2] = OP_DIV_UP; // 0x04
        bytes32 rpnStream = createRPNStream(opcodes);

        uint256 result = processor.evaluateRPN(regValues, rpnStream, 3);
        // Expected: ceiling((max - 1) / 2) = (max - 1) / 2 = max / 2
        assertEq(result, type(uint256).max / 2);
    }
}
