// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISwapRouter - Minimal Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// @title UniswapForwarder - Wraps Uniswap V3 swaps for EphemeralProxy
/// @notice Holds input tokens in its own reserves and calls Uniswap V3 Router.
///         The EphemeralProxy calls executeSwap() — selector NOT blacklisted.
///         Pre-fund this contract with tokens via whale impersonation on the fork.
contract UniswapForwarder {
    ISwapRouter public immutable router;

    constructor(address _router) {
        require(_router != address(0), "Invalid router");
        router = ISwapRouter(_router);
    }

    /// @notice Execute a swap through Uniswap V3
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Amount of input token to swap
    /// @param amountOutMin Minimum output (slippage protection)
    /// @param recipient Address to receive output tokens
    /// @param fee Pool fee tier (e.g. 3000 = 0.3%)
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 fee
    ) external returns (uint256 amountOut) {
        require(
            IERC20(tokenIn).balanceOf(address(this)) >= amountIn,
            "Forwarder: insufficient reserves"
        );

        IERC20(tokenIn).approve(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Accept ETH (needed for WETH deposit)
    receive() external payable {}
}
