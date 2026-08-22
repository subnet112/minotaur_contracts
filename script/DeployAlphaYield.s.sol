// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {AppIntentBaseV2} from "../src/AppIntentBaseV2.sol";
import {IMetagraph} from "../src/interfaces/IMetagraph.sol";

/// Deploy AlphaVault + AlphaYieldApp on Bittensor EVM (964).
///
/// THE CHICKEN AND EGG. AlphaVault's coldkey is blake2_256("evm:" ‖ its own
/// address), and CHAIN 964 DOES NOT PROVIDE blake2f: address 0x09, the BLAKE2b
/// compression function on a standard EVM, answers the EIP-152 test vector with
/// an elliptic-curve error here (sha256 at 0x02 works fine). Note the hash
/// itself is not the obstacle — one staticcall to a working blake2f would do it,
/// see test/Blake2Coldkey.t.sol — the chain's precompile set is. So the coldkey
/// must be supplied at construction, which means the vault's address must be
/// known BEFORE the vault exists. Hence two phases:
///
///   1. PHASE=predict — prints the address this deployer's next nonce will
///      produce. Feed it to `node tools/coldkey.mjs <address>`.
///   2. PHASE=deploy   — pass that coldkey as VAULT_COLDKEY. The script asserts
///      the vault actually landed on the predicted address; if the nonce moved
///      in between, the coldkey would be silently wrong and every purchase would
///      revert ColdkeyMismatch at first use rather than at deploy.
///
/// Env inputs:
///   PHASE              - "predict" or "deploy"
///   DEPLOYER_PRIVATE_KEY
///   VAULT_COLDKEY      - bytes32, from tools/coldkey.mjs (deploy phase only)
///   EXPECTED_VAULT     - the address PHASE 1 printed, i.e. the address the
///                        coldkey was derived from (deploy phase only)
///   GOVERNOR           - allowlist + fee admin
///   RELAYER            - the platform relayer
///   FEE_RECIPIENT, PERFORMANCE_FEE_BPS
///   NETUID, TOKEN_NAME, TOKEN_SYMBOL
///   MARKET_HOTKEYS - comma-separated bytes32, AT LEAST TWO. Index 0 becomes the
///                    live delegation. One candidate is not a deployable state:
///                    there is nothing to choose between, so the App declines to
///                    score it (NothingToOptimize) and the intent would sit idle
///                    until a second candidate cleared the 2-day timelock.
///   MARKET_UIDS    - comma-separated uints, same order and length
///   REBALANCE_COOLDOWN - seconds; the perpetual order must be signed with at
///                        least this, see PreflightAlphaYield
contract DeployAlphaYield is Script {
    IMetagraph constant METAGRAPH = IMetagraph(0x0000000000000000000000000000000000000802);

    address constant WTAO_964 = 0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81;
    address constant APP_REGISTRY_964 = 0x80758D3Bf11715c82dB9964C634d5Fd8a0C58aBF;
    address constant VALIDATOR_REGISTRY_964 = 0x0B5fE44e90515571761D86C28c4855F325EDE098;

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        string memory phase = vm.envOr("PHASE", string("predict"));

        if (keccak256(bytes(phase)) == keccak256("predict")) {
            _predict(deployer);
            return;
        }
        _deploy(key, deployer);
    }

    function _predict(address deployer) private view {
        uint64 nonce = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, nonce);
        console.log("=== PHASE 1: predict ===");
        console.log("deployer:", deployer);
        console.log("nonce:   ", nonce);
        console.log("vault will deploy to:", predicted);
        console.log("");
        console.log("Next: node tools/coldkey.mjs", vm.toString(predicted));
        console.log("Then re-run with PHASE=deploy, VAULT_COLDKEY set, and");
        console.log("EXPECTED_VAULT set to the address above.");
        console.log("");
        console.log("Send NO other transaction from this deployer in between. Every tx");
        console.log("moves the nonce, which moves the vault's address, which invalidates");
        console.log("the coldkey. Phase 2 refuses to deploy if that happened, so the");
        console.log("failure is loud, but a shared, actively-used key will hit it.");
    }

    function _deploy(uint256 key, address deployer) private {
        bytes32 coldkey = vm.envBytes32("VAULT_COLDKEY");
        require(coldkey != bytes32(0), "VAULT_COLDKEY unset");

        address governor = vm.envAddress("GOVERNOR");
        address relayer = vm.envAddress("RELAYER");
        uint256 netuid = vm.envUint("NETUID");
        bytes32[] memory hotkeys = vm.envBytes32("MARKET_HOTKEYS", ",");
        uint256[] memory uids = vm.envUint("MARKET_UIDS", ",");
        require(hotkeys.length == uids.length, "MARKET_HOTKEYS/MARKET_UIDS length mismatch");
        require(hotkeys.length >= 2, "need at least TWO candidates; one is unscoreable");

        // Prove every pairing BEFORE spending gas: openMarket would revert on it
        // anyway, but failing here costs nothing and says which one is wrong.
        for (uint256 i = 0; i < hotkeys.length; ++i) {
            require(
                METAGRAPH.getHotkey(uint16(netuid), uint16(uids[i])) == hotkeys[i],
                "a MARKET_UID does not map to its MARKET_HOTKEY on the metagraph"
            );
        }

        // The check that actually matters, and it has to be against PHASE 1's
        // address, not against a freshly-read nonce. Comparing the deployed
        // address to computeCreateAddress(deployer, currentNonce) is a tautology
        // — both use the same nonce, so it can never fail and proves nothing.
        // The coldkey was derived from ONE specific address; assert we are still
        // going to land on it, BEFORE spending any gas.
        address expected = vm.envAddress("EXPECTED_VAULT");
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        require(
            predicted == expected,
            "nonce moved since PHASE 1: the vault would land elsewhere and the coldkey would be wrong. Re-run PHASE=predict."
        );

        vm.startBroadcast(key);

        // Deployer holds governance during setup, then hands it over.
        AlphaVault vault = new AlphaVault(coldkey, deployer);
        require(address(vault) == expected, "vault did not land on the expected address");

        AlphaYieldApp app = new AlphaYieldApp(
            address(vault),
            relayer,
            VALIDATOR_REGISTRY_964,
            vm.envOr("SCORE_THRESHOLD", uint256(5000)),
            WTAO_964,
            vm.envOr("FEE_COLLECTOR", address(0)),
            0,
            0,
            AppIntentBaseV2.FeeMode.APP,
            address(0),
            APP_REGISTRY_964
        );

        AlphaVault.Candidate[] memory initial = new AlphaVault.Candidate[](hotkeys.length);
        for (uint256 i = 0; i < hotkeys.length; ++i) {
            initial[i] = AlphaVault.Candidate({hotkey: hotkeys[i], uid: uint16(uids[i])});
        }
        vault.openMarket(
            netuid, initial,
            vm.envOr("TOKEN_NAME", string("Wrapped Alpha")),
            vm.envOr("TOKEN_SYMBOL", string("wAlpha"))
        );

        vault.setOptimizer(address(app));
        vault.setRebalanceCooldown(vm.envOr("REBALANCE_COOLDOWN", uint256(6 hours)));
        vault.setPerformanceFee(
            vm.envOr("FEE_RECIPIENT", address(0)),
            vm.envOr("PERFORMANCE_FEE_BPS", uint256(1000))
        );
        vault.setGovernor(governor);

        vm.stopBroadcast();

        console.log("=== PHASE 2: deployed ===");
        console.log("AlphaVault:   ", address(vault));
        console.log("AlphaYieldApp:", address(app));
        console.log("coldkey:      ", vm.toString(coldkey));
        console.log("");
        console.log("STILL REQUIRED before this App can execute anything:");
        console.log("  1. Register it:  APP_CONTRACT=%s forge script script/RegisterApp.s.sol", address(app));
        console.log("     Until then scoreIntent SCORES FINE and executeIntent reverts.");
        console.log("  2. Verify the coldkey: node tools/coldkey.mjs %s %s",
            vm.toString(address(vault)), vm.toString(coldkey));
        console.log("  3. Run the gate: VAULT=%s APP=%s forge script script/PreflightAlphaYield.s.sol",
            address(vault), address(app));
    }
}
