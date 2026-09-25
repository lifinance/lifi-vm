// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import './TestUtils.sol';
import 'forge-std/Vm.sol';

/// @notice Consolidated contract for all echo functionality.
/// @dev Example: EchoContract echo = new EchoContract();
contract EchoContract {
    struct Tuple {
        string a;
        string b;
    }

    /// @notice Return exact calldata received.
    /// @dev Example: bytes memory result = echo.echo(data);
    fallback(bytes calldata) external payable returns (bytes memory) {
        return msg.data;
    }

    /// @notice Receive function for ETH transfers.
    receive() external payable { }

    /// @notice Return exact string received.
    /// @dev Example: string memory result = echo.echo("hello");
    function echo(string memory input) external pure returns (string memory) {
        return input;
    }

    /// @notice Return exact bytes received.
    /// @dev Example: bytes memory result = echo.echo(data);
    function echo(bytes memory input) external pure returns (bytes memory) {
        return input;
    }

    /// @notice Return exact tuple received.
    /// @dev Example: (uint256, string[], uint256) memory result = echo.echo(value1, strings, value2);
    function echo(
        uint256 value1,
        string[] memory strings,
        uint256 value2
    )
        external
        pure
        returns (uint256, string[] memory, uint256)
    {
        return (value1, strings, value2);
    }

    /// @notice Return exact uint256 array received.
    /// @dev Example: uint256[] memory result = echo.echo(values);
    function echo(uint256[] memory values) external pure returns (uint256[] memory) {
        return values;
    }

    /// @notice Return exact uint256 received.
    /// @dev Example: uint256 result = target.echoUint256(42);
    function echoUint256(uint256 value) public pure returns (uint256) {
        return value;
    }

    /// @notice Return exact bytes received.
    /// @dev Example: bytes memory result = target.echoBytes(data);
    function echoBytes(bytes memory data) public pure returns (bytes memory) {
        return data;
    }

    /// @notice Return exact string received.
    /// @dev Example: string memory result = target.echoString("hello");
    function echoString(string memory s) public pure returns (string memory) {
        return s;
    }

    /// @notice Return two strings unchanged.
    /// @dev Example: (string memory, string memory) = target.echoStrings("a", "b");
    function echoStrings(string memory s, string memory s2) public pure returns (string memory, string memory) {
        return (s, s2);
    }

    /// @notice Return mixed types unchanged.
    /// @dev Example: (uint256, string memory) = target.echoMixed(42, "hello");
    function echoMixed(uint256 x, string memory s) public pure returns (uint256, string memory) {
        return (x, s);
    }

    /// @notice Return uint256 array unchanged.
    /// @dev Example: uint256[] memory result = target.echoUint256Array(values);
    function echoUint256Array(uint256[] memory arr) public pure returns (uint256[] memory) {
        return arr;
    }

    /// @notice Return string array unchanged.
    /// @dev Example: string[] memory result = target.echoStringArray(strings);
    function echoStringArray(string[] memory arr) public pure returns (string[] memory) {
        return arr;
    }

    /// @notice Return tuple unchanged.
    /// @dev Example: EchoContract.Tuple memory result = target.echoTuple(tup);
    function echoTuple(Tuple calldata tup) external pure returns (Tuple memory) {
        return tup;
    }

    /// @notice Return two tuples unchanged.
    /// @dev Example: (Tuple memory, Tuple memory) = target.echoTwoTuples(tup1, tup2);
    function echoTwoTuples(Tuple calldata tup1, Tuple calldata tup2)
        external
        pure
        returns (Tuple memory, Tuple memory)
    {
        return (tup1, tup2);
    }
}

/// @notice Reverts unless msg.value equals expected amount.
/// @dev Example: ValueCheck checker = new ValueCheck(1 ether);
contract ValueCheck {
    uint256 public immutable expectedValue;

    /// @notice Set expected value on deployment.
    /// @param _expectedValue Required msg.value for calls.
    constructor(uint256 _expectedValue) {
        expectedValue = _expectedValue;
    }

    /// @notice Revert if msg.value doesn't match.
    /// @dev Example: checker.check{value: 1 ether}();
    fallback() external payable {
        require(msg.value == expectedValue, 'Incorrect value');
    }

    receive() external payable { }
}

