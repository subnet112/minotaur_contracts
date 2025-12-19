// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {Settlement} from "../src/Settlement.sol";

/// @title Settlement post-deployment configuration script
/// @notice Updates relayer restrictions and interaction allowlist settings
/// @dev Requires `PRIVATE_KEY` for the owner/admin and `SETTLEMENT_ADDRESS`
contract SettlementConfig is Script {
    /// @notice Applies configuration toggles based on environment variables
    function run() external {
        address settlementAddress = vm.envAddress("SETTLEMENT_ADDRESS");
        uint256 adminKey = vm.envUint("PRIVATE_KEY");

        bool relayerRestrictionFlag = vm.envOr("SET_RELAYER_RESTRICTION", false);
        bool allowlistFlag = vm.envOr("SET_ALLOWLIST_ENABLED", false);
        address relayer = vm.envOr("TRUSTED_RELAYER", address(0));
        bool relayerAllowed = vm.envOr("TRUSTED_RELAYER_ALLOWED", true);
        address target = vm.envOr("INTERACTION_TARGET", address(0));
        bool targetAllowed = vm.envOr("INTERACTION_TARGET_ALLOWED", true);
        bool updateFeeParameters = vm.envOr("UPDATE_FEE_PARAMETERS", false);
        address feeRecipientEnv = vm.envOr("FEE_RECIPIENT", address(0));
        uint256 feeBpsEnv = vm.envOr("FEE_BPS", uint256(0));

        Settlement settlement = Settlement(payable(settlementAddress));

        vm.startBroadcast(adminKey);

        if (vm.envOr("UPDATE_RELAYER_RESTRICTION", false)) {
            settlement.setRelayerRestriction(relayerRestrictionFlag);
        }

        if (vm.envOr("UPDATE_ALLOWLIST_STATUS", false)) {
            settlement.setAllowlistEnabled(allowlistFlag);
        }

        if (relayer != address(0)) {
            settlement.setTrustedRelayer(relayer, relayerAllowed);
        }

        if (target != address(0)) {
            settlement.setInteractionTarget(target, targetAllowed);
        }

        if (updateFeeParameters) {
            settlement.setFeeParameters(feeRecipientEnv, feeBpsEnv);
        }

        vm.stopBroadcast();
    }
}
