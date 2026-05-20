// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ValidatorRegistry.sol";

/// @title DeployValidatorRegistry
/// @notice Deploy a fresh ValidatorRegistry on a single chain. Production
///         counterpart to DeployTestStack.s.sol — same contract, dedicated
///         script for clarity in operational runbooks.
///
///         Owner is the deployer key by default; pass VALIDATOR_REGISTRY_OWNER
///         to override (e.g. for a multisig owner with a separate deployer EOA).
///
/// Env inputs:
///   DEPLOYER_PRIVATE_KEY      - pays gas
///   VALIDATORS                - comma-separated EVM addresses of the initial
///                               validator set (must be non-empty, no dupes)
///   VALIDATOR_REGISTRY_OWNER  - optional; defaults to deployer address
///   QUORUM_BPS                - optional; defaults to 6666 (2-of-3 BFT)
///
/// Output (parseable):
///   VALIDATOR_REGISTRY=0x...
contract DeployValidatorRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("VALIDATOR_REGISTRY_OWNER", deployer);
        uint256 quorumBps = vm.envOr("QUORUM_BPS", uint256(6666));

        string memory validatorsStr = vm.envString("VALIDATORS");
        address[] memory validators = _parseAddresses(validatorsStr);

        require(validators.length > 0, "VALIDATORS list is empty");

        console.log("=== DeployValidatorRegistry ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer (pays gas):", deployer);
        console.log("Owner (registry admin):", owner);
        console.log("Quorum (bps):", quorumBps);
        console.log("Validator count:", validators.length);
        for (uint256 i = 0; i < validators.length; i++) {
            console.log("  validator", i, ":", validators[i]);
        }

        vm.startBroadcast(deployerKey);
        ValidatorRegistry registry = new ValidatorRegistry(owner, validators, quorumBps);
        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED ===");
        console.log("VALIDATOR_REGISTRY=%s", vm.toString(address(registry)));
        console.log("QUORUM_BPS=%s", vm.toString(quorumBps));
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        bytes memory data = bytes(csv);
        if (data.length == 0) return new address[](0);

        uint256 count = 1;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 start = 0;
        uint256 idx = 0;

        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = data[j];
                }
                result[idx] = vm.parseAddress(string(slice));
                idx++;
                start = i + 1;
            }
        }
        return result;
    }
}
