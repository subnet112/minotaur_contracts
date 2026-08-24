// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaYieldApp} from "../src/AlphaYieldApp.sol";
import {AppIntentBaseV2} from "../src/AppIntentBaseV2.sol";
import {IAppIntentBase} from "../src/interfaces/IAppIntentBase.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";
import {MockMetagraph} from "./mocks/MockMetagraph.sol";

/// Validator selection as a scored Minotaur intent.
///
/// The property under test is that the score is ABSOLUTE and bounded: a plan is
/// worth its fraction of the best achievable rate on the allowlist, so finding
/// the optimum pays 10000 BPS whether or not anyone else competed that round.
/// That is the opposite of the DEX aggregator's relative pairwise rule, and it
/// is possible here only because the metagraph makes "best" knowable at a block.
contract AlphaYieldAppTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;
    AlphaYieldApp app;

    bytes32 constant HK_A = bytes32(uint256(0xAA));   // uid 0: big stake, mediocre rate
    bytes32 constant HK_B = bytes32(uint256(0xBB));   // uid 1: the best allowlisted rate
    bytes32 constant HK_OUT = bytes32(uint256(0xFF)); // uid 9: best rate on the subnet, NOT allowlisted
    bytes32 constant HK_TINY = bytes32(uint256(0x71)); // uid 3: huge marginal rate, tiny stake
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    uint256 constant ONE_TAO = 1e18;

    address gov = address(0x600D);
    address relayer = address(0xC0FFEE);
    address registry = address(0x9E61);
    address alice = address(0xA11CE);

    /// Cached in setUp because reading it from the App is an EXTERNAL call, and
    /// an external call inside an argument consumes the pending vm.prank /
    /// vm.expectRevert — which makes the test pass or fail for the wrong reason.
    bytes4 sel;

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);

        // Rates are DILUTION-AWARE, so the fixture is built on what each
        // validator yields AFTER the vault's ~445.8e9 position lands on it:
        //   A (incumbent, position already counted) 15000/672.9e9  = 22.3e-12
        //   B (would gain the position)             35000/545.8e9  = 64.1e-12  <- best
        // NOTE the mock metagraph is STATIC: moving stake in the mock does not
        // grow the destination's reported stake, where the real chain would.
        // That is fine for testing the ranking rule, and is why fixtures state
        // post-move stake directly rather than relying on the move to produce it.
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 35000, true);
        meta.setNeuron(112, 9, HK_OUT, 10_000_000_000, 60000, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);
        staking.setExitFeeBps(10);

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});

        app = new AlphaYieldApp(
            address(vault), relayer, registry, 5000,
            address(0xA7A0), address(0), 0, 0, AppIntentBaseV2.FeeMode.APP, address(0), address(0)
        );

        vm.startPrank(gov);
        vault.openMarket(112, cs, "Wrapped SN112 Alpha", "wAlpha112");
        vault.setOptimizer(address(app));
        vm.stopPrank();

        vm.deal(address(staking), 1_000_000 * ONE_TAO);
        vm.deal(alice, 100 * ONE_TAO);
        vm.warp(block.timestamp + 30 days);

        sel = app.OPTIMIZE_YIELD();

        vm.prank(alice);
        vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);
    }

    function _order(uint256 netuid) internal view returns (IAppIntentBase.IntentOrder memory o) {
        o.orderId = keccak256("o");
        o.app = address(app);
        o.intentSelector = sel;
        o.intentParams = abi.encode(netuid);
        o.submittedBy = alice;
        o.chainId = block.chainid;
        o.deadline = block.timestamp + 1 hours;
    }

    function _plan(bytes32 hotkey, uint16 uid) internal view returns (IAppIntentBase.ExecutionPlan memory p) {
        p.calls = new IAppIntentBase.Call[](0);
        p.deadline = block.timestamp + 1 hours;
        p.metadata = abi.encode(hotkey, uid);
    }

    // ── the score is a fraction of a knowable optimum ────────────────────────

    function test_naming_the_best_allowlisted_validator_scores_full_marks() public {
        IAppIntentBase.IntentOrder memory o_score = _order(112);
        IAppIntentBase.ExecutionPlan memory p_score = _plan(HK_B, 1);
        vm.prank(relayer);
        (uint256 score, bool valid) = app.scoreIntent(o_score, p_score);
        assertEq(score, 10000, "the optimum did not score 1.0");
        assertTrue(valid);
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_B, "the position did not follow the winning plan");
    }

    /// Min-max across the allowlist: the WORST eligible pick scores 0, not some
    /// consoling fraction. With only two candidates the loser is the worst.
    function test_the_worst_allowlisted_pick_scores_zero() public {
        uint256 rA = app.rateOf(112, 0);
        uint256 rB = app.rateOf(112, 1);
        assertLt(rA, rB, "fixture is wrong: A should be the worse validator");

        IAppIntentBase.IntentOrder memory o = _order(112);
        IAppIntentBase.ExecutionPlan memory p = _plan(HK_A, 0);
        vm.prank(relayer);
        (uint256 score,) = app.scoreIntent(o, p);
        assertEq(score, 0, "the worst pick was not scored 0 under min-max");
    }

    /// THE TRAP THIS METRIC EXISTS TO AVOID. A validator holding almost no stake
    /// has a huge MARGINAL rate (dividends/stake) and looks like the obvious
    /// pick — until the vault's position lands on it and swamps the denominator.
    /// Measured on SN112 at fork block 8893344: uid 230 beats uid 0 by ~12,500x
    /// marginally, and loses to it by 59% once the position actually moves.
    function test_a_tiny_validator_with_a_huge_marginal_rate_does_not_win() public {
        // uid 3: 8,659 dividends on 8,800,003 stake — SN112's uid 230, as measured.
        meta.setNeuron(112, 3, HK_TINY, 8_800_003, 8659, true);
        vm.prank(gov);
        vault.queueCandidate(112, HK_TINY);
        vm.warp(block.timestamp + vault.ALLOWLIST_TIMELOCK());
        vm.prank(gov);
        vault.commitCandidate(112, HK_TINY, 3);

        uint256 position = vault.positionAlpha(112);
        assertGt(position, 0);

        // Marginal rate says TINY wins by a mile...
        uint256 marginalTiny = (uint256(8659) * 1e18) / 8_800_003;
        uint256 marginalIncumbent = (uint256(15000) * 1e18) / 672_893_522_735;
        assertGt(marginalTiny, marginalIncumbent * 1000, "fixture does not reproduce the trap");

        // ...but the dilution-aware rate the App uses says otherwise.
        assertLt(
            app.rateOf(112, 3), app.rateOf(112, 0),
            "the tiny validator still wins once our own stake is counted"
        );

        (, uint16 bestUid,) = app.bestCandidate(112);
        assertTrue(bestUid != 3, "the scorer picked the marginal trap");
    }

    /// The score does not depend on any other solver's submission — the whole
    /// point of an absolute rule.
    function test_score_is_absolute_not_relative_to_other_plans() public {
        IAppIntentBase.IntentOrder memory o_first = _order(112);
        IAppIntentBase.ExecutionPlan memory p_first = _plan(HK_B, 1);
        vm.prank(relayer);
        (uint256 first,) = app.scoreIntent(o_first, p_first);

        vm.warp(vault.nextRebalanceAt(112));
        IAppIntentBase.IntentOrder memory o_second = _order(112);
        IAppIntentBase.ExecutionPlan memory p_second = _plan(HK_A, 0);
        vm.prank(relayer);
        (uint256 second,) = app.scoreIntent(o_second, p_second);

        vm.warp(vault.nextRebalanceAt(112));
        IAppIntentBase.IntentOrder memory o_third = _order(112);
        IAppIntentBase.ExecutionPlan memory p_third = _plan(HK_B, 1);
        vm.prank(relayer);
        (uint256 third,) = app.scoreIntent(o_third, p_third);

        assertEq(first, third, "an identical plan scored differently after a rival submitted");
        assertLt(second, first);
    }

    function test_a_plan_naming_a_non_allowlisted_validator_is_rejected() public {
        // HK_OUT has the best rate on the whole subnet. It still cannot be chosen:
        // its take was never vetted, and take is invisible on chain.
        IAppIntentBase.IntentOrder memory o = _order(112);
        IAppIntentBase.ExecutionPlan memory p = _plan(HK_OUT, 9);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AlphaYieldApp.NotAllowlisted.selector, HK_OUT));
        app.scoreIntent(o, p);
    }

    function test_a_dead_subnet_is_declined_rather_than_scored() public {
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 0, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 0, true);
        IAppIntentBase.IntentOrder memory o = _order(112);
        IAppIntentBase.ExecutionPlan memory p = _plan(HK_B, 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AlphaYieldApp.NoScorableYield.selector, uint256(112)));
        app.scoreIntent(o, p);
    }

    /// Re-affirming the incumbent is a legitimate answer when it is already best.
    function test_keeping_the_current_validator_scores_full_marks_when_it_is_best() public {
        // make A the best, so standing pat is correct
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 1, true);
        uint256 cooldownBefore = vault.nextRebalanceAt(112);
        IAppIntentBase.IntentOrder memory o_score = _order(112);
        IAppIntentBase.ExecutionPlan memory p_score = _plan(HK_A, 0);
        vm.prank(relayer);
        (uint256 score,) = app.scoreIntent(o_score, p_score);

        assertEq(score, 10000, "standing pat on the best validator was penalised");
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_A, "the position moved when it should not have");
        assertEq(
            vault.nextRebalanceAt(112), cooldownBefore,
            "a no-op burned the cooldown, blocking a real move later"
        );
    }

    function test_only_the_relayer_may_score() public {
        IAppIntentBase.IntentOrder memory o = _order(112);
        IAppIntentBase.ExecutionPlan memory p = _plan(HK_B, 1);
        vm.expectRevert();
        app.scoreIntent(o, p); // no prank: caller is the test contract, not the relayer
    }

    /// survey() is the solver's whole input: candidates, live rates, cooldown.
    function test_survey_publishes_everything_a_solver_needs() public view {
        (bytes32[] memory hks, uint16[] memory uids, uint256[] memory rates, uint256 readyAt) =
            app.survey(112);
        assertEq(hks.length, 2);
        assertEq(hks[0], HK_A);
        assertEq(uids[1], 1);
        assertGt(rates[1], rates[0], "survey does not reveal which validator is better");
        assertEq(readyAt, vault.nextRebalanceAt(112));
    }
}

