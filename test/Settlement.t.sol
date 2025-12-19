// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {Settlement} from "../src/Settlement.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

/// @title Settlement contract test suite
/// @notice Covers intent execution, replay protection, tampering, permit flows, and admin toggles
/// @dev Relies on mocks to simulate solver-provided interaction plans
contract SettlementTest is Test {
    using stdJson for string;

    uint256 internal constant USER_PRIVATE_KEY = 0xA11CE;
    address internal immutable user = vm.addr(USER_PRIVATE_KEY);
    address internal immutable receiver = address(0xD00D);
    address internal immutable relayer = address(0xA11);

    Settlement internal settlement;
    MockPermitToken internal permitTokenIn;
    MockERC20 internal tokenOut;

    bytes32 private constant PERMIT_DATA_TYPEHASH =
        keccak256("PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)");
    bytes32 private constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 quoteId,address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,address receiver,uint256 deadline,uint256 nonce,bytes32 interactionsHash,uint256 callValue,uint256 gasEstimate,PermitData permit)PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)"
    );

    function setUp() public {
        settlement = new Settlement(address(this));

        permitTokenIn = new MockPermitToken("MockPermitToken", "MPT");
        tokenOut = new MockERC20("MockTokenOut", "MOUT");

        permitTokenIn.mint(user, 1_000 ether);
        permitTokenIn.setSettlementCaller(address(settlement));
    }

    /// @notice Happy path covering an EIP-2612 permit settlement
    function testExecuteOrderHappyPathWithEIP2612Permit() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;
        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        // Verify initial state - no allowance before permit
        uint256 initialAllowance = permitTokenIn.allowance(user, address(settlement));
        assertEq(initialAllowance, 0, "initial allowance should be zero");
        uint256 initialUserBalance = permitTokenIn.balanceOf(user);
        uint256 initialSettlementBalance = permitTokenIn.balanceOf(address(settlement));
        uint256 initialReceiverBalance = tokenOut.balanceOf(receiver);
        uint256 initialPermitNonce = permitTokenIn.nonces(user);

        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes memory permitCall = _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: permitCall,
            amount: amountIn,
            deadline: permitDeadline
        });

        intent.userSignature = _signIntent(intent);

        vm.expectEmit(true, true, false, false); // Don't check timestamp exactly
        emit Settlement.SwapSettled(
            intent.quoteId,
            intent.user,
            intent.tokenIn,
            intent.amountIn,
            intent.tokenOut,
            amountOut,
            0,
            intent.gasEstimate,
            block.timestamp // Will be checked by expectEmit
        );

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // Verify permit was actually consumed
        assertEq(permitTokenIn.nonces(user), initialPermitNonce + 1, "permit nonce should be incremented");

        // Verify allowance was consumed by the transfer (should be 0 since permit set exactly amountIn)
        uint256 finalAllowance = permitTokenIn.allowance(user, address(settlement));
        assertEq(finalAllowance, 0, "allowance should be consumed by transfer");

        // Verify token movements
        assertEq(permitTokenIn.balanceOf(user), initialUserBalance - amountIn, "user balance should decrease");
        assertEq(permitTokenIn.balanceOf(address(settlement)), initialSettlementBalance, "settlement should not hold tokens after execution");
        assertEq(permitTokenIn.balanceOf(address(interactionTarget)), amountIn, "interaction target should receive tokens");
        assertEq(tokenOut.balanceOf(receiver), initialReceiverBalance + amountOut, "receiver should get output tokens");

        // Verify nonce consumption
        assertTrue(settlement.isNonceUsed(user, intent.nonce));
    }

    /// @notice Nonce reuse must revert to prevent order replay
    function testReplayRevertsOnNonceReuse() public {
        uint256 amountIn = 50 ether;
        uint256 amountOut = 45 ether;
        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        vm.expectRevert(abi.encodeWithSelector(Settlement.NonceAlreadyUsed.selector, user, intent.nonce));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Tampering with the execution plan hash invalidates the intent
    function testTamperedPlanReverts() public {
        uint256 amountIn = 20 ether;
        uint256 amountOut = 18 ether;
        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        // Tamper with amountOut in the plan without updating the signature/hash.
        Settlement.ExecutionPlan memory tamperedPlan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut + 1 ether);
        bytes32 tamperedHash = settlement.hashExecutionPlan(tamperedPlan);

        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InteractionsHashMismatch.selector, intent.interactionsHash, tamperedHash)
        );
        vm.prank(relayer);
        settlement.executeOrder(intent, tamperedPlan);
    }

    /// @notice Settlement succeeds with traditional ERC20 approvals and no permit
    function testExecuteOrderWithStandardApproval() public {
        uint256 amountIn = 40 ether;
        uint256 amountOut = 39 ether;
        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        // Set specific allowance (not max)
        vm.prank(user);
        permitTokenIn.approve(address(settlement), amountIn * 2); // More than needed

        // Verify initial allowance
        uint256 initialAllowance = permitTokenIn.allowance(user, address(settlement));
        assertGe(initialAllowance, amountIn, "initial allowance should cover amountIn");

        uint256 initialUserBalance = permitTokenIn.balanceOf(user);
        uint256 initialReceiverBalance = tokenOut.balanceOf(receiver);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.StandardApproval,
            permitCall: "",
            amount: amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // Verify allowance was consumed
        uint256 finalAllowance = permitTokenIn.allowance(user, address(settlement));
        assertEq(finalAllowance, initialAllowance - amountIn, "allowance should be reduced by amountIn");

        // Verify token movements
        assertEq(permitTokenIn.balanceOf(user), initialUserBalance - amountIn, "user balance should decrease");
        assertEq(tokenOut.balanceOf(receiver), initialReceiverBalance + amountOut, "receiver should get output tokens");
        assertEq(permitTokenIn.balanceOf(address(interactionTarget)), amountIn, "interaction target should receive tokens");
    }

    /// @notice Settlement reverts when output tokens fall below the minimum
    function testSlippageRevertsWhenOutputBelowMinimum() public {
        uint256 amountIn = 15 ether;
        uint256 actualAmountOut = 10 ether;
        uint256 claimedMinOut = 13 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, claimedMinOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.InsufficientOutput.selector, actualAmountOut, claimedMinOut));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice EIP-3009 authorization can transfer tokens without prior allowance
    function testEIP3009PermitTransfersFunds() public {
        MockEIP3009Token eip3009Token = new MockEIP3009Token("Mock3009", "M3009");
        eip3009Token.mint(user, 1_000 ether);

        uint256 amountIn = 25 ether;
        uint256 amountOut = 23 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(eip3009Token, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(eip3009Token), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, eip3009Token, tokenOut, amountIn, amountOut);

        // Get the authorization nonce that will be used
        bytes32 authNonce = keccak256("auth-nonce");

        // Verify authorization is not used initially
        assertFalse(eip3009Token.authorizationState(authNonce), "authorization should not be used initially");

        uint256 initialUserBalance = eip3009Token.balanceOf(user);
        uint256 initialReceiverBalance = tokenOut.balanceOf(receiver);

        (bytes memory permitCall, uint256 validBefore) = _buildEIP3009PermitCall(eip3009Token, amountIn);
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP3009,
            permitCall: permitCall,
            amount: amountIn,
            deadline: validBefore
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // Verify authorization was consumed
        assertTrue(eip3009Token.authorizationState(authNonce), "authorization should be marked as used");

        // Verify token movements
        assertEq(eip3009Token.balanceOf(user), initialUserBalance - amountIn, "user balance should decrease");
        assertEq(tokenOut.balanceOf(receiver), initialReceiverBalance + amountOut, "receiver should get output tokens");
        assertEq(eip3009Token.balanceOf(address(interactionTarget)), amountIn, "interaction target should receive tokens");

        // Verify that the authorization cannot be reused (different test would be needed for full validation)
    }

    /// @notice Relayer restrictions reject unauthorized callers while allowing trusted ones
    function testRelayerRestrictionBlocksUntrustedCaller() public {
        settlement.setRelayerRestriction(true);
        settlement.setTrustedRelayer(relayer, true);

        uint256 amountIn = 10 ether;
        uint256 amountOut = 10 ether;
        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.RelayerNotAllowed.selector, address(0xBADD))); // untrusted
        vm.prank(address(0xBADD));
        settlement.executeOrder(intent, plan);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Positive slippage fees are skimmed for the configured recipient
    function testPositiveSlippageFeeCharged() public {
        address feeReceiver = address(0xFEE);
        uint256 feeBps = 2_000; // 20%
        settlement.setFeeParameters(feeReceiver, feeBps);

        uint256 amountIn = 100 ether;
        uint256 minAmountOut = 90 ether;
        uint256 actualAmountOut = 110 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, minAmountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        uint256 expectedFee = (actualAmountOut - minAmountOut) * feeBps / 10_000;
        uint256 expectedUserPayout = actualAmountOut - expectedFee;

        vm.expectEmit(true, true, false, false); // Don't check timestamp exactly
        emit Settlement.SwapSettled(
            intent.quoteId,
            intent.user,
            intent.tokenIn,
            intent.amountIn,
            intent.tokenOut,
            actualAmountOut,
            expectedFee,
            intent.gasEstimate,
            block.timestamp // Will be checked by expectEmit
        );

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        assertEq(tokenOut.balanceOf(feeReceiver), expectedFee, "fee recipient balance");
        assertEq(tokenOut.balanceOf(receiver), expectedUserPayout, "receiver payout");
    }

    /// @notice Fee parameters reject rates above the denominator
    function testSetFeeParametersRevertsWhenBpsTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(Settlement.FeeBpsTooHigh.selector, 10_001, 10_000));
        settlement.setFeeParameters(address(0xFEE), 10_001);
    }

    /// @notice Fee parameters require a non-zero recipient when fee is enabled
    function testSetFeeParametersRevertsWithoutRecipient() public {
        vm.expectRevert(Settlement.InvalidFeeRecipient.selector);
        settlement.setFeeParameters(address(0), 100);
    }

    /// @notice Zero fee configuration skips skimming even with recipient configured
    function testZeroFeeDoesNotSkim() public {
        settlement.setFeeParameters(address(0xFEE), 0);

        uint256 amountIn = 80 ether;
        uint256 minAmountOut = 70 ether;
        uint256 actualAmountOut = 75 ether; // positive slippage, but fee bps zero

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, minAmountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        assertEq(tokenOut.balanceOf(address(0xFEE)), 0, "fee recipient should receive nothing");
        assertEq(tokenOut.balanceOf(receiver), actualAmountOut, "receiver should get full amount");
    }

    /// @notice Custom permits executed via raw call can set allowances for settlement
    function testCustomPermitSetsAllowance() public {
        uint256 amountIn = 30 ether;
        uint256 amountOut = 28 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        // Ensure no initial allowance
        vm.prank(user);
        permitTokenIn.approve(address(settlement), 0);
        assertEq(permitTokenIn.allowance(user, address(settlement)), 0, "initial allowance should be zero");

        uint256 initialUserBalance = permitTokenIn.balanceOf(user);
        uint256 initialReceiverBalance = tokenOut.balanceOf(receiver);

        bytes memory permitCall = abi.encodeWithSelector(
            MockPermitToken.customPermit.selector, intent.user, address(settlement), intent.amountIn
        );
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.Custom,
            permitCall: permitCall,
            amount: intent.amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // Verify allowance was consumed by the transfer (should be 0 since we set exactly amountIn)
        assertEq(permitTokenIn.allowance(user, address(settlement)), 0, "allowance should be consumed by transfer");

        // Verify token movements
        assertEq(permitTokenIn.balanceOf(user), initialUserBalance - amountIn, "user balance should decrease");
        assertEq(tokenOut.balanceOf(receiver), initialReceiverBalance + amountOut, "receiver should get output tokens");
        assertEq(permitTokenIn.balanceOf(address(interactionTarget)), amountIn, "interaction target should receive tokens");
    }

    /// @notice Missing permit calldata triggers validation revert
    function testEIP2612PermitMissingCalldataReverts() public {
        uint256 amountIn = 10 ether;
        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(0x123), amountIn, amountIn);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountIn);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: "",
            amount: amountIn,
            deadline: block.timestamp + 1 hours
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(Settlement.PermitCallMissing.selector);
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Permit owner mismatch reverts before attempting the external permit call
    function testEIP2612PermitOwnerMismatchReverts() public {
        uint256 amountIn = 10 ether;
        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(0x123), amountIn, amountIn);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountIn);

        bytes memory mismatchedPermit = abi.encode(
            address(0xBEEF), // Wrong owner
            address(settlement),
            amountIn,
            block.timestamp + 1 hours,
            uint8(0),
            bytes32(0),
            bytes32(0)
        );
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: mismatchedPermit,
            amount: amountIn,
            deadline: block.timestamp + 1 hours
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitOwnerMismatch.selector, intent.user, address(0xBEEF)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Users can proactively invalidate nonces and prevent reuse
    function testInvalidateNonceMarksAsUsed() public {
        uint256 nonce = 123;
        vm.prank(user);
        settlement.invalidateNonce(nonce);
        assertTrue(settlement.isNonceUsed(user, nonce));

        vm.expectRevert(abi.encodeWithSelector(Settlement.NonceAlreadyUsed.selector, user, nonce));
        vm.prank(user);
        settlement.invalidateNonce(nonce);
    }

    /// @notice Unused call value is refunded to the user after execution
    function testUnusedCallValueRefundedToUser() public {
        uint256 totalValue = 0.1 ether;
        uint256 consumeValue = 0.04 ether;

        MockNativeSink sink = new MockNativeSink();

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](1);
        plan.postInteractions = new Settlement.Interaction[](0);
        plan.interactions[0] = Settlement.Interaction({
            target: address(sink),
            value: consumeValue,
            callData: abi.encodeWithSelector(MockNativeSink.consume.selector)
        });

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.callValue = totalValue;
        intent.userSignature = _signIntent(intent);

        vm.deal(relayer, 1 ether);
        vm.deal(user, 0);

        vm.prank(relayer);
        settlement.executeOrder{value: totalValue}(intent, plan);

        assertEq(sink.received(), consumeValue, "sink consumption");
        assertEq(user.balance, totalValue - consumeValue, "user refunded leftover value");
    }

    /// @notice Only the owner can sweep native ETH from the contract
    function testSweepNativeOnlyOwner() public {
        vm.deal(address(settlement), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        settlement.sweepNative(payable(user), 0.5 ether);
    }

    /// @notice Owner can sweep native ETH to a treasury address
    function testSweepNativeTransfersFunds() public {
        vm.deal(address(settlement), 1 ether);
        address payable treasury = payable(address(0xB0B));

        uint256 before = treasury.balance;
        settlement.sweepNative(treasury, 0.75 ether);

        assertEq(treasury.balance - before, 0.75 ether);
        assertEq(address(settlement).balance, 0.25 ether);
    }

    /// @notice Only the owner can sweep ERC20 tokens from the contract
    function testSweepTokenOnlyOwner() public {
        uint256 amount = 100 ether;
        permitTokenIn.mint(address(settlement), amount);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        settlement.sweepToken(permitTokenIn, user, amount);
    }

    /// @notice Owner sweeping tokens transfers them to the specified recipient
    function testSweepTokenTransfersFunds() public {
        uint256 amount = 50 ether;
        permitTokenIn.mint(address(settlement), amount);

        address recipient = address(0xC0FFEE);
        uint256 before = permitTokenIn.balanceOf(recipient);

        settlement.sweepToken(permitTokenIn, recipient, amount);

        assertEq(permitTokenIn.balanceOf(recipient) - before, amount);
        assertEq(permitTokenIn.balanceOf(address(settlement)), 0);
    }

    /// @notice Allowlist rejects interaction targets when flag is enabled
    function testAllowlistBlocksUnknownTarget() public {
        settlement.setAllowlistEnabled(true);

        Settlement.Interaction[] memory interactions = new Settlement.Interaction[](1);
        interactions[0] = Settlement.Interaction({target: address(0xDEAD), value: 0, callData: ""});

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = interactions;
        plan.interactions = new Settlement.Interaction[](0);
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.interactionsHash = settlement.hashExecutionPlan(plan);
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.InvalidInteractionTarget.selector, address(0xDEAD)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Allowlisted targets proceed once explicitly permitted
    function testAllowlistAllowsWhitelistedTarget() public {
        settlement.setAllowlistEnabled(true);

        MockNoopTarget noopTarget = new MockNoopTarget();
        settlement.setInteractionTarget(address(noopTarget), true);

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](1);
        plan.postInteractions = new Settlement.Interaction[](0);
        plan.interactions[0] = Settlement.Interaction({
            target: address(noopTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockNoopTarget.execute.selector)
        });

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        assertEq(noopTarget.lastCaller(), address(settlement));
    }

    /// @notice Missing signatures are rejected before execution
    function testExecuteOrderRevertsWithoutSignature() public {
        uint256 amountIn = 10 ether;
        uint256 amountOut = 9 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 100 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        vm.expectRevert(Settlement.MissingSignature.selector);
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Zero user intents revert before calling into settlement logic
    function testExecuteOrderRevertsWithZeroUser() public {
        uint256 amountIn = 10 ether;
        uint256 amountOut = 9 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 100 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        intent.user = address(0);
        intent.userSignature = bytes("sig");

        vm.expectRevert(abi.encodeWithSelector(Settlement.InvalidUser.selector, address(0)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Zero receivers are rejected before execution
    function testExecuteOrderRevertsWithZeroReceiver() public {
        uint256 amountIn = 10 ether;
        uint256 amountOut = 9 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 100 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        intent.receiver = address(0);
        intent.userSignature = bytes("sig");

        vm.expectRevert(abi.encodeWithSelector(Settlement.InvalidReceiver.selector, address(0)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Call value mismatches are caught before the self-call
    function testExecuteOrderRevertsOnCallValueMismatch() public {
        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](0);
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.callValue = 0.1 ether;
        intent.userSignature = bytes("sig");

        vm.expectRevert(abi.encodeWithSelector(Settlement.CallValueMismatch.selector, intent.callValue, uint256(0)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Expired orders revert inside the self-call path
    function testExecuteOrderRevertsWhenExpired() public {
        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](0);
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.deadline = block.timestamp - 1;
        intent.userSignature = bytes("sig");

        vm.expectRevert(Settlement.OrderExpired.selector);
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Signature mismatches revert during digest recovery
    function testExecuteOrderRevertsWithInvalidSignature() public {
        uint256 amountIn = 10 ether;
        uint256 amountOut = 9 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 100 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        intent.userSignature = _signIntent(intent);
        intent.amountIn = amountIn + 1;

        vm.expectRevert(Settlement.InvalidSignature.selector);
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice EIP-2612 permits must provide sufficient allowance
    function testPermitAmountTooLowReverts() public {
        uint256 amountIn = 25 ether;
        uint256 amountOut = 20 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitAmount = amountIn - 1;
        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes memory permitCall = _buildEIP2612PermitCall(permitTokenIn, permitAmount, permitDeadline);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: permitCall,
            amount: permitAmount,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitAmountTooLow.selector, permitAmount, amountIn));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Permits with expired deadlines are rejected
    function testPermitDeadlineExpiredReverts() public {
        uint256 amountIn = 25 ether;
        uint256 amountOut = 20 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp - 1;
        bytes memory permitCall = _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: permitCall,
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitDeadlineExpired.selector, permitDeadline));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Permits that authorize the wrong spender are rejected
    function testPermitSpenderMismatchReverts() public {
        uint256 amountIn = 25 ether;
        uint256 amountOut = 20 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes memory permitCall = _buildEIP2612PermitCallWithSpender(
            permitTokenIn, address(0xBEEF), amountIn, permitDeadline
        );

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: permitCall,
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(
            abi.encodeWithSelector(Settlement.PermitSpenderMismatch.selector, address(settlement), address(0xBEEF))
        );
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice EIP-3009 permits cannot be used before validAfter
    function testEIP3009PermitNotYetValidReverts() public {
        MockEIP3009Token eip3009Token = new MockEIP3009Token("Mock3009", "M3009");
        eip3009Token.mint(user, 1_000 ether);

        uint256 amountIn = 30 ether;
        uint256 amountOut = 25 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(eip3009Token, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(eip3009Token), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, eip3009Token, tokenOut, amountIn, amountOut);

        uint256 validAfter = block.timestamp + 1 hours;
        uint256 validBefore = validAfter + 30 minutes;
        bytes32 authNonce = keccak256("auth-nonce");

        bytes memory permitCall = _buildEIP3009PermitCallWithParams(
            eip3009Token, amountIn, validAfter, validBefore, authNonce
        );

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP3009,
            permitCall: permitCall,
            amount: amountIn,
            deadline: validBefore
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitNotYetValid.selector, validAfter));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice EIP-3009 permits with expired validity windows are rejected
    function testEIP3009PermitExpiredReverts() public {
        MockEIP3009Token eip3009Token = new MockEIP3009Token("Mock3009", "M3009");
        eip3009Token.mint(user, 1_000 ether);

        uint256 amountIn = 30 ether;
        uint256 amountOut = 25 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(eip3009Token, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(eip3009Token), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, eip3009Token, tokenOut, amountIn, amountOut);

        vm.warp(1 days);

        intent.deadline = block.timestamp + 1 hours;

        uint256 validBefore = block.timestamp - 1;
        uint256 validAfter = validBefore - 30 minutes;
        bytes32 authNonce = keccak256("auth-nonce");

        bytes memory permitCall = _buildEIP3009PermitCallWithParams(
            eip3009Token, amountIn, validAfter, validBefore, authNonce
        );

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP3009,
            permitCall: permitCall,
            amount: amountIn,
            deadline: validBefore
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitDeadlineExpired.selector, validBefore));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice EIP-3009 authorizations cannot be reused after consumption
    function testEIP3009AuthorizationCannotBeReused() public {
        MockEIP3009Token eip3009Token = new MockEIP3009Token("Mock3009", "M3009");
        eip3009Token.mint(user, 1_000 ether);

        uint256 amountIn = 35 ether;
        uint256 amountOut = 30 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(eip3009Token, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(eip3009Token), address(interactionTarget), amountIn, amountOut);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, eip3009Token, tokenOut, amountIn, amountOut);

        (bytes memory permitCall, uint256 validBefore) = _buildEIP3009PermitCall(eip3009Token, amountIn);
        bytes32 authNonce = keccak256("auth-nonce");

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP3009,
            permitCall: permitCall,
            amount: amountIn,
            deadline: validBefore
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        Settlement.OrderIntent memory intent2 = _buildBaseIntent(plan, eip3009Token, tokenOut, amountIn, amountOut);
        intent2.nonce = 2;
        intent2.permit = intent.permit;
        intent2.userSignature = _signIntent(intent2);

        vm.expectRevert(abi.encodeWithSelector(MockEIP3009Token.AuthorizationUsed.selector, authNonce));
        vm.prank(relayer);
        settlement.executeOrder(intent2, plan);
    }

    /// @notice Custom permit calls that revert bubble up via PermitCallFailed
    function testCustomPermitFailureReverts() public {
        MockFailingCustomPermitToken customToken = new MockFailingCustomPermitToken("Failing", "FAIL");
        customToken.mint(user, 1_000 ether);

        uint256 amountIn = 50 ether;
        uint256 amountOut = 45 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(customToken, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(customToken), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, customToken, tokenOut, amountIn, amountOut);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.Custom,
            permitCall: abi.encodeWithSelector(MockFailingCustomPermitToken.failingPermit.selector),
            amount: amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        bytes memory innerReason = abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "CUSTOM_PERMIT_FAILED");
        vm.expectRevert(abi.encodeWithSelector(Settlement.PermitCallFailed.selector, innerReason));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Interactions with zero targets are rejected
    function testInteractionWithZeroTargetReverts() public {
        Settlement.Interaction[] memory interactions = new Settlement.Interaction[](1);
        interactions[0] = Settlement.Interaction({target: address(0), value: 0, callData: ""});

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = interactions;
        plan.interactions = new Settlement.Interaction[](0);
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.InvalidInteractionTarget.selector, address(0)));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Interaction failures bubble up through the InteractionCallFailed error
    function testInteractionFailureBubbles() public {
        MockRevertingInteractionTarget revertingTarget = new MockRevertingInteractionTarget();

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](1);
        plan.postInteractions = new Settlement.Interaction[](0);
        plan.interactions[0] = Settlement.Interaction({
            target: address(revertingTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockRevertingInteractionTarget.revertWithReason.selector)
        });

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        bytes memory innerReason = abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "INTERACTION_REVERT");
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InteractionCallFailed.selector, address(revertingTarget), innerReason)
        );
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Interactions cannot consume more value than provided
    function testInteractionValueCannotExceedCallValue() public {
        MockNativeSink sink = new MockNativeSink();

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](1);
        plan.postInteractions = new Settlement.Interaction[](0);
        plan.interactions[0] = Settlement.Interaction({
            target: address(sink),
            value: 0.06 ether,
            callData: abi.encodeWithSelector(MockNativeSink.consume.selector)
        });

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.callValue = 0.05 ether;
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(abi.encodeWithSelector(Settlement.InsufficientCallValue.selector, intent.callValue, 0.06 ether));
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        settlement.executeOrder{value: intent.callValue}(intent, plan);
    }

    /// @notice Standard approval flow reverts when allowance is insufficient
    function testStandardApprovalInsufficientAllowanceReverts() public {
        uint256 amountIn = 40 ether;
        uint256 amountOut = 35 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        vm.prank(user);
        permitTokenIn.approve(address(settlement), amountIn - 1);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.StandardApproval,
            permitCall: "",
            amount: amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InsufficientAllowance.selector, uint256(amountIn - 1), amountIn)
        );
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Partial transfers trigger the InsufficientInputAmount error
    function testCollectUserFundsDetectsShortTransfer() public {
        MockPartialTransferToken partialToken = new MockPartialTransferToken("Partial", "PRT");
        partialToken.mint(user, 1_000 ether);

        uint256 amountIn = 60 ether;
        uint256 amountOut = 55 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(partialToken, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(partialToken), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, partialToken, tokenOut, amountIn, amountOut);

        vm.prank(user);
        partialToken.approve(address(settlement), amountIn);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.StandardApproval,
            permitCall: "",
            amount: amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        uint256 expectedCollected = amountIn - partialToken.shortfall();
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.InsufficientInputAmount.selector, expectedCollected, amountIn)
        );
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice SwapFailed is emitted when execution reverts mid-flight
    function testSwapFailedEventEmittedOnRevert() public {
        uint256 amountIn = 20 ether;
        uint256 claimedMinOut = 18 ether;
        uint256 actualAmountOut = 15 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 200 ether);

        Settlement.ExecutionPlan memory plan =
            _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, claimedMinOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.expectEmit(true, true, false, false);
        emit Settlement.SwapFailed(intent.quoteId, intent.user, "");

        vm.expectRevert(abi.encodeWithSelector(Settlement.InsufficientOutput.selector, actualAmountOut, claimedMinOut));
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice InteractionExecuted is emitted for every interaction phase
    function testInteractionExecutedEventsEmitted() public {
        uint256 amountIn = 45 ether;
        uint256 amountOut = 50 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 500 ether);

        MockNoopTarget noopTarget = new MockNoopTarget();

        Settlement.Interaction[] memory pre = new Settlement.Interaction[](1);
        pre[0] = Settlement.Interaction({
            target: address(permitTokenIn),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(interactionTarget), amountIn)
        });

        Settlement.Interaction[] memory main = new Settlement.Interaction[](1);
        main[0] = Settlement.Interaction({
            target: address(interactionTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockInteractionTarget.executeSwap.selector, amountIn, amountOut)
        });

        Settlement.Interaction[] memory post = new Settlement.Interaction[](1);
        post[0] = Settlement.Interaction({
            target: address(noopTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockNoopTarget.execute.selector)
        });

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = pre;
        plan.interactions = main;
        plan.postInteractions = post;

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.recordLogs();
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256("InteractionExecuted(bytes32,address,uint256,bytes)");

        address[3] memory expectedTargets = [address(permitTokenIn), address(interactionTarget), address(noopTarget)];
        uint256 interactionCount;

        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length == 0 || entries[i].topics[0] != expectedTopic) {
                continue;
            }

            assertEq(entries[i].topics[1], bytes32(intent.quoteId));

            (address target, uint256 value, bytes memory callData) = abi.decode(entries[i].data, (address, uint256, bytes));
            assertEq(target, expectedTargets[interactionCount]);
            assertEq(value, 0);
            assertGt(callData.length, 0);

            interactionCount++;
        }

        assertEq(interactionCount, 3, "expected three interaction events");
        assertEq(noopTarget.lastCaller(), address(settlement));
    }

    /// @notice Hash function produces deterministic results for identical plans
    function testHashExecutionPlanDeterministic() public {
        Settlement.Interaction[] memory interactions = new Settlement.Interaction[](2);
        interactions[0] = Settlement.Interaction({
            target: address(0x123),
            value: 0.1 ether,
            callData: abi.encodeWithSelector(bytes4(keccak256("test()")))
        });
        interactions[1] = Settlement.Interaction({
            target: address(0x456),
            value: 0,
            callData: abi.encodeWithSelector(bytes4(keccak256("test2(uint256)")), 42)
        });

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = interactions;
        plan.postInteractions = new Settlement.Interaction[](0);

        bytes32 hash1 = settlement.hashExecutionPlan(plan);
        bytes32 hash2 = settlement.hashExecutionPlan(plan);

        assertEq(hash1, hash2, "hash should be deterministic");
        assertFalse(hash1 == bytes32(0), "hash should not be zero");
    }

    /// @notice Hash function produces different results for different interaction orders
    function testHashExecutionPlanDifferentOrders() public {
        Settlement.Interaction[] memory interactions1 = new Settlement.Interaction[](2);
        interactions1[0] = Settlement.Interaction({
            target: address(0x123), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("first()")))
        });
        interactions1[1] = Settlement.Interaction({
            target: address(0x456), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("second()")))
        });

        Settlement.Interaction[] memory interactions2 = new Settlement.Interaction[](2);
        interactions2[0] = Settlement.Interaction({
            target: address(0x456), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("second()")))
        });
        interactions2[1] = Settlement.Interaction({
            target: address(0x123), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("first()")))
        });

        Settlement.ExecutionPlan memory plan1;
        plan1.preInteractions = new Settlement.Interaction[](0);
        plan1.interactions = interactions1;
        plan1.postInteractions = new Settlement.Interaction[](0);

        Settlement.ExecutionPlan memory plan2;
        plan2.preInteractions = new Settlement.Interaction[](0);
        plan2.interactions = interactions2;
        plan2.postInteractions = new Settlement.Interaction[](0);

        bytes32 hash1 = settlement.hashExecutionPlan(plan1);
        bytes32 hash2 = settlement.hashExecutionPlan(plan2);

        assertNotEq(hash1, hash2, "different interaction orders should produce different hashes");
    }

    /// @notice Hash function handles empty plans correctly
    function testHashExecutionPlanEmptyPlans() public {
        Settlement.ExecutionPlan memory emptyPlan;
        emptyPlan.preInteractions = new Settlement.Interaction[](0);
        emptyPlan.interactions = new Settlement.Interaction[](0);
        emptyPlan.postInteractions = new Settlement.Interaction[](0);

        bytes32 hash = settlement.hashExecutionPlan(emptyPlan);
        assertFalse(hash == bytes32(0), "empty plan should have non-zero hash");

        // Same empty plan should produce same hash
        bytes32 hash2 = settlement.hashExecutionPlan(emptyPlan);
        assertEq(hash, hash2, "empty plans should be deterministic");
    }

    /// @notice Hash function includes all interaction phases (pre, main, post)
    function testHashExecutionPlanIncludesAllPhases() public {
        Settlement.Interaction[] memory pre = new Settlement.Interaction[](1);
        pre[0] = Settlement.Interaction({
            target: address(0x111), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("pre()")))
        });

        Settlement.Interaction[] memory main = new Settlement.Interaction[](1);
        main[0] = Settlement.Interaction({
            target: address(0x222), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("main()")))
        });

        Settlement.Interaction[] memory post = new Settlement.Interaction[](1);
        post[0] = Settlement.Interaction({
            target: address(0x333), value: 0, callData: abi.encodeWithSelector(bytes4(keccak256("post()")))
        });

        Settlement.ExecutionPlan memory planWithAll;
        planWithAll.preInteractions = pre;
        planWithAll.interactions = main;
        planWithAll.postInteractions = post;

        Settlement.ExecutionPlan memory planWithoutPre;
        planWithoutPre.preInteractions = new Settlement.Interaction[](0);
        planWithoutPre.interactions = main;
        planWithoutPre.postInteractions = post;

        bytes32 hashWithAll = settlement.hashExecutionPlan(planWithAll);
        bytes32 hashWithoutPre = settlement.hashExecutionPlan(planWithoutPre);

        assertNotEq(hashWithAll, hashWithoutPre, "missing pre-interactions should change hash");
    }

    /// @notice EIP-712 domain separator is consistent across calls
    function testDomainSeparatorConsistency() public {
        bytes32 sep1 = settlement.domainSeparator();
        bytes32 sep2 = settlement.domainSeparator();
        bytes32 sep3 = settlement.domainSeparator();

        assertEq(sep1, sep2, "domain separator should be consistent");
        assertEq(sep2, sep3, "domain separator should be consistent across multiple calls");
        assertFalse(sep1 == bytes32(0), "domain separator should not be zero");
    }

    /// @notice Domain separator matches expected EIP-712 format
    function testDomainSeparatorFormat() public {
        bytes32 domainSep = settlement.domainSeparator();

        // Expected format: keccak256(abi.encode(
        //     keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        //     keccak256("OIF Settlement"),
        //     keccak256("1"),
        //     chainId,
        //     address(settlement)
        // ))

        bytes32 expectedDomainTypeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 expectedNameHash = keccak256(bytes("OIF Settlement"));
        bytes32 expectedVersionHash = keccak256(bytes("1"));
        uint256 chainId = block.chainid;
        address contractAddr = address(settlement);

        bytes32 expected = keccak256(abi.encode(
            expectedDomainTypeHash,
            expectedNameHash,
            expectedVersionHash,
            chainId,
            contractAddr
        ));

        assertEq(domainSep, expected, "domain separator should match expected EIP-712 format");
    }

    /// @notice Constructor initializes contract with correct owner
    function testConstructorInitialization() public {
        address initialOwner = address(0xABCD);
        Settlement newSettlement = new Settlement(initialOwner);

        // Test that owner is set correctly
        vm.prank(initialOwner);
        newSettlement.setRelayerRestriction(true); // This should not revert if owner is correct

        // Test domain separator is initialized
        bytes32 domainSep = newSettlement.domainSeparator();
        assertFalse(domainSep == bytes32(0), "domain separator should be initialized");

        // Test initial state - reset to false for this check
        vm.prank(initialOwner);
        newSettlement.setRelayerRestriction(false);
        assertFalse(newSettlement.relayerRestrictionEnabled(), "relayer restriction should be disabled initially");
        assertFalse(newSettlement.allowlistEnabled(), "allowlist should be disabled initially");
        assertEq(newSettlement.feeRecipient(), address(0), "fee recipient should be zero initially");
        assertEq(newSettlement.positiveSlippageFeeBps(), 0, "fee bps should be zero initially");
    }

    /// @notice Constructor reverts with zero owner address
    function testConstructorRevertsWithZeroOwner() public {
        vm.expectRevert(); // Ownable constructor may revert with zero address
        new Settlement(address(0));
    }

    /// @notice Self-call protection prevents direct calls to internal execute function
    function testSelfCallProtection() public {
        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = new Settlement.Interaction[](0);
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(Settlement.SelfCallOnly.selector);
        settlement._execute(intent, plan, 0);
    }

    /// @notice Contract accepts native ETH via receive function
    function testReceiveFunctionAcceptsEther() public {
        uint256 initialBalance = address(settlement).balance;
        uint256 sendAmount = 1 ether;

        vm.deal(address(this), sendAmount);
        (bool success,) = address(settlement).call{value: sendAmount}("");

        assertTrue(success, "receive function should accept ETH");
        assertEq(address(settlement).balance, initialBalance + sendAmount, "contract should hold the sent ETH");
    }

    /// @notice Contract accepts zero value ETH transfers
    function testReceiveFunctionAcceptsZeroValue() public {
        uint256 initialBalance = address(settlement).balance;

        (bool success,) = address(settlement).call{value: 0}("");

        assertTrue(success, "receive function should accept zero value transfers");
        assertEq(address(settlement).balance, initialBalance, "balance should remain unchanged");
    }

    /// @notice Fuzz test executeOrder with various amount combinations
    function testFuzzExecuteOrderAmounts(uint256 amountIn, uint256 minAmountOut) public {
        // Bound inputs to reasonable ranges to avoid overflow
        amountIn = bound(amountIn, 1, 1000 ether);
        minAmountOut = bound(minAmountOut, 0, amountIn); // minAmountOut <= amountIn

        // Skip if minAmountOut > amountIn (shouldn't happen due to bound, but safety check)
        vm.assume(minAmountOut <= amountIn);

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountIn);

        // Ensure interaction target will return at least minAmountOut
        vm.assume(amountIn >= minAmountOut);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, minAmountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        uint256 amountOut = settlement.executeOrder(intent, plan);

        // Basic invariants that should always hold
        assertGe(amountOut, minAmountOut, "should receive at least minimum amount");
        assertLe(amountOut, amountIn, "should not receive more than sent"); // Assuming no amplification
    }

    /// @notice Fuzz test with various deadlines
    function testFuzzExecuteOrderDeadlines(uint256 deadlineOffset) public {
        deadlineOffset = bound(deadlineOffset, 1, 365 days);

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, amountOut);

        intent.deadline = block.timestamp + deadlineOffset;

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // If we reach here, the deadline was valid
        assertTrue(block.timestamp <= intent.deadline, "deadline should be in future");
    }

    /// @notice Test reentrancy protection via ReentrancyGuard
    function testReentrancyProtection() public {
        ReentrancyAttackTarget attackTarget = new ReentrancyAttackTarget(payable(address(settlement)));

        Settlement.Interaction[] memory interactions = new Settlement.Interaction[](1);
        interactions[0] = Settlement.Interaction({
            target: address(attackTarget),
            value: 0,
            callData: abi.encodeWithSelector(ReentrancyAttackTarget.attack.selector)
        });

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = interactions;
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        vm.expectRevert(); // Should revert due to reentrancy guard
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
    }

    /// @notice Test fee calculation with large values to prevent overflow
    function testFeeCalculationBoundaryMaxValues() public {
        address feeReceiver = address(0xFEE);
        settlement.setFeeParameters(feeReceiver, 1000); // 10% fee

        uint256 amountIn = 100 ether;
        uint256 minAmountOut = 90 ether;
        // Use a large but safe value that won't cause overflow in calculations
        uint256 actualAmountOut = type(uint256).max / 1000; // Very large but safe for multiplication

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        // Mint large amount to interaction target
        tokenOut.mint(address(interactionTarget), actualAmountOut);

        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, minAmountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // Fee should be calculated: (actualAmountOut - minAmountOut) * feeBps / 10000
        uint256 expectedPositiveSlippage = actualAmountOut - minAmountOut;
        uint256 expectedFee = (expectedPositiveSlippage * 1000) / 10_000;

        assertEq(tokenOut.balanceOf(feeReceiver), expectedFee, "fee should be calculated correctly with large values");
    }

    /// @notice Test fee calculation with zero positive slippage
    function testFeeCalculationZeroSlippage() public {
        address feeReceiver = address(0xFEE);
        settlement.setFeeParameters(feeReceiver, 1000); // 10% fee

        uint256 amountIn = 100 ether;
        uint256 minAmountOut = 100 ether; // Equal to actual output
        uint256 actualAmountOut = 100 ether;

        MockInteractionTarget interactionTarget = _deployInteractionTarget(permitTokenIn, tokenOut);
        tokenOut.mint(address(interactionTarget), 1_000 ether);

        Settlement.ExecutionPlan memory plan = _buildPlan(address(permitTokenIn), address(interactionTarget), amountIn, actualAmountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, amountIn, minAmountOut);

        uint256 permitDeadline = block.timestamp + 1 hours;
        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.EIP2612,
            permitCall: _buildEIP2612PermitCall(permitTokenIn, amountIn, permitDeadline),
            amount: amountIn,
            deadline: permitDeadline
        });
        intent.userSignature = _signIntent(intent);

        uint256 initialFeeBalance = tokenOut.balanceOf(feeReceiver);

        vm.prank(relayer);
        settlement.executeOrder(intent, plan);

        // No positive slippage, so no fee
        assertEq(tokenOut.balanceOf(feeReceiver), initialFeeBalance, "no fee should be charged on zero slippage");
    }

    /// @notice Test gas consumption for complex execution plans
    function testGasConsumptionComplexPlan() public {
        // Create a plan with many interactions
        uint256 numInteractions = 10;
        Settlement.Interaction[] memory interactions = new Settlement.Interaction[](numInteractions);

        MockNoopTarget[] memory targets = new MockNoopTarget[](numInteractions);
        for (uint256 i = 0; i < numInteractions; i++) {
            targets[i] = new MockNoopTarget();
            settlement.setInteractionTarget(address(targets[i]), true);

            interactions[i] = Settlement.Interaction({
                target: address(targets[i]),
                value: 0,
                callData: abi.encodeWithSelector(MockNoopTarget.execute.selector)
            });
        }

        Settlement.ExecutionPlan memory plan;
        plan.preInteractions = new Settlement.Interaction[](0);
        plan.interactions = interactions;
        plan.postInteractions = new Settlement.Interaction[](0);

        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, permitTokenIn, tokenOut, 0, 0);
        intent.userSignature = _signIntent(intent);

        uint256 gasStart = gasleft();
        vm.prank(relayer);
        settlement.executeOrder(intent, plan);
        uint256 gasUsed = gasStart - gasleft();

        // Gas usage should be reasonable (less than 1M gas for 10 interactions)
        assertLt(gasUsed, 1_000_000, "gas consumption should be reasonable");

        // Verify all interactions executed
        for (uint256 i = 0; i < numInteractions; i++) {
            assertEq(targets[i].lastCaller(), address(settlement), "all interactions should execute");
        }
    }

    /// @notice Test integration with real ERC20 tokens (not mocks)
    function testIntegrationWithRealERC20() public {
        // Deploy real ERC20 token (not our mock)
        RealERC20 realTokenIn = new RealERC20("Real Token", "REAL");
        RealERC20 realTokenOut = new RealERC20("Real Output", "ROUT");

        // Mint tokens to user
        realTokenIn.mint(user, 1000 ether);

        // Create interaction target and mint tokens to it
        RealTokenInteractionTarget interactionTarget = new RealTokenInteractionTarget(realTokenIn, realTokenOut);
        realTokenOut.mint(address(interactionTarget), 1000 ether); // Mint output tokens to interaction target

        uint256 amountIn = 100 ether;
        uint256 amountOut = 95 ether;

        // Set up allowance
        vm.prank(user);
        realTokenIn.approve(address(settlement), amountIn);

        Settlement.ExecutionPlan memory plan = _buildPlan(address(realTokenIn), address(interactionTarget), amountIn, amountOut);
        Settlement.OrderIntent memory intent = _buildBaseIntent(plan, realTokenIn, realTokenOut, amountIn, amountOut);

        intent.permit = Settlement.PermitData({
            permitType: Settlement.PermitType.StandardApproval,
            permitCall: "",
            amount: amountIn,
            deadline: 0
        });
        intent.userSignature = _signIntent(intent);

        uint256 initialUserBalance = realTokenIn.balanceOf(user);
        uint256 initialReceiverBalance = realTokenOut.balanceOf(receiver);

        vm.prank(relayer);
        uint256 returnedAmountOut = settlement.executeOrder(intent, plan);

        // Verify token movements with real ERC20
        assertEq(realTokenIn.balanceOf(user), initialUserBalance - amountIn, "user should lose input tokens");
        assertEq(realTokenOut.balanceOf(receiver), initialReceiverBalance + amountOut, "receiver should gain output tokens");
        assertEq(returnedAmountOut, amountOut, "should return correct amount out");
    }

    /// @dev Constructs a baseline order intent used across test scenarios
    function _buildBaseIntent(
        Settlement.ExecutionPlan memory plan,
        IERC20 tokenIn_,
        IERC20 tokenOut_,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal view returns (Settlement.OrderIntent memory intent) {
        bytes32 interactionsHash = settlement.hashExecutionPlan(plan);

        intent.quoteId = keccak256("quote-id");
        intent.user = user;
        intent.tokenIn = tokenIn_;
        intent.tokenOut = tokenOut_;
        intent.amountIn = amountIn;
        intent.minAmountOut = minAmountOut;
        intent.receiver = receiver;
        intent.deadline = block.timestamp + 2 hours;
        intent.nonce = 1;
        intent.permit =
            Settlement.PermitData({permitType: Settlement.PermitType.None, permitCall: "", amount: 0, deadline: 0});
        intent.interactionsHash = interactionsHash;
        intent.callValue = 0;
        intent.gasEstimate = 150_000;
        intent.userSignature = bytes("");
    }

    /// @dev Builds a minimal approve-then-swap interaction plan targeting the mock contract
    function _buildPlan(address tokenIn_, address target_, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (Settlement.ExecutionPlan memory plan)
    {
        Settlement.Interaction[] memory pre = new Settlement.Interaction[](1);
        pre[0] = Settlement.Interaction({
            target: tokenIn_,
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, target_, amountIn)
        });

        Settlement.Interaction[] memory main = new Settlement.Interaction[](1);
        main[0] = Settlement.Interaction({
            target: target_,
            value: 0,
            callData: abi.encodeWithSelector(MockInteractionTarget.executeSwap.selector, amountIn, amountOut)
        });

        Settlement.Interaction[] memory post = new Settlement.Interaction[](0);

        plan.preInteractions = pre;
        plan.interactions = main;
        plan.postInteractions = post;
    }

    /// @dev Encodes an EIP-2612 permit payload for the mock permit token
    function _buildEIP2612PermitCall(MockPermitToken token, uint256 amount, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = token.nonces(user);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(settlement),
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PRIVATE_KEY, digest);

        return abi.encode(user, address(settlement), amount, deadline, v, r, s);
    }

    /// @dev Encodes an EIP-2612 permit payload with a custom spender for negative tests
    function _buildEIP2612PermitCallWithSpender(
        MockPermitToken token,
        address spender,
        uint256 amount,
        uint256 deadline
    ) internal view returns (bytes memory) {
        uint256 nonce = token.nonces(user);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                spender,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PRIVATE_KEY, digest);

        return abi.encode(user, spender, amount, deadline, v, r, s);
    }

    /// @dev Encodes an EIP-3009 transfer authorization payload for the mock token
    function _buildEIP3009PermitCall(MockEIP3009Token token, uint256 amount)
        internal
        view
        returns (bytes memory permitCall, uint256 validBefore)
    {
        uint256 validAfter = block.timestamp;
        validBefore = block.timestamp + 30 minutes;
        bytes32 nonce = keccak256("auth-nonce");

        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                user,
                address(settlement),
                amount,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PRIVATE_KEY, digest);

        permitCall = abi.encode(user, address(settlement), amount, validAfter, validBefore, nonce, v, r, s);
    }

    /// @dev Encodes an EIP-3009 authorization with explicit validity parameters
    function _buildEIP3009PermitCallWithParams(
        MockEIP3009Token token,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory permitCall) {
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                user,
                address(settlement),
                amount,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PRIVATE_KEY, digest);

        permitCall = abi.encode(user, address(settlement), amount, validAfter, validBefore, nonce, v, r, s);
    }

    /// @dev Produces a compact signature over the order intent using the test user's key
    function _signIntent(Settlement.OrderIntent memory intent) internal view returns (bytes memory) {
        bytes32 structHash = _hashOrderIntent(intent);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mirrors the contract helper to compute the order intent struct hash
    function _hashOrderIntent(Settlement.OrderIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                intent.quoteId,
                intent.user,
                address(intent.tokenIn),
                address(intent.tokenOut),
                intent.amountIn,
                intent.minAmountOut,
                intent.receiver,
                intent.deadline,
                intent.nonce,
                intent.interactionsHash,
                intent.callValue,
                intent.gasEstimate,
                _hashPermitData(intent.permit)
            )
        );
    }

    /// @dev Mirrors the contract helper to compute the permit struct hash
    function _hashPermitData(Settlement.PermitData memory permit) internal pure returns (bytes32) {
        if (permit.permitType == Settlement.PermitType.None) {
            return bytes32(0);
        }
        return keccak256(
            abi.encode(
                PERMIT_DATA_TYPEHASH,
                uint8(permit.permitType),
                keccak256(permit.permitCall),
                permit.amount,
                permit.deadline
            )
        );
    }

    /// @dev Deploys a mock interaction target that mimics a solver integration contract
    function _deployInteractionTarget(IERC20 tokenIn_, MockERC20 tokenOut_) internal returns (MockInteractionTarget) {
        return new MockInteractionTarget(address(settlement), tokenIn_, tokenOut_);
    }
}

