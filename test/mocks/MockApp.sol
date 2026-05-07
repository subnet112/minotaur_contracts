// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/AppIntentBase.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockApp - Minimal AppIntentBase implementation for platform testing
/// @notice Implements a simple swap intent: pull input tokens, execute plan,
///         verify output tokens received. Used by E2E and AppIntentBase tests
///         as a concrete app without depending on DexAggregatorApp.
contract MockApp is AppIntentBase {
    using SafeERC20 for IERC20;

    bytes4 public constant SWAP_SELECTOR = bytes4(keccak256(
        "swap(address,address,uint256,uint256,address)"
    ));

    constructor(
        address _relayer,
        address _validatorRegistry,
        uint256 _quorumBps,
        uint256 _scoreThreshold,
        address _wrappedNativeToken,
        address _platformFeeCollector,
        uint256 _maxPlatformFeeWei,
        address, // _feeCollector (unused, matches DexAggregatorApp signature for test compat)
        uint256  // _feeBps (unused)
    ) AppIntentBase(
        _relayer, _validatorRegistry, _quorumBps, _scoreThreshold,
        _wrappedNativeToken, _platformFeeCollector, _maxPlatformFeeWei
    ) {
        registeredIntents[SWAP_SELECTOR] = true;
    }

    function _handleIntent(
        IntentOrder calldata order,
        ExecutionPlan calldata plan
    ) internal override returns (uint256 score, bool valid) {
        (
            address tokenIn, address tokenOut,
            uint256 amountIn, uint256 minAmountOut, address receiver
        ) = abi.decode(order.intentParams, (address, address, uint256, uint256, address));

        require(tokenIn != tokenOut, "Same token");

        _snapshot(tokenOut);
        _fundAndExecute(order, plan, tokenIn, order.submittedBy, amountIn);

        uint256 gained = _gained(tokenOut);
        if (gained < minAmountOut) return (0, false);

        IERC20(tokenOut).safeTransfer(receiver, gained);

        score = _scoreLinear(gained, minAmountOut);
        valid = true;
    }

    /// @notice No-op platform fee (tests don't need fee logic)
    function _collectPlatformFee(
        bytes32, address, bytes calldata
    ) internal pure override {}
}
