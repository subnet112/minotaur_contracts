// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AppRegistry.sol";

/// @title RegisterApp
/// @notice Register a deployed App contract in the AppRegistry. The caller
///         must be the developer that the contract was deployed under
///         (i.e. on the allowlist while mode == GATED; anyone while mode ==
///         OPEN). The recorded developer address is the only party that may
///         later update the manifest hash.
///
/// Env inputs:
///   DEVELOPER_PRIVATE_KEY - allowlisted developer key
///   APP_REGISTRY          - address of the deployed AppRegistry
///   APP_ID                - bytes32 (hex, with or without 0x prefix)
///   MANIFEST_HASH         - bytes32 sha256 of the JS scoring bundle
///   APP_CONTRACT          - the deployed App contract address on this chain
contract RegisterApp is Script {
    function run() external {
        uint256 devKey = vm.envUint("DEVELOPER_PRIVATE_KEY");
        address registryAddr = vm.envAddress("APP_REGISTRY");
        bytes32 appId = vm.envBytes32("APP_ID");
        bytes32 manifestHash = vm.envBytes32("MANIFEST_HASH");
        address appContract = vm.envAddress("APP_CONTRACT");

        AppRegistry registry = AppRegistry(registryAddr);
        address developer = vm.addr(devKey);

        console.log("=== RegisterApp ===");
        console.log("Registry:", registryAddr);
        console.log("Developer (caller):", developer);
        console.log("App ID:", vm.toString(appId));
        console.log("Manifest hash:", vm.toString(manifestHash));
        console.log("App contract:", appContract);
        console.log("Registry mode:", uint8(registry.mode()) == 0 ? "GATED" : "OPEN");

        require(!registry.isRegistered(appId), "App ID already registered");
        require(registry.appByContract(appContract) == bytes32(0), "Contract already mapped");

        vm.startBroadcast(devKey);
        registry.registerApp(appId, manifestHash, appContract);
        vm.stopBroadcast();

        console.log("");
        console.log("=== REGISTERED ===");
        console.log("isRegistered:", registry.isRegistered(appId));
    }
}
