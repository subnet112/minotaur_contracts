// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Minimal interface for EIP-3009 compatible tokens
/// @notice Subset of the USDC-style authorization transfer API used by the settlement contract
interface ITransferWithAuthorization {
    /// @notice Transfers tokens using an off-chain signature based authorization
    /// @param from Token owner granting the authorization
    /// @param to Recipient of the tokens
    /// @param value Amount of tokens to transfer
    /// @param validAfter Timestamp after which the authorization becomes valid
    /// @param validBefore Timestamp after which the authorization expires
    /// @param nonce Unique nonce preventing replay of the authorization
    /// @param v ECDSA recovery byte of the authorization signature
    /// @param r ECDSA signature r value
    /// @param s ECDSA signature s value
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
