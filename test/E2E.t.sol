// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AppIntentBase.sol";
import "../src/ValidatorRegistry.sol";
import "../src/EIP712Verifier.sol";
import "./mocks/MockApp.sol";
import "./mocks/MockToken.sol";
import "./mocks/TestSwapRouter.sol";

/// @title E2E Test - Full executeIntent flow in pure Solidity
/// @notice Known-good reference for the Python E2E tests to match.
contract E2ETest is Test {
    MockApp public app;
    ValidatorRegistry public registry;
    MockToken public weth;
    MockToken public usdc;
    TestSwapRouter public router;

    address public relayerAddr;
    uint256 public relayerKey;
    address public userAddr;
    uint256 public userKey;
    address public feeCollector;

    address[] public validatorAddrs;
    uint256[] public validatorKeys;

    bytes32 public DOMAIN_SEPARATOR;
    bytes4 public SWAP_SELECTOR;

    function setUp() public {
        // Deterministic accounts
        (relayerAddr, relayerKey) = makeAddrAndKey("relayer");
        (userAddr, userKey) = makeAddrAndKey("user");
        feeCollector = makeAddr("feeCollector");

        // 3 validators
        for (uint256 i = 0; i < 3; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string(abi.encodePacked("validator", vm.toString(i)))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }
        _sortValidators();

        // Deploy
        weth = new MockToken("Wrapped ETH", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        router = new TestSwapRouter();
        registry = new ValidatorRegistry(relayerAddr, validatorAddrs, 8000);
        app = new MockApp(relayerAddr, address(registry), 5000, address(weth), relayerAddr, 0.1 ether, feeCollector, 5000);

        DOMAIN_SEPARATOR = app.DOMAIN_SEPARATOR();
        SWAP_SELECTOR = app.SWAP_SELECTOR();

        // Fund router with USDC reserves
        usdc.mint(address(router), 10_000_000e6);
    }

    /// @notice Full executeIntent flow: mint → sign → plan → validate → execute
    function test_fullExecuteIntent() public {
        // 1. Mint WETH to user (for the swap)
        weth.mint(userAddr, 1e18);
        vm.prank(userAddr);
        weth.approve(address(app), 1e18);

        // 2. Build order
        bytes32 orderId = keccak256("test_order_1");
        bytes memory intentParams = abi.encode(
            address(weth),    // inputToken
            address(usdc),    // outputToken
            uint256(1e18),    // inputAmount
            uint256(1800e6),  // minOutput
            userAddr,         // receiver
            uint256(0),       // permit deadline
            uint8(0),         // permit v
            bytes32(0),       // permit r
            bytes32(0),       // permit s
            uint256(0),       // platformFeeWei
            false             // unwrapOutput
        );

        IAppIntentBase.IntentOrder memory order = IAppIntentBase.IntentOrder({
            orderId: orderId,
            app: address(app),
            intentSelector: SWAP_SELECTOR,
            intentParams: intentParams,
            submittedBy: userAddr,
            chainId: block.chainid,
            deadline: block.timestamp + 3600,
            nonce: 0,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });

        // 3. Sign user order (EIP-712)
        bytes memory userSig = _signOrder(order, userKey);

        // 4. Build execution plan: router.swapExact(usdc, 1800e6, app)
        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(router.swapExact, (address(usdc), 1800e6, address(app)))
        });

        IAppIntentBase.ExecutionPlan memory plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: order.deadline,
            nonce: 0,
            metadata: ""
        });

        // 5. Compute plan hash and sign validator approvals
        bytes32 planHash = EIP712Verifier.hashPlanMem(plan);
        uint256 scoreThreshold = app.scoreThreshold();

        bytes[] memory validatorSigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            validatorSigs[i] = _signPlanApproval(
                orderId, planHash, scoreThreshold, validatorKeys[i]
            );
        }

        // 6. Execute from relayer
        vm.prank(relayerAddr);
        app.executeIntent(order, plan, userSig, validatorSigs);

        // 7. Verify
        assertGe(usdc.balanceOf(userAddr), 1800e6, "User should have USDC");
        assertEq(app.nonces(userAddr), 1, "Nonce should increment");
        assertTrue(app.executedOrders(orderId), "Order should be marked executed");
    }

    /// @notice Replay protection: same orderId should revert
    function test_replayProtection() public {
        weth.mint(userAddr, 2e18);
        vm.startPrank(userAddr);
        weth.approve(address(app), 2e18);
        vm.stopPrank();

        bytes32 orderId = keccak256("replay_test");
        bytes memory intentParams = abi.encode(
            address(weth), address(usdc), uint256(1e18), uint256(1800e6),
            userAddr, uint256(0), uint8(0), bytes32(0), bytes32(0),
            uint256(0),  // platformFeeWei
            false        // unwrapOutput
        );

        IAppIntentBase.IntentOrder memory order = IAppIntentBase.IntentOrder({
            orderId: orderId,
            app: address(app),
            intentSelector: SWAP_SELECTOR,
            intentParams: intentParams,
            submittedBy: userAddr,
            chainId: block.chainid,
            deadline: block.timestamp + 3600,
            nonce: 0,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });

        bytes memory userSig = _signOrder(order, userKey);

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(router.swapExact, (address(usdc), 1800e6, address(app)))
        });

        IAppIntentBase.ExecutionPlan memory plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: order.deadline,
            nonce: 0,
            metadata: ""
        });

        bytes32 planHash = EIP712Verifier.hashPlanMem(plan);
        uint256 scoreThreshold = app.scoreThreshold();

        bytes[] memory validatorSigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            validatorSigs[i] = _signPlanApproval(orderId, planHash, scoreThreshold, validatorKeys[i]);
        }

        // First execution succeeds
        vm.prank(relayerAddr);
        app.executeIntent(order, plan, userSig, validatorSigs);

        // Second execution with same orderId reverts
        // Update nonce for the second attempt
        order.nonce = 1;
        userSig = _signOrder(order, userKey);

        vm.prank(relayerAddr);
        vm.expectRevert("Already executed");
        app.executeIntent(order, plan, userSig, validatorSigs);
    }

    /// @notice Perpetual order supports multiple executions
    function test_perpetualOrder() public {
        weth.mint(userAddr, 10e18);
        vm.startPrank(userAddr);
        weth.approve(address(app), 10e18);
        vm.stopPrank();

        bytes32 orderId = keccak256("perpetual_test");
        bytes memory intentParams = abi.encode(
            address(weth), address(usdc), uint256(1e18), uint256(1800e6),
            userAddr, uint256(0), uint8(0), bytes32(0), bytes32(0),
            uint256(0),  // platformFeeWei
            false        // unwrapOutput
        );

        IAppIntentBase.IntentOrder memory order = IAppIntentBase.IntentOrder({
            orderId: orderId,
            app: address(app),
            intentSelector: SWAP_SELECTOR,
            intentParams: intentParams,
            submittedBy: userAddr,
            chainId: block.chainid,
            deadline: block.timestamp + 3600,
            nonce: 0,
            perpetual: true,
            maxExecutions: 3,
            cooldown: 0
        });

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(router.swapExact, (address(usdc), 1800e6, address(app)))
        });

        IAppIntentBase.ExecutionPlan memory plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: order.deadline,
            nonce: 0,
            metadata: ""
        });

        bytes32 planHash = EIP712Verifier.hashPlanMem(plan);
        uint256 scoreThreshold = app.scoreThreshold();

        bytes[] memory validatorSigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            validatorSigs[i] = _signPlanApproval(orderId, planHash, scoreThreshold, validatorKeys[i]);
        }

        // First execution succeeds
        bytes memory userSig = _signOrder(order, userKey);
        vm.prank(relayerAddr);
        app.executeIntent(order, plan, userSig, validatorSigs);
        assertEq(app.executionCounts(orderId), 1);
        assertEq(app.nonces(userAddr), 1);

        // Second execution succeeds (no CREATE2 collision)
        order.nonce = 1;
        userSig = _signOrder(order, userKey);
        vm.prank(relayerAddr);
        app.executeIntent(order, plan, userSig, validatorSigs);
        assertEq(app.executionCounts(orderId), 2);
        assertEq(app.nonces(userAddr), 2);
        assertGe(usdc.balanceOf(userAddr), 3600e6, "User got tokens from both executions");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _signOrder(
        IAppIntentBase.IntentOrder memory order,
        uint256 privateKey
    ) internal view returns (bytes memory) {
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
        bytes32 digest = _toTypedDataHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signPlanApproval(
        bytes32 orderId,
        bytes32 planHash,
        uint256 score,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            EIP712Verifier.PLAN_APPROVAL_TYPEHASH,
            orderId,
            planHash,
            score
        ));
        bytes32 digest = _toTypedDataHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _toTypedDataHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
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
