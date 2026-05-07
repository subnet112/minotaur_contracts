// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ValidatorRegistry.sol";

/// @title DeployTestStack - Deploys infrastructure for the local testnet
/// @notice Only deploys ValidatorRegistry. App contracts are deployed through
///         the Minotaur pipeline (create_app_intent → deploy_app_intent).
///         Outputs KEY=VALUE lines for Python parsing.
contract DeployTestStack is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address relayer = vm.addr(deployerKey);

        // Parse validator addresses from env
        string memory validatorsStr = vm.envString("VALIDATORS");
        address[] memory validators = _parseAddresses(validatorsStr);

        vm.startBroadcast(deployerKey);

        // Deploy ValidatorRegistry (needed by all app contracts)
        ValidatorRegistry registry = new ValidatorRegistry(relayer, validators);

        vm.stopBroadcast();

        // Output for Python parsing
        console.log("REGISTRY_ADDRESS=%s", vm.toString(address(registry)));
        console.log("RELAYER_ADDRESS=%s", vm.toString(relayer));
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
