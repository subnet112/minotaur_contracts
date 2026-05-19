// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IAppRegistry
/// @notice Minimal interface used by AppIntentBase to check that an App
///         contract is authorized to execute. The full contract surface
///         (governance, allowlist, manifest hashes, revocation) lives in
///         AppRegistry.sol; the platform only needs the reverse lookup.
interface IAppRegistry {
    /// @notice Returns the appId registered for a given contract address, or
    ///         bytes32(0) if the contract is not registered (or has been
    ///         revoked).
    function appByContract(address contractAddr) external view returns (bytes32);

    /// @notice Returns true if the appId is currently registered.
    function isRegistered(bytes32 appId) external view returns (bool);
}
