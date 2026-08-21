// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {WrappedAlpha} from "../src/WrappedAlpha.sol";
import {MockStakingV2} from "./mocks/MockStakingV2.sol";

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
    AlphaVault vault;

    bytes32 constant HK_112 = bytes32(uint256(0x112));
    bytes32 constant HK_64 = bytes32(uint256(0x64));
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

        vault = new AlphaVault(VAULT_CK, gov);
        staking.setColdkeyFor(address(vault), VAULT_CK);
        staking.setAlphaPerRao(445);
        staking.setExitFeeBps(10);

        vm.prank(gov);
        vault.openMarket(112, HK_112, "Wrapped SN112 Alpha", "wAlpha112");

        vm.deal(address(staking), 1_000_000 * ONE_TAO);
        vm.deal(alice, 100 * ONE_TAO);
        vm.deal(bob, 100 * ONE_TAO);
    }

    function _token(uint256 netuid) internal view returns (WrappedAlpha t) {
        (, t) = vault.markets(netuid);
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
        vault.openMarket(64, HK_64, "Wrapped SN64 Alpha", "wAlpha64");

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
        vault.openMarket(64, HK_64, "Wrapped SN64 Alpha", "wAlpha64");
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
        vault.openMarket(64, HK_64, "x", "x");
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
