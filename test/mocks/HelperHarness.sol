// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/AppIntentBase.sol";

/// @title HelperHarness - Exposes AppIntentBase internal helpers for testing
contract HelperHarness is AppIntentBase {
    bytes4 public constant TEST_SELECTOR = bytes4(keccak256("test(uint256)"));

    constructor(
        address _relayer,
        address _validatorRegistry,
        uint256 _scoreThreshold,
        address _wrappedNativeToken,
        address _platformFeeCollector,
        uint256 _maxPlatformFeeWei
    ) AppIntentBase(
        _relayer, _validatorRegistry, _scoreThreshold,
        _wrappedNativeToken, _platformFeeCollector,
        0,                          // minPlatformFeeWei (test helper — no floor)
        _maxPlatformFeeWei,
        FeeMode.USER,               // default mode for helper tests
        address(0),                 // appPaymaster
        address(0)                  // appRegistry — disabled for legacy harness tests
    ) {
        registeredIntents[TEST_SELECTOR] = true;
    }

    // Expose _snapshot
    function snapshot(address token) external {
        _snapshot(token);
    }

    // Expose _gained
    function gained(address token) external view returns (uint256) {
        return _gained(token);
    }

    // Expose _scoreLinear
    function scoreLinear(uint256 actual, uint256 minimum) external pure returns (uint256) {
        return _scoreLinear(actual, minimum);
    }

    // Expose _fundAndExecute — payable so tests can forward msg.value to
    // exercise the native ETH path.
    function fundAndExecute(
        IntentOrder calldata order,
        ExecutionPlan calldata plan,
        address token,
        address from,
        uint256 amount
    ) external payable returns (address proxy) {
        return _fundAndExecute(order, plan, token, from, amount);
    }

    function _handleIntent(
        IntentOrder calldata,
        ExecutionPlan calldata
    ) internal pure override returns (uint256 score, bool valid) {
        return (8000, true);
    }
}