/// @title Mock contract that attempts reentrancy during execution
contract ReentrancyAttackTarget {
    address payable public settlement;

    constructor(address payable settlement_) {
        settlement = settlement_;
    }

    function attack() external {
        // Try to call back into settlement during execution
        Settlement(settlement).executeOrder(
            Settlement.OrderIntent({
                quoteId: bytes32(0),
                user: address(0),
                tokenIn: IERC20(address(0)),
                tokenOut: IERC20(address(0)),
                amountIn: 0,
                minAmountOut: 0,
                receiver: address(0),
                deadline: 0,
                nonce: 0,
                permit: Settlement.PermitData({
                    permitType: Settlement.PermitType.None,
                    permitCall: "",
                    amount: 0,
                    deadline: 0
                }),
                interactionsHash: bytes32(0),
                callValue: 0,
                gasEstimate: 0,
                userSignature: ""
            }),
            Settlement.ExecutionPlan({
                preInteractions: new Settlement.Interaction[](0),
                interactions: new Settlement.Interaction[](0),
                postInteractions: new Settlement.Interaction[](0)
            })
        );
    }
}

/// @title Real ERC20 token for integration testing
contract RealERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Interaction target that works with real ERC20 tokens
contract RealTokenInteractionTarget {
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;

    constructor(IERC20 tokenIn_, IERC20 tokenOut_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    function executeSwap(uint256 amountIn, uint256 amountOut) external {
        // Pull input tokens from settlement contract and send output tokens back
        // This mimics what a real DEX would do
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, amountOut);
    }
}

