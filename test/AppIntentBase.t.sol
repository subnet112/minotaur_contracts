// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AppIntentBase.sol";
import "../src/ValidatorRegistry.sol";
import "../src/EIP712Verifier.sol";
import "./mocks/MockApp.sol";
import "./mocks/MockToken.sol";
import "./mocks/MockRouter.sol";
import "./mocks/HelperHarness.sol";
import "./mocks/MockWETH9.sol";

contract AppIntentBaseTest is Test {
    MockApp public app;
    ValidatorRegistry public registry;
    MockToken public weth;
    MockToken public usdc;
    MockRouter public router;

    // Test accounts
    address public relayerAddr;
    uint256 public relayerKey;
    address public user;
    uint256 public userKey;
    address public feeCollector;
    address[] public validatorAddrs;
    uint256[] public validatorKeys;

    bytes32 public DOMAIN_SEPARATOR;

    function setUp() public {
        // Generate test accounts
        (relayerAddr, relayerKey) = makeAddrAndKey("relayer");
        (user, userKey) = makeAddrAndKey("user");
        feeCollector = makeAddr("feeCollector");

        // Create 3 validators
        for (uint256 i = 0; i < 3; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string(abi.encodePacked("validator", vm.toString(i))));
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }

        // Sort validators by address (required for signature verification)
        _sortValidators();

        // Deploy registry first (holds canonical quorumBps), then app
        registry = new ValidatorRegistry(relayerAddr, validatorAddrs, 8000);
        weth = new MockToken("Wrapped ETH", "WETH", 18);
        app = new MockApp(relayerAddr, address(registry), 5000, address(weth), relayerAddr, 0.1 ether, feeCollector, 5000);
        usdc = new MockToken("USD Coin", "USDC", 6);
        router = new MockRouter();

        DOMAIN_SEPARATOR = app.DOMAIN_SEPARATOR();

        // Fund router with USDC for swaps
        usdc.mint(address(router), 1_000_000e6);
    }

    // ── Validator quorum tests ───────────────────────────────────────────

    function test_quorumRequired() public view {
        // 80% of 3 = 2.4, ceil = 3
        assertEq(app.getQuorumRequired(), 3);
    }

    function test_updateValidators() public {
        address[] memory newValidators = new address[](2);
        newValidators[0] = address(0x100);
        newValidators[1] = address(0x200);

        vm.prank(relayerAddr);
        registry.updateValidators(newValidators);

        assertEq(app.getQuorumRequired(), 2); // 80% of 2 = 1.6, ceil = 2
        assertTrue(registry.isValidator(address(0x100)));
        assertTrue(registry.isValidator(address(0x200)));
        assertFalse(registry.isValidator(validatorAddrs[0]));
    }

    function test_updateValidators_onlyOwner() public {
        address[] memory newValidators = new address[](1);
        newValidators[0] = address(0x100);

        vm.expectRevert("Only owner");
        registry.updateValidators(newValidators);
    }

    // ── Registry reference ─────────────────────────────────────────────

    function test_validatorRegistryAddress() public view {
        assertEq(app.validatorRegistry(), address(registry));
    }

    // ── Nonce and replay tests ───────────────────────────────────────────

    function test_noncesStartAtZero() public view {
        assertEq(app.nonces(user), 0);
    }

    function test_isNotExecutedInitially() public view {
        assertFalse(app.executedOrders(bytes32(uint256(1))));
    }

    // ── Intent registration tests ────────────────────────────────────────

    function test_swapIntentRegistered() public view {
        bytes4 swapSelector = bytes4(keccak256("swap(address,address,uint256,uint256,address)"));
        assertTrue(app.registeredIntents(swapSelector));
    }

    // ── Score threshold tests ────────────────────────────────────────────

    function test_scoreThresholdDefault() public view {
        assertEq(app.scoreThreshold(), 5000);
    }

    function test_updateScoreThreshold() public {
        vm.prank(relayerAddr);
        app.updateScoreThreshold(7000);
        assertEq(app.scoreThreshold(), 7000);
    }

    function test_updateScoreThreshold_onlyRelayer() public {
        vm.expectRevert("Only relayer");
        app.updateScoreThreshold(7000);
    }

    function test_updateScoreThreshold_revert_zero() public {
        vm.prank(relayerAddr);
        vm.expectRevert("Threshold must be 5000-10000");
        app.updateScoreThreshold(0);
    }

    function test_updateScoreThreshold_revert_tooHigh() public {
        vm.prank(relayerAddr);
        vm.expectRevert("Threshold must be 5000-10000");
        app.updateScoreThreshold(10001);
    }

    // ── EIP-712 hashing tests ────────────────────────────────────────────

    function test_planHashDeterministic() public pure {
        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(0x1),
            value: 0,
            callData: hex"deadbeef"
        });

        IAppIntentBase.ExecutionPlan memory plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: 1700000000,
            nonce: 1,
            metadata: ""
        });

        bytes32 h1 = EIP712Verifier.hashPlanMem(plan);
        bytes32 h2 = EIP712Verifier.hashPlanMem(plan);
        assertEq(h1, h2);
        assertTrue(h1 != bytes32(0));
    }

    // ── Validator getters ────────────────────────────────────────────────

    function test_getValidators() public view {
        address[] memory vals = app.getValidators();
        assertEq(vals.length, 3);
    }

    function test_relayer() public view {
        assertEq(app.relayer(), relayerAddr);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _sortValidators() internal {
        // Simple bubble sort for test setup
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

// ── Helper function tests ─────────────────────────────────────────────────

contract AppIntentBaseHelpersTest is Test {
    HelperHarness public harness;
    ValidatorRegistry public registry;
    MockToken public tokenA;
    MockToken public tokenB;

    address public relayerAddr;
    address public user;

    function setUp() public {
        (relayerAddr,) = makeAddrAndKey("relayer");
        (user,) = makeAddrAndKey("user");

        address[] memory validators = new address[](1);
        validators[0] = address(0x100);
        registry = new ValidatorRegistry(relayerAddr, validators, 8000);
        harness = new HelperHarness(relayerAddr, address(registry), 5000, address(0), address(0), 0);

        tokenA = new MockToken("Token A", "TKA", 18);
        tokenB = new MockToken("Token B", "TKB", 18);
    }

    // ── _snapshot / _gained ───────────────────────────────────────────────

    function test_snapshot_and_gained() public {
        // Mint some tokenA to harness
        tokenA.mint(address(harness), 100e18);
        harness.snapshot(address(tokenA));

        // Simulate gains — mint more tokens to harness
        tokenA.mint(address(harness), 50e18);

        assertEq(harness.gained(address(tokenA)), 50e18);
    }

    function test_gained_no_change() public {
        tokenA.mint(address(harness), 100e18);
        harness.snapshot(address(tokenA));

        // No transfer
        assertEq(harness.gained(address(tokenA)), 0);
    }

    function test_gained_underflow_returns_zero() public {
        tokenA.mint(address(harness), 100e18);
        harness.snapshot(address(tokenA));

        // Reduce balance below snapshot (burn)
        tokenA.burn(address(harness), 30e18);

        // Should return 0, not revert
        assertEq(harness.gained(address(tokenA)), 0);
    }

    function test_snapshot_multiple_tokens() public {
        tokenA.mint(address(harness), 100e18);
        tokenB.mint(address(harness), 200e18);

        harness.snapshot(address(tokenA));
        harness.snapshot(address(tokenB));

        tokenA.mint(address(harness), 10e18);
        tokenB.mint(address(harness), 20e18);

        assertEq(harness.gained(address(tokenA)), 10e18);
        assertEq(harness.gained(address(tokenB)), 20e18);
    }

    // ── _scoreLinear ──────────────────────────────────────────────────────

    function test_scoreLinear_belowMinimum() public view {
        assertEq(harness.scoreLinear(99, 100), 0);
    }

    function test_scoreLinear_atMinimum() public view {
        assertEq(harness.scoreLinear(100, 100), 5000);
    }

    function test_scoreLinear_atDouble() public view {
        assertEq(harness.scoreLinear(200, 100), 10000);
    }

    function test_scoreLinear_aboveDouble() public view {
        assertEq(harness.scoreLinear(300, 100), 10000);
    }

    function test_scoreLinear_between() public view {
        // 150 is halfway between 100 and 200 → 5000 + 2500 = 7500
        assertEq(harness.scoreLinear(150, 100), 7500);
    }

    function test_scoreLinear_zero_minimum() public view {
        // Edge case: minimum = 0 would divide by zero, but actual >= 0 * 2 = 0
        // so it returns 10000 (the >= 2x check hits first)
        assertEq(harness.scoreLinear(0, 0), 10000);
    }

    // ── _fundAndExecute ───────────────────────────────────────────────────

    function test_fundAndExecute() public {
        // Mint tokens to user and approve harness
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(harness), 100e18);

        // Build a minimal order and empty plan
        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](0);
        IAppIntentBase.IntentOrder memory order = IAppIntentBase.IntentOrder({
            orderId: bytes32(uint256(1)),
            app: address(harness),
            intentSelector: harness.TEST_SELECTOR(),
            intentParams: abi.encode(uint256(42)),
            submittedBy: user,
            chainId: block.chainid,
            deadline: block.timestamp + 1000,
            nonce: 0,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });
        IAppIntentBase.ExecutionPlan memory plan = IAppIntentBase.ExecutionPlan({
            calls: calls,
            deadline: block.timestamp + 1000,
            nonce: 0,
            metadata: ""
        });

        // fundAndExecute: deploys proxy, transfers tokens from user to proxy, runs plan
        harness.fundAndExecute(order, plan, address(tokenA), user, 50e18);

        // User should have 50e18 remaining
        assertEq(tokenA.balanceOf(user), 50e18);
    }
}

