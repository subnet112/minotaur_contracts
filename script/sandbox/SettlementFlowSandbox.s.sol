// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract SettlementFlowSandbox is Script, StdCheats {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint256 internal constant AMOUNT_IN = 1_000_000_000;

    function run() external {
        string memory forkUrl = vm.envOr("SIM_FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            string memory infuraKey = vm.envOr("INFURA_API_KEY", string(""));
            require(bytes(infuraKey).length != 0, "INFURA_API_KEY required");
            forkUrl = string.concat("https://mainnet.infura.io/v3/", infuraKey);
        }
        vm.createSelectFork(forkUrl, 23_746_829);

        address user = address(0x1234);
        address settlement = address(0xdeadbeef);

        deal(USDC, user, AMOUNT_IN, true);
        console2.log("User balance after deal", IERC20(USDC).balanceOf(user));

        vm.prank(user);
        IERC20(USDC).approve(settlement, type(uint256).max);

        vm.startPrank(settlement);
        IERC20(USDC).transferFrom(user, settlement, AMOUNT_IN);
        console2.log("Settlement balance after collect", IERC20(USDC).balanceOf(settlement));
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        console2.log("Allowance to router", IERC20(USDC).allowance(settlement, ROUTER));
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: 500,
            recipient: user,
            deadline: block.timestamp + 1 days,
            amountIn: AMOUNT_IN,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try ISwapRouter(ROUTER).exactInputSingle(params) returns (uint256 amountOut) {
            console2.log("Swap ok", amountOut);
        } catch (bytes memory revertData) {
            console2.log("Swap revert");
            console2.logBytes(revertData);
        }
        vm.stopPrank();

        console2.log("Final settlement WETH", IERC20(WETH).balanceOf(settlement));
    }
}
