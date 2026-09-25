// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { Bp } from './lib/Bp.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { RegisterFile } from '../src/RegisterFile.sol';

/// @dev Returns hand-built blobs as raw return data, so each case controls every word the VM
///      stores. Used to drive one byte-identical CALL command against differing callee data.
contract ScalarReturner {
    uint256 constant A = 0xAAAA;
    uint256 constant HIDDEN = 0xBADBAD;

    /// @dev `abi.encode(bytes)` for a one-word payload: `[0x20][len=0x20][payload]`.
    function canonical() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(0x20), uint256(32), A));
    }

    /// @dev Same header, two extra words appended. The length word still reads 32.
    function surplus() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(0x20), uint256(32), A, HIDDEN, HIDDEN));
    }

    /// @dev Header only: declares a payload word it does not carry.
    function deficit() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(0x20), uint256(32)));
    }

    /// @dev A dynamic tuple `(bytes,bytes)`: head words are offsets other than `0x20`.
    function dynamicTuple() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(64), uint256(128), uint256(32), A, uint256(32), A));
    }

    /// @dev Shorter than the `0x40` minimum `setDynamic` requires.
    function tooShort() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(0x20)));
    }

    /// @dev A tuple `(uint256 amount, bytes data)` with `amount == 32`. Word 0 is the amount, so
    ///      the head is byte-indistinguishable from a single dynamic scalar's.
    function ambiguousTuple() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(32), uint256(0x40), uint256(32), A));
    }

    /// @dev A one-field dynamic tuple `(bytes)`. Identical on the wire to `canonical()`.
    function oneFieldTuple() external pure returns (bytes memory) {
        _rawReturn(abi.encode(uint256(0x20), uint256(32), A));
    }

    function _rawReturn(bytes memory blob) private pure {
        assembly {
            return(add(blob, 0x20), mload(blob))
        }
    }
}

