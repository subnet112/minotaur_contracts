// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployAlphaYield} from "../script/DeployAlphaYield.s.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";
import {MockMetagraph} from "./mocks/MockMetagraph.sol";

/// Exercises the real deploy script, both phases, rather than trusting that it
/// reads correctly. The last two defects in this branch — a tautological nonce
/// guard and a one-candidate market that paid full marks — were both found by
/// reading this script rather than running it, so run it.
contract DeployAlphaYieldTest is Test {
    DeployAlphaYield dep;
    MockMetagraph meta;

    // real SN112 hotkeys read off a Finney fork
    bytes32 constant HK_0 = bytes32(0x56426093d1d8298bbc833d8fec69b94733841ebe0f5cebbb29062d5baf58ab5c);
    bytes32 constant HK_41 = bytes32(0x56a9aee6291bd03ab6d36d4d13e2bebae7cd403518066c72fba1b417d6ddd748);

    uint256 constant KEY = 0xA11CE;
    address deployer;

    address constant WTAO_964 = 0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81;
    address constant APP_REGISTRY_964 = 0x80758D3Bf11715c82dB9964C634d5Fd8a0C58aBF;

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        MockStakingV2(payable(0x0000000000000000000000000000000000000805)).setAlphaPerRao(445);
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        meta.setNeuron(112, 0, HK_0, 674_353_772_016, 15000, true);
        meta.setNeuron(112, 41, HK_41, 1_442_603_990_173_928, 35000, true);

        deployer = vm.addr(KEY);
        vm.deal(deployer, 10 ether);
        dep = new DeployAlphaYield();

        _baseEnv();
    }

    /// vm.setEnv writes HOST environment, which is not rolled back between tests
    /// the way EVM state is. A test that overrides one variable therefore leaks
    /// it into whatever runs next, so every test re-establishes the full set
    /// rather than relying on setUp.
    function _baseEnv() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(KEY));
        vm.setEnv("GOVERNOR", vm.toString(address(0x600D)));
        vm.setEnv("RELAYER", vm.toString(address(0x7e90)));
        vm.setEnv("NETUID", "112");
        vm.setEnv("MARKET_HOTKEYS", string.concat(vm.toString(HK_0), ",", vm.toString(HK_41)));
        vm.setEnv("MARKET_UIDS", "0,41");
        vm.setEnv("TOKEN_NAME", "Wrapped SN112 Alpha");
        vm.setEnv("TOKEN_SYMBOL", "wAlpha112");
        vm.setEnv("REBALANCE_COOLDOWN", "21600");
        vm.setEnv("FEE_RECIPIENT", vm.toString(address(0xFEE5)));
        vm.setEnv("PERFORMANCE_FEE_BPS", "1000");
        vm.setEnv("PHASE", "predict");
        vm.setEnv("EXPECTED_VAULT", vm.toString(address(0)));
        vm.setEnv("VAULT_COLDKEY", vm.toString(bytes32(0)));
    }

    function _predicted() internal view returns (address) {
        return vm.computeCreateAddress(deployer, vm.getNonce(deployer));
    }

    /// ONE sequential test, deliberately.
    ///
    /// The script is env-driven and `vm.setEnv` writes the HOST environment,
    /// which is shared process-wide and not rolled back between tests the way
    /// EVM state is. Splitting this across test functions makes them race: each
    /// one passes alone and they contaminate each other when run together, which
    /// is worse than no test because it looks like coverage. So the whole flow
    /// runs in order in a single function, asserting as it goes.
    function test_the_full_two_phase_deploy() public {
        _baseEnv();

        // ── PHASE 1 ──────────────────────────────────────────────────────────
        vm.setEnv("PHASE", "predict");
        address expected = _predicted();
        dep.run();
        console.log("phase 1 predicted:", expected);
        assertTrue(expected != address(0));

        // ── negative cases, before the real deploy consumes the nonce ────────
        vm.setEnv("PHASE", "deploy");
        vm.setEnv("EXPECTED_VAULT", vm.toString(expected));
        vm.setEnv("VAULT_COLDKEY", vm.toString(bytes32(uint256(0xC01D))));

        vm.setEnv("MARKET_HOTKEYS", vm.toString(HK_0));
        vm.setEnv("MARKET_UIDS", "0");
        _expectRun("need at least TWO candidates; one is unscoreable");

        vm.setEnv("MARKET_HOTKEYS", string.concat(vm.toString(HK_0), ",", vm.toString(HK_41)));
        vm.setEnv("MARKET_UIDS", "0,42"); // 42 is not HK_41's uid
        _expectRun("a MARKET_UID does not map to its MARKET_HOTKEY on the metagraph");

        vm.setEnv("MARKET_UIDS", "0,41");
        vm.setEnv("EXPECTED_VAULT", vm.toString(address(0xBAD)));
        _expectRun(
            "nonce moved since PHASE 1: the vault would land elsewhere and the coldkey would be wrong. Re-run PHASE=predict."
        );

        // ── PHASE 2, for real ────────────────────────────────────────────────
        vm.setEnv("EXPECTED_VAULT", vm.toString(expected));
        assertEq(_predicted(), expected, "a failed run consumed the nonce");
        dep.run();

        AlphaVault vault = AlphaVault(payable(expected));
        assertEq(vault.coldkey(), bytes32(uint256(0xC01D)), "coldkey not bound");
        assertEq(vault.governor(), address(0x600D), "governance not handed over");
        assertEq(vault.rebalanceCooldown(), 21600, "cooldown not set");
        assertEq(vault.performanceFeeBps(), 1000, "fee not set");
        assertEq(vault.feeRecipient(), address(0xFEE5), "fee recipient not set");
        assertEq(vault.candidateCount(112), 2, "market not opened with both candidates");

        AlphaYieldApp app = AlphaYieldApp(payable(vault.optimizer()));
        assertEq(address(app.vault()), expected, "app not pointed at the vault");
        assertEq(app.relayer(), address(0x7e90), "relayer not set");
        assertEq(address(app.appRegistry()), APP_REGISTRY_964, "app registry not wired");
        assertEq(address(app.wrappedNativeToken()), WTAO_964, "WTAO not wired");

        (bytes32 hk, uint16 uid, , ,) = vault.markets(112);
        assertEq(hk, HK_0);
        assertEq(uid, 0);
        console.log("vault:", expected);
        console.log("app:  ", address(app));
    }

    function _expectRun(string memory expectedRevert) internal {
        try dep.run() {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, expectedRevert, "wrong revert reason");
        }
    }
}
