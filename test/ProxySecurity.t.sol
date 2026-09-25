// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { MinimalProxy } from '../src/proxy/MinimalProxy.sol';
import { ProxyFactory } from '../src/proxy/ProxyFactory.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { CreateXScript } from 'createx-forge/script/CreateXScript.sol';
import { CREATEX_ADDRESS } from 'createx-forge/script/CreateX.d.sol';

/**
 * @dev Interface for contract owners that can be called back during VM execution
 */
interface IReentrantOwner {
    function reenter(address proxy, bytes calldata data) external;
    function start(address proxy, bytes calldata data) external;
}

/**
 * @dev Contract owner that attempts reentrancy during VM execution
 */
contract ReentrantOwner is IReentrantOwner {
    function start(address proxy, bytes calldata data) external {
        (bool ok, bytes memory result) = proxy.call(data);
        if (!ok) {
            // Bubble up the exact revert data
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function reenter(address proxy, bytes calldata data) external {
        // Reenter while outer call is in-flight - this should hit reentrancy guard and revert
        (bool success, bytes memory result) = proxy.call(data);
        if (!success) {
            // Bubble up the reentrancy guard revert
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/**
 * @dev Contract owner that reenters only once per proxy
 */
contract ReentrantOwnerOnce is IReentrantOwner {
    mapping(address => bool) public did;

    function start(address proxy, bytes calldata data) external {
        (bool ok, bytes memory ret) = proxy.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function reenter(address proxy, bytes calldata data) external {
        if (did[proxy]) return; // no reentry after first time
        did[proxy] = true; // set flag BEFORE attempting call to persist even on revert
        (bool ok, bytes memory ret) = proxy.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function setDid(address proxy) external {
        did[proxy] = true;
    }
}

/**
 * @dev Error to prove that the proxy forwarded a call to this VM
 */
error ReachedVM();

/**
 * @dev Mock VM that always reverts with ReachedVM to prove forwarding occurred
 */
contract VmMarker {
    fallback() external payable {
        revert ReachedVM();
    }
}

/**
 * @dev Mock VM that calls back to the owner during delegatecall, bubbling reverts
 */
contract VmReenterBubble {
    // runs in proxy context via DELEGATECALL
    fallback() external {
        // msg.sender == owner (preserved across delegatecall)
        msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        // Always bubble the inner revert so the test can assert the guard's selector
        assembly {
            returndatacopy(0, 0, returndatasize())
            revert(0, returndatasize())
        }
    }
}

/**
 * @dev Mock VM that calls back to the owner during delegatecall, swallowing reverts
 */
contract VmReenterSwallow {
    fallback() external {
        msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        // swallow revert and return
    }
}

/**
 * @dev Attacker contract for testing non-owner reentrancy
 */
contract Attacker {
    function ping(address proxy, bytes calldata data) external {
        (bool ok, bytes memory ret) = proxy.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/**
 * @dev Mock VM that calls an attacker contract during execution
 */
contract VmCallAttacker {
    fallback() external {
        // msg.sender == initiating owner (EOA/contract)
        // call attacker which then calls proxy
        Attacker a = new Attacker();
        a.ping(address(this), msg.data);
    }
}

/**
 * @dev Simple middleman contract for testing tx.origin bypass attempts
 */
contract Middleman {
    function callProxy(address proxy, bytes calldata data) external returns (bool, bytes memory) {
        return proxy.call(data);
    }
}

/**
 * @dev Mock VM that reenters into a different proxy during execution
 */
contract VmReenterOtherProxy {
    address public other;

    constructor(address _other) {
        other = _other;
    }

    fallback() external {
        // delegatecalled in proxy A context; msg.sender == owner
        // Reenter into proxy B; same owner so onlyOwner passes; guard is isolated
        (bool ok, bytes memory ret) = other.call(msg.data);
        assembly {
            if iszero(ok) { revert(add(ret, 0x20), mload(ret)) }
        }
    }
}

/**
 * @dev Mock VM that attempts to reenter the proxy directly (self-call)
 */
contract VmSelfCall {
    fallback() external {
        // reenter the proxy directly; in proxy context address(this) == proxy
        (bool ok, bytes memory ret) = address(this).call(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/**
 * @dev Mock VM that calls back to owner, but succeeds if owner doesn't reenter
 */
contract VmConditionalReenter {
    fallback() external {
        (bool success, bytes memory ret) =
            msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        if (!success) {
            // Bubble reentrancy failures
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        // Success path - return normally
    }
}

/// forge-config: default.isolate = true
contract ProxySecurityTest is SpecTestBase, CreateXScript {
    ProxyFactory proxyFactory;
    MinimalProxy aliceProxy;
    MinimalProxy bobProxy;
    address unauthorized = address(0xDEAD);
    address contractCaller;

    // Reentrancy guard error selector: ReentrantCall(address existingCaller)
    bytes4 constant REENTRANT_CALL_SELECTOR = 0xf57c448b;

    function setUp() public virtual override withCreateX {
        super.setUp();

        // Deploy proxy factory
        proxyFactory = new ProxyFactory(address(machine), CREATEX_ADDRESS);
        vm.label(address(proxyFactory), 'ProxyFactory');

        // Deploy proxies for alice and bob
        aliceProxy = MinimalProxy(payable(proxyFactory.deployProxy(alice)));
        bobProxy = MinimalProxy(payable(proxyFactory.deployProxy(bob)));
        vm.label(address(aliceProxy), 'AliceProxy');
        vm.label(address(bobProxy), 'BobProxy');

        // Create a contract caller for testing
        contractCaller = address(new MockContractCaller());
        vm.label(contractCaller, 'ContractCaller');

        // Setup token approvals
        vm.prank(alice);
        mockToken.approve(address(aliceProxy), 1000 ether);
    }

    /* ═══════════════════════════ OWNER ACCESS CONTROL TESTS ═══════════════════════════ */

    // Verify that the proxy owner can successfully call the VM through their proxy
    function test_authorized_owner_can_call() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Alice should be able to call her own proxy
        vm.prank(alice);
        (bool success,) = address(aliceProxy).call(callData);
        assertTrue(success, 'Authorized call should succeed');
    }

    // Verify that non-owners are rejected with Unauthorized error when trying to use any proxy
    function test_unauthorized_caller_reverts() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Unauthorized address should be rejected
        vm.prank(unauthorized);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        (bool success,) = address(aliceProxy).call(callData);
        success; // silence unused variable warning
    }

    // Verify that proxy owners cannot access each other's proxies (Alice can't use Bob's proxy and vice versa)
    function test_wrong_owner_cannot_call_other_proxy() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Bob should not be able to call Alice's proxy
        vm.prank(bob);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        (bool success,) = address(aliceProxy).call(callData);
        success; // silence unused variable warning

        // Alice should not be able to call Bob's proxy
        vm.prank(alice);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        (bool success2,) = address(bobProxy).call(callData);
        success2; // silence unused variable warning
    }

    // Verify that contract owners (not just EOAs) can successfully use their proxies
    function test_contract_caller_with_authorization() external {
        // Deploy a proxy for the contract caller
        MinimalProxy contractProxy = MinimalProxy(payable(proxyFactory.deployProxy(contractCaller)));

        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(123));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Contract should be able to call its own proxy
        vm.prank(contractCaller);
        (bool success,) = address(contractProxy).call(callData);
        assertTrue(success, 'Contract caller should succeed');
    }

    /* ═══════════════════════════ REENTRANCY GUARD TESTS ═══════════════════════════ */

    // Verify that the reentrancy guard properly resets between separate calls (no poisoning)
    function test_sequential_calls_succeed() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // First call should succeed
        vm.prank(alice);
        (bool success1,) = address(aliceProxy).call(callData);
        assertTrue(success1, 'First call should succeed');

        // Second call should also succeed (guard should reset)
        s0.registers[0] = abi.encode(uint256(2));
        callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success2,) = address(aliceProxy).call(callData);
        assertTrue(success2, 'Second call should succeed');
    }

    // Verify that when a contract owner attempts reentrancy, the guard triggers and reverts with the caller's address
    // Flow: Owner calls proxy -> VM calls back to owner -> Owner tries to reenter → Guard blocks with ReentrantCall(owner)
    function test_ownerContract_reentrancy_hits_guard() external {
        VmReenterBubble vm2 = new VmReenterBubble();
        ReentrantOwner ownerC = new ReentrantOwner();
        MinimalProxy p = new MinimalProxy(address(ownerC), address(vm2), address(0));

        bytes memory data = hex'feedc0de'; // any bytes; VM ignores

        // Should hit reentrancy guard and revert with caller address
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(ownerC)));
        ownerC.start(address(p), data);
    }

    // Verify that if reentrancy fails but the VM swallows the revert, subsequent calls still work normally
    // This tests that the guard doesn't get stuck in a bad state when reverts are swallowed
    function test_reentrancy_revert_does_not_poison_next_call() external {
        VmReenterSwallow vm2 = new VmReenterSwallow();
        ReentrantOwner ownerC = new ReentrantOwner();
        MinimalProxy p = new MinimalProxy(address(ownerC), address(vm2), address(0));

        bytes memory data = hex'01';
        // First call succeeds even though inner reentry failed
        ownerC.start(address(p), data);

        // Second call also succeeds (guard cleared or reverted state)
        ownerC.start(address(p), data);
    }

    // Verify that reentrancy guards are isolated per proxy (Alice's guard doesn't affect Bob's proxy)
    function test_reentrancy_guard_isolates_different_proxies() external {
        // Test that reentrancy guard on one proxy doesn't affect another
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Complete call on Alice's proxy
        vm.prank(alice);
        (bool success1,) = address(aliceProxy).call(callData);
        assertTrue(success1, "Alice's call should succeed");

        // Bob's proxy should work independently
        s0.registers[0] = abi.encode(uint256(2));
        callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(bob);
        (bool success2,) = address(bobProxy).call(callData);
        assertTrue(success2, "Bob's call should succeed independently");
    }

    // Verify that when an outer transaction reverts after reentrancy, the guard state is properly reverted too
    // Tests that TSTORE/SSTORE state changes revert correctly with the transaction
    function test_outer_revert_does_not_poison_next_call() external {
        VmReenterSwallow vm2 = new VmReenterSwallow();
        ReentrantOwnerOnce ownerC = new ReentrantOwnerOnce();
        MinimalProxy p = new MinimalProxy(address(ownerC), address(vm2), address(0));
        bytes memory data = hex'aa';

        // First call succeeds even though inner reentrancy was blocked by guard
        // The VM swallows the revert, but the ownerC still sets did[proxy] = true
        ownerC.start(address(p), data);

        // Second call on the SAME proxy now succeeds (owner no longer attempts reentrancy)
        ownerC.start(address(p), data);
    }

    /* ═══════════════════════════ COMBINED SECURITY TESTS ═══════════════════════════ */

    // Verify that when a non-owner attempts reentrancy via VM callback, they're blocked by onlyOwner (not the reentrancy guard)
    // Flow: Owner calls proxy -> VM creates attacker -> Attacker tries to call proxy -> onlyOwner blocks with Unauthorized
    function test_nonOwner_reentry_blocks_on_onlyOwner() external {
        VmCallAttacker vm2 = new VmCallAttacker();
        // EOA owner
        MinimalProxy p = new MinimalProxy(alice, address(vm2), address(0));
        bytes memory data = hex'02';

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(p).call(data);
        assertFalse(ok);
        assertEq(bytes4(ret), VmErrors.Unauthorized.selector);
        assertTrue(bytes4(ret) != REENTRANT_CALL_SELECTOR);
    }

    // Verify that authorized owners can make multiple successful calls with different parameters (guard resets properly)
    function test_owner_can_make_multiple_calls_different_data() external {
        // Test that authorized owner can make multiple calls with different data
        VMState memory s0 = Regs.init(2);

        // First call
        s0.registers[0] = abi.encode(uint256(100));
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData1 = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success1,) = address(aliceProxy).call(callData1);
        assertTrue(success1, 'First call should succeed');

        // Second call with different data
        s0.registers[0] = abi.encode(uint256(200));
        bytes memory callData2 = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success2,) = address(aliceProxy).call(callData2);
        assertTrue(success2, 'Second call should succeed');
    }

    // Verify that tx.origin bypass attempts fail - only msg.sender matters for authorization, not tx.origin
    // This prevents attacks where owner signs a transaction that calls a malicious contract that tries to use their proxy
    function test_txOrigin_owner_but_msgSender_not_owner_reverts() external {
        Middleman m = new Middleman();
        MinimalProxy p = new MinimalProxy(alice, address(machine), address(0));

        VMState memory s0 = Regs.init(1);
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory data = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.startPrank(alice); // tx.origin = alice
        (bool success, bytes memory result) = m.callProxy(address(p), data); // msg.sender = middleman
        vm.stopPrank();

        // Should fail because msg.sender != owner, even though tx.origin == owner
        assertFalse(success, 'Call should fail - msg.sender is not owner');
        assertEq(bytes4(result), VmErrors.Unauthorized.selector, 'Should revert with Unauthorized error');
    }

    /* ═══════════════════════════ EDGE CASES AND ERROR SCENARIOS ═══════════════════════════ */

    // Verify that minimal calldata (1 byte) is forwarded to the VM via fallback function (not receive)
    function test_empty_calldata_forwards_to_vm() external {
        MinimalProxy p = new MinimalProxy(alice, address(new VmMarker()), address(0));
        vm.prank(alice);
        vm.expectRevert(ReachedVM.selector); // 1-byte calldata hits fallback, not receive
        address(p).call(hex'00');
    }

    // Verify that calls with invalid function selectors are forwarded to the VM (proxy has no functions)
    function test_invalid_selector_forwards_to_vm() external {
        MinimalProxy p = new MinimalProxy(alice, address(new VmMarker()), address(0));
        bytes memory invalid = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(42));
        vm.prank(alice);
        vm.expectRevert(ReachedVM.selector);
        address(p).call(invalid);
    }

    // Verify that proxies can receive ETH along with function calls and that this doesn't break the reentrancy guard
    function test_proxy_with_eth_value() external {
        assertEq(address(aliceProxy).balance, 0); // Clean start assertion

        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // Send ETH with the call
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(aliceProxy).call{ value: 0.5 ether }(callData);
        assertTrue(success, 'Call with ETH should succeed');

        // Verify proxy received the ETH
        assertEq(address(aliceProxy).balance, 0.5 ether, 'Proxy should have received ETH');
    }

    // Verify that anyone can send ETH to the proxy's receive function and this doesn't interfere with the reentrancy guard
    // The receive function is intentionally open to allow ETH deposits from any source
    function test_anyone_can_send_eth_to_receive_and_guard_intact() external {
        assertEq(address(aliceProxy).balance, 0); // Clean start assertion

        // Test that receive function is open and doesn't affect reentrancy guard
        vm.deal(unauthorized, 1 ether);
        vm.prank(unauthorized);
        (bool ok,) = address(aliceProxy).call{ value: 1 ether }('');
        assertTrue(ok, 'Unauthorized user should be able to send ETH via receive');
        assertEq(address(aliceProxy).balance, 1 ether, 'Proxy should have received ETH');

        // Owner call still succeeds afterwards (guard not affected by receive)
        VMState memory s = Regs.init(1);
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);
        bytes memory cd = abi.encodeWithSelector(machine.runVM.selector, cmds, s);
        vm.prank(alice);
        (ok,) = address(aliceProxy).call(cd);
        assertTrue(ok, 'Owner call should still succeed after receive');
    }

    // Verify that an owner can reenter into a different proxy during VM execution (guards are isolated per proxy)
    // Flow: Owner calls proxyA → vmA reenters proxyB → proxyB allows it (same owner + isolated guard)
    function test_owner_reenters_other_proxy_ok() external {
        ReentrantOwner ownerC = new ReentrantOwner();
        // VM that never reverts on arbitrary calldata
        VmReenterSwallow vmB = new VmReenterSwallow();
        MinimalProxy proxyB = new MinimalProxy(address(ownerC), address(vmB), address(0));

        VmReenterOtherProxy vmA = new VmReenterOtherProxy(address(proxyB));
        MinimalProxy proxyA = new MinimalProxy(address(ownerC), address(vmA), address(0));

        ownerC.start(address(proxyA), hex'01'); // must not revert
    }

    // Verify that the reentrancy guard encodes the caller's address in the revert data for debugging
    function test_guard_reverts_with_owner_address_arg() external {
        VmReenterBubble vm2 = new VmReenterBubble();
        ReentrantOwner ownerC = new ReentrantOwner();
        MinimalProxy p = new MinimalProxy(address(ownerC), address(vm2), address(0));
        bytes memory data = hex'03';
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(ownerC)));
        ownerC.start(address(p), data);
    }

    // Verify that when reentrancy causes a bubbled revert (full transaction rollback), the next call works normally
    // This tests that guard state is properly reverted when the entire transaction fails
    function test_reentrancy_bubbled_revert_then_next_call_succeeds() external {
        VmConditionalReenter vm2 = new VmConditionalReenter(); // bubbles reentry failures, succeeds otherwise
        ReentrantOwnerOnce ownerC = new ReentrantOwnerOnce(); // reenters only once per proxy
        MinimalProxy p = new MinimalProxy(address(ownerC), address(vm2), address(0));
        bytes memory data = hex'01';

        // First call reverts due to guard - this bubbles so all state reverts
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(ownerC)));
        ownerC.start(address(p), data);

        // Set the one-time flag to simulate owner not attempting reentrancy on second call
        ownerC.setDid(address(p));

        // Second call should succeed since:
        // 1. The proxy reentrancy guard was reverted (not stuck)
        // 2. Owner no longer attempts reentrancy (due to did[proxy] = true)
        ownerC.start(address(p), data);
    }

    // Verify that when the VM tries to reenter the same proxy directly, it's blocked by onlyOwner (msg.sender becomes the proxy address)
    function test_vm_self_reenter_blocks_on_onlyOwner() external {
        MinimalProxy p = new MinimalProxy(alice, address(new VmSelfCall()), address(0));
        vm.prank(alice);
        vm.expectRevert(VmErrors.Unauthorized.selector); // msg.sender == proxy on reentry
        (bool ok,) = address(p).call(hex'00');
        ok; // silence unused variable warning
    }

    /// forge-config: default.isolate = false
    // Verify reentrancy guard poisoning attempt in no-isolate mode - calls VM twice in same tx to test guard persistence
    function test_no_isolate_reentrancy_guard_poisoning() external {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(1));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // First VM call in the transaction
        vm.prank(alice);
        (bool success1,) = address(aliceProxy).call(callData);
        assertTrue(success1, 'First VM call should succeed');

        // Second VM call in the same transaction to test guard poisoning
        s0.registers[0] = abi.encode(uint256(2));
        callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success2,) = address(aliceProxy).call(callData);
        assertTrue(success2, 'Second VM call should succeed - no guard poisoning');
    }
}

/**
 * @dev Simple contract for testing contract-to-contract calls
 */
contract MockContractCaller {
    function makeCall(address target, bytes memory data) external returns (bool success, bytes memory result) {
        return target.call(data);
    }
}
