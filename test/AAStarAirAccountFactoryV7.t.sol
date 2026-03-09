// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";

/// @title AAStarAirAccountFactoryV7Test - Unit tests for CREATE2 factory
contract AAStarAirAccountFactoryV7Test is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public ownerA;
    address public ownerB;

    function setUp() public {
        entryPoint = makeAddr("entryPoint");
        ownerA = makeAddr("ownerA");
        ownerB = makeAddr("ownerB");

        factory = new AAStarAirAccountFactoryV7(entryPoint);
    }

    /// @notice createAccount should deploy a new account with correct owner and entryPoint
    function test_createAccount() public {
        address account = factory.createAccount(ownerA, 0);

        assertTrue(account != address(0), "Account should be deployed");
        assertTrue(account.code.length > 0, "Account should have code");

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));
        assertEq(acc.owner(), ownerA, "Owner should match");
        assertEq(acc.entryPoint(), entryPoint, "EntryPoint should match");
    }

    /// @notice Creating the same account twice should return the same address (idempotent)
    function test_createAccount_deterministic() public {
        address account1 = factory.createAccount(ownerA, 42);
        address account2 = factory.createAccount(ownerA, 42);

        assertEq(account1, account2, "Same owner + salt should produce same address");
    }

    /// @notice getAddress prediction should match actual deployment address
    function test_getAddress_matchesCreated() public {
        uint256 salt = 123;
        address predicted = factory.getAddress(ownerA, salt);
        address actual = factory.createAccount(ownerA, salt);

        assertEq(predicted, actual, "Predicted address should match deployed address");
    }

    /// @notice Different owners should produce different account addresses
    function test_createAccount_differentOwners() public {
        address accountA = factory.createAccount(ownerA, 0);
        address accountB = factory.createAccount(ownerB, 0);

        assertTrue(accountA != accountB, "Different owners should get different addresses");
    }

    /// @notice Same owner with different salts should produce different addresses
    function test_createAccount_differentSalts() public {
        address account1 = factory.createAccount(ownerA, 0);
        address account2 = factory.createAccount(ownerA, 1);

        assertTrue(account1 != account2, "Different salts should produce different addresses");
    }

    /// @notice Factory should store the correct entryPoint
    function test_factoryEntryPoint() public view {
        assertEq(factory.entryPoint(), entryPoint, "Factory entryPoint should match");
    }

    /// @notice createAccount should emit AccountCreated event
    function test_createAccount_emitsEvent() public {
        uint256 salt = 99;
        address predicted = factory.getAddress(ownerA, salt);

        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountFactoryV7.AccountCreated(predicted, ownerA, salt);

        factory.createAccount(ownerA, salt);
    }
}
