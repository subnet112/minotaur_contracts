// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAppIntentBase.sol";
import "./interfaces/IAppRegistry.sol";
import "./interfaces/IValidatorRegistry.sol";
import "./EphemeralProxy.sol";
import "./EIP712Verifier.sol";

/// @notice Minimal WETH9 interface for native token wrapping.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title AppIntentBase - Base contract for all Minotaur App Intent contracts
/// @notice Enforces user signature verification, N-of-M validator quorum,
///         ephemeral proxy execution, replay protection, intent registration,
///         and cross-chain escrow for multi-leg intents.
///         All App contracts inherit from this.
///
///         Fee enforcement:
///         The base contract makes protocol-fee settlement NON-OVERRIDABLE.
///         Apps customize only the fee AMOUNT via `_calculateProtocolFee`,
///         which the base then CLAMPS to [minPlatformFeeWei, maxPlatformFeeWei]
///         before settling. The settlement path itself (`_settleProtocolFeePre`
///         / `_verifyFeeSettlementPost`) is `private` and cannot be skipped.
///
///         Two payment patterns are supported:
///         - FeeMode.USER: fee is pulled directly from the user via
///           safeTransferFrom(user, platformFeeCollector, fee). Suitable when
///           the user holds the wrapped native token and is Bittensor-aware.
///         - FeeMode.APP: the base snapshots `platformFeeCollector` balance,
///           runs `_handleIntent`, and requires the collector balance to have
///           grown by at least the owed fee. The app is responsible for
///           sourcing the payment during its intent logic (typically from
///           swap surplus or its own paymaster). Suitable for consumer-facing
///           apps whose users do not hold the wrapped native token.
abstract contract AppIntentBase is IAppIntentBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── EIP-712 ──────────────────────────────────────────────────────────

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── State ────────────────────────────────────────────────────────────

    address public immutable relayer;
    address public immutable validatorRegistry;
    IAppRegistry public immutable appRegistry;   // address(0) = registry check disabled
    uint256 public quorumBps;          // e.g. 8000 = 80%
    uint256 public scoreThreshold;     // BPS, default 5000

    // ── Platform fee state ──────────────────────────────────────────────

    /// @notice Who pays the protocol fee on each order.
    enum FeeMode {
        USER,   // Pulled directly from the user (user signed the fee amount).
        APP     // Delivered by the app to the collector during _handleIntent.
    }

    IERC20 public immutable wrappedNativeToken;   // WETH on Ethereum/Base, WTAO on BT EVM
    address public platformFeeCollector;          // protocol treasury / FeeSplitter
    uint256 public maxPlatformFeeWei;             // safety cap (protects users from runaway orders)
    uint256 public minPlatformFeeWei;             // protocol floor (protects subnet from fee=0 orders)
    FeeMode public feeMode;                       // who pays — USER or APP
    address public appPaymaster;                  // when feeMode == APP, recommended source of funds
                                                  // (informational — the base only checks the collector
                                                  //  balance delta, not where the funds came from)

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executedOrders;        // one-shot replay
    mapping(bytes32 => uint256) public executionCounts;    // perpetual tracking
    mapping(bytes32 => uint256) public lastFilledAt;       // perpetual cooldown
    mapping(bytes4 => bool) public registeredIntents;      // allowed intent selectors
    mapping(bytes32 => mapping(uint256 => bool)) public legExecuted;  // orderId → legIndex → done

    // ── Escrow state (multi-leg cross-chain) ────────────────────────────

    struct EscrowDeposit {
        address token;
        uint256 amount;
        address user;
        uint256 deadline;
        bool released;
        bool refunded;
    }

    mapping(bytes32 => mapping(uint256 => EscrowDeposit)) public escrow;

    event PlatformFeeCollected(
        bytes32 indexed orderId,
        address indexed user,
        uint256 amount
    );

    event FeeModeUpdated(FeeMode mode);
    event AppPaymasterUpdated(address indexed paymaster);
    event MinPlatformFeeUpdated(uint256 minFeeWei);
    event MaxPlatformFeeUpdated(uint256 maxFeeWei);
    event PlatformFeeCollectorUpdated(address indexed collector);

    event EscrowDeposited(
        bytes32 indexed orderId, uint256 legIndex,
        address token, uint256 amount, address user, uint256 deadline
    );
    event EscrowReleased(bytes32 indexed orderId, uint256 legIndex, address token, uint256 amount);
    event EscrowRefunded(bytes32 indexed orderId, uint256 legIndex, address token, uint256 amount, address user);

    // ── Constructor ──────────────────────────────────────────────────────

    /// @notice Initialize the platform contract.
    /// @param _relayer Trusted relayer address (submits transactions, runs admin).
    /// @param _validatorRegistry Address of the ValidatorRegistry.
    /// @param _quorumBps Required quorum in BPS (e.g. 8000 = 80%).
    /// @param _scoreThreshold Minimum on-chain plan score in BPS (>= 5000).
    /// @param _wrappedNativeToken WETH on EVM chains, WTAO on Bittensor EVM.
    /// @param _platformFeeCollector Where protocol fees flow (treasury / FeeSplitter).
    /// @param _minPlatformFeeWei Floor on protocol fee — protects against fee=0 orders.
    /// @param _maxPlatformFeeWei Cap on protocol fee — protects against runaway charges.
    /// @param _feeMode FeeMode.USER (pull from user) or FeeMode.APP (verify collector balance grew).
    /// @param _appPaymaster Optional informational pointer to the app's funding source
    ///        when _feeMode == APP. Apps may use this for off-chain monitoring; the contract
    ///        does not enforce funds come from this exact address — only that the collector
    ///        balance increased by at least the owed amount during _handleIntent.
    /// @param _appRegistry Address of the AppRegistry that authorises this App. When set
    ///        to a non-zero address, executeIntent / executeLeg require the contract to
    ///        be registered in `appRegistry.appByContract` or revert. address(0) disables
    ///        the check — intended for test fixtures and pre-registry deployments.
    constructor(
        address _relayer,
        address _validatorRegistry,
        uint256 _quorumBps,
        uint256 _scoreThreshold,
        address _wrappedNativeToken,
        address _platformFeeCollector,
        uint256 _minPlatformFeeWei,
        uint256 _maxPlatformFeeWei,
        FeeMode _feeMode,
        address _appPaymaster,
        address _appRegistry
    ) {
        require(_relayer != address(0), "Invalid relayer");
        require(_validatorRegistry != address(0), "Invalid registry");
        require(_quorumBps > 0 && _quorumBps <= 10000, "Invalid quorum");
        require(_minPlatformFeeWei <= _maxPlatformFeeWei, "Min fee exceeds max");

        relayer = _relayer;
        validatorRegistry = _validatorRegistry;
        appRegistry = IAppRegistry(_appRegistry);
        quorumBps = _quorumBps;
        scoreThreshold = _scoreThreshold >= 5000 ? _scoreThreshold : 5000;

        // Platform fee setup (zero collector = fees effectively disabled if both floors zero)
        wrappedNativeToken = IERC20(_wrappedNativeToken);
        platformFeeCollector = _platformFeeCollector;
        minPlatformFeeWei = _minPlatformFeeWei;
        maxPlatformFeeWei = _maxPlatformFeeWei;
        feeMode = _feeMode;
        appPaymaster = _appPaymaster;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("MinotaurAppIntent"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /// @notice Revert if the registry is configured and this contract is not
    ///         registered (or has been revoked). When appRegistry is the
    ///         zero address, the check is bypassed entirely.
    function _requireRegistered() internal view {
        if (address(appRegistry) != address(0)) {
            require(
                appRegistry.appByContract(address(this)) != bytes32(0),
                "App not registered"
            );
        }
    }

    // ── Core execution ───────────────────────────────────────────────────

    /// @notice Execute an intent order with validator consensus
    /// @param order The user's signed intent order
    /// @param plan The execution plan generated by the solving engine
    /// @param userSignature EIP-712 signature from the user
    /// @param validatorSignatures Sorted ECDSA signatures from validators
    function executeIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        uint256 startGas = gasleft();

        // 1. Verify intent function is registered
        require(registeredIntents[order.intentSelector], "Intent not registered");

        // 1b. Verify this App contract is authorised by the registry. Cheap
        //     external view; skipped entirely when appRegistry == address(0)
        //     for test fixtures and pre-registry deployments.
        _requireRegistered();

        // 2. Check chain and deadline
        require(order.chainId == block.chainid, "Wrong chain");
        require(block.timestamp <= order.deadline, "Order expired");

        // 3. Replay protection
        if (order.perpetual) {
            require(
                executionCounts[order.orderId] < order.maxExecutions,
                "Max executions reached"
            );
            if (executionCounts[order.orderId] > 0) {
                require(
                    block.timestamp >= lastFilledAt[order.orderId] + order.cooldown,
                    "Cooldown not elapsed"
                );
            }
        } else {
            require(!executedOrders[order.orderId], "Already executed");
        }

        // 4. Verify per-user nonce (skip when sentinel value type(uint256).max
        //    is used, allowing multiple concurrent orders per user)
        if (order.nonce != type(uint256).max) {
            require(order.nonce == nonces[order.submittedBy], "Invalid nonce");
        }

        // 5. Verify user EIP-712 signature
        require(
            EIP712Verifier.verifyUserSignature(order, userSignature, DOMAIN_SEPARATOR),
            "Invalid user signature"
        );

        // 6. Verify validator quorum
        bytes32 planHash = EIP712Verifier.hashPlan(plan);
        uint256 validatorCount = IValidatorRegistry(validatorRegistry).getValidatorCount();
        uint256 quorumRequired = (validatorCount * quorumBps + 9999) / 10000;
        uint256 validSigs = EIP712Verifier.verifyValidatorSignatures(
            order.orderId,
            planHash,
            scoreThreshold,
            validatorSignatures,
            validatorRegistry,
            DOMAIN_SEPARATOR
        );
        require(validSigs >= quorumRequired, "Insufficient quorum");

        // 7. Protocol fee — pre-handle settlement (pulls or snapshots, never skipped).
        (uint256 feeOwed, uint256 collectorBefore) = _settleProtocolFeePre(order);

        // 8-9. Execute plan and check intent via dispatch
        (uint256 score, bool valid) = _handleIntent(order, plan);
        require(valid, "Intent invariant check failed");

        // 10. Enforce on-chain score threshold
        require(score >= scoreThreshold, "Score below threshold");

        // 10b. Protocol fee — post-handle verification (APP mode only).
        _verifyFeeSettlementPost(order.orderId, order.submittedBy, feeOwed, collectorBefore);

        // 11. Update state (only increment nonce when not using sentinel)
        if (order.nonce != type(uint256).max) {
            nonces[order.submittedBy]++;
        }
        if (order.perpetual) {
            executionCounts[order.orderId]++;
            lastFilledAt[order.orderId] = block.timestamp;
        } else {
            executedOrders[order.orderId] = true;
        }

        uint256 gasUsed = startGas - gasleft();
        emit IntentExecuted(order.orderId, order.submittedBy, score, planHash, gasUsed);
    }

    // ── Multi-leg execution ─────────────────────────────────────────────────

    event IntentLegExecuted(
        bytes32 indexed orderId,
        address indexed submittedBy,
        uint256 legIndex,
        uint256 score,
        bytes32 planHash,
        uint256 gasUsed
    );

    /// @notice Execute a single leg of a multi-leg intent order.
    /// @dev For intents requiring multiple transactions (cross-chain, multi-step).
    ///      Each leg is independently validated:
    ///      - User signature (if provided, verified against order hash)
    ///      - Validator quorum for this leg's specific plan
    ///      - App invariant check via _handleIntent
    ///      Leg sequencing is enforced by the platform (blockloop/relayer),
    ///      not on-chain. The contract only tracks per-leg replay protection.
    ///      Used for both forward execution and rollback legs.
    /// @param order The intent order (same across all legs)
    /// @param plan The execution plan for THIS leg only
    /// @param legIndex Leg identifier (0-indexed, used for replay protection)
    /// @param userSignature EIP-712 signature from the user (empty = testnet fallback)
    /// @param validatorSignatures Sorted ECDSA signatures from validators
    function executeLeg(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        _executeLegInternal(order, plan, legIndex, userSignature, validatorSignatures);
    }

    /// @notice Deprecated: use executeLeg instead.
    function executeCrossChainLeg(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        _executeLegInternal(order, plan, legIndex, userSignature, validatorSignatures);
    }

    function _executeLegInternal(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) internal {
        uint256 startGas = gasleft();

        // 1. Verify intent function is registered
        require(registeredIntents[order.intentSelector], "Intent not registered");

        // 1b. Verify this App contract is authorised by the registry.
        _requireRegistered();

        // 2. Check chain and deadline
        require(order.chainId == block.chainid, "Wrong chain");
        require(block.timestamp <= order.deadline, "Order expired");

        // 3. Per-leg replay protection
        require(!legExecuted[order.orderId][legIndex], "Leg already executed");

        // 3b. Escrow gate: if bridged funds were deposited for this leg,
        //     require explicit release before execution proceeds.
        //     For non-escrowed legs (source legs, single-chain), this is a
        //     cold storage read of amount=0 and passes (~2100 gas).
        if (escrow[order.orderId][legIndex].amount > 0) {
            require(escrow[order.orderId][legIndex].released, "Escrow not released");
        }

        // 4. Verify user signature (required on mainnet, optional on testnet)
        if (userSignature.length > 0) {
            require(
                EIP712Verifier.verifyUserSignature(order, userSignature, DOMAIN_SEPARATOR),
                "Invalid user signature"
            );
        } else {
            // Empty signature allowed only when validator quorum serves as
            // authorization (multi-leg intents where user signed the overall
            // order on the source chain). Validator quorum check below
            // provides the authorization gate.
        }

        // 5. Verify validator quorum for THIS leg's plan
        bytes32 planHash = EIP712Verifier.hashPlan(plan);
        uint256 validatorCount = IValidatorRegistry(validatorRegistry).getValidatorCount();
        uint256 quorumRequired = (validatorCount * quorumBps + 9999) / 10000;
        uint256 validSigs = EIP712Verifier.verifyValidatorSignatures(
            order.orderId,
            planHash,
            scoreThreshold,
            validatorSignatures,
            validatorRegistry,
            DOMAIN_SEPARATOR
        );
        require(validSigs >= quorumRequired, "Insufficient quorum");

        // 6. Protocol fee — pre-handle settlement.
        (uint256 feeOwed, uint256 collectorBefore) = _settleProtocolFeePre(order);

        // 7. Execute plan and check intent
        (uint256 score, bool valid) = _handleIntent(order, plan);
        require(valid, "Intent invariant check failed");
        require(score >= scoreThreshold, "Score below threshold");

        // 7b. Protocol fee — post-handle verification (APP mode only).
        _verifyFeeSettlementPost(order.orderId, order.submittedBy, feeOwed, collectorBefore);

        // 8. Mark this leg as executed
        legExecuted[order.orderId][legIndex] = true;

        uint256 gasUsed = startGas - gasleft();
        emit IntentLegExecuted(order.orderId, order.submittedBy, legIndex, score, planHash, gasUsed);
    }

    // ── Internal: plan execution primitives ────────────────────────────────

    /// @notice Deploy an EphemeralProxy for this order.
    function _deployProxy(IntentOrder calldata order) internal returns (address) {
        return address(new EphemeralProxy{salt: _proxySalt(order)}());
    }

    /// @notice Execute plan calls through an already-deployed proxy.
    function _runPlan(address proxy, ExecutionPlan calldata plan) internal {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < plan.calls.length; i++) {
            totalValue += plan.calls[i].value;
        }
        EphemeralProxy(payable(proxy)).execute{value: totalValue}(plan.calls);
    }

    /// @notice Deploy proxy and execute plan in one call (convenience).
    function _executePlan(IntentOrder calldata order, ExecutionPlan calldata plan) internal virtual returns (address) {
        address proxy = _deployProxy(order);
        _runPlan(proxy, plan);
        return proxy;
    }

    /// @notice Override to check invariants and return score.
    /// @dev Apps that override _handleIntent directly can skip this.
    function _checkIntent(
        IntentOrder calldata /* order */,
        ExecutionPlan calldata /* plan */,
        address /* proxy */
    ) internal virtual returns (uint256, bool) {
        revert("_checkIntent not implemented");
    }

    /// @notice Execute plan and check intent invariants.
    /// @dev Default calls _executePlan + _checkIntent (backward compat).
    ///      Override to dispatch to real intent functions based on intentSelector.
    function _handleIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan
    ) internal virtual returns (uint256 score, bool valid) {
        address proxy = _executePlan(order, plan);
        return _checkIntent(order, plan, proxy);
    }

    /// @notice Derive CREATE2 salt for the EphemeralProxy.
    function _proxySalt(IntentOrder calldata order) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(order.orderId, executionCounts[order.orderId]));
    }

    // ── Developer helpers ─────────────────────────────────────────────────

    /// @notice Snapshot a token's balance for later comparison via _gained()
    mapping(address => uint256) private _balanceSnapshots;

    function _snapshot(address token) internal {
        _balanceSnapshots[token] = IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns how much of `token` was gained since the last _snapshot()
    function _gained(address token) internal view returns (uint256) {
        uint256 current = IERC20(token).balanceOf(address(this));
        uint256 pre = _balanceSnapshots[token];
        return current >= pre ? current - pre : 0;
    }

    /// @notice Standard linear score: 5000 at `minimum`, 10000 at 2x, capped
    function _scoreLinear(uint256 actual, uint256 minimum) internal pure returns (uint256) {
        if (actual < minimum) return 0;
        if (actual >= minimum * 2) return 10000;
        return 5000 + ((actual - minimum) * 5000) / minimum;
    }

    /// @notice Deploy proxy, fund it with tokens, execute plan.
    /// @dev Two funding paths:
    ///      1. Native (msg.value > 0, token == wrappedNativeToken): wraps msg.value
    ///         to WETH, sends to proxy. Refunds any excess.
    ///      2. ERC-20 (default): pulls `amount` from `from` via safeTransferFrom.
    ///      The native path enables seamless one-transaction ETH swaps where the
    ///      user calls executeIntent directly with msg.value.
    function _fundAndExecute(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        address token,
        address from,
        uint256 amount
    ) internal returns (address proxy) {
        proxy = _deployProxy(order);
        if (msg.value > 0 && token == address(wrappedNativeToken)) {
            // Native ETH/TAO path: wrap msg.value → WETH → send to proxy
            require(msg.value >= amount, "Insufficient msg.value");
            IWETH(address(wrappedNativeToken)).deposit{value: amount}();
            IERC20(token).safeTransfer(proxy, amount);
            // Refund excess ETH to the submitter
            if (msg.value > amount) {
                (bool sent,) = payable(from).call{value: msg.value - amount}("");
                require(sent, "Refund failed");
            }
        } else {
            IERC20(token).safeTransferFrom(from, proxy, amount);
        }
        _runPlan(proxy, plan);
    }

    // ── Cross-chain escrow ─────────────────────────────────────────────────
    //
    // For multi-leg intents, bridged funds land in this contract and are held
    // in escrow until post-bridge validation passes. This prevents the
    // "leg 1 succeeds, leg 2 fails, funds lost" attack vector.
    //
    // Flow:
    //   1. Bridge delivers tokens to this contract on destination chain
    //   2. Relayer calls escrowDeposit() to register the deposit
    //   3. Validators re-quote at current prices, verify slippage is acceptable
    //   4. Relayer calls escrowRelease() with validator quorum signatures
    //   5. executeLeg() proceeds (escrow gate passes)
    //   6. If anything fails or times out, user calls escrowRefund() after deadline

    /// @notice Register bridged tokens received for a multi-leg escrow.
    /// @dev Called by the relayer after bridge delivery confirms. The relayer
    ///      must snapshot the token balance before bridge delivery, then call
    ///      this after delivery so the contract can measure the received amount.
    /// @param orderId The intent order these funds belong to
    /// @param legIndex The destination leg that will consume these funds
    /// @param token The bridged token address on this chain
    /// @param amount The amount received from the bridge
    /// @param user The original order submitter (receives refund on timeout)
    /// @param deadline Timestamp after which user can claim a refund
    function escrowDeposit(
        bytes32 orderId,
        uint256 legIndex,
        address token,
        uint256 amount,
        address user,
        uint256 deadline
    ) external onlyRelayer nonReentrant {
        require(amount > 0, "Zero amount");
        require(escrow[orderId][legIndex].amount == 0, "Already deposited");
        require(deadline > block.timestamp, "Deadline in past");
        require(user != address(0), "Invalid user");

        // Verify the contract actually holds these tokens
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "Insufficient token balance for escrow"
        );

        escrow[orderId][legIndex] = EscrowDeposit({
            token: token,
            amount: amount,
            user: user,
            deadline: deadline,
            released: false,
            refunded: false
        });

        emit EscrowDeposited(orderId, legIndex, token, amount, user, deadline);
    }

    /// @notice Release escrowed funds for destination leg execution.
    /// @dev Called by the relayer after post-bridge validation passes and
    ///      validators sign off. Once released, executeLeg() can proceed.
    ///      Tokens remain in the contract for the execution plan to use.
    /// @param orderId The intent order
    /// @param legIndex The destination leg to release funds for
    /// @param validatorSignatures Validator quorum approving the release
    /// @param releaseHash Hash of the release parameters for signature verification.
    ///        Computed as: keccak256(abi.encodePacked(orderId, legIndex, token, amount))
    function escrowRelease(
        bytes32 orderId,
        uint256 legIndex,
        bytes[] calldata validatorSignatures,
        bytes32 releaseHash
    ) external onlyRelayer nonReentrant {
        EscrowDeposit storage dep = escrow[orderId][legIndex];
        require(dep.amount > 0, "No deposit");
        require(!dep.released && !dep.refunded, "Already settled");
        require(block.timestamp <= dep.deadline, "Expired: user must claim refund");

        // Verify validator quorum approves this release
        uint256 validatorCount = IValidatorRegistry(validatorRegistry).getValidatorCount();
        uint256 quorumRequired = (validatorCount * quorumBps + 9999) / 10000;
        uint256 validSigs = EIP712Verifier.verifyValidatorSignatures(
            orderId,
            releaseHash,
            scoreThreshold,
            validatorSignatures,
            validatorRegistry,
            DOMAIN_SEPARATOR
        );
        require(validSigs >= quorumRequired, "Insufficient quorum for release");

        dep.released = true;
        emit EscrowReleased(orderId, legIndex, dep.token, dep.amount);
    }

    /// @notice Claim refund of escrowed funds after deadline expiry.
    /// @dev Permissionless for the original user. No relayer or validator
    ///      approval needed — just the deadline passing. This ensures users
    ///      can always recover bridged funds if the destination leg fails,
    ///      times out, or is never executed.
    /// @param orderId The intent order
    /// @param legIndex The leg whose escrow to refund
    function escrowRefund(bytes32 orderId, uint256 legIndex) external nonReentrant {
        EscrowDeposit storage dep = escrow[orderId][legIndex];
        require(dep.amount > 0, "No deposit");
        require(!dep.released && !dep.refunded, "Already settled");
        require(block.timestamp > dep.deadline, "Not expired yet");
        require(msg.sender == dep.user, "Not the depositor");

        dep.refunded = true;
        IERC20(dep.token).safeTransfer(dep.user, dep.amount);

        emit EscrowRefunded(orderId, legIndex, dep.token, dep.amount, dep.user);
    }

    /// @notice Check escrow status for a specific order leg.
    function getEscrow(bytes32 orderId, uint256 legIndex) external view returns (
        address token, uint256 amount, address user,
        uint256 deadline, bool released, bool refunded
    ) {
        EscrowDeposit storage dep = escrow[orderId][legIndex];
        return (dep.token, dep.amount, dep.user, dep.deadline, dep.released, dep.refunded);
    }

    // ── Simulation helper ──────────────────────────────────────────────────

    /// @notice Score a plan for off-chain simulation (Anvil fork).
    /// @dev Runs _handleIntent (execute + check). No signature/nonce/replay checks.
    ///      Called within simulator snapshot (reverted after).
    ///      Restricted to relayer to prevent unauthorized execution.
    ///
    ///      Fee accounting matches executeIntent: pre-handle settle, post-handle
    ///      verify. The fork is reverted after simulation, so no real tokens move
    ///      but the validator can confirm the fee path WORKS for this order.
    function scoreIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan
    ) external virtual onlyRelayer nonReentrant returns (uint256 score, bool valid) {
        (uint256 feeOwed, uint256 collectorBefore) = _settleProtocolFeePre(order);
        (score, valid) = _handleIntent(order, plan);
        if (valid) {
            _verifyFeeSettlementPost(order.orderId, order.submittedBy, feeOwed, collectorBefore);
        }
    }

    // ── Admin (relayer only) ─────────────────────────────────────────────

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Only relayer");
        _;
    }

    /// @notice Register an intent function selector (APP-7)
    /// @param selector The 4-byte function selector to register
    function registerIntent(bytes4 selector) external onlyRelayer {
        require(selector != bytes4(0), "Invalid selector");
        registeredIntents[selector] = true;
    }

    /// @notice Minimum allowed score threshold: 5000 BPS (0.5/1.0).
    ///         Prevents attackers from lowering the threshold to accept
    ///         low-quality or value-extracting plans.
    uint256 public constant MIN_SCORE_THRESHOLD = 5000;

    function updateScoreThreshold(uint256 _threshold) external onlyRelayer {
        require(_threshold >= MIN_SCORE_THRESHOLD && _threshold <= 10000, "Threshold must be 5000-10000");
        scoreThreshold = _threshold;
    }

    function setPlatformFeeCollector(address _collector) external onlyRelayer {
        require(_collector != address(0), "Invalid collector");
        platformFeeCollector = _collector;
        emit PlatformFeeCollectorUpdated(_collector);
    }

    function setMaxPlatformFeeWei(uint256 _maxFee) external onlyRelayer {
        require(_maxFee >= minPlatformFeeWei, "Max below min");
        maxPlatformFeeWei = _maxFee;
        emit MaxPlatformFeeUpdated(_maxFee);
    }

    function setMinPlatformFeeWei(uint256 _minFee) external onlyRelayer {
        require(_minFee <= maxPlatformFeeWei, "Min above max");
        minPlatformFeeWei = _minFee;
        emit MinPlatformFeeUpdated(_minFee);
    }

    function setFeeMode(FeeMode _mode) external onlyRelayer {
        feeMode = _mode;
        emit FeeModeUpdated(_mode);
    }

    function setAppPaymaster(address _paymaster) external onlyRelayer {
        appPaymaster = _paymaster;
        emit AppPaymasterUpdated(_paymaster);
    }

    // ── Platform fee internals ──────────────────────────────────────────

    /// @notice Default fee decoder — reads the last 32 bytes of intentParams.
    ///         Apps whose intentParams encoding does NOT end with
    ///         `uint256 platformFeeWei` must override `_calculateProtocolFee`
    ///         instead of relying on this helper.
    function _decodePlatformFee(bytes calldata intentParams) internal pure returns (uint256) {
        if (intentParams.length < 32) return 0;
        return abi.decode(intentParams[intentParams.length - 32:], (uint256));
    }

    /// @notice Compute the protocol fee for this order, in wrappedNativeToken wei.
    /// @dev Apps override this to customize the AMOUNT — e.g. to decode a different
    ///      position in intentParams, or compute from plan complexity. The returned
    ///      value is then clamped to [minPlatformFeeWei, maxPlatformFeeWei] by the
    ///      base, so apps CANNOT bypass the floor or exceed the cap.
    ///      Default implementation reads the last 32 bytes of intentParams.
    function _calculateProtocolFee(
        IntentOrder calldata order
    ) internal view virtual returns (uint256) {
        return _decodePlatformFee(order.intentParams);
    }

    /// @dev Strictly validate that the candidate fee lies in the configured
    ///      [min, max] range. Reverts on out-of-bounds so the user's signed
    ///      order is honoured exactly — never silently re-priced.
    ///      App overrides of `_calculateProtocolFee` and `_swap`-style flows
    ///      call this BEFORE attempting the actual transfer, so a mismatch
    ///      between the off-chain price quote and the on-chain configuration
    ///      surfaces as a clear revert rather than an unexpected charge.
    function _clampFee(uint256 feeWei) internal view returns (uint256) {
        require(feeWei <= maxPlatformFeeWei, "Fee exceeds cap");
        require(feeWei >= minPlatformFeeWei, "Fee below floor");
        return feeWei;
    }

    /// @notice Settle the protocol fee BEFORE _handleIntent runs.
    /// @dev Private — non-overridable. Apps customize only the amount via
    ///      `_calculateProtocolFee`. The settlement path itself cannot be skipped.
    ///
    ///      USER mode: pulls fee from user via safeTransferFrom. Atomic — if user
    ///        lacks balance/allowance the entire executeIntent reverts.
    ///        Skipped only on native-input swaps (msg.value > 0) — the user is
    ///        paying via msg.value and has no separate WETH to pull from.
    ///      APP mode: returns (feeOwed, balanceBefore). The base re-checks AFTER
    ///        `_handleIntent` that the collector balance grew by at least feeOwed.
    ///
    /// @return feeOwed The fee amount still owed AFTER this call (0 if settled
    ///         here in USER mode or skipped on native input).
    /// @return collectorBefore Snapshot of platformFeeCollector's balance in
    ///         wrappedNativeToken at the start of execution (0 when not in APP mode).
    function _settleProtocolFeePre(
        IntentOrder calldata order
    ) private returns (uint256 feeOwed, uint256 collectorBefore) {
        uint256 raw = _calculateProtocolFee(order);
        feeOwed = _clampFee(raw);

        if (feeOwed == 0) return (0, 0);
        require(platformFeeCollector != address(0), "No fee collector");

        if (feeMode == FeeMode.USER) {
            // Native input path: user has no WETH to pull from. Apps that want
            // to charge a fee in native-input flows must override
            // `_calculateProtocolFee` to return 0 in that case, OR run in APP
            // mode and source the fee from msg.value internally.
            if (msg.value > 0) return (0, 0);

            wrappedNativeToken.safeTransferFrom(order.submittedBy, platformFeeCollector, feeOwed);
            emit PlatformFeeCollected(order.orderId, order.submittedBy, feeOwed);
            return (0, 0);
        }

        // APP mode — leave the obligation for _verifyFeeSettlementPost.
        collectorBefore = wrappedNativeToken.balanceOf(platformFeeCollector);
        return (feeOwed, collectorBefore);
    }

    /// @notice Verify the protocol fee was delivered in APP mode.
    /// @dev Private — non-overridable. Reverts the entire transaction if the
    ///      collector balance did not grow by at least the owed amount. This
    ///      makes the fee MANDATORY — the app cannot skip or reduce it without
    ///      reverting the order (which makes the user whole).
    function _verifyFeeSettlementPost(
        bytes32 orderId,
        address user,
        uint256 feeOwed,
        uint256 collectorBefore
    ) private {
        if (feeOwed == 0) return;
        uint256 collectorAfter = wrappedNativeToken.balanceOf(platformFeeCollector);
        require(collectorAfter >= collectorBefore + feeOwed, "Protocol fee not paid");
        emit PlatformFeeCollected(orderId, user, collectorAfter - collectorBefore);
    }

    // ── Views ────────────────────────────────────────────────────────────

    function getValidators() external view returns (address[] memory) {
        return IValidatorRegistry(validatorRegistry).getValidators();
    }

    function getQuorumRequired() external view returns (uint256) {
        uint256 n = IValidatorRegistry(validatorRegistry).getValidatorCount();
        return (n * quorumBps + 9999) / 10000;
    }

    /// @notice Accept ETH for execution plans that need value
    receive() external payable {}
}
