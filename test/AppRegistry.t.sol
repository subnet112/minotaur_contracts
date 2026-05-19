// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AppRegistry.sol";
import "../src/AppIntentBase.sol";
import "../src/ValidatorRegistry.sol";
import "./mocks/MockToken.sol";

/// @title MockGatedApp
/// @notice Minimal AppIntentBase implementation that wires the registry
///         through at construction. Used by AppRegistry integration tests to
///         exercise the on-chain check inside executeIntent.
contract MockGatedApp is AppIntentBase {
    bytes4 public constant TEST_SELECTOR = bytes4(keccak256("test(uint256)"));

    constructor(
        address _relayer,
        address _validatorRegistry,
        address _appRegistry
    ) AppIntentBase(
        _relayer,
        _validatorRegistry,
        8000,                // quorumBps
        5000,                // scoreThreshold
        address(0),          // wrappedNativeToken — unused in these tests
        address(0),          // platformFeeCollector
        0,                   // minPlatformFeeWei
        type(uint256).max,   // maxPlatformFeeWei
        FeeMode.USER,
        address(0),          // appPaymaster
        _appRegistry
    ) {
        registeredIntents[TEST_SELECTOR] = true;
    }

    function _handleIntent(
        IntentOrder calldata,
        ExecutionPlan calldata
    ) internal pure override returns (uint256 score, bool valid) {
        return (8000, true);
    }
}

