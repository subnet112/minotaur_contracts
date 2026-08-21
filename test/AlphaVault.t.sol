// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {WrappedAlpha} from "../src/WrappedAlpha.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";
import {MockMetagraph} from "./mocks/MockMetagraph.sol";

/// One contract, any subnet, two ownership models.
///
/// SCOPE: the mock prices alpha at a constant, so this proves routing, custody
/// and share arithmetic and says NOTHING about AMM slippage. Slippage and
/// redemption cost were measured on a Chopsticks fork of Finney
/// (tools/chopsticks-sim in the subnet repo): 1 TAO -> 445,806,103,716 alpha ->
/// 0.998993307 TAO (10.1 bps), no unbonding delay, and moveStake preserving a
/// position 1:1 within a netuid.
contract AlphaVaultTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;

    bytes32 constant HK_112 = bytes32(uint256(0x112));
    bytes32 constant HK_64 = bytes32(uint256(0x64));
    bytes32 constant HK_ALT = bytes32(uint256(0xA17));
    bytes32 constant HK_NEW = bytes32(uint256(0xEE));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    bytes32 constant ALICE_CK = bytes32(uint256(0xA11CE));
    uint256 constant ONE_TAO = 1e18;
    uint256 constant ONE_RAO = 1e9;

    address gov = address(0x600D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        MockStakingV2 impl = new MockStakingV2();
        vm.etch(0x0000000000000000000000000000000000000805, address(impl).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));

        MockMetagraph mimpl = new MockMetagraph();
        vm.etch(0x0000000000000000000000000000000000000802, address(mimpl).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        // SN112 shape at fork block 8892914: uid 0 dominant, uid 1 a smaller but
        // BETTER-yielding validator (less stake per unit of dividend).
        meta.setNeuron(112, 0, HK_112, 672_893_522_735, 53111, true);
        meta.setNeuron(112, 1, HK_ALT, 100_000_000_000, 12419, true);
        meta.setNeuron(112, 7, HK_NEW, 50_000_000_000, 5000, true);
        meta.setNeuron(64, 0, HK_64, 1_000_000_000, 100, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);
        staking.setExitFeeBps(10);

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_112, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_ALT, uid: 1});
        vm.prank(gov);
        vault.openMarket(112, cs, "Wrapped SN112 Alpha", "wAlpha112");

        vm.deal(address(staking), 1_000_000 * ONE_TAO);
        vm.deal(alice, 100 * ONE_TAO);
        vm.deal(bob, 100 * ONE_TAO);
    }

    function _token(uint256 netuid) internal view returns (WrappedAlpha t) {
        (, , t, ,) = vault.markets(netuid);
    }

    function _one(bytes32 hk, uint16 uid) internal pure returns (AlphaVault.Candidate[] memory cs) {
        cs = new AlphaVault.Candidate[](1);
        cs[0] = AlphaVault.Candidate({hotkey: hk, uid: uid});
    }

    // ── mode 1: self-custody, the vault holds nothing ────────────────────────

    function test_purchase_delivers_alpha_to_the_user_not_the_vault() public {
        vm.prank(alice);
        uint256 out = vault.purchase{value: ONE_TAO}(112, HK_112, ALICE_CK, 0);

        assertEq(out, 1e9 * 445, "wrong alpha amount");
        assertEq(staking.getStake(HK_112, ALICE_CK, 112), out, "user did not receive the position");
        assertEq(staking.getStake(HK_112, VAULT_CK, 112), 0, "vault kept custody");
    }

    function test_purchase_needs_no_open_market() public {
        // an unopened subnet still works: nothing is held, so nothing to account
        vm.prank(alice);
        uint256 out = vault.purchase{value: ONE_TAO}(64, HK_64, ALICE_CK, 0);
        assertEq(staking.getStake(HK_64, ALICE_CK, 64), out);
    }

    function test_purchase_rejects_a_zero_beneficiary() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.NoBeneficiary.selector);
        vault.purchase{value: ONE_TAO}(112, HK_112, bytes32(0), 0);
    }

    function test_purchase_slippage_guard() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.purchase{value: ONE_TAO}(112, HK_112, ALICE_CK, type(uint256).max);
    }

    // ── mode 2: wrapped ──────────────────────────────────────────────────────

    function test_wrapped_purchase_mints_erc20_and_vault_holds_the_position() public {
        vm.prank(alice);
        uint256 shares = vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);

        assertGt(shares, 0);
        assertEq(_token(112).balanceOf(alice), shares, "no wAlpha minted");
        assertEq(staking.getStake(HK_112, VAULT_CK, 112), 1e9 * 445, "vault holds nothing");
        assertEq(staking.getStake(HK_112, ALICE_CK, 112), 0, "user should NOT hold alpha");
    }

    function test_wrapped_requires_an_open_market() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.MarketNotOpen.selector);
        vault.purchaseWrapped{value: ONE_TAO}(64, alice, 0);
    }

    function test_wrapped_yield_accrues_to_holders() public {
        vm.prank(alice);
        uint256 aShares = vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);
        staking.creditAlpha(VAULT_CK, HK_112, 112, vault.positionAlpha(112)); // emission doubles it
        vm.prank(bob);
        uint256 bShares = vault.purchaseWrapped{value: ONE_TAO}(112, bob, 0);
        assertApproxEqRel(bShares, aShares / 2, 1e15, "bob should buy in at the post-yield rate");
    }

    function test_wrapped_redeem_returns_tao() public {
        vm.prank(alice);
        uint256 shares = vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = vault.redeemWrapped(112, shares, 0);
        assertEq(_token(112).balanceOf(alice), 0);
        assertEq(alice.balance - before, out);
        assertApproxEqRel(out, (ONE_TAO * 9990) / 10_000, 1e15);
    }

    // ── the property that makes ONE contract safe for MANY subnets ───────────

    function test_subnets_are_accounted_independently() public {
        vm.prank(gov);
        vault.openMarket(64, _one(HK_64, 0), "Wrapped SN64 Alpha", "wAlpha64");

        vm.prank(alice);
        uint256 s112 = vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);
        vm.prank(bob);
        uint256 s64 = vault.purchaseWrapped{value: ONE_TAO}(64, bob, 0);

        // emission on 112 only
        staking.creditAlpha(VAULT_CK, HK_112, 112, vault.positionAlpha(112));

        // SN64's share price must be untouched by SN112's yield
        assertEq(vault.convertToAlpha(64, s64), _alphaFor(64, s64), "SN64 rate moved");
        assertGt(vault.convertToAlpha(112, s112), 0);
        assertTrue(_token(112) != _token(64), "subnets must not share a token");
    }

    function _alphaFor(uint256 netuid, uint256 shares) internal view returns (uint256) {
        return (shares * (vault.positionAlpha(netuid) + 1)) / (vault.totalShares(netuid) + 1e9);
    }

    function test_donation_to_one_subnet_cannot_zero_a_depositor_in_another() public {
        vm.prank(gov);
        vault.openMarket(64, _one(HK_64, 0), "Wrapped SN64 Alpha", "wAlpha64");
        // hostile donation onto the vault's coldkey for 112 via transferStake
        staking.creditAlpha(VAULT_CK, HK_112, 112, 1e18);

        vm.prank(bob);
        uint256 s64 = vault.purchaseWrapped{value: ONE_TAO}(64, bob, 0);
        assertGt(s64, 0, "SN64 depositor harmed by an SN112 donation");
    }

    function test_donation_cannot_zero_the_next_depositor_in_the_same_subnet() public {
        vm.prank(alice);
        vault.purchaseWrapped{value: ONE_RAO}(112, alice, 0);
        staking.creditAlpha(VAULT_CK, HK_112, 112, 1e18);
        vm.prank(bob);
        assertGt(vault.purchaseWrapped{value: ONE_TAO}(112, bob, 0), 0, "inflation attack succeeded");
    }

    // ── shared guards ────────────────────────────────────────────────────────

    function test_units_reject_unaligned_and_dust() public {
        vm.startPrank(alice);
        vm.expectRevert(AlphaVault.UnalignedAmount.selector);
        vault.purchaseWrapped{value: ONE_TAO + 1}(112, alice, 0);
        vm.expectRevert(AlphaVault.DustAmount.selector);
        vault.purchase{value: ONE_RAO - 1}(112, HK_112, ALICE_CK, 0);
        vm.stopPrank();
    }

    function test_wrong_coldkey_fails_closed() public {
        AlphaVault bad = new AlphaVault(bytes32(uint256(0xDEAD)), gov);
        staking.setColdkeyFor(address(bad), VAULT_CK);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.ColdkeyMismatch.selector);
        bad.purchase{value: ONE_TAO}(112, HK_112, ALICE_CK, 0);
    }

    function test_only_governor_opens_markets() public {
        vm.prank(alice);
        vm.expectRevert(AlphaVault.NotGovernor.selector);
        vault.openMarket(64, _one(HK_64, 0), "x", "x");
    }

    function test_wrapped_token_is_mintable_only_by_the_vault() public {
        // resolve the token FIRST: _token() calls vault.markets(), which would
        // otherwise consume the prank/expectRevert before mint is reached
        WrappedAlpha t = _token(112);
        vm.prank(alice);
        vm.expectRevert(WrappedAlpha.OnlyVault.selector);
        t.mint(alice, 1e18);
    }

    function test_wrapped_token_is_burnable_only_by_the_vault() public {
        WrappedAlpha t = _token(112);
        vm.prank(alice);
        vault.purchaseWrapped{value: ONE_TAO}(112, alice, 0);
        vm.prank(alice);
        vm.expectRevert(WrappedAlpha.OnlyVault.selector);
        t.burn(alice, 1);
    }

    function testFuzz_wrapped_round_trip_never_creates_value(uint96 amt) public {
        uint256 tao = (uint256(amt) / ONE_RAO) * ONE_RAO;
        vm.assume(tao >= ONE_RAO && tao <= 50 * ONE_TAO);
        vm.deal(alice, tao);
        vm.startPrank(alice);
        uint256 shares = vault.purchaseWrapped{value: tao}(112, alice, 0);
        uint256 out = vault.redeemWrapped(112, shares, 0);
        vm.stopPrank();
        assertLe(out, tao, "round trip minted value from nothing");
    }
}

