// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IAppIntentBase.sol";

/// @title EphemeralProxy - Disposable proxy for intent execution
/// @notice Deployed per-execution via CREATE2 (salt = keccak256(orderId, executionCount)).
///         Executes the plan's calls from its own address context.
///         Token approvals land on this disposable address (worthless after execution).
contract EphemeralProxy {
    error CallFailed(uint256 index, bytes reason);

    /// @notice Execute an array of calls and self-destruct
    /// @param calls The calls to execute in order
    function execute(IAppIntentBase.Call[] calldata calls) external payable {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call{value: calls[i].value}(
                calls[i].callData
            );
            if (!success) {
                revert CallFailed(i, result);
            }
        }

        // Return any remaining ETH to the caller (AppIntentBase)
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool sent,) = msg.sender.call{value: remaining}("");
            require(sent, "ETH return failed");
        }
    }

    /// @notice Accept ETH transfers
    receive() external payable {}
}
