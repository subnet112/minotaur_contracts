// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IAppIntentBase.sol";

/// @title ExecutorProxy - Cloneable ephemeral plan executor (V2)
/// @notice V1 deploys the full EphemeralProxy bytecode per execution
///         (~165k gas: 32k CREATE2 + 659 bytes of code deposit). V2 deploys
///         this implementation ONCE (in the app's constructor) and spins up a
///         55-byte EIP-1167 clone of it per order (~45k gas).
///
///         Security model is V1's, deliberately: every order executes on a
///         FRESH address that is never funded again, so any approvals or
///         other state a plan leaves behind are structurally worthless —
///         no validator diligence required for approval hygiene. Two strict
///         improvements over V1's proxy:
///         - `execute` is gated to the deploying app (V1's was permissionless,
///           which made leftover dust publicly sweepable).
///         - The gate rides an immutable, which clones share via delegatecall,
///           so it costs no storage.
contract ExecutorProxy {
    error CallFailed(uint256 index, bytes reason);

    /// @notice The AppIntentBaseV2 contract that deployed this implementation.
    ///         Immutables live in the implementation's code, so every clone
    ///         enforces the same gate.
    address public immutable app;

    constructor() {
        app = msg.sender;
    }

    /// @notice Execute an array of calls in order. App-only.
    function execute(IAppIntentBase.Call[] calldata calls) external payable {
        require(msg.sender == app, "Only app");
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call{value: calls[i].value}(
                calls[i].callData
            );
            if (!success) {
                revert CallFailed(i, result);
            }
        }

        // Return any remaining ETH to the app
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool sent,) = msg.sender.call{value: remaining}("");
            require(sent, "ETH return failed");
        }
    }

    /// @notice Accept ETH transfers
    receive() external payable {}
}