/// @notice Always reverts with configurable reason.
/// @dev Example: Reverter rev = new Reverter("Custom error");
contract Reverter {
    string public reason;

    /// @notice Configure revert behavior.
    /// @param _reason Revert reason string.
    constructor(string memory _reason) {
        reason = _reason;
    }

    /// @notice Always reverts.
    /// @dev Example: rev.fail(); // reverts
    fallback() external payable {
        revert(reason);
    }

    receive() external payable { }
}

/// @notice Target for testing CALLDATA_SURGERY operation.
/// @dev Example: SurgeryTarget target = new SurgeryTarget();
contract SurgeryTarget {
    /// @notice Return modified values.
    /// @dev Example: (uint256, address) = target.replaceParts(123, addr);
    function replaceParts(uint256 value, address addr) external pure returns (uint256, address) {
        return (value, addr);
    }
}

/// @notice Target that always reverts.
/// @dev Example: RevertingTarget target = new RevertingTarget();
contract RevertingTarget {
    error AlwaysFails(string message);

    /// @notice Always reverts with error.
    /// @dev Example: target.fail(); // reverts
    function fail() public pure {
        revert AlwaysFails('Execution is meant to fail.');
    }

    /// @notice Always reverts with message.
    /// @dev Example: target.alwaysReverts(); // reverts
    function alwaysReverts() external pure {
        revert('Always reverts');
    }
}

/// @notice Stateful contract for testing DELEGATECALL.
/// @dev Example: LogicContract logic = new LogicContract();
contract LogicContract {
    uint256 public x;

    /// @notice Set state variable x.
    /// @dev Example: logic.setX(42);
    function setX(uint256 _x) public {
        x = _x;
    }
}

/// @notice Dispatcher executing calls to arbitrary addresses.
/// @dev Example: DispatcherTarget dispatcher = new DispatcherTarget();
contract DispatcherTarget {
    /// @notice Execute call to target with data.
    /// @dev Example: bytes memory result = dispatcher.executeCall(target, data);
    function executeCall(address target, bytes calldata data) external returns (bytes memory) {
        (bool success, bytes memory result) = target.call(data);
        require(success, 'Call failed');
        return result;
    }
}

/// @notice Checks msg.value and returns it.
/// @dev Example: ValueChecker checker = new ValueChecker();
contract ValueChecker {
    uint256 public lastValue;

    /// @notice Store and return msg.value.
    /// @dev Example: uint256 value = checker.checkValue{value: 1 ether}();
    function checkValue() external payable returns (uint256) {
        lastValue = msg.value;
        return msg.value;
    }
}

/// @notice Stateful contract for testing state changes.
/// @dev Example: StateChanger changer = new StateChanger();
contract StateChanger {
    uint256 public state;

    /// @notice Change state to new value.
    /// @dev Example: changer.changeState(42);
    function changeState(uint256 newState) external {
        state = newState;
    }

    /// @notice View current state.
    /// @dev Example: uint256 currentState = changer.viewState();
    function viewState() external view returns (uint256) {
        return state;
    }
}

/// @notice Helper to get EOA-like address.
/// @dev Example: address eoa = Mocks.noCode();
library Mocks {
    /// @notice Get address with no deployed code.
    /// @dev Example: address eoa = Mocks.noCode();
    /// @return addr Address guaranteed to have no code.
    function noCode() internal returns (address addr) {
        // Use a deterministic address
        addr = address(0xDEAdBeeFBAdf00dC0FfeE1cEB00DaFbEAdBEEf00);
        // Ensure it has no code by etching empty bytecode
        Vm vm = TestUtils.getVm();
        vm.etch(addr, '');
    }
}
