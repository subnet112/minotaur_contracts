// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry - Shared validator set for all App Intent contracts
/// @notice Deploy ONE per chain. All AppIntentBase contracts reference it.
///         Relayer updates validators here instead of on every app.
contract ValidatorRegistry is IValidatorRegistry {
    address public owner;
    address[] public validators;
    mapping(address => bool) public isValidator;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _owner, address[] memory _validators) {
        require(_owner != address(0), "Invalid owner");
        require(_validators.length > 0, "No validators");

        owner = _owner;

        for (uint256 i = 0; i < _validators.length; i++) {
            require(_validators[i] != address(0), "Invalid validator");
            require(!isValidator[_validators[i]], "Duplicate validator");
            validators.push(_validators[i]);
            isValidator[_validators[i]] = true;
        }
    }

    function getValidators() external view returns (address[] memory) {
        return validators;
    }

    function getValidatorCount() external view returns (uint256) {
        return validators.length;
    }

    /// @notice Replace the entire validator set. Reverts on empty, zero-address, or duplicates.
    function updateValidators(address[] calldata _validators) external onlyOwner {
        require(_validators.length > 0, "No validators");

        // Clear old validators
        for (uint256 i = 0; i < validators.length; i++) {
            isValidator[validators[i]] = false;
        }
        delete validators;

        // Set new validators
        for (uint256 i = 0; i < _validators.length; i++) {
            require(_validators[i] != address(0), "Invalid validator");
            require(!isValidator[_validators[i]], "Duplicate validator");
            validators.push(_validators[i]);
            isValidator[_validators[i]] = true;
        }

        emit ValidatorsUpdated(_validators);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
