// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {Settlement} from "../src/Settlement.sol";

/// @title Settlement deployment script
/// @notice Deploys a new `Settlement` instance using environment-provided credentials
/// @dev Expects `PRIVATE_KEY` (hex string without 0x) and optional `SETTLEMENT_OWNER`
contract SettlementDeploy is Script {
    /// @notice Broadcasts a transaction that deploys the settlement contract
    /// @return deployed Address of the newly deployed settlement contract
    function run() external returns (Settlement deployed) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("SETTLEMENT_OWNER", address(0));

        address deployer = vm.addr(deployerKey);
        if (owner == address(0)) {
            owner = deployer;
        }

        vm.startBroadcast(deployerKey);
        deployed = new Settlement(owner);
        vm.stopBroadcast();
    }
}
