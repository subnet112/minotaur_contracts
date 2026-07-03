// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/AppIntentBaseV2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAppV2 - Minimal AppIntentBaseV2 implementation for platform testing
/// @notice Mirror of MockApp on the gas-optimized V2 base: same simple swap
///         intent (pull input tokens, execute plan, verify output received).
///
///         Test-only: deploys in USER mode with minPlatformFeeWei = 0 so most
///         tests do not have to worry about fee settlement. Individual tests
///         that exercise fee logic set the mode + paymaster via admin setters.
contract MockAppV2 is AppIntentBaseV2 {
    using SafeERC20 for IERC20;

    bytes4 public constant SWAP_SELECTOR = bytes4(keccak256(
        "swap(address,address,uint256,uint256,address)"
    ));

    constructor(
        address _relayer,
        address _validatorRegistry,
        uint256 _scoreThreshold,
        address _wrappedNativeToken,
        address _platformFeeCollector,
        uint256 _maxPlatformFeeWei,
        address, // _feeCollector (unused, matches MockApp signature for test compat)
        uint256  // _feeBps (unused)
    ) AppIntentBaseV2(
        _relayer, _validatorRegistry, _scoreThreshold,
        _wrappedNativeToken, _platformFeeCollector,
        0,                          // minPlatformFeeWei — tests opt-in via setMinPlatformFeeWei
        _maxPlatformFeeWei,
        FeeMode.USER,               // default to USER mode for backwards-compatible test paths
        address(0),                 // appPaymaster (unused in USER mode)
        address(0)                  // appRegistry — disabled for mock tests
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
}