/// The allowlist, the re-delegation path, and the performance fee.
///
/// These exist because validator choice is competed as a Minotaur intent rather
/// than set by governance. The allowlist is the boundary that makes an untrusted
/// solver's recommendation safe to act on; the fee is how the work gets paid for.
contract AlphaVaultRebalanceTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;

    bytes32 constant HK_A = bytes32(uint256(0xAA));   // uid 0, big, mediocre rate
    bytes32 constant HK_B = bytes32(uint256(0xBB));   // uid 1, small, better rate
    bytes32 constant HK_OUT = bytes32(uint256(0xFF)); // uid 9, never allowlisted
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));
    uint256 constant ONE_TAO = 1e18;

    address gov = address(0x600D);
    address opt = address(0x0971);
    address fees = address(0xFEE5);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);

        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 53111, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 12419, true);
        meta.setNeuron(112, 9, HK_OUT, 10_000_000_000, 60000, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        // vm.etch copies code, not storage — the mock's declared defaults are
        // absent at the precompile address and must be set explicitly.
        staking.setAlphaPerRao(445);
        staking.setExitFeeBps(10);

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "Wrapped SN112 Alpha", "wAlpha112");
        vault.setOptimizer(opt);
        vm.stopPrank();

        vm.deal(address(staking), 1_000_000 * ONE_TAO);
        vm.deal(alice, 100 * ONE_TAO);
        vm.warp(block.timestamp + 30 days); // clear the opening cooldown
    }

    function _deposit(uint256 tao) internal returns (uint256) {
        vm.prank(alice);
        return vault.purchaseWrapped{value: tao}(112, alice, 0);
    }

    function _position() internal view returns (uint256) { return vault.positionAlpha(112); }

    // ── the allowlist is the trust boundary ──────────────────────────────────

    function test_rebalance_moves_the_whole_position_to_an_allowlisted_validator() public {
        _deposit(ONE_TAO);
        uint256 before = _position();
        assertGt(before, 0);

        vm.prank(opt);
        uint256 moved = vault.rebalance(112, HK_B, 1);

        assertEq(moved, before, "alpha changed in a same-netuid move");
        assertEq(staking.getStake(HK_A, VAULT_CK, 112), 0, "old delegation not drained");
        assertEq(staking.getStake(HK_B, VAULT_CK, 112), before, "new delegation not funded");
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_B);
    }

    function test_rebalance_rejects_a_validator_off_the_allowlist() public {
        _deposit(ONE_TAO);
        // HK_OUT has by far the best raw rate — that is the point. A solver that
        // names it must still be refused, because take was never vetted for it.
        vm.prank(opt);
        vm.expectRevert(AlphaVault.NotCandidate.selector);
        vault.rebalance(112, HK_OUT, 9);
    }

    function test_rebalance_rejects_a_uid_that_no_longer_maps_to_the_hotkey() public {
        _deposit(ONE_TAO);
        // uid 1 gets reassigned to another neuron — a real event on Bittensor.
        meta.setNeuron(112, 1, bytes32(uint256(0xDEAD)), 1, 1, true);
        vm.prank(opt);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.UidMismatch.selector, HK_B, bytes32(uint256(0xDEAD)))
        );
        vault.rebalance(112, HK_B, 1);
    }

    function test_only_the_optimizer_may_rebalance() public {
        _deposit(ONE_TAO);
        vm.prank(gov); // not even the governor
        vm.expectRevert(AlphaVault.NotOptimizer.selector);
        vault.rebalance(112, HK_B, 1);
    }

    function test_cooldown_bounds_thrashing() public {
        _deposit(ONE_TAO);
        vm.prank(opt);
        vault.rebalance(112, HK_B, 1);

        // Resolve readyAt BEFORE pranking: a call in the expectRevert argument
        // consumes the prank, and the test would then pass for the wrong reason.
        uint256 readyAt = vault.nextRebalanceAt(112);
        vm.prank(opt);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.RebalanceTooSoon.selector, readyAt));
        vault.rebalance(112, HK_A, 0);

        vm.warp(readyAt);
        vm.prank(opt);
        vault.rebalance(112, HK_A, 0); // now allowed
    }

    /// The rounding the real chain actually does must NOT trip the guard —
    /// a strict equality check here made rebalancing impossible on Finney.
    function test_one_rao_of_rounding_dust_is_tolerated() public {
        _deposit(ONE_TAO);
        uint256 before = _position();
        staking.setMoveDust(1); // exactly what a Finney fork run loses

        vm.prank(opt);
        uint256 moved = vault.rebalance(112, HK_B, 1);
        assertEq(moved, before - 1, "fixture did not reproduce the rounding");
        (bytes32 hk,,,,) = vault.markets(112);
        assertEq(hk, HK_B, "a one-rao rounding blocked the move");
    }

    function test_a_move_losing_more_than_dust_still_reverts() public {
        _deposit(ONE_TAO);
        uint256 before = _position();
        // Resolve every external read BEFORE pranking — a call inside the
        // expectRevert argument consumes the prank and the test then fails (or
        // passes) for the wrong reason.
        uint256 tooMuch = vault.MAX_MOVE_DUST() + 1;
        staking.setMoveDust(tooMuch);

        vm.prank(opt);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.MoveLostAlpha.selector, before, before - tooMuch)
        );
        vault.rebalance(112, HK_B, 1);
    }

    function test_a_lossy_move_reverts_instead_of_repricing_shares() public {
        _deposit(ONE_TAO);
        uint256 before = _position();
        staking.setMoveLossBps(1); // 0.01% haircut

        vm.prank(opt);
        vm.expectRevert(
            abi.encodeWithSelector(
                AlphaVault.MoveLostAlpha.selector, before, before - (before * 1) / 10_000
            )
        );
        vault.rebalance(112, HK_B, 1);
    }

    // ── widening trust waits; narrowing it does not ──────────────────────────

    function test_adding_a_candidate_is_timelocked() public {
        meta.setNeuron(112, 3, HK_OUT, 10_000_000_000, 60000, true);

        vm.prank(gov);
        vault.queueCandidate(112, HK_OUT);

        uint256 eta = vault.candidateEta(keccak256(abi.encodePacked(uint256(112), HK_OUT)));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.TimelockPending.selector, eta));
        vault.commitCandidate(112, HK_OUT, 3);

        vm.warp(eta);
        vm.prank(gov);
        vault.commitCandidate(112, HK_OUT, 3);
        assertTrue(vault.isCandidate(112, HK_OUT));
        assertEq(vault.candidateCount(112), 3);
    }

    function test_a_candidate_cannot_be_committed_without_being_queued() public {
        vm.prank(gov);
        vm.expectRevert(AlphaVault.NotQueued.selector);
        vault.commitCandidate(112, HK_OUT, 9);
    }

    function test_removing_a_candidate_is_immediate_but_not_the_live_one() public {
        vm.prank(gov);
        vm.expectRevert(AlphaVault.AlreadyDelegated.selector);
        vault.removeCandidate(112, HK_A); // currently delegated

        vm.prank(gov);
        vault.removeCandidate(112, HK_B); // instant, no timelock
        assertFalse(vault.isCandidate(112, HK_B));
        assertEq(vault.candidateCount(112), 1);
    }

    // ── the performance fee ──────────────────────────────────────────────────

    function test_fee_is_charged_on_yield_and_only_on_yield() public {
        vm.prank(gov);
        vault.setPerformanceFee(fees, 1000); // 10%

        uint256 shares = _deposit(ONE_TAO);
        uint256 principal = _position();
        assertEq(vault.convertToAlpha(112, vault.totalShares(112)), principal, "deposit was billed");

        // 10% yield arrives
        uint256 yield_ = principal / 10;
        staking.creditAlpha(VAULT_CK, HK_A, 112, yield_);
        vault.accrue(112);

        uint256 feeShares = WrappedAlpha(_tok()).balanceOf(fees);
        uint256 feeAlpha = vault.convertToAlpha(112, feeShares);
        uint256 aliceAlpha = vault.convertToAlpha(112, shares);

        assertApproxEqRel(feeAlpha, yield_ / 10, 1e15, "fee is not 10% of the yield");
        assertApproxEqRel(aliceAlpha, principal + (yield_ * 9) / 10, 1e15, "holder did not keep 90%");
    }

    function test_high_water_mark_does_not_bill_the_same_gain_twice() public {
        vm.prank(gov);
        vault.setPerformanceFee(fees, 1000);
        _deposit(ONE_TAO);

        uint256 principal = _position();
        staking.creditAlpha(VAULT_CK, HK_A, 112, principal / 10);
        vault.accrue(112);
        uint256 afterFirst = WrappedAlpha(_tok()).balanceOf(fees);
        assertGt(afterFirst, 0);

        // a drawdown, then a recovery back to the same level
        staking.debitAlpha(VAULT_CK, HK_A, 112, principal / 10);
        vault.accrue(112);
        staking.creditAlpha(VAULT_CK, HK_A, 112, principal / 10);
        vault.accrue(112);

        assertEq(
            WrappedAlpha(_tok()).balanceOf(fees), afterFirst,
            "recovering to an old high was billed as new yield"
        );
    }

    function test_fee_is_settled_before_a_new_depositor_arrives() public {
        vm.prank(gov);
        vault.setPerformanceFee(fees, 1000);
        _deposit(ONE_TAO);
        staking.creditAlpha(VAULT_CK, HK_A, 112, _position() / 10);

        // Bob buys in without anyone calling accrue() first. He must not be
        // diluted by a fee on yield earned entirely before he existed.
        address bob2 = address(0xB0B2);
        vm.deal(bob2, ONE_TAO);
        vm.prank(bob2);
        uint256 bobShares = vault.purchaseWrapped{value: ONE_TAO}(112, bob2, 0);
        uint256 bobAlpha = vault.convertToAlpha(112, bobShares);

        vm.prank(gov);
        vault.setPerformanceFee(fees, 0);
        assertApproxEqRel(bobAlpha, vault.convertToAlpha(112, bobShares), 1e15);
        // what Bob can redeem must still be ~what he paid for
        assertApproxEqRel(bobAlpha, 445e9, 1e15, "new depositor absorbed an old fee");
    }

    function test_fee_is_capped_in_code() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.FeeTooHigh.selector, uint256(2001)));
        vault.setPerformanceFee(fees, 2001);
    }

    function test_rebalance_crystallises_the_fee_before_moving() public {
        vm.prank(gov);
        vault.setPerformanceFee(fees, 1000);
        _deposit(ONE_TAO);
        staking.creditAlpha(VAULT_CK, HK_A, 112, _position() / 10);

        vm.prank(opt);
        vault.rebalance(112, HK_B, 1);
        assertGt(
            WrappedAlpha(_tok()).balanceOf(fees), 0,
            "moving validators skipped the fee earned at the old one"
        );
    }

    function _tok() internal view returns (address t) {
        (, , WrappedAlpha w, ,) = vault.markets(112);
        t = address(w);
    }
}

