// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MockRouter - Simulates a DEX router for testing
/// @notice Swaps tokens at a fixed 1:1800 rate (simulating ETH/USDC)
contract MockRouter {
    uint256 public rate = 1800; // 1 WETH = 1800 USDC (6 decimal vs 18 decimal)

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    /// @notice Simple swap: take inputToken, give outputToken at fixed rate
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 minOutput,
        address recipient
    ) external returns (uint256 outputAmount) {
        // Pull input tokens
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);

        // Calculate output (simplified)
        uint8 inputDecimals = _getDecimals(inputToken);
        uint8 outputDecimals = _getDecimals(outputToken);

        if (inputDecimals >= outputDecimals) {
            outputAmount = (inputAmount * rate) / (10 ** (inputDecimals - outputDecimals));
        } else {
            outputAmount = (inputAmount * rate) * (10 ** (outputDecimals - inputDecimals));
        }

        require(outputAmount >= minOutput, "Insufficient output");

        // Send output tokens
        IERC20(outputToken).transfer(recipient, outputAmount);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
