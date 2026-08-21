// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingV2} from "./interfaces/IStakingV2.sol";
import {IMetagraph} from "./interfaces/IMetagraph.sol";
import {WrappedAlpha} from "./WrappedAlpha.sol";

/// ONE contract, ANY subnet, two ways to own the result.
///
/// The DEX aggregator routes a user's USDC on Ethereum into TAO on 964 and hands
/// it here. The user chose one of two things when they signed the intent:
///
///   ETH:(10000 USDC) => BT EVM(? subnet112 alpha)
///       `purchase` — stake, then hand the position STRAIGHT to the user's own
///       coldkey. The vault custodies nothing; the user owns real alpha and
///       manages it, exactly as if they had staked themselves. Selling later
///       moves their own alpha and leaves accrued yield with them.
///
///   ETH:(10000 USDC) => BT EVM(? wAlpha112)
///       `purchaseWrapped` — the vault keeps the position and mints an ERC-20
///       claim. The holder is exposed to alpha from an EVM address without ever
///       touching Bittensor, and the vault absorbs the yield into the share
///       price. They own wAlpha, NOT alpha — that is the trade.
///
/// WHY ONE CONTRACT AND NOT ONE PER SUBNET: alpha is not fungible across
/// subnets — separate AMM pools, separate prices — so accounting is per netuid
/// and MUST stay isolated. Sharing a contract does not share a balance sheet
/// here: each netuid has its own share supply, its own position, and its own
/// virtual offset. A donation into SN112 cannot move the SN64 share price.
///
/// UNITS: the EVM native balance on 964 is 18-decimal wei; the staking
/// precompile speaks 9-decimal rao. Measured on a Finney fork, not assumed:
/// addStake(1e9 rao) debits exactly 1e18 wei. Forwarding msg.value straight in
/// would stake a billionth of the deposit while accepting all of it.
contract AlphaVault is ReentrancyGuard {
    IStakingV2 public constant STAKING = IStakingV2(0x0000000000000000000000000000000000000805);
    IMetagraph public constant METAGRAPH = IMetagraph(0x0000000000000000000000000000000000000802);

    uint256 public constant WEI_PER_RAO = 1e9;

    /// Bounded because the optimiser scores by scanning every candidate; an
    /// unbounded set would make scoring cost grow without limit.
    uint256 public constant MAX_CANDIDATES = 16;

    /// Adding a validator widens who holders must trust, so it waits. REMOVING
    /// one is instant — narrowing the set can only ever reduce risk, and a
    /// validator that turns hostile must be ejectable immediately.
    uint256 public constant ALLOWLIST_TIMELOCK = 2 days;

    /// Floor under the configurable cooldown. Re-delegation is free
    /// mechanically, so nothing but a clock stops a hostile or buggy optimiser
    /// from thrashing the position.
    ///
    /// WHY THIS EXISTS ALONGSIDE AppIntentBase's ORDER COOLDOWN, rather than
    /// deferring to it — they are not the same guarantee:
    ///
    ///   * The base's cooldown is keyed on `order.orderId` and answers "how
    ///     often may THIS ORDER fill?". A second perpetual order aimed at the
    ///     same market carries its own independent clock, and both could fill
    ///     back to back. This one is keyed on the NETUID and answers "how often
    ///     may THIS MARKET's position move?" — an invariant of the asset, which
    ///     is what holders actually need.
    ///   * `order.cooldown` is a user-signed field chosen by whoever creates the
    ///     order, not a protocol constant.
    ///   * The base checks it in `executeIntent` only. `scoreIntent` reaches
    ///     `_handleIntent` — and therefore `rebalance` — with none of the
    ///     replay, deadline or cooldown checks applied. It is meant to run
    ///     against a fork, but it is a real function on a real contract, and
    ///     this is the only thing bounding what a stray call to it can do.
    ///
    /// So the order cooldown paces the intent, and this paces the position. Set
    /// them to the same value at deploy; `nextRebalanceAt` is public so the
    /// order can be built from it rather than duplicating the number by hand.
    uint256 public constant MIN_REBALANCE_COOLDOWN = 1 hours;
    uint256 public constant DEFAULT_REBALANCE_COOLDOWN = 6 hours;

    /// A performance fee is a claim on holders' yield; cap it in code so no
    /// governor can quietly raise it to confiscatory levels.
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2000;

    /// `moveStake` arrives ONE rao short of what left. Measured on a Finney fork
    /// at 1 TAO and again at 25 TAO — identical single-unit loss both times, so
    /// it is integer-division rounding inside the extrinsic and does NOT scale
    /// with the position.
    ///
    /// This tolerance is ABSOLUTE for that reason. An earlier probe reported the
    /// move as "0.0000% loss" and a strict `moved < amount` check was written
    /// against that reading — but four decimal places cannot tell exactly
    /// lossless from off-by-one, and the strict check made rebalancing
    /// impossible on the real chain. A percentage bound would have hidden the
    /// same thing again.
    ///
    /// 1000 is ~1000x the observed rounding and still ~2000x TIGHTER than one
    /// basis point of a single-TAO position (445.8e9 rao), so a haircut that
    /// actually costs holders anything cannot hide underneath it.
    uint256 public constant MAX_MOVE_DUST = 1000;

    uint256 private constant BPS = 10_000;
    uint256 private constant PPS_SCALE = 1e18;

    /// Sized against attack cost. A donation of D rounds a depositor of `minted`
    /// alpha to zero shares when D > minted * V — and `transferStake` lets ANYONE
    /// donate onto this vault's coldkey, so the first-depositor attack is
    /// reachable by design of the precompile rather than by oversight. At 1e3 a
    /// ~4.45e14 donation broke it (a unit test caught that); 1e9 puts the same
    /// attack on a 1 TAO deposit at ~4.45e20 alpha.
    uint256 private constant VIRTUAL_SHARES = 1e9;
    uint256 private constant VIRTUAL_ALPHA = 1;

    /// blake2_256("evm:" ‖ address(this)) — NOT computable in the EVM (only the
    /// blake2f compression function, EIP-152), so it is supplied at construction
    /// and proved at runtime: a successful addStake that does not raise THIS
    /// coldkey's stake reverts, so the first wrapped purchase fails closed
    /// rather than mispricing every share after it.
    bytes32 public immutable coldkey;

    struct Market {
        bytes32 hotkey;      // the validator this subnet's wrapped position delegates to
        uint16 uid;          // that validator's metagraph uid, proved against the chain
        WrappedAlpha token;  // the ERC-20 face; address(0) until opened
        uint64 lastRebalance;
        /// Highest alpha-per-share ever seen, 1e18-scaled. The performance fee is
        /// charged only on growth above this line, so a fall and recovery is not
        /// billed twice and the fee tracks REALISED yield rather than a forecast.
        uint256 highWaterPps;
    }

    struct Candidate {
        bytes32 hotkey;
        uint16 uid;
    }

    mapping(uint256 => Market) public markets;

    /// The set the optimiser may choose within. This is the load-bearing safety
    /// boundary: solver-supplied plans are untrusted, and the delegate take that
    /// determines real payout is NOT readable on chain, so eligibility is vetted
    /// once here rather than trusted per-plan.
    mapping(uint256 => Candidate[]) private _candidates;
    mapping(uint256 => mapping(bytes32 => bool)) public isCandidate;
    mapping(bytes32 => uint256) public candidateEta;

    address public governor;

    /// The only address that may re-delegate. Intended to be the App contract, so
    /// that re-delegation happens through a scored intent rather than by fiat.
    address public optimizer;

    address public feeRecipient;
    uint256 public performanceFeeBps;

    /// Configurable so a deployment sets ONE number that the perpetual order's
    /// `cooldown` is then derived from, instead of two constants drifting apart.
    uint256 public rebalanceCooldown;

    event MarketOpened(uint256 indexed netuid, bytes32 hotkey, address token);
    event Purchased(uint256 indexed netuid, bytes32 indexed beneficiary, uint256 taoWei, uint256 alphaOut);
    event PurchasedWrapped(uint256 indexed netuid, address indexed receiver, uint256 taoWei, uint256 alphaMinted, uint256 shares);
    event RedeemedWrapped(uint256 indexed netuid, address indexed who, uint256 shares, uint256 alphaBurned, uint256 taoWei);
    event CandidateQueued(uint256 indexed netuid, bytes32 hotkey, uint256 eta);
    event CandidateAdded(uint256 indexed netuid, bytes32 hotkey, uint16 uid);
    event CandidateRemoved(uint256 indexed netuid, bytes32 hotkey);
    event Rebalanced(uint256 indexed netuid, bytes32 from, bytes32 to, uint16 uid, uint256 amount);
    event PerformanceFeeCharged(uint256 indexed netuid, uint256 feeAlpha, uint256 feeShares, uint256 newHighWater);
    event OptimizerSet(address optimizer);
    event PerformanceFeeSet(address recipient, uint256 bps);
    event RebalanceCooldownSet(uint256 seconds_);

    error DustAmount();
    error UnalignedAmount();
    error ColdkeyMismatch();
    error MarketNotOpen();
    error MarketAlreadyOpen();
    error SlippageExceeded(uint256 got, uint256 wanted);
    error ZeroShares();
    error NotGovernor();
    error TaoTransferFailed();
    error NoBeneficiary();
    error NotOptimizer();
    error NotCandidate();
    error AlreadyCandidate();
    error TooManyCandidates();
    error TimelockPending(uint256 eta);
    error NotQueued();
    error UidMismatch(bytes32 wanted, bytes32 got);
    error RebalanceTooSoon(uint256 readyAt);
    error AlreadyDelegated();
    error NothingStaked();
    error MoveLostAlpha(uint256 sent, uint256 arrived);
    error FeeTooHigh(uint256 bps);
    error NoCandidates();
    error CooldownTooShort(uint256 given, uint256 floor);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier onlyOptimizer() {
        if (msg.sender != optimizer) revert NotOptimizer();
        _;
    }

    constructor(bytes32 _coldkey, address _governor) {
        coldkey = _coldkey;
        governor = _governor;
        rebalanceCooldown = DEFAULT_REBALANCE_COOLDOWN;
    }

    // ── markets ──────────────────────────────────────────────────────────────

    /// Open a subnet for WRAPPED purchases. Only needed for the wrapped path —
    /// `purchase` works for any netuid with no setup, because it never holds a
    /// position and so has nothing to account for.
    ///
    /// `initial` is the candidate set the optimiser may ever choose within;
    /// index 0 becomes the live delegation. Every entry is proved against the
    /// metagraph here, so a typo'd uid cannot be admitted and later mis-scored.
    function openMarket(
        uint256 netuid,
        Candidate[] calldata initial,
        string calldata name,
        string calldata symbol
    ) external onlyGovernor returns (address token) {
        if (address(markets[netuid].token) != address(0)) revert MarketAlreadyOpen();
        if (initial.length == 0) revert NoCandidates();
        if (initial.length > MAX_CANDIDATES) revert TooManyCandidates();

        for (uint256 i = 0; i < initial.length; ++i) {
            _proveUid(netuid, initial[i]);
            if (isCandidate[netuid][initial[i].hotkey]) revert AlreadyCandidate();
            isCandidate[netuid][initial[i].hotkey] = true;
            _candidates[netuid].push(initial[i]);
            emit CandidateAdded(netuid, initial[i].hotkey, initial[i].uid);
        }

        WrappedAlpha t = new WrappedAlpha(netuid, name, symbol);
        markets[netuid] = Market({
            hotkey: initial[0].hotkey,
            uid: initial[0].uid,
            token: t,
            lastRebalance: uint64(block.timestamp),
            highWaterPps: 0
        });
        emit MarketOpened(netuid, initial[0].hotkey, address(t));
        return address(t);
    }

    // ── allowlist ────────────────────────────────────────────────────────────

    /// Widening the trusted set waits out a timelock so holders can exit first.
    function queueCandidate(uint256 netuid, bytes32 hotkey) external onlyGovernor {
        if (isCandidate[netuid][hotkey]) revert AlreadyCandidate();
        if (_candidates[netuid].length >= MAX_CANDIDATES) revert TooManyCandidates();
        uint256 eta = block.timestamp + ALLOWLIST_TIMELOCK;
        candidateEta[_key(netuid, hotkey)] = eta;
        emit CandidateQueued(netuid, hotkey, eta);
    }

    function commitCandidate(uint256 netuid, bytes32 hotkey, uint16 uid) external onlyGovernor {
        bytes32 k = _key(netuid, hotkey);
        uint256 eta = candidateEta[k];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TimelockPending(eta);
        if (isCandidate[netuid][hotkey]) revert AlreadyCandidate();
        if (_candidates[netuid].length >= MAX_CANDIDATES) revert TooManyCandidates();

        Candidate memory c = Candidate({hotkey: hotkey, uid: uid});
        // Proved at COMMIT, not at queue: uids are reassigned when neurons
        // deregister, so a check two days stale would be worthless.
        _proveUid(netuid, c);

        delete candidateEta[k];
        isCandidate[netuid][hotkey] = true;
        _candidates[netuid].push(c);
        emit CandidateAdded(netuid, hotkey, uid);
    }

    /// No timelock: ejecting a validator can only narrow trust. The live
    /// delegation cannot be removed out from under the position — move first.
    function removeCandidate(uint256 netuid, bytes32 hotkey) external onlyGovernor {
        if (!isCandidate[netuid][hotkey]) revert NotCandidate();
        if (markets[netuid].hotkey == hotkey) revert AlreadyDelegated();

        Candidate[] storage cs = _candidates[netuid];
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].hotkey == hotkey) {
                cs[i] = cs[cs.length - 1];
                cs.pop();
                break;
            }
        }
        delete isCandidate[netuid][hotkey];
        emit CandidateRemoved(netuid, hotkey);
    }

    function candidateCount(uint256 netuid) external view returns (uint256) {
        return _candidates[netuid].length;
    }

    function candidateAt(uint256 netuid, uint256 i) external view returns (bytes32 hotkey, uint16 uid) {
        Candidate memory c = _candidates[netuid][i];
        return (c.hotkey, c.uid);
    }

    // ── re-delegation ────────────────────────────────────────────────────────

    function nextRebalanceAt(uint256 netuid) public view returns (uint256) {
        return uint256(markets[netuid].lastRebalance) + rebalanceCooldown;
    }

    /// Build the perpetual order's `cooldown` from this, so the two clocks are
    /// configured once rather than asserted to match.
    function setRebalanceCooldown(uint256 seconds_) external onlyGovernor {
        if (seconds_ < MIN_REBALANCE_COOLDOWN) revert CooldownTooShort(seconds_, MIN_REBALANCE_COOLDOWN);
        rebalanceCooldown = seconds_;
        emit RebalanceCooldownSet(seconds_);
    }

    /// Move the whole wrapped position to another allowlisted validator.
    ///
    /// Callable ONLY by the optimiser App, so the destination is the output of a
    /// scored intent. Three things are enforced here rather than trusted: the
    /// destination is on the allowlist, its uid genuinely maps to that hotkey on
    /// the metagraph right now, and the alpha that arrives matches what left.
    /// The plan a solver submits is DATA — this contract never executes
    /// solver-supplied calls.
    function rebalance(uint256 netuid, bytes32 toHotkey, uint16 toUid)
        external onlyOptimizer nonReentrant returns (uint256 moved)
    {
        Market storage m = markets[netuid];
        if (address(m.token) == address(0)) revert MarketNotOpen();
        if (!isCandidate[netuid][toHotkey]) revert NotCandidate();
        if (toHotkey == m.hotkey) revert AlreadyDelegated();
        uint256 ready = nextRebalanceAt(netuid);
        if (block.timestamp < ready) revert RebalanceTooSoon(ready);
        _proveUid(netuid, Candidate({hotkey: toHotkey, uid: toUid}));

        // Crystallise the fee against the OLD validator's performance before the
        // position moves, so a rebalance can never be used to reset the mark.
        _accrueFee(netuid);

        bytes32 from = m.hotkey;
        uint256 amount = STAKING.getStake(from, coldkey, netuid);
        if (amount == 0) revert NothingStaked();

        uint256 before = STAKING.getStake(toHotkey, coldkey, netuid);
        // Same netuid on both sides — a delegation move, never a pool crossing.
        STAKING.moveStake(from, toHotkey, netuid, netuid, amount);
        moved = STAKING.getStake(toHotkey, coldkey, netuid) - before;
        // Measured, not assumed. Same-netuid moves lose exactly one rao to
        // rounding; anything beyond MAX_MOVE_DUST is a real haircut on every
        // holder, so it reverts rather than silently repricing the shares.
        if (moved + MAX_MOVE_DUST < amount) revert MoveLostAlpha(amount, moved);

        m.hotkey = toHotkey;
        m.uid = toUid;
        m.lastRebalance = uint64(block.timestamp);
        emit Rebalanced(netuid, from, toHotkey, toUid, moved);
    }

    /// Crystallise any fee owed. Permissionless on purpose: it can only ever
    /// charge growth that already happened, and letting anyone call it means the
    /// mark cannot drift far from reality between deposits.
    function accrue(uint256 netuid) external nonReentrant {
        _accrueFee(netuid);
    }

    // ── governance ───────────────────────────────────────────────────────────

    function setOptimizer(address o) external onlyGovernor {
        optimizer = o;
        emit OptimizerSet(o);
    }

    /// The fee is charged on realised share-price growth. That is deliberate:
    /// the delegate take is not readable on chain, so a plan CAN route to a
    /// validator that keeps everything. Billing on what holders actually earned
    /// makes such a plan worth zero to the fee recipient too.
    function setPerformanceFee(address recipient, uint256 bps) external onlyGovernor {
        if (bps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh(bps);
        feeRecipient = recipient;
        performanceFeeBps = bps;
        emit PerformanceFeeSet(recipient, bps);
    }

    function setGovernor(address g) external onlyGovernor { governor = g; }

    // ── views ────────────────────────────────────────────────────────────────

    /// The vault's own position in one subnet. Chain state, no oracle — which is
    /// only possible because accounting never crosses subnets. A multi-subnet
    /// index would have to price alpha against TAO (IAlpha 0x…0808's
    /// simSwapAlphaForTao) and is deliberately NOT this contract.
    function positionAlpha(uint256 netuid) public view returns (uint256) {
        Market memory m = markets[netuid];
        if (address(m.token) == address(0)) return 0;
        return STAKING.getStake(m.hotkey, coldkey, netuid);
    }

    function totalShares(uint256 netuid) public view returns (uint256) {
        Market memory m = markets[netuid];
        return address(m.token) == address(0) ? 0 : m.token.totalSupply();
    }

    /// Alpha backing one share, 1e18-scaled. This is the only thing the fee is
    /// measured against — it rises with yield and with nothing else, because a
    /// deposit adds alpha and shares in the same ratio.
    function pricePerShare(uint256 netuid) public view returns (uint256) {
        return ((positionAlpha(netuid) + VIRTUAL_ALPHA) * PPS_SCALE)
            / (totalShares(netuid) + VIRTUAL_SHARES);
    }

    function convertToAlpha(uint256 netuid, uint256 shares) public view returns (uint256) {
        return (shares * (positionAlpha(netuid) + VIRTUAL_ALPHA))
            / (totalShares(netuid) + VIRTUAL_SHARES);
    }

    // ── mode 1: self-custody ─────────────────────────────────────────────────

    /// Stake the TAO sent here and hand the resulting alpha to `beneficiary`.
    ///
    /// The precompile credits `msg.sender`'s mapped coldkey and offers no
    /// stake-on-behalf-of, so the alpha lands here first and is moved out in the
    /// same transaction. The vault is a conduit, never a custodian.
    ///
    /// `beneficiary` is the user's own mapped coldkey. It CANNOT be derived here
    /// (no blake2_256 in the EVM), so the caller supplies it — meaning this
    /// function is only as safe as its caller. It is intended to be reached
    /// through an App intent whose beneficiary is system-derived, never
    /// user-supplied.
    function purchase(uint256 netuid, bytes32 hotkey, bytes32 beneficiary, uint256 minAlphaOut)
        external payable nonReentrant returns (uint256 alphaOut)
    {
        if (beneficiary == bytes32(0)) revert NoBeneficiary();
        uint256 rao = _toRao(msg.value);

        uint256 before = STAKING.getStake(hotkey, coldkey, netuid);
        STAKING.addStake(hotkey, rao, netuid);
        alphaOut = STAKING.getStake(hotkey, coldkey, netuid) - before;
        if (alphaOut == 0) revert ColdkeyMismatch();
        if (alphaOut < minAlphaOut) revert SlippageExceeded(alphaOut, minAlphaOut);

        // Same netuid on both sides: a delegation move, not a pool trade.
        STAKING.transferStake(beneficiary, hotkey, netuid, netuid, alphaOut);
        emit Purchased(netuid, beneficiary, msg.value, alphaOut);
    }

    // ── mode 2: wrapped ──────────────────────────────────────────────────────

    /// Stake the TAO sent here, keep the position, mint `receiver` an ERC-20
    /// claim on it. Shares are minted against the MEASURED alpha delta, so an
    /// AMM move between quote and execution cannot mint unbacked shares.
    function purchaseWrapped(uint256 netuid, address receiver, uint256 minSharesOut)
        external payable nonReentrant returns (uint256 shares)
    {
        if (address(markets[netuid].token) == address(0)) revert MarketNotOpen();
        uint256 rao = _toRao(msg.value);

        // Before ANY measurement: yield earned up to now belongs to existing
        // holders and the fee recipient, not to the incoming deposit.
        _accrueFee(netuid);
        Market memory m = markets[netuid];

        uint256 alphaBefore = STAKING.getStake(m.hotkey, coldkey, netuid);
        uint256 supplyBefore = m.token.totalSupply();

        STAKING.addStake(m.hotkey, rao, netuid);
        uint256 minted = STAKING.getStake(m.hotkey, coldkey, netuid) - alphaBefore;
        if (minted == 0) revert ColdkeyMismatch();

        shares = (minted * (supplyBefore + VIRTUAL_SHARES)) / (alphaBefore + VIRTUAL_ALPHA);
        if (shares == 0) revert ZeroShares();
        if (shares < minSharesOut) revert SlippageExceeded(shares, minSharesOut);

        m.token.mint(receiver, shares);
        emit PurchasedWrapped(netuid, receiver, msg.value, minted, shares);
    }

    /// Burn wrapped shares, unstake the alpha behind them, forward the TAO.
    /// `minTaoOutWei` binds the MEASURED balance delta rather than a quoted
    /// price, so it bounds what the redeemer actually receives even if the
    /// subnet pool moves mid-call.
    function redeemWrapped(uint256 netuid, uint256 shares, uint256 minTaoOutWei)
        external nonReentrant returns (uint256 taoOutWei)
    {
        if (address(markets[netuid].token) == address(0)) revert MarketNotOpen();
        if (shares == 0) revert ZeroShares();

        // Settle the fee first so the redeemer cannot exit ahead of a fee that
        // their own holding period earned.
        _accrueFee(netuid);
        Market memory m = markets[netuid];

        uint256 alphaOut = convertToAlpha(netuid, shares);
        if (alphaOut == 0) revert ZeroShares();

        // Burn before the external call: the claim must shrink in the accounting
        // before the position shrinks on chain, never the other way round.
        m.token.burn(msg.sender, shares);

        uint256 balBefore = address(this).balance;
        STAKING.removeStake(m.hotkey, alphaOut, netuid);
        taoOutWei = address(this).balance - balBefore;
        if (taoOutWei < minTaoOutWei) revert SlippageExceeded(taoOutWei, minTaoOutWei);

        (bool ok,) = msg.sender.call{value: taoOutWei}("");
        if (!ok) revert TaoTransferFailed();
        emit RedeemedWrapped(netuid, msg.sender, shares, alphaOut, taoOutWei);
    }

    // ── internals ────────────────────────────────────────────────────────────

    function _key(uint256 netuid, bytes32 hotkey) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(netuid, hotkey));
    }

    /// A uid is a slot, not an identity — neurons deregister and slots are
    /// reused. Every place a uid is accepted it is proved against the metagraph
    /// in the same transaction, so scoring can trust the pairing.
    function _proveUid(uint256 netuid, Candidate memory c) private view {
        bytes32 onChain = METAGRAPH.getHotkey(uint16(netuid), c.uid);
        if (onChain != c.hotkey) revert UidMismatch(c.hotkey, onChain);
    }

    /// Charge the performance fee on growth above the high-water mark, as share
    /// dilution rather than as a withdrawal — the vault never has loose alpha to
    /// send, and diluting is how a share-price vault expresses a fee.
    ///
    /// Nothing here can charge on a deposit: pricePerShare is invariant to
    /// deposits by construction, so the mark only moves when the position grows
    /// without shares growing, which is exactly yield.
    function _accrueFee(uint256 netuid) internal {
        Market storage m = markets[netuid];
        if (address(m.token) == address(0)) return;

        uint256 pps = pricePerShare(netuid);
        uint256 hwm = m.highWaterPps;
        if (pps <= hwm) return;

        uint256 supply = m.token.totalSupply();
        uint256 bps = performanceFeeBps;
        address to = feeRecipient;
        // Mark still advances when the fee is off or there is nobody to bill:
        // otherwise switching the fee on would retroactively charge for growth
        // that accrued while it was off.
        if (supply == 0 || bps == 0 || to == address(0)) {
            m.highWaterPps = pps;
            return;
        }

        uint256 gainAlpha = ((pps - hwm) * supply) / PPS_SCALE;
        uint256 feeAlpha = (gainAlpha * bps) / BPS;
        if (feeAlpha == 0) {
            m.highWaterPps = pps;
            return;
        }

        uint256 assets = positionAlpha(netuid) + VIRTUAL_ALPHA;
        if (feeAlpha >= assets) return; // pathological; leave the mark, charge nothing

        // Shares whose post-mint value equals feeAlpha, so the charge lands on
        // existing holders exactly once.
        uint256 feeShares = (feeAlpha * (supply + VIRTUAL_SHARES)) / (assets - feeAlpha);
        if (feeShares == 0) {
            m.highWaterPps = pps;
            return;
        }

        m.token.mint(to, feeShares);
        uint256 newPps = pricePerShare(netuid);
        m.highWaterPps = newPps;
        emit PerformanceFeeCharged(netuid, feeAlpha, feeShares, newPps);
    }

    function _toRao(uint256 weiAmount) private pure returns (uint256 rao) {
        rao = weiAmount / WEI_PER_RAO;
        if (rao == 0) revert DustAmount();
        // Reject rather than truncate: a sub-rao remainder would be stranded here
        // and silently credited to whoever redeems next.
        if (rao * WEI_PER_RAO != weiAmount) revert UnalignedAmount();
    }

    receive() external payable {}
}
