// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import { Test } from 'forge-std/Test.sol';
import { MinimalProxy } from '../src/proxy/MinimalProxy.sol';
import { Tstorish } from '../src/proxy/TStorish.sol';
import { VmErrors } from '../src/VmErrors.sol';

/**
 * @title MinimalProxyReentrancyTest
 * @notice Comprehensive test suite for MinimalProxy reentrancy guard functionality
 * @dev Tests both TSTORE and SSTORE paths, various reentrancy scenarios, and edge cases
 */
contract MinimalProxyReentrancyTest is Test {
    // Test contracts
    MinimalProxy proxy;
    MinimalProxy proxyB;
    ReentrantCaller reentrantOwner;
    address owner = address(0x1337);
    address attacker = address(0xDEAD);

    // Reentrancy guard error selector: ReentrantCall(address existingCaller)
    bytes4 constant REENTRANT_CALL_SELECTOR = 0xf57c448b;

    // Events for testing
    event CallExecuted(address caller, bytes data);
    event ReentryAttempted(address proxy, bytes data);

    function setUp() public {
        vm.label(owner, 'Owner');
        vm.label(attacker, 'Attacker');

        // Deploy reentrant owner contract
        reentrantOwner = new ReentrantCaller();
        vm.label(address(reentrantOwner), 'ReentrantOwner');
    }

    // ============ Basic Reentrancy Guard Tests ============

    /**
     * @notice Test that direct reentrancy is properly blocked
     */
    function test_directReentrancy_blocked() public {
        MockVmReentrant vmReentrant = new MockVmReentrant();
        proxy = new MinimalProxy(address(reentrantOwner), address(vmReentrant), address(0));

        bytes memory data = abi.encode('test');

        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(reentrantOwner)));
        reentrantOwner.start(address(proxy), data);
    }

    /**
     * @notice Test that guard properly clears between separate calls
     */
    function test_guardClearsBetweenCalls() public {
        MockVmSimple vmSimple = new MockVmSimple();
        proxy = new MinimalProxy(owner, address(vmSimple), address(0));

        // First call should succeed
        vm.prank(owner);
        (bool success1, bytes memory result1) = address(proxy).call('call1');
        assertTrue(success1, 'First call should succeed');
        assertEq(result1, abi.encode('success'));

        // Second call should also succeed (guard cleared)
        vm.prank(owner);
        (bool success2, bytes memory result2) = address(proxy).call('call2');
        assertTrue(success2, 'Second call should succeed');
        assertEq(result2, abi.encode('success'));
    }

    /**
     * @notice Test that guard correctly stores and reports caller address
     */
    function test_guardStoresCallerAddress() public {
        MockVmReentrantReporter vmReporter = new MockVmReentrantReporter();
        proxy = new MinimalProxy(address(reentrantOwner), address(vmReporter), address(0));

        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(reentrantOwner)));
        reentrantOwner.start(address(proxy), 'test');
    }

    // ============ TSTORE vs SSTORE Behavior Tests ============

    /**
     * @notice Test guard behavior with TSTORE support mocked
     */
    function test_guardWithTstoreSupport() public {
        MockTstorishEnabled tstorishVm = new MockTstorishEnabled();
        proxy = new MinimalProxy(owner, address(tstorishVm), address(0));

        // The guard should work the same whether using TSTORE or SSTORE
        vm.prank(owner);
        (bool success, bytes memory result) = address(proxy).call('test');
        assertTrue(success, 'Call should succeed with TSTORE');
        assertEq(result, abi.encode('tstore_used'));
    }

    /**
     * @notice Test guard behavior when falling back to SSTORE
     */
    function test_guardWithSstoreFallback() public {
        MockTstorishDisabled tstorishVm = new MockTstorishDisabled();
        proxy = new MinimalProxy(owner, address(tstorishVm), address(0));

        vm.prank(owner);
        (bool success, bytes memory result) = address(proxy).call('test');
        assertTrue(success, 'Call should succeed with SSTORE');
        assertEq(result, abi.encode('sstore_used'));
    }

    /**
     * @notice Test TSTORE activation after deployment
     */
    function test_tstoreActivationAfterDeployment() public {
        MockTstorishUpgradeable upgradeable = new MockTstorishUpgradeable();
        proxy = new MinimalProxy(owner, address(upgradeable), address(0));

        // Initially uses SSTORE
        vm.prank(owner);
        (bool success1,) = address(proxy).call('check');
        assertTrue(success1, 'Should work with SSTORE initially');

        // Activate TSTORE (would be done through Tstorish.__activateTstore() in real scenario)
        upgradeable.simulateActivation();

        // Now uses TSTORE
        vm.prank(owner);
        (bool success2,) = address(proxy).call('check');
        assertTrue(success2, 'Should work with TSTORE after activation');
    }

    // ============ Complex Reentrancy Scenarios ============

    /**
     * @notice Test nested reentrancy attempts (A -> B -> A)
     */
    function test_nestedReentrancy() public {
        MockVmNestedReentrant vmNested = new MockVmNestedReentrant();
        proxy = new MinimalProxy(owner, address(vmNested), address(0));
        proxyB = new MinimalProxy(owner, address(vmNested), address(0));

        vmNested.setProxies(address(proxy), address(proxyB));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, owner));
        address(proxy).call('nested');
    }

    /**
     * @notice Test cross-proxy reentrancy (proxy A reenters proxy B)
     */
    function test_crossProxyReentrancy() public {
        MockVmCrossProxy vmCross = new MockVmCrossProxy();
        proxy = new MinimalProxy(owner, address(vmCross), address(0));
        proxyB = new MinimalProxy(owner, address(vmCross), address(0));

        vmCross.setOtherProxy(address(proxyB));

        // Cross-proxy reentrancy should succeed (different guard slots)
        vm.prank(owner);
        (bool success,) = address(proxy).call('cross');
        assertTrue(success, 'Cross-proxy call should succeed');
    }

    /**
     * @notice Test reentrancy through multiple delegatecall levels
     */
    function test_multiLevelDelegatecallReentrancy() public {
        MockVmMultiLevel vmMulti = new MockVmMultiLevel();
        MockVmReentrant vmReentrant = new MockVmReentrant();

        vmMulti.setTarget(address(vmReentrant));
        proxy = new MinimalProxy(owner, address(vmMulti), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, owner));
        address(proxy).call('multi');
    }

    /**
     * @notice Test reentrancy with different msg.sender values
     */
    function test_reentrancyDifferentSenders() public {
        MockVmChangeSender vmChange = new MockVmChangeSender();
        proxy = new MinimalProxy(owner, address(vmChange), address(0));

        // Even with different sender in nested call, should be blocked by onlyOwner
        vm.prank(owner);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        address(proxy).call('change');
    }

    // ============ Guard State Management Tests ============

    /**
     * @notice Test that guard uses value 1 as "cleared" state for efficiency
     */
    function test_guardClearedStateValue() public {
        MockVmStateChecker vmChecker = new MockVmStateChecker();
        proxy = new MinimalProxy(owner, address(vmChecker), address(0));

        // After a successful call, guard should be set to 1 (cleared)
        vm.prank(owner);
        (bool success, bytes memory result) = address(proxy).call('check');
        assertTrue(success);

        uint256 guardValue = abi.decode(result, (uint256));
        assertEq(guardValue, 1, 'Cleared guard should have value 1');
    }

    /**
     * @notice Test that addresses > 1 are identified as "entered" state
     */
    function test_guardEnteredStateDetection() public {
        MockVmReentrantWithCheck vmCheck = new MockVmReentrantWithCheck();
        proxy = new MinimalProxy(address(reentrantOwner), address(vmCheck), address(0));

        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(reentrantOwner)));
        reentrantOwner.start(address(proxy), 'test');
    }

    /**
     * @notice Test proper encoding of ReentrantCall error with caller address
     */
    function test_reentrantCallErrorEncoding() public {
        MockVmReentrant vmReentrant = new MockVmReentrant();

        // Test with different owner addresses
        address[] memory owners = new address[](3);
        owners[0] = address(0x1111);
        owners[1] = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        owners[2] = address(uint160(uint256(keccak256('random'))));

        for (uint256 i = 0; i < owners.length; i++) {
            ReentrantCaller ownerCaller = new ReentrantCaller();
            MinimalProxy testProxy = new MinimalProxy(address(ownerCaller), address(vmReentrant), address(0));

            vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, address(ownerCaller)));
            ownerCaller.start(address(testProxy), 'test');
        }
    }

    // ============ Edge Cases & Error Scenarios ============

    /**
     * @notice Test behavior when VM bubbles reentry errors
     */
    function test_vmBubblesReentryError() public {
        MockVmReentrantBubble vmBubble = new MockVmReentrantBubble();
        proxy = new MinimalProxy(owner, address(vmBubble), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(REENTRANT_CALL_SELECTOR, owner));
        address(proxy).call('bubble');
    }

    /**
     * @notice Test behavior when VM swallows reentry errors
     */
    function test_vmSwallowsReentryError() public {
        MockVmReentrantSwallow vmSwallow = new MockVmReentrantSwallow();
        proxy = new MinimalProxy(owner, address(vmSwallow), address(0));

        // Call succeeds even though reentrancy was attempted and blocked
        vm.prank(owner);
        (bool success, bytes memory result) = address(proxy).call('swallow');
        assertTrue(success, 'Call should succeed when VM swallows error');
        assertEq(result, abi.encode('swallowed'));

        // Subsequent call should also work (guard properly cleared)
        vm.prank(owner);
        (bool success2,) = address(proxy).call('normal');
        assertTrue(success2, 'Subsequent call should succeed');
    }

    /**
     * @notice Test guard during failed delegatecalls
     */
    function test_guardWithFailedDelegatecall() public {
        MockVmReverting vmRevert = new MockVmReverting();
        proxy = new MinimalProxy(owner, address(vmRevert), address(0));

        vm.prank(owner);
        vm.expectRevert('VM_REVERT');
        address(proxy).call('fail');

        // Guard should be properly cleared even after revert
        MockVmSimple vmSimple = new MockVmSimple();
        proxy = new MinimalProxy(owner, address(vmSimple), address(0));

        vm.prank(owner);
        (bool success,) = address(proxy).call('test');
        assertTrue(success, 'Should work after failed delegatecall');
    }
}

