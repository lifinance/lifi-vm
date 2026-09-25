// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import '../../src/DataModel.sol';
import '../../src/CommandPacking.sol';
import '../../src/VmConstants.sol';

/// @notice Build fully packed VMCommand structs/words. Do not expose packing details.
/// @dev Example: VMCommand cmd = VmCmd.call(target, uint8(CallType.CALL), 1, 2, 3);
library VmCmd {
    /// @notice Build a CALLDATA_BUILD command with selector and blueprint.
    /// @dev Example: VmCmd.cdb(bytes4(keccak256("transfer(address,uint256)")), 1, bp);
    /// @param sel Function selector to encode.
    /// @param dest Destination register for built calldata.
    /// @param bp Blueprint defining calldata structure (≤22 bytes).
    /// @return VMCommand with packed CALLDATA_BUILD operation.
    function cdb(bytes4 sel, uint8 dest, bytes memory bp) internal pure returns (VMCommand memory) {
        require(bp.length <= VmConstants.MAX_CDB_BP, 'Blueprint exceeds 22 bytes');
        return VMCommand({ op: OP.CALLDATA_BUILD, data: CommandPacking.packCallDataBuild(sel, dest, bp) });
    }

    /// @notice Build an ABI_ENCODE command from blueprint.
    /// @dev Example: VmCmd.abiEnc(1, bp);
    /// @param dest Destination register for encoded data.
    /// @param bp Blueprint defining encoding structure (≤27 bytes).
    /// @return VMCommand with packed ABI_ENCODE operation.
    function abiEnc(uint8 dest, bytes memory bp) internal pure returns (VMCommand memory) {
        require(bp.length <= VmConstants.MAX_ABI_BP, 'Blueprint exceeds 27 bytes');
        return VMCommand({ op: OP.ABI_ENCODE, data: CommandPacking.packAbiEncode(dest, bp) });
    }

    /// @notice Build a CALL command with specified parameters.
    /// @dev Example: VmCmd.call(target, CallType.CALL, 1, 2, 3);
    /// @param to Target contract address.
    /// @param callType Call type enum value.
    /// @param dest Destination register for return data.
    /// @param dataReg Register containing calldata.
    /// @param valueReg Register containing call value (for VALUECALL).
    /// @return VMCommand with packed CALL operation.
    function call(
        address to,
        CallType callType,
        uint8 dest,
        uint8 dataReg,
        uint8 valueReg
    )
        internal
        pure
        returns (VMCommand memory)
    {
        return VMCommand({ op: OP.CALL, data: CommandPacking.packCall(to, uint8(callType), dest, dataReg, valueReg) });
    }

    /// @notice Build a RETURN command from source register.
    /// @dev Example: VmCmd.ret(1);
    /// @param src Register containing data to return.
    /// @return VMCommand with packed RETURN operation.
    function ret(uint8 src) internal pure returns (VMCommand memory) {
        return VMCommand({ op: OP.RETURN, data: CommandPacking.packReturn(src) });
    }

    /// @notice Build a REMAINING_GAS command.
    /// @dev Example: VmCmd.gasTo(1);
    /// @param dest Destination register for gas value.
    /// @return VMCommand with packed REMAINING_GAS operation.
    function gasTo(uint8 dest) internal pure returns (VMCommand memory) {
        return VMCommand({ op: OP.REMAINING_GAS, data: CommandPacking.packRemainingGas(dest) });
    }

    /// @notice Build a NATIVE_BALANCE command.
    /// @dev Example: VmCmd.nativeBal(0, 1);
    /// @param addrReg Register containing target address.
    /// @param dest Destination register for balance value.
    /// @return VMCommand with packed NATIVE_BALANCE operation.
    function nativeBal(uint8 addrReg, uint8 dest) internal pure returns (VMCommand memory) {
        return VMCommand({ op: OP.NATIVE_BALANCE, data: CommandPacking.packNativeBalance(addrReg, dest) });
    }

    /// @notice Build a LOG command with variant and source registers.
    /// @dev Example: VmCmd.logOp(uint8(LogVariant.STATIC_1), uint256(1));
    /// @param variant Log variant (use LogVariant enum).
    /// @param sourceRegsPacked Packed register indices (max 208 bits).
    /// @return VMCommand with packed LOG operation.
    function logOp(uint8 variant, uint256 sourceRegsPacked) internal pure returns (VMCommand memory) {
        return VMCommand({ op: OP.LOG, data: CommandPacking.packLog(variant, sourceRegsPacked) });
    }

    /// @notice Build a CALLDATA_SURGERY command with descriptors.
    /// @dev Example: VmCmd.surgery(0, descs);
    /// @param srcReg Register containing template calldata.
    /// @param descs Surgery descriptors array.
    /// @return VMCommand with packed CALLDATA_SURGERY operation.
    function surgery(uint8 srcReg, SurgeryDescriptor[] memory descs) internal pure returns (VMCommand memory) {
        require(descs.length <= VmConstants.MAX_SURGERIES, 'too many surgeries');

        CallDataSurgery memory surg;
        surg.sourceReg = srcReg;
        surg.surgeryCount = uint8(descs.length);

        for (uint256 i = 0; i < descs.length; i++) {
            surg.surgeries[i] = descs[i];
        }

        return VMCommand({ op: OP.CALLDATA_SURGERY, data: CommandPacking.packCallDataSurgery(surg) });
    }

    /// @notice Build a DEPOSIT_APPROVED command.
    /// @dev Example: VmCmd.depositApproved(token, 1, 2);
    /// @param token Static ERC20 token address.
    /// @param dest Destination register for deposited amount.
    /// @param maxDepositReg Register containing the maximum deposit amount.
    /// @return VMCommand with packed DEPOSIT_APPROVED operation.
    function depositApproved(address token, uint8 dest, uint8 maxDepositReg) internal pure returns (VMCommand memory) {
        return VMCommand({
            op: OP.DEPOSIT_APPROVED,
            data: CommandPacking.packDepositApproved(
                DepositApproved({ token: token, destReg: dest, maxDepositReg: maxDepositReg })
            )
        });
    }

    /// @notice Build an EXPLODE command to decompose tuple.
    /// @param sourceReg Register containing tuple to explode.
    /// @param destRegs Destination registers.
    /// @return VMCommand with packed EXPLODE operation.
    function explode(uint8 sourceReg, uint8[] memory destRegs) internal pure returns (VMCommand memory) {
        return
            VMCommand({ op: OP.EXPLODE, data: CommandPacking.packExplode(sourceReg, uint8(destRegs.length), destRegs) });
    }

    /// @notice Build a SAFE_TRANSFER command for ERC20 token transfers.
    /// @dev Example: VmCmd.safeTransfer(token, 0, 1);
    /// @param token ERC20 token contract address.
    /// @param toReg Register containing recipient address.
    /// @param amountReg Register containing transfer amount.
    /// @return VMCommand with packed SAFE_TRANSFER operation.
    function safeTransfer(address token, uint8 toReg, uint8 amountReg) internal pure returns (VMCommand memory) {
        return VMCommand({ op: OP.SAFE_TRANSFER, data: CommandPacking.packSafeTransfer(token, toReg, amountReg) });
    }
}
