// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

import {ITransferWithAuthorization} from "./interfaces/ITransferWithAuthorization.sol";

/// @title Single-order settlement contract for the Mino aggregator
/// @notice Verifies user intents, executes solver-provided interaction plans, and settles swaps atomically
/// @dev Inspired by CoW Protocol's GPv2Settlement but limited to one order per transaction
contract Settlement is EIP712, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Permit types supported by the settlement contract
    enum PermitType {
        None,
        EIP2612,
        EIP3009,
        StandardApproval,
        Custom
    }

    /// @notice Encoded permit or approval data accompanying an order intent
    struct PermitData {
        /// @notice Type discriminator for the permit encoded in `permitCall`
        PermitType permitType;
        /// @notice Raw ABI-encoded permit or approval payload
        bytes permitCall;
        /// @notice Allowance or transfer amount enforced by the permit
        uint256 amount;
        /// @notice Absolute expiry passed to the permit (0 if not used)
        uint256 deadline;
    }

    /// @notice Low-level call executed during settlement
    struct Interaction {
        /// @notice Contract address to be called
        address target;
        /// @notice Native ETH value forwarded with the call
        uint256 value;
        /// @notice ABI-encoded calldata executed on the target
        bytes callData;
    }

    /// @notice Pre, main, and post interaction bundles created by the solver
    struct ExecutionPlan {
        /// @notice Optional setup interactions executed before the main path
        Interaction[] preInteractions;
        /// @notice Primary execution steps for the settlement
        Interaction[] interactions;
        /// @notice Optional cleanup or distribution interactions executed after the main path
        Interaction[] postInteractions;
    }

    /// @notice User intent signed off-chain and fulfilled by the settlement contract
    struct OrderIntent {
        /// @notice Off-chain quote identifier emitted with settlements
        bytes32 quoteId;
        /// @notice User that authorized the swap intent and funds movement
        address user;
        IERC20 tokenIn;
        IERC20 tokenOut;
        /// @notice Token amount pulled from the user
        uint256 amountIn;
        /// @notice Minimum acceptable `tokenOut` amount for the settlement
        uint256 minAmountOut;
        /// @notice Recipient of the output tokens
        address receiver;
        uint256 deadline;
        uint256 nonce;
        PermitData permit;
        bytes32 interactionsHash;
        /// @notice Sum of ETH value forwarded across interactions
        uint256 callValue;
        /// @notice Gas hint provided for off-chain scoring
        uint256 gasEstimate;
        /// @notice EIP-712 signature produced by the user over the order intent
        bytes userSignature;
    }

    /// @notice EIP-712 type hash for `PermitData`
    bytes32 private constant PERMIT_DATA_TYPEHASH =
        keccak256("PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)");

    /// @notice EIP-712 type hash for `OrderIntent`
    bytes32 private constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 quoteId,address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,address receiver,uint256 deadline,uint256 nonce,bytes32 interactionsHash,uint256 callValue,uint256 gasEstimate,PermitData permit)PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)"
    );

    /// @dev Tracks whether a user nonce has already been consumed
    mapping(address => mapping(uint256 => bool)) private _consumedNonces;

    /// @notice Denominator used for basis point fee calculations
    uint256 private constant FEE_BPS_DENOMINATOR = 10_000;

    /// @notice Flag that restricts settlement calls to explicitly trusted relayers
    bool public relayerRestrictionEnabled;
    /// @notice Mapping of addresses permitted to relay settlements when restrictions are enabled
    mapping(address => bool) public trustedRelayers;

    /// @notice Flag that enforces an allowlist for interaction targets
    bool public allowlistEnabled;
    /// @notice Mapping of contracts allowed to be called when the allowlist is enabled
    mapping(address => bool) public interactionTargetAllowed;

    /// @notice Address that receives protocol fees derived from positive slippage
    address public feeRecipient;
    /// @notice Fee rate (in basis points) applied to positive slippage
    uint256 public positiveSlippageFeeBps;

    /// @notice Emitted once an order settles successfully
    /// @dev `amountOut` reflects the total tokenOut collected; `feeAmount` is routed to `feeRecipient`
    event SwapSettled(
        bytes32 indexed quoteId,
        address indexed user,
        IERC20 tokenIn,
        uint256 amountIn,
        IERC20 tokenOut,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 gasEstimate,
        uint256 timestamp
    );

    /// @notice Emitted for every interaction executed during settlement
    event InteractionExecuted(bytes32 indexed quoteId, address target, uint256 value, bytes callData);

    /// @notice Emitted when settlement reverts and bubble-up reason is decoded
    event SwapFailed(bytes32 indexed quoteId, address indexed user, string reason);

    /// @notice Emitted when a user self-invalidates a nonce
    event NonceInvalidated(address indexed user, uint256 indexed nonce);
    /// @notice Emitted when an allowlisted interaction target toggles
    event InteractionAllowlistUpdated(address indexed target, bool isAllowed);
    /// @notice Emitted when the allowlist flag toggles
    event AllowlistStatusUpdated(bool enabled);
    /// @notice Emitted when relayer restrictions are toggled
    event RelayerRestrictionUpdated(bool enabled);
    /// @notice Emitted when a relayer is added to or removed from the trusted set
    event TrustedRelayerUpdated(address indexed relayer, bool allowed);
    /// @notice Emitted when native ETH is swept out by the owner
    event NativeSwept(address indexed to, uint256 amount);
    /// @notice Emitted when ERC20 tokens are swept out by the owner
    event TokenSwept(IERC20 indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when fee parameters are updated by the owner
    event FeeParametersUpdated(address indexed recipient, uint256 feeBps);

    /// @notice Thrown when an order exceeds its deadline
    error OrderExpired();
    /// @notice Thrown when attempting to reuse an already-consumed nonce
    error NonceAlreadyUsed(address user, uint256 nonce);
    /// @notice Thrown when signature recovery does not resolve to the user
    error InvalidSignature();
    /// @notice Thrown when the user signature is missing from calldata
    error MissingSignature();
    /// @notice Thrown when the intent user address is zero
    error InvalidUser(address user);
    /// @notice Thrown when the receiver address is zero
    error InvalidReceiver(address receiver);
    /// @notice Thrown when a provided execution plan hash does not match the intent hash
    error InteractionsHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice Thrown when msg.value does not match the intent call value
    error CallValueMismatch(uint256 expected, uint256 provided);
    /// @notice Thrown when a caller is not authorized to relay settlement
    error RelayerNotAllowed(address relayer);
    /// @notice Thrown when a permit deadline has already elapsed
    error PermitDeadlineExpired(uint256 deadline);
    /// @notice Thrown when a permit is not yet valid
    error PermitNotYetValid(uint256 validAfter);
    /// @notice Thrown when permit calldata is missing for non-standard approvals
    error PermitCallMissing();
    /// @notice Thrown when the permit owner does not match the intent user
    error PermitOwnerMismatch(address expected, address actual);
    /// @notice Thrown when the permit spender does not match the settlement contract
    error PermitSpenderMismatch(address expected, address actual);
    /// @notice Thrown when a permit amount is insufficient for the required transfer
    error PermitAmountTooLow(uint256 provided, uint256 required);
    /// @notice Thrown when a custom permit call reverts
    error PermitCallFailed(bytes data);
    /// @notice Thrown when an unsupported permit type is provided
    error UnsupportedPermitType();
    /// @notice Thrown when ERC20 allowance is insufficient to pull funds
    error InsufficientAllowance(uint256 allowance, uint256 required);
    /// @notice Thrown when fewer tokens than expected were collected from the user
    error InsufficientInputAmount(uint256 collected, uint256 required);
    /// @notice Thrown when output tokens received are below the minimum amount
    error InsufficientOutput(uint256 received, uint256 minimum);
    /// @notice Thrown when interactions attempt to spend more ETH than available
    error InsufficientCallValue(uint256 available, uint256 requested);
    /// @notice Thrown when an interaction target is invalid or not allowed
    error InvalidInteractionTarget(address target);
    /// @notice Thrown when an interaction call reverts and bubbles the return data
    error InteractionCallFailed(address target, bytes reason);
    /// @notice Thrown when an internal call can only be made via the contract itself
    error SelfCallOnly();
    /// @notice Thrown when fee basis points exceed the allowed denominator
    error FeeBpsTooHigh(uint256 provided, uint256 maxAllowed);
    /// @notice Thrown when configuring a non-zero fee without a valid recipient
    error InvalidFeeRecipient();

    /// @notice Initializes the settlement contract
    /// @param initialOwner Address that receives ownership of administrative functions
    constructor(address initialOwner) EIP712("OIF Settlement", "1") Ownable(initialOwner) {}

    receive() external payable {}

    /// @notice Executes a solver-provided settlement plan using a user-signed intent
    /// @param intent The order intent signed by the user
    /// @param plan The execution plan agreed upon off-chain
    /// @return amountOut Tokens received for the user after executing the plan
    function executeOrder(OrderIntent calldata intent, ExecutionPlan calldata plan)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (relayerRestrictionEnabled && !trustedRelayers[msg.sender]) {
            revert RelayerNotAllowed(msg.sender);
        }
        if (intent.userSignature.length == 0) {
            revert MissingSignature();
        }
        if (intent.user == address(0)) {
            revert InvalidUser(intent.user);
        }
        if (intent.receiver == address(0)) {
            revert InvalidReceiver(intent.receiver);
        }
        if (msg.value != intent.callValue) {
            revert CallValueMismatch(intent.callValue, msg.value);
        }

        uint256 nativeBalanceBefore = address(this).balance - msg.value;

        try this._execute(intent, plan, nativeBalanceBefore) returns (uint256 settled, uint256 feeAmount) {
            emit SwapSettled(
                intent.quoteId,
                intent.user,
                intent.tokenIn,
                intent.amountIn,
                intent.tokenOut,
                settled,
                feeAmount,
                intent.gasEstimate,
                block.timestamp
            );
            return settled;
        } catch (bytes memory reason) {
            emit SwapFailed(intent.quoteId, intent.user, _decodeRevertReason(reason));
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @notice Computes the canonical hash of an execution plan
    /// @param plan Plan containing pre, main, and post interactions
    /// @return keccak256 digest of the encoded interactions
    function hashExecutionPlan(ExecutionPlan calldata plan) public pure returns (bytes32) {
        bytes memory encoded = _encodeInteractions(plan.preInteractions);
        encoded = bytes.concat(encoded, _encodeInteractions(plan.interactions));
        encoded = bytes.concat(encoded, _encodeInteractions(plan.postInteractions));
        return keccak256(encoded);
    }

    /// @notice Returns the current EIP-712 domain separator for signature verification
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Returns whether a user nonce has already been consumed
    /// @param user The owner of the nonce
    /// @param nonce The nonce value to check
    /// @return True if the nonce has been used
    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return _consumedNonces[user][nonce];
    }

    /// @notice Allows users to invalidate an unused nonce proactively
    /// @param nonce The nonce to invalidate
    function invalidateNonce(uint256 nonce) external {
        if (_consumedNonces[msg.sender][nonce]) {
            revert NonceAlreadyUsed(msg.sender, nonce);
        }
        _consumedNonces[msg.sender][nonce] = true;
        emit NonceInvalidated(msg.sender, nonce);
    }

    /// @notice Enables or disables relayer restrictions
    /// @param enabled True to restrict settlement to trusted relayers
    function setRelayerRestriction(bool enabled) external onlyOwner {
        relayerRestrictionEnabled = enabled;
        emit RelayerRestrictionUpdated(enabled);
    }

    /// @notice Adds or removes an address from the trusted relayer set
    /// @param relayer Address of the relayer
    /// @param allowed True to authorize the relayer, false to remove it
    function setTrustedRelayer(address relayer, bool allowed) external onlyOwner {
        trustedRelayers[relayer] = allowed;
        emit TrustedRelayerUpdated(relayer, allowed);
    }

    /// @notice Enables or disables the interaction target allowlist
    /// @param enabled True to require allowlisted interaction targets
    function setAllowlistEnabled(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistStatusUpdated(enabled);
    }

    /// @notice Adds or removes a contract from the interaction allowlist
    /// @param target Address of the contract to update
    /// @param allowed True if the contract can be called during settlement
    function setInteractionTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) {
            revert InvalidInteractionTarget(target);
        }
        interactionTargetAllowed[target] = allowed;
        emit InteractionAllowlistUpdated(target, allowed);
    }

    /// @notice Updates fee recipient and positive slippage fee rate
    /// @param recipient Address receiving protocol fees (set zero address to disable fees)
    /// @param feeBps Fee expressed in basis points (max 10_000)
    function setFeeParameters(address recipient, uint256 feeBps) external onlyOwner {
        if (feeBps > FEE_BPS_DENOMINATOR) {
            revert FeeBpsTooHigh(feeBps, FEE_BPS_DENOMINATOR);
        }
        if (recipient == address(0) && feeBps != 0) {
            revert InvalidFeeRecipient();
        }

        feeRecipient = recipient;
        positiveSlippageFeeBps = feeBps;
        emit FeeParametersUpdated(recipient, feeBps);
    }

    /// @notice Sweeps stray native ETH to an address controlled by the owner
    /// @param to Recipient of the swept ETH
    /// @param amount Amount of ETH to transfer
    function sweepNative(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            revert InvalidReceiver(address(to));
        }
        Address.sendValue(to, amount);
        emit NativeSwept(to, amount);
    }

    /// @notice Sweeps arbitrary ERC20 tokens to an address controlled by the owner
    /// @param token Token to transfer
    /// @param to Recipient of the tokens
    /// @param amount Amount of tokens to sweep
    function sweepToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            revert InvalidReceiver(to);
        }
        token.safeTransfer(to, amount);
        emit TokenSwept(token, to, amount);
    }

    /// @dev Internal hook invoked via self-call to execute the order once guards pass
    /// @param intent User intent being fulfilled
    /// @param plan Execution plan agreed off-chain
    /// @param nativeBalanceBefore Balance snapshot before interactions to compute ETH deltas
    /// @return amountOut Total amount of tokenOut collected by settlement
    /// @return feeAmount Portion of positive slippage routed to the fee recipient
    function _execute(OrderIntent calldata intent, ExecutionPlan calldata plan, uint256 nativeBalanceBefore)
        external
        returns (uint256 amountOut, uint256 feeAmount)
    {
        if (msg.sender != address(this)) {
            revert SelfCallOnly();
        }
        if (block.timestamp > intent.deadline) {
            revert OrderExpired();
        }

        _useNonce(intent.user, intent.nonce);

        bytes32 expectedInteractionsHash = hashExecutionPlan(plan);
        if (expectedInteractionsHash != intent.interactionsHash) {
            revert InteractionsHashMismatch(intent.interactionsHash, expectedInteractionsHash);
        }

        bytes32 digest = _hashTypedDataV4(_hashOrderIntent(intent));
        address signer = ECDSA.recover(digest, intent.userSignature);
        if (signer != intent.user) {
            revert InvalidSignature();
        }

        uint256 tokenInBalanceBefore = intent.tokenIn.balanceOf(address(this));
        uint256 tokenOutBalanceBefore = intent.tokenOut.balanceOf(address(this));

        _applyPermit(intent);
        _collectUserFunds(intent, tokenInBalanceBefore);

        uint256 remainingCallValue = intent.callValue;
        remainingCallValue = _runInteractions(intent, plan.preInteractions, remainingCallValue);
        remainingCallValue = _runInteractions(intent, plan.interactions, remainingCallValue);
        remainingCallValue = _runInteractions(intent, plan.postInteractions, remainingCallValue);

        uint256 tokenOutBalanceAfter = intent.tokenOut.balanceOf(address(this));
        uint256 outputDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;
        if (outputDelta < intent.minAmountOut) {
            revert InsufficientOutput(outputDelta, intent.minAmountOut);
        }

        feeAmount = _takePositiveSlippageFee(intent, outputDelta);

        uint256 userPayout = outputDelta - feeAmount;
        if (userPayout > 0) {
            intent.tokenOut.safeTransfer(intent.receiver, userPayout);
        }

        uint256 nativeSurplus = address(this).balance - nativeBalanceBefore;
        if (nativeSurplus > 0) {
            _payoutNative(intent.user, nativeSurplus);
        }

        return (outputDelta, feeAmount);
    }

    /// @dev Executes a list of interactions sequentially while tracking remaining call value
    /// @param intent User intent, used for telemetry
    /// @param interactions Interaction array to execute
    /// @param remainingCallValue ETH value available for the interactions
    /// @return Updated remaining call value after executing the interactions
    function _runInteractions(
        OrderIntent calldata intent,
        Interaction[] calldata interactions,
        uint256 remainingCallValue
    ) private returns (uint256) {
        uint256 length = interactions.length;
        for (uint256 i = 0; i < length;) {
            Interaction calldata interaction = interactions[i];
            if (interaction.target == address(0)) {
                revert InvalidInteractionTarget(interaction.target);
            }
            if (allowlistEnabled && !interactionTargetAllowed[interaction.target]) {
                revert InvalidInteractionTarget(interaction.target);
            }
            if (interaction.value > remainingCallValue) {
                revert InsufficientCallValue(remainingCallValue, interaction.value);
            }
            (bool success, bytes memory returndata) =
                interaction.target.call{value: interaction.value}(interaction.callData);
            if (!success) {
                revert InteractionCallFailed(interaction.target, returndata);
            }
            emit InteractionExecuted(intent.quoteId, interaction.target, interaction.value, interaction.callData);

            unchecked {
                remainingCallValue -= interaction.value;
                ++i;
            }
        }
        return remainingCallValue;
    }

    /// @dev Applies the permit associated with an intent when required
    /// @param intent User intent containing permit metadata
    function _applyPermit(OrderIntent calldata intent) private {
        PermitData calldata permit = intent.permit;
        PermitType permitType = permit.permitType;

        if (permitType == PermitType.None) {
            return;
        }

        if (permitType == PermitType.StandardApproval) {
            uint256 allowance = intent.tokenIn.allowance(intent.user, address(this));
            if (allowance < intent.amountIn) {
                revert InsufficientAllowance(allowance, intent.amountIn);
            }
            return;
        }

        if (permit.deadline != 0 && permit.deadline < block.timestamp) {
            revert PermitDeadlineExpired(permit.deadline);
        }

        if (permit.permitCall.length == 0) {
            revert PermitCallMissing();
        }

        if (permitType == PermitType.EIP2612) {
            (address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
                abi.decode(permit.permitCall, (address, address, uint256, uint256, uint8, bytes32, bytes32));

            if (owner != intent.user) {
                revert PermitOwnerMismatch(intent.user, owner);
            }
            if (spender != address(this)) {
                revert PermitSpenderMismatch(address(this), spender);
            }
            if (value < intent.amountIn) {
                revert PermitAmountTooLow(value, intent.amountIn);
            }

            if (deadline < block.timestamp) {
                revert PermitDeadlineExpired(deadline);
            }

            IERC20Permit(address(intent.tokenIn)).permit(owner, spender, value, deadline, v, r, s);
            return;
        }

        if (permitType == PermitType.EIP3009) {
            (
                address from,
                address to,
                uint256 value,
                uint256 validAfter,
                uint256 validBefore,
                bytes32 nonce,
                uint8 v,
                bytes32 r,
                bytes32 s
            ) = abi.decode(
                permit.permitCall, (address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
            );

            if (from != intent.user) {
                revert PermitOwnerMismatch(intent.user, from);
            }
            if (to != address(this)) {
                revert PermitSpenderMismatch(address(this), to);
            }
            if (value < intent.amountIn) {
                revert PermitAmountTooLow(value, intent.amountIn);
            }
            if (validBefore < block.timestamp) {
                revert PermitDeadlineExpired(validBefore);
            }
            if (block.timestamp < validAfter) {
                revert PermitNotYetValid(validAfter);
            }

            ITransferWithAuthorization(address(intent.tokenIn)).transferWithAuthorization(
                from, to, value, validAfter, validBefore, nonce, v, r, s
            );
            return;
        }

        if (permitType == PermitType.Custom) {
            (bool success, bytes memory data) = address(intent.tokenIn).call(permit.permitCall);
            if (!success) {
                revert PermitCallFailed(data);
            }
            return;
        }

        revert UnsupportedPermitType();
    }

    /// @dev Pulls the required token amount from the user using allowance or authorization flow
    /// @param intent User intent describing assets to collect
    /// @param tokenBalanceBefore Token balance snapshot before collection for delta accounting
    function _collectUserFunds(OrderIntent calldata intent, uint256 tokenBalanceBefore) private {
        IERC20 token = intent.tokenIn;

        if (intent.permit.permitType != PermitType.EIP3009) {
            uint256 allowance = token.allowance(intent.user, address(this));
            if (allowance < intent.amountIn) {
                revert InsufficientAllowance(allowance, intent.amountIn);
            }
            token.safeTransferFrom(intent.user, address(this), intent.amountIn);
        }

        uint256 collected = token.balanceOf(address(this)) - tokenBalanceBefore;
        if (collected < intent.amountIn) {
            revert InsufficientInputAmount(collected, intent.amountIn);
        }
    }

    /// @dev Transfers positive slippage fees to the configured recipient
    /// @param intent User intent used to access minAmountOut and token address
    /// @param outputDelta Total amount of tokenOut received by the settlement contract
    /// @return feeAmount Amount transferred to the fee recipient
    function _takePositiveSlippageFee(OrderIntent calldata intent, uint256 outputDelta)
        private
        returns (uint256 feeAmount)
    {
        if (feeRecipient == address(0) || positiveSlippageFeeBps == 0) {
            return 0;
        }
        if (outputDelta <= intent.minAmountOut) {
            return 0;
        }

        uint256 positiveSlippage = outputDelta - intent.minAmountOut;
        feeAmount = (positiveSlippage * positiveSlippageFeeBps) / FEE_BPS_DENOMINATOR;

        if (feeAmount == 0) {
            return 0;
        }

        intent.tokenOut.safeTransfer(feeRecipient, feeAmount);
    }

    /// @dev Marks a user nonce as consumed and reverts on reuse
    function _useNonce(address user, uint256 nonce) private {
        if (_consumedNonces[user][nonce]) {
            revert NonceAlreadyUsed(user, nonce);
        }
        _consumedNonces[user][nonce] = true;
    }

    /// @dev Sends native ETH to the specified recipient
    function _payoutNative(address to, uint256 amount) private {
        Address.sendValue(payable(to), amount);
    }

    /// @dev Hashes the EIP-712 struct for an order intent
    function _hashOrderIntent(OrderIntent calldata intent) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                intent.quoteId,
                intent.user,
                address(intent.tokenIn),
                address(intent.tokenOut),
                intent.amountIn,
                intent.minAmountOut,
                intent.receiver,
                intent.deadline,
                intent.nonce,
                intent.interactionsHash,
                intent.callValue,
                intent.gasEstimate,
                _hashPermitData(intent.permit)
            )
        );
    }

    /// @dev Hashes permit data for inclusion in the EIP-712 digest
    function _hashPermitData(PermitData calldata permit) private pure returns (bytes32) {
        if (permit.permitType == PermitType.None) {
            return bytes32(0);
        }
        return keccak256(
            abi.encode(
                PERMIT_DATA_TYPEHASH,
                uint8(permit.permitType),
                keccak256(permit.permitCall),
                permit.amount,
                permit.deadline
            )
        );
    }

    /// @dev Encodes interactions into a canonical byte representation
    function _encodeInteractions(Interaction[] calldata interactions) private pure returns (bytes memory data) {
        uint256 length = interactions.length;
        if (length == 0) {
            return "";
        }

        for (uint256 i = 0; i < length;) {
            Interaction calldata interaction = interactions[i];
            data = bytes.concat(
                data, abi.encodePacked(interaction.target, interaction.value, keccak256(interaction.callData))
            );

            unchecked {
                ++i;
            }
        }

        return data;
    }

    /// @dev Tries to decode a revert reason for telemetry purposes
    function _decodeRevertReason(bytes memory revertData) private pure returns (string memory) {
        if (revertData.length == 0) {
            return "EMPTY_REVERT_DATA";
        }
        if (revertData.length < 4) {
            return "0x";
        }

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }

        if (revertData.length >= 68 && selector == 0x08c379a0) {
            assembly ("memory-safe") {
                revertData := add(revertData, 0x04)
                mstore(revertData, sub(mload(revertData), 0x04))
            }
            return abi.decode(revertData, (string));
        }

        return string.concat("0x", Strings.toHexString(uint256(uint32(selector)), 4));
    }
}
