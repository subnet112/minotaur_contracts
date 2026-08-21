// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakingV2} from "./interfaces/IStakingV2.sol";
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

    uint256 public constant WEI_PER_RAO = 1e9;

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
        WrappedAlpha token;  // the ERC-20 face; address(0) until opened
    }

    mapping(uint256 => Market) public markets;

    address public governor;

    event MarketOpened(uint256 indexed netuid, bytes32 hotkey, address token);
    event Purchased(uint256 indexed netuid, bytes32 indexed beneficiary, uint256 taoWei, uint256 alphaOut);
    event PurchasedWrapped(uint256 indexed netuid, address indexed receiver, uint256 taoWei, uint256 alphaMinted, uint256 shares);
    event RedeemedWrapped(uint256 indexed netuid, address indexed who, uint256 shares, uint256 alphaBurned, uint256 taoWei);

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

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(bytes32 _coldkey, address _governor) {
        coldkey = _coldkey;
        governor = _governor;
    }

    // ── markets ──────────────────────────────────────────────────────────────

    /// Open a subnet for WRAPPED purchases. Only needed for the wrapped path —
    /// `purchase` works for any netuid with no setup, because it never holds a
    /// position and so has nothing to account for.
    ///
    /// The hotkey is fixed here and cannot be changed. All wAlpha<netuid> must be
    /// backed by ONE position or it is not fungible, and a vault that can move
    /// its own delegation is one whose holders must trust whoever triggers the
    /// move. Re-delegation costs nothing mechanically (moveStake preserves alpha
    /// 1:1, measured on a fork) so this is purely a governance choice, and the
    /// conservative one is taken until it is deliberately revisited.
    function openMarket(uint256 netuid, bytes32 hotkey, string calldata name, string calldata symbol)
        external onlyGovernor returns (address token)
    {
        if (address(markets[netuid].token) != address(0)) revert MarketAlreadyOpen();
        WrappedAlpha t = new WrappedAlpha(netuid, name, symbol);
        markets[netuid] = Market({hotkey: hotkey, token: t});
        emit MarketOpened(netuid, hotkey, address(t));
        return address(t);
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
        Market memory m = markets[netuid];
        if (address(m.token) == address(0)) revert MarketNotOpen();
        uint256 rao = _toRao(msg.value);

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
        Market memory m = markets[netuid];
        if (address(m.token) == address(0)) revert MarketNotOpen();
        if (shares == 0) revert ZeroShares();

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

    function _toRao(uint256 weiAmount) private pure returns (uint256 rao) {
        rao = weiAmount / WEI_PER_RAO;
        if (rao == 0) revert DustAmount();
        // Reject rather than truncate: a sub-rao remainder would be stranded here
        // and silently credited to whoever redeems next.
        if (rao * WEI_PER_RAO != weiAmount) revert UnalignedAmount();
    }

    receive() external payable {}
}
