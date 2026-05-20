// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry - Shared validator set + quorum for all App Intent contracts
/// @notice Deploy ONE per chain. All AppIntentBase contracts reference it.
///         The owner controls both the validator set (updateValidators) and
///         the network-wide quorum threshold (setQuorumBps).
contract ValidatorRegistry is IValidatorRegistry {
    address public owner;
    address[] public validators;
    mapping(address => bool) public isValidator;
    uint256 public quorumBps;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(
        address _owner,
        address[] memory _validators,
        uint256 _quorumBps
    ) {
        require(_owner != address(0), "Invalid owner");
        require(_validators.length > 0, "No validators");
        require(_quorumBps > 0 && _quorumBps <= 10000, "Invalid quorum");

        owner = _owner;
        quorumBps = _quorumBps;

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

    /// @notice Update the network-wide quorum threshold in basis points.
    /// @dev All AppIntentBase contracts referencing this registry read quorumBps
    ///      at verification time, so a single owner tx reconfigures every App on
    ///      this chain. Off-chain validators are expected to poll this value and
    ///      refresh their local cache (default cadence: once per epoch).
    function setQuorumBps(uint256 _quorumBps) external onlyOwner {
        require(_quorumBps > 0 && _quorumBps <= 10000, "Invalid quorum");
        quorumBps = _quorumBps;
        emit QuorumBpsUpdated(_quorumBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
