// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/// @notice Minimal script to sanity-check direct swaps against Uniswap V3 at a pinned block
contract UniswapSwapSmoke is Script, StdCheats {
    uint256 internal constant FORK_BLOCK = 23_746_829;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint256 internal constant AMOUNT_IN = 1_000_000_000; // 1,000 USDC (6 decimals)

    function run() external {
        string memory forkUrl = vm.envOr("SIM_FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            string memory infuraKey = vm.envOr("INFURA_API_KEY", string(""));
            require(bytes(infuraKey).length != 0, "SIM_FORK_URL or INFURA_API_KEY required");
            forkUrl = string.concat("https://mainnet.infura.io/v3/", infuraKey);
        }

        if (FORK_BLOCK != 0) {
            vm.createSelectFork(forkUrl, FORK_BLOCK);
        } else {
            vm.createSelectFork(forkUrl);
        }

        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(SWAP_ROUTER, "UniswapV3SwapRouter");

        uint256 userKey = uint256(keccak256("swap-smoke-user"));
        address user = vm.addr(userKey);
        vm.label(user, "SwapSmokeUser");

        vm.deal(user, 1 ether);
        deal(USDC, user, AMOUNT_IN, true);

        vm.startBroadcast(userKey);

        IERC20(USDC).approve(SWAP_ROUTER, AMOUNT_IN);

        uint256 deadline = block.timestamp + 1 days;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: 500,
            recipient: user,
            deadline: deadline,
            amountIn: AMOUNT_IN,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        try ISwapRouter(SWAP_ROUTER).exactInputSingle(params) returns (uint256 amountOut) {
            console2.log("Swap succeeded amountOut", amountOut);
            console2.log("Used deadline", deadline);
        } catch (bytes memory revertData) {
            console2.log("Swap reverted with data:");
            console2.logBytes(revertData);
            vm.stopBroadcast();
            revert("Uniswap swap failed in smoke script");
        }

        vm.stopBroadcast();

        console2.log("Final WETH balance", IERC20(WETH).balanceOf(user));
    }
}


