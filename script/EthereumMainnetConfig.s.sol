// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {Settlement} from "../src/Settlement.sol";

/// @title Ethereum Mainnet Settlement Configuration
/// @notice Configures the Settlement contract with common DEX routers for Ethereum Mainnet
/// @dev Run with: forge script script/EthereumMainnetConfig.s.sol:EthereumMainnetConfig --rpc-url $MAINNET_RPC_URL --broadcast
contract EthereumMainnetConfig is Script {
    // =============================================================================
    // Ethereum Mainnet DEX Router Addresses
    // =============================================================================

    // Uniswap
    address constant UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant UNISWAP_UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // SushiSwap
    address constant SUSHISWAP_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    // 1inch
    address constant ONEINCH_AGGREGATION_ROUTER_V5 = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address constant ONEINCH_AGGREGATION_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Curve
    address constant CURVE_ROUTER = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address constant CURVE_ROUTER_NG = 0xF0d4c12A5768D806021F80a262B4d39d26C58b8D;

    // Balancer
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // 0x Protocol
    address constant ZEROX_EXCHANGE_PROXY = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Paraswap
    address constant PARASWAP_AUGUSTUS_V6 = 0x6A000F20005980200259B80c5102003040001068;
    address constant PARASWAP_AUGUSTUS_V5 = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;

    // CoW Protocol
    address constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    // Kyber
    address constant KYBER_META_AGGREGATION_ROUTER_V2 = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    /// @notice Configures the Settlement contract with DEX router allowlist
    function run() external {
        address settlementAddress = vm.envAddress("SETTLEMENT_ADDRESS");
        uint256 adminKey = vm.envUint("PRIVATE_KEY");

        Settlement settlement = Settlement(payable(settlementAddress));

        console.log("=== Ethereum Mainnet Settlement Configuration ===");
        console.log("Settlement Address:", settlementAddress);
        console.log("");

        vm.startBroadcast(adminKey);

        // Enable allowlist
        console.log("Enabling interaction allowlist...");
        settlement.setAllowlistEnabled(true);

        // Add all DEX routers to allowlist
        console.log("Adding DEX routers to allowlist...");

        // Uniswap
        _addRouter(settlement, UNISWAP_V3_SWAP_ROUTER, "Uniswap V3 SwapRouter");
        _addRouter(settlement, UNISWAP_V3_SWAP_ROUTER_02, "Uniswap V3 SwapRouter02");
        _addRouter(settlement, UNISWAP_UNIVERSAL_ROUTER, "Uniswap Universal Router");
        _addRouter(settlement, UNISWAP_V2_ROUTER, "Uniswap V2 Router");

        // SushiSwap
        _addRouter(settlement, SUSHISWAP_ROUTER, "SushiSwap Router");

        // 1inch
        _addRouter(settlement, ONEINCH_AGGREGATION_ROUTER_V5, "1inch Aggregation Router V5");
        _addRouter(settlement, ONEINCH_AGGREGATION_ROUTER_V6, "1inch Aggregation Router V6");

        // Curve
        _addRouter(settlement, CURVE_ROUTER, "Curve Router");
        _addRouter(settlement, CURVE_ROUTER_NG, "Curve Router NG");

        // Balancer
        _addRouter(settlement, BALANCER_VAULT, "Balancer Vault");

        // 0x Protocol
        _addRouter(settlement, ZEROX_EXCHANGE_PROXY, "0x Exchange Proxy");

        // Paraswap
        _addRouter(settlement, PARASWAP_AUGUSTUS_V5, "Paraswap Augustus V5");
        _addRouter(settlement, PARASWAP_AUGUSTUS_V6, "Paraswap Augustus V6");

        // CoW Protocol
        _addRouter(settlement, COW_SETTLEMENT, "CoW Protocol Settlement");

        // Kyber
        _addRouter(settlement, KYBER_META_AGGREGATION_ROUTER_V2, "Kyber Meta Aggregation Router V2");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Configuration Complete ===");
        console.log("Total routers added: 15");
    }

    function _addRouter(Settlement settlement, address router, string memory name) internal {
        settlement.setInteractionTarget(router, true);
        console.log("  +", name);
        console.log("   ", router);
    }
}