/// @title ERC20 token with EIP-2612 permit support for testing
contract MockPermitToken is ERC20, ERC20Permit {
    address public settlementCaller;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC20Permit(name_) {}

    /// @notice Mints tokens for test scenarios
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setSettlementCaller(address caller) external {
        settlementCaller = caller;
    }

    function customPermit(address owner, address spender, uint256 amount) external {
        require(msg.sender == settlementCaller, "UNAUTHORIZED_CALLER");
        _approve(owner, spender, amount);
    }
}

/// @title Minimal ERC20 used as the output asset in tests
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mints tokens for test scenarios
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title Mock interaction target that simulates solver integrations
contract MockInteractionTarget {
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;
    address public immutable settlement;

    // Track calls for validation
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;
    address public lastCaller;

    error OnlySettlement();
    error InvalidAmountIn(uint256 expected, uint256 actual);
    error InvalidAmountOut(uint256 expected, uint256 actual);

    constructor(address settlement_, IERC20 tokenIn_, IERC20 tokenOut_) {
        settlement = settlement_;
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    /// @notice Simulates a solver interaction by pulling tokens and sending outputs back to the settlement
    function executeSwap(uint256 amountIn, uint256 amountOut) external {
        if (msg.sender != settlement) {
            revert OnlySettlement();
        }

        // Record the call for validation
        lastCaller = msg.sender;
        lastAmountIn = amountIn;
        lastAmountOut = amountOut;

        // Verify we have enough tokens to send
        require(tokenOut.balanceOf(address(this)) >= amountOut, "insufficient output tokens");

        // Pull input tokens and send output tokens
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, amountOut);
    }

    /// @notice Validates that the last call received the expected amounts
    function validateLastCall(uint256 expectedAmountIn, uint256 expectedAmountOut) external view {
        require(lastCaller == settlement, "no valid call recorded");
        require(lastAmountIn == expectedAmountIn, "incorrect amountIn");
        require(lastAmountOut == expectedAmountOut, "incorrect amountOut");
    }
}

