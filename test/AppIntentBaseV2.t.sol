// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AppIntentBaseV2.sol";
import "../src/ValidatorRegistry.sol";
import "../src/EIP712Verifier.sol";
import "./mocks/MockAppV2.sol";
import "./mocks/MockToken.sol";
import "./mocks/MockRouter.sol";

/// @notice V2 base coverage: the full executeIntent pipeline (signatures,
///         quorum, plan execution, scoring) on the gas-optimized base, plus
///         the properties V2 changes touch — clone-per-order isolation,
///         lean replay protection, and the executeCrossChainLeg alias.
contract AppIntentBaseV2Test is Test {
    MockAppV2 public app;
    ValidatorRegistry public registry;
    MockToken public weth;
    MockToken public usdc;
    MockRouter public router;

    address public relayerAddr;
    uint256 public relayerKey;
    address public user;
    uint256 public userKey;
    address public feeCollector;
    address[] public validatorAddrs;
    uint256[] public validatorKeys;

    bytes32 public DOMAIN_SEPARATOR;

    function setUp() public {
        (relayerAddr, relayerKey) = makeAddrAndKey("relayer");
        (user, userKey) = makeAddrAndKey("user");
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

    // ── Full pipeline ────────────────────────────────────────────────────

    function test_executeIntent_fullPipeline() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _swapOrder(keccak256("v2_e2e"), 0);

        _execute(order, plan);

        assertEq(usdc.balanceOf(user), 1800e6, "user received swap output");
        assertEq(app.nonces(user), 1, "nonce incremented");
    }

    // ── Clone isolation (the property the clone model buys) ─────────────

    function test_cloneIsolation_freshAddressPerOrder() public {
        bytes32 orderA = keccak256("v2_iso_a");
        bytes32 orderB = keccak256("v2_iso_b");

        address proxyA = app.predictProxy(orderA);
        address proxyB = app.predictProxy(orderB);
        assertTrue(proxyA != proxyB, "each order gets its own executor address");
        assertEq(proxyA.code.length, 0, "clone does not exist before execution");

        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _swapOrder(orderA, 0);
        _execute(order, plan);

        assertGt(proxyA.code.length, 0, "clone deployed at the predicted address");
        assertEq(weth.balanceOf(proxyA), 0, "used clone holds nothing");

        // Dangling state on a used clone is unreachable: the address is never
        // funded again and execute() is gated to the app.
        IAppIntentBase.Call[] memory sweep = new IAppIntentBase.Call[](0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Only app");
        ExecutorProxy(payable(proxyA)).execute(sweep);
    }

    // ── Lean replay protection ───────────────────────────────────────────

    function test_replay_noncedOrder_rejectedByNonce() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _swapOrder(keccak256("v2_replay_nonced"), 0);
        _execute(order, plan);

        // V2 does not write executedOrders for nonced orders...
        assertFalse(app.executedOrders(order.orderId), "no bitmap write for nonced orders");

        // ...because the nonce is already a complete replay guard.
        weth.mint(user, 1e18);
        vm.prank(user);
        weth.approve(address(app), 1e18);
        bytes memory userSig = _signOrder(order);
        bytes[] memory sigs = _validatorSigs(order.orderId, plan);
        vm.expectRevert("Invalid nonce");
        app.executeIntent(order, plan, userSig, sigs);
    }

    function test_replay_sentinelNonceOrder_rejectedByBitmap() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _swapOrder(keccak256("v2_replay_sentinel"), type(uint256).max);
        _execute(order, plan);

        assertTrue(app.executedOrders(order.orderId), "sentinel orders use the bitmap");

        weth.mint(user, 1e18);
        vm.prank(user);
        weth.approve(address(app), 1e18);
        bytes memory userSig = _signOrder(order);
        bytes[] memory sigs = _validatorSigs(order.orderId, plan);
        vm.expectRevert("Already executed");
        app.executeIntent(order, plan, userSig, sigs);
    }

    // ── Relayer-compat alias ─────────────────────────────────────────────

    function test_executeCrossChainLeg_aliasWorks() public {
        (IAppIntentBase.IntentOrder memory order, IAppIntentBase.ExecutionPlan memory plan) =
            _swapOrder(keccak256("v2_leg_alias"), type(uint256).max);

        bytes memory userSig = _signOrder(order);
        bytes[] memory sigs = _validatorSigs(order.orderId, plan);

        app.executeCrossChainLeg(order, plan, 0, userSig, sigs);

        assertTrue(app.legExecuted(order.orderId, 0), "leg marked executed");
        assertEq(usdc.balanceOf(user), 1800e6, "leg delivered output");
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _swapOrder(bytes32 orderId, uint256 nonce) internal returns (
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
            // Trailing word = platformFeeWei (0), read by _decodePlatformFee.
            intentParams: abi.encode(address(weth), address(usdc), amountIn, uint256(1800e6), user, uint256(0)),
            submittedBy: user,
            chainId: block.chainid,
            deadline: block.timestamp + 3600,
            nonce: nonce,
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

    function _execute(
        IAppIntentBase.IntentOrder memory order,
        IAppIntentBase.ExecutionPlan memory plan
    ) internal {
        bytes memory userSig = _signOrder(order);
        bytes[] memory sigs = _validatorSigs(order.orderId, plan);
        app.executeIntent(order, plan, userSig, sigs);
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