// ── Native ETH path tests for _fundAndExecute ─────────────────────────────
// These use a second harness instance with a real MockWETH9 as the
// wrappedNativeToken so we can exercise the msg.value → wrap → transfer
// code path added for seamless one-transaction ETH swaps.

contract AppIntentBaseNativeFundingTest is Test {
    HelperHarness public harness;
    ValidatorRegistry public registry;
    MockWETH9 public weth;

    address public relayerAddr;
    address public user;
    uint256 public userKey;

    // IntentOrder + ExecutionPlan factories keep the tests readable.
    function _buildOrder() internal view returns (IAppIntentBase.IntentOrder memory) {
        return IAppIntentBase.IntentOrder({
            orderId: bytes32(uint256(0xdeadbeef)),
            app: address(harness),
            intentSelector: harness.TEST_SELECTOR(),
            intentParams: abi.encode(uint256(42)),
            submittedBy: user,
            chainId: block.chainid,
            deadline: block.timestamp + 1000,
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
            deadline: block.timestamp + 1000,
            nonce: 0,
            metadata: ""
        });
    }

    function setUp() public {
        (relayerAddr,) = makeAddrAndKey("relayer");
        (user, userKey) = makeAddrAndKey("user");

        address[] memory validators = new address[](1);
        validators[0] = address(0x100);
        registry = new ValidatorRegistry(relayerAddr, validators, 8000);

        // Real WETH9-compatible mock for the native path.
        weth = new MockWETH9();

        harness = new HelperHarness(
            relayerAddr,
            address(registry),
            5000,          // scoreThreshold
            address(weth), // wrappedNativeToken
            address(0),    // platformFeeCollector
            0              // maxPlatformFeeWei
        );

        vm.deal(user, 100 ether);
    }

    // ── Path 1: msg.value == amount, token == WETH ────────────────────────
    // Happy path: user sends exactly the right amount of ETH, no refund.

    function test_native_exactAmount_wrapsAndFundsProxy() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder();
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        uint256 amount = 1 ether;
        uint256 userEthBefore = user.balance;

        vm.prank(user);
        address proxy = harness.fundAndExecute{value: amount}(
            order, plan, address(weth), user, amount
        );

        // Proxy received wrapped WETH.
        assertEq(weth.balanceOf(proxy), amount, "proxy should hold wrapped WETH");
        // No excess refund — user spent exactly `amount` in ETH.
        assertEq(user.balance, userEthBefore - amount, "user ETH should be deducted");
        // Contract itself holds no leftover ETH.
        assertEq(address(harness).balance, 0, "harness should hold no ETH");
    }

    // ── Path 2: msg.value > amount, refund excess ─────────────────────────
    // User sends more ETH than needed — the excess must be refunded to them.

    function test_native_excess_refundsToUser() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder();
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        uint256 amount = 1 ether;
        uint256 msgValue = 1.5 ether;  // 0.5 ETH excess
        uint256 userEthBefore = user.balance;

        vm.prank(user);
        address proxy = harness.fundAndExecute{value: msgValue}(
            order, plan, address(weth), user, amount
        );

        assertEq(weth.balanceOf(proxy), amount, "proxy should hold exactly `amount` WETH");
        // Net ETH spent = amount (wrapped) + 0 (refund of excess)
        assertEq(user.balance, userEthBefore - amount, "user ETH should be refunded excess");
        assertEq(address(harness).balance, 0, "harness should hold no ETH");
    }

    // ── Path 3: msg.value < amount, revert ────────────────────────────────

    function test_native_insufficientMsgValue_reverts() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder();
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        uint256 amount = 1 ether;
        uint256 msgValue = 0.5 ether;

        vm.prank(user);
        vm.expectRevert(bytes("Insufficient msg.value"));
        harness.fundAndExecute{value: msgValue}(
            order, plan, address(weth), user, amount
        );
    }

    // ── Path 4: ERC-20 fallback when msg.value == 0 ───────────────────────
    // With msg.value == 0, the new branch must NOT activate even though
    // `token == wrappedNativeToken` — must fall through to safeTransferFrom.

    function test_erc20_path_whenMsgValueZero_onWethToken() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder();
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        uint256 amount = 1 ether;

        // Give user WETH by depositing ETH into the mock.
        vm.prank(user);
        weth.deposit{value: amount}();
        vm.prank(user);
        weth.approve(address(harness), amount);

        uint256 userEthBefore = user.balance;

        vm.prank(user);
        address proxy = harness.fundAndExecute(  // no value => msg.value == 0
            order, plan, address(weth), user, amount
        );

        assertEq(weth.balanceOf(proxy), amount, "proxy should hold pulled WETH");
        assertEq(weth.balanceOf(user), 0, "user WETH should be spent");
        assertEq(user.balance, userEthBefore, "user ETH balance unchanged");
    }

    // ── Path 5: msg.value > 0 but token != WETH → ERC-20 fallback ─────────
    // Edge case: user accidentally attaches ETH but the order targets a
    // non-native token. Behaviour: still fall through to safeTransferFrom
    // (we don't wrap arbitrary tokens). The ETH becomes trapped unless
    // _runPlan or fallback refunds it — acceptable since the blockloop
    // only sets _user_submit for native input swaps.

    function test_msgValueAttached_withNonWethToken_usesErc20Path() public {
        IAppIntentBase.IntentOrder memory order = _buildOrder();
        IAppIntentBase.ExecutionPlan memory plan = _emptyPlan();

        // A different ERC-20 (not WETH).
        MockToken dai = new MockToken("Dai", "DAI", 18);
        dai.mint(user, 100e18);
        vm.prank(user);
        dai.approve(address(harness), 100e18);

        vm.prank(user);
        address proxy = harness.fundAndExecute{value: 0.1 ether}(
            order, plan, address(dai), user, 10e18
        );

        assertEq(dai.balanceOf(proxy), 10e18, "proxy should receive DAI via safeTransferFrom");
        // The 0.1 ETH attached ends up stuck in the harness — documented quirk.
        // The frontend only sets _user_submit when input token is WETH, so
        // this path is not reachable through normal flow.
        assertEq(address(harness).balance, 0.1 ether);
    }
}
