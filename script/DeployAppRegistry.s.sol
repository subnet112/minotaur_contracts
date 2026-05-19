// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AppRegistry.sol";

/// @title DeployAppRegistry
/// @notice Deploy the AppRegistry on a single chain. Mode starts at GATED;
///         the deployer must call setDeveloperAllowed before any apps can
///         register (see SetupAppRegistry.s.sol).
///
/// Env inputs:
///   DEPLOYER_PRIVATE_KEY  - the key that pays gas. Need not be the owner.
///   APP_REGISTRY_OWNER    - address that holds setMode / setDeveloperAllowed
///                           / revokeApp / renounceOwnership. Should normally
///                           be a multisig; passing the deployer's own address
///                           is fine for rehearsal / testnet.
///
/// Output (parseable):
///   APP_REGISTRY=0x...
contract DeployAppRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("APP_REGISTRY_OWNER");

        require(owner != address(0), "APP_REGISTRY_OWNER unset");

        address deployer = vm.addr(deployerKey);

        console.log("=== DeployAppRegistry ===");
        console.log("Deployer (pays gas):", deployer);
        console.log("Owner (registry admin):", owner);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);
        AppRegistry registry = new AppRegistry(owner);
        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED ===");
        console.log("APP_REGISTRY=%s", vm.toString(address(registry)));
        console.log("Mode: GATED (default - call setDeveloperAllowed before any registerApp)");
    }
}
