// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IValidatorRegistry - Shared validator registry interface
/// @notice One registry per chain, referenced by all AppIntentBase contracts
interface IValidatorRegistry {
    event ValidatorsUpdated(address[] validators);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function isValidator(address addr) external view returns (bool);
    function getValidators() external view returns (address[] memory);
    function getValidatorCount() external view returns (uint256);
    function updateValidators(address[] calldata _validators) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}
