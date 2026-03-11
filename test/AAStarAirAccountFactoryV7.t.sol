// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, console2} from "forge-std/Test.sol";
import {AAStarAirAccountFactoryV7} from "../src/core/AAStarAirAccountFactoryV7.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";

/// @title AAStarAirAccountFactoryV7Test - Unit tests for CREATE2 factory
contract AAStarAirAccountFactoryV7Test is Test {
    AAStarAirAccountFactoryV7 public factory;
    address public entryPoint;
    address public ownerA;
    address public ownerB;
    address public guardian1;
    address public guardian2;
    address public communityGuardian;

    uint256 constant TEST_DAILY_LIMIT = 0.5 ether;

    function setUp() public {
        entryPoint = makeAddr("entryPoint");
        ownerA = makeAddr("ownerA");
        ownerB = makeAddr("ownerB");
        guardian1 = makeAddr("guardian1");
        guardian2 = makeAddr("guardian2");
        communityGuardian = makeAddr("communityGuardian");

        factory = new AAStarAirAccountFactoryV7(entryPoint, communityGuardian);
    }

    function _minimalConfig() internal pure returns (AAStarAirAccountBase.InitConfig memory) {
        uint8[] memory noAlgs = new uint8[](0);
        return AAStarAirAccountBase.InitConfig({
            guardians: [address(0), address(0), address(0)],
            dailyLimit: 0,
            approvedAlgIds: noAlgs,
            minDailyLimit: 0
        });
    }

    // ─── createAccountWithDefaults ──────────────────────────────────

    function test_createAccountWithDefaults() public {
        address account = factory.createAccountWithDefaults(ownerA, 0, guardian1, guardian2, TEST_DAILY_LIMIT);

        assertTrue(account.code.length > 0);

        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));
        assertEq(acc.owner(), ownerA);
        assertEq(acc.guardianCount(), 3);
        assertEq(acc.guardians(0), guardian1);
        assertEq(acc.guardians(1), guardian2);
        assertEq(acc.guardians(2), communityGuardian);

        // Guard should be initialized with user-specified daily limit
        assertTrue(address(acc.guard()) != address(0));
        AAStarGlobalGuard g = acc.guard();
        assertEq(g.account(), account);
        assertEq(g.dailyLimit(), TEST_DAILY_LIMIT);
        assertTrue(g.approvedAlgorithms(0x02)); // ECDSA
        assertTrue(g.approvedAlgorithms(0x01)); // BLS
        assertTrue(g.approvedAlgorithms(0x03)); // P256
    }

    function test_createAccountWithDefaults_deterministic() public {
        address a1 = factory.createAccountWithDefaults(ownerA, 1, guardian1, guardian2, TEST_DAILY_LIMIT);
        address a2 = factory.createAccountWithDefaults(ownerA, 1, guardian1, guardian2, TEST_DAILY_LIMIT);
        assertEq(a1, a2);
    }

    function test_getAddressWithDefaults_matchesCreated() public {
        address predicted = factory.getAddressWithDefaults(ownerA, 5, guardian1, guardian2, TEST_DAILY_LIMIT);
        address actual = factory.createAccountWithDefaults(ownerA, 5, guardian1, guardian2, TEST_DAILY_LIMIT);
        assertEq(predicted, actual);
    }

    function test_createAccountWithDefaults_differentLimits() public {
        address a1 = factory.createAccountWithDefaults(ownerA, 0, guardian1, guardian2, 0.1 ether);
        address a2 = factory.createAccountWithDefaults(ownerA, 0, guardian1, guardian2, 1 ether);
        // Different daily limits produce different addresses (different initcode)
        assertTrue(a1 != a2);
    }

    // ─── createAccount (full config) ────────────────────────────────

    function test_createAccount_fullConfig() public {
        uint8[] memory algIds = new uint8[](2);
        algIds[0] = 0x02;
        algIds[1] = 0x03;
        AAStarAirAccountBase.InitConfig memory config = AAStarAirAccountBase.InitConfig({
            guardians: [guardian1, guardian2, address(0)],
            dailyLimit: 5 ether,
            approvedAlgIds: algIds,
            minDailyLimit: 0
        });

        address account = factory.createAccount(ownerA, 0, config);
        AAStarAirAccountV7 acc = AAStarAirAccountV7(payable(account));

        assertEq(acc.guardianCount(), 2);
        assertEq(acc.guardians(0), guardian1);
        assertEq(acc.guardians(1), guardian2);
        assertEq(acc.guard().dailyLimit(), 5 ether);
    }

    function test_getAddress_matchesCreated() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 123, config);
        address actual = factory.createAccount(ownerA, 123, config);
        assertEq(predicted, actual);
    }

    // ─── Different params produce different addresses ────────────────

    function test_differentOwners_differentAddresses() public {
        address a = factory.createAccountWithDefaults(ownerA, 0, guardian1, guardian2, TEST_DAILY_LIMIT);
        address b = factory.createAccountWithDefaults(ownerB, 0, guardian1, guardian2, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    function test_differentSalts_differentAddresses() public {
        address a = factory.createAccountWithDefaults(ownerA, 0, guardian1, guardian2, TEST_DAILY_LIMIT);
        address b = factory.createAccountWithDefaults(ownerA, 1, guardian1, guardian2, TEST_DAILY_LIMIT);
        assertTrue(a != b);
    }

    // ─── Factory state ──────────────────────────────────────────────

    function test_factoryEntryPoint() public view {
        assertEq(factory.entryPoint(), entryPoint);
    }

    function test_factoryCommunityGuardian() public view {
        assertEq(factory.defaultCommunityGuardian(), communityGuardian);
    }

    // ─── Event emission ─────────────────────────────────────────────

    function test_createAccount_emitsEvent() public {
        AAStarAirAccountBase.InitConfig memory config = _minimalConfig();
        address predicted = factory.getAddress(ownerA, 99, config);

        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountFactoryV7.AccountCreated(predicted, ownerA, 99);

        factory.createAccount(ownerA, 99, config);
    }
}
