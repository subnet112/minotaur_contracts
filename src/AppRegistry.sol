// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  AppRegistry
/// @notice Source of truth for which App Intents are authorized to run on the
///         subnet. Validators and the relayer read this registry before
///         accepting orders or signing executeIntent: an app whose record is
///         missing (or whose manifest hash does not match) must be rejected.
///
///         The registry has two operating modes:
///
///         - Mode.GATED (default): only addresses on the developer allowlist
///           may call `registerApp`. The owner curates the allowlist and may
///           also revoke apps. Used during closed beta to keep the deploy
///           surface controlled while the protocol stabilises.
///
///         - Mode.OPEN: anyone may call `registerApp`. The owner allowlist is
///           ignored. App revocation still works if the owner has not yet
///           renounced.
///
///         The owner can flip between modes any number of times while
///         ownership is held. `renounceOwnership` is a one-way exit that
///         requires the registry to already be in OPEN mode — once renounced,
///         no party can re-gate the registry, revoke apps, or alter the
///         allowlist. This is the credible-neutrality switch: the team
///         eventually calls `setMode(OPEN)` then `renounceOwnership()`, and
///         from that point the gate is permanently off.
///
///         Apps are keyed by `bytes32 appId` (typically `keccak256(name +
///         salt)`). Each record stores the original developer address (the
///         only party that may update the manifest hash), the latest
///         `manifestHash` (sha256 of the JS scoring bundle so validators can
///         verify the off-chain artifact they fetch), the deployed contract
///         address on this chain, and the registration timestamp.
///
///         The registry is intended to be deployed once per chain where apps
///         execute (Base for the primary DEX deployment, BT EVM later, etc).
///         AppIds are global; chain-specific contract addresses live in the
///         per-chain registry instance.
contract AppRegistry {
    // ── Types ──────────────────────────────────────────────────────────────

    enum Mode { GATED, OPEN }

    struct AppRecord {
        address developer;        // the only address that may update manifestHash
        bytes32 manifestHash;     // sha256(JS scoring bundle)
        address contractAddr;     // deployed App contract on this chain
        uint64  registeredAt;     // block.timestamp of registration
    }

    // ── State ──────────────────────────────────────────────────────────────

    address public owner;         // address(0) once renounced
    Mode    public mode;          // defaults to GATED in constructor

    mapping(bytes32 => AppRecord) public apps;             // appId → record
    mapping(address => bytes32)   public appByContract;    // contract → appId
    mapping(address => bool)      public allowedDevelopers;

    // ── Events ─────────────────────────────────────────────────────────────

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipRenounced();
    event ModeChanged(Mode mode);
    event DeveloperAllowed(address indexed developer);
    event DeveloperRevoked(address indexed developer);
    event AppRegistered(
        bytes32 indexed appId,
        address indexed developer,
        bytes32 manifestHash,
        address contractAddr
    );
    event AppManifestUpdated(bytes32 indexed appId, bytes32 newManifestHash);
    event AppRevoked(bytes32 indexed appId);

    // ── Constructor ────────────────────────────────────────────────────────

    /// @param _owner Initial owner — typically the team multisig. The mode
    ///        starts at GATED so the registry is closed until the owner
    ///        explicitly allowlists developers.
    constructor(address _owner) {
        require(_owner != address(0), "AppRegistry: zero owner");
        owner = _owner;
        mode = Mode.GATED;
        emit OwnershipTransferred(address(0), _owner);
        emit ModeChanged(Mode.GATED);
    }

    // ── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "AppRegistry: not owner");
        _;
    }

    // ── Governance (owner-only, until renounced) ───────────────────────────

    /// @notice Move the registry between GATED and OPEN. Freely reversible
    ///         while the owner is still in place. Apps already registered
    ///         under either mode remain valid.
    function setMode(Mode m) external onlyOwner {
        if (m != mode) {
            mode = m;
            emit ModeChanged(m);
        }
    }

    /// @notice Add or remove a developer from the allowlist used in GATED
    ///         mode. Has no effect on already-registered apps.
    function setDeveloperAllowed(address dev, bool allowed) external onlyOwner {
        require(dev != address(0), "AppRegistry: zero developer");
        if (allowedDevelopers[dev] != allowed) {
            allowedDevelopers[dev] = allowed;
            if (allowed) emit DeveloperAllowed(dev);
            else         emit DeveloperRevoked(dev);
        }
    }

    /// @notice Kill switch for malicious or broken apps. Deletes the record
    ///         and the reverse mapping so validators and the relayer reject
    ///         the app from the next block onwards. Only callable until the
    ///         owner renounces; in a renounced registry, registered apps are
    ///         permanent.
    function revokeApp(bytes32 appId) external onlyOwner {
        AppRecord memory rec = apps[appId];
        require(rec.registeredAt != 0, "AppRegistry: unknown app");
        delete appByContract[rec.contractAddr];
        delete apps[appId];
        emit AppRevoked(appId);
    }

    /// @notice Hand ownership to a new admin (e.g. multisig rotation).
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AppRegistry: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Permanently disable owner powers. Must be in OPEN mode first,
    ///         which forces a deliberate two-step sequence — flipping the
    ///         gate off and renouncing in the same tx requires the caller to
    ///         have explicitly called `setMode(OPEN)` beforehand. After this
    ///         call, no party can re-gate the registry, mutate the allowlist,
    ///         or revoke apps.
    function renounceOwnership() external onlyOwner {
        require(mode == Mode.OPEN, "AppRegistry: must be OPEN before renounce");
        emit OwnershipRenounced();
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ── Registration (developer-facing) ────────────────────────────────────

    /// @notice Register a new app. In GATED mode, msg.sender must be on the
    ///         developer allowlist. In OPEN mode, anyone may register.
    ///
    ///         `appId` is global across chains and immutable once written.
    ///         `contractAddr` is the deployment on this chain; if the same
    ///         app exists on multiple chains, each chain's AppRegistry holds
    ///         its own record with its own contract address.
    ///
    ///         The developer recorded here is the only party who may later
    ///         update the manifest hash via `updateManifest`.
    function registerApp(
        bytes32 appId,
        bytes32 manifestHash,
        address contractAddr
    ) external {
        require(appId != bytes32(0), "AppRegistry: zero appId");
        require(manifestHash != bytes32(0), "AppRegistry: zero manifest hash");
        require(contractAddr != address(0), "AppRegistry: zero contract");
        require(apps[appId].registeredAt == 0, "AppRegistry: app already registered");
        require(appByContract[contractAddr] == bytes32(0), "AppRegistry: contract already mapped");

        if (mode == Mode.GATED) {
            require(allowedDevelopers[msg.sender], "AppRegistry: developer not allowlisted");
        }

        apps[appId] = AppRecord({
            developer:    msg.sender,
            manifestHash: manifestHash,
            contractAddr: contractAddr,
            registeredAt: uint64(block.timestamp)
        });
        appByContract[contractAddr] = appId;

        emit AppRegistered(appId, msg.sender, manifestHash, contractAddr);
    }

    /// @notice Update the manifest hash for an app whose JS scoring bundle
    ///         has been hot-upgraded. Only the original developer may call.
    ///         The contract address and developer address are immutable.
    function updateManifest(bytes32 appId, bytes32 newManifestHash) external {
        require(newManifestHash != bytes32(0), "AppRegistry: zero manifest hash");
        AppRecord storage rec = apps[appId];
        require(rec.registeredAt != 0, "AppRegistry: unknown app");
        require(rec.developer == msg.sender, "AppRegistry: not developer");
        rec.manifestHash = newManifestHash;
        emit AppManifestUpdated(appId, newManifestHash);
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function isRegistered(bytes32 appId) external view returns (bool) {
        return apps[appId].registeredAt != 0;
    }

    function getApp(bytes32 appId) external view returns (AppRecord memory) {
        return apps[appId];
    }

    function isOpen() external view returns (bool) {
        return mode == Mode.OPEN;
    }

    function isRenounced() external view returns (bool) {
        return owner == address(0);
    }
}
