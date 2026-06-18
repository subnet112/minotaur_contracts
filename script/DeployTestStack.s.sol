// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ValidatorRegistry.sol";
import {ChampionRegistry} from "../src/ChampionRegistry.sol";

/// @title DeployTestStack - Deploys infrastructure for the local testnet
/// @notice Only deploys ValidatorRegistry. App contracts are deployed through
///         the Minotaur pipeline (create_app_intent → deploy_app_intent).
///         Outputs KEY=VALUE lines for Python parsing.
///
///         Env:
///           DEPLOYER_PRIVATE_KEY (required)
///           VALIDATORS           (comma-separated addresses)
///           QUORUM_BPS           (optional, defaults to 6666 = 2-of-3 BFT)
contract DeployTestStack is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address relayer = vm.addr(deployerKey);

        // Parse validator addresses from env
        string memory validatorsStr = vm.envString("VALIDATORS");
        address[] memory validators = _parseAddresses(validatorsStr);

        uint256 quorumBps = vm.envOr("QUORUM_BPS", uint256(6666));

        vm.startBroadcast(deployerKey);

        // Deploy ValidatorRegistry (holds validator set + canonical quorumBps)
        ValidatorRegistry registry = new ValidatorRegistry(relayer, validators, quorumBps);

        // Deploy ChampionRegistry (delegates the validator set to the
        // ValidatorRegistry above; keeps its own quorumBps for champion
        // certification). This lets the testnet exercise the champion
        // consensus path with a real on-chain registry instead of relying on
        // a silent fallback to ValidatorRegistry.
        ChampionRegistry championRegistry = new ChampionRegistry(address(registry), quorumBps, relayer);

        vm.stopBroadcast();

        // Output for Python parsing
        console.log("REGISTRY_ADDRESS=%s", vm.toString(address(registry)));
        console.log("CHAMPION_REGISTRY_ADDRESS=%s", vm.toString(address(championRegistry)));
        console.log("RELAYER_ADDRESS=%s", vm.toString(relayer));
        console.log("QUORUM_BPS=%s", vm.toString(quorumBps));
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        bytes memory data = bytes(csv);
        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 start = 0;
        uint256 idx = 0;

        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory addrBytes = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    addrBytes[j - start] = data[j];
                }
                result[idx] = vm.parseAddress(string(addrBytes));
                idx++;
                start = i + 1;
            }
        }

        return result;
    }
}