contract AppRegistryTest is Test {
    AppRegistry public registry;

    address public owner;
    address public dev1;
    address public dev2;
    address public stranger;

    bytes32 public constant APP_ID_1 = keccak256("app:dex-v1");
    bytes32 public constant APP_ID_2 = keccak256("app:dca-v1");
    bytes32 public constant MANIFEST_HASH_1 = keccak256("manifest-1");
    bytes32 public constant MANIFEST_HASH_2 = keccak256("manifest-2");

    address public contract1 = address(0xA1);
    address public contract2 = address(0xA2);

    function setUp() public {
        owner = makeAddr("owner");
        dev1 = makeAddr("dev1");
        dev2 = makeAddr("dev2");
        stranger = makeAddr("stranger");

        registry = new AppRegistry(owner);
    }

    // ── Constructor / initial state ────────────────────────────────────────

    function test_initialState_isGated() public view {
        assertEq(registry.owner(), owner);
        assertEq(uint8(registry.mode()), uint8(AppRegistry.Mode.GATED));
        assertFalse(registry.isOpen());
        assertFalse(registry.isRenounced());
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert("AppRegistry: zero owner");
        new AppRegistry(address(0));
    }

    // ── Developer allowlist ────────────────────────────────────────────────

    function test_setDeveloperAllowed_addsAndRemoves() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        assertTrue(registry.allowedDevelopers(dev1));

        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, false);
        assertFalse(registry.allowedDevelopers(dev1));
    }

    function test_setDeveloperAllowed_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("AppRegistry: not owner");
        registry.setDeveloperAllowed(dev1, true);
    }

    function test_setDeveloperAllowed_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("AppRegistry: zero developer");
        registry.setDeveloperAllowed(address(0), true);
    }

    // ── Registration in GATED mode ─────────────────────────────────────────

    function test_registerApp_gated_succeedsForAllowedDev() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);

        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        assertTrue(registry.isRegistered(APP_ID_1));
        AppRegistry.AppRecord memory rec = registry.getApp(APP_ID_1);
        assertEq(rec.developer, dev1);
        assertEq(rec.manifestHash, MANIFEST_HASH_1);
        assertEq(rec.contractAddr, contract1);
        assertGt(rec.registeredAt, 0);
        assertEq(registry.appByContract(contract1), APP_ID_1);
    }

    function test_registerApp_gated_revertsForUnallowedDev() public {
        vm.prank(stranger);
        vm.expectRevert("AppRegistry: developer not allowlisted");
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);
    }

    function test_registerApp_revertsOnDuplicate() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);

        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(dev1);
        vm.expectRevert("AppRegistry: app already registered");
        registry.registerApp(APP_ID_1, MANIFEST_HASH_2, contract2);
    }

    function test_registerApp_revertsOnContractCollision() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);

        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(dev1);
        vm.expectRevert("AppRegistry: contract already mapped");
        registry.registerApp(APP_ID_2, MANIFEST_HASH_2, contract1);
    }

    function test_registerApp_revertsOnZeroFields() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);

        vm.prank(dev1);
        vm.expectRevert("AppRegistry: zero appId");
        registry.registerApp(bytes32(0), MANIFEST_HASH_1, contract1);

        vm.prank(dev1);
        vm.expectRevert("AppRegistry: zero manifest hash");
        registry.registerApp(APP_ID_1, bytes32(0), contract1);

        vm.prank(dev1);
        vm.expectRevert("AppRegistry: zero contract");
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, address(0));
    }

    // ── Registration in OPEN mode ──────────────────────────────────────────

    function test_registerApp_open_allowsAnyone() public {
        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.OPEN);
        assertTrue(registry.isOpen());

        vm.prank(stranger);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        assertTrue(registry.isRegistered(APP_ID_1));
        assertEq(registry.getApp(APP_ID_1).developer, stranger);
    }

    // ── Manifest updates ───────────────────────────────────────────────────

    function test_updateManifest_byDeveloper() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(dev1);
        registry.updateManifest(APP_ID_1, MANIFEST_HASH_2);

        assertEq(registry.getApp(APP_ID_1).manifestHash, MANIFEST_HASH_2);
    }

    function test_updateManifest_revertsForNonDeveloper() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(dev2);
        vm.expectRevert("AppRegistry: not developer");
        registry.updateManifest(APP_ID_1, MANIFEST_HASH_2);

        // Owner is also not the developer
        vm.prank(owner);
        vm.expectRevert("AppRegistry: not developer");
        registry.updateManifest(APP_ID_1, MANIFEST_HASH_2);
    }

    function test_updateManifest_revertsOnUnknownApp() public {
        vm.prank(dev1);
        vm.expectRevert("AppRegistry: unknown app");
        registry.updateManifest(APP_ID_1, MANIFEST_HASH_2);
    }

    // ── Revoke ─────────────────────────────────────────────────────────────

    function test_revokeApp_clearsRecordAndReverseMapping() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(owner);
        registry.revokeApp(APP_ID_1);

        assertFalse(registry.isRegistered(APP_ID_1));
        assertEq(registry.appByContract(contract1), bytes32(0));
    }

    function test_revokeApp_allowsReregistration() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(owner);
        registry.revokeApp(APP_ID_1);

        // Same appId + contract can be re-registered post-revoke
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_2, contract1);
        assertEq(registry.getApp(APP_ID_1).manifestHash, MANIFEST_HASH_2);
    }

    function test_revokeApp_revertsForNonOwner() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(stranger);
        vm.expectRevert("AppRegistry: not owner");
        registry.revokeApp(APP_ID_1);
    }

    // ── Ownership transfer ─────────────────────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        assertEq(registry.owner(), newOwner);

        // Old owner has no power
        vm.prank(owner);
        vm.expectRevert("AppRegistry: not owner");
        registry.setMode(AppRegistry.Mode.OPEN);

        // New owner does
        vm.prank(newOwner);
        registry.setMode(AppRegistry.Mode.OPEN);
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert("AppRegistry: zero owner");
        registry.transferOwnership(address(0));
    }

    // ── Renounce semantics ─────────────────────────────────────────────────

    function test_renounce_revertsWhenStillGated() public {
        vm.prank(owner);
        vm.expectRevert("AppRegistry: must be OPEN before renounce");
        registry.renounceOwnership();
    }

    function test_renounce_succeedsAfterOpen_andLocksAllGovernance() public {
        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.OPEN);

        vm.prank(owner);
        registry.renounceOwnership();

        assertEq(registry.owner(), address(0));
        assertTrue(registry.isRenounced());
        assertTrue(registry.isOpen());

        // Every governance lever is dead. Each reverts with "not owner".
        vm.prank(owner);
        vm.expectRevert("AppRegistry: not owner");
        registry.setMode(AppRegistry.Mode.GATED);

        vm.prank(owner);
        vm.expectRevert("AppRegistry: not owner");
        registry.setDeveloperAllowed(dev1, true);

        // App registration still works (anyone, in OPEN mode)
        vm.prank(stranger);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);
        assertTrue(registry.isRegistered(APP_ID_1));

        // But it can never be revoked post-renounce
        vm.prank(owner);
        vm.expectRevert("AppRegistry: not owner");
        registry.revokeApp(APP_ID_1);
    }

    // ── Mode flipping ──────────────────────────────────────────────────────

    function test_setMode_flipsFreely() public {
        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.OPEN);
        assertEq(uint8(registry.mode()), uint8(AppRegistry.Mode.OPEN));

        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.GATED);
        assertEq(uint8(registry.mode()), uint8(AppRegistry.Mode.GATED));
    }

    function test_setMode_doesNotInvalidateExistingApps() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev1, true);
        vm.prank(dev1);
        registry.registerApp(APP_ID_1, MANIFEST_HASH_1, contract1);

        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.OPEN);
        assertTrue(registry.isRegistered(APP_ID_1));

        vm.prank(owner);
        registry.setMode(AppRegistry.Mode.GATED);
        assertTrue(registry.isRegistered(APP_ID_1));
    }
}