/// What the deploy script actually produces on day one: a market opened with a
/// single candidate, because the allowlist can only be widened through a 2-day
/// timelock. Scoring has to mean something in that state.
contract AlphaYieldSingleCandidateTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;
    AlphaYieldApp app;

    bytes32 constant HK_A = bytes32(uint256(0xAA));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    address gov = address(0x600D);
    address relayer = address(0xC0FFEE);
    bytes4 sel;

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);

        app = new AlphaYieldApp(
            address(vault), relayer, address(0x9E61), 5000,
            address(0xA7A0), address(0), 0, 0, AppIntentBaseV2.FeeMode.APP, address(0), address(0)
        );

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](1);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "w", "w");
        vault.setOptimizer(address(app));
        vm.stopPrank();

        sel = app.OPTIMIZE_YIELD();
        vm.deal(address(staking), 1_000_000 ether);
        vm.deal(address(this), 10 ether);
        vault.purchaseWrapped{value: 1e18}(112, address(this), 0);
    }

    /// With one candidate there is no choice to make, so there is nothing to
    /// grade. Paying full marks would turn the intent into a free-points faucet:
    /// every round, every solver names the only option and scores 1.0 for a no-op.
    function test_a_single_candidate_market_is_not_scoreable() public {
        IAppIntentBase.IntentOrder memory o;
        o.orderId = keccak256("o");
        o.app = address(app);
        o.intentSelector = sel;
        o.intentParams = abi.encode(uint256(112));
        o.chainId = block.chainid;
        o.deadline = block.timestamp + 1 hours;

        IAppIntentBase.ExecutionPlan memory p;
        p.calls = new IAppIntentBase.Call[](0);
        p.metadata = abi.encode(HK_A, uint16(0));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaYieldApp.NothingToOptimize.selector, uint256(112), uint256(1))
        );
        app.scoreIntent(o, p);
    }
}

