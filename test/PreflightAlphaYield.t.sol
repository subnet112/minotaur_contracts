// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PreflightAlphaYield} from "../script/PreflightAlphaYield.s.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {AppIntentBase} from "../src/AppIntentBase.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";
import {MockMetagraph} from "./mocks/MockMetagraph.sol";

contract MockAppRegistry {
    mapping(address => bytes32) public appByContract;
    function register(address a, bytes32 id) external { appByContract[a] = id; }
    function isRegistered(bytes32) external pure returns (bool) { return true; }
}

contract MockValidatorRegistry {
    uint256 public quorumBps = 5000;
    function setQuorum(uint256 q) external { quorumBps = q; }
}

/// A preflight that cannot fail is worse than no preflight: it converts an
/// unchecked deploy into a checked-looking one. Each test here breaks exactly
/// one precondition and asserts the gate catches it.
contract PreflightAlphaYieldTest is Test {
    PreflightAlphaYield pf;
    AlphaVault vault;
    AlphaYieldApp app;
    MockAppRegistry appReg;
    MockValidatorRegistry valReg;
    MockStakingV2 staking;
    MockMetagraph meta;

    bytes32 constant HK_A = bytes32(uint256(0xAA));
    bytes32 constant HK_B = bytes32(uint256(0xBB));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    address gov = address(0x600D);
    address relayer = address(0xC0FFEE);
    address wtao = address(0xA7A0);

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 35000, true);

        appReg = new MockAppRegistry();
        valReg = new MockValidatorRegistry();
        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);

        app = new AlphaYieldApp(
            address(vault), relayer, address(valReg), 5000, wtao,
            address(0), 0, 0, AppIntentBase.FeeMode.APP, address(0), address(appReg)
        );

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "w", "w");
        vault.setOptimizer(address(app));
        vault.setPerformanceFee(address(0xFEE5), 1000);
        vm.stopPrank();

        appReg.register(address(app), keccak256("alpha-yield"));

        pf = new PreflightAlphaYield();
        vm.setEnv("VAULT", vm.toString(address(vault)));
        vm.setEnv("APP", vm.toString(address(app)));
        vm.setEnv("NETUID", "112");
        vm.setEnv("ORDER_COOLDOWN", "21600");
    }

    function test_a_correctly_wired_deployment_passes() public {
        pf.run();
    }

    /// THE ONE THIS EXISTS FOR. scoreIntent never calls _requireRegistered, so
    /// an unregistered app scores perfectly in every benchmark round and reverts
    /// on every real execution. Nothing in the scoring path reveals it.
    function test_it_catches_an_unregistered_app() public {
        appReg.register(address(app), bytes32(0));
        vm.expectRevert("preflight failed");
        pf.run();
    }

    function test_it_catches_an_optimizer_that_is_not_the_app() public {
        vm.prank(gov);
        vault.setOptimizer(address(0xDEAD));
        vm.expectRevert("preflight failed");
        pf.run();
    }

    /// uids are SLOTS and get reused when a neuron deregisters. A stale pairing
    /// means rebalance() reverts UidMismatch mid-round on a live order.
    function test_it_catches_a_candidate_uid_that_no_longer_maps() public {
        meta.setNeuron(112, 1, bytes32(uint256(0xDEAD)), 1, 1, true);
        vm.expectRevert("preflight failed");
        pf.run();
    }

    function test_it_catches_a_stale_validator_registry() public {
        valReg.setQuorum(0);
        vm.expectRevert("preflight failed");
        pf.run();
    }

    /// An order cooldown shorter than the vault's just burns rounds: the fill
    /// reverts RebalanceTooSoon every time until the vault's clock catches up.
    function test_it_catches_an_order_cooldown_shorter_than_the_vaults() public {
        vm.setEnv("ORDER_COOLDOWN", "3600"); // vault default is 6h
        vm.expectRevert("preflight failed");
        pf.run();
    }

    function test_it_catches_a_market_that_was_never_opened() public {
        vm.setEnv("NETUID", "64");
        vm.expectRevert("preflight failed");
        pf.run();
    }
}