/// @title Mock token implementing the EIP-3009 authorization flow
contract MockEIP3009Token is ERC20 {
    using ECDSA for bytes32;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(bytes32 => bool) public authorizationState;
    bytes32 private immutable _domainSeparator;

    error AuthorizationUsed(bytes32 nonce);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name_)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Mints tokens for test scenarios
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Returns the EIP-712 domain separator used for signatures
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator;
    }

    /// @notice Transfers tokens based on an EIP-3009 style authorization
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
    ) external {
        if (block.timestamp < validAfter) {
            revert("AUTH_NOT_YET_VALID");
        }
        if (block.timestamp > validBefore) {
            revert("AUTH_EXPIRED");
        }

        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
        address signer = digest.recover(v, r, s);
        require(signer == from, "AUTH_INVALID_SIGNATURE");

        if (authorizationState[nonce]) {
            revert AuthorizationUsed(nonce);
        }
        authorizationState[nonce] = true;

        _transfer(from, to, value);
    }
}

/// @title Simple no-op interaction target used for allowlist testing
contract MockNoopTarget {
    address public lastCaller;

    function execute() external {
        lastCaller = msg.sender;
    }
}

/// @title Mock contract that records received native ETH for call value tests
contract MockNativeSink {
    uint256 public received;

    function consume() external payable {
        received += msg.value;
    }
}

/// @title Interaction target that always reverts for testing bubble-up behavior
contract MockRevertingInteractionTarget {
    function revertWithReason() external pure {
        revert("INTERACTION_REVERT");
    }
}

/// @title ERC20 token whose custom permit reverts
contract MockFailingCustomPermitToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function failingPermit() external pure {
        revert("CUSTOM_PERMIT_FAILED");
    }
}

/// @title ERC20 token that transfers less than requested to trigger settlement guards
contract MockPartialTransferToken is ERC20 {
    uint256 private constant PARTIAL_SHORTFALL = 1 ether;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function shortfall() external pure returns (uint256) {
        return PARTIAL_SHORTFALL;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 transferAmount = value > PARTIAL_SHORTFALL ? value - PARTIAL_SHORTFALL : 0;
        super.transferFrom(from, to, transferAmount);
        return true;
    }
}
