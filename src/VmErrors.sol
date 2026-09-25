// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/// @title VmErrors
/// @custom:version 1.1.0
/// @notice Shared error definitions for the Virtual Machine
library VmErrors {
    /// @notice Thrown when a disallowed operation is executed
    error Disallowed();

    /// @notice Thrown when a read exceeds the bounds of the source data. Raised by
    ///         `SurgeryOPS` (surgery offset/length), `ExplodeLib` (source shorter than the head
    ///         region, or a dynamic offset that is unaligned, inside the head region, past the
    ///         source, or not strictly increasing) and `MemoryUtils.slice`.
    error OutOfBounds();

    /// @notice Thrown when replacement data exceeds surgery length
    error ReplacementTooLarge();

    /// @notice Thrown when too many surgeries are requested (maximum 6)
    error TooManySurgeries();

    /// @notice Thrown when an invalid log variant is provided
    error InvalidLogVariant();

    /// @notice Thrown when an invalid call type is provided
    error InvalidCallType();

    /// @notice Thrown when a blueprint exceeds the maximum allowed size
    error BlueprintTooLarge();

    /// @notice Thrown when source registers exceed 208 bits for log packing
    error SourceRegistersExceed208Bits();

    /// @notice Thrown when no tokens are approved for deposit
    error NoApprovedTokens();

    /// @notice Thrown when token transfer fails during deposit
    error TokenTransferFailed();

    /// @notice Thrown when an invalid opcode is encountered
    error InvalidOpcode(uint8 opcode);

    /// @notice Thrown when bytes are attempted to be read as address
    error InvalidAddressBytes();

    /// @notice Thrown when calldata is too short (must be at least 36 bytes: 32 for length + 4 for selector)
    error InvalidCallDataLength();

    /// @notice Thrown when value data is too short (must be at least 32 bytes)
    error InvalidValueLength();

    /// @notice Thrown when too many operations are requested (maximum 32)
    error TooManyOperations();

    /// @notice Thrown when an invalid user address (zero address) is provided
    error InvalidUserAddress();

    /// @notice Thrown when a proxy has already been deployed for the user
    error ProxyAlreadyDeployed();

    /// @notice Thrown when unauthorized access is attempted
    error Unauthorized();

    /// @notice Thrown when attempting to call a non-contract address
    error CallToNonContract();

    /// @notice Thrown when register data has invalid length
    error InvalidRegisterLength();

    /// @notice Thrown when destination register count is outwith allowed range
    error DestinationCountOutOfBounds(uint8 count);

    /// @notice Thrown when destination register count does not match the specified count
    error DestinationCountMismatch(uint8 expected, uint256 found);

    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();

    /// @notice Thrown when an invalid token address is provided
    error InvalidTokenAddress();

    /// @notice Thrown when GetBalance call fails (in DepositApproved)
    error GetBalanceFailed();

    /// @notice Thrown when factoryInitialize has already been called
    error AlreadyInitialized();

    /// @notice Thrown when reserved padding bytes in a packed command word are non-zero
    error NonZeroPadding();
}
