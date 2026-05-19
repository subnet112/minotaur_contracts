// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AppRegistry.sol";

/// @title SetupAppRegistry
/// @notice Post-deploy admin call to allowlist a developer address. Must be
///         broadcast with the registry owner's key. Idempotent — re-running
///         is a no-op (the contract's setDeveloperAllowed checks the current
///         state before emitting).
///
/// Env inputs:
///   OWNER_PRIVATE_KEY     - private key matching AppRegistry.owner()
///   APP_REGISTRY          - address of the deployed AppRegistry
///   DEVELOPER_TO_ALLOW    - address to add (or remove) from the allowlist
///   ALLOW                 - "true" to allow, "false" to revoke (default true)
contract SetupAppRegistry is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("OWNER_PRIVATE_KEY");
        address registryAddr = vm.envAddress("APP_REGISTRY");
        address developer = vm.envAddress("DEVELOPER_TO_ALLOW");
        bool allow = vm.envOr("ALLOW", true);

        AppRegistry registry = AppRegistry(registryAddr);
        address owner = vm.addr(ownerKey);

        console.log("=== SetupAppRegistry ===");
        console.log("Registry:", registryAddr);
        console.log("Owner (caller):", owner);
        console.log("On-chain owner:", registry.owner());
        console.log("Developer:", developer);
        console.log("Action:", allow ? "ALLOW" : "REVOKE");

        require(registry.owner() == owner, "Caller is not registry owner");

        vm.startBroadcast(ownerKey);
        registry.setDeveloperAllowed(developer, allow);
        vm.stopBroadcast();

        console.log("");
        console.log("=== DONE ===");
        console.log("allowedDevelopers[%s] = %s", vm.toString(developer), allow ? "true" : "false");
    }
}
