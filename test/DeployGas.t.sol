// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {AppIntentBaseV2} from "../src/AppIntentBaseV2.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";
import {MockMetagraph} from "./mocks/MockMetagraph.sol";

/// What the full deploy costs, so it can be checked against a real balance
/// instead of guessed at.
contract DeployGasTest is Test {
    bytes32 constant HK_A = bytes32(uint256(0xAA));
    bytes32 constant HK_B = bytes32(uint256(0xBB));

    function test_measure_full_deploy() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        MockMetagraph meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 35000, true);

        uint256 total;
        uint256 g = gasleft();
        AlphaVault vault = new AlphaVault(bytes32(uint256(0xC01D)), address(this));
        uint256 gVault = g - gasleft(); total += gVault;

        g = gasleft();
        AlphaYieldApp app = new AlphaYieldApp(
            address(vault), address(0xC0FFEE), address(0x9E61), 5000,
            address(0xA7A0), address(0), 0, 0, AppIntentBaseV2.FeeMode.APP, address(0), address(0)
        );
        uint256 gApp = g - gasleft(); total += gApp;

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});
        g = gasleft();
        vault.openMarket(112, cs, "Wrapped SN112 Alpha", "wAlpha112");
        uint256 gMarket = g - gasleft(); total += gMarket;

        g = gasleft();
        vault.setOptimizer(address(app));
        vault.setRebalanceCooldown(6 hours);
        vault.setPerformanceFee(address(0xFEE5), 1000);
        vault.setGovernor(address(0x600D));
        uint256 gConfig = g - gasleft(); total += gConfig;

        console.log("AlphaVault deploy   :", gVault);
        console.log("AlphaYieldApp deploy:", gApp);
        console.log("openMarket          :", gMarket);
        console.log("config (4 txs)      :", gConfig);
        console.log("TOTAL               :", total);
        // each tx also pays the 21000 intrinsic; 7 txs in the real flow
        console.log("TOTAL + 7x21000     :", total + 7 * 21000);
    }
}
