// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {Settlement} from "src/Settlement.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract SettlementExecuteSandbox is Script, StdCheats {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint256 internal constant AMOUNT_IN = 1_000_000_000;

    bytes32 internal constant QUOTE_ID = bytes32("QUOTE_USDC_WETH");

    function run() external {
        string memory forkUrl = vm.envOr("SIM_FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            string memory infuraKey = vm.envOr("INFURA_API_KEY", string(""));
            require(bytes(infuraKey).length != 0, "INFURA_API_KEY required");
            forkUrl = string.concat("https://mainnet.infura.io/v3/", infuraKey);
        }
        vm.createSelectFork(forkUrl, 23_746_829);

        address owner = vm.addr(uint256(keccak256("settlement-owner")));
        address user = vm.addr(uint256(keccak256("sim-user")));
        address relayer = vm.addr(uint256(keccak256("sim-relayer")));

        Settlement settlement = new Settlement(owner);

        deal(USDC, user, AMOUNT_IN, true);
        console2.log("User balance", IERC20(USDC).balanceOf(user));

        vm.prank(user);
        IERC20(USDC).approve(address(settlement), type(uint256).max);

        Settlement.Interaction[] memory empty;
        Settlement.Interaction[] memory pre = new Settlement.Interaction[](1);
        pre[0] = Settlement.Interaction({
            target: USDC,
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, ROUTER, type(uint256).max)
        });

        Settlement.Interaction[] memory main = new Settlement.Interaction[](1);
        main[0] = Settlement.Interaction({
            target: ROUTER,
            value: 0,
            callData: hex"04e45aaf000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000001f40000000000000000000000009996e4253e938d81a360b353c4fcefa67e7120bc00000000000000000000000000000000000000000000000000000000f4865700000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        });

        Settlement.ExecutionPlan memory plan = Settlement.ExecutionPlan({
            preInteractions: pre,
            interactions: main,
            postInteractions: empty
        });

        Settlement.PermitData memory permit;
        permit.permitType = Settlement.PermitType.StandardApproval;
        permit.amount = AMOUNT_IN;

        Settlement.OrderIntent memory intent = Settlement.OrderIntent({
            quoteId: QUOTE_ID,
            user: user,
            tokenIn: IERC20(USDC),
            tokenOut: IERC20(WETH),
            amountIn: AMOUNT_IN,
            minAmountOut: 0,
            receiver: user,
            deadline: 4_102_444_800,
            nonce: 1,
            permit: permit,
            interactionsHash: settlement.hashExecutionPlan(plan),
            callValue: 0,
            gasEstimate: 450_000,
            userSignature: bytes("")
        });

        bytes32 structHash = settlement.hashExecutionPlan(plan);
        console2.logBytes32(structHash);
        intent.interactionsHash = structHash;

        bytes32 digest = settlement.domainSeparator();
        digest = keccak256(abi.encodePacked("\x19\x01", digest, settlement.hashOrderIntent(intent)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("sim-user")), digest);
        intent.userSignature = abi.encodePacked(r, s, v);

        vm.startPrank(relayer);
        try settlement.executeOrder(intent, plan) returns (uint256 amountOut) {
            console2.log("Settlement swap amountOut", amountOut);
        } catch (bytes memory revertData) {
            console2.log("Settlement executeOrder reverted");
            console2.logBytes(revertData);
        }
        vm.stopPrank();
    }
}
