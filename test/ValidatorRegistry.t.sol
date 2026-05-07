// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ValidatorRegistry.sol";

contract ValidatorRegistryTest is Test {
    ValidatorRegistry public registry;

    address public owner;
    address[] public initialValidators;

    function setUp() public {
        owner = address(0xA11CE);
        initialValidators.push(address(0x100));
        initialValidators.push(address(0x200));
        initialValidators.push(address(0x300));

        registry = new ValidatorRegistry(owner, initialValidators);
    }

    function test_constructorSetsValidators() public view {
        address[] memory vals = registry.getValidators();
        assertEq(vals.length, 3);
        assertEq(vals[0], address(0x100));
        assertEq(vals[1], address(0x200));
        assertEq(vals[2], address(0x300));
        assertEq(registry.owner(), owner);
    }

    function test_isValidator() public view {
        assertTrue(registry.isValidator(address(0x100)));
        assertTrue(registry.isValidator(address(0x200)));
        assertTrue(registry.isValidator(address(0x300)));
        assertFalse(registry.isValidator(address(0x400)));
        assertFalse(registry.isValidator(address(0)));
    }

    function test_getValidatorCount() public view {
        assertEq(registry.getValidatorCount(), 3);
    }

    function test_updateValidatorsReplacesSet() public {
        address[] memory newVals = new address[](2);
        newVals[0] = address(0x400);
        newVals[1] = address(0x500);

        vm.prank(owner);
        registry.updateValidators(newVals);

        // New validators present
        assertTrue(registry.isValidator(address(0x400)));
        assertTrue(registry.isValidator(address(0x500)));
        assertEq(registry.getValidatorCount(), 2);

        // Old validators removed
        assertFalse(registry.isValidator(address(0x100)));
        assertFalse(registry.isValidator(address(0x200)));
        assertFalse(registry.isValidator(address(0x300)));
    }

    function test_updateValidatorsOnlyOwner() public {
        address[] memory newVals = new address[](1);
        newVals[0] = address(0x400);

        vm.expectRevert("Only owner");
        registry.updateValidators(newVals);
    }

    function test_updateValidatorsEmitsEvent() public {
        address[] memory newVals = new address[](2);
        newVals[0] = address(0x400);
        newVals[1] = address(0x500);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IValidatorRegistry.ValidatorsUpdated(newVals);
        registry.updateValidators(newVals);
    }

    function test_cannotSetEmptyValidators() public {
        address[] memory empty = new address[](0);

        vm.prank(owner);
        vm.expectRevert("No validators");
        registry.updateValidators(empty);
    }

    function test_cannotSetZeroAddressValidator() public {
        address[] memory bad = new address[](1);
        bad[0] = address(0);

        vm.prank(owner);
        vm.expectRevert("Invalid validator");
        registry.updateValidators(bad);
    }

    function test_transferOwnership() public {
        address newOwner = address(0xBEEF);

        vm.prank(owner);
        registry.transferOwnership(newOwner);

        assertEq(registry.owner(), newOwner);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.expectRevert("Only owner");
        registry.transferOwnership(address(0xBEEF));
    }

    function test_transferOwnership_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert("Invalid owner");
        registry.transferOwnership(address(0));
    }

    function test_constructorRejectsZeroOwner() public {
        address[] memory vals = new address[](1);
        vals[0] = address(0x100);

        vm.expectRevert("Invalid owner");
        new ValidatorRegistry(address(0), vals);
    }

    function test_constructorRejectsEmptyValidators() public {
        address[] memory empty = new address[](0);

        vm.expectRevert("No validators");
        new ValidatorRegistry(owner, empty);
    }

    function test_constructorRejectsDuplicateValidators() public {
        address[] memory dupes = new address[](2);
        dupes[0] = address(0x100);
        dupes[1] = address(0x100);

        vm.expectRevert("Duplicate validator");
        new ValidatorRegistry(owner, dupes);
    }

    function test_updateValidatorsRejectsDuplicates() public {
        address[] memory dupes = new address[](2);
        dupes[0] = address(0x400);
        dupes[1] = address(0x400);

        vm.prank(owner);
        vm.expectRevert("Duplicate validator");
        registry.updateValidators(dupes);
    }
}
