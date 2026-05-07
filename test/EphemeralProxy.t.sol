// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EphemeralProxy.sol";
import "../src/interfaces/IAppIntentBase.sol";
import "./mocks/MockToken.sol";

contract EphemeralProxyTest is Test {
    MockToken public token;

    function setUp() public {
        token = new MockToken("Test", "TST", 18);
    }

    function test_executeMultipleCalls() public {
        EphemeralProxy proxy = new EphemeralProxy();
        token.mint(address(proxy), 1000e18);

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(
                token.transfer.selector,
                address(this),
                500e18
            )
        });

        proxy.execute(calls);
        assertEq(token.balanceOf(address(this)), 500e18);
    }

    function test_executeWithValue() public {
        EphemeralProxy proxy = new EphemeralProxy();
        vm.deal(address(this), 1 ether);

        address recipient = address(0xBEEF);
        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: recipient,
            value: 0.5 ether,
            callData: ""
        });

        proxy.execute{value: 0.5 ether}(calls);
        assertEq(recipient.balance, 0.5 ether);
    }

    function test_executeReturnsRemainingEth() public {
        EphemeralProxy proxy = new EphemeralProxy();
        vm.deal(address(this), 2 ether);
        uint256 balanceBefore = address(this).balance;

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](0);
        proxy.execute{value: 1 ether}(calls);

        // Should get ETH back since no calls consumed it
        assertEq(address(this).balance, balanceBefore);
    }

    function test_executeRevertsOnFailedCall() public {
        EphemeralProxy proxy = new EphemeralProxy();

        IAppIntentBase.Call[] memory calls = new IAppIntentBase.Call[](1);
        calls[0] = IAppIntentBase.Call({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(
                token.transfer.selector,
                address(this),
                1000e18  // More than balance
            )
        });

        vm.expectRevert();
        proxy.execute(calls);
    }

    function test_create2Deterministic() public {
        bytes32 salt1 = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));

        EphemeralProxy p1 = new EphemeralProxy{salt: salt1}();
        EphemeralProxy p2 = new EphemeralProxy{salt: salt2}();

        assertTrue(address(p1) != address(p2));
    }

    receive() external payable {}
}