/// scoreIntent applies no score threshold — it calls _handleIntent and returns.
/// So the App must not act on a plan before knowing it is good enough, or a
/// single scoreIntent call can relocate a pooled position to a bad validator.
contract AlphaYieldThresholdGateTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;
    AlphaYieldApp app;

    bytes32 constant HK_GOOD = bytes32(uint256(0xAA));
    bytes32 constant HK_BAD = bytes32(uint256(0xBB));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    address gov = address(0x600D);
    address relayer = address(0xC0FFEE);
    bytes4 sel;

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        // SN112's real shape: uid0 dominant, the runner-up scoring ~4099 BPS,
        // i.e. below the 5000 gate. Naming it must not move anything.
        meta.setNeuron(112, 0, HK_GOOD, 672_893_522_735, 53111, true);
        meta.setNeuron(112, 1, HK_BAD, 8_800_003, 8659, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);

        app = new AlphaYieldApp(
            address(vault), relayer, address(0x9E61), 5000,
            address(0xA7A0), address(0), 0, 0, AppIntentBaseV2.FeeMode.APP, address(0), address(0)
        );

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_GOOD, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_BAD, uid: 1});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "w", "w");
        vault.setOptimizer(address(app));
        vm.stopPrank();

        sel = app.OPTIMIZE_YIELD();
        vm.deal(address(staking), 1_000_000 ether);
        vm.deal(address(this), 10 ether);
        vault.purchaseWrapped{value: 1e18}(112, address(this), 0);
        vm.warp(block.timestamp + 30 days);
    }

    function _run(bytes32 hk, uint16 uid) internal returns (uint256 score) {
        IAppIntentBase.IntentOrder memory o;
        o.orderId = keccak256("o");
        o.app = address(app);
        o.intentSelector = sel;
        o.intentParams = abi.encode(uint256(112));
        o.chainId = block.chainid;
        o.deadline = block.timestamp + 1 hours;
        IAppIntentBase.ExecutionPlan memory p;
        p.calls = new IAppIntentBase.Call[](0);
        p.metadata = abi.encode(hk, uid);
        vm.prank(relayer);
        (score,) = app.scoreIntent(o, p);
    }

    function test_a_sub_threshold_plan_scores_low_and_moves_nothing() public {
        uint256 score = _run(HK_BAD, 1);
        assertLt(score, 5000, "fixture wrong: the bad validator should be below the gate");
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_GOOD, "a sub-threshold plan relocated the position via scoreIntent");
        assertEq(staking.getStake(HK_BAD, VAULT_CK, 112), 0, "stake leaked to the bad validator");
    }

    function test_a_passing_plan_still_moves() public {
        // flip the fixture so the other validator is genuinely better
        meta.setNeuron(112, 1, HK_BAD, 100_000_000_000, 60000, true);
        uint256 score = _run(HK_BAD, 1);
        assertEq(score, 10000);
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_BAD, "a passing plan failed to move the position");
    }
}

