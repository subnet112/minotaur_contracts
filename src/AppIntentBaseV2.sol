// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAppIntentBase.sol";
import "./interfaces/IAppRegistry.sol";
import "./interfaces/IValidatorRegistry.sol";
import "./EIP712Verifier.sol";
import {IWETH} from "./AppIntentBase.sol";
import "./ExecutorProxy.sol";

/// @title AppIntentBaseV2 - Gas-optimized AppIntentBase (candidate upstream changes)
/// @notice Behavior-compatible with AppIntentBase: the EIP-712 signing schema,
///         validator attestation format, fee enforcement, and escrow flows are
///         all UNCHANGED — existing signed orders and validator tooling work
///         as-is. Four gas changes, each marked with a `V2:` comment:
///
///         1. Per-order EIP-1167 clones of a one-time ExecutorProxy
///            implementation replace the full-bytecode EphemeralProxy CREATE2
///            deploy (~45k vs ~165k per execution). Same salt derivation and
///            the same structural guarantee as V1: each order executes on a
///            fresh address that is never funded again, so dangling approvals
///            left by a plan are worthless by construction.
///
///         2. `executedOrders` is only checked/written for sentinel-nonce
///            orders. For nonced orders the enforced, incrementing nonce
///            already makes replay impossible, so the extra SSTORE (~22k) is
///            redundant. NOTE: `executedOrders(orderId)` no longer returns
///            true for completed nonced orders — indexers must use the
///            IntentExecuted event (they already should).
///
///         3. Balance snapshots (`_snapshot`/`_gained`) live in EIP-1153
///            transient storage instead of a storage mapping. Saves a
///            22.1k/5k SSTORE per swap; the value is only ever needed within
///            one transaction.
///
///         4. ReentrancyGuardTransient replaces the storage-based guard
///            (~5k net per call).
abstract contract AppIntentBaseV2 is IAppIntentBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ── EIP-712 ──────────────────────────────────────────────────────────

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── State ────────────────────────────────────────────────────────────

    address public immutable relayer;
    address public immutable validatorRegistry;
    IAppRegistry public immutable appRegistry;   // address(0) = registry check disabled
    uint256 public scoreThreshold;     // BPS, default 5000

    /// @notice V2: executor implementation, deployed once. Each order runs on
    ///         a fresh EIP-1167 clone of it (see _deployProxy).
    address public immutable executorImplementation;

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

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executedOrders;        // V2: sentinel-nonce orders only
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

    constructor(
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
    ) {
        require(_relayer != address(0), "Invalid relayer");
        require(_validatorRegistry != address(0), "Invalid registry");
        require(_minPlatformFeeWei <= _maxPlatformFeeWei, "Min fee exceeds max");

        relayer = _relayer;
        validatorRegistry = _validatorRegistry;
        appRegistry = IAppRegistry(_appRegistry);
        scoreThreshold = _scoreThreshold >= 5000 ? _scoreThreshold : 5000;

        wrappedNativeToken = IERC20(_wrappedNativeToken);
        platformFeeCollector = _platformFeeCollector;
        minPlatformFeeWei = _minPlatformFeeWei;
        maxPlatformFeeWei = _maxPlatformFeeWei;
        feeMode = _feeMode;
        appPaymaster = _appPaymaster;

        // V2: one-time implementation deployment; per-order clones are cheap.
        executorImplementation = address(new ExecutorProxy());

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("MinotaurAppIntent"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    function _requireRegistered() internal view {
        if (address(appRegistry) != address(0)) {
            require(
                appRegistry.appByContract(address(this)) != bytes32(0),
                "App not registered"
            );
        }
    }

    // ── Core execution ───────────────────────────────────────────────────

    function executeIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        uint256 startGas = gasleft();

        // 1. Verify intent function is registered
        require(registeredIntents[order.intentSelector], "Intent not registered");

        // 1b. Verify this App contract is authorised by the registry.
        _requireRegistered();

        // 2. Check chain and deadline
        require(order.chainId == block.chainid, "Wrong chain");
        require(block.timestamp <= order.deadline, "Order expired");

        // 3. Replay protection.
        //    V2: for nonced one-shot orders, the nonce check below is already
        //    a complete replay guard (the signed nonce can never match again
        //    after the increment), so executedOrders is neither read nor
        //    written — saving a cold SLOAD + a fresh SSTORE (~24k). Only
        //    sentinel-nonce orders need the orderId bitmap.
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
        } else if (order.nonce == type(uint256).max) {
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
        uint256 quorumRequired = (validatorCount * IValidatorRegistry(validatorRegistry).quorumBps() + 9999) / 10000;
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
        } else if (order.nonce == type(uint256).max) {
            // V2: only sentinel-nonce orders need the orderId replay bitmap.
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

    /// @notice When true, every leg execution must go through
    ///         executeLegSigned — the user's plan-set signature becomes
    ///         mandatory and the legacy validator-quorum-only paths revert.
    ///         Deploys false (legacy-compatible); the platform flips it on
    ///         once its pipeline emits plan-set signatures, closing the
    ///         "destination leg executes with an empty user signature" hole
    ///         (docs/architecture/cross-chain-intents.md §5 in
    ///         minotaur_subnet).
    bool public planSetSignatureRequired;

    event PlanSetVerified(
        bytes32 indexed orderId,
        bytes32 planSetHash,
        uint256 legIndex,
        uint256 setPosition
    );

    function setPlanSetSignatureRequired(bool _required) external onlyRelayer {
        planSetSignatureRequired = _required;
    }

    function executeLeg(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        _executeLegInternal(order, plan, legIndex, userSignature, validatorSignatures, false);
    }

    /// @notice Deprecated: use executeLeg instead. Retained so V2 is a
    ///         drop-in for the current relayer, which still submits
    ///         destination legs through this selector (minotaur_subnet
    ///         evm_relayer/chain_config).
    function executeCrossChainLeg(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        _executeLegInternal(order, plan, legIndex, userSignature, validatorSignatures, false);
    }

    /// @notice Execute a leg under the user's PLAN-SET signature: the user
    ///         signed (once, at quote acceptance, chain-agnostic domain) the
    ///         ordered hashes of EVERY leg plan — forward legs first, then
    ///         revert/rollback legs. The executed plan must be a member of
    ///         that signed set, so neither the relayer nor a colluding
    ///         validator quorum can substitute a recovery path the user
    ///         never agreed to. Refreshed (re-quoted) legs require a fresh
    ///         signature over the updated set by construction.
    /// @param planSetHashes The full ordered plan-hash set the user signed.
    /// @param setPosition   This plan's index within planSetHashes.
    /// @param userSignature REQUIRED — signature over
    ///                      PlanSetApproval(orderId, keccak256(planSetHashes)).
    function executeLegSigned(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes32[] calldata planSetHashes,
        uint256 setPosition,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures
    ) external payable nonReentrant {
        require(userSignature.length > 0, "Plan-set signature required");
        require(setPosition < planSetHashes.length, "Set position out of range");
        require(
            planSetHashes[setPosition] == EIP712Verifier.hashPlan(plan),
            "Plan not in signed set"
        );
        bytes32 planSetHash = keccak256(abi.encodePacked(planSetHashes));
        require(
            EIP712Verifier.verifyPlanSetSignature(
                order.submittedBy, order.orderId, planSetHash, userSignature
            ),
            "Invalid plan-set signature"
        );
        emit PlanSetVerified(order.orderId, planSetHash, legIndex, setPosition);

        // Order-level user signature already superseded by the plan-set
        // approval — pass an empty calldata slice so the internal gauntlet
        // doesn't re-require a per-chain order signature the destination
        // chain can't have.
        _executeLegInternal(
            order, plan, legIndex, userSignature[0:0], validatorSignatures, true
        );
    }

    function _executeLegInternal(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        uint256 legIndex,
        bytes calldata userSignature,
        bytes[] calldata validatorSignatures,
        bool planSetVerified
    ) internal {
        uint256 startGas = gasleft();

        require(registeredIntents[order.intentSelector], "Intent not registered");
        _requireRegistered();
        require(order.chainId == block.chainid, "Wrong chain");
        require(block.timestamp <= order.deadline, "Order expired");

        // Per-leg replay protection (must stay in storage: legs span txs)
        require(!legExecuted[order.orderId][legIndex], "Leg already executed");

        // Enforcement: once armed, only the plan-set-signed path may execute
        // legs — quorum alone no longer suffices.
        if (planSetSignatureRequired) {
            require(planSetVerified, "Plan-set signature required");
        }

        if (escrow[order.orderId][legIndex].amount > 0) {
            require(escrow[order.orderId][legIndex].released, "Escrow not released");
        }

        if (userSignature.length > 0) {
            require(
                EIP712Verifier.verifyUserSignature(order, userSignature, DOMAIN_SEPARATOR),
                "Invalid user signature"
            );
        }

        bytes32 planHash = EIP712Verifier.hashPlan(plan);
        uint256 validatorCount = IValidatorRegistry(validatorRegistry).getValidatorCount();
        uint256 quorumRequired = (validatorCount * IValidatorRegistry(validatorRegistry).quorumBps() + 9999) / 10000;
        uint256 validSigs = EIP712Verifier.verifyValidatorSignatures(
            order.orderId,
            planHash,
            scoreThreshold,
            validatorSignatures,
            validatorRegistry,
            DOMAIN_SEPARATOR
        );
        require(validSigs >= quorumRequired, "Insufficient quorum");

        (uint256 feeOwed, uint256 collectorBefore) = _settleProtocolFeePre(order);

        (uint256 score, bool valid) = _handleIntent(order, plan);
        require(valid, "Intent invariant check failed");
        require(score >= scoreThreshold, "Score below threshold");

        _verifyFeeSettlementPost(order.orderId, order.submittedBy, feeOwed, collectorBefore);

        legExecuted[order.orderId][legIndex] = true;

        uint256 gasUsed = startGas - gasleft();
        emit IntentLegExecuted(order.orderId, order.submittedBy, legIndex, score, planHash, gasUsed);
    }

    // ── Internal: plan execution primitives ────────────────────────────────

    /// @notice V2: deploy a fresh EIP-1167 clone of the executor
    ///         implementation for this order. Same one-address-per-execution
    ///         model and salt derivation as V1's EphemeralProxy, at ~45k
    ///         instead of ~165k.
    function _deployProxy(IntentOrder calldata order) internal returns (address) {
        return Clones.cloneDeterministic(executorImplementation, _proxySalt(order));
    }

    /// @notice Derive CREATE2 salt for the executor clone (V1-compatible).
    function _proxySalt(IntentOrder calldata order) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(order.orderId, executionCounts[order.orderId]));
    }

    /// @notice Predict the executor clone address for an order's NEXT
    ///         execution — lets solvers reference the proxy address inside
    ///         plan calldata before it exists.
    function predictProxy(bytes32 orderId) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(orderId, executionCounts[orderId]));
        return Clones.predictDeterministicAddress(executorImplementation, salt, address(this));
    }

    /// @notice Execute plan calls through the executor.
    function _runPlan(address proxy, ExecutionPlan calldata plan) internal {
        uint256 totalValue = 0;
        for (uint256 i = 0; i < plan.calls.length; i++) {
            totalValue += plan.calls[i].value;
        }
        ExecutorProxy(payable(proxy)).execute{value: totalValue}(plan.calls);
    }

    /// @notice Execute plan through the persistent executor (convenience).
    function _executePlan(IntentOrder calldata order, ExecutionPlan calldata plan) internal virtual returns (address) {
        address proxy = _deployProxy(order);
        _runPlan(proxy, plan);
        return proxy;
    }

    function _checkIntent(
        IntentOrder calldata /* order */,
        ExecutionPlan calldata /* plan */,
        address /* proxy */
    ) internal virtual returns (uint256, bool) {
        revert("_checkIntent not implemented");
    }

    function _handleIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan
    ) internal virtual returns (uint256 score, bool valid) {
        address proxy = _executePlan(order, plan);
        return _checkIntent(order, plan, proxy);
    }

    // ── Developer helpers ─────────────────────────────────────────────────

    /// @dev V2: balance snapshots moved to EIP-1153 transient storage. The
    ///      value only ever lives within one transaction, so a storage
    ///      mapping (22.1k cold / 5k warm SSTORE per swap) is wasted; TSTORE
    ///      costs 100 gas. Namespace-keyed to avoid slot collisions.
    bytes32 private constant SNAPSHOT_NAMESPACE = keccak256("minotaur.v2.balanceSnapshot");

    function _snapshotSlot(address token) private pure returns (bytes32) {
        return keccak256(abi.encode(SNAPSHOT_NAMESPACE, token));
    }

    function _snapshot(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        bytes32 slot = _snapshotSlot(token);
        assembly {
            tstore(slot, bal)
        }
    }

    /// @notice Returns how much of `token` was gained since the last _snapshot()
    function _gained(address token) internal view returns (uint256) {
        uint256 current = IERC20(token).balanceOf(address(this));
        bytes32 slot = _snapshotSlot(token);
        uint256 pre;
        assembly {
            pre := tload(slot)
        }
        return current >= pre ? current - pre : 0;
    }

    /// @notice Standard linear score: 5000 at `minimum`, 10000 at 2x, capped
    function _scoreLinear(uint256 actual, uint256 minimum) internal pure returns (uint256) {
        if (actual < minimum) return 0;
        if (actual >= minimum * 2) return 10000;
        return 5000 + ((actual - minimum) * 5000) / minimum;
    }

    /// @notice Fund the executor with tokens, execute plan.
    function _fundAndExecute(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        address token,
        address from,
        uint256 amount
    ) internal returns (address proxy) {
        proxy = _deployProxy(order);
        if (msg.value > 0 && token == address(wrappedNativeToken)) {
            require(msg.value >= amount, "Insufficient msg.value");
            IWETH(address(wrappedNativeToken)).deposit{value: amount}();
            IERC20(token).safeTransfer(proxy, amount);
            if (msg.value > amount) {
                (bool sent,) = payable(from).call{value: msg.value - amount}("");
                require(sent, "Refund failed");
            }
        } else {
            IERC20(token).safeTransferFrom(from, proxy, amount);
        }
        _runPlan(proxy, plan);
    }

    // ── Cross-chain escrow (unchanged from V1) ─────────────────────────────

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

        uint256 validatorCount = IValidatorRegistry(validatorRegistry).getValidatorCount();
        uint256 quorumRequired = (validatorCount * IValidatorRegistry(validatorRegistry).quorumBps() + 9999) / 10000;
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

    function getEscrow(bytes32 orderId, uint256 legIndex) external view returns (
        address token, uint256 amount, address user,
        uint256 deadline, bool released, bool refunded
    ) {
        EscrowDeposit storage dep = escrow[orderId][legIndex];
        return (dep.token, dep.amount, dep.user, dep.deadline, dep.released, dep.refunded);
    }

    // ── Simulation helper ──────────────────────────────────────────────────

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

    function registerIntent(bytes4 selector) external onlyRelayer {
        require(selector != bytes4(0), "Invalid selector");
        registeredIntents[selector] = true;
    }

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

    // ── Platform fee internals (unchanged from V1) ──────────────────────

    function _decodePlatformFee(bytes calldata intentParams) internal pure returns (uint256) {
        if (intentParams.length < 32) return 0;
        return abi.decode(intentParams[intentParams.length - 32:], (uint256));
    }

    function _calculateProtocolFee(
        IntentOrder calldata order
    ) internal view virtual returns (uint256) {
        return _decodePlatformFee(order.intentParams);
    }

    function _clampFee(uint256 feeWei) internal view returns (uint256) {
        require(feeWei <= maxPlatformFeeWei, "Fee exceeds cap");
        require(feeWei >= minPlatformFeeWei, "Fee below floor");
        return feeWei;
    }

    function _settleProtocolFeePre(
        IntentOrder calldata order
    ) private returns (uint256 feeOwed, uint256 collectorBefore) {
        uint256 raw = _calculateProtocolFee(order);
        feeOwed = _clampFee(raw);

        if (feeOwed == 0) return (0, 0);
        require(platformFeeCollector != address(0), "No fee collector");

        if (feeMode == FeeMode.USER) {
            if (msg.value > 0) return (0, 0);

            wrappedNativeToken.safeTransferFrom(order.submittedBy, platformFeeCollector, feeOwed);
            emit PlatformFeeCollected(order.orderId, order.submittedBy, feeOwed);
            return (0, 0);
        }

        collectorBefore = wrappedNativeToken.balanceOf(platformFeeCollector);
        return (feeOwed, collectorBefore);
    }

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
        return (n * IValidatorRegistry(validatorRegistry).quorumBps() + 9999) / 10000;
    }

    /// @notice Accept ETH for execution plans that need value
    receive() external payable {}
}
