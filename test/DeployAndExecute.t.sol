// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { SpecTestBase } from './SpecTestBase.sol';
import { VMState, VMCommand, CallType } from '../src/DataModel.sol';
import { VmCmd } from './lib/VmCmd.sol';
import { Regs } from './lib/Regs.sol';
import { TestUtils } from './lib/TestUtils.sol';
import { EchoContract, ValueChecker } from './lib/Mocks.sol';
import { MinimalProxy } from '../src/proxy/MinimalProxy.sol';
import { ProxyFactory } from '../src/proxy/ProxyFactory.sol';
import { VmErrors } from '../src/VmErrors.sol';
import { CreateXScript } from 'createx-forge/script/CreateXScript.sol';
import { CREATEX_ADDRESS } from 'createx-forge/script/CreateX.d.sol';

/// forge-config: default.isolate = true
contract DeployAndExecuteTest is SpecTestBase, CreateXScript {
    ProxyFactory proxyFactory;
    EchoContract echoContract;
    ValueChecker valueChecker;

    function setUp() public virtual override withCreateX {
        super.setUp();

        echoContract = new EchoContract();
        valueChecker = new ValueChecker();

        proxyFactory = new ProxyFactory(address(machine), CREATEX_ADDRESS);
        vm.label(address(proxyFactory), 'ProxyFactory');
    }

    /* ═══════════════════════════ HELPER ═══════════════════════════ */

    function _buildReturnCalldata(uint256 val) internal view returns (bytes memory) {
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(val);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        return abi.encodeWithSelector(machine.runVM.selector, cmds, s0);
    }

    /* ═══════════════════════════ HAPPY PATH ═══════════════════════════ */

    /// @notice deployAndExecute deploys proxy and executes commands atomically
    function test_deployAndExecute_happy_path() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Proxy was deployed
        assertTrue(proxy.code.length > 0, 'Proxy should have code');

        // Owner is set correctly
        assertEq(MinimalProxy(payable(proxy)).owner(), alice, 'Owner should be alice');
        assertEq(MinimalProxy(payable(proxy)).vmAddress(), address(machine), 'VM address should match');
        assertEq(MinimalProxy(payable(proxy)).factory(), address(proxyFactory), 'Factory should match');
    }

    /// @notice After deployAndExecute, proxy works identically to deployProxy
    function test_post_deploy_normal_operation() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Make a normal call through the proxy post-deployment
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(123));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success,) = proxy.call(callData);
        assertTrue(success, 'Post-deploy call should succeed');
    }

    /* ═══════════════════════════ DEPOSIT_APPROVED DURING DEPLOY ═══════════════════════════ */

    /// @notice DEPOSIT_APPROVED works during deployAndExecute (pulls from owner via storage slot)
    function test_deposit_approved_during_deploy() external {
        // Predict proxy address and have alice approve it
        address predicted = proxyFactory.predictProxyAddress(alice);

        vm.prank(alice);
        mockToken.approve(predicted, 500 ether);

        // Build DEPOSIT_APPROVED command
        VMState memory s0 = Regs.init(2);
        s0.registers[1] = abi.encode(type(uint256).max);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);

        bytes memory arbiCall = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        uint256 aliceBefore = mockToken.balanceOf(alice);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = predicted;

        // Verify tokens were pulled from alice to proxy
        assertTrue(mockToken.balanceOf(proxy) > 0, 'Proxy should have received tokens');
        assertTrue(mockToken.balanceOf(alice) < aliceBefore, 'Alice balance should decrease');
    }

    /* ═══════════════════════════ VALUE FORWARDING ═══════════════════════════ */

    /// @notice ETH is forwarded from factory to proxy during deployAndExecute
    function test_value_forwarding() external {
        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('checkValue()');
        s0.registers[0] = TestUtils.prependLength(testData);
        s0.registers[2] = abi.encode(1 ether);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.call(address(valueChecker), CallType.VALUECALL, 1, 0, 2);

        bytes memory arbiCall = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        proxyFactory.deployAndExecute{ value: 1 ether }(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        assertTrue(proxy.code.length > 0, 'Proxy should be deployed');
    }

    /// @notice ETH forwarding works with no arbiCall
    function test_value_forwarding_no_init() external {
        vm.prank(alice);
        proxyFactory.deployAndExecute{ value: 1 ether }('');
        address proxy = proxyFactory.predictProxyAddress(alice);

        assertEq(proxy.balance, 1 ether, 'Proxy should have received ETH');
    }

    /* ═══════════════════════════ REVERT PROPAGATION ═══════════════════════════ */

    /// @notice If VM execution fails, entire tx reverts (proxy is NOT deployed)
    function test_revert_propagation() external {
        // Build calldata with an invalid opcode to force a revert
        VMState memory s0 = Regs.init(2);

        VMCommand[] memory cmds = new VMCommand[](1);
        // Use DEPOSIT_APPROVED with zero address token - should revert with InvalidTokenAddress
        cmds[0] = VmCmd.depositApproved(address(0), 0, 1);

        bytes memory arbiCall = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        address predicted = proxyFactory.predictProxyAddress(alice);

        vm.prank(alice);
        vm.expectRevert();
        proxyFactory.deployAndExecute(arbiCall);

        // Proxy should NOT be deployed
        assertEq(predicted.code.length, 0, 'Proxy should not exist after revert');
    }

    /* ═══════════════════════════ ACCESS CONTROL ═══════════════════════════ */

    /// @notice deployAndExecute reverts for zero address caller
    function test_zero_address_reverts() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(address(0));
        vm.expectRevert(VmErrors.InvalidUserAddress.selector);
        proxyFactory.deployAndExecute(arbiCall);
    }

    /* ═══════════════════════════ DOUBLE DEPLOY PREVENTION ═══════════════════════════ */

    /// @notice deployAndExecute reverts if proxy already exists
    function test_double_deploy_prevention() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        // First deploy
        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);

        // Second deploy should fail
        vm.prank(alice);
        vm.expectRevert(VmErrors.ProxyAlreadyDeployed.selector);
        proxyFactory.deployAndExecute(arbiCall);
    }

    /* ═══════════════════════════ FACTORY ONE-TIME ACCESS ═══════════════════════════ */

    /// @notice Factory cannot call proxy a second time (one-time init guard)
    function test_factory_cannot_call_proxy_twice() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Second call from factory should revert with AlreadyInitialized
        vm.prank(address(proxyFactory));
        vm.expectRevert(VmErrors.AlreadyInitialized.selector);
        (bool ok,) = proxy.call(arbiCall);
        ok; // silence unused variable warning
    }

    /// @notice Unauthorized callers cannot call proxy fallback
    function test_unauthorized_caller_reverts() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Non-owner, non-factory caller should revert with Unauthorized
        vm.prank(bob);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        (bool ok,) = proxy.call(arbiCall);
        ok; // silence unused variable warning
    }

    /// @notice Factory can call a deployProxy-created proxy once
    function test_factory_can_call_deployProxy_proxy_once() external {
        address proxy = proxyFactory.deployProxy(alice);

        // Factory can call proxy once via fallback
        vm.prank(address(proxyFactory));
        (bool ok,) = proxy.call(_buildReturnCalldata(42));
        assertTrue(ok, 'Factory should be able to call proxy once');

        // Second call reverts
        vm.prank(address(proxyFactory));
        vm.expectRevert(VmErrors.AlreadyInitialized.selector);
        (bool ok2,) = proxy.call(_buildReturnCalldata(42));
        ok2; // silence unused variable warning
    }

    /* ═══════════════════════════ FRONT-RUNNING SCENARIO ═══════════════════════════ */

    /// @notice Attacker deployProxy + victim deployAndExecute = victim reverts safely
    function test_frontrunning_scenario() external {
        // Attacker front-runs with deployProxy (permissionless)
        proxyFactory.deployProxy(alice);

        // Victim's deployAndExecute should revert cleanly
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        vm.expectRevert(VmErrors.ProxyAlreadyDeployed.selector);
        proxyFactory.deployAndExecute(arbiCall);
    }

    /* ═══════════════════════════ REGRESSION: deployProxy STILL WORKS ═══════════════════════════ */

    /// @notice deployProxy still works with updated creationCode
    function test_deployProxy_regression() external {
        address proxy = proxyFactory.deployProxy(alice);

        assertTrue(proxy.code.length > 0, 'Proxy should have code');
        assertEq(MinimalProxy(payable(proxy)).owner(), alice, 'Owner should be alice');
        assertEq(MinimalProxy(payable(proxy)).vmAddress(), address(machine), 'VM address should match');
        assertEq(MinimalProxy(payable(proxy)).factory(), address(proxyFactory), 'Factory should match');

        // Proxy should work normally
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success,) = proxy.call(callData);
        assertTrue(success, 'deployProxy proxy should work normally');
    }

    /// @notice deployProxy and deployAndExecute produce same deterministic addresses
    function test_address_determinism() external {
        // Predict addresses
        address alicePredicted = proxyFactory.predictProxyAddress(alice);
        address bobPredicted = proxyFactory.predictProxyAddress(bob);

        // Deploy alice via deployProxy
        address aliceProxy = proxyFactory.deployProxy(alice);
        assertEq(aliceProxy, alicePredicted, 'deployProxy address should match prediction');

        // Deploy bob via deployAndExecute
        bytes memory arbiCall = _buildReturnCalldata(42);
        vm.prank(bob);
        proxyFactory.deployAndExecute(arbiCall);
        assertEq(bobPredicted.code.length > 0, true, 'deployAndExecute should deploy proxy at predicted address');
    }

    /* ═══════════════════════════ CALL OPERATION DURING INIT ═══════════════════════════ */

    /// @notice External CALL works during deployAndExecute init
    function test_call_during_init() external {
        VMState memory s0 = Regs.init(4);
        bytes memory testData = abi.encodeWithSignature('test(uint256)', 42);
        s0.registers[0] = TestUtils.prependLength(testData);

        VMCommand[] memory cmds = new VMCommand[](2);
        cmds[0] = VmCmd.call(address(echoContract), CallType.CALL, 1, 0, 2);
        cmds[1] = VmCmd.ret(1);

        bytes memory arbiCall = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        assertTrue(proxy.code.length > 0, 'Proxy should be deployed');
    }

    /* ═══════════════════════════ EMPTY INIT CALLDATA ═══════════════════════════ */

    /// @notice deployAndExecute with empty arbiCall skips execution
    function test_empty_arbiCall() external {
        vm.prank(alice);
        proxyFactory.deployAndExecute('');
        address proxy = proxyFactory.predictProxyAddress(alice);

        assertEq(MinimalProxy(payable(proxy)).owner(), alice);
        assertEq(MinimalProxy(payable(proxy)).vmAddress(), address(machine));

        // Should work normally
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(42));
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        vm.prank(alice);
        (bool success,) = proxy.call(abi.encodeWithSelector(machine.runVM.selector, cmds, s0));
        assertTrue(success);
    }

    /* ═══════════════════════════ EVENT EMISSION ═══════════════════════════ */

    /// @notice deployAndExecute emits ProxyDeployed event
    function test_emits_proxy_deployed_event() external {
        bytes memory arbiCall = _buildReturnCalldata(42);
        address predicted = proxyFactory.predictProxyAddress(alice);

        vm.expectEmit(true, true, false, false);
        emit ProxyFactory.ProxyDeployed(alice, predicted);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
    }

    /* ═══════════════════════════ DEPOSIT_APPROVED POST-DEPLOY ═══════════════════════════ */

    /// @notice DEPOSIT_APPROVED works normally post-deployment when user calls proxy directly
    function test_deposit_approved_works_post_deploy() external {
        // Deploy proxy for alice
        vm.prank(alice);
        proxyFactory.deployAndExecute(_buildReturnCalldata(1));
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Alice approves the proxy for token spending
        vm.prank(alice);
        mockToken.approve(proxy, 1000 ether);

        // Build DEPOSIT_APPROVED command
        VMState memory s0 = Regs.init(2);
        s0.registers[1] = abi.encode(type(uint256).max);

        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        uint256 aliceBefore = mockToken.balanceOf(alice);

        // Alice calls proxy directly — DEPOSIT_APPROVED reads owner from storage and pulls tokens
        vm.prank(alice);
        (bool success,) = proxy.call(callData);
        assertTrue(success, 'DEPOSIT_APPROVED should work post-deploy');

        // Verify tokens were transferred
        assertTrue(mockToken.balanceOf(proxy) > 0, 'Proxy should have tokens');
        assertTrue(mockToken.balanceOf(alice) < aliceBefore, 'Alice balance should decrease');
    }

    /* ═══════════════════════════ SECURITY: ATTACKER CANNOT DRAIN VIA FACTORY ═══════════════════════════ */

    /// @notice Attacker cannot exploit factory's one-time call to steal tokens from another
    /// user's proxy. The malicious payload: DEPOSIT_APPROVED (pull victim's tokens into proxy)
    /// then CALL with transferFrom (move tokens from proxy to attacker).
    ///
    /// Attack path 1: Bob calls Alice's proxy directly → blocked by onlyOwnerOrFactory.
    /// Attack path 2: Bob calls deployAndExecute with malicious payload → deploys Bob's own
    ///                proxy (not Alice's), so the payload executes in Bob's context.
    /// Attack path 3: Bob front-runs with deployProxy(alice), then tries to invoke the
    ///                factory's one-time call on Alice's proxy → the factory has no public
    ///                method to call an already-deployed proxy.
    function test_attacker_cannot_steal_via_call_transfer_payload() external {
        // Step 1: Alice pre-approves her deterministic proxy for tokens
        address aliceProxy = proxyFactory.predictProxyAddress(alice);
        vm.prank(alice);
        mockToken.approve(aliceProxy, 1000 ether);

        uint256 aliceBefore = mockToken.balanceOf(alice);
        uint256 bobBefore = mockToken.balanceOf(bob);

        // Step 2: Bob crafts a malicious payload:
        //   cmd[0] = DEPOSIT_APPROVED  (pull victim's approved tokens into the proxy)
        //   cmd[1] = CALLDATA_BUILD    (build transferFrom(proxy, bob, amount))
        //   cmd[2] = CALL              (execute the transferFrom on the token)
        VMState memory s0 = Regs.init(8);
        s0.registers[1] = abi.encode(type(uint256).max); // maxDeposit
        s0.registers[2] = abi.encode(aliceProxy); // from (proxy itself)
        s0.registers[3] = abi.encode(bob); // to (attacker)
        s0.registers[4] = abi.encode(1000 ether); // amount

        bytes memory bp = abi.encodePacked(uint8(2), uint8(3), uint8(4));
        bytes4 transferFromSel = bytes4(keccak256('transferFrom(address,address,uint256)'));

        VMCommand[] memory cmds = new VMCommand[](3);
        cmds[0] = VmCmd.depositApproved(address(mockToken), 0, 1);
        cmds[1] = VmCmd.cdb(transferFromSel, 5, bp);
        cmds[2] = VmCmd.call(address(mockToken), CallType.CALL, 6, 5, 7);

        bytes memory maliciousPayload = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        // --- Attack path 1: Bob calls Alice's proxy directly → Unauthorized ---
        vm.prank(bob);
        vm.expectRevert(VmErrors.Unauthorized.selector);
        (bool ok,) = aliceProxy.call(maliciousPayload);
        ok; // silence warning

        // --- Attack path 2: Bob uses deployAndExecute ---
        // This deploys BOB's proxy, not Alice's. The DEPOSIT_APPROVED reads _OWNER_SLOT
        // (which is bob in bob's proxy context). Bob hasn't approved his own proxy for
        // tokens, so DEPOSIT_APPROVED deposits 0. Then the CALL to transferFrom tries to
        // move 1000 ether that the proxy doesn't hold → reverts. Atomic rollback.
        vm.prank(bob);
        vm.expectRevert(); // bob's proxy has no tokens
        proxyFactory.deployAndExecute(maliciousPayload);

        // Alice's tokens completely untouched
        assertEq(mockToken.balanceOf(alice), aliceBefore, 'Alice tokens untouched after path 2');

        // --- Attack path 3: Bob front-runs with deployProxy(alice) ---
        vm.prank(bob);
        address deployed = proxyFactory.deployProxy(alice);
        assertEq(deployed, aliceProxy);

        // The factory has no public method to call an already-deployed proxy.
        // Alice's deployAndExecute reverts because her proxy already exists.
        vm.prank(alice);
        vm.expectRevert(VmErrors.ProxyAlreadyDeployed.selector);
        proxyFactory.deployAndExecute(maliciousPayload);

        // Bob can't use deployAndExecute to target alice's proxy either —
        // his second call would also revert (his proxy already exists from failed path 2?
        // No — path 2 reverted atomically, so bob's proxy was never deployed).
        // Bob's new deployAndExecute deploys bob's proxy, not alice's.
        // But the payload still fails because bob's proxy has no tokens.
        vm.prank(bob);
        vm.expectRevert(); // bob's proxy still has no tokens
        proxyFactory.deployAndExecute(maliciousPayload);

        // Final verification: no tokens moved
        assertEq(mockToken.balanceOf(alice), aliceBefore, 'Alice tokens still untouched');
        assertEq(mockToken.balanceOf(bob), bobBefore, 'Bob gained nothing');
        assertEq(mockToken.balanceOf(aliceProxy), 0, 'Alice proxy has no tokens');
    }

    /// @notice Owner can still call proxy after factory init has been used
    function test_owner_calls_after_factory_init() external {
        bytes memory arbiCall = _buildReturnCalldata(42);

        vm.prank(alice);
        proxyFactory.deployAndExecute(arbiCall);
        address proxy = proxyFactory.predictProxyAddress(alice);

        // Owner should still be able to call after factory used its one-time access
        VMState memory s0 = Regs.init(2);
        s0.registers[0] = abi.encode(uint256(99));
        VMCommand[] memory cmds = new VMCommand[](1);
        cmds[0] = VmCmd.ret(0);

        bytes memory callData = abi.encodeWithSelector(machine.runVM.selector, cmds, s0);

        vm.prank(alice);
        (bool success,) = proxy.call(callData);
        assertTrue(success, 'Owner should be able to call after factory init');

        // Owner can call multiple times
        vm.prank(alice);
        (bool success2,) = proxy.call(callData);
        assertTrue(success2, 'Owner should be able to call multiple times');
    }

    /* ═══════════════════════════ RETURN DATA ═══════════════════════════ */

    /// @notice deployAndExecute returns raw VM output bytes
    function test_deployAndExecute_returns_vm_output() external {
        bytes memory arbiCall = _buildReturnCalldata(42);
        vm.prank(alice);
        bytes memory vmResult = proxyFactory.deployAndExecute(arbiCall);
        assertTrue(vmResult.length > 0, 'VM result should not be empty');
        uint256 returned = abi.decode(vmResult, (uint256));
        assertEq(returned, 42);
    }

    /// @notice deployAndExecute with empty calldata returns empty bytes
    function test_deployAndExecute_empty_calldata_returns_empty_bytes() external {
        vm.prank(alice);
        bytes memory vmResult = proxyFactory.deployAndExecute('');
        assertEq(vmResult.length, 0, 'Empty calldata should produce empty result');
    }
}