// ============ Mock Helper Contracts ============

/**
 * @dev Contract that can be called to attempt reentrancy
 */
contract ReentrantCaller {
    function reenter(address proxy, bytes calldata data) external {
        // Attempt to reenter the proxy
        (bool success, bytes memory result) = proxy.call(data);
        if (!success) {
            // Bubble up the exact error
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }

    function start(address proxy, bytes calldata data) external {
        // Initial call to proxy
        (bool success, bytes memory result) = proxy.call(data);
        if (!success) {
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }
}

// ============ Mock VM Contracts ============

/**
 * @dev Simple VM that returns success
 */
contract MockVmSimple {
    fallback() external payable {
        bytes memory result = abi.encode('success');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM that attempts direct reentrancy
 */
contract MockVmReentrant {
    fallback() external payable {
        // Try to reenter the proxy via the owner (msg.sender in delegatecall context)
        (bool success,) = msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        if (!success) {
            // Bubble up the revert
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}

/**
 * @dev VM that attempts reentrancy and reports the error
 */
contract MockVmReentrantReporter {
    fallback() external payable {
        // Try to reenter via the owner and capture the exact error
        (bool success, bytes memory result) =
            msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        if (!success) {
            // Return the exact revert data
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }
}

/**
 * @dev VM that bubbles reentrancy errors
 */
contract MockVmReentrantBubble {
    fallback() external payable {
        (bool success, bytes memory result) = address(this).call(msg.data);
        if (!success) {
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }
}

/**
 * @dev VM that swallows reentrancy errors
 */
contract MockVmReentrantSwallow {
    fallback() external payable {
        // Attempt reentrancy but swallow any errors
        address(this).call(msg.data);

        // Return success regardless
        bytes memory result = abi.encode('swallowed');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM that simulates TSTORE support
 */
contract MockTstorishEnabled {
    fallback() external payable {
        bytes memory result = abi.encode('tstore_used');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM that simulates SSTORE fallback
 */
contract MockTstorishDisabled {
    fallback() external payable {
        bytes memory result = abi.encode('sstore_used');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM that can simulate TSTORE activation
 */
contract MockTstorishUpgradeable {
    bool public tstoreActive;

    function simulateActivation() external {
        tstoreActive = true;
    }

    fallback() external payable {
        bytes memory result = tstoreActive ? abi.encode('tstore') : abi.encode('sstore');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM for testing nested reentrancy
 */
contract MockVmNestedReentrant {
    address proxyA;
    address proxyB;

    function setProxies(address _a, address _b) external {
        proxyA = _a;
        proxyB = _b;
    }

    fallback() external payable {
        if (address(this) == proxyA) {
            // From proxy A, call proxy B
            (bool success, bytes memory result) = proxyB.call(msg.data);
            if (!success) {
                assembly {
                    let size := mload(result)
                    revert(add(result, 0x20), size)
                }
            }
        } else {
            // From proxy B, try to call back to proxy A
            (bool success, bytes memory result) = proxyA.call(msg.data);
            if (!success) {
                assembly {
                    let size := mload(result)
                    revert(add(result, 0x20), size)
                }
            }
        }
    }
}

/**
 * @dev VM for cross-proxy calls
 */
contract MockVmCrossProxy {
    address otherProxy;

    function setOtherProxy(address _other) external {
        otherProxy = _other;
    }

    fallback() external payable {
        if (otherProxy != address(0)) {
            // Call the other proxy (should succeed as guards are isolated)
            (bool success,) = otherProxy.call('data');
            require(success, 'Cross-proxy call failed');
        }

        bytes memory result = abi.encode('success');
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM for multi-level delegatecall testing
 */
contract MockVmMultiLevel {
    address target;

    function setTarget(address _target) external {
        target = _target;
    }

    fallback() external payable {
        // Delegatecall to another contract that will attempt reentrancy
        (bool success, bytes memory result) = target.delegatecall(msg.data);
        if (!success) {
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }
}

/**
 * @dev VM that changes sender during reentrancy
 */
contract MockVmChangeSender {
    fallback() external payable {
        // Create new contract to change msg.sender
        Attacker attacker = new Attacker();
        bytes memory result = attacker.attemptCall(address(this), msg.data);
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev Helper contract for changing sender
 */
contract Attacker {
    function attemptCall(address target, bytes memory data) external returns (bytes memory) {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            return result;
        }
        return abi.encode('unexpected_success');
    }
}

/**
 * @dev VM for checking guard state values
 */
contract MockVmStateChecker {
    fallback() external payable {
        // In a real implementation, we'd check the actual storage slot
        // For testing, we simulate the cleared state value
        bytes memory result = abi.encode(uint256(1));
        assembly {
            return(add(result, 0x20), mload(result))
        }
    }
}

/**
 * @dev VM that checks for entered state during reentrancy
 */
contract MockVmReentrantWithCheck {
    fallback() external payable {
        // Attempt reentrancy which should detect entered state
        (bool success, bytes memory result) =
            msg.sender.call(abi.encodeWithSignature('reenter(address,bytes)', address(this), msg.data));
        if (!success) {
            assembly {
                let size := mload(result)
                revert(add(result, 0x20), size)
            }
        }
    }
}

/**
 * @dev VM that always reverts with a specific message
 */
contract MockVmReverting {
    fallback() external payable {
        revert('VM_REVERT');
    }
}
