// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Bittensor's native staking precompile (chain 964), at 0x…0805.
///
/// Two properties of this interface shape everything built on it:
///
///   * `addStake` takes NO coldkey. It credits the mapped account of
///     `msg.sender` — `blake2_256("evm:" ‖ address)`. So whoever sends the
///     transaction owns the alpha, and a contract that stakes owns it itself.
///   * `getStake` reads ANY coldkey, so a contract can price its own position
///     from chain state with no oracle.
///
/// UNITS: `amount` here is RAO (9 decimals). The EVM native balance on 964 is
/// 18-decimal wei. They differ by 1e9 — measured, not assumed: on a Finney fork
/// `addStake(1e9 rao)` debited exactly 1e18 wei.
interface IStakingV2 {
    function addStake(bytes32 hotkey, uint256 amountRao, uint256 netuid) external payable;

    function removeStake(bytes32 hotkey, uint256 amountAlpha, uint256 netuid) external payable;

    /// Slippage-bounded exit. `limitPrice` bounds the alpha→TAO clearing price;
    /// `allowPartial` chooses between a partial fill and a revert.
    function removeStakeLimit(
        bytes32 hotkey,
        uint256 amountAlpha,
        uint256 limitPrice,
        bool allowPartial,
        uint256 netuid
    ) external payable;

    /// Moves a position to ANOTHER coldkey — the primitive that lets a vault
    /// redeem a holder into real alpha under their own key rather than TAO.
    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amountAlpha
    ) external payable;

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid)
        external view returns (uint256);
}
