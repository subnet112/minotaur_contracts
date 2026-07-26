// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AppIntentBaseV2.sol";
import "../src/ValidatorRegistry.sol";
import "../src/EIP712Verifier.sol";
import "./mocks/MockAppV2.sol";
import "./mocks/MockToken.sol";
import "./mocks/MockRouter.sol";

/// @notice Plan-set signature coverage: the user signs the ordered hashes of
///         EVERY leg plan (forward + revert) ONCE under the chain-agnostic
///         PlanSet domain; executeLegSigned proves membership before running
///         the leg. With planSetSignatureRequired armed, the legacy
///         quorum-only leg paths revert — closing the empty-user-sig hole on
///         destination legs.
contract PlanSetSignatureTest is Test {
    MockAppV2 public app;
    ValidatorRegistry public registry;
    MockToken public weth;
    MockToken public usdc;
    MockRouter public router;

    address public relayerAddr;
    uint256 public relayerKey;
    address public user;
    uint256 public userKey;
    address public attacker;
    uint256 public attackerKey;
    address public feeCollector;
    address[] public validatorAddrs;
    uint256[] public validatorKeys;

    bytes32 public DOMAIN_SEPARATOR;

    function setUp() public {
        (relayerAddr, relayerKey) = makeAddrAndKey("relayer");
        (user, userKey) = makeAddrAndKey("user");
        (attacker, attackerKey) = makeAddrAndKey("attacker");
        feeCollector = makeAddr("feeCollector");

        for (uint256 i = 0; i < 3; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string(abi.encodePacked("validator", vm.toString(i))));
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }
        _sortValidators();

        registry = new ValidatorRegistry(relayerAddr, validatorAddrs, 8000);
        weth = new MockToken("Wrapped ETH", "WETH", 18);
        app = new MockAppV2(relayerAddr, address(registry), 5000, address(weth), relayerAddr, 0.1 ether, feeCollector, 5000);
        usdc = new MockToken("USD Coin", "USDC", 6);
        router = new MockRouter();

        DOMAIN_SEPARATOR = app.DOMAIN_SEPARATOR();

        usdc.mint(address(router), 1_000_000e6);
    }

    // ── Signed path ──────────────────────────────────────────────────────

    function test_executeLegSigned_happyPath() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_happy"));

        (bytes32[] memory setHashes, bytes memory sig) = _signedSet(order, plan);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);

        assertTrue(app.legExecuted(order.orderId, 0), "leg marked executed");
        assertEq(usdc.balanceOf(user), 1800e6, "leg delivered output");
    }

    function test_executeLegSigned_worksWithEnforcementArmed() public {
        vm.prank(relayerAddr);
        app.setPlanSetSignatureRequired(true);

        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_armed"));
        (bytes32[] memory setHashes, bytes memory sig) = _signedSet(order, plan);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);
        assertTrue(app.legExecuted(order.orderId, 0));
    }

    function test_planNotInSet_reverts() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_not_member"));

        // User signs a set that does NOT contain this plan's hash.
        bytes32[] memory setHashes = new bytes32[](2);
        setHashes[0] = keccak256("some other plan");
        setHashes[1] = keccak256("yet another plan");
        bytes memory sig = _signPlanSet(userKey, order.orderId, setHashes);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        vm.expectRevert("Plan not in signed set");
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);
    }

    function test_wrongSetPosition_reverts() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_wrong_pos"));

        bytes32[] memory setHashes = new bytes32[](2);
        setHashes[0] = EIP712Verifier.hashPlanMem(plan);
        setHashes[1] = keccak256("revert leg plan");
        bytes memory sig = _signPlanSet(userKey, order.orderId, setHashes);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        // Right set, wrong claimed position.
        vm.expectRevert("Plan not in signed set");
        app.executeLegSigned(order, plan, 0, setHashes, 1, sig, vsigs);

        vm.expectRevert("Set position out of range");
        app.executeLegSigned(order, plan, 0, setHashes, 2, sig, vsigs);
    }

    function test_signatureByNonUser_reverts() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_bad_signer"));

        bytes32[] memory setHashes = _setOf(plan);
        // Attacker signs the correct set — must still fail: the approval
        // has to come from order.submittedBy.
        bytes memory sig = _signPlanSet(attackerKey, order.orderId, setHashes);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        vm.expectRevert("Invalid plan-set signature");
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);
    }

    function test_signatureBindsOrderId() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_bind_order"));

        bytes32[] memory setHashes = _setOf(plan);
        // Signed for a DIFFERENT order id → must not authorize this one.
        bytes memory sig = _signPlanSet(userKey, keccak256("other_order"), setHashes);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        vm.expectRevert("Invalid plan-set signature");
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);
    }

    function test_emptySignature_reverts() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_empty_sig"));

        bytes32[] memory setHashes = _setOf(plan);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        vm.expectRevert("Plan-set signature required");
        app.executeLegSigned(order, plan, 0, setHashes, 0, "", vsigs);
    }

    function test_legReplay_reverts() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_replay"));

        (bytes32[] memory setHashes, bytes memory sig) = _signedSet(order, plan);
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);

        weth.mint(user, 1e18);
        vm.prank(user);
        weth.approve(address(app), 1e18);

        vm.expectRevert("Leg already executed");
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, vsigs);
    }

    function test_quorumStillRequiredOnSignedPath() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_quorum"));

        (bytes32[] memory setHashes, bytes memory sig) = _signedSet(order, plan);
        // Only one validator signature — below the 80% quorum of 3.
        bytes[] memory one = new bytes[](1);
        one[0] = _validatorSigs(order.orderId, plan)[0];

        vm.expectRevert("Insufficient quorum");
        app.executeLegSigned(order, plan, 0, setHashes, 0, sig, one);
    }

    // ── Enforcement flag ─────────────────────────────────────────────────

    function test_enforcement_blocksLegacyLegPaths() public {
        vm.prank(relayerAddr);
        app.setPlanSetSignatureRequired(true);

        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_block_legacy"));
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        // Quorum-only (empty user sig) — the exact hole this closes.
        vm.expectRevert("Plan-set signature required");
        app.executeLeg(order, plan, 0, "", vsigs);

        vm.expectRevert("Plan-set signature required");
        app.executeCrossChainLeg(order, plan, 0, "", vsigs);

        // Even an order-signed legacy call is blocked: the order signature
        // doesn't bind the plan set.
        bytes memory orderSig = _signOrder(order);
        vm.expectRevert("Plan-set signature required");
        app.executeLeg(order, plan, 0, orderSig, vsigs);
    }

    function test_enforcementOff_legacyStillWorks() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _legOrder(keccak256("ps_legacy_ok"));
        bytes[] memory vsigs = _validatorSigs(order.orderId, plan);

        app.executeLeg(order, plan, 0, "", vsigs);
        assertTrue(app.legExecuted(order.orderId, 0), "back-compat preserved");
    }

    function test_setterOnlyRelayer() public {
        vm.expectRevert("Only relayer");
        app.setPlanSetSignatureRequired(true);

        vm.prank(relayerAddr);
        app.setPlanSetSignatureRequired(true);
        assertTrue(app.planSetSignatureRequired());
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /// @dev Sentinel nonce so the leg path (which doesn't consume nonces the
    ///      way executeIntent does) matches how the platform submits legs.
    function _legOrder(bytes32 orderId) internal returns (
        IAppIntentBase.IntentOrder memory order,
        IAppIntentBase.ExecutionPlan memory plan
    ) {
        uint256 amountIn = 1e18;
        weth.mint(user, amountIn);
        vm.prank(user);
        weth.approve(address(app), amountIn);

        order = IAppIntentBase.IntentOrder({
            orderId: orderId,
            app: address(app),
            intentSelector: app.SWAP_SELECTOR(),
            intentParams: abi.encode(address(weth), address(usdc), amountIn, uint256(1800e6), user, uint256(0)),
            submittedBy: user,
            chainId: block.chainid,
            deadline: block.timestamp + 3600,
            nonce: type(uint256).max,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](2);
        calls[0] = IAppIntentBase.Call({
            target: address(weth),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(router), amountIn))
        });
        calls[1] = IAppIntentBase.Call({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(router.swap, (address(weth), address(usdc), amountIn, 0, address(app)))
        });
        plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: order.deadline,
            nonce: 0,
            metadata: ""
        });
    }

    /// @dev A realistic set: this plan (forward leg) + a placeholder revert
    ///      leg hash, signed by the user.
    function _signedSet(
        IAppIntentBase.IntentOrder memory order,
        IAppIntentBase.ExecutionPlan memory plan
    ) internal view returns (bytes32[] memory setHashes, bytes memory sig) {
        setHashes = _setOf(plan);
        sig = _signPlanSet(userKey, order.orderId, setHashes);
    }

    function _setOf(
        IAppIntentBase.ExecutionPlan memory plan
    ) internal pure returns (bytes32[] memory setHashes) {
        setHashes = new bytes32[](2);
        setHashes[0] = EIP712Verifier.hashPlanMem(plan);
        setHashes[1] = keccak256("revert leg plan");
    }

    function _signPlanSet(
        uint256 key,
        bytes32 orderId,
        bytes32[] memory setHashes
    ) internal pure returns (bytes memory) {
        bytes32 planSetHash = keccak256(abi.encodePacked(setHashes));
        bytes32 structHash = keccak256(abi.encode(
            EIP712Verifier.PLAN_SET_APPROVAL_TYPEHASH,
            orderId,
            planSetHash
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", EIP712Verifier.PLAN_SET_DOMAIN_SEPARATOR, structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOrder(IAppIntentBase.IntentOrder memory order) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            EIP712Verifier.INTENT_ORDER_TYPEHASH,
            order.orderId,
            order.app,
            order.intentSelector,
            keccak256(order.intentParams),
            order.submittedBy,
            order.chainId,
            order.deadline,
            order.nonce,
            order.perpetual,
            order.maxExecutions,
            order.cooldown
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validatorSigs(
        bytes32 orderId,
        IAppIntentBase.ExecutionPlan memory plan
    ) internal view returns (bytes[] memory sigs) {
        bytes32 planHash = EIP712Verifier.hashPlanMem(plan);
        uint256 threshold = app.scoreThreshold();
        sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 structHash = keccak256(abi.encode(
                EIP712Verifier.PLAN_APPROVAL_TYPEHASH,
                orderId,
                planHash,
                threshold
            ));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorKeys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _sortValidators() internal {
        for (uint256 i = 0; i < validatorAddrs.length; i++) {
            for (uint256 j = i + 1; j < validatorAddrs.length; j++) {
                if (validatorAddrs[i] > validatorAddrs[j]) {
                    (validatorAddrs[i], validatorAddrs[j]) = (validatorAddrs[j], validatorAddrs[i]);
                    (validatorKeys[i], validatorKeys[j]) = (validatorKeys[j], validatorKeys[i]);
                }
            }
        }
    }
}
