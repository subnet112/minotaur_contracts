// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {IMetagraph} from "../src/interfaces/IMetagraph.sol";
import {IAppRegistry} from "../src/interfaces/IAppRegistry.sol";
import {IValidatorRegistry} from "../src/interfaces/IValidatorRegistry.sol";

/// Read-only gate to run before this App is allowed to take real orders.
///
/// IT EXISTS FOR ONE FAILURE MODE ABOVE ALL. `scoreIntent` does NOT call
/// `_requireRegistered`; only `executeIntent` and `executeLeg` do. An App that
/// was deployed but never registered in the AppRegistry therefore SIMULATES AND
/// SCORES PERFECTLY in every benchmark round, and then reverts "App not
/// registered" on every real execution. Nothing in the scoring path will ever
/// surface that. The same asymmetry applies to a wrong wrappedNativeToken and a
/// wrong relayer.
///
/// Env inputs:
///   VAULT, APP        - the deployed pair
///   NETUID            - the market to check (0 skips market checks)
///   ORDER_COOLDOWN    - the cooldown the perpetual order will be signed with
///
/// Chain-964 addresses are verified against live state rather than trusted from
/// a .env: at fork block 8899983 ValidatorRegistry.quorumBps() returned 5000 and
/// all three registries reported owner 0x7dC30109a32764f808823095C576a0355B7978d6,
/// the post-rotation owner.
contract PreflightAlphaYield is Script {
    IMetagraph constant METAGRAPH = IMetagraph(0x0000000000000000000000000000000000000802);
    address constant STAKING = 0x0000000000000000000000000000000000000805;

    address constant WTAO_964 = 0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81;
    address constant APP_REGISTRY_964 = 0x80758D3Bf11715c82dB9964C634d5Fd8a0C58aBF;
    address constant VALIDATOR_REGISTRY_964 = 0x0B5fE44e90515571761D86C28c4855F325EDE098;

    uint256 private failures;

    function run() external {
        check(
            AlphaVault(payable(vm.envAddress("VAULT"))),
            AlphaYieldApp(payable(vm.envAddress("APP"))),
            vm.envOr("NETUID", uint256(0)),
            vm.envOr("ORDER_COOLDOWN", uint256(0))
        );
    }

    /// The gate itself, taking parameters rather than reading the environment.
    ///
    /// `vm.setEnv` writes the HOST environment, which is shared process-wide and
    /// survives across tests AND across concurrently-running test contracts.
    /// When both this script's tests and the deploy script's tests drove
    /// themselves through env vars they collided on NETUID and the suite went
    /// flaky — passing individually, failing about one run in three together.
    /// A flaky test is worse than none: it reads as coverage. So the logic takes
    /// arguments and only `run()` touches the environment.
    function check(
        AlphaVault vault,
        AlphaYieldApp app,
        uint256 netuid,
        uint256 orderCooldown
    ) public {
        failures = 0;
        console.log("=== Preflight: AlphaYield on chain", block.chainid, "===");

        _wiring(vault, app);
        _registration(app);
        _precompiles();
        if (netuid != 0) _market(vault, app, netuid);
        if (orderCooldown != 0) _cooldown(vault, orderCooldown);

        console.log("");
        if (failures != 0) {
            console.log("PREFLIGHT FAILED:", failures, "check(s)");
            revert("preflight failed");
        }
        console.log("PREFLIGHT PASSED");
        console.log("NOTE: vault.coldkey() cannot be verified on chain (no blake2_256 in the EVM).");
        console.log("      Run: node tools/coldkey.mjs <vault> <coldkey>");
    }

    // ── checks ───────────────────────────────────────────────────────────────

    function _wiring(AlphaVault vault, AlphaYieldApp app) private {
        _ok("vault has code", address(vault).code.length > 0);
        _ok("app has code", address(app).code.length > 0);
        _ok("app points at this vault", address(app.vault()) == address(vault));
        _ok("vault's optimizer is this app", vault.optimizer() == address(app));
        _ok("vault has a governor", vault.governor() != address(0));
        _ok("coldkey is set (value unverifiable here)", vault.coldkey() != bytes32(0));

        // A fee recipient of zero silently disables the fee: _accrueFee advances
        // the high-water mark and charges nothing, so the network earns nothing
        // and no error is ever raised.
        _warn(
            "performance fee is live",
            vault.performanceFeeBps() != 0 && vault.feeRecipient() != address(0)
        );
    }

    function _registration(AlphaYieldApp app) private {
        address reg = address(app.appRegistry());
        _ok("app has an AppRegistry (address(0) disables the gate entirely)", reg != address(0));
        if (block.chainid == 964) {
            _ok("AppRegistry is the canonical 964 one", reg == APP_REGISTRY_964);
            _ok("wrappedNativeToken is WTAO on 964", address(app.wrappedNativeToken()) == WTAO_964);
            _ok("ValidatorRegistry is the canonical 964 one", app.validatorRegistry() == VALIDATOR_REGISTRY_964);
        }
        if (reg != address(0)) {
            // THE check. Passing this is the difference between an App that scores
            // in benchmarks and one that can actually execute.
            _ok(
                "app is REGISTERED (scoreIntent never checks this; executeIntent reverts without it)",
                IAppRegistry(reg).appByContract(address(app)) != bytes32(0)
            );
        }
        address vr = app.validatorRegistry();
        _ok("ValidatorRegistry has code", vr.code.length > 0);
        if (vr.code.length > 0) {
            _ok("quorumBps is non-zero (a zero means a stale contract)",
                IValidatorRegistry(vr).quorumBps() != 0);
        }
        _ok("relayer is set", app.relayer() != address(0));
        _ok("scoreThreshold in range", app.scoreThreshold() >= 5000 && app.scoreThreshold() <= 10000);
    }

    function _precompiles() private {
        uint16 count = METAGRAPH.getUidCount(uint16(112));
        _ok("metagraph precompile answers (uid count > 0)", count > 0);
    }

    function _market(AlphaVault vault, AlphaYieldApp app, uint256 netuid) private {
        (bytes32 hotkey, uint16 uid, , ,) = vault.markets(netuid);
        _ok("market is open", hotkey != bytes32(0));

        uint256 n = vault.candidateCount(netuid);
        // Not "> 0": one candidate is unscoreable and the App reverts
        // NothingToOptimize rather than paying full marks for a forced choice.
        _ok("market has at least TWO candidates (one is unscoreable)", n >= 2);
        _ok("candidate set is within MAX_CANDIDATES", n <= vault.MAX_CANDIDATES());

        bool incumbentAllowed;
        bool allUidsProve = true;
        for (uint256 i = 0; i < n; ++i) {
            (bytes32 h, uint16 u) = vault.candidateAt(netuid, i);
            if (h == hotkey) incumbentAllowed = true;
            // A uid is a SLOT and gets reused when a neuron deregisters. A stale
            // pairing here means rebalance() reverts UidMismatch at the worst
            // possible moment — mid-round, on a live order.
            if (METAGRAPH.getHotkey(uint16(netuid), u) != h) {
                allUidsProve = false;
                console.log("  stale candidate uid:", u);
            }
        }
        _ok("the live delegation is itself allowlisted", incumbentAllowed);
        _ok("every candidate uid still maps to its hotkey", allUidsProve);
        _ok("incumbent uid still maps to its hotkey",
            METAGRAPH.getHotkey(uint16(netuid), uid) == hotkey);

        (, , uint256 best,) = app.candidateRange(netuid);
        // Not fatal: a subnet where nothing earns is unscoreable, and the App
        // reverts NoScorableYield rather than handing out marks it cannot justify.
        _warn("some allowlisted validator is earning (else every order reverts)", best > 0);
    }

    function _cooldown(AlphaVault vault, uint256 orderCooldown) private {
        uint256 vaultCooldown = vault.rebalanceCooldown();
        console.log("  vault.rebalanceCooldown:", vaultCooldown);
        console.log("  order cooldown:", orderCooldown);
        // The base keys its clock on order.orderId, the vault on the netuid. If
        // the order's is the shorter one, fills revert RebalanceTooSoon and burn
        // benchmark rounds for no reason.
        _ok("order cooldown >= vault cooldown", orderCooldown >= vaultCooldown);
        _ok("vault cooldown above the floor", vaultCooldown >= vault.MIN_REBALANCE_COOLDOWN());
    }

    // ── output ───────────────────────────────────────────────────────────────

    function _ok(string memory what, bool pass) private {
        console.log(pass ? "  PASS " : "  FAIL ", what);
        if (!pass) failures++;
    }

    function _warn(string memory what, bool pass) private pure {
        console.log(pass ? "  ok   " : "  WARN ", what);
    }
}
