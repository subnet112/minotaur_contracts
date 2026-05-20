// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorRegistry - Shared validator registry interface
/// @notice One registry per chain, referenced by all AppIntentBase contracts.
///         Holds the canonical validator set AND the canonical quorumBps for
///         the network. AppIntentBase reads quorumBps from here at verification
///         time so the value is configurable network-wide via a single
///         setQuorumBps owner tx rather than baked into each App.
interface IValidatorRegistry {
    event ValidatorsUpdated(address[] validators);
    event QuorumBpsUpdated(uint256 newQuorumBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function isValidator(address addr) external view returns (bool);
    function getValidators() external view returns (address[] memory);
    function getValidatorCount() external view returns (uint256);
    function quorumBps() external view returns (uint256);
    function updateValidators(address[] calldata _validators) external;
    function setQuorumBps(uint256 _quorumBps) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}