/// A freshly deployed market holds no position until its first depositor. The
/// validator choice decides nothing in that state, so it must not be scoreable —
/// otherwise every round pays full marks for a no-op over an empty vault.
contract AlphaYieldEmptyVaultTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;
    AlphaYieldApp app;

    bytes32 constant HK_A = bytes32(uint256(0xAA));
    bytes32 constant HK_B = bytes32(uint256(0xBB));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    address gov = address(0x600D);
    address relayer = address(0xC0FFEE);
    bytes4 sel;

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        // Mirrors the deployed SN112 market: the incumbent dominates and the
        // second candidate is inert, so naming the incumbent is both the right
        // answer and a no-op.
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);
        meta.setNeuron(112, 1, HK_B, 1_442_603_990_173_928, 224, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);

        app = new AlphaYieldApp(
            address(vault), relayer, address(0x9E61), 5000,
            address(0xA7A0), address(0), 0, 0, AppIntentBaseV2.FeeMode.APP, address(0), address(0)
        );

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "w", "w");
        vault.setOptimizer(address(app));
        vm.stopPrank();

        sel = app.OPTIMIZE_YIELD();
        vm.deal(address(staking), 1_000_000 ether);
        vm.deal(address(this), 10 ether);
    }

    function _call(bytes32 hk, uint16 uid) internal returns (uint256 score) {
        IAppIntentBase.IntentOrder memory o;
        o.orderId = keccak256("o");
        o.app = address(app);
        o.intentSelector = sel;
        o.intentParams = abi.encode(uint256(112));
        o.chainId = block.chainid;
        o.deadline = block.timestamp + 1 hours;
        IAppIntentBase.ExecutionPlan memory p;
        p.calls = new IAppIntentBase.Call[](0);
        p.metadata = abi.encode(hk, uid);
        vm.prank(relayer);
        (score,) = app.scoreIntent(o, p);
    }

    function test_an_empty_vault_is_not_scoreable() public {
        assertEq(vault.positionAlpha(112), 0, "fixture: vault should be empty");
        vm.expectRevert(abi.encodeWithSelector(AlphaYieldApp.NothingAtStake.selector, uint256(112)));
        _call(HK_A, 0);
    }

    function test_it_becomes_scoreable_once_someone_deposits() public {
        vault.purchaseWrapped{value: 1e18}(112, address(this), 0);
        assertGt(vault.positionAlpha(112), 0);
        assertEq(_call(HK_A, 0), 10000, "should score normally once funded");
    }
}
