// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestSwapRouter - Simplified router for E2E testing
/// @notice Sends output tokens from its own reserves via transfer().
///         Fund this router with output tokens before testing.
contract TestSwapRouter {
    /// @notice Execute a swap by sending output tokens to recipient
    /// @param outputToken Token to send
    /// @param outputAmount Amount to send
    /// @param recipient Address to receive tokens
    function swapExact(
        address outputToken,
        uint256 outputAmount,
        address recipient
    ) external {
        require(
            IERC20(outputToken).balanceOf(address(this)) >= outputAmount,
            "Router: insufficient reserves"
        );
        IERC20(outputToken).transfer(recipient, outputAmount);
    }
}
