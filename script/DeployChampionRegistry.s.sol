// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ChampionRegistry.sol";

/// @title DeployChampionRegistry
/// @notice Deploy the ChampionRegistry to BT EVM (chain 964) for on-chain
///         champion attestation. References the existing ValidatorRegistry.
///
/// Env inputs:
///   DEPLOYER_PRIVATE_KEY   - relayer key that pays TAO gas
///   VALIDATOR_REGISTRY     - existing ValidatorRegistry address on BT EVM
///   CHAMPION_QUORUM_BPS    - defaults to 6666 (2-of-3)
contract DeployChampionRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address validatorRegistry = vm.envAddress("VALIDATOR_REGISTRY");
        uint256 quorumBps = vm.envOr("CHAMPION_QUORUM_BPS", uint256(6666));

        address deployer = vm.addr(deployerKey);

        console.log("=== DeployChampionRegistry ===");
        console.log("Deployer:", deployer);
        console.log("ValidatorRegistry:", validatorRegistry);
        console.log("QuorumBps:", quorumBps);

        vm.startBroadcast(deployerKey);

        ChampionRegistry registry = new ChampionRegistry(
            validatorRegistry,
            quorumBps,
            deployer
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED ===");
        console.log("ChampionRegistry:", address(registry));
    }
}
