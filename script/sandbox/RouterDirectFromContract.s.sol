// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract SimpleCaller {
    function pullAndSwap(
        address tokenIn,
        address router,
        bytes calldata data,
        address from,
        uint256 amount
    ) external {
        IERC20(tokenIn).transferFrom(from, address(this), amount);
        IERC20(tokenIn).approve(router, type(uint256).max);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            fee: 500,
            recipient: from,
            deadline: block.timestamp + 1 days,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory encoded = abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, params);
        console2.logBytes(encoded);

        uint256 amountOut = ISwapRouter(router).exactInputSingle(params);
        console2.log("interface call amountOut", amountOut);
    }
}

contract RouterDirectFromContract is Script, StdCheats {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
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

        address user = vm.addr(uint256(keccak256("sim-user")));
        deal(USDC, user, AMOUNT_IN, true);

        SimpleCaller caller = new SimpleCaller();

        vm.startPrank(user);
        IERC20(USDC).approve(address(caller), type(uint256).max);
        vm.stopPrank();

        bytes memory data = hex"04e45aaf000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000001f40000000000000000000000009996e4253e938d81a360b353c4fcefa67e7120bc00000000000000000000000000000000000000000000000000000000f4865700000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        try caller.pullAndSwap(USDC, ROUTER, data, user, AMOUNT_IN) {
            console2.log("Contract-based swap succeeded");
        } catch (bytes memory revertData) {
            console2.log("Contract-based swap reverted");
            console2.logBytes(revertData);
        }
    }
}