/// @title AppRegistry × AppIntentBase integration
/// @notice Verifies the on-chain check that executeIntent / executeLeg run
///         against the registry. We don't exercise the full execution path
///         (validator quorum, EIP-712 sigs, etc) — only that the registry
///         gate is the first hard failure when the contract is not
///         registered, and that it lets execution proceed otherwise.
contract AppRegistryIntegrationTest is Test {
    AppRegistry public registry;
    ValidatorRegistry public validatorRegistry;
    MockGatedApp public gatedApp;
    MockGatedApp public ungatedApp;

    address public owner;
    address public relayerAddr;
    address public dev;

    bytes32 public constant APP_ID = keccak256("integration-app");
    bytes32 public constant MANIFEST_HASH = keccak256("integration-manifest");

    function setUp() public {
        owner = makeAddr("owner");
        relayerAddr = makeAddr("relayer");
        dev = makeAddr("dev");

        // ValidatorRegistry requires at least one validator; the registry
        // gate (1b in executeIntent) fires before the validator quorum check,
        // so the exact set is irrelevant for these tests.
        address[] memory validators = new address[](1);
        validators[0] = makeAddr("v1");
        validatorRegistry = new ValidatorRegistry(relayerAddr, validators);
        registry = new AppRegistry(owner);

        // gatedApp wires the registry through; ungatedApp passes address(0)
        // so the check is disabled (regression — existing apps must still work).
        gatedApp = new MockGatedApp(relayerAddr, address(validatorRegistry), address(registry));
        ungatedApp = new MockGatedApp(relayerAddr, address(validatorRegistry), address(0));
    }

    function _buildOrder(address appAddr) internal view returns (IAppIntentBase.IntentOrder memory) {
        return IAppIntentBase.IntentOrder({
            orderId: keccak256("order-1"),
            app: appAddr,
            intentSelector: gatedApp.TEST_SELECTOR(),
            intentParams: hex"",
            submittedBy: dev,
            chainId: block.chainid,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });
    }

    function _emptyPlan() internal view returns (IAppIntentBase.ExecutionPlan memory) {
        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](0);
        return IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            metadata: hex""
        });
    }

    function test_executeIntent_revertsWhenUnregistered() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder(address(gatedApp));
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        bytes[] memory sigs = new bytes[](0);
        vm.expectRevert("App not registered");
        gatedApp.executeIntent(order, plan, hex"", sigs);
    }

    function test_executeIntent_passesRegistryCheckAfterRegistration() public {
        // Allowlist dev and register the gated app
        vm.prank(owner);
        registry.setDeveloperAllowed(dev, true);
        vm.prank(dev);
        registry.registerApp(APP_ID, MANIFEST_HASH, address(gatedApp));

        IAppIntentBase.IntentOrder memory order = _buildOrder(address(gatedApp));
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();
        bytes[] memory sigs = new bytes[](0);

        // Registry check passes — execution proceeds to the user signature
        // verification, which fails with OpenZeppelin's ECDSA custom error
        // because we passed an empty signature. The exact error confirms we
        // made it past the registry gate to a downstream check.
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", 0));
        gatedApp.executeIntent(order, plan, hex"", sigs);
    }

    function test_executeIntent_revertsAgainAfterRevoke() public {
        vm.prank(owner);
        registry.setDeveloperAllowed(dev, true);
        vm.prank(dev);
        registry.registerApp(APP_ID, MANIFEST_HASH, address(gatedApp));

        vm.prank(owner);
        registry.revokeApp(APP_ID);

        IAppIntentBase.IntentOrder memory order = _buildOrder(address(gatedApp));
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();
        bytes[] memory sigs = new bytes[](0);

        vm.expectRevert("App not registered");
        gatedApp.executeIntent(order, plan, hex"", sigs);
    }

    function test_executeIntent_skipsCheck_whenRegistryIsZero() public {
        // ungatedApp has appRegistry == address(0): check should be bypassed.
        // The next failure is the user signature, not the registry.
        IAppIntentBase.IntentOrder memory order = _buildOrder(address(ungatedApp));
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();
        bytes[] memory sigs = new bytes[](0);

        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", 0));
        ungatedApp.executeIntent(order, plan, hex"", sigs);
    }
}
