// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import 'forge-std/Test.sol';
import { MemoryUtils } from '../src/MemoryUtils.sol';
import { VmErrors } from '../src/VmErrors.sol';

contract MemoryUtilsTest is Test {
    function slice(bytes memory data, uint256 start, uint256 length) external pure returns (bytes memory) {
        return MemoryUtils.slice(data, start, length);
    }

    /// @dev `start + length` would overflow and panic; the documented error is OutOfBounds.
    function test_slice_StartOverflow_RevertsOutOfBounds() public {
        vm.expectRevert(VmErrors.OutOfBounds.selector);
        this.slice(new bytes(64), type(uint256).max, 1);
    }

    /// @dev The shape `ExplodeLib` produces: an in-bounds `start` with `length = end - start` chosen by
    ///      the source. `start + length` overflows `uint256`; the guard must still revert OutOfBounds.
    function test_slice_ExplodeShapedOverflow_RevertsOutOfBounds() public {
        vm.expectRevert(VmErrors.OutOfBounds.selector);
        this.slice(new bytes(64), 32, type(uint256).max);
    }

    function test_slice_PastEnd_RevertsOutOfBounds() public {
        vm.expectRevert(VmErrors.OutOfBounds.selector);
        this.slice(new bytes(64), 32, 33);
    }

    /// @dev `start + length == data.length` by one word past the boundary reverts (off-by-one guard).
    function test_slice_OneBytePastEnd_RevertsOutOfBounds() public {
        vm.expectRevert(VmErrors.OutOfBounds.selector);
        this.slice(new bytes(64), 64, 1);
    }

    /// @dev Accept boundary: `start == data.length` with `length == 0` returns empty, not OutOfBounds.
    ///      A tightening to `start >= data.length` would break this.
    function test_slice_StartAtEndZeroLength_ReturnsEmpty() public {
        assertEq(this.slice(new bytes(64), 64, 0).length, 0);
    }

    /// @dev Accept boundary: `start + length == data.length` returns the tail exactly.
    function test_slice_ExactToEnd_ReturnsTail() public {
        assertEq(this.slice(new bytes(64), 32, 32).length, 32);
    }

    /// @dev Pins accept/reject at the predicate boundary in both directions, so a tightening of the
    ///      first clause or an off-by-one in the second breaks a test. `&&` short-circuits, so the
    ///      `dataLen - start` in the oracle never underflows.
    function testFuzz_slice_Boundary(uint256 dataLen, uint256 start, uint256 length) public {
        dataLen = bound(dataLen, 0, 256);
        start = bound(start, 0, 320);
        length = bound(length, 0, 320);
        bytes memory data = new bytes(dataLen);

        if (start <= dataLen && length <= dataLen - start) {
            assertEq(this.slice(data, start, length).length, length);
        } else {
            vm.expectRevert(VmErrors.OutOfBounds.selector);
            this.slice(data, start, length);
        }
    }
}
