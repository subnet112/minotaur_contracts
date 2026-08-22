// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AppIntentBase} from "./AppIntentBase.sol";
import {AlphaVault} from "./AlphaVault.sol";
import {IMetagraph} from "./interfaces/IMetagraph.sol";

/// The Minotaur App that turns validator selection into a competed intent.
///
/// A wrapped-alpha position has to be delegated to SOME validator, and which one
/// changes what holders earn. Rather than pick by governance, this App exposes
/// the choice as an intent: solvers propose a validator, the best proposal wins,
/// and the vault pays for the service out of realised yield.
///
/// WHY THE PLAN IS DATA, NOT CODE. Every other App executes the solver's plan —
/// it deploys an EphemeralProxy and runs the calls. This one does not, and the
/// difference is deliberate: those plans move funds the user just supplied,
/// while a plan here would move a POOLED, custodied position belonging to every
/// wAlpha holder. Solver code on this subnet is untrusted by construction, so
/// the plan carries only a (hotkey, uid) recommendation in `metadata` and this
/// contract performs the move itself, inside the vault's allowlist. A malicious
/// plan can at worst name a worse allowlisted validator — and score badly for it.
///
/// SCORING IS ABSOLUTE, 0..1 (as BPS on chain). The DEX aggregator's relative
/// pairwise rule does not apply here: there is a knowable best answer at every
/// block, namely the highest-yielding validator on the allowlist, so a plan is
/// scored as a fraction of that optimum rather than against a champion.
///
///     score = (rate(chosen) - rate(worst)) / (rate(best) - rate(worst))
///
/// normalised across the allowlist so the worst eligible pick scores 0 and the
/// best scores 1 — full discrimination over the spread that actually exists,
/// rather than a ratio that collapses once one candidate dominates.
///
/// RATE IS DILUTION-AWARE, AND THAT IS NOT A DETAIL:
///
///     rate(uid) = dividends(uid) / (stake(uid) + position moving in)
///
/// The naive `dividends / stake` is a MARGINAL rate — what the next infinitesimal
/// unit of stake earns — and using it to place a large position is a serious
/// error. Measured on SN112 at fork block 8893344: uid 230 holds 8,659 dividends
/// on 8,800,003 stake, which scores ~12,500x better than uid 0 on the marginal
/// rate. Move the vault's 445.8e9 alpha onto it and the same position earns
/// 59% LESS than uid 0 would have, because our own stake swamps a denominator
/// that small. The marginal metric would have paid full marks for throwing away
/// most of the yield. Including the incoming position is what makes the score
/// answer the question actually being asked: where should THIS money go.
///
/// (The incumbent's metagraph stake already contains the vault's position, so it
/// is not added twice — see `_rate`.)
///
/// Both terms are ordinary metagraph state (IMetagraph at 0x…0802), which is
/// what makes this scorable in a fork simulation at a single block instead of
/// requiring an epoch of waiting.
///
/// KNOWN LIMIT, STATED PLAINLY: the formula omits the delegate TAKE, because no
/// precompile exposes it. Actual payout is `dividends × (1 − take)`, so a
/// validator that charges 100% would score identically to one that charges
/// nothing. Two things contain that, neither of them this scorer: the vault's
/// allowlist (take is vetted off-chain before a hotkey is eligible at all), and
/// the performance fee, which is charged on realised share-price growth — so a
/// plan that routes to a take-everything validator earns the fee recipient
/// nothing either. Do not raise `scoreThreshold` expecting it to police take.
contract AlphaYieldApp is AppIntentBase {
    IMetagraph public constant METAGRAPH = IMetagraph(0x0000000000000000000000000000000000000802);

    /// Scores are a fraction of the achievable optimum, expressed in BPS.
    uint256 private constant BPS = 10_000;
    uint256 private constant RATE_SCALE = 1e18;

    AlphaVault public immutable vault;

    bytes4 public constant OPTIMIZE_YIELD = bytes4(keccak256("optimizeYield(uint256)"));

    event YieldOptimized(
        uint256 indexed netuid,
        bytes32 indexed chosen,
        uint16 uid,
        uint256 chosenRate,
        uint256 bestRate,
        bool moved
    );

    error NotAllowlisted(bytes32 hotkey);
    error NoScorableYield(uint256 netuid);
    error NothingToOptimize(uint256 netuid, uint256 candidates);

    constructor(
        address _vault,
        address _relayer,
        address _validatorRegistry,
        uint256 _scoreThreshold,
        address _wrappedNativeToken,
        address _platformFeeCollector,
        uint256 _minPlatformFeeWei,
        uint256 _maxPlatformFeeWei,
        FeeMode _feeMode,
        address _appPaymaster,
        address _appRegistry
    )
        AppIntentBase(
            _relayer,
            _validatorRegistry,
            _scoreThreshold,
            _wrappedNativeToken,
            _platformFeeCollector,
            _minPlatformFeeWei,
            _maxPlatformFeeWei,
            _feeMode,
            _appPaymaster,
            _appRegistry
        )
    {
        require(_vault != address(0), "Invalid vault");
        vault = AlphaVault(payable(_vault));
        registeredIntents[OPTIMIZE_YIELD] = true;
    }

    /// No per-order platform fee, and not because fees are unwanted — because
    /// there is no notional to charge one against. Every other App bills a cut of
    /// a user-supplied amount; an order here supplies nothing and moves nobody's
    /// funds but the vault's own. The base's default would decode the last 32
    /// bytes of `intentParams` — which on this App is the NETUID — and bill it as
    /// wei, so leaving it in place charges 112 wei for optimising SN112.
    ///
    /// Minotaur is paid instead by the vault's performance fee, on realised
    /// share-price growth. That is the deliberate arrangement: the network earns
    /// only when holders earn, which is also what makes an unpriceable delegate
    /// take safe to live with.
    function _calculateProtocolFee(IntentOrder calldata) internal view virtual override returns (uint256) {
        return 0;
    }

    // ── the intent ───────────────────────────────────────────────────────────

    /// What the vault's position would earn per unit if delegated to `uid`.
    /// Zero for a uid that is not currently a validator — an unusable
    /// destination, and zero is the honest score for naming it.
    function rateOf(uint256 netuid, uint16 uid) public view returns (uint256) {
        return _rate(netuid, uid, vault.positionAlpha(netuid), _incumbentUid(netuid));
    }

    function _incumbentUid(uint256 netuid) internal view returns (uint16 uid) {
        (, uid, , ,) = vault.markets(netuid);
    }

    function _rate(uint256 netuid, uint16 uid, uint256 position, uint16 incumbent)
        internal view returns (uint256)
    {
        uint16 n = uint16(netuid);
        if (!METAGRAPH.getValidatorStatus(n, uid)) return 0;
        uint256 stake = uint256(METAGRAPH.getStake(n, uid));
        // The incumbent's reported stake ALREADY contains our position; every
        // other candidate's does not, and would gain it on a move.
        if (uid != incumbent) stake += position;
        if (stake == 0) return 0;
        return (uint256(METAGRAPH.getDividends(n, uid)) * RATE_SCALE) / stake;
    }

    /// Best and worst rate reachable inside the vault's allowlist. Bounded by
    /// AlphaVault.MAX_CANDIDATES, so this cannot become unbounded work.
    function candidateRange(uint256 netuid)
        public view returns (bytes32 bestHotkey, uint16 bestUid, uint256 bestRate, uint256 worstRate)
    {
        uint256 n = vault.candidateCount(netuid);
        if (n == 0) return (bytes32(0), 0, 0, 0);
        uint256 position = vault.positionAlpha(netuid);
        uint16 incumbent = _incumbentUid(netuid);
        worstRate = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            (bytes32 h, uint16 u) = vault.candidateAt(netuid, i);
            uint256 r = _rate(netuid, u, position, incumbent);
            if (r > bestRate) { bestRate = r; bestHotkey = h; bestUid = u; }
            if (r < worstRate) worstRate = r;
        }
    }

    function bestCandidate(uint256 netuid)
        public view returns (bytes32 hotkey, uint16 uid, uint256 rate)
    {
        (hotkey, uid, rate,) = candidateRange(netuid);
    }

    /// Everything a solver needs to build a plan, in one call — the candidate
    /// set with live rates plus the cooldown. Published so that competing on
    /// this intent needs no indexer and no privileged data.
    function survey(uint256 netuid)
        external view
        returns (bytes32[] memory hotkeys, uint16[] memory uids, uint256[] memory rates, uint256 readyAt)
    {
        uint256 n = vault.candidateCount(netuid);
        hotkeys = new bytes32[](n);
        uids = new uint16[](n);
        rates = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            (bytes32 h, uint16 u) = vault.candidateAt(netuid, i);
            hotkeys[i] = h;
            uids[i] = u;
            rates[i] = rateOf(netuid, u);
        }
        readyAt = vault.nextRebalanceAt(netuid);
    }

    /// Plan shape:
    ///   order.intentParams = abi.encode(uint256 netuid)
    ///   plan.metadata      = abi.encode(bytes32 hotkey, uint16 uid)
    ///
    /// `plan.calls` is IGNORED — see the contract-level note. Solvers should send
    /// an empty array; anything there is dead weight that only costs them gas.
    function _handleIntent(IntentOrder calldata order, ExecutionPlan calldata plan)
        internal override returns (uint256 score, bool valid)
    {
        uint256 netuid = abi.decode(order.intentParams, (uint256));
        (bytes32 chosen, uint16 uid) = abi.decode(plan.metadata, (bytes32, uint16));

        if (!vault.isCandidate(netuid, chosen)) revert NotAllowlisted(chosen);

        // With fewer than two candidates there is no choice to make and so
        // nothing to grade. Min-max would hand out FULL MARKS — best equals
        // worst, every solver names the only option, and the intent becomes a
        // free-points faucet paying 1.0 for a no-op every round. A market opened
        // with one validator (which is what a fresh deploy produces, since the
        // allowlist can only be widened through a 2-day timelock) is simply not
        // scoreable until a second candidate lands.
        uint256 candidates = vault.candidateCount(netuid);
        if (candidates < 2) revert NothingToOptimize(netuid, candidates);

        (, , uint256 bestRate, uint256 worstRate) = candidateRange(netuid);
        // No validator on the allowlist is earning anything: there is no better
        // and no worse, so there is nothing to score. Fail rather than hand out
        // full marks for a choice that cannot be distinguished.
        if (bestRate == 0) revert NoScorableYield(netuid);

        (bytes32 current, uint16 incumbent, , ,) = vault.markets(netuid);
        uint256 chosenRate = _rate(netuid, uid, vault.positionAlpha(netuid), incumbent);
        bool moved;
        if (chosen != current) {
            // Reverts if the uid no longer maps to this hotkey, if the cooldown
            // has not elapsed, or if the move would lose alpha. All three are
            // conditions a solver can read in advance via `survey`.
            vault.rebalance(netuid, chosen, uid);
            moved = true;
        }

        // Min-max across the allowlist: worst eligible pick 0, best 1. When every
        // candidate is identical there is no spread to grade on and any pick is
        // the right one, so it scores full marks rather than dividing by zero.
        score = bestRate == worstRate
            ? BPS
            : ((chosenRate - worstRate) * BPS) / (bestRate - worstRate);
        if (score > BPS) score = BPS; // worstRate <= chosenRate <= bestRate
        valid = true;

        emit YieldOptimized(netuid, chosen, uid, chosenRate, bestRate, moved);
    }
}
