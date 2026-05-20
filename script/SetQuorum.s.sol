// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ValidatorRegistry.sol";

/// @title SetQuorum - Reconfigure the network-wide quorumBps on a chain
/// @notice Calls ValidatorRegistry.setQuorumBps(...) as the registry owner.
///         A single owner tx propagates to every AppIntentBase on this chain;
///         off-chain validators pick up the new value within one
///         ProtocolConfig refresh interval (default ~60s).
///
///         Env:
///           REGISTRY_OWNER_PRIVATE_KEY  (required) owner of the ValidatorRegistry
///           VALIDATOR_REGISTRY          (required) registry address
///           QUORUM_BPS                  (required) new threshold in basis points
contract SetQuorum is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("REGISTRY_OWNER_PRIVATE_KEY");
        address registryAddr = vm.envAddress("VALIDATOR_REGISTRY");
        uint256 newQuorumBps = vm.envUint("QUORUM_BPS");

        ValidatorRegistry registry = ValidatorRegistry(registryAddr);
        uint256 oldQuorumBps = registry.quorumBps();

        console.log("Registry:", registryAddr);
        console.log("Old quorumBps:", oldQuorumBps);
        console.log("New quorumBps:", newQuorumBps);

        vm.startBroadcast(ownerKey);
        registry.setQuorumBps(newQuorumBps);
        vm.stopBroadcast();

        // Sanity-check the change
        uint256 actual = registry.quorumBps();
        require(actual == newQuorumBps, "setQuorumBps did not take effect");
        console.log("Updated. New value confirmed on-chain:", actual);
    }
}