/// @notice Locks in the two rulings recorded in `docs/isa.md`:
///
///         1. **CALL destination-register high bit.** Set means `RegisterFile.setDynamic`, which
///            accepts only a single dynamic scalar (`[0x20][len][payload]`). A tuple return must
///            use a clear high bit and be decomposed with EXPLODE. These tests pin the accepted
///            and rejected shapes so the contract the off-chain compiler relies on cannot drift.
///
///         2. **Register canonicality is not guaranteed** (see the *Register Canonicality*
///            section). `setDynamic` never compares the length word against the bytes that follow,
///            so a callee controls whether a register carries more or fewer bytes than it declares
///            — the same break `ExplodeSemantics.t.sol` pins for EXPLODE, reached here without any
///            EXPLODE involvement. Both producers must be locked, or a future tightening of one
///            would read as closing a gap that the other leaves open.
contract CallRegisterCanonicalityTest is SpecTestBase {
    ScalarReturner private returner;

    function setUp() public override {
        super.setUp();
        returner = new ScalarReturner();
    }

    /// @dev CALL the selector into register 1 with the destination high bit **set**, re-encode
    ///      register 1 as a single-field dynamic tuple, and return the payload.
    function _runDynamicDest(bytes4 sel) private returns (VMState memory s1, bytes memory out) {
        VMState memory s0 = Regs.init(4);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(sel));

        VMCommand[] memory cmds = new VMCommand[](3);
        cmds[0] = VmCmd.call(address(returner), CallType.STATICCALL, Regs.withDyn(1), 0, 0);
        cmds[1] = VmCmd.abiEnc(2, abi.encodePacked(Bp.pushTuple(), Bp.d(1), Bp.end()));
        cmds[2] = VmCmd.ret(2);

        (s1, out) = run(cmds, s0);
    }

    function _declaredLen(bytes memory blob) private pure returns (uint256 n) {
        assembly {
            n := mload(add(blob, 0x20))
        }
    }

    function _word(bytes memory blob, uint256 i) private pure returns (uint256 w) {
        assembly {
            w := mload(add(add(blob, 0x20), mul(i, 32)))
        }
    }

    /* ─────────── ruling 1: what the destination high bit accepts ─────────── */

    /// ISA: a set high bit routes the return through `setDynamic`, which strips the leading `0x20`
    /// offset word and re-tags the remainder as raw bytes.
    function test_Call_DynamicDest_SingleDynamicScalar_StripsOffsetWord() public {
        (VMState memory s1,) = _runDynamicDest(ScalarReturner.canonical.selector);

        assertEq(s1.registers[1].length, 64, 'offset word stripped, length word and payload remain');
        assertEq(_declaredLen(s1.registers[1]), 32, 'declares one payload word');
    }

    /// ISA: "A dynamic tuple such as `(bytes,string,uint256[])` has head words `{0x60, 0xa0, ...}`,
    /// so word 0 is not `0x20` and a set high bit reverts `InvalidDynamicData()`."
    function test_Call_DynamicDest_DynamicTupleReturn_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RegisterFile.InvalidDynamicData.selector));
        _runDynamicDest(ScalarReturner.dynamicTuple.selector);
    }

    /// ISA: `setDynamic` requires `data.length >= 0x40`.
    function test_Call_DynamicDest_ReturnShorterThanTwoWords_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RegisterFile.InvalidDynamicData.selector));
        _runDynamicDest(ScalarReturner.tooShort.selector);
    }

    /// ISA: "The `word 0 == 0x20` test is necessary, not sufficient." A tuple whose first field is
    /// static presents that field's *value* as word 0, so `(uint256 amount, bytes data)` with
    /// `amount == 32` is accepted and silently mis-framed. This is why the VM cannot sniff the
    /// intended mode from the return data: a wrong flag is silent corruption, not a revert.
    function test_Call_DynamicDest_AmbiguousTupleHead_AcceptedAndMisframed() public {
        (VMState memory s1,) = _runDynamicDest(ScalarReturner.ambiguousTuple.selector);

        assertEq(_declaredLen(s1.registers[1]), 0x40, "length word is the tuple's offset word");
        assertEq(s1.registers[1].length, 96, 'amount word was stripped as if it were an ABI offset');
    }

    /// ISA: the ambiguity runs both ways — a one-field dynamic tuple `(bytes)` and a bare `bytes`
    /// are byte-identical on the wire, so no head inspection can separate them.
    function test_Call_DynamicDest_OneFieldTupleIsIndistinguishableFromScalar() public {
        (VMState memory tupleState,) = _runDynamicDest(ScalarReturner.oneFieldTuple.selector);
        (VMState memory scalarState,) = _runDynamicDest(ScalarReturner.canonical.selector);

        assertEq(tupleState.registers[1], scalarState.registers[1], 'same register from both shapes');
    }

    /// ISA: a tuple return must use a **clear** high bit; the blob is then stored verbatim through
    /// `RegisterFile.set` and EXPLODE decomposes it. This is the shape the off-chain compiler emits
    /// for a dynamic-tuple CALL destination.
    function test_Call_StaticDest_DynamicTupleReturn_StoredVerbatimAndExplodable() public {
        VMState memory s0 = Regs.init(5);
        s0.registers[0] = TestUtils.prependLength(abi.encodeWithSelector(ScalarReturner.dynamicTuple.selector));

        uint8[] memory dests = new uint8[](2);
        dests[0] = Regs.withDyn(2);
        dests[1] = Regs.withDyn(3);

        VMCommand[] memory cmds = new VMCommand[](2);
        // Destination 1 has the high bit clear: no setDynamic, no shape check.
        cmds[0] = VmCmd.call(address(returner), CallType.STATICCALL, 1, 0, 0);
        cmds[1] = VmCmd.explode(1, dests);

        (VMState memory s1,) = run(cmds, s0);

        assertEq(s1.registers[1].length, 192, 'raw tuple blob stored verbatim, offset words intact');
        assertEq(_word(s1.registers[1], 0), 64, 'head word 0 is an offset, not 0x20');
        assertEq(s1.registers[2], abi.encode(uint256(32), uint256(0xAAAA)), 'EXPLODE recovered field a');
        assertEq(s1.registers[3], abi.encode(uint256(32), uint256(0xAAAA)), 'EXPLODE recovered field b');
    }

    /* ─────────── ruling 2: canonicality is the callee's choice ─────────── */

    /// Baseline for the two cases below: with canonical callee data the register's byte length and
    /// its declared payload length agree.
    function test_Call_CanonicalCallee_RegisterLengthMatchesDeclaredLength() public {
        (VMState memory s1,) = _runDynamicDest(ScalarReturner.canonical.selector);

        assertEq(s1.registers[1].length, _declaredLen(s1.registers[1]) + 32, 'self-consistent');
    }

    /// ISA *Register Canonicality*: "A callee returning `[0x20][len=0x20][3 payload words]` yields a
    /// 128-byte register whose length word reads `32`." No revert, and the surplus reaches the
    /// re-encoded payload as ABI dead space.
    function test_Call_DynamicDest_SurplusPayload_AcceptedAndPropagates() public {
        (VMState memory s1, bytes memory out) = _runDynamicDest(ScalarReturner.surplus.selector);

        assertEq(_declaredLen(s1.registers[1]), 32, 'still declares one payload word');
        assertEq(s1.registers[1].length, 128, 'but the register carries three');
        assertEq(_word(s1.registers[1], 3), 0xBADBAD, 'callee-chosen word past the declared payload');

        (, bytes memory canonicalOut) = _runDynamicDest(ScalarReturner.canonical.selector);
        assertEq(out.length, canonicalOut.length + 64, 'output grew by the surplus');

        // Payload layout: [w0][ptr=0x20][field off=0x20][len=0x20][payload][surplus][surplus].
        // The declared payload is one word, so w5 and w6 are ABI dead space.
        assertEq(_word(out, 3), 32, 'field still declares one payload word');
        assertEq(_word(out, 5), 0xBADBAD, 'surplus word reaches the returned payload');
        assertEq(_word(out, 6), 0xBADBAD, 'and so does the second');

        // The logical field still decodes unchanged: a canonicality break, not corruption.
        assertEq(_word(out, 4), 0xAAAA, 'declared payload intact');
    }

    /// ISA *Register Canonicality*: "returning `[0x20][len=0x20]` with no payload yields a 32-byte
    /// register declaring 32 bytes of payload it does not carry." Also accepted.
    function test_Call_DynamicDest_DeficitPayload_Accepted() public {
        (VMState memory s1, bytes memory out) = _runDynamicDest(ScalarReturner.deficit.selector);

        assertEq(s1.registers[1].length, 32, 'register is its length word alone');
        assertEq(_declaredLen(s1.registers[1]), 32, 'yet declares a payload word it does not carry');

        // Payload layout: [w0][ptr=0x20][field off=0x20][len=0x20] and nothing after it. The field
        // declares a payload word that the payload does not contain, so a decoder reading it reads
        // past the end of the returned bytes.
        assertEq(out.length, 128, 'four words: no payload word was emitted');
        assertEq(_word(out, 3), 32, 'declared length outruns the payload');
    }
}
