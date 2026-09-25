// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { Setup } from './Setup.sol';

enum OpType {
    GENERIC,
    CLAMPED_CALL
}

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        bytes[] registers;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    // === EXPLODE observation ===
    // Populated by the clamped ExplodeTargets handlers, read by the EXPLODE invariants in Properties.
    // Kept in dedicated storage (not _before/_after) so intervening non-explode operations cannot
    // clobber the observation the EXPLODE invariants reason about.
    //
    // Only digests are retained, not register images. Persisting two full register arrays per handler
    // call costs one SSTORE per register and adds ~7KB to CryticTester's bytecode, which pushes the
    // harness constructor past the 25M `gas_limit` in foundry.toml and makes the whole suite
    // undeployable. Comparing keccak digests of the exact same byte strings is equally strong.
    enum ExplodeMode {
        NONE, // no clamped EXPLODE has run yet
        STATIC, // every destination static
        DYNAMIC, // every destination dynamic, none aliasing the source
        ALIAS, // one dynamic destination aliasing the source register
        MIXED // interleaved static and dynamic destinations
    }

    struct ExplodeObs {
        ExplodeMode mode;
        bool reverted; // did the most recent clamped EXPLODE revert
        bool untouched; // every non-destination register was byte-identical afterwards
        bytes32 expected; // digest of the byte string the destinations must hold, per the ISA
        bytes32 actual; // digest of the byte string they actually hold
    }

    ExplodeObs internal _explode;

    // === Raw EXPLODE observation ===
    // Populated by the unclamped `explode_raw` handler. That handler feeds arbitrary bits to the VM,
    // so reverting is the normal outcome and carries no information on its own. What must never
    // happen is a revert outside the taxonomy the ISA declares: a Solidity `Panic` would mean the VM
    // hit an overflow or a bad array index rather than rejecting malformed input, and empty return
    // data would mean it ran out of gas. Both are bugs; `OutOfBounds` and friends are the contract.
    struct ExplodeRawObs {
        bool ran; // at least one raw EXPLODE has been attempted
        bool reverted; // the most recent raw EXPLODE reverted
        bool emptyReason; // it reverted with no return data at all
        bytes4 selector; // the revert selector, when there was one
    }

    ExplodeRawObs internal _explodeRaw;

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
        __before();
        _;
        __after();
    }

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    function __before() internal {
        // Copy the whole state
        _before = Vars({ registers: new bytes[](state.registers.length) });
        for (uint256 i = 0; i < state.registers.length; i++) {
            _before.registers[i] = state.registers[i];
        }
    }

    function __after() internal {
        // Copy the whole state
        _after = Vars({ registers: new bytes[](state.registers.length) });
        for (uint256 i = 0; i < state.registers.length; i++) {
            _after.registers[i] = state.registers[i];
        }
    }
}
