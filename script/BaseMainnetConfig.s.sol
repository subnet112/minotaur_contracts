// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {Settlement} from "../src/Settlement.sol";

/// @title Base Mainnet Settlement Configuration
/// @notice Configures the Settlement contract with common DEX routers for Base Mainnet
/// @dev Run with: forge script script/BaseMainnetConfig.s.sol:BaseMainnetConfig --rpc-url $BASE_RPC_URL --broadcast
contract BaseMainnetConfig is Script {
    // =============================================================================
    // Base Mainnet DEX Router Addresses
    // =============================================================================

    // Uniswap (deployed on Base)
    address constant UNISWAP_V3_SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNISWAP_V3_SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNISWAP_UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

    // SushiSwap V3 on Base
    address constant SUSHISWAP_V3_ROUTER = 0xFB7ef66A7e61224Dd6fcD0d7d9c3AE5C8455c371;

    // Aerodrome (Base native DEX - largest on Base)
    address constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_ROUTER_V2 = 0x6Cb442acF35158D5eDa88fe602221b67B400Be3E;

    // BaseSwap
    address constant BASESWAP_ROUTER = 0x327Df1E6de05895d2ab08513aaDD9313Fe505d86;

    // Balancer on Base
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // 1inch on Base
    address constant ONEINCH_AGGREGATION_ROUTER_V5 = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address constant ONEINCH_AGGREGATION_ROUTER_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;

    // 0x Protocol on Base
    address constant ZEROX_EXCHANGE_PROXY = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Paraswap on Base
    address constant PARASWAP_AUGUSTUS_V6 = 0x6A000F20005980200259B80c5102003040001068;

    // Odos on Base
    address constant ODOS_ROUTER_V2 = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

    // KyberSwap on Base
    address constant KYBER_META_AGGREGATION_ROUTER_V2 = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    // WooFi on Base
    address constant WOOFI_ROUTER = 0x4c4AF8DBc524681930a27b2F1Af5bcC8062E6fB7;

    /// @notice Configures the Settlement contract with DEX router allowlist
    function run() external {
        address settlementAddress = vm.envAddress("SETTLEMENT_ADDRESS");
        uint256 adminKey = vm.envUint("PRIVATE_KEY");

        Settlement settlement = Settlement(payable(settlementAddress));

        console.log("=== Base Mainnet Settlement Configuration ===");
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
        _addRouter(settlement, UNISWAP_UNIVERSAL_ROUTER, "Uniswap Universal Router");

        // Aerodrome (Base native - very important)
        _addRouter(settlement, AERODROME_ROUTER, "Aerodrome Router");
        _addRouter(settlement, AERODROME_ROUTER_V2, "Aerodrome Router V2");

        // SushiSwap
        _addRouter(settlement, SUSHISWAP_V3_ROUTER, "SushiSwap V3 Router");

        // BaseSwap
        _addRouter(settlement, BASESWAP_ROUTER, "BaseSwap Router");

        // Balancer
        _addRouter(settlement, BALANCER_VAULT, "Balancer Vault");

        // 1inch
        _addRouter(settlement, ONEINCH_AGGREGATION_ROUTER_V5, "1inch Aggregation Router V5");
        _addRouter(settlement, ONEINCH_AGGREGATION_ROUTER_V6, "1inch Aggregation Router V6");

        // 0x Protocol
        _addRouter(settlement, ZEROX_EXCHANGE_PROXY, "0x Exchange Proxy");

        // Paraswap
        _addRouter(settlement, PARASWAP_AUGUSTUS_V6, "Paraswap Augustus V6");

        // Odos
        _addRouter(settlement, ODOS_ROUTER_V2, "Odos Router V2");

        // KyberSwap
        _addRouter(settlement, KYBER_META_AGGREGATION_ROUTER_V2, "Kyber Meta Aggregation Router V2");

        // WooFi
        _addRouter(settlement, WOOFI_ROUTER, "WooFi Router");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Configuration Complete ===");
        console.log("Total routers added: 14");
    }

    function _addRouter(Settlement settlement, address router, string memory name) internal {
        settlement.setInteractionTarget(router, true);
        console.log("  +", name);
        console.log("   ", router);
    }
}