/// The vault's cooldown is not a duplicate of AppIntentBase's order cooldown.
/// The base keys its clock on order.orderId; this one keys on the netuid, so it
/// still binds when a SECOND order targets the same market — and when the
/// scoreIntent path reaches rebalance with none of the base's checks applied.
contract AlphaVaultCooldownTest is Test {
    MockStakingV2 staking;
    MockMetagraph meta;
    AlphaVault vault;

    bytes32 constant HK_A = bytes32(uint256(0xAA));
    bytes32 constant HK_B = bytes32(uint256(0xBB));
    bytes32 constant VAULT_CK = bytes32(uint256(0xC01D));

    address gov = address(0x600D);
    address opt = address(0x0971);

    function setUp() public {
        vm.etch(0x0000000000000000000000000000000000000805, address(new MockStakingV2()).code);
        staking = MockStakingV2(payable(0x0000000000000000000000000000000000000805));
        vm.etch(0x0000000000000000000000000000000000000802, address(new MockMetagraph()).code);
        meta = MockMetagraph(0x0000000000000000000000000000000000000802);
        meta.setNeuron(112, 0, HK_A, 672_893_522_735, 15000, true);
        meta.setNeuron(112, 1, HK_B, 100_000_000_000, 35000, true);

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);
        staking.setExitFeeBps(10);

        AlphaVault.Candidate[] memory cs = new AlphaVault.Candidate[](2);
        cs[0] = AlphaVault.Candidate({hotkey: HK_A, uid: 0});
        cs[1] = AlphaVault.Candidate({hotkey: HK_B, uid: 1});
        vm.startPrank(gov);
        vault.openMarket(112, cs, "w", "w");
        vault.setOptimizer(opt);
        vm.stopPrank();

        vm.deal(address(staking), 1_000_000 ether);
        vm.deal(address(this), 10 ether);
        vm.warp(block.timestamp + 30 days);
        vault.purchaseWrapped{value: 1e18}(112, address(this), 0);
    }

    function test_the_default_matches_the_documented_six_hours() public view {
        assertEq(vault.rebalanceCooldown(), 6 hours);
        assertEq(vault.DEFAULT_REBALANCE_COOLDOWN(), 6 hours);
    }

    /// One number at deploy, which the perpetual order's cooldown is built from.
    function test_governor_sets_one_cooldown_that_the_order_is_derived_from() public {
        vm.prank(gov);
        vault.setRebalanceCooldown(12 hours);
        assertEq(vault.rebalanceCooldown(), 12 hours);

        vm.prank(opt);
        vault.rebalance(112, HK_B, 1);
        assertEq(
            vault.nextRebalanceAt(112), block.timestamp + 12 hours,
            "nextRebalanceAt is not the single source the order should read"
        );
    }

    function test_the_cooldown_cannot_be_set_below_the_floor() public {
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.CooldownTooShort.selector, 59 minutes, uint256(1 hours))
        );
        vault.setRebalanceCooldown(59 minutes);
    }

    function test_only_the_governor_sets_it() public {
        vm.prank(opt);
        vm.expectRevert(AlphaVault.NotGovernor.selector);
        vault.setRebalanceCooldown(12 hours);
    }

    /// The case the base's per-order clock cannot cover: a caller that never
    /// went through executeIntent at all still cannot move the position twice.
    function test_it_binds_a_caller_that_bypassed_the_order_entirely() public {
        vm.prank(opt);
        vault.rebalance(112, HK_B, 1);

        uint256 readyAt = vault.nextRebalanceAt(112);
        vm.prank(opt);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.RebalanceTooSoon.selector, readyAt));
        vault.rebalance(112, HK_A, 0);
    }
}
